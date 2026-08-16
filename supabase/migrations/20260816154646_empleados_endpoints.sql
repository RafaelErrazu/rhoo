-- ═══════════════════════════════════════════════════════════
--  RHoo! · Endpoints del módulo Empleados
-- ═══════════════════════════════════════════════════════════

/* Lista con búsqueda, filtros y paginación.
   La búsqueda ignora acentos y mayúsculas usando el índice de
   `sin_acentos` que creamos en la migración 01: sin él, buscar
   "perez" no encontraría a "Pérez". */
create or replace function public.listar_empleados(
  p_buscar    text default null,
  p_estatus   text default 'Activo',
  p_centro_id uuid default null,
  p_limite    integer default 50,
  p_desde     integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_yo    uuid;
  v_admin boolean := app.es_admin();
  v_total integer;
  v_filas jsonb;
begin
  select empleado_id into v_yo from public.perfiles where id = auth.uid();

  if not v_admin and v_yo is null then
    return jsonb_build_object('status','error','message','Sin permiso');
  end if;

  with visibles as (
    select e.*
    from public.empleados e
    where e.tenant_id = app.mi_tenant()
      and (v_admin or e.jefe_id = v_yo or e.id = v_yo)
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
    -- El saldo se calcula al vuelo: guardarlo se desincroniza
    'saldo_vacaciones', public.saldo_vacaciones(v.id)
  )) into v_filas
  from visibles v
  left join public.centros_trabajo c on c.id = v.centro_id;

  return jsonb_build_object(
    'status','success',
    'total', v_total,
    'filas', coalesce(v_filas, '[]'::jsonb)
  );
end;
$$;

/* Expediente completo de una persona. */
create or replace function public.obtener_empleado(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  e      public.empleados;
  v_yo   uuid;
begin
  select empleado_id into v_yo from public.perfiles where id = auth.uid();

  select * into e from public.empleados
   where id = p_id and tenant_id = app.mi_tenant();
  if not found then
    return jsonb_build_object('status','error','message','No encontrado');
  end if;

  -- Se repite la regla de visibilidad de RLS: esta funcion es
  -- SECURITY DEFINER, asi que RLS no la protege sola.
  if not app.es_admin() and e.id <> v_yo and e.jefe_id is distinct from v_yo then
    return jsonb_build_object('status','error','message','Sin permiso');
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
    'jefe',   (select jsonb_build_object('id', id, 'nombre', nombre_completo)
               from public.empleados where id = e.jefe_id),
    'turno',  (select jsonb_build_object('clave', t.clave, 'nombre', t.nombre,
                        'entrada', t.hora_entrada, 'salida', t.hora_salida)
               from public.asignaciones_turno a
               join public.turnos t on t.id = a.turno_id
               where a.empleado_id = e.id
                 and current_date >= a.desde
                 and (a.hasta is null or current_date <= a.hasta)
               limit 1),
    'ultimas_jornadas', coalesce((
        select jsonb_agg(jsonb_build_object(
          'fecha', fecha_laboral, 'estatus', estatus,
          'entrada', entrada, 'salida', salida,
          'retardo', minutos_retardo, 'trabajados', minutos_trabajados)
          order by fecha_laboral desc)
        from (select * from public.jornadas
              where empleado_id = e.id
              order by fecha_laboral desc limit 10) j
      ), '[]'::jsonb)
  );
end;
$$;

/* Alta. Pide lo mínimo indispensable.
   Un formulario de 25 campos obligatorios provoca que RH invente
   datos para poder guardar; es peor que un expediente incompleto. */
