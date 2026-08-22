-- ══ 1. LIMPIEZA ══════════════════════════════════════════════════════════

drop function if exists public.calcular_periodo(uuid);

-- ══ 2. MOTOR: paga_doble ═════════════════════════════════════════════════

create or replace function public.calcular_prenomina_empleado(
  p_periodo_id uuid, p_empleado_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  per public.periodos_nomina;
  e   public.empleados;
  v_sdi jsonb;
  v_sd  numeric;
  v_avisos jsonb := '[]'::jsonb;

  v_trab numeric := 0;
  v_desc numeric := 0;
  v_vac  numeric := 0;
  v_inc  numeric := 0;
  v_pcg  numeric := 0;
  v_psg  numeric := 0;
  v_falt numeric := 0;
  v_ret  integer := 0;
  v_sept_perdido numeric := 0;

  v_hd numeric := 0;
  v_ht numeric := 0;
  v_hx numeric := 0;
  v_fest numeric := 0;
  v_dom  numeric := 0;
  v_dlab numeric := 0;

  v_max_dia numeric;
  v_max_semana numeric;
  v_mover numeric;
  v_grupo_emp uuid;
  v_tiene_turno boolean;

  r record;
  v_id uuid;

  imp_sueldo numeric := 0;
  imp_sept numeric := 0;
  imp_ext numeric := 0;
  imp_fest numeric := 0;
  imp_dom numeric := 0;
  imp_dlab numeric := 0;
  imp_vac numeric := 0;
  imp_pvac numeric := 0;
  imp_inc numeric := 0;
  otras_p numeric := 0;
  otras_d numeric := 0;
  v_tot_p numeric;
  v_tot_d numeric;
begin
  select * into per from public.periodos_nomina
   where id = p_periodo_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Periodo no encontrado'; end if;
  if per.estado = 'cerrado' then
    raise exception 'El periodo esta cerrado. Reabrelo para recalcular.';
  end if;

  select * into e from public.empleados
   where id = p_empleado_id and tenant_id = per.tenant_id;
  if not found then
    return jsonb_build_object('status','error','message','Empleado no encontrado');
  end if;

  select s.grupo_id into v_grupo_emp
    from public.sueldos s
   where s.empleado_id = p_empleado_id
     and s.desde <= per.hasta
     and (s.hasta is null or s.hasta >= per.desde)
   order by s.desde desc
   limit 1;

  if v_grupo_emp is not null and v_grupo_emp <> per.grupo_id then
    return jsonb_build_object('status','error',
      'message','El empleado pertenece a otro grupo de nomina.');
  end if;

  select exists (
    select 1 from public.asignaciones_turno a
     where a.empleado_id = p_empleado_id
       and a.desde <= per.hasta
       and (a.hasta is null or a.hasta >= per.desde))
    into v_tiene_turno;

  if not v_tiene_turno then
    v_avisos := v_avisos || jsonb_build_array(jsonb_build_object(
      'tipo','sin_turno',
      'texto','El empleado no tiene turno asignado en este periodo. No se '
           || 'calculan descansos trabajados (art. 73) ni se prorratean '
           || 'incidencias por turno. Asignale un turno y recalcula.'));
  end if;

  v_sdi := public.sdi_empleado(p_empleado_id, per.hasta);
  if v_sdi ? 'error' then
    return jsonb_build_object('status','error','message', v_sdi->>'error');
  end if;
  v_sd := (v_sdi->>'sueldo_diario')::numeric;

  if (v_sdi->>'excede_tope')::boolean then
    v_avisos := v_avisos || jsonb_build_array(jsonb_build_object(
      'tipo','sdi_tope',
      'texto','El SDI excede el tope de 25 UMAs. Para IMSS se cotiza topado.'));
  end if;

  v_max_dia    := app.param('extras_max_dia', per.hasta);
  v_max_semana := app.param('extras_max_semana', per.hasta);

  -- ── Recorrido de jornadas ──
  for r in
    select j.fecha_laboral, j.estatus, j.minutos_extra, j.minutos_retardo,
           extract(dow from j.fecha_laboral) as dow,
           public.turno_del_dia(p_empleado_id, j.fecha_laboral) is null
             as sin_turno,
           -- El festivo y su bandera de pago se leen juntos: un dia no
           -- laborable sin prima no debe entrar como festivo del art. 75.
           (select n.paga_doble
              from public.dias_no_laborables n
             where n.tenant_id = e.tenant_id
               and n.fecha = j.fecha_laboral
               and (n.centro_id is null or n.centro_id = e.centro_id)
             order by n.centro_id nulls last
             limit 1) as festivo_paga
      from public.jornadas j
     where j.empleado_id = p_empleado_id
       and j.fecha_laboral between per.desde and per.hasta
     order by j.fecha_laboral
  loop
    if r.estatus in ('completa','retardo') then
      v_trab := v_trab + 1;
      if r.estatus = 'retardo' then v_ret := v_ret + 1; end if;

      -- Festivo con prima: art. 75, salario doble adicional
      if r.festivo_paga is true then
        v_fest := v_fest + 1;

      -- Descanso trabajado: art. 73, salario doble adicional. Aplica tambien
      -- a un dia no laborable sin prima que cayo en su descanso: el 73 no es
      -- opcional para el patron.
      elsif r.sin_turno and v_tiene_turno then
        v_dlab := v_dlab + 1;
      end if;

      -- Prima dominical: art. 71
      if r.dow = 0 then v_dom := v_dom + 1; end if;

      -- Tiempo extra
      if coalesce(r.minutos_extra,0) > 0 then
        declare v_h numeric := round(r.minutos_extra / 60.0, 2);
        begin
          if v_h <= v_max_dia then
            v_hd := v_hd + v_h;
          else
            v_hd := v_hd + v_max_dia;
            v_ht := v_ht + (v_h - v_max_dia);
          end if;
        end;
      end if;

    elsif r.estatus = 'descanso' then
      v_desc := v_desc + 1;
    elsif r.estatus = 'festivo' then
      v_desc := v_desc + 1;
    elsif r.estatus = 'falta' then
      v_falt := v_falt + 1;
    elsif r.estatus = 'incompleta' then
      v_trab := v_trab + 1;
      v_avisos := v_avisos || jsonb_build_array(jsonb_build_object(
        'tipo','jornada_incompleta',
        'texto','Jornada sin checada de salida el ' || r.fecha_laboral
             || '. Se contó como trabajada.'));
    end if;
  end loop;

  -- ── Incidencias aprobadas del periodo ──
  for r in
    select t.clave, t.con_goce, t.descuenta_vac,
           i.fecha_inicio, i.fecha_fin
      from public.incidencias i
      join public.tipos_incidencia t on t.id = i.tipo_id
     where i.empleado_id = p_empleado_id
       and i.estatus = 'aprobada'
       and daterange(i.fecha_inicio, i.fecha_fin, '[]')
        && daterange(per.desde, per.hasta, '[]')
  loop
    declare
      v_ini date := greatest(r.fecha_inicio, per.desde);
      v_fin date := least(r.fecha_fin, per.hasta);
      v_n numeric;
    begin
      if v_tiene_turno then
        select count(*) into v_n
          from generate_series(v_ini, v_fin, '1 day') d
         where public.turno_del_dia(p_empleado_id, d::date) is not null;
      else
        v_n := (v_fin - v_ini) + 1;
      end if;

      if r.descuenta_vac then
        v_vac := v_vac + v_n;
      elsif r.clave = 'INC' then
        v_inc := v_inc + v_n;
      elsif r.con_goce then
        v_pcg := v_pcg + v_n;
      else
        v_psg := v_psg + v_n;
      end if;

      v_trab := greatest(0, v_trab - v_n);
    end;
  end loop;

  if v_falt > 0 then
    v_sept_perdido := round(v_falt / 6.0, 2);
  end if;

  -- ── Tope del art. 66, por semana calendario ──
  select coalesce(sum(greatest(0, sem_h - v_max_semana)), 0)
    into v_hx
    from (
      select date_trunc('week', j.fecha_laboral) as sem,
             sum(coalesce(j.minutos_extra,0)) / 60.0 as sem_h
        from public.jornadas j
       where j.empleado_id = p_empleado_id
         and j.fecha_laboral between per.desde and per.hasta
       group by 1
    ) w;

  if v_hx > 0 then
    v_mover := least(v_hd, v_hx);
    v_hd := v_hd - v_mover;
    v_ht := v_ht + v_mover;

    v_avisos := v_avisos || jsonb_build_array(jsonb_build_object(
      'tipo','extras_tope',
      'texto','El tiempo extra excede el máximo del artículo 66 de la LFT '
           || '(3 horas diarias, 3 veces por semana). Excedente pagado al '
           || 'triple: ' || round(v_hx,2) || ' horas.'));
  end if;

  -- ── IMPORTES ──
  imp_sueldo := round((v_trab + v_desc + v_pcg) * v_sd, 2);
  imp_sept   := round(-1 * v_sept_perdido * v_sd, 2);
  imp_ext    := round((v_hd * 2 + v_ht * 3) * (v_sd / 8.0), 2);
  imp_fest   := round(v_fest * v_sd * 2, 2);
  imp_dlab   := round(v_dlab * v_sd * 2, 2);
  imp_dom    := round(v_dom * v_sd * app.param('prima_dominical', per.hasta), 2);
  imp_vac    := round(v_vac * v_sd, 2);
  imp_pvac   := round(v_vac * v_sd * app.param('prima_vacacional', per.hasta), 2);

  imp_inc := 0;
  if v_inc > 0 then
    v_avisos := v_avisos || jsonb_build_array(jsonb_build_object(
      'tipo','incapacidad',
      'texto', v_inc || ' día(s) de incapacidad. El subsidio lo paga el IMSS: '
            || 'verifica si la política de la empresa cubre los primeros 3 días '
            || 'en enfermedad general.'));
  end if;

  if v_dlab > 0 then
    v_avisos := v_avisos || jsonb_build_array(jsonb_build_object(
      'tipo','descanso_trabajado',
      'texto', v_dlab || ' día(s) de descanso trabajados. Se pagó el salario '
            || 'doble adicional (art. 73 LFT).'));
  end if;

  select coalesce(sum(case when c.naturaleza = 'percepcion' then m.importe else 0 end),0),
         coalesce(sum(case when c.naturaleza = 'deduccion'  then m.importe else 0 end),0)
    into otras_p, otras_d
    from public.movimientos_nomina m
    join public.conceptos_nomina c on c.id = m.concepto_id
   where m.periodo_id = p_periodo_id and m.empleado_id = p_empleado_id;

  v_tot_p := imp_sueldo + imp_ext + imp_fest + imp_dlab + imp_dom
           + imp_vac + imp_pvac + imp_inc + otras_p;
  v_tot_d := abs(imp_sept) + otras_d;

  if v_sd is null or v_sd = 0 then
    return jsonb_build_object('status','error','message','Sin sueldo vigente');
  end if;

  insert into public.prenomina (
    tenant_id, periodo_id, empleado_id,
    sueldo_diario, sdi, factor,
    dias_periodo, dias_trabajados, dias_descanso, dias_vacaciones,
    dias_incapacidad, dias_permiso_cg, dias_permiso_sg, faltas, septimo_perdido,
    horas_dobles, horas_triples, horas_excedidas,
    dias_festivo_lab, dias_descanso_lab, domingos_lab, retardos,
    importe_sueldo, importe_septimo, importe_extras, importe_festivos,
    importe_descanso_lab, importe_prima_dom, importe_vacaciones,
    importe_prima_vac, importe_incapacidad,
    otras_percepciones, otras_deducciones,
    total_percepciones, total_deducciones, neto_estimado,
    avisos, calculado_en
  ) values (
    e.tenant_id, p_periodo_id, p_empleado_id,
    v_sd, (v_sdi->>'sdi')::numeric, (v_sdi->>'factor')::numeric,
    per.dias, v_trab, v_desc, v_vac,
    v_inc, v_pcg, v_psg, v_falt, v_sept_perdido,
    v_hd, v_ht, v_hx,
    v_fest, v_dlab, v_dom, v_ret,
    imp_sueldo, imp_sept, imp_ext, imp_fest,
    imp_dlab, imp_dom, imp_vac, imp_pvac, imp_inc,
    otras_p, otras_d,
    v_tot_p, v_tot_d, v_tot_p - v_tot_d,
    v_avisos, now()
  )
  on conflict (periodo_id, empleado_id) do update set
    sueldo_diario = excluded.sueldo_diario,
    sdi = excluded.sdi, factor = excluded.factor,
    dias_periodo = excluded.dias_periodo,
    dias_trabajados = excluded.dias_trabajados,
    dias_descanso = excluded.dias_descanso,
    dias_vacaciones = excluded.dias_vacaciones,
    dias_incapacidad = excluded.dias_incapacidad,
    dias_permiso_cg = excluded.dias_permiso_cg,
    dias_permiso_sg = excluded.dias_permiso_sg,
    faltas = excluded.faltas,
    septimo_perdido = excluded.septimo_perdido,
    horas_dobles = excluded.horas_dobles,
    horas_triples = excluded.horas_triples,
    horas_excedidas = excluded.horas_excedidas,
    dias_festivo_lab = excluded.dias_festivo_lab,
    dias_descanso_lab = excluded.dias_descanso_lab,
    domingos_lab = excluded.domingos_lab,
    retardos = excluded.retardos,
    importe_sueldo = excluded.importe_sueldo,
    importe_septimo = excluded.importe_septimo,
    importe_extras = excluded.importe_extras,
    importe_festivos = excluded.importe_festivos,
    importe_descanso_lab = excluded.importe_descanso_lab,
    importe_prima_dom = excluded.importe_prima_dom,
    importe_vacaciones = excluded.importe_vacaciones,
    importe_prima_vac = excluded.importe_prima_vac,
    importe_incapacidad = excluded.importe_incapacidad,
    otras_percepciones = excluded.otras_percepciones,
    otras_deducciones = excluded.otras_deducciones,
    total_percepciones = excluded.total_percepciones,
    total_deducciones = excluded.total_deducciones,
    neto_estimado = excluded.neto_estimado,
    avisos = excluded.avisos,
    calculado_en = now()
  returning id into v_id;

  return jsonb_build_object('status','success','id',v_id,
    'neto', v_tot_p - v_tot_d, 'avisos', v_avisos);
end;
$$;

-- ══ 3. TABLERO: GRUPOS Y PERIODOS ════════════════════════════════════════

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
    'grupos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', g.id, 'clave', g.clave, 'nombre', g.nombre,
               'frecuencia', g.frecuencia, 'dias_para_pago', g.dias_para_pago,
               'activo', g.activo,
               'empleados', (
                 select count(*) from public.sueldos s
                  where s.grupo_id = g.id
                    and (s.hasta is null or s.hasta >= current_date))
             ) order by g.clave), '[]'::jsonb)
        from public.grupos_nomina g where g.tenant_id = v_t),
    'periodos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'numero', p.numero, 'anio', p.anio,
               'desde', p.desde, 'hasta', p.hasta, 'dias', p.dias,
               'fecha_pago', p.fecha_pago, 'estado', p.estado,
               'grupo', g.nombre, 'grupo_clave', g.clave,
               'frecuencia', p.frecuencia,
               'empleados', t.n, 'neto', t.neto,
               'percepciones', t.perc, 'deducciones', t.ded,
               'con_avisos', t.avisos
             ) order by p.desde desc), '[]'::jsonb)
        from public.periodos_nomina p
        join public.grupos_nomina g on g.id = p.grupo_id
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

