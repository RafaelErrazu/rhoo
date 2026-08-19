-- ═══════════════════════════════════════════════════════════
--  RHoo! · Módulo proveedor
-- ═══════════════════════════════════════════════════════════

alter table public.tenants
  add column if not exists suspendido boolean not null default false,
  add column if not exists suspendido_motivo text,
  add column if not exists limite_empleados integer,
  add column if not exists contacto_nombre text,
  add column if not exists contacto_email text,
  add column if not exists contacto_tel text,
  add column if not exists notas text;

-- Límites por plan. En tabla y no en código para poder cambiar
-- la oferta comercial sin desplegar.
create table if not exists public.planes (
  clave            text primary key,
  nombre           text not null,
  limite_empleados integer,          -- null = sin límite
  limite_centros   integer,
  precio_mensual   numeric(10,2),
  features         jsonb not null default '{}'::jsonb,
  orden            integer not null default 100
);

insert into public.planes (clave, nombre, limite_empleados, limite_centros, precio_mensual, features, orden)
values
  ('trial','Prueba', 25, 1, 0,
   '{"nom035":true,"asistencia":true,"documentos":true,"prenomina":false}'::jsonb, 10),
  ('basico','Básico', 100, 3, 0,
   '{"nom035":true,"asistencia":true,"documentos":true,"prenomina":false}'::jsonb, 20),
  ('pro','Profesional', 500, 10, 0,
   '{"nom035":true,"asistencia":true,"documentos":true,"prenomina":true}'::jsonb, 30),
  ('enterprise','Empresarial', null, null, 0,
   '{"nom035":true,"asistencia":true,"documentos":true,"prenomina":true}'::jsonb, 40)
on conflict (clave) do nothing;

alter table public.planes enable row level security;
create policy planes_leer on public.planes for select using (true);
create policy planes_escribir on public.planes
  for all using (app.es_proveedor()) with check (app.es_proveedor());
grant select on public.planes to authenticated, anon;

/* El límite se aplica en la base.
   Un limite que solo vive en la interfaz se salta con la consola
   del navegador en diez segundos. */
create or replace function app.validar_limite_empleados()
returns trigger
language plpgsql
as $$
declare
  v_lim integer;
  v_n   integer;
begin
  if new.estatus <> 'Activo' then return new; end if;

  select coalesce(t.limite_empleados, p.limite_empleados)
    into v_lim
  from public.tenants t
  left join public.planes p on p.clave = t.plan
  where t.id = new.tenant_id;

  if v_lim is null then return new; end if;

  select count(*) into v_n from public.empleados
   where tenant_id = new.tenant_id and estatus = 'Activo'
     and (TG_OP = 'INSERT' or id <> new.id);

  if v_n >= v_lim then
    raise exception 'Tu plan permite hasta % empleados activos. Contacta a tu proveedor para ampliarlo.', v_lim;
  end if;

  return new;
end;
$$;

create trigger empleados_limite_plan
  before insert or update of estatus on public.empleados
  for each row execute function app.validar_limite_empleados();

/* Bloquea a un tenant suspendido en la puerta de entrada.
   Se hace sobre mi_tenant() porque es la funcion que alimenta
   todas las politicas: si devuelve null, RLS bloquea todo sin
   tener que tocar cada tabla. */
create or replace function app.mi_tenant()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p.tenant_id
  from public.perfiles p
  join public.tenants t on t.id = p.tenant_id
  where p.id = auth.uid()
    and p.activo
    and not t.suspendido
$$;

