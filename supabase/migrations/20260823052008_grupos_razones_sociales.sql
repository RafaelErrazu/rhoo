-- ══ 1. GRUPOS COMERCIALES ════════════════════════════════════════════════

create table if not exists public.grupos_empresariales (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  clave        text not null,
  nombre       text not null,
  -- De dónde salen las reglas de operación. 'grupo' las hereda para todas sus
  -- empresas; 'empresa' deja que cada una defina las suyas. Configurable
  -- porque un mismo cliente puede tener grupos homogeneos y heterogeneos.
  reglas_desde text not null default 'grupo'
               check (reglas_desde in ('grupo','empresa')),
  config       jsonb not null default '{}'::jsonb,
  activo       boolean not null default true,
  creado_en    timestamptz not null default now(),
  unique (tenant_id, clave)
);

alter table public.grupos_empresariales enable row level security;

drop policy if exists grupos_emp_leer on public.grupos_empresariales;
create policy grupos_emp_leer on public.grupos_empresariales
  for select using (tenant_id = app.mi_tenant());

drop policy if exists grupos_emp_escribir on public.grupos_empresariales;
create policy grupos_emp_escribir on public.grupos_empresariales
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

grant select, insert, update, delete on public.grupos_empresariales to authenticated;
grant all on public.grupos_empresariales to service_role;

-- ══ 2. RAZONES SOCIALES ══════════════════════════════════════════════════

create table if not exists public.razones_sociales (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  grupo_id      uuid not null references public.grupos_empresariales(id),

  clave         text not null,
  razon_social  text not null,
  nombre_comercial text,

  -- Identificación fiscal y patronal. Sin esto no hay CFDI ni IDSE.
  rfc               text,
  registro_patronal text,
  regimen_fiscal    text,
  codigo_postal     text,
  domicilio         text,

  representante_legal text,
  activo        boolean not null default true,
  config        jsonb not null default '{}'::jsonb,
  creado_en     timestamptz not null default now(),

  unique (tenant_id, clave)
);

create unique index if not exists rs_rfc_idx
  on public.razones_sociales (tenant_id, upper(trim(rfc)))
  where rfc is not null;

create index if not exists rs_grupo_idx on public.razones_sociales (grupo_id);

alter table public.razones_sociales enable row level security;

drop policy if exists rs_leer on public.razones_sociales;
create policy rs_leer on public.razones_sociales
  for select using (tenant_id = app.mi_tenant());

drop policy if exists rs_escribir on public.razones_sociales;
create policy rs_escribir on public.razones_sociales
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

grant select, insert, update, delete on public.razones_sociales to authenticated;
grant all on public.razones_sociales to service_role;

-- ══ 3. PRIMA DE RIESGO CON VIGENCIA ══════════════════════════════════════

/* La prima se determina cada febrero ante el IMSS. Con vigencia y no como
   valor unico: recalcular un periodo viejo debe usar la prima de entonces. */
create table if not exists public.primas_riesgo (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  razon_id     uuid not null references public.razones_sociales(id) on delete cascade,
  clase        text,
  fraccion     text,
  prima        numeric(8,6) not null check (prima >= 0 and prima <= 0.15),
  vigente_de   date not null,
  vigente_a    date,
  nota         text,
  creado_en    timestamptz not null default now(),
  unique (razon_id, vigente_de)
);

alter table public.primas_riesgo enable row level security;

drop policy if exists primas_leer on public.primas_riesgo;
create policy primas_leer on public.primas_riesgo
  for select using (tenant_id = app.mi_tenant());

drop policy if exists primas_escribir on public.primas_riesgo;
create policy primas_escribir on public.primas_riesgo
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

grant select, insert, update, delete on public.primas_riesgo to authenticated;
grant all on public.primas_riesgo to service_role;

-- ══ 4. MIGRAR LOS DATOS EXISTENTES ═══════════════════════════════════════

-- Un grupo por tenant. Los clientes con una sola empresa nunca lo van a ver.
insert into public.grupos_empresariales (tenant_id, clave, nombre, reglas_desde)
select t.id, 'GRAL', coalesce(t.nombre,'Grupo principal'), 'grupo'
from public.tenants t
where not exists (
  select 1 from public.grupos_empresariales g where g.tenant_id = t.id);

