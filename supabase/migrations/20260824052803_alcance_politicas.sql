-- ════════════════════════════════════════════════════════════════════════
-- RHoo! · Alcance por usuario · tabla, helpers y políticas
--
-- Estado final extraído de la base. Complementa a la migración de RPCs:
-- aquí va la capa de RLS, que es la que protege aunque alguien fabrique la
-- petición a mano.
--
-- Ya aplicado en la base. Este archivo existe para que un restore no lo
-- pierda: NO hace falta correr db push.
-- ════════════════════════════════════════════════════════════════════════

-- ══ 1. LA TABLA ═════════════════════════════════════════════════════════

create table if not exists public.perfiles_alcance (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenants(id) on delete cascade,
  perfil_id  uuid not null references public.perfiles(id) on delete cascade,
  -- Uno de los dos, no ambos. Por grupo incluye sus empresas futuras.
  grupo_id   uuid references public.grupos_empresariales(id) on delete cascade,
  razon_id   uuid references public.razones_sociales(id) on delete cascade,
  creado_por uuid references public.perfiles(id),
  creado_en  timestamptz not null default now(),

  constraint alcance_uno_solo check (
    (grupo_id is not null and razon_id is null) or
    (grupo_id is null and razon_id is not null))
);

create unique index if not exists alcance_grupo_idx
  on public.perfiles_alcance (perfil_id, grupo_id) where grupo_id is not null;
create unique index if not exists alcance_razon_idx
  on public.perfiles_alcance (perfil_id, razon_id) where razon_id is not null;
create index if not exists alcance_perfil_idx
  on public.perfiles_alcance (perfil_id);

alter table public.perfiles_alcance enable row level security;

-- Cada quien lee su propio alcance (la UI lo necesita); solo administración
-- lo modifica.
drop policy if exists alcance_leer on public.perfiles_alcance;
create policy alcance_leer on public.perfiles_alcance
  for select using (
    tenant_id = app.mi_tenant()
    and (perfil_id = auth.uid() or app.es_admin()));

drop policy if exists alcance_escribir on public.perfiles_alcance;
create policy alcance_escribir on public.perfiles_alcance
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

drop policy if exists zz_prov_alcance on public.perfiles_alcance;
create policy zz_prov_alcance on public.perfiles_alcance
  for all using (app.es_proveedor()) with check (app.es_proveedor());

grant select, insert, update, delete on public.perfiles_alcance to authenticated;
grant all on public.perfiles_alcance to service_role;

-- ══ 2. LOS HELPERS ══════════════════════════════════════════════════════

/* ¿Este usuario tiene el alcance limitado?
   Sin filas en perfiles_alcance ve todo el tenant. Es a proposito: si el
   default fuera "no ve nada", cada alta de usuario seria un tramite y alguien
   acabaria dandole acceso total para salir del paso. */
create or replace function app.alcance_limitado()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.perfiles_alcance where perfil_id = auth.uid())
$$;

/* Razones sociales que este usuario alcanza. El alcance por grupo se expande
   a sus empresas, incluidas las que se creen despues. */
create or replace function app.mis_razones()
returns setof uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select r.id
    from public.razones_sociales r
   where r.tenant_id = app.mi_tenant()
     and (
       not app.alcance_limitado()
       or r.id in (select a.razon_id from public.perfiles_alcance a
                    where a.perfil_id = auth.uid() and a.razon_id is not null)
       or r.grupo_id in (select a.grupo_id from public.perfiles_alcance a
                          where a.perfil_id = auth.uid() and a.grupo_id is not null))
$$;

