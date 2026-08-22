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

  -- Días que la asistencia ya marcó como incidencia. Sirven para detectar
  -- descuadres entre lo que dice asistencia y lo que hay aprobado.
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

      -- Descanso trabajado: art. 73
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
    elsif r.estatus = 'incidencia' then
      -- La asistencia ya marco el dia. No suma a trabajados: lo clasifica el
      -- recorrido de incidencias, que sabe si fue vacacion, incapacidad o
      -- permiso. Aqui solo se cuenta para cuadrar despues.
      v_jinc := v_jinc + 1;
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
      v_n numeric;        -- dias de la incidencia que caen en su turno
      v_quitar numeric;   -- de esos, los que se habian contado como trabajados
    begin
      -- Cuantos dias cuenta la incidencia. Con turno asignado, solo los dias
      -- laborables segun su turno: contar naturales inflaria las vacaciones
      -- con los descansos. Sin turno se cuentan naturales, porque filtrar por
      -- un turno inexistente daria cero y le borraria las vacaciones.
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

      -- Solo se descuenta lo que de verdad se habia sumado. Si la asistencia
      -- ya marco esas jornadas como 'incidencia', nunca entraron a trabajados
      -- y restarlas otra vez le quitaba al empleado el doble de dias: era el
      -- bug que dejaba a alguien con 3 dias pagados de 13.
      select count(*) into v_quitar
        from generate_series(v_ini, v_fin, '1 day') d
        join public.jornadas j
          on j.empleado_id = p_empleado_id
         and j.fecha_laboral = d::date
       where j.estatus in ('completa','retardo','incompleta');

      v_trab := greatest(0, v_trab - v_quitar);
    end;
  end loop;

  -- Jornadas marcadas como incidencia sin respaldo aprobado. Pasa cuando una
  -- solicitud se rechaza o se cancela despues de que el trigger ya movio la
  -- jornada: esos dias no se pagan a nadie y antes desaparecian en silencio.
  v_huerfanos := v_jinc - (v_vac + v_inc + v_pcg + v_psg);
  if v_huerfanos > 0 then
    v_avisos := v_avisos || jsonb_build_array(jsonb_build_object(
      'tipo','incidencia_sin_respaldo',
      'texto', v_huerfanos || ' día(s) aparecen como incidencia en asistencia '
            || 'pero no tienen una incidencia aprobada que los respalde. No se '
            || 'estan pagando: revisa la asistencia de este periodo.'));
  end if;

  -- ── Séptimo día proporcional (art. 73) ──
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