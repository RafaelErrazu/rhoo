-- ═══════════════════════════════════════════════════════════
--  RHoo! · Motor de jornadas + checadores
-- ═══════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────
--  MÉTODO DE CHECADA POR EMPLEADO
-- ─────────────────────────────────────────────────────────────
create type public.metodo_checada as enum
  ('dispositivo','movil','ambos','ninguno');

alter table public.empleados
  add column metodo_checada public.metodo_checada not null default 'ambos';

comment on column public.empleados.metodo_checada is
  'ninguno = no registra asistencia (REPSE, honorarios, directivos). Se valida en RLS, no en la interfaz.';

-- Coordenadas del centro, para la geocerca
alter table public.centros_trabajo
  add column lat numeric(10,7),
  add column lng numeric(10,7),
  add column radio_m integer not null default 150;

-- ─────────────────────────────────────────────────────────────
--  DISPOSITIVOS (checadores físicos)
--
--  Cada reloj tiene su propia llave. Una llave compartida entre
--  clientes significa que quien saque la llave de un checador
--  puede inyectar checadas en cualquier empresa.
--  Se guarda solo el hash: si alguien lee esta tabla, no obtiene
--  llaves usables.
-- ─────────────────────────────────────────────────────────────
create table public.dispositivos (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  centro_id     uuid not null references public.centros_trabajo(id) on delete cascade,

  nombre        text not null,               -- 'Entrada principal'
  marca         text,                        -- ZKTeco, Anviz, Hikvision
  modelo        text,
  numero_serie  text,

  -- Cómo se comunica. Determina qué se espera de él.
  modo          text not null default 'agente'
                check (modo in ('agente','push','manual')),

  llave_hash    text not null,               -- sha256 de la llave
  llave_pista   text,                        -- ultimos 4, para identificarla

  -- Un reloj sin batería de respaldo se desfasa. Este ajuste
  -- corrige la hora sin tener que tocar el aparato.
  ajuste_minutos integer not null default 0,

  zona_horaria  text not null default 'America/Mexico_City',

  activo        boolean not null default true,
  ultimo_contacto timestamptz,
  ultimo_evento   timestamptz,               -- fecha del ultimo registro recibido

  creado_en     timestamptz not null default now(),
  unique (tenant_id, nombre)
);

create index dispositivos_tenant_idx on public.dispositivos (tenant_id, activo);

comment on column public.dispositivos.ultimo_contacto is
  'Ultima vez que el dispositivo o su agente se comunico. Si lleva horas sin reportar, alguien lo desconecto y nadie se dio cuenta.';

-- ─────────────────────────────────────────────────────────────
--  ENROLAMIENTOS
--
--  El reloj no conoce el UUID del empleado: maneja su propio
--  numero interno (User ID 1, 2, 3...). Sin esta tabla, cambiar
--  un empleado de dispositivo obligaria a reconfigurar el reloj.
--  Y con ella, el mismo dedo puede estar en dos relojes con
--  numeros distintos sin problema.
-- ─────────────────────────────────────────────────────────────
create table public.enrolamientos (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id) on delete cascade,
  dispositivo_id uuid not null references public.dispositivos(id) on delete cascade,
  empleado_id    uuid not null references public.empleados(id) on delete cascade,
  id_en_equipo   text not null,              -- User ID dentro del reloj
  creado_en      timestamptz not null default now(),

  unique (dispositivo_id, id_en_equipo)
);

create index enrol_emp_idx on public.enrolamientos (tenant_id, empleado_id);

-- La checada ahora sabe de dónde vino
alter table public.checadas
  add column dispositivo_id uuid references public.dispositivos(id) on delete set null,
  add column id_externo text;

-- Idempotencia: el agente puede reenviar lo mismo si se cayó la
-- conexión a media carga. Sin esto, cada reintento duplica el
-- día completo de una planta entera.
create unique index checadas_externo_unq
  on public.checadas (dispositivo_id, id_externo)
  where id_externo is not null;