/* Atajo para politicas y RPCs: ¿alcanzo esta razon social? */
create or replace function app.alcanza_razon(p_razon uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select not app.alcance_limitado()
      or p_razon is null
      or p_razon in (select app.mis_razones())
$$;

grant execute on function app.alcance_limitado() to authenticated;
grant execute on function app.mis_razones() to authenticated;
grant execute on function app.alcanza_razon(uuid) to authenticated;

-- ══ 3. POLÍTICAS · EMPLEADOS ════════════════════════════════════════════
-- El filtro se agrega a la rama de admin/RH. Las ramas de "mi propio
-- expediente" y "mi equipo" NO se tocan: quien consulta lo suyo debe poder
-- verlo aunque su perfil no tenga alcance de RH.

drop policy if exists empleados_leer on public.empleados;
create policy empleados_leer on public.empleados
  for select using (
    tenant_id = app.mi_tenant()
    and (
      (app.es_admin() and app.alcanza_razon(razon_id))
      or id = (select empleado_id from public.perfiles where id = auth.uid())
      or jefe_id = (select empleado_id from public.perfiles where id = auth.uid())
    ));

drop policy if exists empleados_escribir on public.empleados;
create policy empleados_escribir on public.empleados
  for all using (
    tenant_id = app.mi_tenant() and app.es_admin() and app.alcanza_razon(razon_id))
  with check (
    tenant_id = app.mi_tenant() and app.es_admin() and app.alcanza_razon(razon_id));

-- ══ 4. POLÍTICAS · CENTROS ══════════════════════════════════════════════

drop policy if exists centros_leer on public.centros_trabajo;
create policy centros_leer on public.centros_trabajo
  for select using (
    tenant_id = app.mi_tenant() and app.alcanza_razon(razon_id));

drop policy if exists centros_escribir on public.centros_trabajo;
create policy centros_escribir on public.centros_trabajo
  for all using (
    tenant_id = app.mi_tenant() and app.es_admin() and app.alcanza_razon(razon_id))
  with check (
    tenant_id = app.mi_tenant() and app.es_admin() and app.alcanza_razon(razon_id));

-- ══ 5. POLÍTICAS · SUELDOS ══════════════════════════════════════════════
-- Los sueldos no tienen razon_id: se filtra por la del empleado.

drop policy if exists sueldos_leer on public.sueldos;
create policy sueldos_leer on public.sueldos
  for select using (
    tenant_id = app.mi_tenant()
    and (
      (app.es_admin() and app.alcanza_razon(
        (select e.razon_id from public.empleados e where e.id = empleado_id)))
      or empleado_id = (select empleado_id from public.perfiles where id = auth.uid())
    ));

drop policy if exists sueldos_escribir on public.sueldos;
create policy sueldos_escribir on public.sueldos
  for all using (
    tenant_id = app.mi_tenant() and app.es_admin()
    and app.alcanza_razon(
      (select e.razon_id from public.empleados e where e.id = empleado_id)))
  with check (
    tenant_id = app.mi_tenant() and app.es_admin()
    and app.alcanza_razon(
      (select e.razon_id from public.empleados e where e.id = empleado_id)));

-- ══ 6. POLÍTICAS · NÓMINA ═══════════════════════════════════════════════

drop policy if exists periodos_leer on public.periodos_nomina;
create policy periodos_leer on public.periodos_nomina
  for select using (
    tenant_id = app.mi_tenant() and app.es_admin() and app.alcanza_razon(razon_id));

drop policy if exists periodos_escribir on public.periodos_nomina;
create policy periodos_escribir on public.periodos_nomina
  for all using (
    tenant_id = app.mi_tenant() and app.es_admin() and app.alcanza_razon(razon_id))
  with check (
    tenant_id = app.mi_tenant() and app.es_admin() and app.alcanza_razon(razon_id));

drop policy if exists prenom_leer on public.prenomina;
create policy prenom_leer on public.prenomina
  for select using (
    tenant_id = app.mi_tenant()
    and (
      (app.es_admin() and app.alcanza_razon(
        (select p.razon_id from public.periodos_nomina p where p.id = periodo_id)))
      or empleado_id = (select empleado_id from public.perfiles where id = auth.uid())
    ));

drop policy if exists prenom_escribir on public.prenomina;
create policy prenom_escribir on public.prenomina
  for all using (
    tenant_id = app.mi_tenant() and app.es_admin()
    and app.alcanza_razon(
      (select p.razon_id from public.periodos_nomina p where p.id = periodo_id)))
  with check (
    tenant_id = app.mi_tenant() and app.es_admin()
    and app.alcanza_razon(
      (select p.razon_id from public.periodos_nomina p where p.id = periodo_id)));

drop policy if exists grupos_leer on public.grupos_nomina;
create policy grupos_leer on public.grupos_nomina
  for select using (
    tenant_id = app.mi_tenant() and app.alcanza_razon(razon_id));

drop policy if exists grupos_escribir on public.grupos_nomina;
create policy grupos_escribir on public.grupos_nomina
  for all using (
    tenant_id = app.mi_tenant() and app.es_admin() and app.alcanza_razon(razon_id))
  with check (
    tenant_id = app.mi_tenant() and app.es_admin() and app.alcanza_razon(razon_id));

-- ══ 7. POLÍTICAS · ASISTENCIA E INCIDENCIAS ═════════════════════════════

drop policy if exists jornadas_leer on public.jornadas;
create policy jornadas_leer on public.jornadas
  for select using (
    tenant_id = app.mi_tenant()
    and (
      (app.es_admin() and app.alcanza_razon(
        (select e.razon_id from public.empleados e where e.id = empleado_id)))
      or empleado_id = (select empleado_id from public.perfiles where id = auth.uid())
      or empleado_id in (
        select e.id from public.empleados e
         where e.jefe_id = (select empleado_id from public.perfiles where id = auth.uid()))
    ));

drop policy if exists jornadas_escribir on public.jornadas;
create policy jornadas_escribir on public.jornadas
  for all using (
    tenant_id = app.mi_tenant() and app.es_admin()
    and app.alcanza_razon(
      (select e.razon_id from public.empleados e where e.id = empleado_id)))
  with check (
    tenant_id = app.mi_tenant() and app.es_admin()
    and app.alcanza_razon(
      (select e.razon_id from public.empleados e where e.id = empleado_id)));

drop policy if exists inc_leer on public.incidencias;
create policy inc_leer on public.incidencias
  for select using (
    tenant_id = app.mi_tenant()
    and (
      (app.es_admin() and app.alcanza_razon(
        (select e.razon_id from public.empleados e where e.id = empleado_id)))
      or empleado_id = (select empleado_id from public.perfiles where id = auth.uid())
      or empleado_id in (
        select e.id from public.empleados e
         where e.jefe_id = (select empleado_id from public.perfiles where id = auth.uid()))
    ));

drop policy if exists inc_rh on public.incidencias;
create policy inc_rh on public.incidencias
  for all using (
    tenant_id = app.mi_tenant() and app.es_admin()
    and app.alcanza_razon(
      (select e.razon_id from public.empleados e where e.id = empleado_id)))
  with check (
    tenant_id = app.mi_tenant() and app.es_admin()
    and app.alcanza_razon(
      (select e.razon_id from public.empleados e where e.id = empleado_id)));

-- ══ 8. POLÍTICAS · STORAGE ══════════════════════════════════════════════
-- La ruta es tenant/empleado/archivo. Sin validar el segundo nivel, un RH
-- limitado descarga la INE de otra empresa con solo conocer la ruta: el RPC
-- ya filtraba, pero el archivo se pedia directo al storage.

drop policy if exists expedientes_leer on storage.objects;
create policy expedientes_leer on storage.objects
  for select using (
    bucket_id = 'expedientes'
    and (
      app.es_proveedor()
      or (
        (storage.foldername(name))[1] = (app.mi_tenant())::text
        and app.alcanza_razon((
          select e.razon_id from public.empleados e
           where e.id::text = (storage.foldername(name))[2]))
      )
    ));

drop policy if exists expedientes_borrar on storage.objects;
create policy expedientes_borrar on storage.objects
  for delete using (
    bucket_id = 'expedientes'
    and (storage.foldername(name))[1] = (app.mi_tenant())::text
    and app.es_admin()
    and app.alcanza_razon((
      select e.razon_id from public.empleados e
       where e.id::text = (storage.foldername(name))[2])));

drop policy if exists expedientes_subir on storage.objects;
create policy expedientes_subir on storage.objects
  for insert with check (
    bucket_id = 'expedientes'
    and (storage.foldername(name))[1] = (app.mi_tenant())::text
    and app.es_admin()
    and app.alcanza_razon((
      select e.razon_id from public.empleados e
       where e.id::text = (storage.foldername(name))[2])));

-- ══ 9. RPCs DE ADMINISTRACIÓN DEL ALCANCE ═══════════════════════════════

create or replace function public.alcance_usuario(p_perfil_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_t uuid := app.mi_tenant();
  p public.perfiles;
begin
  if not app.es_admin() then
    raise exception 'Solo administracion puede consultar el alcance.';
  end if;

  select * into p from public.perfiles where id = p_perfil_id and tenant_id = v_t;
  if not found then raise exception 'Usuario no encontrado'; end if;

  return jsonb_build_object(
    'perfil', jsonb_build_object(
      'id', p.id, 'nombre', p.nombre, 'email', p.email,
      'rol', p.rol, 'activo', p.activo),
    'asignado', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', a.id,
               'tipo', case when a.grupo_id is not null then 'grupo' else 'empresa' end,
               'ref_id', coalesce(a.grupo_id, a.razon_id),
               'clave', coalesce(g.clave, r.clave),
               'nombre', coalesce(g.nombre, r.razon_social)
             ) order by a.creado_en), '[]'::jsonb)
        from public.perfiles_alcance a
        left join public.grupos_empresariales g on g.id = a.grupo_id
        left join public.razones_sociales r on r.id = a.razon_id
       where a.perfil_id = p_perfil_id),
    'grupos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', g.id, 'clave', g.clave, 'nombre', g.nombre,
               'empresas', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'id', r.id, 'clave', r.clave,
                          'razon_social', r.razon_social) order by r.clave),
                        '[]'::jsonb)
                   from public.razones_sociales r where r.grupo_id = g.id)
             ) order by g.clave), '[]'::jsonb)
        from public.grupos_empresariales g where g.tenant_id = v_t)
  );
