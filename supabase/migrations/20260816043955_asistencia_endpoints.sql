-- ═══════════════════════════════════════════════════════════
--  RHoo! · Endpoints del módulo Asistencia
-- ═══════════════════════════════════════════════════════════

/* Estado de MI día: para la tarjeta de checar.
   Devuelve todo lo que la interfaz necesita en una sola llamada,
   incluidas las ubicaciones válidas: así el celular puede decir
   "estás a 2 km de tu centro" ANTES de que la persona oprima el
   botón y se lleve un rechazo. */
create or replace function public.mi_dia()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_emp   uuid;
  e       public.empleados;
  v_fecha date;
  j       public.jornadas;
  t       public.turnos;
begin
  select empleado_id into v_emp from public.perfiles where id = auth.uid();
  if v_emp is null then
    return jsonb_build_object('puede', false, 'motivo', 'sin_empleado');
  end if;

  select * into e from public.empleados where id = v_emp;
  v_fecha := app.fecha_laboral_de(v_emp, now(),
               app.cfg_txt('zona_horaria', e.tenant_id));

  select * into j from public.jornadas
   where empleado_id = v_emp and fecha_laboral = v_fecha;

  select * into t from public.turnos
   where id = public.turno_del_dia(v_emp, v_fecha);

  return jsonb_build_object(
    'puede',   e.metodo_checada in ('movil','ambos') and e.estatus = 'Activo',
    'motivo',  case
                 when e.estatus <> 'Activo'            then 'inactivo'
                 when e.metodo_checada = 'ninguno'     then 'no_aplica'
                 when e.metodo_checada = 'dispositivo' then 'solo_dispositivo'
                 else null end,
    'empleado', jsonb_build_object(
        'nombre', e.nombre_completo, 'no', e.no_empleado, 'puesto', e.puesto),
    'fecha_laboral', v_fecha,
    'turno', case when t.id is null then null else jsonb_build_object(
        'clave', t.clave, 'nombre', t.nombre,
        'entrada', t.hora_entrada, 'salida', t.hora_salida,
        'cruza', public.turno_cruza_medianoche(t.*)) end,
    'checadas', coalesce((
        select jsonb_agg(jsonb_build_object('momento', momento, 'origen', origen)
                         order by momento)
        from public.checadas
        where empleado_id = v_emp and fecha_laboral = v_fecha and not anulada
      ), '[]'::jsonb),
    'jornada', case when j.id is null then null else jsonb_build_object(
        'estatus', j.estatus, 'retardo', j.minutos_retardo,
        'trabajados', j.minutos_trabajados, 'extra', j.minutos_extra) end,
    'geocerca', app.cfg_bool('geocerca_activa', e.tenant_id),
    'selfie',   app.cfg_bool('requiere_selfie', e.tenant_id),
    'ubicaciones', coalesce((
        select jsonb_agg(jsonb_build_object(
          'nombre', nombre, 'lat', lat, 'lng', lng, 'radio', radio_m))
        from public.ubicaciones_validas(v_emp)
      ), '[]'::jsonb)
  );
end;
$$;

/* Tablero del día para RH y jefes.
   Incluye a TODOS los que debían trabajar, no solo a los que
   checaron: el valor del tablero está en los ausentes. Una lista
   de presentes no responde la pregunta que RH se hace en la
   mañana. */