-- Una razón social por cada texto distinto que ya exista en centros. Los
-- centros sin razon social capturada caen en una generica.
insert into public.razones_sociales (tenant_id, grupo_id, clave, razon_social, rfc)
select distinct on (c.tenant_id, upper(trim(coalesce(c.razon_social,''))))
       c.tenant_id,
       g.id,
       'RS' || lpad((dense_rank() over (
         partition by c.tenant_id
         order by upper(trim(coalesce(c.razon_social,'')))
       ))::text, 2, '0'),
       coalesce(nullif(trim(c.razon_social),''), t.nombre, 'Razón social principal'),
       t.rfc
from public.centros_trabajo c
join public.tenants t on t.id = c.tenant_id
join public.grupos_empresariales g on g.tenant_id = c.tenant_id and g.clave = 'GRAL'
where not exists (
  select 1 from public.razones_sociales r where r.tenant_id = c.tenant_id);

-- Tenants sin centros: también necesitan su razón social para poder operar.
insert into public.razones_sociales (tenant_id, grupo_id, clave, razon_social, rfc)
select t.id, g.id, 'RS01', coalesce(t.nombre,'Razón social principal'), t.rfc
from public.tenants t
join public.grupos_empresariales g on g.tenant_id = t.id and g.clave = 'GRAL'
where not exists (
  select 1 from public.razones_sociales r where r.tenant_id = t.id);

-- ══ 5. CENTROS APUNTAN A RAZÓN SOCIAL ════════════════════════════════════

alter table public.centros_trabajo
  add column if not exists razon_id uuid references public.razones_sociales(id);

update public.centros_trabajo c
   set razon_id = r.id
  from public.razones_sociales r
 where r.tenant_id = c.tenant_id
   and c.razon_id is null
   and upper(trim(coalesce(c.razon_social,''))) = upper(trim(r.razon_social));

-- Los que no empataron por nombre van a la primera razón social del tenant.
update public.centros_trabajo c
   set razon_id = (select r.id from public.razones_sociales r
                    where r.tenant_id = c.tenant_id order by r.clave limit 1)
 where c.razon_id is null;

alter table public.centros_trabajo alter column razon_id set not null;

comment on column public.centros_trabajo.razon_social is
  'OBSOLETA. La razón social vive en razones_sociales via razon_id. Se conserva
   temporalmente para poder auditar la migración.';

-- ══ 6. EMPLEADOS PERTENECEN A UNA RAZÓN SOCIAL ═══════════════════════════

/* En empleados y no en sueldos: cambiar de razon social es legalmente una baja
   y un alta con contrato nuevo, no un dato con vigencia. El cambio se registra
   como movimiento laboral. */
alter table public.empleados
  add column if not exists razon_id uuid references public.razones_sociales(id);

update public.empleados e
   set razon_id = c.razon_id
  from public.centros_trabajo c
 where c.id = e.centro_id and e.razon_id is null;

update public.empleados e
   set razon_id = (select r.id from public.razones_sociales r
                    where r.tenant_id = e.tenant_id order by r.clave limit 1)
 where e.razon_id is null;

create index if not exists empleados_razon_idx on public.empleados (razon_id);

-- Coherencia: el centro del empleado debe pertenecer a su misma razon social.
-- Sin esto, alguien contratado por la empresa A podria checar en un centro de
-- la empresa B y su nomina saldria en el periodo equivocado.
create or replace function app.validar_razon_centro()
returns trigger language plpgsql
security definer set search_path = public, pg_temp as $fn$
declare v_razon uuid;
begin
  if new.centro_id is null then return new; end if;

  select razon_id into v_razon from public.centros_trabajo where id = new.centro_id;

  if new.razon_id is null then
    new.razon_id := v_razon;
  elsif v_razon is not null and new.razon_id <> v_razon then
    raise exception 'El centro pertenece a otra razon social. Cambia primero el centro o registra el movimiento de cambio de empresa.';
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_razon_centro on public.empleados;
create trigger trg_razon_centro
  before insert or update of centro_id, razon_id on public.empleados
  for each row execute function app.validar_razon_centro();

-- ══ 7. GRUPOS DE PAGO Y PERIODOS POR RAZÓN SOCIAL ════════════════════════