end;
$$;

/* Reemplaza el alcance completo de un usuario. Se manda la lista entera en
   lugar de agregar de a uno: asi la pantalla no tiene que llevar la cuenta de
   lo que quito y lo que agrego. */
create or replace function public.alcance_guardar(
  p_perfil_id uuid, p_grupos uuid[] default null, p_razones uuid[] default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_t uuid := app.mi_tenant();
  v_n integer := 0;
begin
  if not app.es_admin() then
    raise exception 'Solo administracion puede asignar el alcance.';
  end if;
  if not exists (select 1 from public.perfiles
                  where id = p_perfil_id and tenant_id = v_t) then
    raise exception 'Usuario no encontrado';
  end if;

  -- Nadie amplia su propio alcance. Es el mismo control interno que impide
  -- aprobar tus propias incidencias: quien se autoriza a si mismo no deja
  -- rastro utilizable en una auditoria.
  if p_perfil_id = auth.uid() then
    raise exception 'No puedes modificar tu propio alcance. Pidelo a otro administrador.';
  end if;

  -- El proveedor no se limita: su acceso va por otra via y restringirlo aqui
  -- lo dejaria sin poder dar soporte.
  if exists (select 1 from public.perfiles
              where id = p_perfil_id and rol = 'superadmin') then
    raise exception 'El superadmin no se limita por alcance.';
  end if;

  if p_grupos is not null and exists (
    select 1 from unnest(p_grupos) x
     where x not in (select id from public.grupos_empresariales where tenant_id = v_t))
  then
    raise exception 'Uno de los grupos no pertenece a este cliente.';
  end if;

  if p_razones is not null and exists (
    select 1 from unnest(p_razones) x
     where x not in (select id from public.razones_sociales where tenant_id = v_t))
  then
    raise exception 'Una de las empresas no pertenece a este cliente.';
  end if;

  delete from public.perfiles_alcance where perfil_id = p_perfil_id;

  if p_grupos is not null then
    insert into public.perfiles_alcance (tenant_id, perfil_id, grupo_id, creado_por)
    select v_t, p_perfil_id, x, auth.uid() from unnest(p_grupos) x
    on conflict do nothing;
  end if;

  if p_razones is not null then
    insert into public.perfiles_alcance (tenant_id, perfil_id, razon_id, creado_por)
    select v_t, p_perfil_id, x, auth.uid() from unnest(p_razones) x
    on conflict do nothing;
  end if;

  select count(*) into v_n from public.perfiles_alcance where perfil_id = p_perfil_id;

  perform app.auditar('alcance_asignado','perfiles', p_perfil_id::text, null,
    jsonb_build_object('grupos', p_grupos, 'razones', p_razones, 'total', v_n));

  return jsonb_build_object('status','success','asignaciones', v_n,
    'sin_limite', v_n = 0);
end;
$$;

create or replace function public.alcance_resumen()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.es_admin() then
    raise exception 'Solo administracion puede consultar el alcance.';
  end if;

  return jsonb_build_object(
    'filas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'perfil_id', p.id, 'nombre', p.nombre, 'rol', p.rol,
               'total', (select count(*) from public.perfiles_alcance a
                          where a.perfil_id = p.id),
               'etiquetas', (
                 select coalesce(jsonb_agg(coalesce(g.clave, r.clave)
                          order by coalesce(g.clave, r.clave)), '[]'::jsonb)
                   from public.perfiles_alcance a
                   left join public.grupos_empresariales g on g.id = a.grupo_id
                   left join public.razones_sociales r on r.id = a.razon_id
                  where a.perfil_id = p.id)
             ) order by p.nombre), '[]'::jsonb)
        from public.perfiles p
       where p.tenant_id = app.mi_tenant() and p.activo)
  );