-- ══ 4. CREAR PERIODO ═════════════════════════════════════════════════════

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

-- ══ 5. DETALLE DE UN PERIODO ═════════════════════════════════════════════

create or replace function public.nomina_detalle(p_periodo_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  per public.periodos_nomina;
  g public.grupos_nomina;
begin
  select * into per from public.periodos_nomina
   where id = p_periodo_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Periodo no encontrado'; end if;

  select * into g from public.grupos_nomina where id = per.grupo_id;

  return jsonb_build_object(
    'es_admin', app.es_admin(),
    'periodo', jsonb_build_object(
      'id', per.id, 'numero', per.numero, 'anio', per.anio,
      'desde', per.desde, 'hasta', per.hasta, 'dias', per.dias,
      'fecha_pago', per.fecha_pago, 'estado', per.estado,
      'frecuencia', per.frecuencia, 'nota', per.nota,
      'grupo', g.nombre, 'grupo_clave', g.clave, 'grupo_id', g.id,
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
      -- Empleados del grupo que aun no tienen renglon: el hueco mas caro de
      -- una nomina es la persona que nadie noto que faltaba.
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

-- ══ 6. ESTADO DEL PERIODO ════════════════════════════════════════════════

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

-- ══ 7. MOVIMIENTOS ═══════════════════════════════════════════════════════

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

create or replace function public.nomina_mov_borrar(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  m public.movimientos_nomina;
  per public.periodos_nomina;
begin
  if not app.es_admin() then
    raise exception 'Solo RH o administracion puede borrar movimientos.';
  end if;

  select * into m from public.movimientos_nomina
   where id = p_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Movimiento no encontrado'; end if;

  select * into per from public.periodos_nomina where id = m.periodo_id;
  if per.estado = 'cerrado' then
    raise exception 'El periodo esta cerrado. Reabrelo para modificar.';
  end if;

  delete from public.movimientos_nomina where id = p_id;

  perform app.auditar('movimiento_borrado','movimientos_nomina', p_id::text,
    jsonb_build_object('empleado', m.empleado_id, 'importe', m.importe), null);

  return jsonb_build_object('status','success',
    'recalculo', public.calcular_prenomina_empleado(m.periodo_id, m.empleado_id));
end;
$$;

-- ══ 8. GRUPOS ════════════════════════════════════════════════════════════

create or replace function public.nomina_grupo_guardar(
  p_clave text, p_nombre text, p_frecuencia text,
  p_dias_para_pago integer default 5, p_activo boolean default true,
  p_centro_id uuid default null, p_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
  if not app.es_admin() then
    raise exception 'Solo RH o administracion puede administrar grupos.';
  end if;

  if p_id is null then
    insert into public.grupos_nomina (
      tenant_id, clave, nombre, frecuencia, centro_id, dias_para_pago, activo)
    values (app.mi_tenant(), upper(trim(p_clave)), trim(p_nombre),
            p_frecuencia::frecuencia_nomina, p_centro_id,
            coalesce(p_dias_para_pago,5), coalesce(p_activo,true))
    returning id into v_id;
  else
    -- La frecuencia NO se edita: cambiarla dejaria periodos ya calculados
    -- con una periodicidad que no corresponde a sus fechas.
    update public.grupos_nomina
       set nombre = trim(p_nombre), dias_para_pago = coalesce(p_dias_para_pago,5),
           activo = coalesce(p_activo,true), centro_id = p_centro_id
     where id = p_id and tenant_id = app.mi_tenant()
    returning id into v_id;
    if v_id is null then raise exception 'Grupo no encontrado'; end if;
  end if;

  perform app.auditar('grupo_nomina','grupos_nomina', v_id::text, null,
    jsonb_build_object('clave', p_clave, 'nombre', p_nombre));

  return jsonb_build_object('status','success','id',v_id);
end;
$$;

-- ══ 9. SUELDOS CON VIGENCIA ══════════════════════════════════════════════

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
  v_id uuid;
  v_min numeric;
begin
  if not app.es_admin() then
    raise exception 'Solo RH o administracion puede registrar sueldos.';
  end if;
  if not exists (select 1 from public.empleados
                  where id = p_empleado_id and tenant_id = v_t) then
    raise exception 'Empleado no encontrado';
  end if;
  if p_grupo_id is not null and not exists (
       select 1 from public.grupos_nomina where id = p_grupo_id and tenant_id = v_t) then
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

-- ══ 10. PERMISOS ═════════════════════════════════════════════════════════

do $$
declare f text;
begin
  for f in
    select format('%s(%s)', p.proname, pg_get_function_identity_arguments(p.oid))
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('nomina_periodos','nomina_periodo_crear','nomina_detalle',
                         'nomina_periodo_estado','nomina_mov_guardar',
                         'nomina_mov_borrar','nomina_grupo_guardar',
                         'nomina_sueldo_guardar','calcular_prenomina_periodo',
                         'calcular_prenomina_empleado')
  loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;