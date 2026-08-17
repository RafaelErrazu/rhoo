-- ═══════════════════════════════════════════════════════════
--  RHoo! · Endpoints del módulo Turnos
-- ═══════════════════════════════════════════════════════════

/* Catálogo completo: turnos, patrones y cuánta gente usa cada
   uno. El conteo evita el error de borrar un turno que 40
   personas están usando. */
create or replace function public.catalogo_turnos()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.es_admin() then
    raise exception 'Sin permiso';
  end if;

  return jsonb_build_object(
    'status','success',
    'turnos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id, 'clave', t.clave, 'nombre', t.nombre,
        'entrada', t.hora_entrada, 'salida', t.hora_salida,
        'comida', t.minutos_comida, 'comida_computa', t.comida_computa,
        'tolerancia', t.tolerancia_entrada, 'min_falta', t.min_para_falta,
        'color', t.color, 'activo', t.activo,
        'horas', public.turno_horas(t.*),
        'cruza', public.turno_cruza_medianoche(t.*),
        'asignados', (select count(*) from public.asignaciones_turno a
                      where a.turno_id = t.id
                        and (a.hasta is null or a.hasta >= current_date))
      ) order by t.clave)
      from public.turnos t where t.tenant_id = app.mi_tenant()
    ), '[]'::jsonb),
    'patrones', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'nombre', p.nombre, 'unidad', p.unidad,
        'largo', array_length(p.secuencia,1), 'activo', p.activo,
        'secuencia', p.secuencia,
        -- Se resuelven las claves aquí: el front no debería tener
        -- que cruzar dos arreglos para pintar el ciclo.
        'claves', (select jsonb_agg(coalesce(
                     (select clave from public.turnos where id = s.tid), 'D')
                     order by s.orden)
                   from unnest(p.secuencia) with ordinality as s(tid, orden)),
        'asignados', (select count(*) from public.asignaciones_turno a
                      where a.patron_id = p.id
                        and (a.hasta is null or a.hasta >= current_date))
      ) order by p.nombre)
      from public.patrones_rotacion p where p.tenant_id = app.mi_tenant()
    ), '[]'::jsonb)
  );
end;
$$;