end;
$$;

/* Reasignar un centro de empresa, con sus empleados, en una transaccion. */
create or replace function public.centro_mover_empresa(
  p_centro_id uuid, p_razon_id uuid, p_motivo text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_t uuid := app.mi_tenant();
  c public.centros_trabajo;
  v_n integer;
  v_periodos integer;
begin
  if not app.es_admin() then
    raise exception 'Solo administracion puede mover centros entre empresas.';
  end if;

  select * into c from public.centros_trabajo
   where id = p_centro_id and tenant_id = v_t;
  if not found then raise exception 'Centro no encontrado'; end if;

  if not exists (select 1 from public.razones_sociales
                  where id = p_razon_id and tenant_id = v_t and activo) then
    raise exception 'Empresa destino no valida';
  end if;

  if c.razon_id = p_razon_id then
    return jsonb_build_object('status','success','sin_cambios',true);
  end if;

  -- Un periodo abierto de la empresa origen quedaria calculando gente que ya
  -- no le pertenece. Se detiene antes, no despues del timbrado.
  select count(*) into v_periodos
    from public.periodos_nomina p
   where p.razon_id = c.razon_id and p.estado <> 'cerrado';

  if v_periodos > 0 then
    raise exception 'La empresa de origen tiene % periodo(s) de nomina sin cerrar. Cierralos antes de mover el centro.', v_periodos;
  end if;

  update public.centros_trabajo set razon_id = p_razon_id where id = p_centro_id;

  -- El trigger de coherencia toma la razon del centro cuando se pone en null.
  update public.empleados set razon_id = null where centro_id = p_centro_id;

  select count(*) into v_n from public.empleados where centro_id = p_centro_id;

  perform app.auditar('centro_movido','centros_trabajo', p_centro_id::text,
    jsonb_build_object('razon_id', c.razon_id),
    jsonb_build_object('razon_id', p_razon_id, 'empleados', v_n,
                       'motivo', p_motivo));

  return jsonb_build_object('status','success','empleados', v_n);
end;
$$;

do $$
declare f text;
begin
  for f in
    select format('%s(%s)', p.proname, pg_get_function_identity_arguments(p.oid))
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('alcance_usuario','alcance_guardar','alcance_resumen',
                         'centro_mover_empresa')
  loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
