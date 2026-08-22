-- ═══════════════════════════════════════════════════════════
--  RHoo! · Prenómina · parámetros, periodos y motor
-- ═══════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────
--  PARÁMETROS CON VIGENCIA
--
--  Con vigencia y no un valor unico: recalcular la nomina de
--  marzo debe usar la UMA de marzo, no la de hoy. Un parametro
--  sin historia hace que las nominas viejas cambien solas.
-- ─────────────────────────────────────────────────────────────
create table public.parametros_fiscales (
  id          uuid primary key default gen_random_uuid(),
  clave       text not null,
  valor       numeric(14,4) not null,
  vigente_de  date not null,
  vigente_a   date,
  nota        text,
  creado_en   timestamptz not null default now(),

  unique (clave, vigente_de)
);

create index param_clave_idx on public.parametros_fiscales (clave, vigente_de desc);

-- Valores 2026. Son publicos y globales, no por tenant.
insert into public.parametros_fiscales (clave, valor, vigente_de, nota) values
  ('uma_diaria',        113.14,  '2026-02-01','UMA diaria, INEGI'),
  ('uma_mensual',      3439.46,  '2026-02-01','UMA mensual'),
  ('uma_anual',       41273.52,  '2026-02-01','UMA anual'),
  ('salario_minimo',    278.80,  '2026-01-01','General'),
  ('salario_minimo_znf',419.88,  '2026-01-01','Zona Libre Frontera Norte'),
  ('umi',                108.57, '2026-01-01','Unidad Mixta Infonavit'),
  ('dias_aguinaldo',      15,    '2026-01-01','Minimo LFT art. 87'),
  ('prima_vacacional',    0.25,  '2026-01-01','Minimo LFT art. 80'),
  ('prima_dominical',     0.25,  '2026-01-01','LFT art. 71'),
  ('tope_cotizacion_umas',25,    '2026-01-01','Tope de SBC en UMAs'),
  ('extras_max_dia',       3,    '2026-01-01','LFT art. 66'),
  ('extras_max_semana',    9,    '2026-01-01','LFT art. 66, 3 dias x 3 horas')
on conflict (clave, vigente_de) do nothing;

alter table public.parametros_fiscales enable row level security;
create policy param_leer on public.parametros_fiscales for select using (true);
create policy param_escribir on public.parametros_fiscales
  for all using (app.es_proveedor()) with check (app.es_proveedor());
grant select on public.parametros_fiscales to authenticated, anon;

/* Lee un parámetro a una fecha dada. */
create or replace function app.param(p_clave text, p_fecha date default current_date)
returns numeric
language sql
stable
as $$
  select valor from public.parametros_fiscales
  where clave = p_clave
    and vigente_de <= p_fecha
    and (vigente_a is null or vigente_a >= p_fecha)
  order by vigente_de desc
  limit 1
$$;

-- ─────────────────────────────────────────────────────────────
--  DATOS DE SUELDO POR EMPLEADO
--
--  En tabla aparte con vigencia, no como columna de `empleados`:
--  un aumento no debe reescribir el historial, y la nomina de
--  hace dos meses tiene que poder recalcularse con el sueldo que
--  la persona tenia entonces.
-- ─────────────────────────────────────────────────────────────
create type public.tipo_salario as enum ('fijo','variable','mixto');

create table public.sueldos (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  empleado_id  uuid not null references public.empleados(id) on delete cascade,

  sueldo_diario numeric(12,2) not null check (sueldo_diario > 0),
  tipo         public.tipo_salario not null default 'fijo',

  -- Prestaciones sobre las que se integra el SDI. Se guardan por
  -- empleado porque un contrato puede dar mas que la ley.
  dias_aguinaldo   integer not null default 15,
  prima_vac_pct    numeric(5,4) not null default 0.25,

  -- Otras prestaciones que integran (vales, fondo de ahorro,
  -- bonos fijos) como monto diario
  otras_prestaciones numeric(12,2) not null default 0,

  zona_frontera boolean not null default false,
  banco        text,
  clabe        text,

  desde        date not null default current_date,
  hasta        date,
  motivo       text,
  creado_por   uuid references public.perfiles(id),
  creado_en    timestamptz not null default now(),

  constraint sueldo_rango check (hasta is null or hasta >= desde)
);

create index sueldos_emp_idx on public.sueldos (tenant_id, empleado_id, desde desc);