-- ═══════════════════════════════════════════════════════════
--  FECHA LABORAL
--
--  La pieza que hace que el turno nocturno cuadre. Una checada a
--  las 02:00 del martes, para quien entra a las 22:00, pertenece
--  al LUNES. Si se asigna por fecha de calendario, el turno se
--  parte en dos y las horas nunca cierran.
--
--  Regla: si el turno del dia anterior cruza medianoche y la hora
--  de la checada cae dentro de su ventana (mas margen), la
--  checada es del dia anterior.
-- ═══════════════════════════════════════════════════════════
create or replace function app.fecha_laboral_de(
  p_empleado_id uuid,
  p_momento     timestamptz,
  p_zona        text default 'America/Mexico_City'
)
returns date
language plpgsql
stable
as $$
declare
  v_local     timestamp;
  v_dia       date;
  v_ayer      date;
  t_ayer      public.turnos;
  v_hora      time;
  v_margen    interval := interval '4 hours';   -- salidas tardias y extras
begin
  v_local := p_momento at time zone p_zona;
  v_dia   := v_local::date;
  v_ayer  := v_dia - 1;
  v_hora  := v_local::time;

  select t.* into t_ayer
  from public.turnos t
  where t.id = public.turno_del_dia(p_empleado_id, v_ayer);

  -- Si ayer trabajo un turno que cruza medianoche y esta checada
  -- cae antes de su hora de salida (mas margen), es de ayer.
  if found and t_ayer.hora_salida <= t_ayer.hora_entrada then
    if v_hora < (t_ayer.hora_salida + v_margen) then
      return v_ayer;
    end if;
  end if;

  return v_dia;
end;
$$;

