-- ═══════════════════════════════════════════════════════════
--  RHoo! · Organigrama
-- ═══════════════════════════════════════════════════════════

/* Impide ciclos en la jerarquia.
   Sin esto, A→B→C→A cuelga cualquier consulta recursiva hasta
   que Postgres corta por profundidad. La validacion existente
   solo cubria el ciclo de un paso (ser tu propio jefe). */
create or replace function app.validar_jerarquia()
returns trigger
language plpgsql
as $$
declare
  v_actual uuid;
  v_pasos  integer := 0;
begin
  if new.jefe_id is null then return new; end if;

  if new.jefe_id = new.id then
    raise exception 'Un empleado no puede ser su propio jefe';
  end if;

  -- Se sube por la cadena de mando buscando volver al punto de
  -- partida. El tope de 50 es una red de seguridad: si una
  -- jerarquia ya corrupta existiera, esto no se cuelga.
  v_actual := new.jefe_id;
  while v_actual is not null and v_pasos < 50 loop
    if v_actual = new.id then
      raise exception 'Ese cambio crearia un ciclo en la jerarquia: la persona que quieres asignar como jefe ya depende de este empleado';
    end if;
    select jefe_id into v_actual from public.empleados where id = v_actual;
    v_pasos := v_pasos + 1;
  end loop;

  return new;
end;
$$;

create trigger empleados_validar_jerarquia
  before insert or update of jefe_id on public.empleados
  for each row execute function app.validar_jerarquia();

/* Árbol completo con nivel y ruta.
   La ruta sirve para ordenar: sin ella, un árbol plano no se
   puede pintar con la sangría correcta. */
create or replace function public.organigrama(p_centro_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_arbol jsonb;
  v_huerf jsonb;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  with recursive arbol as (
    -- Raíces: quienes no reportan a nadie dentro del alcance
    select e.id, e.nombre_completo, e.no_empleado, e.puesto,
           e.departamento, e.jefe_id, e.centro_id,
           0 as nivel,
           e.nombre_completo::text as ruta
    from public.empleados e
    where e.tenant_id = app.mi_tenant()
      and e.estatus = 'Activo'
      and e.jefe_id is null
      and (p_centro_id is null or e.centro_id = p_centro_id)
      -- Solo son raíz si alguien les reporta; los demás son
      -- huérfanos y van en su propia lista.
      and exists (select 1 from public.empleados h
                  where h.jefe_id = e.id and h.estatus = 'Activo')

    union all

    select e.id, e.nombre_completo, e.no_empleado, e.puesto,
           e.departamento, e.jefe_id, e.centro_id,
           a.nivel + 1,
           a.ruta || ' > ' || e.nombre_completo
    from public.empleados e
    join arbol a on a.id = e.jefe_id
    where e.tenant_id = app.mi_tenant()
      and e.estatus = 'Activo'
      and a.nivel < 20        -- red de seguridad
  )
  select jsonb_agg(jsonb_build_object(
    'id', id, 'nombre', nombre_completo, 'no', no_empleado,
    'puesto', puesto, 'departamento', departamento,
    'jefe_id', jefe_id, 'nivel', nivel,
    'equipo', (select count(*) from public.empleados d
               where d.jefe_id = arbol.id and d.estatus = 'Activo')
  ) order by ruta) into v_arbol
  from arbol;

  -- Sin jefe y sin equipo: los que faltan por ubicar. Se
  -- muestran aparte porque son el pendiente real, no un error.
  select jsonb_agg(jsonb_build_object(
    'id', e.id, 'nombre', e.nombre_completo, 'no', e.no_empleado,
    'puesto', e.puesto, 'departamento', e.departamento
  ) order by e.nombre_completo) into v_huerf
  from public.empleados e
  where e.tenant_id = app.mi_tenant()
    and e.estatus = 'Activo'
    and e.jefe_id is null
    and (p_centro_id is null or e.centro_id = p_centro_id)
    and not exists (select 1 from public.empleados h
                    where h.jefe_id = e.id and h.estatus = 'Activo');

  return jsonb_build_object(
    'status','success',
    'arbol', coalesce(v_arbol, '[]'::jsonb),
    'sin_jefe', coalesce(v_huerf, '[]'::jsonb)
  );
end;
$$;

/* Asigna o quita jefe. Devuelve el tamaño del equipo que se
   mueve con la persona: un cambio de jefatura sin ver el impacto
   es como se rompe una jerarquía sin querer. */
create or replace function public.asignar_jefe(
  p_empleado_id uuid,
  p_jefe_id     uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_antes uuid;
  v_eq    integer;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  select jefe_id into v_antes from public.empleados
   where id = p_empleado_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Empleado no encontrado'; end if;

  if p_jefe_id is not null
     and not exists (select 1 from public.empleados
                     where id = p_jefe_id and tenant_id = app.mi_tenant()
                       and estatus = 'Activo') then
    raise exception 'El jefe indicado no existe o no esta activo';
  end if;

  -- El trigger valida el ciclo
  update public.empleados set jefe_id = p_jefe_id where id = p_empleado_id;

  select count(*) into v_eq from public.empleados
   where jefe_id = p_empleado_id and estatus = 'Activo';

  perform app.auditar('empleado.jefe', 'empleados', p_empleado_id::text,
    jsonb_build_object('jefe_id', v_antes),
    jsonb_build_object('jefe_id', p_jefe_id, 'equipo_afectado', v_eq));

  return jsonb_build_object('status','success','equipo', v_eq);
end;
$$;

/* Mi equipo: para que el rol jefe tenga a quien ver.
   Incluye el estado de hoy y el saldo de vacaciones, que es lo
   que un jefe necesita al autorizar. */
create or replace function public.mi_equipo()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_yo    uuid;
  v_filas jsonb;
begin
  select empleado_id into v_yo from public.perfiles where id = auth.uid();
  if v_yo is null then
    return jsonb_build_object('status','success','filas','[]'::jsonb);
  end if;

  select jsonb_agg(jsonb_build_object(
    'id', e.id, 'nombre', e.nombre_completo, 'no', e.no_empleado,
    'puesto', e.puesto,
    'saldo', public.saldo_vacaciones(e.id),
    'hoy', coalesce(
      (select estatus::text from public.jornadas j
       where j.empleado_id = e.id and j.fecha_laboral = current_date),
      case when public.turno_del_dia(e.id, current_date) is null
           then 'descanso' else 'pendiente' end),
    'pendientes', (select count(*) from public.incidencias i
                   where i.empleado_id = e.id
                     and i.estatus in ('pendiente','aprobada_jefe'))
  ) order by e.nombre_completo) into v_filas
  from public.empleados e
  where e.jefe_id = v_yo and e.estatus = 'Activo';

  return jsonb_build_object('status','success',
    'filas', coalesce(v_filas,'[]'::jsonb));
end;
$$;

grant execute on function public.organigrama(uuid)          to authenticated;
grant execute on function public.asignar_jefe(uuid,uuid)    to authenticated;
grant execute on function public.mi_equipo()                to authenticated;