/* El CFDI se timbra con un RFC. Un periodo que abarque dos razones sociales
   seria imposible de timbrar, asi que la nomina cuelga de la razon social. */
alter table public.grupos_nomina
  add column if not exists razon_id uuid references public.razones_sociales(id);

update public.grupos_nomina g
   set razon_id = coalesce(
         (select c.razon_id from public.centros_trabajo c where c.id = g.centro_id),
         (select r.id from public.razones_sociales r
           where r.tenant_id = g.tenant_id order by r.clave limit 1))
 where g.razon_id is null;

alter table public.grupos_nomina alter column razon_id set not null;

alter table public.periodos_nomina
  add column if not exists razon_id uuid references public.razones_sociales(id);

update public.periodos_nomina p
   set razon_id = g.razon_id
  from public.grupos_nomina g
 where g.id = p.grupo_id and p.razon_id is null;

alter table public.periodos_nomina alter column razon_id set not null;

-- El periodo hereda la razón social de su grupo y no puede divergir.
create or replace function app.sync_razon_periodo()
returns trigger language plpgsql
security definer set search_path = public, pg_temp as $fn$
begin
  select razon_id into new.razon_id
    from public.grupos_nomina where id = new.grupo_id;
  return new;
end;
$fn$;

drop trigger if exists trg_sync_razon_periodo on public.periodos_nomina;
create trigger trg_sync_razon_periodo
  before insert or update of grupo_id on public.periodos_nomina
  for each row execute function app.sync_razon_periodo();

-- ══ 8. HELPERS DE CONFIGURACIÓN CON HERENCIA ═════════════════════════════

/* Valor efectivo de una llave: empresa → grupo → tenant → defaults.
   Con override por nivel para que un grupo homogeneo no capture nada y uno
   heterogeneo ajuste solo sus excepciones. */
create or replace function app.cfg_razon(p_clave text, p_razon uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  r public.razones_sociales;
  g public.grupos_empresariales;
  v jsonb;
begin
  if p_razon is null then return app.cfg(p_clave); end if;

  select * into r from public.razones_sociales where id = p_razon;
  if not found then return app.cfg(p_clave); end if;

  select * into g from public.grupos_empresariales where id = r.grupo_id;

  -- Si las reglas las manda el grupo, el valor de la empresa se ignora: es la
  -- diferencia entre un grupo que estandariza y uno que solo consolida.
  if g.reglas_desde = 'empresa' and r.config ? p_clave then
    return r.config -> p_clave;
  end if;

  if g.config ? p_clave then
    return g.config -> p_clave;
  end if;

  return app.cfg(p_clave, r.tenant_id);
end;
$$;

create or replace function app.cfg_razon_int(p_clave text, p_razon uuid)
returns integer language sql stable
security definer set search_path = public, pg_temp as $$
  select nullif(trim(app.cfg_razon(p_clave, p_razon) #>> '{}'), '')::integer
$$;

create or replace function app.cfg_razon_bool(p_clave text, p_razon uuid)
returns boolean language sql stable
security definer set search_path = public, pg_temp as $$
  select coalesce((app.cfg_razon(p_clave, p_razon))::text::boolean, false)
$$;

/* Prima de riesgo vigente a una fecha. */
create or replace function public.prima_riesgo(p_razon uuid, p_fecha date default current_date)
returns numeric language sql stable
security definer set search_path = public, pg_temp as $$
  select prima from public.primas_riesgo
   where razon_id = p_razon
     and vigente_de <= p_fecha
     and (vigente_a is null or vigente_a >= p_fecha)
   order by vigente_de desc
   limit 1
$$;

grant execute on function app.cfg_razon(text, uuid) to authenticated;
grant execute on function app.cfg_razon_int(text, uuid) to authenticated;
grant execute on function app.cfg_razon_bool(text, uuid) to authenticated;
grant execute on function public.prima_riesgo(uuid, date) to authenticated;

-- ══ 9. RPCs DE ADMINISTRACIÓN ════════════════════════════════════════════

create or replace function public.estructura_empresarial()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_t uuid := app.mi_tenant();
begin
  if v_t is null then raise exception 'Sin sesion valida'; end if;

  return jsonb_build_object(
    'es_admin', app.es_admin(),
    'grupos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', g.id, 'clave', g.clave, 'nombre', g.nombre,
               'reglas_desde', g.reglas_desde, 'activo', g.activo,
               'empresas', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'id', r.id, 'clave', r.clave,
                          'razon_social', r.razon_social,
                          'nombre_comercial', r.nombre_comercial,
                          'rfc', r.rfc, 'registro_patronal', r.registro_patronal,
                          'regimen_fiscal', r.regimen_fiscal,
                          'codigo_postal', r.codigo_postal,
                          'domicilio', r.domicilio,
                          'representante_legal', r.representante_legal,
                          'activo', r.activo,
                          'prima', public.prima_riesgo(r.id),
                          'centros', (
                            select count(*) from public.centros_trabajo c
                             where c.razon_id = r.id and c.activo),
                          'empleados', (
                            select count(*) from public.empleados e
                             where e.razon_id = r.id and e.estatus = 'Activo'),
                          -- Lo que impide operar, al frente: sin RFC no hay
                          -- CFDI y sin registro patronal no hay IDSE.
                          'faltantes', (
                            select coalesce(jsonb_agg(x), '[]'::jsonb) from (
                              select 'RFC' as x where r.rfc is null
                              union all
                              select 'Registro patronal' where r.registro_patronal is null
                              union all
                              select 'Régimen fiscal' where r.regimen_fiscal is null
                              union all
                              select 'Código postal' where r.codigo_postal is null
                              union all
                              select 'Prima de riesgo' where public.prima_riesgo(r.id) is null
                            ) f)
                        ) order by r.clave), '[]'::jsonb)
                   from public.razones_sociales r where r.grupo_id = g.id)
             ) order by g.clave), '[]'::jsonb)
        from public.grupos_empresariales g where g.tenant_id = v_t)
  );