-- ═══════════════════════════════════════════════════════════
--  REGISTRAR CHECADA
--
--  Un solo camino de entrada para movil y dispositivo: si cada
--  origen tuviera su propia funcion, las reglas se
--  desincronizarian y una de las dos acabaria sin validar la
--  geocerca.
-- ═══════════════════════════════════════════════════════════
create or replace function public.registrar_checada(
  p_lat         numeric default null,
  p_lng         numeric default null,
  p_precision   numeric default null,
  p_dispositivo text default null,
  p_selfie      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_emp_id  uuid;
  e         public.empleados;
  c         public.centros_trabajo;
  v_fecha   date;
  v_dist    numeric;
  v_id      uuid;
  v_turno   uuid;
begin
  select empleado_id into v_emp_id from public.perfiles where id = auth.uid();
  if v_emp_id is null then
    return jsonb_build_object('status','error',
      'message','Tu usuario no esta ligado a un empleado.');
  end if;

  select * into e from public.empleados where id = v_emp_id;

  if e.estatus <> 'Activo' then
    return jsonb_build_object('status','error',
      'message','Tu registro no esta activo.');
  end if;

  -- El metodo se valida aqui, no en el boton
  if e.metodo_checada = 'ninguno' then
    return jsonb_build_object('status','error',
      'message','Tu puesto no registra asistencia.');
  end if;
  if e.metodo_checada = 'dispositivo' then
    return jsonb_build_object('status','error',
      'message','Debes registrar tu asistencia en el checador de tu centro de trabajo.');
  end if;

  select * into c from public.centros_trabajo where id = e.centro_id;

  -- Geocerca. Se usa la distancia esferica simple: a estas
  -- distancias el error contra una formula geodesica es de
  -- centimetros, y evita depender de PostGIS.
  if app.cfg_bool('geocerca_activa', e.tenant_id)
     and c.lat is not null and p_lat is not null then
    v_dist := 6371000 * acos(
      least(1, greatest(-1,
        sin(radians(c.lat)) * sin(radians(p_lat)) +
        cos(radians(c.lat)) * cos(radians(p_lat)) *
        cos(radians(p_lng) - radians(c.lng))
      ))
    );
    if v_dist > coalesce(c.radio_m, app.cfg_int('geocerca_radio_m', e.tenant_id)) then
      return jsonb_build_object('status','error',
        'message','Estas a ' || round(v_dist) || ' m de tu centro de trabajo. '
                || 'Acercate o pide a RH un registro manual.',
        'distancia', round(v_dist));
    end if;
  end if;

  if app.cfg_bool('requiere_selfie', e.tenant_id) and p_selfie is null then
    return jsonb_build_object('status','error',
      'message','Se requiere fotografia para registrar tu asistencia.');
  end if;

  v_fecha := app.fecha_laboral_de(v_emp_id, now(),
               app.cfg_txt('zona_horaria', e.tenant_id));

  insert into public.checadas
    (tenant_id, empleado_id, momento, fecha_laboral, origen,
     lat, lng, precision_m, dispositivo, selfie_path)
  values
    (e.tenant_id, v_emp_id, now(), v_fecha, 'pwa',
     p_lat, p_lng, p_precision, p_dispositivo, p_selfie)
  returning id into v_id;

  perform public.calcular_jornada(v_emp_id, v_fecha);

  select turno_id into v_turno from public.jornadas
  where empleado_id = v_emp_id and fecha_laboral = v_fecha;

  return jsonb_build_object(
    'status','success',
    'checada_id', v_id,
    'fecha_laboral', v_fecha,
    -- Cuantas checadas lleva hoy: la interfaz decide si el
    -- proximo boton dice "Entrada" o "Salida" con esto.
    'numero', (select count(*) from public.checadas
               where empleado_id = v_emp_id
                 and fecha_laboral = v_fecha and not anulada)
  );
end;
$$;

grant execute on function public.registrar_checada(numeric,numeric,numeric,text,text)
  to authenticated;

-- ═══════════════════════════════════════════════════════════
--  EL MOTOR · checadas → jornada
--
--  Se recalcula desde cero cada vez. Es mas lento que actualizar
--  incrementalmente, pero significa que una correccion de RH o un
--  cambio de configuracion se refleja sin estados intermedios
--  raros. Y a este volumen, la diferencia no se percibe.
-- ═══════════════════════════════════════════════════════════
create or replace function public.calcular_jornada(
  p_empleado_id uuid,
  p_fecha       date
)
returns public.jornadas
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  e            public.empleados;
  t            public.turnos;
  v_turno_id   uuid;
  v_entrada    timestamptz;
  v_salida     timestamptz;
  v_n          integer;
  v_zona       text;
  v_esperada   timestamptz;
  v_retardo    integer := 0;
  v_trab       integer;
  v_extra      integer := 0;
  v_estatus    public.estatus_jornada;
  v_inc        public.incidencias;
  v_festivo    boolean;
  v_tol        integer;
  v_falta_min  integer;
  v_jornada    public.jornadas;
begin
  select * into e from public.empleados where id = p_empleado_id;
  if not found then return null; end if;

  v_zona      := app.cfg_txt('zona_horaria', e.tenant_id);
  v_tol       := app.cfg_int('tolerancia_retardo_min', e.tenant_id);
  v_falta_min := app.cfg_int('minutos_para_falta', e.tenant_id);

  v_turno_id := public.turno_del_dia(p_empleado_id, p_fecha);

  select * into t from public.turnos where id = v_turno_id;

  -- Primera y ultima checada del dia laboral. Se ignora el "tipo"
  -- que reporte el equipo: con el orden basta, y asi un empleado
  -- que oprime "entrada" dos veces no rompe el calculo.
  select min(momento), max(momento), count(*)
    into v_entrada, v_salida, v_n
  from public.checadas
  where empleado_id = p_empleado_id
    and fecha_laboral = p_fecha
    and not anulada;

  -- Con una sola checada no hay salida, hay entrada
  if v_n = 1 then v_salida := null; end if;

  select exists(
    select 1 from public.dias_no_laborables
    where tenant_id = e.tenant_id
      and fecha = p_fecha
      and (centro_id is null or centro_id = e.centro_id)
  ) into v_festivo;

  select * into v_inc
  from public.incidencias
  where empleado_id = p_empleado_id
    and estatus = 'aprobada'
    and p_fecha between fecha_inicio and fecha_fin
  limit 1;

  -- ── Jerarquia de estatus ──
  -- El orden importa: una incidencia aprobada gana sobre una
  -- falta, y un festivo gana sobre un retardo. Si se evaluara al
  -- reves, alguien con incapacidad saldria con faltas.
  if v_inc.id is not null then
    v_estatus := 'incidencia';

  elsif v_festivo then
    v_estatus := 'festivo';

  elsif v_turno_id is null then
    v_estatus := 'descanso';

  elsif v_entrada is null then
    -- Sin checadas en un dia laborable. Solo es falta si el dia
    -- ya paso: marcar falta a las 9 de la manana de hoy seria
    -- acusar a alguien que todavia va en camino.
    v_estatus := case when p_fecha < current_date then 'falta' else 'pendiente' end;

  else
    v_esperada := (p_fecha + t.hora_entrada) at time zone v_zona;
    v_retardo  := greatest(0,
      floor(extract(epoch from (v_entrada - v_esperada)) / 60)::integer);

    if v_retardo > v_falta_min then
      v_estatus := 'falta';
    elsif v_salida is null then
      -- Falta la salida: se respeta la configuracion del cliente
      if app.cfg_txt('checada_faltante', e.tenant_id) = 'asumir_salida'
         and p_fecha < current_date then
        v_salida  := (p_fecha + t.hora_salida) at time zone v_zona
                     + case when public.turno_cruza_medianoche(t.*)
                            then interval '1 day' else interval '0' end;
        v_estatus := case when v_retardo > v_tol then 'retardo' else 'completa' end;
      else
        v_estatus := case when p_fecha < current_date then 'incompleta' else 'pendiente' end;
      end if;
    elsif v_retardo > v_tol then
      v_estatus := 'retardo';
    else
      v_estatus := 'completa';
    end if;
  end if;

  -- ── Minutos trabajados y extras ──
  if v_entrada is not null and v_salida is not null then
    v_trab := floor(extract(epoch from (v_salida - v_entrada)) / 60)::integer;

    if t.id is not null and not t.comida_computa then
      v_trab := greatest(0, v_trab - t.minutos_comida);
    end if;

    -- Extras solo si superan el minimo configurado. En modo
    -- 'autorizacion' NO se generan solas: se registran como
    -- tiempo trabajado y el jefe las autoriza aparte. Contarlas
    -- automaticamente convierte cada cafe de mas en dinero.
    if t.id is not null and app.cfg_txt('extras_modo', e.tenant_id) = 'automatico' then
      v_extra := greatest(0,
        v_trab - round(public.turno_horas(t.*) * 60)::integer);
      if v_extra < app.cfg_int('extras_min_para_contar', e.tenant_id) then
        v_extra := 0;
      end if;
    end if;
  end if;

  insert into public.jornadas
    (tenant_id, empleado_id, fecha_laboral, turno_id,
     entrada, salida, minutos_trabajados, minutos_retardo,
     minutos_extra, estatus, calculado_en)
  values
    (e.tenant_id, p_empleado_id, p_fecha, v_turno_id,
     v_entrada, v_salida, v_trab, v_retardo,
     v_extra, v_estatus, now())
  on conflict (tenant_id, empleado_id, fecha_laboral) do update set
    turno_id           = excluded.turno_id,
    entrada            = excluded.entrada,
    salida             = excluded.salida,
    minutos_trabajados = excluded.minutos_trabajados,
    minutos_retardo    = excluded.minutos_retardo,
    minutos_extra      = excluded.minutos_extra,
    estatus            = excluded.estatus,
    calculado_en       = now()
    -- ajuste_minutos y ajuste_motivo NO se tocan: son de RH y un
    -- recalculo no debe borrar una correccion humana.
  returning * into v_jornada;

  return v_jornada;
end;
$$;

/* Recalcula un rango. Para cierres de nomina y para cuando RH
   cambia un turno con efecto retroactivo. */
create or replace function public.recalcular_jornadas(
  p_desde date,
  p_hasta date,
  p_empleado_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r      record;
  v_dia  date;
  v_n    integer := 0;
begin
  if not app.es_admin() then
    raise exception 'Solo administradores pueden recalcular jornadas';
  end if;

  for r in
    select id from public.empleados
    where tenant_id = app.mi_tenant()
      and (p_empleado_id is null or id = p_empleado_id)
      and estatus = 'Activo'
  loop
    v_dia := p_desde;
    while v_dia <= p_hasta loop
      perform public.calcular_jornada(r.id, v_dia);
      v_n := v_n + 1;
      v_dia := v_dia + 1;
    end loop;
  end loop;

  perform app.auditar('jornadas.recalcular', 'jornadas', null, null,
    jsonb_build_object('desde', p_desde, 'hasta', p_hasta, 'dias', v_n));

  return v_n;
end;
$$;

grant execute on function public.calcular_jornada(uuid,date) to authenticated;
grant execute on function public.recalcular_jornadas(date,date,uuid) to authenticated;

-- Cuando RH aprueba una incidencia, los días afectados se
-- recalculan solos. Sin esto, una incapacidad aprobada dejaría
-- las faltas ya marcadas intactas.
create or replace function app.recalc_por_incidencia()
returns trigger
language plpgsql
as $$
declare v_dia date;
begin
  if new.estatus = 'aprobada'
     and (old.estatus is null or old.estatus <> 'aprobada') then
    v_dia := new.fecha_inicio;
    while v_dia <= new.fecha_fin loop
      perform public.calcular_jornada(new.empleado_id, v_dia);
      v_dia := v_dia + 1;
    end loop;
  end if;
  return new;
end;
$$;

create trigger inc_recalcular
  after insert or update of estatus on public.incidencias
  for each row execute function app.recalc_por_incidencia();

-- ═══════════════════════════════════════════════════════════
--  INGESTA DESDE CHECADOR FÍSICO
--
--  La llama la Edge Function con la service_role, después de
--  validar la llave del dispositivo. No se expone a
--  `authenticated`: un checador no tiene sesión de usuario.
-- ═══════════════════════════════════════════════════════════
create or replace function public.ingerir_checadas(
  p_dispositivo_id uuid,
  p_eventos        jsonb   -- [{ id_en_equipo, momento, id_externo }]
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  d          public.dispositivos;
  ev         jsonb;
  v_emp      uuid;
  v_momento  timestamptz;
  v_fecha    date;
  v_ok       integer := 0;
  v_dup      integer := 0;
  v_sin      integer := 0;
  v_afect    jsonb := '[]'::jsonb;
begin
  select * into d from public.dispositivos where id = p_dispositivo_id and activo;
  if not found then
    return jsonb_build_object('status','error','message','Dispositivo no encontrado o inactivo');
  end if;

  for ev in select * from jsonb_array_elements(p_eventos) loop
    select empleado_id into v_emp
    from public.enrolamientos
    where dispositivo_id = d.id
      and id_en_equipo = (ev->>'id_en_equipo');

    -- Un dedo sin enrolar NO se descarta en silencio: se cuenta y
    -- se reporta. Alguien checando sin registro es un empleado que
    -- va a reclamar su día y no habrá evidencia.
    if v_emp is null then
      v_sin := v_sin + 1;
      continue;
    end if;

    -- El ajuste corrige relojes desfasados sin tocar el aparato
    v_momento := (ev->>'momento')::timestamptz
                 + (d.ajuste_minutos || ' minutes')::interval;

    v_fecha := app.fecha_laboral_de(v_emp, v_momento, d.zona_horaria);

    begin
      insert into public.checadas
        (tenant_id, empleado_id, momento, fecha_laboral, origen,
         dispositivo_id, id_externo)
      values
        (d.tenant_id, v_emp, v_momento, v_fecha, 'biometrico',
         d.id, ev->>'id_externo');
      v_ok := v_ok + 1;
      v_afect := v_afect || jsonb_build_object('e', v_emp, 'f', v_fecha);
    exception when unique_violation then
      -- Reenvío del agente: ya estaba. No es un error.
      v_dup := v_dup + 1;
    end;
  end loop;

  -- Se recalcula una vez por empleado-día, no por checada
  perform public.calcular_jornada(
    (x->>'e')::uuid, (x->>'f')::date)
  from (select distinct x from jsonb_array_elements(v_afect) x) s;

  update public.dispositivos
     set ultimo_contacto = now(),
         ultimo_evento = greatest(coalesce(ultimo_evento, 'epoch'::timestamptz), now())
   where id = d.id;

  return jsonb_build_object(
    'status','success',
    'insertadas', v_ok, 'duplicadas', v_dup, 'sin_enrolar', v_sin
  );
end;
$$;

revoke all on function public.ingerir_checadas(uuid,jsonb) from public, anon, authenticated;

-- ═══════════════════════════════════════════════════════════
--  RLS de las tablas nuevas
-- ═══════════════════════════════════════════════════════════
alter table public.dispositivos   enable row level security;
alter table public.enrolamientos  enable row level security;

create policy disp_leer on public.dispositivos
  for select using (tenant_id = app.mi_tenant() and app.es_admin());
create policy disp_escribir on public.dispositivos
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());
create policy zz_proveedor_dispositivos on public.dispositivos
  for all using (app.es_proveedor()) with check (app.es_proveedor());

create policy enrol_leer on public.enrolamientos
  for select using (tenant_id = app.mi_tenant() and app.es_admin());
create policy enrol_escribir on public.enrolamientos
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());
create policy zz_proveedor_enrolamientos on public.enrolamientos
  for all using (app.es_proveedor()) with check (app.es_proveedor());

grant select, insert, update, delete
  on public.dispositivos, public.enrolamientos to authenticated;