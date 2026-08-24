-- ════════════════════════════════════════════════════════════════════════
-- RHoo! · Alcance en los RPCs que faltaron
--
-- La migración anterior se aplicó parcialmente: quedaron con filtro
-- listar_empleados, nomina_periodos y estructura_empresarial. Aquí van los
-- 11 restantes.
--
-- Este archivo es SOLO SQL: se puede pegar completo en el SQL Editor o en
-- una migración nueva sin quitarle nada.
-- ════════════════════════════════════════════════════════════════════════

-- ── 1. obtener_empleado ─────────────────────────────────────────────────
-- Un expediente incluye el sueldo, así que abrir uno ajeno es la fuga más
-- grave: basta con adivinar un id.

create or replace function public.obtener_empleado(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  e public.empleados;
  v_yo uuid;
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

  -- Y el alcance: un RH limitado no debe abrir el expediente de otra empresa
  -- aunque su rol se lo permita en general. Su propio expediente y el de su
  -- equipo siguen visibles.
  if app.es_admin() and not app.alcanza_razon(e.razon_id)
     and e.id <> v_yo and e.jefe_id is distinct from v_yo then
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
$$;

-- ── 2. nomina_detalle ───────────────────────────────────────────────────

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
$$;

-- ── 3. calcular_prenomina_periodo ───────────────────────────────────────
-- Sin este filtro, un RH limitado podria calcular la nomina de otra empresa
-- mandando el id del periodo a mano.

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
$$;

-- ── 4. nomina_periodo_estado ────────────────────────────────────────────

create or replace function public.nomina_periodo_estado(
  p_periodo_id uuid, p_estado text, p_nota text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
$$;

-- ── 5. nomina_periodo_crear ─────────────────────────────────────────────

create or replace function public.nomina_periodo_crear(
  p_grupo_id uuid, p_desde date, p_hasta date,
  p_fecha_pago date default null, p_numero integer default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
$$;

-- ── 6. nomina_mov_guardar ───────────────────────────────────────────────

create or replace function public.nomina_mov_guardar(
  p_periodo_id uuid, p_empleado_id uuid, p_concepto_id uuid,
  p_importe numeric, p_cantidad numeric default null,
  p_nota text default null, p_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
$$;

-- ── 7. nomina_sueldo_historial ──────────────────────────────────────────

create or replace function public.nomina_sueldo_historial(p_empleado_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
$$;

-- ── 8. nomina_sueldo_guardar ────────────────────────────────────────────

create or replace function public.nomina_sueldo_guardar(
  p_empleado_id uuid, p_sueldo_diario numeric, p_grupo_id uuid,
  p_desde date default current_date,
  p_tipo text default 'fijo',
  p_dias_aguinaldo integer default 15,
  p_prima_vac_pct numeric default 0.25,
  p_otras_prestaciones numeric default 0,
  p_zona_frontera boolean default false,
  p_banco text default null, p_clabe text default null,
  p_motivo text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
$$;

-- ── 9. razon_guardar ────────────────────────────────────────────────────
-- Sin esto, un RH limitado podria editar el RFC de una empresa ajena.

create or replace function public.razon_guardar(
  p_grupo_id uuid, p_clave text, p_razon_social text,
  p_nombre_comercial text default null, p_rfc text default null,
  p_registro_patronal text default null, p_regimen_fiscal text default null,
  p_codigo_postal text default null, p_domicilio text default null,
  p_representante_legal text default null, p_activo boolean default true,
  p_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
$$;

-- ── 10. primas_historial ────────────────────────────────────────────────

create or replace function public.primas_historial(p_razon_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
$$;

-- ── 11. prima_guardar ───────────────────────────────────────────────────

create or replace function public.prima_guardar(
  p_razon_id uuid, p_prima numeric, p_vigente_de date,
  p_clase text default null, p_fraccion text default null,
  p_nota text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
$$;
-- ── 12. listar_empleados ────────────────────────────────────────────────

create or replace function public.listar_empleados(
  p_buscar text default null, p_estatus text default 'Activo',
  p_centro_id uuid default null, p_limite integer default 50,
  p_desde integer default 0)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
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
$$;