end;
$$;

create or replace function public.grupo_emp_guardar(
  p_clave text, p_nombre text, p_reglas_desde text default 'grupo',
  p_activo boolean default true, p_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if not app.es_admin() then
    raise exception 'Solo administración puede administrar grupos.';
  end if;
  if p_reglas_desde not in ('grupo','empresa') then
    raise exception 'Valor invalido para el origen de las reglas';
  end if;

  if p_id is null then
    insert into public.grupos_empresariales
      (tenant_id, clave, nombre, reglas_desde, activo)
    values (app.mi_tenant(), upper(trim(p_clave)), trim(p_nombre),
            p_reglas_desde, coalesce(p_activo,true))
    returning id into v_id;
  else
    update public.grupos_empresariales
       set nombre = trim(p_nombre), reglas_desde = p_reglas_desde,
           activo = coalesce(p_activo,true)
     where id = p_id and tenant_id = app.mi_tenant()
    returning id into v_id;
    if v_id is null then raise exception 'Grupo no encontrado'; end if;
  end if;

  perform app.auditar('grupo_empresarial','grupos_empresariales', v_id::text, null,
    jsonb_build_object('clave', p_clave, 'nombre', p_nombre,
                       'reglas_desde', p_reglas_desde));
  return jsonb_build_object('status','success','id',v_id);
end;
$$;

create or replace function public.razon_guardar(
  p_grupo_id uuid, p_clave text, p_razon_social text,
  p_nombre_comercial text default null, p_rfc text default null,
  p_registro_patronal text default null, p_regimen_fiscal text default null,
  p_codigo_postal text default null, p_domicilio text default null,
  p_representante_legal text default null, p_activo boolean default true,
  p_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_t uuid := app.mi_tenant();
  v_id uuid;
begin
  if not app.es_admin() then
    raise exception 'Solo administración puede administrar empresas.';
  end if;
  if not exists (select 1 from public.grupos_empresariales
                  where id = p_grupo_id and tenant_id = v_t) then
    raise exception 'Grupo no valido';
  end if;

  if p_id is null then
    insert into public.razones_sociales (
      tenant_id, grupo_id, clave, razon_social, nombre_comercial, rfc,
      registro_patronal, regimen_fiscal, codigo_postal, domicilio,
      representante_legal, activo)
    values (
      v_t, p_grupo_id, upper(trim(p_clave)), trim(p_razon_social),
      nullif(trim(coalesce(p_nombre_comercial,'')),''),
      nullif(upper(trim(coalesce(p_rfc,''))),''),
      nullif(trim(coalesce(p_registro_patronal,'')),''),
      nullif(trim(coalesce(p_regimen_fiscal,'')),''),
      nullif(trim(coalesce(p_codigo_postal,'')),''),
      nullif(trim(coalesce(p_domicilio,'')),''),
      nullif(trim(coalesce(p_representante_legal,'')),''),
      coalesce(p_activo,true))
    returning id into v_id;
  else
    update public.razones_sociales
       set grupo_id = p_grupo_id,
           razon_social = trim(p_razon_social),
           nombre_comercial = nullif(trim(coalesce(p_nombre_comercial,'')),''),
           rfc = nullif(upper(trim(coalesce(p_rfc,''))),''),
           registro_patronal = nullif(trim(coalesce(p_registro_patronal,'')),''),
           regimen_fiscal = nullif(trim(coalesce(p_regimen_fiscal,'')),''),
           codigo_postal = nullif(trim(coalesce(p_codigo_postal,'')),''),
           domicilio = nullif(trim(coalesce(p_domicilio,'')),''),
           representante_legal = nullif(trim(coalesce(p_representante_legal,'')),''),
           activo = coalesce(p_activo,true)
     where id = p_id and tenant_id = v_t
    returning id into v_id;
    if v_id is null then raise exception 'Empresa no encontrada'; end if;
  end if;

  perform app.auditar('razon_social','razones_sociales', v_id::text, null,
    jsonb_build_object('clave', p_clave, 'razon_social', p_razon_social,
                       'rfc', p_rfc));
  return jsonb_build_object('status','success','id',v_id);
end;
$$;

create or replace function public.prima_guardar(
  p_razon_id uuid, p_prima numeric, p_vigente_de date,
  p_clase text default null, p_fraccion text default null,
  p_nota text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if not app.es_admin() then
    raise exception 'Solo administración puede registrar la prima de riesgo.';
  end if;
  if not exists (select 1 from public.razones_sociales
                  where id = p_razon_id and tenant_id = app.mi_tenant()) then
    raise exception 'Empresa no encontrada';
  end if;
  -- La prima se captura como fraccion: 0.005 y no 0.5%.
  if p_prima > 0.15 then
    raise exception 'La prima se captura como fracción (0.005 = 0.5%%). Máximo 0.15.';
  end if;

  -- Cierra la vigencia anterior en lugar de sobreescribirla.
  update public.primas_riesgo
     set vigente_a = p_vigente_de - 1
   where razon_id = p_razon_id
     and vigente_de < p_vigente_de
     and (vigente_a is null or vigente_a >= p_vigente_de);

  insert into public.primas_riesgo
    (tenant_id, razon_id, clase, fraccion, prima, vigente_de, nota)
  values (app.mi_tenant(), p_razon_id, p_clase, p_fraccion, p_prima,
          p_vigente_de, p_nota)
  on conflict (razon_id, vigente_de) do update
     set prima = excluded.prima, clase = excluded.clase,
         fraccion = excluded.fraccion, nota = excluded.nota
  returning id into v_id;

  perform app.auditar('prima_riesgo','primas_riesgo', v_id::text, null,
    jsonb_build_object('razon', p_razon_id, 'prima', p_prima,
                       'vigente_de', p_vigente_de));
  return jsonb_build_object('status','success','id',v_id);
end;
$$;

-- ══ 10. EL TABLERO DE NÓMINA MUESTRA LA EMPRESA ══════════════════════════

create or replace function public.nomina_periodos(p_anio integer default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_t uuid := app.mi_tenant();
  v_anio integer := coalesce(p_anio, extract(year from current_date)::integer);
begin
  if v_t is null then raise exception 'Sin sesion valida'; end if;

  return jsonb_build_object(
    'anio', v_anio,
    'es_admin', app.es_admin(),
    'anios', (
      select coalesce(jsonb_agg(distinct anio order by anio desc), '[]'::jsonb)
        from public.periodos_nomina where tenant_id = v_t),
    'empresas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', r.id, 'clave', r.clave, 'razon_social', r.razon_social,
               'rfc', r.rfc, 'grupo', g.nombre) order by r.clave), '[]'::jsonb)
        from public.razones_sociales r
        join public.grupos_empresariales g on g.id = r.grupo_id
       where r.tenant_id = v_t and r.activo),
    'grupos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', g.id, 'clave', g.clave, 'nombre', g.nombre,
               'frecuencia', g.frecuencia, 'dias_para_pago', g.dias_para_pago,
               'activo', g.activo,
               'razon_id', g.razon_id,
               'empresa', r.clave,
               'empleados', (
                 select count(*) from public.sueldos s
                  where s.grupo_id = g.id
                    and (s.hasta is null or s.hasta >= current_date))
             ) order by r.clave, g.clave), '[]'::jsonb)
        from public.grupos_nomina g
        left join public.razones_sociales r on r.id = g.razon_id
       where g.tenant_id = v_t),
    'periodos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'numero', p.numero, 'anio', p.anio,
               'desde', p.desde, 'hasta', p.hasta, 'dias', p.dias,
               'fecha_pago', p.fecha_pago, 'estado', p.estado,
               'grupo', g.nombre, 'grupo_clave', g.clave,
               'empresa', r.clave, 'razon_social', r.razon_social,
               'frecuencia', p.frecuencia,
               'empleados', t.n, 'neto', t.neto,
               'percepciones', t.perc, 'deducciones', t.ded,
               'con_avisos', t.avisos
             ) order by p.desde desc), '[]'::jsonb)
        from public.periodos_nomina p
        join public.grupos_nomina g on g.id = p.grupo_id
        left join public.razones_sociales r on r.id = p.razon_id
        cross join lateral (
          select count(*) as n,
                 coalesce(sum(x.neto_estimado),0) as neto,
                 coalesce(sum(x.total_percepciones),0) as perc,
                 coalesce(sum(x.total_deducciones),0) as ded,
                 count(*) filter (where jsonb_array_length(x.avisos) > 0) as avisos
            from public.prenomina x where x.periodo_id = p.id
        ) t
       where p.tenant_id = v_t and p.anio = v_anio)
  );