/* Guarda o crea un turno. */
create or replace function public.guardar_turno(
  p_id     uuid,
  p_datos  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id    uuid;
  v_sale  time := (p_datos->>'salida')::time;
  v_entra time := (p_datos->>'entrada')::time;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  if v_entra = v_sale then
    raise exception 'La entrada y la salida no pueden ser la misma hora';
  end if;

  if p_id is null then
    insert into public.turnos
      (tenant_id, clave, nombre, hora_entrada, hora_salida,
       minutos_comida, comida_computa, tolerancia_entrada, min_para_falta, color)
    values (
      app.mi_tenant(),
      upper(trim(p_datos->>'clave')),
      trim(p_datos->>'nombre'),
      v_entra, v_sale,
      coalesce((p_datos->>'comida')::integer, 0),
      coalesce((p_datos->>'comida_computa')::boolean, false),
      coalesce((p_datos->>'tolerancia')::integer, 10),
      coalesce((p_datos->>'min_falta')::integer, 60),
      coalesce(nullif(p_datos->>'color',''), '#2EC4B6')
    ) returning id into v_id;

    perform app.auditar('turno.crear', 'turnos', v_id::text, null, p_datos);
  else
    update public.turnos set
      nombre             = trim(p_datos->>'nombre'),
      hora_entrada       = v_entra,
      hora_salida        = v_sale,
      minutos_comida     = coalesce((p_datos->>'comida')::integer, minutos_comida),
      comida_computa     = coalesce((p_datos->>'comida_computa')::boolean, comida_computa),
      tolerancia_entrada = coalesce((p_datos->>'tolerancia')::integer, tolerancia_entrada),
      min_para_falta     = coalesce((p_datos->>'min_falta')::integer, min_para_falta),
      color              = coalesce(nullif(p_datos->>'color',''), color),
      activo             = coalesce((p_datos->>'activo')::boolean, activo)
    where id = p_id and tenant_id = app.mi_tenant()
    returning id into v_id;

    if v_id is null then raise exception 'Turno no encontrado'; end if;

    -- El cambio de horario NO recalcula el pasado
    -- automáticamente: si alguien corrige la hora de entrada de
    -- un turno, las jornadas de meses anteriores no deben mover
    -- sus faltas sin que RH lo decida. Para eso está
    -- recalcular_jornadas(), que es explícita.
    perform app.auditar('turno.actualizar', 'turnos', v_id::text, null, p_datos);
  end if;

  return jsonb_build_object('status','success','id', v_id);
end;
$$;

/* Guarda un patrón de rotación.
   La secuencia llega como arreglo de claves ('MAT','D','NOC') y
   se traduce a UUID aquí: el front no maneja identificadores. */
create or replace function public.guardar_patron(
  p_id       uuid,
  p_nombre   text,
  p_claves   text[],
  p_unidad   text default 'dia'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sec    uuid[] := '{}';
  k        text;
  v_tid    uuid;
  v_id     uuid;
  v_seguidos integer := 0;
  v_max      integer := 0;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;
  if array_length(p_claves,1) is null then
    raise exception 'El patron necesita al menos un dia';
  end if;

  foreach k in array p_claves loop
    if k = 'D' or k is null or k = '' then
      v_sec := v_sec || null::uuid;
      v_seguidos := 0;
    else
      select id into v_tid from public.turnos
       where tenant_id = app.mi_tenant() and clave = upper(k);
      if v_tid is null then
        raise exception 'No existe el turno con clave %', k;
      end if;
      v_sec := v_sec || v_tid;
      v_seguidos := v_seguidos + 1;
      v_max := greatest(v_max, v_seguidos);
    end if;
  end loop;

  if p_id is null then
    insert into public.patrones_rotacion (tenant_id, nombre, secuencia, unidad)
    values (app.mi_tenant(), trim(p_nombre), v_sec, p_unidad)
    returning id into v_id;
  else
    update public.patrones_rotacion
       set nombre = trim(p_nombre), secuencia = v_sec, unidad = p_unidad
     where id = p_id and tenant_id = app.mi_tenant()
    returning id into v_id;
    if v_id is null then raise exception 'Patron no encontrado'; end if;
  end if;

  perform app.auditar('patron.guardar', 'patrones_rotacion', v_id::text, null,
    jsonb_build_object('nombre', p_nombre, 'claves', p_claves, 'unidad', p_unidad));

  return jsonb_build_object(
    'status','success', 'id', v_id,
    -- Se avisa, no se bloquea: un rol quincenal con descansos
    -- acumulados puede ser legítimo, y asumir que el cliente se
    -- equivoca sería peor que advertirle.
    'aviso_lft', case when v_max > 6 then
      'Este patron tiene ' || v_max || ' dias consecutivos de trabajo. '
      || 'El articulo 69 de la LFT obliga a un dia de descanso por cada seis '
      || 'trabajados. Verifica que el esquema lo compense.'
      else null end
  );
end;
$$;

/* Asigna turno o patrón a un empleado.
   Cierra la asignación anterior en lugar de reemplazarla: las
   jornadas pasadas deben seguir evaluándose con el turno que la
   persona tenía entonces. */
create or replace function public.asignar_turno(
  p_empleado_id uuid,
  p_turno_id    uuid default null,
  p_patron_id   uuid default null,
  p_desde       date default null,
  p_descanso    smallint[] default '{0}',
  p_ancla       date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_desde date := coalesce(p_desde, current_date);
  v_id    uuid;
  v_cerradas integer;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  if (p_turno_id is null) = (p_patron_id is null) then
    raise exception 'Indica un turno fijo o un patron de rotacion, no ambos';
  end if;

  if not exists (select 1 from public.empleados
                 where id = p_empleado_id and tenant_id = app.mi_tenant()) then
    raise exception 'Empleado no encontrado';
  end if;

  -- Cierra lo vigente el día antes de que arranque lo nuevo.
  -- La restricción de exclusión de la migración 02 rechazaría el
  -- traslape, así que este paso no es opcional.
  update public.asignaciones_turno
     set hasta = v_desde - 1
   where empleado_id = p_empleado_id
     and (hasta is null or hasta >= v_desde)
     and desde < v_desde;
  v_cerradas := 0;

  -- Si ya existe una asignación que arranca en la misma fecha o
  -- después, se elimina: es una corrección, no un cambio
  -- histórico.
  delete from public.asignaciones_turno
   where empleado_id = p_empleado_id and desde >= v_desde;

  insert into public.asignaciones_turno
    (tenant_id, empleado_id, turno_id, patron_id, fecha_ancla, dias_descanso, desde)
  values
    (app.mi_tenant(), p_empleado_id, p_turno_id, p_patron_id,
     case when p_patron_id is not null then coalesce(p_ancla, v_desde) else null end,
     coalesce(p_descanso, '{0}'), v_desde)
  returning id into v_id;

  -- Recalcula desde el cambio hasta hoy: el turno nuevo cambia
  -- qué días eran laborables y cuáles descanso.
  if v_desde <= current_date then
    perform public.calcular_jornada(p_empleado_id, d::date)
    from generate_series(v_desde, current_date, '1 day') d;
  end if;

  perform app.auditar('turno.asignar', 'asignaciones_turno', v_id::text, null,
    jsonb_build_object('empleado', p_empleado_id, 'turno', p_turno_id,
                       'patron', p_patron_id, 'desde', v_desde));

  return jsonb_build_object('status','success','id', v_id);
end;
$$;

/* Calendario: qué turno le toca a cada quien en un rango.
   Se calcula al vuelo. Un calendario materializado son 100 mil
   renglones al año por cada 300 empleados, y queda obsoleto en
   cuanto alguien cambia de patrón. */
create or replace function public.calendario_turnos(
  p_desde     date,
  p_hasta     date,
  p_centro_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare v_filas jsonb;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;
  if p_hasta - p_desde > 45 then
    raise exception 'El rango maximo es de 45 dias';
  end if;

  select jsonb_agg(x order by x->>'nombre') into v_filas
  from (
    select jsonb_build_object(
      'id', e.id,
      'nombre', e.nombre_completo,
      'no', e.no_empleado,
      'dias', (
        select jsonb_agg(jsonb_build_object(
          'f', d::date,
          'c', coalesce((select clave from public.turnos
                         where id = public.turno_del_dia(e.id, d::date)), 'D'),
          'col', coalesce((select color from public.turnos
                           where id = public.turno_del_dia(e.id, d::date)), null),
          -- Los festivos se marcan aparte: un día de descanso
          -- obligatorio no es lo mismo que el descanso semanal.
          'fest', exists(select 1 from public.dias_no_laborables
                         where tenant_id = e.tenant_id and fecha = d::date
                           and (centro_id is null or centro_id = e.centro_id))
        ) order by d)
        from generate_series(p_desde, p_hasta, '1 day') d
      )
    ) as x
    from public.empleados e
    where e.tenant_id = app.mi_tenant()
      and e.estatus = 'Activo'
      and e.metodo_checada <> 'ninguno'
      and (p_centro_id is null or e.centro_id = p_centro_id)
    limit 100
  ) s;

  return jsonb_build_object(
    'status','success',
    'desde', p_desde, 'hasta', p_hasta,
    'filas', coalesce(v_filas, '[]'::jsonb)
  );
end;
$$;

/* Historial de asignaciones de un empleado, para el expediente. */
create or replace function public.historial_turnos(p_empleado_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'desde', a.desde, 'hasta', a.hasta,
    'turno', t.nombre, 'patron', p.nombre,
    'descanso', a.dias_descanso,
    'vigente', a.hasta is null or a.hasta >= current_date
  ) order by a.desde desc), '[]'::jsonb)
  from public.asignaciones_turno a
  left join public.turnos t on t.id = a.turno_id
  left join public.patrones_rotacion p on p.id = a.patron_id
  where a.empleado_id = p_empleado_id
    and a.tenant_id = app.mi_tenant()
$$;

grant execute on function public.catalogo_turnos()                              to authenticated;
grant execute on function public.guardar_turno(uuid,jsonb)                      to authenticated;
grant execute on function public.guardar_patron(uuid,text,text[],text)          to authenticated;
grant execute on function public.asignar_turno(uuid,uuid,uuid,date,smallint[],date) to authenticated;
grant execute on function public.calendario_turnos(date,date,uuid)              to authenticated;
grant execute on function public.historial_turnos(uuid)                         to authenticated;