-- Sin traslapes: dos sueldos vigentes el mismo dia hacen que el
-- calculo dependa del orden de lectura.
create extension if not exists btree_gist;
alter table public.sueldos
  add constraint sueldos_sin_traslape
  exclude using gist (
    empleado_id with =,
    daterange(desde, coalesce(hasta,'infinity'::date), '[]') with &&
  );

/* Factor de integración · art. 27 LSS.
   (365 + días de aguinaldo + días de vacaciones × prima) / 365 */
create or replace function public.factor_integracion(
  p_dias_aguinaldo integer,
  p_dias_vacaciones integer,
  p_prima_pct numeric
)
returns numeric
language sql
immutable
as $$
  select round(
    (365 + p_dias_aguinaldo + (p_dias_vacaciones * p_prima_pct)) / 365.0
  , 6)
$$;

/* SDI de un empleado a una fecha.
   Los dias de vacaciones vienen de la LFT segun su antiguedad:
   el factor sube con los anios de servicio, y por eso el SDI
   debe recalcularse en cada aniversario. */
create or replace function public.sdi_empleado(
  p_empleado_id uuid,
  p_fecha date default current_date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  e       public.empleados;
  s       public.sueldos;
  v_anios integer;
  v_dias  integer;
  v_fi    numeric;
  v_sdi   numeric;
  v_tope  numeric;
begin
  select * into e from public.empleados where id = p_empleado_id;
  if not found then return jsonb_build_object('error','Empleado no encontrado'); end if;

  select * into s from public.sueldos
   where empleado_id = p_empleado_id
     and desde <= p_fecha
     and (hasta is null or hasta >= p_fecha)
   limit 1;

  if not found then
    return jsonb_build_object('error','El empleado no tiene sueldo registrado');
  end if;

  v_anios := greatest(1, extract(year from age(p_fecha, e.fecha_ingreso))::integer);
  v_dias  := public.dias_vacaciones_lft(v_anios);
  v_fi    := public.factor_integracion(s.dias_aguinaldo, v_dias, s.prima_vac_pct);
  v_sdi   := round((s.sueldo_diario + s.otras_prestaciones) * v_fi, 2);

  -- Tope de 25 UMAs (art. 28 LSS)
  v_tope := app.param('tope_cotizacion_umas', p_fecha) * app.param('uma_diaria', p_fecha);

  return jsonb_build_object(
    'sueldo_diario', s.sueldo_diario,
    'otras_prestaciones', s.otras_prestaciones,
    'dias_aguinaldo', s.dias_aguinaldo,
    'dias_vacaciones', v_dias,
    'prima_vac_pct', s.prima_vac_pct,
    'factor', v_fi,
    'sdi', v_sdi,
    'sdi_topado', least(v_sdi, round(v_tope,2)),
    'tope', round(v_tope,2),
    'excede_tope', v_sdi > v_tope,
    'tipo', s.tipo,
    'anios_servicio', v_anios);
end;
$$;

-- ─────────────────────────────────────────────────────────────
--  PERIODOS DE NÓMINA
-- ─────────────────────────────────────────────────────────────
create type public.frecuencia_nomina as enum
  ('semanal','catorcenal','quincenal','mensual','decenal');

create table public.periodos_nomina (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  centro_id    uuid references public.centros_trabajo(id) on delete set null,

  frecuencia   public.frecuencia_nomina not null,
  numero       integer not null,
  anio         integer not null,

  desde        date not null,
  hasta        date not null,
  dias         integer not null,
  fecha_pago   date,

  estado       text not null default 'abierto'
               check (estado in ('abierto','revision','cerrado')),

  -- Se congela al cerrar: sin esto, un reporte impreso ayer no
  -- coincide con el mismo reporte impreso hoy.
  cerrado_en   timestamptz,
  cerrado_por  uuid references public.perfiles(id),

  nota         text,
  creado_en    timestamptz not null default now(),

  unique (tenant_id, centro_id, frecuencia, anio, numero),
  constraint periodo_rango check (hasta >= desde)
);

create index periodos_tenant_idx
  on public.periodos_nomina (tenant_id, anio desc, numero desc);

-- ─────────────────────────────────────────────────────────────
--  RENGLONES: un empleado en un periodo
-- ─────────────────────────────────────────────────────────────
create table public.prenomina (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  periodo_id   uuid not null references public.periodos_nomina(id) on delete cascade,
  empleado_id  uuid not null references public.empleados(id) on delete cascade,

  -- Se congelan al calcular: si manana cambia el sueldo o la
  -- antiguedad, este renglon no debe moverse.
  sueldo_diario numeric(12,2) not null,
  sdi          numeric(12,2) not null,
  factor       numeric(10,6),

  -- Días del periodo
  dias_periodo    integer not null,
  dias_trabajados numeric(6,2) not null default 0,
  dias_descanso   numeric(6,2) not null default 0,
  dias_vacaciones numeric(6,2) not null default 0,
  dias_incapacidad numeric(6,2) not null default 0,
  dias_permiso_cg numeric(6,2) not null default 0,   -- con goce
  dias_permiso_sg numeric(6,2) not null default 0,   -- sin goce
  faltas          numeric(6,2) not null default 0,
  septimo_perdido numeric(6,2) not null default 0,

  -- Tiempo extra
  horas_dobles    numeric(6,2) not null default 0,
  horas_triples   numeric(6,2) not null default 0,
  horas_excedidas numeric(6,2) not null default 0,   -- sobre el tope legal

  -- Días especiales
  dias_festivo_lab numeric(6,2) not null default 0,
  domingos_lab     numeric(6,2) not null default 0,
  retardos         integer not null default 0,

  -- Importes
  importe_sueldo      numeric(14,2) not null default 0,
  importe_septimo     numeric(14,2) not null default 0,
  importe_extras      numeric(14,2) not null default 0,
  importe_festivos    numeric(14,2) not null default 0,
  importe_prima_dom   numeric(14,2) not null default 0,
  importe_vacaciones  numeric(14,2) not null default 0,
  importe_prima_vac   numeric(14,2) not null default 0,
  importe_incapacidad numeric(14,2) not null default 0,

  otras_percepciones  numeric(14,2) not null default 0,
  otras_deducciones   numeric(14,2) not null default 0,

  total_percepciones  numeric(14,2) not null default 0,
  total_deducciones   numeric(14,2) not null default 0,
  -- Neto ANTES de impuestos: esta prenomina no calcula ISR ni
  -- cuotas. Se llama "estimado" a proposito para que nadie lo
  -- confunda con el neto real del recibo.
  neto_estimado       numeric(14,2) not null default 0,

  avisos       jsonb not null default '[]'::jsonb,
  nota         text,
  calculado_en timestamptz,

  unique (periodo_id, empleado_id)
);

create index prenom_periodo_idx on public.prenomina (periodo_id);

/* Conceptos capturables: bonos, préstamos, comisiones. */
create table public.conceptos_nomina (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  clave       text not null,
  nombre      text not null,
  naturaleza  text not null check (naturaleza in ('percepcion','deduccion')),
  -- Si integra al SDI: un bono de productividad fijo si, un
  -- prestamo no. Determina el SBC variable.
  integra_sdi boolean not null default false,
  gravable    boolean not null default true,
  activo      boolean not null default true,
  orden       integer not null default 100,

  unique (tenant_id, clave)
);

create table public.movimientos_nomina (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  periodo_id   uuid not null references public.periodos_nomina(id) on delete cascade,
  empleado_id  uuid not null references public.empleados(id) on delete cascade,
  concepto_id  uuid not null references public.conceptos_nomina(id) on delete restrict,

  cantidad     numeric(12,2),
  importe      numeric(14,2) not null,
  nota         text,
  creado_por   uuid references public.perfiles(id),
  creado_en    timestamptz not null default now()
);

create index movs_periodo_idx
  on public.movimientos_nomina (tenant_id, periodo_id, empleado_id);

-- ═══════════════════════════════════════════════════════════
--  EL MOTOR
-- ═══════════════════════════════════════════════════════════

/* Calcula un renglón de prenómina.
   Lee las jornadas ya calculadas por el motor de asistencia y
   las incidencias aprobadas: la prenomina no reinterpreta la
   asistencia, la consume. */
create or replace function public.calcular_prenomina_empleado(
  p_periodo_id  uuid,
  p_empleado_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  per     public.periodos_nomina;
  e       public.empleados;
  v_sdi   jsonb;
  v_sd    numeric;          -- sueldo diario
  v_avisos jsonb := '[]'::jsonb;

  v_trab  numeric := 0;
  v_desc  numeric := 0;
  v_vac   numeric := 0;
  v_inc   numeric := 0;
  v_pcg   numeric := 0;
  v_psg   numeric := 0;
  v_falt  numeric := 0;
  v_ret   integer := 0;
  v_sept_perdido numeric := 0;

  v_hd    numeric := 0;     -- horas dobles
  v_ht    numeric := 0;     -- triples
  v_hx    numeric := 0;     -- excedidas sobre el tope
  v_fest  numeric := 0;
  v_dom   numeric := 0;

  v_max_dia    numeric;
  v_max_semana numeric;

  r       record;
  v_id    uuid;

  imp_sueldo numeric := 0;
  imp_sept   numeric := 0;
  imp_ext    numeric := 0;
  imp_fest   numeric := 0;
  imp_dom    numeric := 0;
  imp_vac    numeric := 0;
  imp_pvac   numeric := 0;
  imp_inc    numeric := 0;
  otras_p    numeric := 0;
  otras_d    numeric := 0;
  v_tot_p    numeric;
  v_tot_d    numeric;
begin
  select * into per from public.periodos_nomina
   where id = p_periodo_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Periodo no encontrado'; end if;
  if per.estado = 'cerrado' then
    raise exception 'El periodo esta cerrado. Reabrelo para recalcular.';
  end if;

  select * into e from public.empleados where id = p_empleado_id;

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
           exists(select 1 from public.dias_no_laborables n
                  where n.tenant_id = e.tenant_id
                    and n.fecha = j.fecha_laboral
                    and (n.centro_id is null or n.centro_id = e.centro_id)) as es_festivo
    from public.jornadas j
    where j.empleado_id = p_empleado_id
      and j.fecha_laboral between per.desde and per.hasta
    order by j.fecha_laboral
  loop
    if r.estatus in ('completa','retardo') then
      v_trab := v_trab + 1;
      if r.estatus = 'retardo' then v_ret := v_ret + 1; end if;

      -- Festivo trabajado: art. 75, se paga el triple (el
      -- ordinario ya va en dias trabajados, aqui van los 2 extra)
      if r.es_festivo then v_fest := v_fest + 1; end if;

      -- Prima dominical: art. 71, 25% adicional por trabajar en
      -- domingo cuando no es su descanso habitual
      if r.dow = 0 then v_dom := v_dom + 1; end if;

      -- Tiempo extra
      if coalesce(r.minutos_extra,0) > 0 then
        declare v_h numeric := round(r.minutos_extra / 60.0, 2);
        begin
          -- Hasta 3 horas al dia son dobles; el exceso diario es
          -- triple (art. 67)
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
      -- Se cuenta como trabajado pero se avisa: descontarle el
      -- dia a alguien porque falto su checada de salida seria
      -- castigarlo por una falla del sistema.
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
      v_n   numeric;
    begin
      -- Solo los dias que caian en su turno: contar naturales
      -- inflaria las vacaciones con los descansos.
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
  -- Art. 73: el descanso se paga si se trabajo la semana
  -- completa. Una falta descuenta el dia mas su parte del
  -- septimo, que es lo que en la practica se llama "falta doble".
  if v_falt > 0 then
    v_sept_perdido := round(v_falt / 6.0, 2);
  end if;

  -- ── Aviso de topes del art. 66 ──
  -- Se AVISA, no se recorta: recortar esconderia horas que el
  -- trabajador si trabajo, y el reclamo despues es peor.
  if (v_hd + v_ht) > v_max_semana * (per.dias / 7.0) then
    v_hx := (v_hd + v_ht) - (v_max_semana * (per.dias / 7.0));
    v_avisos := v_avisos || jsonb_build_array(jsonb_build_object(
      'tipo','extras_tope',
      'texto','El tiempo extra excede el máximo del artículo 66 de la LFT '
              || '(3 horas diarias, 3 veces por semana). Excedente: '
              || round(v_hx,2) || ' horas.'));
  end if;

  -- ── IMPORTES ──
  imp_sueldo := round((v_trab + v_desc + v_pcg) * v_sd, 2);
  imp_sept   := round(-1 * v_sept_perdido * v_sd, 2);   -- negativo: es descuento

  -- Doble = 2x el valor de la hora; triple = 3x.
  -- La hora se estima sobre jornada de 8 h.
  imp_ext := round((v_hd * 2 + v_ht * 3) * (v_sd / 8.0), 2);

  -- Festivo trabajado: 200% ADICIONAL (art. 75)
  imp_fest := round(v_fest * v_sd * 2, 2);

  -- Prima dominical: 25% del salario diario por domingo
  imp_dom := round(v_dom * v_sd * app.param('prima_dominical', per.hasta), 2);

  imp_vac  := round(v_vac * v_sd, 2);
  imp_pvac := round(v_vac * v_sd * app.param('prima_vacacional', per.hasta), 2);

  -- Incapacidad: la paga el IMSS, no el patron. Se registra en
  -- cero con aviso, porque el subsidio no va en la nomina.
  imp_inc := 0;
  if v_inc > 0 then
    v_avisos := v_avisos || jsonb_build_array(jsonb_build_object(
      'tipo','incapacidad',
      'texto', v_inc || ' día(s) de incapacidad. El subsidio lo paga el IMSS: '
               || 'verifica si la política de la empresa cubre los primeros 3 días '
               || 'en enfermedad general.'));
  end if;

  -- ── Movimientos capturados ──
  select coalesce(sum(case when c.naturaleza = 'percepcion' then m.importe else 0 end),0),
         coalesce(sum(case when c.naturaleza = 'deduccion'  then m.importe else 0 end),0)
    into otras_p, otras_d
  from public.movimientos_nomina m
  join public.conceptos_nomina c on c.id = m.concepto_id
  where m.periodo_id = p_periodo_id and m.empleado_id = p_empleado_id;

  v_tot_p := imp_sueldo + imp_ext + imp_fest + imp_dom + imp_vac + imp_pvac
             + imp_inc + otras_p;
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
    dias_festivo_lab, domingos_lab, retardos,
    importe_sueldo, importe_septimo, importe_extras, importe_festivos,
    importe_prima_dom, importe_vacaciones, importe_prima_vac, importe_incapacidad,
    otras_percepciones, otras_deducciones,
    total_percepciones, total_deducciones, neto_estimado,
    avisos, calculado_en
  ) values (
    e.tenant_id, p_periodo_id, p_empleado_id,
    v_sd, (v_sdi->>'sdi')::numeric, (v_sdi->>'factor')::numeric,
    per.dias, v_trab, v_desc, v_vac,
    v_inc, v_pcg, v_psg, v_falt, v_sept_perdido,
    v_hd, v_ht, v_hx,
    v_fest, v_dom, v_ret,
    imp_sueldo, imp_sept, imp_ext, imp_fest,
    imp_dom, imp_vac, imp_pvac, imp_inc,
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
    domingos_lab = excluded.domingos_lab,
    retardos = excluded.retardos,
    importe_sueldo = excluded.importe_sueldo,
    importe_septimo = excluded.importe_septimo,
    importe_extras = excluded.importe_extras,
    importe_festivos = excluded.importe_festivos,
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

/* Calcula el periodo completo. */
create or replace function public.calcular_periodo(p_periodo_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  per   public.periodos_nomina;
  r     record;
  v_ok  integer := 0;
  v_err jsonb := '[]'::jsonb;
  v_res jsonb;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  select * into per from public.periodos_nomina
   where id = p_periodo_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Periodo no encontrado'; end if;

  for r in
    select e.id, e.nombre_completo
    from public.empleados e
    where e.tenant_id = app.mi_tenant()
      and (per.centro_id is null or e.centro_id = per.centro_id)
      -- Quien se dio de baja antes del periodo no entra; quien se
      -- fue a media quincena si, con sus dias trabajados.
      and (e.estatus = 'Activo'
           or (e.fecha_baja is not null and e.fecha_baja >= per.desde))
  loop
    v_res := public.calcular_prenomina_empleado(p_periodo_id, r.id);
    if v_res->>'status' = 'success' then
      v_ok := v_ok + 1;
    else
      -- Los que fallan se listan, no se ocultan: un empleado sin
      -- sueldo registrado que no aparece en la nomina es un
      -- problema que se descubre el dia del pago.
      v_err := v_err || jsonb_build_array(jsonb_build_object(
        'empleado', r.nombre_completo, 'motivo', v_res->>'message'));
    end if;
  end loop;

  perform app.auditar('prenomina.calcular', 'periodos_nomina', p_periodo_id::text,
    null, jsonb_build_object('calculados', v_ok, 'errores', jsonb_array_length(v_err)));

  return jsonb_build_object('status','success',
    'calculados', v_ok, 'errores', v_err);
end;
$$;

-- ─────────────────────────────────────────────────────────────
--  RLS
-- ─────────────────────────────────────────────────────────────
alter table public.sueldos            enable row level security;
alter table public.periodos_nomina    enable row level security;
alter table public.prenomina          enable row level security;
alter table public.conceptos_nomina   enable row level security;
alter table public.movimientos_nomina enable row level security;

/* El sueldo es el dato más sensible del sistema: ni el jefe
   directo lo ve. Solo RH y el propio interesado. */
create policy sueldos_leer on public.sueldos
  for select using (
    tenant_id = app.mi_tenant() and (
      app.es_admin()
      or empleado_id = (select empleado_id from public.perfiles where id = auth.uid()))
  );
create policy sueldos_escribir on public.sueldos
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

create policy periodos_leer on public.periodos_nomina
  for select using (tenant_id = app.mi_tenant() and app.es_admin());
create policy periodos_escribir on public.periodos_nomina
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

create policy prenom_leer on public.prenomina
  for select using (
    tenant_id = app.mi_tenant() and (
      app.es_admin()
      or empleado_id = (select empleado_id from public.perfiles where id = auth.uid()))
  );
create policy prenom_escribir on public.prenomina
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

create policy conceptos_leer on public.conceptos_nomina
  for select using (tenant_id = app.mi_tenant());
create policy conceptos_escribir on public.conceptos_nomina
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

create policy movs_leer on public.movimientos_nomina
  for select using (tenant_id = app.mi_tenant() and app.es_admin());
create policy movs_escribir on public.movimientos_nomina
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

create policy zz_prov_sueldos on public.sueldos
  for all using (app.es_proveedor()) with check (app.es_proveedor());
create policy zz_prov_periodos on public.periodos_nomina
  for all using (app.es_proveedor()) with check (app.es_proveedor());
create policy zz_prov_prenom on public.prenomina
  for all using (app.es_proveedor()) with check (app.es_proveedor());

grant select, insert, update, delete on
  public.sueldos, public.periodos_nomina, public.prenomina,
  public.conceptos_nomina, public.movimientos_nomina
  to authenticated;

grant execute on function app.param(text,date)                              to authenticated;
grant execute on function public.factor_integracion(integer,integer,numeric) to authenticated;
grant execute on function public.sdi_empleado(uuid,date)                     to authenticated;
grant execute on function public.calcular_prenomina_empleado(uuid,uuid)      to authenticated;
grant execute on function public.calcular_periodo(uuid)                      to authenticated;

-- ─────────────────────────────────────────────────────────────
--  CONCEPTOS BASE por tenant
-- ─────────────────────────────────────────────────────────────
do $$
declare t record;
begin
  for t in select id from public.tenants loop
    insert into public.conceptos_nomina
      (tenant_id, clave, nombre, naturaleza, integra_sdi, gravable, orden)
    values
      (t.id,'BONO','Bono de productividad','percepcion', true,  true,  10),
      (t.id,'COMIS','Comisiones','percepcion',           true,  true,  20),
      (t.id,'VALES','Vales de despensa','percepcion',    false, false, 30),
      (t.id,'AHORRO','Fondo de ahorro','percepcion',     false, false, 40),
      (t.id,'PREMIO','Premio de asistencia','percepcion',true,  true,  50),
      (t.id,'OTROSP','Otras percepciones','percepcion',  false, true,  90),
      (t.id,'PREST','Préstamo personal','deduccion',     false, false, 110),
      (t.id,'ANTIC','Anticipo de sueldo','deduccion',    false, false, 120),
      (t.id,'FONACOT','Fonacot','deduccion',             false, false, 130),
      (t.id,'INFONAVIT','Crédito Infonavit','deduccion', false, false, 140),
      (t.id,'PENSION','Pensión alimenticia','deduccion', false, false, 150),
      (t.id,'AHORROD','Fondo de ahorro (retención)','deduccion', false, false, 160),
      (t.id,'SINDICATO','Cuota sindical','deduccion',    false, false, 170),
      (t.id,'OTROSD','Otras deducciones','deduccion',    false, false, 190)
    on conflict (tenant_id, clave) do nothing;
  end loop;
end $$;