end;
$$;

-- ══ 11. EL CÁLCULO RESPETA LA RAZÓN SOCIAL ═══════════════════════════════

/* Solo se calculan los empleados de la razón social del periodo. Sin esto, un
   periodo de la empresa A pagaria gente de la empresa B y el CFDI saldria con
   el RFC equivocado. */
create or replace function public.calcular_prenomina_periodo(p_periodo_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  per public.periodos_nomina;
  r record;
  res jsonb;
  v_ok integer := 0;
  v_err integer := 0;
  v_detalle jsonb := '[]'::jsonb;
begin
  if not app.es_admin() then
    raise exception 'Solo RH o administracion puede calcular la prenomina.';
  end if;

  select * into per from public.periodos_nomina
   where id = p_periodo_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Periodo no encontrado'; end if;
  if per.estado = 'cerrado' then
    raise exception 'El periodo esta cerrado. Reabrelo para recalcular.';
  end if;

  for r in
    select e.id, e.nombre_completo
      from public.empleados e
     where e.tenant_id = per.tenant_id
       and e.razon_id = per.razon_id
       and (e.fecha_baja is null or e.fecha_baja >= per.desde)
       and e.fecha_ingreso <= per.hasta
       and (per.centro_id is null or e.centro_id = per.centro_id)
       and exists (
         select 1 from public.sueldos s
          where s.empleado_id = e.id
            and s.desde <= per.hasta
            and (s.hasta is null or s.hasta >= per.desde)
            and coalesce(s.grupo_id, per.grupo_id) = per.grupo_id)
     order by e.nombre_completo
  loop
    begin
      res := public.calcular_prenomina_empleado(p_periodo_id, r.id);
      if res->>'status' = 'success' then
        v_ok := v_ok + 1;
      else
        v_err := v_err + 1;
        v_detalle := v_detalle || jsonb_build_array(jsonb_build_object(
          'empleado', r.nombre_completo, 'message', res->>'message'));
      end if;
    exception when others then
      -- Un empleado con datos rotos no debe tumbar la nomina de los demas.
      v_err := v_err + 1;
      v_detalle := v_detalle || jsonb_build_array(jsonb_build_object(
        'empleado', r.nombre_completo, 'message', SQLERRM));
    end;
  end loop;

  perform app.auditar('prenomina_calculada','periodos_nomina',
    p_periodo_id::text, null,
    jsonb_build_object('calculados',v_ok,'errores',v_err));

  return jsonb_build_object('status','success',
    'calculados', v_ok, 'errores', v_err, 'detalle', v_detalle);
end;
$$;

/* El detalle también filtra los pendientes por razón social. */
create or replace function public.nomina_detalle(p_periodo_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  per public.periodos_nomina;
  g public.grupos_nomina;
  rs public.razones_sociales;
begin
  select * into per from public.periodos_nomina
   where id = p_periodo_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Periodo no encontrado'; end if;

  select * into g from public.grupos_nomina where id = per.grupo_id;
  select * into rs from public.razones_sociales where id = per.razon_id;

  return jsonb_build_object(
    'es_admin', app.es_admin(),
    'reglas', jsonb_build_object(
      'retardos_para_falta', app.cfg_razon_int('retardos_para_falta', per.razon_id),
      'descuenta_tiempo_retardo', app.cfg_razon_bool('descuenta_tiempo_retardo', per.razon_id)),
    'periodo', jsonb_build_object(
      'id', per.id, 'numero', per.numero, 'anio', per.anio,
      'desde', per.desde, 'hasta', per.hasta, 'dias', per.dias,
      'fecha_pago', per.fecha_pago, 'estado', per.estado,
      'frecuencia', per.frecuencia, 'nota', per.nota,
      'grupo', g.nombre, 'grupo_clave', g.clave, 'grupo_id', g.id,
      'empresa', rs.clave, 'razon_social', rs.razon_social, 'rfc', rs.rfc,
      'cerrado_en', per.cerrado_en),
    'conceptos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', c.id, 'clave', c.clave, 'nombre', c.nombre,
               'naturaleza', c.naturaleza) order by c.naturaleza, c.orden),
             '[]'::jsonb)
        from public.conceptos_nomina c
       where c.tenant_id = per.tenant_id and c.activo),
    'filas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', x.id, 'empleado_id', e.id,
               'nombre', e.nombre_completo, 'no_empleado', e.no_empleado,
               'puesto', e.puesto,
               'sueldo_diario', x.sueldo_diario, 'sdi', x.sdi,
               'dias_trabajados', x.dias_trabajados,
               'dias_descanso', x.dias_descanso,
               'dias_vacaciones', x.dias_vacaciones,
               'dias_incapacidad', x.dias_incapacidad,
               'dias_permiso_cg', x.dias_permiso_cg,
               'dias_permiso_sg', x.dias_permiso_sg,
               'faltas', x.faltas, 'septimo_perdido', x.septimo_perdido,
               'retardos', x.retardos,
               'minutos_retardo', x.minutos_retardo,
               'faltas_por_retardo', x.faltas_por_retardo,
               'horas_dobles', x.horas_dobles, 'horas_triples', x.horas_triples,
               'horas_excedidas', x.horas_excedidas,
               'dias_festivo_lab', x.dias_festivo_lab,
               'dias_descanso_lab', x.dias_descanso_lab,
               'domingos_lab', x.domingos_lab,
               'importe_sueldo', x.importe_sueldo,
               'importe_septimo', x.importe_septimo,
               'importe_extras', x.importe_extras,
               'importe_festivos', x.importe_festivos,
               'importe_descanso_lab', x.importe_descanso_lab,
               'importe_prima_dom', x.importe_prima_dom,
               'importe_vacaciones', x.importe_vacaciones,
               'importe_prima_vac', x.importe_prima_vac,
               'importe_retardos', x.importe_retardos,
               'otras_percepciones', x.otras_percepciones,
               'otras_deducciones', x.otras_deducciones,
               'total_percepciones', x.total_percepciones,
               'total_deducciones', x.total_deducciones,
               'neto', x.neto_estimado, 'avisos', x.avisos,
               'calculado_en', x.calculado_en
             ) order by e.nombre_completo), '[]'::jsonb)
        from public.prenomina x
        join public.empleados e on e.id = x.empleado_id
       where x.periodo_id = per.id),
    'movimientos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', m.id, 'empleado_id', m.empleado_id,
               'concepto_id', m.concepto_id, 'clave', c.clave,
               'concepto', c.nombre, 'naturaleza', c.naturaleza,
               'cantidad', m.cantidad, 'importe', m.importe, 'nota', m.nota)
             order by c.naturaleza, c.orden), '[]'::jsonb)
        from public.movimientos_nomina m
        join public.conceptos_nomina c on c.id = m.concepto_id
       where m.periodo_id = per.id),
    'pendientes', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', e.id, 'nombre', e.nombre_completo,
               'no_empleado', e.no_empleado,
               'motivo', case when s.id is null then 'Sin sueldo registrado'
                              else 'Sin calcular' end)
             order by e.nombre_completo), '[]'::jsonb)
        from public.empleados e
        left join public.sueldos s on s.empleado_id = e.id
             and s.desde <= per.hasta
             and (s.hasta is null or s.hasta >= per.desde)
             and coalesce(s.grupo_id, per.grupo_id) = per.grupo_id
       where e.tenant_id = per.tenant_id
         and e.razon_id = per.razon_id
         and (e.fecha_baja is null or e.fecha_baja >= per.desde)
         and e.fecha_ingreso <= per.hasta
         and (per.centro_id is null or e.centro_id = per.centro_id)
         and (s.id is null or not exists (
               select 1 from public.prenomina x
                where x.periodo_id = per.id and x.empleado_id = e.id))
         and not exists (
               select 1 from public.sueldos s2
                where s2.empleado_id = e.id
                  and s2.desde <= per.hasta
                  and (s2.hasta is null or s2.hasta >= per.desde)
                  and s2.grupo_id is not null
                  and s2.grupo_id <> per.grupo_id))
  );
