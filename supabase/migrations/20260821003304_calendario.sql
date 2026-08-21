-- ═══════════════════════════════════════════════════════════
--  RHoo! · Calendario unificado
--
--  Sin tablas nuevas: todo lo que se muestra ya vive en su
--  modulo. Duplicarlo en una tabla de "eventos" haria que el
--  calendario mintiera en cuanto alguien cancele unas vacaciones.
-- ═══════════════════════════════════════════════════════════

create or replace function public.calendario(
  p_desde     date,
  p_hasta     date,
  p_centro_id uuid default null,
  p_solo_mias boolean default false
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_yo      uuid;
  v_tenant  uuid;
  v_admin   boolean := app.es_admin();
  v_eventos jsonb := '[]'::jsonb;
begin
  select empleado_id, tenant_id into v_yo, v_tenant
  from public.perfiles where id = auth.uid();

  if v_tenant is null then
    return jsonb_build_object('status','error','message','Sin perfil');
  end if;

  if p_hasta - p_desde > 120 then
    raise exception 'El rango maximo es de 120 dias';
  end if;

  -- ── AUSENCIAS APROBADAS ──
  -- El tipo solo se muestra a RH y al propio interesado: saber
  -- que alguien no viene es operativo, saber que esta
  -- incapacitado es informacion medica.
  select v_eventos || coalesce(jsonb_agg(jsonb_build_object(
    'clase','ausencia',
    'desde', i.fecha_inicio,
    'hasta', i.fecha_fin,
    'empleado_id', e.id,
    'nombre', e.nombre_completo,
    'titulo', case
                when v_admin or e.id = v_yo then t.nombre
                else 'Ausente'
              end,
    'color', case
               when v_admin or e.id = v_yo then t.color
               else '#8494A7'
             end,
    'propio', e.id = v_yo,
    'dias', i.dias
  )), '[]'::jsonb) into v_eventos
  from public.incidencias i
  join public.empleados e on e.id = i.empleado_id
  join public.tipos_incidencia t on t.id = i.tipo_id
  where i.tenant_id = v_tenant
    and i.estatus = 'aprobada'
    and daterange(i.fecha_inicio, i.fecha_fin, '[]') && daterange(p_desde, p_hasta, '[]')
    and e.estatus = 'Activo'
    and (p_centro_id is null or e.centro_id = p_centro_id)
    and (
      -- Visibilidad: RH todo, el jefe su equipo, cada quien lo suyo
      v_admin
      or e.id = v_yo
      or (not p_solo_mias and e.jefe_id = v_yo)
    );

  -- ── DÍAS FESTIVOS ──
  select v_eventos || coalesce(jsonb_agg(jsonb_build_object(
    'clase','festivo',
    'desde', n.fecha, 'hasta', n.fecha,
    'titulo', n.descripcion,
    'color', '#6366F1',
    'oficial', n.oficial
  )), '[]'::jsonb) into v_eventos
  from public.dias_no_laborables n
  where n.tenant_id = v_tenant
    and n.fecha between p_desde and p_hasta
    and (p_centro_id is null or n.centro_id is null or n.centro_id = p_centro_id);

  -- ── CUMPLEAÑOS ──
  -- Se compara mes y dia: la fecha del evento es de ESTE año, no
  -- la de nacimiento.
  select v_eventos || coalesce(jsonb_agg(jsonb_build_object(
    'clase','cumple',
    'desde', f.fecha, 'hasta', f.fecha,
    'empleado_id', f.id,
    'nombre', f.nombre_completo,
    'titulo', 'Cumpleaños de ' || f.nombre_completo,
    'color', '#DB2777',
    'propio', f.id = v_yo
  )), '[]'::jsonb) into v_eventos
  from (
    select e.id, e.nombre_completo,
           make_date(
             extract(year from d)::integer,
             extract(month from e.fecha_nacimiento)::integer,
             extract(day from e.fecha_nacimiento)::integer
           ) as fecha
    from public.empleados e
    cross join generate_series(p_desde, p_hasta, '1 day') d
    where e.tenant_id = v_tenant
      and e.estatus = 'Activo'
      and e.fecha_nacimiento is not null
      and (p_centro_id is null or e.centro_id = p_centro_id)
      and extract(month from e.fecha_nacimiento) = extract(month from d)
      and extract(day   from e.fecha_nacimiento) = extract(day   from d)
    group by e.id, e.nombre_completo, e.fecha_nacimiento, extract(year from d)
  ) f
  where f.fecha between p_desde and p_hasta;

  -- ── ANIVERSARIOS ──
  select v_eventos || coalesce(jsonb_agg(jsonb_build_object(
    'clase','aniversario',
    'desde', f.fecha, 'hasta', f.fecha,
    'empleado_id', f.id,
    'nombre', f.nombre_completo,
    'titulo', f.nombre_completo || ' · ' || f.anios || ' año'
              || (case when f.anios = 1 then '' else 's' end) || ' en la empresa',
    'color', '#0EA5E9',
    'anios', f.anios,
    -- Los multiplos de 5 se destacan: son los que la empresa
    -- reconoce y los que peor se ve que se pasen.
    'destacado', f.anios % 5 = 0,
    'propio', f.id = v_yo
  )), '[]'::jsonb) into v_eventos
  from (
    select e.id, e.nombre_completo,
           make_date(
             extract(year from d)::integer,
             extract(month from e.fecha_ingreso)::integer,
             extract(day from e.fecha_ingreso)::integer
           ) as fecha,
           (extract(year from d) - extract(year from e.fecha_ingreso))::integer as anios
    from public.empleados e
    cross join generate_series(p_desde, p_hasta, '1 day') d
    where e.tenant_id = v_tenant
      and e.estatus = 'Activo'
      and e.fecha_ingreso is not null
      and (p_centro_id is null or e.centro_id = p_centro_id)
      and extract(month from e.fecha_ingreso) = extract(month from d)
      and extract(day   from e.fecha_ingreso) = extract(day   from d)
    group by e.id, e.nombre_completo, e.fecha_ingreso, extract(year from d)
  ) f
  where f.fecha between p_desde and p_hasta and f.anios >= 1;

  -- ── CAMPAÑAS NOM-035 ── (solo para quien administra)
  if v_admin then
    select v_eventos || coalesce(jsonb_agg(jsonb_build_object(
      'clase','campana',
      'desde', c.abre,
      'hasta', coalesce(c.cierra, p_hasta),
      'titulo', c.nombre,
      'color', '#2EC4B6',
      'estado', c.estado
    )), '[]'::jsonb) into v_eventos
    from public.nom035_campanas c
    where c.tenant_id = v_tenant
      and daterange(c.abre, coalesce(c.cierra, 'infinity'::date), '[]')
          && daterange(p_desde, p_hasta, '[]')
      and (p_centro_id is null or c.centro_id = p_centro_id);

    -- ── FECHAS COMPROMISO DEL PROGRAMA DE INTERVENCIÓN ──
    select v_eventos || coalesce(jsonb_agg(jsonb_build_object(
      'clase','accion',
      'desde', a.fecha_meta, 'hasta', a.fecha_meta,
      'titulo', 'Acción NOM-035: ' || left(a.accion, 60),
      'color', case when a.estado = 'hecha' then '#14A085' else '#D97706' end,
      'estado', a.estado
    )), '[]'::jsonb) into v_eventos
    from public.nom035_acciones a
    where a.tenant_id = v_tenant
      and a.fecha_meta between p_desde and p_hasta
      and a.estado <> 'cancelada';
  end if;

  return jsonb_build_object(
    'status','success',
    'desde', p_desde, 'hasta', p_hasta,
    'admin', v_admin,
    'eventos', v_eventos);
end;
$$;

/* Resumen del día: quién no está hoy.
   Es lo que un jefe pregunta en la mañana, y tenerlo en el
   tablero de Inicio evita que abra el calendario para saberlo. */
create or replace function public.hoy_resumen()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_yo     uuid;
  v_tenant uuid;
  v_admin  boolean := app.es_admin();
begin
  select empleado_id, tenant_id into v_yo, v_tenant
  from public.perfiles where id = auth.uid();
  if v_tenant is null then return jsonb_build_object('status','error'); end if;

  return jsonb_build_object(
    'status','success',
    'fecha', current_date,
    'festivo', (
      select descripcion from public.dias_no_laborables
      where tenant_id = v_tenant and fecha = current_date limit 1),
    'ausentes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nombre', e.nombre_completo,
        'tipo', case when v_admin or e.id = v_yo then t.nombre else 'Ausente' end,
        'hasta', i.fecha_fin))
      from public.incidencias i
      join public.empleados e on e.id = i.empleado_id
      join public.tipos_incidencia t on t.id = i.tipo_id
      where i.tenant_id = v_tenant and i.estatus = 'aprobada'
        and current_date between i.fecha_inicio and i.fecha_fin
        and e.estatus = 'Activo'
        and (v_admin or e.jefe_id = v_yo or e.id = v_yo)
    ), '[]'::jsonb),
    'cumples', coalesce((
      select jsonb_agg(e.nombre_completo)
      from public.empleados e
      where e.tenant_id = v_tenant and e.estatus = 'Activo'
        and e.fecha_nacimiento is not null
        and extract(month from e.fecha_nacimiento) = extract(month from current_date)
        and extract(day   from e.fecha_nacimiento) = extract(day   from current_date)
    ), '[]'::jsonb),
    'aniversarios', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nombre', e.nombre_completo,
        'anios', extract(year from age(current_date, e.fecha_ingreso))::integer))
      from public.empleados e
      where e.tenant_id = v_tenant and e.estatus = 'Activo'
        and e.fecha_ingreso is not null and e.fecha_ingreso < current_date
        and extract(month from e.fecha_ingreso) = extract(month from current_date)
        and extract(day   from e.fecha_ingreso) = extract(day   from current_date)
    ), '[]'::jsonb),
    -- Pendientes de acción, para que el tablero no sea solo
    -- informativo
    'por_autorizar', (
      select count(*) from public.incidencias i
      join public.empleados e on e.id = i.empleado_id
      where i.tenant_id = v_tenant
        and i.estatus in ('pendiente','aprobada_jefe')
        and i.empleado_id is distinct from v_yo
        and (v_admin or e.jefe_id = v_yo))
  );
end;
$$;

grant execute on function public.calendario(date,date,uuid,boolean) to authenticated;
grant execute on function public.hoy_resumen()                       to authenticated;