-- ─────────────────────────────────────────────────────────────
--  SIEMBRA DE CATÁLOGOS
--
--  Una funcion, no un script: se versiona con las migraciones,
--  es idempotente y se puede volver a correr sobre un tenant
--  existente. Cuando se agregue un catalogo nuevo, se aplica a
--  todos los clientes con una llamada.
-- ─────────────────────────────────────────────────────────────
create or replace function public.sembrar_catalogos(p_tenant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  mat  uuid; ves uuid; noc uuid;
  v_t  integer := 0; v_i integer := 0; v_d integer := 0; v_f integer := 0;
  v_anio integer := extract(year from current_date)::integer;
begin
  if not app.es_proveedor() then
    raise exception 'Solo el proveedor puede sembrar catalogos';
  end if;

  -- ── TURNOS ──
  insert into public.turnos
    (tenant_id, clave, nombre, hora_entrada, hora_salida, minutos_comida, color)
  values
    (p_tenant_id,'MAT','Matutino','09:00','18:00',60,'#2EC4B6'),
    (p_tenant_id,'VES','Vespertino','14:00','22:00',30,'#F4795B'),
    (p_tenant_id,'NOC','Nocturno','22:00','06:00',30,'#6366F1')
  on conflict (tenant_id, clave) do nothing;

  select count(*) into v_t from public.turnos where tenant_id = p_tenant_id;

  select id into mat from public.turnos where tenant_id=p_tenant_id and clave='MAT';
  select id into ves from public.turnos where tenant_id=p_tenant_id and clave='VES';
  select id into noc from public.turnos where tenant_id=p_tenant_id and clave='NOC';

  insert into public.patrones_rotacion (tenant_id, nombre, secuencia, unidad)
  values
    (p_tenant_id,'Rotativo 3 turnos (semanal)', array[mat,ves,noc],'semana'),
    (p_tenant_id,'4x3 Matutino', array[mat,mat,mat,mat,null,null,null]::uuid[],'dia'),
    (p_tenant_id,'2x2 Continuo', array[noc,noc,null,null]::uuid[],'dia')
  on conflict (tenant_id, nombre) do nothing;

  -- ── INCIDENCIAS ──
  insert into public.tipos_incidencia
    (tenant_id, clave, nombre, con_goce, descuenta_vac, requiere_doc, color)
  values
    (p_tenant_id,'VAC','Vacaciones',            true,  true,  false,'#2EC4B6'),
    (p_tenant_id,'INC','Incapacidad IMSS',      true,  false, true, '#6366F1'),
    (p_tenant_id,'PCG','Permiso con goce',      true,  false, false,'#14A085'),
    (p_tenant_id,'PSG','Permiso sin goce',      false, false, false,'#D97706'),
    (p_tenant_id,'FJ', 'Falta justificada',     false, false, true, '#8494A7'),
    (p_tenant_id,'FI', 'Falta injustificada',   false, false, false,'#DC2626'),
    (p_tenant_id,'MAT','Licencia de maternidad',true,  false, true, '#EC4899'),
    (p_tenant_id,'PAT','Licencia de paternidad',true,  false, true, '#0EA5E9'),
    (p_tenant_id,'DUE','Permiso por fallecimiento', true, false, false,'#64748B')
  on conflict (tenant_id, clave) do nothing;

  select count(*) into v_i from public.tipos_incidencia where tenant_id = p_tenant_id;

  -- ── DOCUMENTOS ──
  insert into public.tipos_documento
    (tenant_id, clave, nombre, obligatorio, vence, campos_ocr, orden)
  values
    (p_tenant_id,'INE','Identificación oficial (INE)', true, true,
     array['curp','nombres','apellido_paterno','apellido_materno',
           'fecha_nacimiento','sexo'], 10),
    (p_tenant_id,'CURP','Constancia de CURP', true, false,
     array['curp','nombres','apellido_paterno','apellido_materno',
           'fecha_nacimiento','sexo'], 20),
    (p_tenant_id,'RFC','Constancia de situación fiscal', true, true,
     array['rfc','curp'], 30),
    (p_tenant_id,'NSS','Número de seguridad social', true, false,
     array['nss','curp'], 40),
    (p_tenant_id,'DOM','Comprobante de domicilio', false, true,
     array[]::text[], 50),
    (p_tenant_id,'ACTA','Acta de nacimiento', false, false,
     array['fecha_nacimiento','nombres','apellido_paterno','apellido_materno'], 60),
    (p_tenant_id,'ESTUDIOS','Comprobante de estudios', false, false,
     array['escolaridad'], 70),
    (p_tenant_id,'CONTRATO','Contrato de trabajo', true, true,
     array[]::text[], 80),
    (p_tenant_id,'BANCO','Cuenta bancaria', false, false,
     array[]::text[], 90),
    (p_tenant_id,'POLITICA','Política de prevención de riesgos psicosociales',
     false, false, array[]::text[], 95),
    (p_tenant_id,'OTRO','Otro documento', false, false,
     array[]::text[], 999)
  on conflict (tenant_id, clave) do nothing;

  select count(*) into v_d from public.tipos_documento where tenant_id = p_tenant_id;

  -- ── FESTIVOS · artículo 74 LFT ──
  -- Se siembran el año en curso y el siguiente: un cliente que
  -- entra en noviembre necesita los de enero.
  insert into public.dias_no_laborables (tenant_id, fecha, descripcion, oficial)
  select p_tenant_id, f.fecha, f.desc, true
  from (
    select make_date(a, 1, 1) as fecha, 'Año Nuevo' as desc from generate_series(v_anio, v_anio+1) a
    union all
    -- Primer lunes de febrero
    select (make_date(a,2,1) + ((8 - extract(dow from make_date(a,2,1))::integer) % 7))::date,
           'Día de la Constitución' from generate_series(v_anio, v_anio+1) a
    union all
    -- Tercer lunes de marzo
    select (make_date(a,3,1) + ((8 - extract(dow from make_date(a,3,1))::integer) % 7) + 14)::date,
           'Natalicio de Benito Juárez' from generate_series(v_anio, v_anio+1) a
    union all
    select make_date(a,5,1), 'Día del Trabajo' from generate_series(v_anio, v_anio+1) a
    union all
    select make_date(a,9,16),'Independencia de México' from generate_series(v_anio, v_anio+1) a
    union all
    -- Tercer lunes de noviembre
    select (make_date(a,11,1) + ((8 - extract(dow from make_date(a,11,1))::integer) % 7) + 14)::date,
           'Revolución Mexicana' from generate_series(v_anio, v_anio+1) a
    union all
    select make_date(a,12,25),'Navidad' from generate_series(v_anio, v_anio+1) a
  ) f
  on conflict (tenant_id, centro_id, fecha) do nothing;

  select count(*) into v_f from public.dias_no_laborables where tenant_id = p_tenant_id;

  perform app.auditar('proveedor.sembrar', 'tenants', p_tenant_id::text, null,
    jsonb_build_object('turnos', v_t, 'incidencias', v_i,
                       'documentos', v_d, 'festivos', v_f));

  return jsonb_build_object('status','success',
    'turnos', v_t, 'incidencias', v_i, 'documentos', v_d, 'festivos', v_f);
end;
$$;

/* Alta completa de cliente. */
create or replace function public.crear_tenant(p_datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id     uuid;
  v_slug   text;
  v_semilla jsonb;
  c        jsonb;
begin
  if not app.es_proveedor() then
    raise exception 'Solo el proveedor puede dar de alta clientes';
  end if;

  -- Slug limpio: va en URLs y en rutas de Storage, asi que nada
  -- de acentos, espacios ni mayusculas.
  v_slug := lower(regexp_replace(
              public.sin_acentos(coalesce(p_datos->>'slug', p_datos->>'nombre')),
              '[^a-z0-9]+', '-', 'g'));
  v_slug := trim(both '-' from v_slug);

  if v_slug = '' then raise exception 'El nombre no genera un identificador valido'; end if;
  if exists (select 1 from public.tenants where slug = v_slug) then
    raise exception 'Ya existe un cliente con el identificador "%"', v_slug;
  end if;

  insert into public.tenants
    (slug, nombre, rfc, plan, limite_empleados,
     contacto_nombre, contacto_email, contacto_tel, notas)
  values (
    v_slug,
    trim(p_datos->>'nombre'),
    upper(nullif(p_datos->>'rfc','')),
    coalesce(nullif(p_datos->>'plan',''), 'trial'),
    nullif(p_datos->>'limite_empleados','')::integer,
    nullif(p_datos->>'contacto_nombre',''),
    lower(nullif(p_datos->>'contacto_email','')),
    nullif(p_datos->>'contacto_tel',''),
    nullif(p_datos->>'notas','')
  ) returning id into v_id;

  -- Centros de trabajo iniciales
  if p_datos ? 'centros' then
    for c in select * from jsonb_array_elements(p_datos->'centros') loop
      insert into public.centros_trabajo (tenant_id, clave, nombre, razon_social, direccion)
      values (v_id,
        upper(regexp_replace(public.sin_acentos(c->>'clave'), '[^a-z0-9]', '', 'g')),
        c->>'nombre', nullif(c->>'razon_social',''), nullif(c->>'direccion',''))
      on conflict (tenant_id, clave) do nothing;
    end loop;
  end if;

  v_semilla := public.sembrar_catalogos(v_id);

  perform app.auditar('proveedor.crear_tenant', 'tenants', v_id::text, null, p_datos);

  return jsonb_build_object(
    'status','success', 'id', v_id, 'slug', v_slug,
    'semilla', v_semilla,
    -- auth.users no se escribe desde SQL: se devuelven las
    -- instrucciones para no dejar al cliente sin poder entrar.
    'siguiente_paso', 'Crea el usuario administrador en Authentication → Users '
      || '(con Auto Confirm activado) y luego asígnalo con asignar_admin().'
  );
end;
$$;

/* Liga un usuario de auth ya creado como admin de un tenant. */
create or replace function public.asignar_admin(
  p_email     text,
  p_tenant_id uuid,
  p_nombre    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_uid uuid;
begin
  if not app.es_proveedor() then raise exception 'Sin permiso'; end if;

  select id into v_uid from auth.users where lower(email) = lower(trim(p_email));
  if v_uid is null then
    raise exception 'No existe un usuario con el correo %. Crealo primero en Authentication → Users.', p_email;
  end if;

  insert into public.perfiles (id, tenant_id, rol, nombre, email)
  values (v_uid, p_tenant_id, 'admin',
          coalesce(nullif(trim(p_nombre),''), split_part(p_email,'@',1)),
          lower(trim(p_email)))
  on conflict (id) do update set
    tenant_id = excluded.tenant_id,
    rol = excluded.rol,
    nombre = excluded.nombre;

  perform app.auditar('proveedor.asignar_admin', 'perfiles', v_uid::text, null,
    jsonb_build_object('email', p_email, 'tenant', p_tenant_id));

  return jsonb_build_object('status','success','usuario_id', v_uid);
end;
$$;

/* Panel del proveedor: uso, no contenido.
   Poder entrar a los datos de un cliente es una cosa; hacerlo
   por defecto en tu tablero es otra. */
create or replace function public.tenants_lista()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', t.id, 'slug', t.slug, 'nombre', t.nombre,
    'plan', t.plan, 'plan_nombre', pl.nombre,
    'suspendido', t.suspendido, 'motivo', t.suspendido_motivo,
    'creado', t.creado_en,
    'contacto', t.contacto_nombre, 'email', t.contacto_email,
    'es_proveedor', coalesce((t.config->>'es_proveedor')::boolean, false),
    'limite', coalesce(t.limite_empleados, pl.limite_empleados),
    'empleados', (select count(*) from public.empleados e
                  where e.tenant_id = t.id and e.estatus = 'Activo'),
    'centros', (select count(*) from public.centros_trabajo c
                where c.tenant_id = t.id and c.activo),
    'usuarios', (select count(*) from public.perfiles p
                 where p.tenant_id = t.id and p.activo),
    'campanas', (select count(*) from public.nom035_campanas ca
                 where ca.tenant_id = t.id),
    'respuestas', (select count(*) from public.nom035_respuestas r
                   where r.tenant_id = t.id),
    'documentos', (select count(*) from public.documentos d
                   where d.tenant_id = t.id),
    -- Ultima actividad: distingue un cliente que usa el sistema
    -- de uno que se dio de alta y nunca volvio.
    'ultima_actividad', greatest(
      (select max(creado_en) from public.checadas where tenant_id = t.id),
      (select max(creado_en) from public.empleados where tenant_id = t.id),
      (select max(creado_en) from public.auditoria where tenant_id = t.id))
  ) order by t.creado_en desc), '[]'::jsonb)
  from public.tenants t
  left join public.planes pl on pl.clave = t.plan
  where app.es_proveedor()