create or replace function public.tablero_dia(p_fecha date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_fecha date := coalesce(p_fecha, current_date);
  v_yo    uuid;
  v_admin boolean := app.es_admin();
  v_filas jsonb;
begin
  select empleado_id into v_yo from public.perfiles where id = auth.uid();

  if not v_admin and v_yo is null then
    return jsonb_build_object('status','error','message','Sin permiso');
  end if;

  with gente as (
    select e.id, e.nombre_completo, e.no_empleado, e.puesto,
           e.metodo_checada, c.clave as centro
    from public.empleados e
    left join public.centros_trabajo c on c.id = e.centro_id
    where e.tenant_id = app.mi_tenant()
      and e.estatus = 'Activo'
      and e.metodo_checada <> 'ninguno'
      and (v_admin or e.jefe_id = v_yo or e.id = v_yo)
  ),
  base as (
    select g.*,
           public.turno_del_dia(g.id, v_fecha) as turno_id,
           j.estatus, j.entrada, j.salida,
           j.minutos_retardo, j.minutos_trabajados, j.minutos_extra
    from gente g
    left join public.jornadas j
      on j.empleado_id = g.id and j.fecha_laboral = v_fecha
  )
  select jsonb_agg(jsonb_build_object(
    'id', id, 'nombre', nombre_completo, 'no', no_empleado,
    'puesto', puesto, 'centro', centro,
    'turno', (select clave from public.turnos where id = turno_id),
    'estatus', coalesce(estatus::text,
                 case when turno_id is null then 'descanso' else 'pendiente' end),
    'entrada', entrada, 'salida', salida,
    'retardo', coalesce(minutos_retardo,0),
    'trabajados', minutos_trabajados,
    'extra', coalesce(minutos_extra,0)
  ) order by
    -- Lo que exige accion primero. Un tablero ordenado por
    -- nombre obliga a leerlo completo para encontrar el problema.
    case coalesce(estatus::text, 'pendiente')
      when 'falta' then 1 when 'incompleta' then 2
      when 'retardo' then 3 when 'pendiente' then 4
      when 'completa' then 5 else 6 end,
    nombre_completo
  ) into v_filas
  from base;

  return jsonb_build_object(
    'status','success',
    'fecha', v_fecha,
    'filas', coalesce(v_filas, '[]'::jsonb)
  );
end;
$$;

/* Registro manual de RH. Se marca origen 'manual' y se audita:
   una checada que RH puede crear sin rastro deja de ser
   evidencia de nada. */
create or replace function public.checada_manual(
  p_empleado_id uuid,
  p_momento     timestamptz,
  p_motivo      text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  e       public.empleados;
  v_fecha date;
  v_id    uuid;
begin
  if not app.es_admin() then
    raise exception 'Solo Recursos Humanos puede registrar asistencia manual';
  end if;
  if coalesce(trim(p_motivo),'') = '' then
    raise exception 'El motivo es obligatorio en un registro manual';
  end if;

  select * into e from public.empleados
   where id = p_empleado_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Empleado no encontrado'; end if;

  v_fecha := app.fecha_laboral_de(p_empleado_id, p_momento,
               app.cfg_txt('zona_horaria', e.tenant_id));

  insert into public.checadas
    (tenant_id, empleado_id, momento, fecha_laboral, origen, dispositivo)
  values
    (e.tenant_id, p_empleado_id, p_momento, v_fecha, 'manual', p_motivo)
  returning id into v_id;

  perform public.calcular_jornada(p_empleado_id, v_fecha);
  perform app.auditar('checada.manual', 'checadas', v_id::text, null,
    jsonb_build_object('empleado', p_empleado_id, 'momento', p_momento,
                       'motivo', p_motivo));

  return jsonb_build_object('status','success','fecha_laboral', v_fecha);
end;
$$;

/* Anula una checada. No se borra: la fila queda con quién y por
   qué. Borrarla destruiría la evidencia, que es justo lo que
   sirve en un conflicto laboral. */
create or replace function public.anular_checada(
  p_checada_id uuid,
  p_motivo     text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare c public.checadas;
begin
  if not app.es_admin() then
    raise exception 'Sin permiso';
  end if;
  if coalesce(trim(p_motivo),'') = '' then
    raise exception 'Indica el motivo de la anulacion';
  end if;

  select * into c from public.checadas
   where id = p_checada_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Checada no encontrada'; end if;

  update public.checadas
     set anulada = true, anulada_por = auth.uid(), anulada_motivo = p_motivo
   where id = p_checada_id;

  perform public.calcular_jornada(c.empleado_id, c.fecha_laboral);
  perform app.auditar('checada.anular', 'checadas', p_checada_id::text,
    jsonb_build_object('momento', c.momento), jsonb_build_object('motivo', p_motivo));

  return jsonb_build_object('status','success');
end;
$$;

/* Crea un dispositivo y devuelve su llave EN CLARO una sola vez.
   Solo se guarda el hash: si alguien lee la tabla, no obtiene
   llaves usables. */
create or replace function public.crear_dispositivo(
  p_centro_id uuid,
  p_nombre    text,
  p_marca     text default null,
  p_modelo    text default null,
  p_serie     text default null,
  p_modo      text default 'agente'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp, extensions
as $$
declare
  v_llave text;
  v_id    uuid;
begin
  if not app.es_admin() then
    raise exception 'Sin permiso';
  end if;

  -- Llave larga y aleatoria. Una llave corta en un aparato que
  -- vive colgado en una pared es una invitacion.
  v_llave := 'rhoo_' || encode(gen_random_bytes(24), 'hex');

  insert into public.dispositivos
    (tenant_id, centro_id, nombre, marca, modelo, numero_serie, modo,
     llave_hash, llave_pista)
  values
    (app.mi_tenant(), p_centro_id, p_nombre, p_marca, p_modelo, p_serie, p_modo,
     encode(digest(v_llave, 'sha256'), 'hex'), right(v_llave, 4))
  returning id into v_id;

  perform app.auditar('dispositivo.crear', 'dispositivos', v_id::text, null,
    jsonb_build_object('nombre', p_nombre, 'modo', p_modo));

  return jsonb_build_object('status','success','id', v_id, 'llave', v_llave);
end;
$$;

create extension if not exists pgcrypto with schema extensions;

grant execute on function public.mi_dia()                                 to authenticated;
grant execute on function public.tablero_dia(date)                        to authenticated;
grant execute on function public.checada_manual(uuid,timestamptz,text)    to authenticated;
grant execute on function public.anular_checada(uuid,text)                to authenticated;
grant execute on function public.crear_dispositivo(uuid,text,text,text,text,text) to authenticated;