create or replace function public.crear_empleado(p_datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id  uuid;
  v_no  text := trim(coalesce(p_datos->>'no_empleado',''));
begin
  if not app.es_admin() then
    raise exception 'Sin permiso para dar de alta empleados';
  end if;
  if v_no = '' then
    raise exception 'El numero de empleado es obligatorio';
  end if;
  if trim(coalesce(p_datos->>'apellido_paterno','')) = ''
     or trim(coalesce(p_datos->>'nombres','')) = '' then
    raise exception 'Apellido paterno y nombres son obligatorios';
  end if;

  if exists (select 1 from public.empleados
             where tenant_id = app.mi_tenant() and no_empleado = v_no) then
    raise exception 'Ya existe un empleado con el numero %', v_no;
  end if;

  insert into public.empleados (
    tenant_id, centro_id, no_empleado,
    apellido_paterno, apellido_materno, nombres,
    sexo, fecha_nacimiento, estado_civil, escolaridad,
    curp, rfc, nss, email, telefono,
    puesto, departamento, tipo_puesto, tipo_contrato, tipo_personal,
    fecha_ingreso, jefe_id, metodo_checada, estatus
  ) values (
    app.mi_tenant(),
    nullif(p_datos->>'centro_id','')::uuid,
    v_no,
    upper(trim(p_datos->>'apellido_paterno')),
    upper(trim(coalesce(p_datos->>'apellido_materno',''))),
    upper(trim(p_datos->>'nombres')),
    nullif(p_datos->>'sexo',''),
    nullif(p_datos->>'fecha_nacimiento','')::date,
    nullif(p_datos->>'estado_civil',''),
    nullif(p_datos->>'escolaridad',''),
    upper(nullif(p_datos->>'curp','')),
    upper(nullif(p_datos->>'rfc','')),
    nullif(p_datos->>'nss',''),
    lower(nullif(p_datos->>'email','')),
    nullif(p_datos->>'telefono',''),
    nullif(p_datos->>'puesto',''),
    nullif(p_datos->>'departamento',''),
    nullif(p_datos->>'tipo_puesto',''),
    nullif(p_datos->>'tipo_contrato',''),
    nullif(p_datos->>'tipo_personal',''),
    nullif(p_datos->>'fecha_ingreso','')::date,
    nullif(p_datos->>'jefe_id','')::uuid,
    coalesce(nullif(p_datos->>'metodo_checada','')::public.metodo_checada,
             app.cfg_txt('metodo_checada_default')::public.metodo_checada),
    'Activo'
  ) returning id into v_id;

  -- Se generan los devengados de vacaciones que ya le
  -- correspondan. Si el alta es de alguien con antiguedad previa
  -- (traspaso, recontratacion), sus dias aparecen de inmediato.
  perform public.devengar_vacaciones(v_id);

  perform app.auditar('empleado.crear', 'empleados', v_id::text, null, p_datos);

  return jsonb_build_object('status','success','id', v_id);
end;
$$;

/* Actualización parcial: solo las claves recibidas.
   Así dos pantallas distintas del expediente no se pisan. */
create or replace function public.actualizar_empleado(
  p_id    uuid,
  p_datos jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
$$;

/* Baja. No borra: cambia estatus y conserva todo.
   La LFT obliga a guardar documentacion laboral despues de la
   separacion, y las jornadas y vacaciones cuelgan del empleado
   con ON DELETE CASCADE: borrarlo destruiria el historico. */
create or replace function public.dar_baja_empleado(
  p_id     uuid,
  p_fecha  date,
  p_motivo text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  e        public.empleados;
  v_saldo  numeric;
begin
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
$$;

/* Reactivación (recontratación o baja capturada por error). */
create or replace function public.reactivar_empleado(p_id uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  update public.empleados
     set estatus = 'Activo', fecha_baja = null, motivo_baja = null
   where id = p_id and tenant_id = app.mi_tenant();

  perform public.devengar_vacaciones(p_id);
  perform app.auditar('empleado.reactivar', 'empleados', p_id::text, null,
    jsonb_build_object('motivo', p_motivo));

  return jsonb_build_object('status','success');
end;
$$;

/* Siguiente número sugerido. Se propone, no se impone: muchas
   empresas traen numeración de su sistema anterior. */
create or replace function public.siguiente_no_empleado()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (max(nullif(regexp_replace(no_empleado, '\D', '', 'g'), ''))::bigint + 1)::text,
    '1')
  from public.empleados
  where tenant_id = app.mi_tenant()
$$;

grant execute on function public.listar_empleados(text,text,uuid,integer,integer) to authenticated;
grant execute on function public.obtener_empleado(uuid)                            to authenticated;
grant execute on function public.crear_empleado(jsonb)                             to authenticated;
grant execute on function public.actualizar_empleado(uuid,jsonb)                   to authenticated;
grant execute on function public.dar_baja_empleado(uuid,date,text)                 to authenticated;
grant execute on function public.reactivar_empleado(uuid,text)                     to authenticated;
grant execute on function public.siguiente_no_empleado()                           to authenticated;