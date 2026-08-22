-- ══ 1. GRUPOS DE NÓMINA ══════════════════════════════════════════════════

create table if not exists public.grupos_nomina (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  clave           text not null,
  nombre          text not null,
  frecuencia      frecuencia_nomina not null,
  centro_id       uuid references public.centros_trabajo(id) on delete set null,
  dias_para_pago  integer not null default 5,
  activo          boolean not null default true,
  creado_en       timestamptz not null default now(),
  unique (tenant_id, clave)
);

create index if not exists grupos_nomina_tenant_idx
  on public.grupos_nomina (tenant_id) where activo;

alter table public.grupos_nomina enable row level security;

drop policy if exists grupos_leer on public.grupos_nomina;
create policy grupos_leer on public.grupos_nomina
  for select using (tenant_id = app.mi_tenant());

drop policy if exists grupos_escribir on public.grupos_nomina;
create policy grupos_escribir on public.grupos_nomina
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

-- Los grants son manuales: el proyecto tiene desactivado el auto-expose.
grant select, insert, update, delete on public.grupos_nomina to authenticated;
grant all on public.grupos_nomina to service_role;

-- ══ 2. GRUPO POR DEFECTO Y BACKFILL ══════════════════════════════════════

insert into public.grupos_nomina (tenant_id, clave, nombre, frecuencia)
select t.id, 'QNA', 'Quincenal general', 'quincenal'
from public.tenants t
where not exists (
  select 1 from public.grupos_nomina g
   where g.tenant_id = t.id and g.clave = 'QNA');

-- Un grupo por cada frecuencia que ya exista en periodos
insert into public.grupos_nomina (tenant_id, clave, nombre, frecuencia)
select distinct p.tenant_id,
       upper(left(p.frecuencia::text, 3)),
       initcap(p.frecuencia::text) || ' general',
       p.frecuencia
from public.periodos_nomina p
where not exists (
  select 1 from public.grupos_nomina g
   where g.tenant_id = p.tenant_id and g.frecuencia = p.frecuencia);

-- ══ 3. PERIODOS APUNTAN A UN GRUPO ═══════════════════════════════════════

alter table public.periodos_nomina
  add column if not exists grupo_id uuid references public.grupos_nomina(id);

update public.periodos_nomina p
   set grupo_id = g.id
  from public.grupos_nomina g
 where g.tenant_id = p.tenant_id
   and g.frecuencia = p.frecuencia
   and p.grupo_id is null;

alter table public.periodos_nomina alter column grupo_id set not null;

alter table public.periodos_nomina
  drop constraint if exists periodos_nomina_tenant_id_centro_id_frecuencia_anio_numero_key;

alter table public.periodos_nomina
  drop constraint if exists periodos_nomina_grupo_anio_numero_key;
alter table public.periodos_nomina
  add constraint periodos_nomina_grupo_anio_numero_key
  unique (tenant_id, grupo_id, anio, numero);

-- La frecuencia del periodo ya no se captura: se hereda del grupo y no puede
-- divergir.
create or replace function app.sync_frecuencia_periodo()
returns trigger language plpgsql security definer
set search_path = public, pg_temp as $fn$
begin
  select g.frecuencia, coalesce(new.centro_id, g.centro_id)
    into new.frecuencia, new.centro_id
    from public.grupos_nomina g
   where g.id = new.grupo_id;
  return new;
end;
$fn$;

drop trigger if exists trg_sync_frecuencia_periodo on public.periodos_nomina;
create trigger trg_sync_frecuencia_periodo
  before insert or update of grupo_id on public.periodos_nomina
  for each row execute function app.sync_frecuencia_periodo();

-- ══ 4. EMPLEADO → GRUPO (historizado en sueldos) ═════════════════════════

alter table public.sueldos
  add column if not exists grupo_id uuid references public.grupos_nomina(id);

create index if not exists sueldos_grupo_idx on public.sueldos (grupo_id);

update public.sueldos s
   set grupo_id = g.id
  from public.grupos_nomina g
 where g.tenant_id = s.tenant_id
   and g.clave = 'QNA'
   and s.grupo_id is null;

-- ══ 5. COLUMNAS NUEVAS DE PRENÓMINA ══════════════════════════════════════

alter table public.prenomina
  add column if not exists dias_descanso_lab   numeric not null default 0,
  add column if not exists importe_descanso_lab numeric not null default 0;