end;
$$;

-- El grupo de pago se crea dentro de una razón social.
create or replace function public.nomina_grupo_guardar(
  p_clave text, p_nombre text, p_frecuencia text,
  p_dias_para_pago integer default 5, p_activo boolean default true,
  p_centro_id uuid default null, p_id uuid default null,
  p_razon_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_t uuid := app.mi_tenant();
  v_razon uuid;
  v_id uuid;
begin
  if not app.es_admin() then
    raise exception 'Solo RH o administracion puede administrar grupos.';
  end if;

  -- Con una sola empresa no se pregunta: se asume la única que hay.
  v_razon := coalesce(p_razon_id,
    (select r.id from public.razones_sociales r
      where r.tenant_id = v_t and r.activo order by r.clave limit 1));

  if not exists (select 1 from public.razones_sociales
                  where id = v_razon and tenant_id = v_t) then
    raise exception 'Empresa no valida';
  end if;

  if p_id is null then
    insert into public.grupos_nomina (
      tenant_id, razon_id, clave, nombre, frecuencia, centro_id,
      dias_para_pago, activo)
    values (v_t, v_razon, upper(trim(p_clave)), trim(p_nombre),
            p_frecuencia::frecuencia_nomina, p_centro_id,
            coalesce(p_dias_para_pago,5), coalesce(p_activo,true))
    returning id into v_id;
  else
    -- La frecuencia y la empresa NO se editan: cambiarlas dejaria periodos ya
    -- calculados apuntando a un RFC o a una periodicidad que no corresponde.
    update public.grupos_nomina
       set nombre = trim(p_nombre), dias_para_pago = coalesce(p_dias_para_pago,5),
           activo = coalesce(p_activo,true), centro_id = p_centro_id
     where id = p_id and tenant_id = v_t
    returning id into v_id;
    if v_id is null then raise exception 'Grupo no encontrado'; end if;
  end if;

  perform app.auditar('grupo_nomina','grupos_nomina', v_id::text, null,
    jsonb_build_object('clave', p_clave, 'nombre', p_nombre, 'razon', v_razon));
  return jsonb_build_object('status','success','id',v_id);
end;
$$;

-- ══ 12. PERMISOS ═════════════════════════════════════════════════════════

do $$
declare f text;
begin
  for f in
    select format('%s(%s)', p.proname, pg_get_function_identity_arguments(p.oid))
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('estructura_empresarial','grupo_emp_guardar',
                         'razon_guardar','prima_guardar','nomina_periodos',
                         'nomina_detalle','nomina_grupo_guardar',
                         'calcular_prenomina_periodo')
  loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;