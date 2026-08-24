-- ═══════════════════════════════════════════════════════════════════════
-- RHoo! · Alcance por usuario · estado final de los RPCs
--
-- Extraido de la base con pg_get_functiondef despues de aplicar el barrido de
-- alcance, para que el repo refleje exactamente lo que esta corriendo.
--
-- REGLA: toda funcion security definer que devuelva datos de empleados,
-- nomina o expedientes debe filtrar con app.alcanza_razon() de forma
-- explicita. Corre con los permisos del dueno, asi que RLS no la protege.
--
-- Ya aplicado en la base. Este archivo existe para que un restore no lo
-- pierda: NO hace falta correr db push.
-- ═══════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.actualizar_empleado(p_id uuid, p_datos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  antes    public.empleados;
  v_camb   jsonb := '{}'::jsonb;
  k        text;
  -- Lista blanca. Sin ella, un payload malicioso podria cambiar
  -- tenant_id y mover al empleado a otra empresa.
  permitidos text[] := array[
    'centro_id','apellido_paterno','apellido_materno','nombres',
    'sexo','fecha_nacimiento','estado_civil','escolaridad',
    'curp','rfc','nss','email','telefono',
    'puesto','departamento','tipo_puesto','tipo_contrato','tipo_personal',
    'fecha_ingreso','jefe_id','metodo_checada'
  ];
begin
  if not app.alcanza_razon((select razon_id from public.empleados where id = p_id)) then
    raise exception 'Ese empleado pertenece a una empresa fuera de tu alcance.';
  end if;

  if not app.es_admin() then
    raise exception 'Sin permiso';
  end if;

  select * into antes from public.empleados
   where id = p_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Empleado no encontrado'; end if;

  for k in select jsonb_object_keys(p_datos) loop
    if k = any(permitidos) then
      v_camb := v_camb || jsonb_build_object(k, p_datos->k);
    end if;
  end loop;

  if v_camb = '{}'::jsonb then
    return jsonb_build_object('status','success','sin_cambios',true);
  end if;

  -- Nadie puede ser su propio jefe: crearia un ciclo en la
  -- jerarquia y romperia las consultas de equipo.
  if v_camb ? 'jefe_id' and (v_camb->>'jefe_id')::uuid = p_id then
    raise exception 'Un empleado no puede ser su propio jefe';
  end if;

  update public.empleados set
    centro_id        = coalesce(nullif(v_camb->>'centro_id','')::uuid, centro_id),
    apellido_paterno = coalesce(upper(nullif(v_camb->>'apellido_paterno','')), apellido_paterno),
    apellido_materno = coalesce(upper(v_camb->>'apellido_materno'), apellido_materno),
    nombres          = coalesce(upper(nullif(v_camb->>'nombres','')), nombres),
    sexo             = case when v_camb ? 'sexo' then nullif(v_camb->>'sexo','') else sexo end,
    fecha_nacimiento = case when v_camb ? 'fecha_nacimiento' then nullif(v_camb->>'fecha_nacimiento','')::date else fecha_nacimiento end,
    estado_civil     = case when v_camb ? 'estado_civil' then nullif(v_camb->>'estado_civil','') else estado_civil end,
    escolaridad      = case when v_camb ? 'escolaridad' then nullif(v_camb->>'escolaridad','') else escolaridad end,
    curp             = case when v_camb ? 'curp' then upper(nullif(v_camb->>'curp','')) else curp end,
    rfc              = case when v_camb ? 'rfc' then upper(nullif(v_camb->>'rfc','')) else rfc end,
    nss              = case when v_camb ? 'nss' then nullif(v_camb->>'nss','') else nss end,
    email            = case when v_camb ? 'email' then lower(nullif(v_camb->>'email','')) else email end,
    telefono         = case when v_camb ? 'telefono' then nullif(v_camb->>'telefono','') else telefono end,
    puesto           = case when v_camb ? 'puesto' then nullif(v_camb->>'puesto','') else puesto end,
    departamento     = case when v_camb ? 'departamento' then nullif(v_camb->>'departamento','') else departamento end,
    tipo_puesto      = case when v_camb ? 'tipo_puesto' then nullif(v_camb->>'tipo_puesto','') else tipo_puesto end,
    tipo_contrato    = case when v_camb ? 'tipo_contrato' then nullif(v_camb->>'tipo_contrato','') else tipo_contrato end,
    tipo_personal    = case when v_camb ? 'tipo_personal' then nullif(v_camb->>'tipo_personal','') else tipo_personal end,
    fecha_ingreso    = case when v_camb ? 'fecha_ingreso' then nullif(v_camb->>'fecha_ingreso','')::date else fecha_ingreso end,
    jefe_id          = case when v_camb ? 'jefe_id' then nullif(v_camb->>'jefe_id','')::uuid else jefe_id end,
    metodo_checada   = coalesce(nullif(v_camb->>'metodo_checada','')::public.metodo_checada, metodo_checada)
  where id = p_id;

  -- Si cambió la fecha de ingreso, la antigüedad cambió y con
  -- ella los días de vacaciones que le corresponden.
  if v_camb ? 'fecha_ingreso' then
    perform public.devengar_vacaciones(p_id);
  end if;

  perform app.auditar('empleado.actualizar', 'empleados', p_id::text,
    (select jsonb_object_agg(k2, to_jsonb(antes) -> k2)
       from jsonb_object_keys(v_camb) k2),
    v_camb);

  return jsonb_build_object('status','success');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.asignar_turno(p_empleado_id uuid, p_turno_id uuid DEFAULT NULL::uuid, p_patron_id uuid DEFAULT NULL::uuid, p_desde date DEFAULT NULL::date, p_descanso smallint[] DEFAULT '{0}'::smallint[], p_ancla date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_desde date := coalesce(p_desde, current_date);
  v_id    uuid;
  v_cerradas integer;
begin
  if not app.alcanza_razon((select razon_id from public.empleados where id = p_empleado_id)) then
    raise exception 'Ese empleado pertenece a una empresa fuera de tu alcance.';
  end if;

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
$function$
;

CREATE OR REPLACE FUNCTION public.bandeja_incidencias(p_vista text DEFAULT 'mias'::text, p_estatus text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_yo    uuid;
  v_admin boolean := app.es_admin();
  v_filas jsonb;
begin
  select empleado_id into v_yo from public.perfiles where id = auth.uid();

  select jsonb_agg(x order by x->>'creado_en' desc) into v_filas
  from (
    select jsonb_build_object(
      'id', i.id,
      'empleado', e.nombre_completo,
      'empleado_id', e.id,
      'no', e.no_empleado,
      'tipo', t.nombre, 'tipo_clave', t.clave,
      'color', t.color, 'descuenta_vac', t.descuenta_vac,
      'desde', i.fecha_inicio, 'hasta', i.fecha_fin, 'dias', i.dias,
      'comentario', i.comentario,
      'estatus', i.estatus,
      'espera', app.siguiente_aprobador(i.id),
      'creado_en', i.creado_en,
      'nota', i.resuelto_nota,
      'firmas', coalesce((
        select jsonb_agg(jsonb_build_object(
          'nivel', a.nivel, 'decision', a.decision,
          'quien', a.actor_nombre, 'cuando', a.creado_en, 'nota', a.nota)
          order by a.creado_en)
        from public.aprobaciones a where a.incidencia_id = i.id
      ), '[]'::jsonb),
      -- Puedo firmar YO esta solicitud ahora mismo
      'puedo_firmar', (
        i.estatus in ('pendiente','aprobada_jefe')
        and i.empleado_id is distinct from v_yo
        and (
          (app.siguiente_aprobador(i.id) = 'jefe' and (e.jefe_id = v_yo or v_admin))
          or (app.siguiente_aprobador(i.id) = 'rh' and v_admin)
        )
      )
    ) as x
    from public.incidencias i
    join public.empleados e on e.id = i.empleado_id
    join public.tipos_incidencia t on t.id = i.tipo_id
    where i.tenant_id = app.mi_tenant() and app.alcanza_razon(e.razon_id)
      and (p_estatus is null or i.estatus::text = p_estatus)
      and case p_vista
            when 'mias' then i.empleado_id = v_yo
            when 'poraprobar' then
              i.estatus in ('pendiente','aprobada_jefe')
              and i.empleado_id is distinct from v_yo
              and (v_admin or e.jefe_id = v_yo)
            else v_admin or e.jefe_id = v_yo or i.empleado_id = v_yo
          end
    limit 200
  ) s;

  return jsonb_build_object('status','success', 'filas', coalesce(v_filas,'[]'::jsonb));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.calcular_prenomina_periodo(p_periodo_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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

  if not app.alcanza_razon(per.razon_id) then
    raise exception 'Este periodo pertenece a una empresa fuera de tu alcance.';
  end if;

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
$function$
;

CREATE OR REPLACE FUNCTION public.calendario(p_desde date, p_hasta date, p_centro_id uuid DEFAULT NULL::uuid, p_solo_mias boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  where i.tenant_id = v_tenant and app.alcanza_razon(e.razon_id)
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
    where e.tenant_id = v_tenant and app.alcanza_razon(e.razon_id)
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
    where e.tenant_id = v_tenant and app.alcanza_razon(e.razon_id)
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
$function$
;

CREATE OR REPLACE FUNCTION public.calendario_turnos(p_desde date, p_hasta date, p_centro_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
          -- Los festivos se marcan aparte: un día de descanso obligatorio no
          -- es lo mismo que el descanso semanal.
          'fest', exists(select 1 from public.dias_no_laborables
                          where tenant_id = e.tenant_id and fecha = d::date
                            and (centro_id is null or centro_id = e.centro_id))
        ) order by d)
        from generate_series(p_desde, p_hasta, '1 day') d
      )
    ) as x
    from public.empleados e
   where e.tenant_id = app.mi_tenant()
     -- Alcance: la funcion es security definer y RLS no la protege.
     and app.alcanza_razon(e.razon_id)
     and e.estatus = 'Activo'
     and (p_centro_id is null or e.centro_id = p_centro_id)
  ) s;

  return jsonb_build_object('status','success',
    'filas', coalesce(v_filas, '[]'::jsonb));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.checada_manual(p_empleado_id uuid, p_momento timestamp with time zone, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  e       public.empleados;
  v_fecha date;
  v_id    uuid;
begin
  if not app.alcanza_razon((select razon_id from public.empleados where id = p_empleado_id)) then
    raise exception 'Ese empleado pertenece a una empresa fuera de tu alcance.';
  end if;

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
$function$
;

CREATE OR REPLACE FUNCTION public.dar_baja_empleado(p_id uuid, p_fecha date, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  e        public.empleados;
  v_saldo  numeric;
begin
  if not app.alcanza_razon((select razon_id from public.empleados where id = p_id)) then
    raise exception 'Ese empleado pertenece a una empresa fuera de tu alcance.';
  end if;

  if not app.es_admin() then
    raise exception 'Sin permiso';
  end if;
  if coalesce(trim(p_motivo),'') = '' then
    raise exception 'El motivo de la baja es obligatorio';
  end if;

  select * into e from public.empleados
   where id = p_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Empleado no encontrado'; end if;
  if e.estatus = 'Baja' then
    raise exception 'Este empleado ya esta dado de baja desde %', e.fecha_baja;
  end if;

  update public.empleados
     set estatus = 'Baja', fecha_baja = p_fecha, motivo_baja = p_motivo
   where id = p_id;

  -- Cierra la asignación de turno: sin esto seguiría "trabajando"
  -- turnos y apareciendo con faltas después de su baja.
  update public.asignaciones_turno
     set hasta = p_fecha
   where empleado_id = p_id and (hasta is null or hasta > p_fecha);

  -- Cierra ubicaciones autorizadas
  update public.ubicaciones_empleado
     set hasta = p_fecha
   where empleado_id = p_id and (hasta is null or hasta > p_fecha);

  v_saldo := public.saldo_vacaciones(p_id);

  perform app.auditar('empleado.baja', 'empleados', p_id::text,
    jsonb_build_object('estatus', e.estatus),
    jsonb_build_object('fecha', p_fecha, 'motivo', p_motivo,
                       'saldo_vacaciones_pendiente', v_saldo));

  return jsonb_build_object(
    'status','success',
    -- Se devuelve el saldo para que RH sepa qué debe finiquitar.
    -- Callarlo sería esconder una obligación de pago.
    'saldo_vacaciones', v_saldo
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.documentos_empleado(p_empleado_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_yo uuid;
  e public.empleados;
begin
  select empleado_id into v_yo from public.perfiles where id = auth.uid();
  if not app.es_admin() and v_yo is distinct from p_empleado_id then
    raise exception 'Sin permiso';
  end if;

  -- Alcance: un expediente trae INE, actas y comprobantes de domicilio. Es lo
  -- mas sensible del sistema y hasta ahora bastaba con adivinar un id.
  select * into e from public.empleados
   where id = p_empleado_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Empleado no encontrado'; end if;

  if v_yo is distinct from p_empleado_id and not app.alcanza_razon(e.razon_id) then
    raise exception 'Este empleado pertenece a una empresa fuera de tu alcance.';
  end if;

  return jsonb_build_object(
    'status','success',
    'documentos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', d.id, 'nombre', d.nombre, 'ruta', d.ruta, 'mime', d.mime,
        'tipo', t.nombre, 'tipo_clave', t.clave,
        'fecha_doc', d.fecha_doc, 'fecha_vence', d.fecha_vence,
        'vencido', d.fecha_vence is not null and d.fecha_vence < current_date,
        'por_vencer', d.fecha_vence is not null
          and d.fecha_vence between current_date and current_date + 30,
        'ocr_estado', d.ocr_estado, 'ocr_campos', d.ocr_campos,
        'creado_en', d.creado_en
      ) order by d.creado_en desc)
      from public.documentos d
      left join public.tipos_documento t on t.id = d.tipo_id
      where d.empleado_id = p_empleado_id
    ), '[]'::jsonb),
    'faltantes', coalesce((
      select jsonb_agg(jsonb_build_object('clave', t.clave, 'nombre', t.nombre))
      from public.tipos_documento t
      where t.tenant_id = app.mi_tenant()
        and t.obligatorio and t.activo
        and not exists (
          select 1 from public.documentos d
           where d.empleado_id = p_empleado_id and d.tipo_id = t.id)
    ), '[]'::jsonb),
    'tipos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id, 'clave', clave, 'nombre', nombre,
        'obligatorio', obligatorio) order by nombre)
      from public.tipos_documento
      where tenant_id = app.mi_tenant() and activo
    ), '[]'::jsonb)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.listar_empleados(p_buscar text DEFAULT NULL::text, p_estatus text DEFAULT 'Activo'::text, p_centro_id uuid DEFAULT NULL::uuid, p_limite integer DEFAULT 50, p_desde integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_yo uuid;
  v_admin boolean := app.es_admin();
  v_total integer;
  v_filas jsonb;
begin
  select empleado_id into v_yo from public.perfiles where id = auth.uid();

  if not v_admin and v_yo is null then
    return jsonb_build_object('status','error','message','Sin permiso');
  end if;

  -- El alcance se filtra aqui a proposito: la funcion es security definer, o
  -- sea que corre como el dueno y salta RLS.
  with visibles as (
    select e.*
      from public.empleados e
     where e.tenant_id = app.mi_tenant()
       and (v_admin or e.jefe_id = v_yo or e.id = v_yo)
       and (not v_admin or app.alcanza_razon(e.razon_id))
       and (p_estatus = 'Todos' or e.estatus = p_estatus)
       and (p_centro_id is null or e.centro_id = p_centro_id)
       and (
         p_buscar is null or trim(p_buscar) = ''
         or public.sin_acentos(e.nombre_completo) like '%' || public.sin_acentos(p_buscar) || '%'
         or e.no_empleado ilike '%' || p_buscar || '%'
         or public.sin_acentos(coalesce(e.puesto,'')) like '%' || public.sin_acentos(p_buscar) || '%'
       )
  )
  select count(*) into v_total from visibles;

  with visibles as (
    select e.*
      from public.empleados e
     where e.tenant_id = app.mi_tenant()
       and (v_admin or e.jefe_id = v_yo or e.id = v_yo)
       and (not v_admin or app.alcanza_razon(e.razon_id))
       and (p_estatus = 'Todos' or e.estatus = p_estatus)
       and (p_centro_id is null or e.centro_id = p_centro_id)
       and (
         p_buscar is null or trim(p_buscar) = ''
         or public.sin_acentos(e.nombre_completo) like '%' || public.sin_acentos(p_buscar) || '%'
         or e.no_empleado ilike '%' || p_buscar || '%'
         or public.sin_acentos(coalesce(e.puesto,'')) like '%' || public.sin_acentos(p_buscar) || '%'
       )
     order by e.nombre_completo
     limit p_limite offset p_desde
  )
  select jsonb_agg(jsonb_build_object(
    'id', v.id, 'no', v.no_empleado, 'nombre', v.nombre_completo,
    'puesto', v.puesto, 'departamento', v.departamento,
    'centro', c.clave, 'centro_id', v.centro_id,
    'estatus', v.estatus,
    'fecha_ingreso', v.fecha_ingreso,
    'antiguedad_meses', public.antiguedad_meses(v.*),
    'metodo_checada', v.metodo_checada,
    'saldo_vacaciones', public.saldo_vacaciones(v.id)
  )) into v_filas
  from visibles v
  left join public.centros_trabajo c on c.id = v.centro_id;

  return jsonb_build_object(
    'status','success', 'total', v_total,
    'filas', coalesce(v_filas, '[]'::jsonb));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.nom035_avance(p_campana_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  c public.nom035_campanas;
  v_resp integer;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  select * into c from public.nom035_campanas
   where id = p_campana_id and tenant_id = app.mi_tenant() and app.alcanza_razon((select ct_al.razon_id from public.centros_trabajo ct_al where ct_al.id = centro_id));
  if not found then raise exception 'Campana no encontrada'; end if;

  select count(*) into v_resp from public.nom035_respuestas
   where campana_id = p_campana_id;

  return jsonb_build_object(
    'status','success',
    'campana', jsonb_build_object(
      'id', c.id, 'nombre', c.nombre, 'estado', c.estado,
      'abre', c.abre, 'cierra', c.cierra,
      'universo', c.universo, 'muestra_minima', c.muestra_minima),
    'respuestas', v_resp,
    'pct_universo', case when c.universo > 0
                    then round(v_resp * 100.0 / c.universo) else 0 end,
    'pct_muestra', case when coalesce(c.muestra_minima,0) > 0
                   then least(100, round(v_resp * 100.0 / c.muestra_minima)) else 0 end,
    'falta_para_muestra', greatest(0, coalesce(c.muestra_minima,0) - v_resp),
    'pendientes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'empleado_id', e.id, 'nombre', e.nombre_completo,
        'no', e.no_empleado, 'email', e.email,
        'token', i.token, 'enviado', i.enviado_en is not null)
        order by e.nombre_completo)
      from public.nom035_invitaciones i
      join public.empleados e on e.id = i.empleado_id
      where i.campana_id = p_campana_id and i.usado_en is null
    ), '[]'::jsonb),
    -- Solo nombres de quien SI contesto, nunca su resultado
    'contestaron', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nombre', e.nombre_completo, 'cuando', i.usado_en)
        order by i.usado_en desc)
      from public.nom035_invitaciones i
      join public.empleados e on e.id = i.empleado_id
      where i.campana_id = p_campana_id and i.usado_en is not null
    ), '[]'::jsonb)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.nom035_programa(p_campana_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare p public.nom035_programas;
begin
  select * into p from public.nom035_programas
   where campana_id = p_campana_id and tenant_id = app.mi_tenant() and app.alcanza_razon((select ct_al.razon_id from public.centros_trabajo ct_al where ct_al.id = centro_id));
  if not found then
    return jsonb_build_object('status','vacio');
  end if;

  return jsonb_build_object(
    'status','success',
    'programa', jsonb_build_object(
      'id', p.id, 'nombre', p.nombre, 'estado', p.estado,
      'nivel_origen', p.nivel_origen, 'inicia', p.inicia, 'concluye', p.concluye),
    'acciones', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id, 'dominio', a.dominio, 'nivel', a.nivel_accion,
        'accion', a.accion, 'estado', a.estado,
        'responsable', coalesce(
          (select nombre_completo from public.empleados where id = a.responsable_id),
          a.responsable_txt),
        'responsable_id', a.responsable_id,
        'meta', a.fecha_meta, 'hecho', a.fecha_hecho,
        'evidencia', a.evidencia_ruta, 'nota', a.nota,
        'vencida', a.fecha_meta is not null and a.fecha_meta < current_date
                   and a.estado not in ('hecha','cancelada'))
        order by a.orden, a.creado_en)
      from public.nom035_acciones a where a.programa_id = p.id
    ), '[]'::jsonb),
    'avance', (
      select case when count(*) = 0 then 0
             else round(count(*) filter (where estado = 'hecha') * 100.0 / count(*))
             end
      from public.nom035_acciones where programa_id = p.id
        and estado <> 'cancelada')
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.nomina_detalle(p_periodo_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  per public.periodos_nomina;
  g public.grupos_nomina;
  rs public.razones_sociales;
begin
  select * into per from public.periodos_nomina
   where id = p_periodo_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Periodo no encontrado'; end if;

  -- Decirlo claro en lugar de fingir que no existe: si RH cree que se le
  -- perdio un periodo, va a abrir un ticket.
  if not app.alcanza_razon(per.razon_id) then
    raise exception 'Este periodo pertenece a una empresa fuera de tu alcance.';
  end if;

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
$function$
;

CREATE OR REPLACE FUNCTION public.nomina_mov_guardar(p_periodo_id uuid, p_empleado_id uuid, p_concepto_id uuid, p_importe numeric, p_cantidad numeric DEFAULT NULL::numeric, p_nota text DEFAULT NULL::text, p_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  per public.periodos_nomina;
  v_id uuid;
begin
  if not app.es_admin() then
    raise exception 'Solo RH o administracion puede capturar movimientos.';
  end if;
  if p_importe is null or p_importe <= 0 then
    -- El signo lo define la naturaleza del concepto, no quien captura: un
    -- prestamo con importe negativo terminaria sumando al neto.
    raise exception 'El importe debe ser mayor a cero.';
  end if;

  select * into per from public.periodos_nomina
   where id = p_periodo_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Periodo no encontrado'; end if;

  if not app.alcanza_razon(per.razon_id) then
    raise exception 'Este periodo pertenece a una empresa fuera de tu alcance.';
  end if;

  if per.estado = 'cerrado' then
    raise exception 'El periodo esta cerrado. Reabrelo para capturar.';
  end if;

  if not exists (select 1 from public.conceptos_nomina
                  where id = p_concepto_id and tenant_id = per.tenant_id and activo) then
    raise exception 'Concepto no valido';
  end if;

  if p_id is null then
    insert into public.movimientos_nomina (
      tenant_id, periodo_id, empleado_id, concepto_id,
      cantidad, importe, nota, creado_por)
    values (per.tenant_id, per.id, p_empleado_id, p_concepto_id,
            p_cantidad, p_importe, p_nota, auth.uid())
    returning id into v_id;
  else
    update public.movimientos_nomina
       set concepto_id = p_concepto_id, cantidad = p_cantidad,
           importe = p_importe, nota = p_nota
     where id = p_id and periodo_id = per.id
    returning id into v_id;
    if v_id is null then raise exception 'Movimiento no encontrado'; end if;
  end if;

  perform app.auditar('movimiento_nomina','movimientos_nomina', v_id::text, null,
    jsonb_build_object('empleado', p_empleado_id, 'importe', p_importe));

  -- Recalculo inmediato: capturar un bono y que el neto no cambie hasta que
  -- alguien recuerde apretar "calcular" es como se pagan nominas mal.
  return jsonb_build_object('status','success','id',v_id,
    'recalculo', public.calcular_prenomina_empleado(per.id, p_empleado_id));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.nomina_periodo_crear(p_grupo_id uuid, p_desde date, p_hasta date, p_fecha_pago date DEFAULT NULL::date, p_numero integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  g public.grupos_nomina;
  v_num integer;
  v_id uuid;
  v_anio integer := extract(year from p_hasta)::integer;
begin
  if not app.es_admin() then
    raise exception 'Solo RH o administracion puede crear periodos.';
  end if;

  select * into g from public.grupos_nomina
   where id = p_grupo_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Grupo de nomina no encontrado'; end if;

  if not app.alcanza_razon(g.razon_id) then
    raise exception 'Ese grupo de pago pertenece a una empresa fuera de tu alcance.';
  end if;

  if p_hasta < p_desde then raise exception 'El rango de fechas esta invertido'; end if;

  -- Traslape con otro periodo del mismo grupo: dos periodos que cubren el
  -- mismo dia pagarian dos veces el mismo trabajo.
  if exists (
    select 1 from public.periodos_nomina p
     where p.grupo_id = p_grupo_id
       and daterange(p.desde, p.hasta, '[]') && daterange(p_desde, p_hasta, '[]'))
  then
    raise exception 'Ya existe un periodo de este grupo que cubre esas fechas.';
  end if;

  if p_numero is null then
    select coalesce(max(numero), 0) + 1 into v_num
      from public.periodos_nomina
     where grupo_id = p_grupo_id and anio = v_anio;
  else
    v_num := p_numero;
  end if;

  insert into public.periodos_nomina (
    tenant_id, grupo_id, centro_id, frecuencia, numero, anio,
    desde, hasta, dias, fecha_pago, estado)
  values (
    g.tenant_id, g.id, g.centro_id, g.frecuencia, v_num, v_anio,
    p_desde, p_hasta, (p_hasta - p_desde) + 1,
    coalesce(p_fecha_pago, p_hasta + g.dias_para_pago), 'abierto')
  returning id into v_id;

  perform app.auditar('periodo_creado','periodos_nomina', v_id::text, null,
    jsonb_build_object('grupo', g.clave, 'numero', v_num, 'anio', v_anio,
                       'desde', p_desde, 'hasta', p_hasta));

  return jsonb_build_object('status','success','id',v_id,'numero',v_num);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.nomina_periodo_estado(p_periodo_id uuid, p_estado text, p_nota text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  per public.periodos_nomina;
  v_n integer;
begin
  if not app.es_admin() then
    raise exception 'Solo RH o administracion puede cambiar el estado.';
  end if;
  if p_estado not in ('abierto','revision','cerrado') then
    raise exception 'Estado invalido';
  end if;

  select * into per from public.periodos_nomina
   where id = p_periodo_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Periodo no encontrado'; end if;

  if not app.alcanza_razon(per.razon_id) then
    raise exception 'Este periodo pertenece a una empresa fuera de tu alcance.';
  end if;

  if p_estado = 'cerrado' then
    select count(*) into v_n from public.prenomina where periodo_id = per.id;
    if v_n = 0 then
      raise exception 'No se puede cerrar un periodo sin renglones calculados.';
    end if;

    update public.periodos_nomina
       set estado = 'cerrado', cerrado_en = now(), cerrado_por = auth.uid(),
           nota = coalesce(p_nota, nota)
     where id = per.id;
  else
    -- Reabrir limpia la firma de cierre: dejarla puesta haria creer que
    -- alguien avalo los numeros que se van a mover.
    update public.periodos_nomina
       set estado = p_estado, cerrado_en = null, cerrado_por = null,
           nota = coalesce(p_nota, nota)
     where id = per.id;
  end if;

  perform app.auditar('periodo_estado','periodos_nomina', per.id::text,
    jsonb_build_object('estado', per.estado),
    jsonb_build_object('estado', p_estado, 'nota', p_nota));

  return jsonb_build_object('status','success','estado',p_estado);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.nomina_periodos(p_anio integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_t uuid := app.mi_tenant();
  v_anio integer := coalesce(p_anio, extract(year from current_date)::integer);
begin
  if v_t is null then raise exception 'Sin sesion valida'; end if;

  return jsonb_build_object(
    'anio', v_anio,
    'es_admin', app.es_admin(),
    'anios', (
      select coalesce(jsonb_agg(distinct p.anio order by p.anio desc), '[]'::jsonb)
        from public.periodos_nomina p
       where p.tenant_id = v_t and app.alcanza_razon(p.razon_id)),
    'empresas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', r.id, 'clave', r.clave, 'razon_social', r.razon_social,
               'rfc', r.rfc, 'grupo', g.nombre) order by r.clave), '[]'::jsonb)
        from public.razones_sociales r
        join public.grupos_empresariales g on g.id = r.grupo_id
       where r.tenant_id = v_t and r.activo
         and r.id in (select app.mis_razones())),
    'grupos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', g.id, 'clave', g.clave, 'nombre', g.nombre,
               'frecuencia', g.frecuencia, 'dias_para_pago', g.dias_para_pago,
               'activo', g.activo, 'razon_id', g.razon_id,
               'empresa', r.clave,
               'empleados', (
                 select count(*) from public.sueldos s
                  where s.grupo_id = g.id
                    and (s.hasta is null or s.hasta >= current_date))
             ) order by r.clave, g.clave), '[]'::jsonb)
        from public.grupos_nomina g
        left join public.razones_sociales r on r.id = g.razon_id
       where g.tenant_id = v_t and app.alcanza_razon(g.razon_id)),
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
       where p.tenant_id = v_t and p.anio = v_anio
         and app.alcanza_razon(p.razon_id))
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.nomina_sueldo_guardar(p_empleado_id uuid, p_sueldo_diario numeric, p_grupo_id uuid, p_desde date DEFAULT CURRENT_DATE, p_tipo text DEFAULT 'fijo'::text, p_dias_aguinaldo integer DEFAULT 15, p_prima_vac_pct numeric DEFAULT 0.25, p_otras_prestaciones numeric DEFAULT 0, p_zona_frontera boolean DEFAULT false, p_banco text DEFAULT NULL::text, p_clabe text DEFAULT NULL::text, p_motivo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_t uuid := app.mi_tenant();
  e public.empleados;
  v_id uuid;
  v_min numeric;
begin
  if not app.es_admin() then
    raise exception 'Solo RH o administracion puede registrar sueldos.';
  end if;

  select * into e from public.empleados
   where id = p_empleado_id and tenant_id = v_t;
  if not found then raise exception 'Empleado no encontrado'; end if;

  if not app.alcanza_razon(e.razon_id) then
    raise exception 'Este empleado pertenece a una empresa fuera de tu alcance.';
  end if;

  if p_grupo_id is not null and not exists (
       select 1 from public.grupos_nomina
        where id = p_grupo_id and tenant_id = v_t) then
    raise exception 'Grupo de nomina no valido';
  end if;

  -- Salario minimo: se avisa como error porque contratar por debajo del
  -- minimo no es una decision del capturista.
  v_min := app.param(case when p_zona_frontera then 'salario_minimo_znf'
                          else 'salario_minimo' end, p_desde);
  if p_sueldo_diario < v_min then
    raise exception 'El sueldo diario (%) es menor al salario minimo vigente (%).',
      p_sueldo_diario, v_min;
  end if;

  if p_prima_vac_pct > 1 then
    raise exception 'La prima vacacional se captura como fraccion (0.25 = 25%%).';
  end if;

  -- Un sueldo posterior ya capturado bloquea: cerrar el vigente dejaria un
  -- hueco de dias sin sueldo entre ambos.
  if exists (select 1 from public.sueldos
              where empleado_id = p_empleado_id and desde >= p_desde) then
    raise exception 'Ya existe un sueldo con vigencia igual o posterior a esa fecha.';
  end if;

  update public.sueldos
     set hasta = p_desde - 1
   where empleado_id = p_empleado_id
     and desde < p_desde
     and (hasta is null or hasta >= p_desde);

  insert into public.sueldos (
    tenant_id, empleado_id, sueldo_diario, tipo, grupo_id,
    dias_aguinaldo, prima_vac_pct, otras_prestaciones, zona_frontera,
    banco, clabe, desde, motivo, creado_por)
  values (
    v_t, p_empleado_id, p_sueldo_diario, p_tipo::tipo_salario, p_grupo_id,
    coalesce(p_dias_aguinaldo,15), coalesce(p_prima_vac_pct,0.25),
    coalesce(p_otras_prestaciones,0), coalesce(p_zona_frontera,false),
    p_banco, p_clabe, p_desde, p_motivo, auth.uid())
  returning id into v_id;

  perform app.auditar('sueldo_registrado','sueldos', v_id::text, null,
    jsonb_build_object('empleado', p_empleado_id, 'sueldo_diario', p_sueldo_diario,
                       'desde', p_desde, 'motivo', p_motivo));

  return jsonb_build_object('status','success','id',v_id,
    'sdi', public.sdi_empleado(p_empleado_id, p_desde));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.nomina_sueldo_historial(p_empleado_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_t uuid := app.mi_tenant();
  e public.empleados;
begin
  if not app.es_admin() then
    raise exception 'No tienes permiso para consultar sueldos.';
  end if;

  select * into e from public.empleados
   where id = p_empleado_id and tenant_id = v_t;
  if not found then raise exception 'Empleado no encontrado'; end if;

  if not app.alcanza_razon(e.razon_id) then
    raise exception 'Este empleado pertenece a una empresa fuera de tu alcance.';
  end if;

  return jsonb_build_object(
    'empleado', jsonb_build_object(
      'id', e.id, 'nombre', e.nombre_completo,
      'no_empleado', e.no_empleado, 'fecha_ingreso', e.fecha_ingreso),
    'sdi', public.sdi_empleado(p_empleado_id, current_date),
    'minimos', jsonb_build_object(
      'general', app.param('salario_minimo', current_date),
      'frontera', app.param('salario_minimo_znf', current_date)),
    'grupos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', g.id, 'clave', g.clave, 'nombre', g.nombre,
               'frecuencia', g.frecuencia) order by g.clave), '[]'::jsonb)
        from public.grupos_nomina g
       where g.tenant_id = v_t and g.activo
         and app.alcanza_razon(g.razon_id)),
    'historial', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', s.id, 'sueldo_diario', s.sueldo_diario, 'tipo', s.tipo,
               'dias_aguinaldo', s.dias_aguinaldo,
               'prima_vac_pct', s.prima_vac_pct,
               'otras_prestaciones', s.otras_prestaciones,
               'zona_frontera', s.zona_frontera,
               'banco', s.banco, 'clabe', s.clabe,
               'desde', s.desde, 'hasta', s.hasta, 'motivo', s.motivo,
               'grupo', g.clave, 'grupo_nombre', g.nombre,
               'grupo_id', s.grupo_id,
               'vigente', (s.hasta is null or s.hasta >= current_date)
                          and s.desde <= current_date,
               'creado_en', s.creado_en,
               'capturo', pf.nombre)
             order by s.desde desc), '[]'::jsonb)
        from public.sueldos s
        left join public.grupos_nomina g on g.id = s.grupo_id
        left join public.perfiles pf on pf.id = s.creado_por
       where s.empleado_id = p_empleado_id)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.obtener_empleado(p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  e public.empleados;
  v_yo uuid;
  v_propio boolean;
begin
  select empleado_id into v_yo from public.perfiles where id = auth.uid();

  select * into e from public.empleados
   where id = p_id and tenant_id = app.mi_tenant();
  if not found then
    return jsonb_build_object('status','error','message','No encontrado');
  end if;

  -- Lo propio y lo de mi equipo: solo cuenta si tengo empleado ligado. Con
  -- v_yo nulo, comparar contra null daba true y abria cualquier expediente.
  v_propio := v_yo is not null and (e.id = v_yo or e.jefe_id = v_yo);

  if not app.es_admin() and not v_propio then
    return jsonb_build_object('status','error','message','Sin permiso');
  end if;

  -- Alcance: un RH limitado no abre expedientes de otra empresa, salvo el
  -- suyo o el de su equipo.
  if not v_propio and not app.alcanza_razon(e.razon_id) then
    return jsonb_build_object('status','error',
      'message','Este empleado pertenece a una empresa fuera de tu alcance.');
  end if;

  return jsonb_build_object(
    'status','success',
    'empleado', to_jsonb(e)
      || jsonb_build_object(
        'edad', public.edad(e.*),
        'antiguedad_meses', public.antiguedad_meses(e.*),
        'saldo_vacaciones', public.saldo_vacaciones(e.id),
        'dias_lft', public.dias_vacaciones_lft(
          coalesce(public.antiguedad_meses(e.*), 0) / 12)
      ),
    'centro', (select jsonb_build_object('clave', clave, 'nombre', nombre)
                 from public.centros_trabajo where id = e.centro_id),
    'jefe', (select jsonb_build_object('id', id, 'nombre', nombre_completo)
               from public.empleados where id = e.jefe_id),
    'turno', (select jsonb_build_object('clave', t.clave, 'nombre', t.nombre,
                       'entrada', t.hora_entrada, 'salida', t.hora_salida)
                from public.asignaciones_turno a
                join public.turnos t on t.id = a.turno_id
               where a.empleado_id = e.id
                 and current_date >= a.desde
                 and (a.hasta is null or current_date <= a.hasta)
               limit 1),
    'ultimas_jornadas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'fecha', j.fecha_laboral, 'estatus', j.estatus,
               'entrada', j.entrada, 'salida', j.salida,
               'minutos_trabajados', j.minutos_trabajados,
               'minutos_retardo', j.minutos_retardo)
             order by j.fecha_laboral desc), '[]'::jsonb)
        from public.jornadas j
       where j.empleado_id = e.id
         and j.fecha_laboral >= current_date - 30)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.organigrama(p_centro_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    where e.tenant_id = app.mi_tenant() and app.alcanza_razon(e.razon_id)
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
    where e.tenant_id = app.mi_tenant() and app.alcanza_razon(e.razon_id)
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
  where e.tenant_id = app.mi_tenant() and app.alcanza_razon(e.razon_id)
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
$function$
;

CREATE OR REPLACE FUNCTION public.prima_guardar(p_razon_id uuid, p_prima numeric, p_vigente_de date, p_clase text DEFAULT NULL::text, p_fraccion text DEFAULT NULL::text, p_nota text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_id uuid;
begin
  if not app.es_admin() then
    raise exception 'Solo administracion puede registrar la prima de riesgo.';
  end if;
  if not exists (select 1 from public.razones_sociales
                  where id = p_razon_id and tenant_id = app.mi_tenant()) then
    raise exception 'Empresa no encontrada';
  end if;
  if not app.alcanza_razon(p_razon_id) then
    raise exception 'Esa empresa esta fuera de tu alcance.';
  end if;
  -- La prima se captura como fraccion: 0.005 y no 0.5%.
  if p_prima > 0.15 then
    raise exception 'La prima se captura como fraccion (0.005 = 0.5%%). Maximo 0.15.';
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
$function$
;

CREATE OR REPLACE FUNCTION public.primas_historial(p_razon_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
begin
  if not app.es_admin() then
    raise exception 'Solo administracion puede consultar la prima de riesgo.';
  end if;
  if not exists (select 1 from public.razones_sociales
                  where id = p_razon_id and tenant_id = app.mi_tenant()) then
    raise exception 'Empresa no encontrada';
  end if;
  if not app.alcanza_razon(p_razon_id) then
    raise exception 'Esa empresa esta fuera de tu alcance.';
  end if;

  return jsonb_build_object(
    'filas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'prima', p.prima, 'clase', p.clase,
               'fraccion', p.fraccion, 'vigente_de', p.vigente_de,
               'vigente_a', p.vigente_a, 'nota', p.nota,
               'vigente', p.vigente_de <= current_date
                          and (p.vigente_a is null or p.vigente_a >= current_date)
             ) order by p.vigente_de desc), '[]'::jsonb)
        from public.primas_riesgo p where p.razon_id = p_razon_id)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.razon_guardar(p_grupo_id uuid, p_clave text, p_razon_social text, p_nombre_comercial text DEFAULT NULL::text, p_rfc text DEFAULT NULL::text, p_registro_patronal text DEFAULT NULL::text, p_regimen_fiscal text DEFAULT NULL::text, p_codigo_postal text DEFAULT NULL::text, p_domicilio text DEFAULT NULL::text, p_representante_legal text DEFAULT NULL::text, p_activo boolean DEFAULT true, p_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_t uuid := app.mi_tenant();
  v_id uuid;
  v_clave text;
  v_rfc text;
begin
  if not app.es_admin() then
    raise exception 'Solo administracion puede administrar empresas.';
  end if;
  if not exists (select 1 from public.grupos_empresariales
                  where id = p_grupo_id and tenant_id = v_t) then
    raise exception 'Grupo no valido';
  end if;

  -- Editar una empresa fuera de alcance, o moverla a un grupo ajeno.
  if p_id is not null and not app.alcanza_razon(p_id) then
    raise exception 'Esa empresa esta fuera de tu alcance.';
  end if;

  v_rfc := nullif(upper(trim(coalesce(p_rfc,''))),'');

  -- El RFC se valida al capturarlo, no en la tabla: los datos migrados traen
  -- RFC mal capturados de origen y bloquearlos impediria corregirlos.
  if v_rfc is not null and length(v_rfc) not between 12 and 13 then
    raise exception 'El RFC debe tener 12 caracteres (moral) o 13 (fisica). Recibi % de longitud %.', v_rfc, length(v_rfc);
  end if;

  if v_rfc is not null and exists (
    select 1 from public.razones_sociales
     where tenant_id = v_t and upper(trim(rfc)) = v_rfc
       and (p_id is null or id <> p_id))
  then
    raise exception 'Ya existe otra empresa con el RFC %.', v_rfc;
  end if;

  if p_id is null then
    -- La clave se genera sola si no se captura: pedirle a RH que invente una
    -- clave corta es pedirle que teclee RS1, RS-1 y RAZON1 el mismo dia.
    v_clave := nullif(upper(trim(coalesce(p_clave,''))),'');
    if v_clave is null then
      select 'RS' || lpad((coalesce(max(
               nullif(regexp_replace(clave, '\D', '', 'g'), '')::integer), 0) + 1)::text,
             2, '0')
        into v_clave
        from public.razones_sociales where tenant_id = v_t;
    end if;

    insert into public.razones_sociales (
      tenant_id, grupo_id, clave, razon_social, nombre_comercial, rfc,
      registro_patronal, regimen_fiscal, codigo_postal, domicilio,
      representante_legal, activo)
    values (
      v_t, p_grupo_id, v_clave, trim(p_razon_social),
      nullif(trim(coalesce(p_nombre_comercial,'')),''), v_rfc,
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
           rfc = v_rfc,
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
    jsonb_build_object('razon_social', p_razon_social, 'rfc', v_rfc));
  return jsonb_build_object('status','success','id',v_id);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.resolver_incidencia(p_id uuid, p_decision text, p_nota text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  i        public.incidencias;
  t        public.tipos_incidencia;
  e        public.empleados;
  v_nivel  text;
  v_yo     uuid;
  p        public.perfiles;
  v_saldo  numeric;
  v_falta  text;
begin
  if not app.alcanza_razon((select razon_id from public.empleados where id = (select empleado_id from public.incidencias where id = p_id))) then
    raise exception 'Ese empleado pertenece a una empresa fuera de tu alcance.';
  end if;

  select * into p from public.perfiles where id = auth.uid();
  select empleado_id into v_yo from public.perfiles where id = auth.uid();

  select * into i from public.incidencias
   where id = p_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Solicitud no encontrada'; end if;

  if i.estatus not in ('pendiente','aprobada_jefe') then
    raise exception 'Esta solicitud ya fue resuelta (%)', i.estatus;
  end if;

  v_nivel := app.siguiente_aprobador(p_id);
  if v_nivel is null then raise exception 'No hay aprobaciones pendientes'; end if;

  select * into e from public.empleados where id = i.empleado_id;
  select * into t from public.tipos_incidencia where id = i.tipo_id;

  -- ── Quien puede firmar cada nivel ──
  if v_nivel = 'jefe' then
    if not (e.jefe_id = v_yo or app.es_admin()) then
      raise exception 'Solo el jefe directo puede dar esta autorizacion';
    end if;
  else
    if not app.es_admin() then
      raise exception 'Solo Recursos Humanos puede dar esta autorizacion';
    end if;
  end if;

  -- Nadie aprueba lo propio, ni siendo RH: es control interno
  -- basico y lo primero que revisa una auditoria.
  if i.empleado_id = v_yo then
    raise exception 'No puedes autorizar tu propia solicitud';
  end if;

  insert into public.aprobaciones
    (tenant_id, incidencia_id, nivel, decision, actor_id, actor_nombre, nota)
  values
    (i.tenant_id, p_id, v_nivel, p_decision, auth.uid(), p.nombre, p_nota);

  -- ── Rechazo: termina aqui ──
  if p_decision = 'rechazada' then
    update public.incidencias
       set estatus = 'rechazada', resuelto_por = auth.uid(),
           resuelto_en = now(), resuelto_nota = p_nota
     where id = p_id;

    perform app.auditar('incidencia.rechazar', 'incidencias', p_id::text, null,
      jsonb_build_object('nivel', v_nivel, 'nota', p_nota));

    return jsonb_build_object('status','success','estatus','rechazada');
  end if;

  -- ── Aprobacion: falta otra firma? ──
  v_falta := app.siguiente_aprobador(p_id);

  if v_falta is not null then
    update public.incidencias set estatus = 'aprobada_jefe' where id = p_id;
    return jsonb_build_object('status','success','estatus','aprobada_jefe',
                              'espera', v_falta);
  end if;

  -- ── Ultima firma: se valida saldo OTRA VEZ ──
  -- Entre la solicitud y esta firma pudieron pasar dias y otra
  -- solicitud pudo consumir el saldo. Validar solo al inicio
  -- permite quedar en negativo.
  if t.descuenta_vac then
    v_saldo := public.saldo_vacaciones(i.empleado_id);
    if i.dias > v_saldo then
      raise exception 'El saldo ya no alcanza: tiene % dia(s) y la solicitud es de %',
        round(v_saldo), i.dias;
    end if;
  end if;

  update public.incidencias
     set estatus = 'aprobada', resuelto_por = auth.uid(),
         resuelto_en = now(), resuelto_nota = p_nota
   where id = p_id;

  -- Los dias se descuentan AQUI, no al solicitar: una solicitud
  -- rechazada dejaria dias fantasma que devolver a mano.
  if t.descuenta_vac then
    insert into public.vacaciones_movimientos
      (tenant_id, empleado_id, tipo, dias, fecha_efecto, incidencia_id, nota, creado_por)
    values
      (i.tenant_id, i.empleado_id, 'tomado', -i.dias, i.fecha_inicio, p_id,
       'Vacaciones del ' || i.fecha_inicio || ' al ' || i.fecha_fin, auth.uid());
  end if;

  -- El trigger inc_recalcular (migracion 02) recalcula las
  -- jornadas de esos dias solo.

  perform app.auditar('incidencia.aprobar', 'incidencias', p_id::text, null,
    jsonb_build_object('nivel', v_nivel, 'dias', i.dias));

  return jsonb_build_object('status','success','estatus','aprobada');
end;
$function$
;

CREATE OR REPLACE FUNCTION public.tablero_dia(p_fecha date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
    where e.tenant_id = app.mi_tenant() and app.alcanza_razon(e.razon_id)
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
$function$
;
