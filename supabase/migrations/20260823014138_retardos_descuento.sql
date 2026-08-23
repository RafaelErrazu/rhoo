-- ══ 1. COLUMNAS NUEVAS ═══════════════════════════════════════════════════

alter table public.prenomina
  add column if not exists minutos_retardo    numeric not null default 0,
  add column if not exists faltas_por_retardo numeric not null default 0,
  add column if not exists importe_retardos   numeric not null default 0;

-- ══ 2. MOTOR ═════════════════════════════════════════════════════════════

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
  v_min_ret numeric := 0;
  v_sept_perdido numeric := 0;

  -- Reglas de retardos, configurables por tenant
  v_ret_para_falta integer;
  v_desc_tiempo boolean;
  v_faltas_ret numeric := 0;
  v_ret_sobran integer := 0;

  v_jinc numeric := 0;
  v_huerfanos numeric;

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
  imp_ret numeric := 0;
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

  v_max_dia        := app.param('extras_max_dia', per.hasta);
  v_max_semana     := app.param('extras_max_semana', per.hasta);
  v_ret_para_falta := app.cfg_int('retardos_para_falta', per.tenant_id);
  v_desc_tiempo    := app.cfg_bool('descuenta_tiempo_retardo', per.tenant_id);

  -- ── Recorrido de jornadas ──
  for r in
    select j.fecha_laboral, j.estatus, j.minutos_extra, j.minutos_retardo,
           extract(dow from j.fecha_laboral) as dow,
           public.turno_del_dia(p_empleado_id, j.fecha_laboral) is null
             as sin_turno,
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
      if r.estatus = 'retardo' then
        v_ret := v_ret + 1;
        v_min_ret := v_min_ret + coalesce(r.minutos_retardo, 0);
      end if;

      if r.festivo_paga is true then
        v_fest := v_fest + 1;
      elsif r.sin_turno and v_tiene_turno then
        v_dlab := v_dlab + 1;
      end if;

      if r.dow = 0 then v_dom := v_dom + 1; end if;

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

    elsif r.estatus = 'incidencia' then
      -- La asistencia marca toda la ausencia, incluidos descansos y festivos
      -- que caen dentro. Para el pago eso no aplica: el descanso semanal se
      -- paga siempre, este o no de vacaciones.
      if r.sin_turno or r.festivo_paga is not null then
        v_desc := v_desc + 1;
      else
        v_jinc := v_jinc + 1;
      end if;

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
      v_quitar numeric;
    begin
      v_n := app.dias_consumibles(p_empleado_id, v_ini, v_fin);

      if r.descuenta_vac then
        v_vac := v_vac + v_n;
      elsif r.clave = 'INC' then
        v_inc := v_inc + v_n;
      elsif r.con_goce then
        v_pcg := v_pcg + v_n;
      else
        v_psg := v_psg + v_n;
      end if;

      select count(*) into v_quitar
        from generate_series(v_ini, v_fin, '1 day') d
        join public.jornadas j
          on j.empleado_id = p_empleado_id
         and j.fecha_laboral = d::date
       where j.estatus in ('completa','retardo','incompleta');

      v_trab := greatest(0, v_trab - v_quitar);
    end;
  end loop;

  v_huerfanos := v_jinc - (v_vac + v_inc + v_pcg + v_psg);
  if v_huerfanos > 0 then
    v_avisos := v_avisos || jsonb_build_array(jsonb_build_object(
      'tipo','incidencia_sin_respaldo',
      'texto', v_huerfanos || ' día(s) aparecen como incidencia en asistencia '
            || 'pero no tienen una incidencia aprobada que los respalde. No se '
            || 'estan pagando: revisa la asistencia de este periodo.'));
  end if;

  if v_falt > 0 then
    v_sept_perdido := round(v_falt / 6.0, 2);
  end if;

  -- ── RETARDOS ─────────────────────────────────────────────────────────
  -- Dos politicas posibles y NUNCA las dos juntas: cobrar el dia completo y
  -- ademas los minutos es sancionar dos veces el mismo hecho.
  if v_ret > 0 then
    if coalesce(v_ret_para_falta, 0) > 0 then
      v_faltas_ret := floor(v_ret::numeric / v_ret_para_falta);
      v_ret_sobran := v_ret - (v_faltas_ret * v_ret_para_falta)::integer;

      if v_faltas_ret > 0 then
        -- Va como deduccion y no como menos dias trabajados: asi el recibo
        -- dice de donde salio el descuento en lugar de esconderlo.
        -- Y NO afecta el septimo dia: una falta real no se trabajo, un
        -- retardo si. Descontar tambien el septimo seria una sancion sobre
        -- otra sancion.
        imp_ret := round(v_faltas_ret * v_sd, 2);

        v_avisos := v_avisos || jsonb_build_array(jsonb_build_object(
          'tipo','retardos_falta',
          'texto', v_ret || ' retardo(s) en el periodo. Con la política de '
                || v_ret_para_falta || ' retardos por día de descuento, se '
                || 'descontaron ' || v_faltas_ret || ' día(s)'
                || case when v_ret_sobran > 0
                     then '. Quedan ' || v_ret_sobran || ' retardo(s) sin llegar al tope'
                     else '' end || '.'));
      end if;

      if v_desc_tiempo then
        v_avisos := v_avisos || jsonb_build_array(jsonb_build_object(
          'tipo','retardos_doble_politica',
          'texto','La configuración tiene activadas las dos políticas de '
               || 'retardos a la vez. Se aplicó solo la de acumulación: '
               || 'descontar el día completo y además los minutos sería '
               || 'sancionar dos veces lo mismo. Revisa Configuración.'));
      end if;

    elsif v_desc_tiempo and v_min_ret > 0 then
      -- Minutos exactos, proporcionales al sueldo sobre jornada de 8 h.
      imp_ret := round((v_min_ret / 60.0) * (v_sd / 8.0), 2);

      v_avisos := v_avisos || jsonb_build_array(jsonb_build_object(
        'tipo','retardos_tiempo',
        'texto', v_ret || ' retardo(s) con ' || round(v_min_ret) || ' minuto(s) '
              || 'acumulados. Se descontó el tiempo efectivo.'));
    end if;
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
  v_tot_d := abs(imp_sept) + imp_ret + otras_d;

  if v_sd is null or v_sd = 0 then
    return jsonb_build_object('status','error','message','Sin sueldo vigente');
  end if;

  insert into public.prenomina (
    tenant_id, periodo_id, empleado_id,
    sueldo_diario, sdi, factor,
    dias_periodo, dias_trabajados, dias_descanso, dias_vacaciones,
    dias_incapacidad, dias_permiso_cg, dias_permiso_sg, faltas, septimo_perdido,
    horas_dobles, horas_triples, horas_excedidas,
    dias_festivo_lab, dias_descanso_lab, domingos_lab,
    retardos, minutos_retardo, faltas_por_retardo,
    importe_sueldo, importe_septimo, importe_extras, importe_festivos,
    importe_descanso_lab, importe_prima_dom, importe_vacaciones,
    importe_prima_vac, importe_incapacidad, importe_retardos,
    otras_percepciones, otras_deducciones,
    total_percepciones, total_deducciones, neto_estimado,
    avisos, calculado_en
  ) values (
    e.tenant_id, p_periodo_id, p_empleado_id,
    v_sd, (v_sdi->>'sdi')::numeric, (v_sdi->>'factor')::numeric,
    per.dias, v_trab, v_desc, v_vac,
    v_inc, v_pcg, v_psg, v_falt, v_sept_perdido,
    v_hd, v_ht, v_hx,
    v_fest, v_dlab, v_dom,
    v_ret, v_min_ret, v_faltas_ret,
    imp_sueldo, imp_sept, imp_ext, imp_fest,
    imp_dlab, imp_dom, imp_vac, imp_pvac, imp_inc, imp_ret,
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
    minutos_retardo = excluded.minutos_retardo,
    faltas_por_retardo = excluded.faltas_por_retardo,
    importe_sueldo = excluded.importe_sueldo,
    importe_septimo = excluded.importe_septimo,
    importe_extras = excluded.importe_extras,
    importe_festivos = excluded.importe_festivos,
    importe_descanso_lab = excluded.importe_descanso_lab,
    importe_prima_dom = excluded.importe_prima_dom,
    importe_vacaciones = excluded.importe_vacaciones,
    importe_prima_vac = excluded.importe_prima_vac,
    importe_incapacidad = excluded.importe_incapacidad,
    importe_retardos = excluded.importe_retardos,
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

-- ══ 3. EL DETALLE DEVUELVE LOS DATOS NUEVOS ══════════════════════════════

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
    'reglas', jsonb_build_object(
      'retardos_para_falta', app.cfg_int('retardos_para_falta', per.tenant_id),
      'descuenta_tiempo_retardo', app.cfg_bool('descuenta_tiempo_retardo', per.tenant_id)),
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