$$;

create or replace function public.tenant_suspender(
  p_id     uuid,
  p_susp   boolean,
  p_motivo text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.es_proveedor() then raise exception 'Sin permiso'; end if;

  -- Nunca al tenant proveedor: te quedarias fuera de tu propio
  -- sistema sin forma de volver a entrar.
  if exists (select 1 from public.tenants
             where id = p_id and (config->>'es_proveedor')::boolean) then
    raise exception 'No se puede suspender el tenant del proveedor';
  end if;

  update public.tenants
     set suspendido = p_susp,
         suspendido_motivo = case when p_susp then p_motivo else null end
   where id = p_id;

  perform app.auditar(
    case when p_susp then 'proveedor.suspender' else 'proveedor.reactivar' end,
    'tenants', p_id::text, null, jsonb_build_object('motivo', p_motivo));

  return jsonb_build_object('status','success');
end;
$$;

create or replace function public.tenant_actualizar(p_id uuid, p_datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.es_proveedor() then raise exception 'Sin permiso'; end if;

  update public.tenants set
    nombre           = coalesce(nullif(p_datos->>'nombre',''), nombre),
    rfc              = case when p_datos ? 'rfc' then upper(nullif(p_datos->>'rfc','')) else rfc end,
    plan             = coalesce(nullif(p_datos->>'plan',''), plan),
    limite_empleados = case when p_datos ? 'limite_empleados'
                       then nullif(p_datos->>'limite_empleados','')::integer
                       else limite_empleados end,
    contacto_nombre  = case when p_datos ? 'contacto_nombre'
                       then nullif(p_datos->>'contacto_nombre','') else contacto_nombre end,
    contacto_email   = case when p_datos ? 'contacto_email'
                       then lower(nullif(p_datos->>'contacto_email','')) else contacto_email end,
    contacto_tel     = case when p_datos ? 'contacto_tel'
                       then nullif(p_datos->>'contacto_tel','') else contacto_tel end,
    notas            = case when p_datos ? 'notas'
                       then nullif(p_datos->>'notas','') else notas end
  where id = p_id;

  perform app.auditar('proveedor.actualizar', 'tenants', p_id::text, null, p_datos);
  return jsonb_build_object('status','success');
end;
$$;

/* Resumen para el tablero del proveedor. */
create or replace function public.proveedor_resumen()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'clientes', (select count(*) from public.tenants
                 where not coalesce((config->>'es_proveedor')::boolean,false)),
    'activos', (select count(*) from public.tenants
                where not suspendido
                  and not coalesce((config->>'es_proveedor')::boolean,false)),
    'empleados', (select count(*) from public.empleados where estatus = 'Activo'),
    'respuestas_nom035', (select count(*) from public.nom035_respuestas),
    'documentos', (select count(*) from public.documentos),
    -- Clientes que se dieron de alta y nunca volvieron: el
    -- indicador que anticipa una cancelacion.
    'inactivos_30d', (
      select count(*) from public.tenants t
      where not t.suspendido
        and not coalesce((t.config->>'es_proveedor')::boolean,false)
        and coalesce((select max(creado_en) from public.auditoria a
                      where a.tenant_id = t.id), t.creado_en) < now() - interval '30 days')
  )
  where app.es_proveedor()
$$;

grant execute on function public.sembrar_catalogos(uuid)              to authenticated;
grant execute on function public.crear_tenant(jsonb)                  to authenticated;
grant execute on function public.asignar_admin(text,uuid,text)        to authenticated;
grant execute on function public.tenants_lista()                      to authenticated;
grant execute on function public.tenant_suspender(uuid,boolean,text)  to authenticated;
grant execute on function public.tenant_actualizar(uuid,jsonb)        to authenticated;
grant execute on function public.proveedor_resumen()                  to authenticated;