-- ══ 6. MOTOR CORREGIDO ═══════════════════════════════════════════════════

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
  v_sd  numeric;                 -- sueldo diario
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

  v_hd numeric := 0;             -- horas dobles
  v_ht numeric := 0;             -- triples
  v_hx numeric := 0;             -- excedidas sobre el tope semanal
  v_fest numeric := 0;
  v_dom  numeric := 0;
  v_dlab numeric := 0;           -- días de descanso trabajados

  v_max_dia numeric;
  v_max_semana numeric;
  v_mover numeric;
  v_grupo_emp uuid;

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

  -- El empleado debe pertenecer al grupo de nomina del periodo. Un sueldo sin
  -- grupo se acepta (compatibilidad con capturas viejas).
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
           exists(select 1 from public.dias_no_laborables n
                   where n.tenant_id = e.tenant_id
                     and n.fecha = j.fecha_laboral
                     and (n.centro_id is null or n.centro_id = e.centro_id))
             as es_festivo
      from public.jornadas j
     where j.empleado_id = p_empleado_id
       and j.fecha_laboral between per.desde and per.hasta
     order by j.fecha_laboral
  loop
    if r.estatus in ('completa','retardo') then
      v_trab := v_trab + 1;
      if r.estatus = 'retardo' then v_ret := v_ret + 1; end if;

      -- Festivo trabajado: art. 75, se paga el triple (el ordinario ya va en
      -- dias trabajados, aqui van los 2 extra)
      if r.es_festivo then
        v_fest := v_fest + 1;

      -- Descanso trabajado: art. 73, salario doble ADICIONAL. Solo cuando no
      -- es festivo: el art. 75 ya cubre ese caso y pagarlo dos veces seria un
      -- error de nomina, no una prestacion.
      elsif r.sin_turno then
        v_dlab := v_dlab + 1;
      end if;

      -- Prima dominical: art. 71, 25% adicional por trabajar en domingo
      if r.dow = 0 then v_dom := v_dom + 1; end if;

      -- Tiempo extra
      if coalesce(r.minutos_extra,0) > 0 then
        declare v_h numeric := round(r.minutos_extra / 60.0, 2);
        begin
          -- Hasta 3 horas al dia son dobles; el exceso diario es triple
          -- (art. 67)
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
      -- Se cuenta como trabajado pero se avisa: descontarle el dia a alguien
      -- porque falto su checada de salida seria castigarlo por una falla del
      -- sistema.
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
      -- Solo los dias que caian en su turno: contar naturales inflaria las
      -- vacaciones con los descansos.
      select count(*) into v_n
        from generate_series(v_ini, v_fin, '1 day') d
       where public.turno_del_dia(p_empleado_id, d::date) is not null;

      if r.descuenta_vac then
        v_vac := v_vac + v_n;
      elsif r.clave = 'INC' then
        v_inc := v_inc + v_n;
      elsif r.con_goce then
        v_pcg := v_pcg + v_n;
      else
        v_psg := v_psg + v_n;
      end if;

      -- Los dias de incidencia no son dias trabajados
      v_trab := greatest(0, v_trab - v_n);
    end;
  end loop;

  -- ── Séptimo día proporcional ──
  -- Art. 73: el descanso se paga si se trabajo la semana completa. Una falta
  -- descuenta el dia mas su parte del septimo, que es lo que en la practica se
  -- llama "falta doble".
  if v_falt > 0 then
    v_sept_perdido := round(v_falt / 6.0, 2);
  end if;

  -- ── Tope del art. 66, por semana calendario ──
  -- Prorratear el tope sobre los dias del periodo dejaba pasar excedentes
  -- reales. El limite es semanal, se mide semana por semana.
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
    -- Art. 68: el tiempo que excede el limite legal se paga al triple. Las
    -- horas no se recortan nunca: esconder horas trabajadas es exactamente
    -- como nace una demanda laboral.
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
  imp_sept   := round(-1 * v_sept_perdido * v_sd, 2);  -- negativo: es descuento

  -- Doble = 2x el valor de la hora; triple = 3x. La hora se estima sobre
  -- jornada de 8 h.
  imp_ext := round((v_hd * 2 + v_ht * 3) * (v_sd / 8.0), 2);

  -- Festivo trabajado: 200% ADICIONAL (art. 75)
  imp_fest := round(v_fest * v_sd * 2, 2);

  -- Descanso trabajado: salario doble ADICIONAL (art. 73)
  imp_dlab := round(v_dlab * v_sd * 2, 2);

  -- Prima dominical: 25% del salario diario por domingo
  imp_dom := round(v_dom * v_sd * app.param('prima_dominical', per.hasta), 2);

  imp_vac  := round(v_vac * v_sd, 2);
  imp_pvac := round(v_vac * v_sd * app.param('prima_vacacional', per.hasta), 2);

  -- Incapacidad: la paga el IMSS, no el patron. Se registra en cero con aviso,
  -- porque el subsidio no va en la nomina.
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

  -- ── Movimientos capturados ──
  select coalesce(sum(case when c.naturaleza = 'percepcion' then m.importe else 0 end),0),
         coalesce(sum(case when c.naturaleza = 'deduccion'  then m.importe else 0 end),0)
    into otras_p, otras_d
    from public.movimientos_nomina m
    join public.conceptos_nomina c on c.id = m.concepto_id
   where m.periodo_id = p_periodo_id and m.empleado_id = p_empleado_id;

  v_tot_p := imp_sueldo + imp_ext + imp_fest + imp_dlab + imp_dom
           + imp_vac + imp_pvac + imp_inc + otras_p;
  v_tot_d := abs(imp_sept) + otras_d;

  -- Sin sueldo registrado no hay nada que calcular
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

-- ══ 7. CÁLCULO MASIVO POR PERIODO ════════════════════════════════════════

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
  if per.estado = 'cerrado' then
    raise exception 'El periodo esta cerrado. Reabrelo para recalcular.';
  end if;

  for r in
    select e.id, e.nombre_completo
      from public.empleados e
     where e.tenant_id = per.tenant_id
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
      -- Un empleado con datos rotos no debe tumbar la nomina de los otros 86.
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

revoke all on function public.calcular_prenomina_periodo(uuid) from public;
grant execute on function public.calcular_prenomina_periodo(uuid) to authenticated;