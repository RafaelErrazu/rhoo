-- ═══════════════════════════════════════════════════════════
--  RHoo! · Migración 02 · Tiempo y asistencia
--  Turnos con rotación, checadas, jornadas calculadas,
--  incidencias y vacaciones conforme a la LFT.
-- ═══════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────
--  CALENDARIO · días festivos oficiales y descansos de empresa
--
--  Los festivos del art. 74 son federales, pero cada cliente
--  agrega los suyos (aniversario, puentes). Se guardan por
--  tenant para que un cliente no vea los del otro, con
--  `oficial` marcando los de ley.
-- ─────────────────────────────────────────────────────────────
create table public.dias_no_laborables (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  centro_id   uuid references public.centros_trabajo(id) on delete cascade,
  fecha       date not null,
  descripcion text not null,
  oficial     boolean not null default false,   -- art. 74 LFT
  paga_doble  boolean not null default true,    -- art. 75: trabajarlo se paga doble
  creado_en   timestamptz not null default now(),

  unique (tenant_id, centro_id, fecha)
);

create index dnl_tenant_fecha_idx
  on public.dias_no_laborables (tenant_id, fecha);

-- ─────────────────────────────────────────────────────────────
--  TURNOS · catálogo de horarios
--
--  `cruza_medianoche` no se captura: se deduce. Si la hora de
--  salida es menor o igual a la de entrada, el turno termina al
--  día siguiente. Dejarlo como columna manual garantiza que
--  alguien la va a capturar mal.
-- ─────────────────────────────────────────────────────────────
create table public.turnos (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  clave           text not null,                 -- 'MAT', 'NOC'
  nombre          text not null,                 -- 'Matutino'
  hora_entrada    time not null,
  hora_salida     time not null,

  -- Minutos de comida. Si no_computable, se descuentan de las
  -- horas trabajadas (art. 63 LFT: el descanso solo cuenta como
  -- jornada si el trabajador no puede salir del centro).
  minutos_comida  integer not null default 0 check (minutos_comida >= 0),
  comida_computa  boolean not null default false,

  -- Tolerancias en minutos
  tolerancia_entrada integer not null default 10 check (tolerancia_entrada >= 0),
  min_para_falta     integer not null default 60,  -- retardo tan grande que es falta

  color           text not null default '#2EC4B6', -- para el calendario
  activo          boolean not null default true,
  creado_en       timestamptz not null default now(),

  unique (tenant_id, clave)
);

create index turnos_tenant_idx on public.turnos (tenant_id, activo);

create or replace function public.turno_cruza_medianoche(t public.turnos)
returns boolean
language sql
immutable
as $$
  select t.hora_salida <= t.hora_entrada
$$;

create or replace function public.turno_horas(t public.turnos)
returns numeric
language sql
immutable
as $$
  select round(
    (extract(epoch from
      case when t.hora_salida <= t.hora_entrada
           then (t.hora_salida + interval '24 hours') - t.hora_entrada
           else t.hora_salida - t.hora_entrada end
    ) / 3600)::numeric
    - case when t.comida_computa then 0 else t.minutos_comida / 60.0 end
  , 2)
$$;

-- ─────────────────────────────────────────────────────────────
--  PATRONES DE ROTACIÓN
--
--  Un patrón es una SECUENCIA de turnos que se repite. El día 0
--  del ciclo se ancla a `fecha_ancla` en la asignación, y con
--  eso se resuelve cualquier esquema sin código especial:
--
--    Fijo:            ['MAT']                        largo 1
--    Rota semanal:    ['MAT','VES','NOC']            largo 3, unidad semana
--    4x3:             ['MAT','MAT','MAT','MAT','D','D','D']  unidad día
--    Continuo 2x2:    ['NOC','NOC','D','D']          unidad día
--
--  Es la única forma de cubrir "por semana, por día, o cuando lo
--  requiera la plantilla" sin una tabla por cada caso.
--  'D' (o NULL en el arreglo) significa descanso.
-- ─────────────────────────────────────────────────────────────
create table public.patrones_rotacion (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  nombre       text not null,

  -- Cada elemento es un turno_id o NULL para descanso.
  secuencia    uuid[] not null check (array_length(secuencia,1) >= 1),

  unidad       text not null default 'dia' check (unidad in ('dia','semana')),
  activo       boolean not null default true,
  creado_en    timestamptz not null default now(),

  unique (tenant_id, nombre)
);

create index patrones_tenant_idx on public.patrones_rotacion (tenant_id, activo);

-- ─────────────────────────────────────────────────────────────
--  ASIGNACIÓN de turno o patrón a un empleado
--
--  Con vigencia (desde/hasta) en lugar de un campo en
--  `empleados`: cuando alguien cambia de turno en marzo, el
--  histórico de enero debe seguir evaluándose con el turno que
--  tenía entonces. Un campo único borraría el pasado.
-- ─────────────────────────────────────────────────────────────
create table public.asignaciones_turno (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  empleado_id   uuid not null references public.empleados(id) on delete cascade,

  turno_id      uuid references public.turnos(id) on delete restrict,
  patron_id     uuid references public.patrones_rotacion(id) on delete restrict,
  fecha_ancla   date,                            -- día 0 del ciclo

  -- Días de descanso semanal para turno fijo (0=domingo).
  -- Art. 69 LFT: al menos un día de descanso por semana.
  dias_descanso smallint[] not null default '{0}',

  desde         date not null,
  hasta         date,                            -- null = vigente
  creado_en     timestamptz not null default now(),

  -- Turno fijo o patrón, nunca los dos ni ninguno
  constraint asig_turno_o_patron check (
    (turno_id is not null and patron_id is null)
    or (turno_id is null and patron_id is not null and fecha_ancla is not null)
  ),
  constraint asig_rango_valido check (hasta is null or hasta >= desde)
);

create index asig_tenant_emp_idx
  on public.asignaciones_turno (tenant_id, empleado_id, desde desc);

-- Evita dos asignaciones traslapadas para el mismo empleado.
-- Sin esto, el sistema no sabría qué turno le toca ese día.
create extension if not exists btree_gist;
alter table public.asignaciones_turno
  add constraint asig_sin_traslape
  exclude using gist (
    empleado_id with =,
    daterange(desde, coalesce(hasta, 'infinity'::date), '[]') with &&
  );

/* Qué turno le toca a un empleado en una fecha.
   Devuelve NULL si descansa o no tiene asignación. */
create or replace function public.turno_del_dia(
  p_empleado_id uuid,
  p_fecha       date
)
returns uuid
language plpgsql
stable
as $$
declare
  a          public.asignaciones_turno;
  v_idx      integer;
  v_largo    integer;
  v_delta    integer;
  v_turno    uuid;
begin
  select * into a
  from public.asignaciones_turno
  where empleado_id = p_empleado_id
    and p_fecha >= desde
    and (hasta is null or p_fecha <= hasta)
  limit 1;

  if not found then return null; end if;

  -- Turno fijo: aplica salvo que sea su día de descanso
  if a.turno_id is not null then
    if extract(dow from p_fecha)::smallint = any(a.dias_descanso) then
      return null;
    end if;
    return a.turno_id;
  end if;

  -- Patrón: se ubica la posición dentro del ciclo
  select array_length(secuencia,1) into v_largo
  from public.patrones_rotacion where id = a.patron_id;

  if v_largo is null or v_largo = 0 then return null; end if;

  select case when unidad = 'semana'
              then floor((p_fecha - a.fecha_ancla) / 7.0)::integer
              else (p_fecha - a.fecha_ancla)
         end
    into v_delta
  from public.patrones_rotacion where id = a.patron_id;

  -- mod() puede dar negativo si la fecha es previa al ancla
  v_idx := ((v_delta % v_largo) + v_largo) % v_largo;

  select secuencia[v_idx + 1] into v_turno
  from public.patrones_rotacion where id = a.patron_id;

  return v_turno;   -- NULL = descanso dentro del patrón
end;
$$;

-- ─────────────────────────────────────────────────────────────
--  CHECADAS · el hecho crudo, inmutable
--
--  Sin columna 'tipo' (entrada/salida) capturada por el usuario:
--  se deduce del orden. Un empleado que oprime "entrada" dos
--  veces por error no debe romper el cálculo del día.
-- ─────────────────────────────────────────────────────────────
create table public.checadas (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  empleado_id   uuid not null references public.empleados(id) on delete cascade,

  momento       timestamptz not null default now(),
  fecha_laboral date not null,          -- día del TURNO, no del reloj

  origen        text not null default 'pwa'
                check (origen in ('pwa','kiosco','biometrico','manual','importacion')),

  -- Geocerca. Se guarda aunque no se valide: sirve como
  -- evidencia y permite auditar después.
  lat           numeric(10,7),
  lng           numeric(10,7),
  precision_m   numeric(8,2),
  dispositivo   text,
  selfie_path   text,                   -- Storage, opcional

  -- Correcciones: la checada mala NO se borra ni se edita, se
  -- anula y se registra quién y por qué.
  anulada       boolean not null default false,
  anulada_por   uuid references public.perfiles(id),
  anulada_motivo text,

  creado_en     timestamptz not null default now()
);

create index checadas_tenant_fecha_idx
  on public.checadas (tenant_id, fecha_laboral desc);
create index checadas_emp_fecha_idx
  on public.checadas (tenant_id, empleado_id, fecha_laboral desc);

-- Las checadas no se editan. Solo se anulan (columnas anulada_*).
create or replace function app.checadas_solo_anular()
returns trigger
language plpgsql
as $$
begin
  if new.momento     is distinct from old.momento
  or new.empleado_id is distinct from old.empleado_id
  or new.fecha_laboral is distinct from old.fecha_laboral then
    raise exception 'Una checada no se modifica. Anulala y registra una nueva.';
  end if;
  return new;
end;
$$;

create trigger checadas_inmutables
  before update on public.checadas
  for each row execute function app.checadas_solo_anular();

-- ─────────────────────────────────────────────────────────────
--  JORNADAS · el día ya interpretado
--
--  Derivada de las checadas: se puede borrar y recalcular sin
--  perder nada. Aquí sí se corrige, aquí sí se recalcula.
-- ─────────────────────────────────────────────────────────────
create type public.estatus_jornada as enum (
  'completa','retardo','falta','descanso','festivo',
  'incidencia','incompleta','pendiente'
);

create table public.jornadas (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  empleado_id     uuid not null references public.empleados(id) on delete cascade,
  fecha_laboral   date not null,

  turno_id        uuid references public.turnos(id) on delete set null,
  entrada         timestamptz,
  salida          timestamptz,

  minutos_trabajados integer,
  minutos_retardo    integer not null default 0,
  minutos_extra      integer not null default 0,

  estatus         public.estatus_jornada not null default 'pendiente',

  -- Ajuste manual de RH. Se separa del cálculo para que un
  -- recálculo no lo borre y para saber siempre qué fue automático.
  ajuste_minutos  integer not null default 0,
  ajuste_motivo   text,
  ajustado_por    uuid references public.perfiles(id),

  calculado_en    timestamptz,
  unique (tenant_id, empleado_id, fecha_laboral)
);

create index jornadas_tenant_fecha_idx
  on public.jornadas (tenant_id, fecha_laboral desc, estatus);
create index jornadas_emp_fecha_idx
  on public.jornadas (tenant_id, empleado_id, fecha_laboral desc);

-- ─────────────────────────────────────────────────────────────
--  INCIDENCIAS · permisos, incapacidades, faltas justificadas
--
--  Con flujo de aprobación, porque una incapacidad afecta la
--  nómina y no puede depender de un correo.
-- ─────────────────────────────────────────────────────────────
create table public.tipos_incidencia (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  clave         text not null,
  nombre        text not null,
  con_goce      boolean not null default true,   -- ¿se paga?
  descuenta_vac boolean not null default false,  -- ¿consume vacaciones?
  requiere_doc  boolean not null default false,  -- ¿exige comprobante?
  color         text not null default '#8494A7',
  activo        boolean not null default true,

  unique (tenant_id, clave)
);

create type public.estatus_solicitud as enum (
  'borrador','pendiente','aprobada','rechazada','cancelada'
);

create table public.incidencias (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  empleado_id   uuid not null references public.empleados(id) on delete cascade,
  tipo_id       uuid not null references public.tipos_incidencia(id) on delete restrict,

  fecha_inicio  date not null,
  fecha_fin     date not null,
  dias          integer,                 -- lo calcula el trigger
  comentario    text,
  documento_path text,

  estatus       public.estatus_solicitud not null default 'pendiente',
  solicitado_por uuid references public.perfiles(id),
  resuelto_por   uuid references public.perfiles(id),
  resuelto_en    timestamptz,
  resuelto_nota  text,

  creado_en     timestamptz not null default now(),

  constraint inc_rango_valido check (fecha_fin >= fecha_inicio)
);

create index inc_tenant_emp_idx
  on public.incidencias (tenant_id, empleado_id, fecha_inicio desc);
create index inc_tenant_estatus_idx
  on public.incidencias (tenant_id, estatus, fecha_inicio desc);

-- ═══════════════════════════════════════════════════════════
--  VACACIONES · LFT art. 76 reformado (Vacaciones Dignas, 2023)
-- ═══════════════════════════════════════════════════════════

/* Días que corresponden según años cumplidos de servicio.
   Art. 76: 12 días al primer año, +2 por año hasta el quinto
   (20 días), y a partir del sexto aumenta 2 días por cada 5
   años de servicio.

   Se implementa como función y no como tabla porque es ley
   federal: no cambia por cliente, y una tabla invita a que
   alguien la "ajuste" y deje de cumplir. Si un cliente da más,
   eso entra como movimiento extra. */
create or replace function public.dias_vacaciones_lft(p_anios integer)
returns integer
language sql
immutable
as $$
  select case
    when p_anios < 1  then 0
    when p_anios = 1  then 12
    when p_anios = 2  then 14
    when p_anios = 3  then 16
    when p_anios = 4  then 18
    when p_anios = 5  then 20
    -- Sexto en adelante: 22, 24, 26... cada 5 años
    else 20 + 2 * (floor((p_anios - 1) / 5.0)::integer)
  end
$$;

comment on function public.dias_vacaciones_lft is
  'LFT art. 76 reformado (DOF 27-12-2022, vigente 2023). 1=12, 2=14, 3=16, 4=18, 5=20, 6-10=22, 11-15=24, 16-20=26...';

create type public.mov_vacaciones as enum (
  'devengado',   -- se cumplió un año de servicio
  'tomado',      -- días disfrutados
  'pagado',      -- prima o liquidación
  'ajuste',      -- corrección manual de RH
  'extra',       -- días por política de la empresa, arriba de la ley
  'prescrito'    -- perdidos por art. 516
);

/* Libro mayor de vacaciones. El saldo es la SUMA de los
   movimientos, nunca una columna guardada: así siempre se puede
   auditar de dónde salió cada día. */
create table public.vacaciones_movimientos (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  empleado_id   uuid not null references public.empleados(id) on delete cascade,

  tipo          public.mov_vacaciones not null,

  -- Positivo suma, negativo resta. 'tomado' y 'prescrito'
  -- siempre negativos; 'devengado' siempre positivo.
  dias          numeric(6,2) not null,

  -- Periodo de servicio al que pertenecen. Sirve para aplicar la
  -- prescripción del art. 516 y para saber qué se toma primero.
  periodo_anio  integer,
  fecha_efecto  date not null default current_date,

  incidencia_id uuid references public.incidencias(id) on delete set null,
  nota          text,
  creado_por    uuid references public.perfiles(id),
  creado_en     timestamptz not null default now(),

  constraint vac_dias_no_cero check (dias <> 0),
  constraint vac_signos check (
    (tipo in ('devengado','extra') and dias > 0)
    or (tipo in ('tomado','prescrito') and dias < 0)
    or tipo in ('pagado','ajuste')
  )
);

create index vac_tenant_emp_idx
  on public.vacaciones_movimientos (tenant_id, empleado_id, fecha_efecto desc);

/* Saldo disponible: suma simple del libro mayor. */
create or replace function public.saldo_vacaciones(p_empleado_id uuid)
returns numeric
language sql
stable
as $$
  select coalesce(sum(dias), 0)
  from public.vacaciones_movimientos
  where empleado_id = p_empleado_id
$$;

/* Genera los devengados que falten para un empleado.
   Idempotente: se puede correr todos los días sin duplicar,
   porque revisa qué periodos ya existen. Eso permite llamarla
   desde un cron sin miedo. */
create or replace function public.devengar_vacaciones(p_empleado_id uuid)
returns integer
language plpgsql
as $$
declare
  e            public.empleados;
  v_anios      integer;
  v_a          integer;
  v_dias       integer;
  v_creados    integer := 0;
begin
  select * into e from public.empleados where id = p_empleado_id;
  if not found or e.fecha_ingreso is null then return 0; end if;

  -- Años cumplidos a la fecha (o a la baja, si ya no trabaja)
  v_anios := extract(year from age(
    coalesce(e.fecha_baja, current_date), e.fecha_ingreso
  ))::integer;

  for v_a in 1..greatest(v_anios, 0) loop
    if not exists (
      select 1 from public.vacaciones_movimientos
      where empleado_id = p_empleado_id
        and tipo = 'devengado'
        and periodo_anio = v_a
    ) then
      v_dias := public.dias_vacaciones_lft(v_a);
      insert into public.vacaciones_movimientos
        (tenant_id, empleado_id, tipo, dias, periodo_anio, fecha_efecto, nota)
      values (
        e.tenant_id, p_empleado_id, 'devengado', v_dias, v_a,
        (e.fecha_ingreso + (v_a || ' years')::interval)::date,
        'Devengado automatico LFT art. 76 - anio ' || v_a
      );
      v_creados := v_creados + 1;
    end if;
  end loop;

  return v_creados;
end;
$$;

-- Días de una incidencia: los calcula el sistema
create or replace function app.calcular_dias_incidencia()
returns trigger
language plpgsql
as $$
begin
  new.dias := (new.fecha_fin - new.fecha_inicio) + 1;
  return new;
end;
$$;

create trigger inc_calcular_dias
  before insert or update on public.incidencias
  for each row execute function app.calcular_dias_incidencia();

-- ═══════════════════════════════════════════════════════════
--  ROW LEVEL SECURITY
-- ═══════════════════════════════════════════════════════════

alter table public.dias_no_laborables      enable row level security;
alter table public.turnos                  enable row level security;
alter table public.patrones_rotacion       enable row level security;
alter table public.asignaciones_turno      enable row level security;
alter table public.checadas                enable row level security;
alter table public.jornadas                enable row level security;
alter table public.tipos_incidencia        enable row level security;
alter table public.incidencias             enable row level security;
alter table public.vacaciones_movimientos  enable row level security;

-- Catálogos: los lee todo el tenant, los edita RH.
-- El colaborador necesita leer turnos para ver su propio horario.
create policy dnl_leer on public.dias_no_laborables
  for select using (tenant_id = app.mi_tenant());
create policy dnl_escribir on public.dias_no_laborables
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

create policy turnos_leer on public.turnos
  for select using (tenant_id = app.mi_tenant());
create policy turnos_escribir on public.turnos
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

create policy patrones_leer on public.patrones_rotacion
  for select using (tenant_id = app.mi_tenant());
create policy patrones_escribir on public.patrones_rotacion
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

create policy tipos_inc_leer on public.tipos_incidencia
  for select using (tenant_id = app.mi_tenant());
create policy tipos_inc_escribir on public.tipos_incidencia
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

/* Datos personales: RH todo, el jefe su equipo, cada quien lo
   suyo. Se repite el patrón de `empleados` porque un horario y
   una checada dicen dónde estuvo una persona: es dato sensible,
   no operativo. */
create policy asig_leer on public.asignaciones_turno
  for select using (
    tenant_id = app.mi_tenant() and (
      app.es_admin()
      or empleado_id = (select empleado_id from public.perfiles where id = auth.uid())
      or empleado_id in (
        select id from public.empleados
        where jefe_id = (select empleado_id from public.perfiles where id = auth.uid())
      )
    )
  );
create policy asig_escribir on public.asignaciones_turno
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

create policy checadas_leer on public.checadas
  for select using (
    tenant_id = app.mi_tenant() and (
      app.es_admin()
      or empleado_id = (select empleado_id from public.perfiles where id = auth.uid())
      or empleado_id in (
        select id from public.empleados
        where jefe_id = (select empleado_id from public.perfiles where id = auth.uid())
      )
    )
  );

-- El empleado puede checar, pero SOLO por sí mismo.
create policy checadas_propia on public.checadas
  for insert with check (
    tenant_id = app.mi_tenant()
    and empleado_id = (select empleado_id from public.perfiles where id = auth.uid())
  );
create policy checadas_rh on public.checadas
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

create policy jornadas_leer on public.jornadas
  for select using (
    tenant_id = app.mi_tenant() and (
      app.es_admin()
      or empleado_id = (select empleado_id from public.perfiles where id = auth.uid())
      or empleado_id in (
        select id from public.empleados
        where jefe_id = (select empleado_id from public.perfiles where id = auth.uid())
      )
    )
  );
create policy jornadas_escribir on public.jornadas
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

-- Incidencias: el empleado crea las propias y las ve; RH resuelve.
create policy inc_leer on public.incidencias
  for select using (
    tenant_id = app.mi_tenant() and (
      app.es_admin()
      or empleado_id = (select empleado_id from public.perfiles where id = auth.uid())
      or empleado_id in (
        select id from public.empleados
        where jefe_id = (select empleado_id from public.perfiles where id = auth.uid())
      )
    )
  );
create policy inc_crear_propia on public.incidencias
  for insert with check (
    tenant_id = app.mi_tenant()
    and empleado_id = (select empleado_id from public.perfiles where id = auth.uid())
  );
create policy inc_rh on public.incidencias
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

create policy vac_leer on public.vacaciones_movimientos
  for select using (
    tenant_id = app.mi_tenant() and (
      app.es_admin()
      or empleado_id = (select empleado_id from public.perfiles where id = auth.uid())
      or empleado_id in (
        select id from public.empleados
        where jefe_id = (select empleado_id from public.perfiles where id = auth.uid())
      )
    )
  );
create policy vac_escribir on public.vacaciones_movimientos
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

-- ═══════════════════════════════════════════════════════════
--  SEMILLA · turnos, patrones, incidencias y festivos 2026
-- ═══════════════════════════════════════════════════════════
do $$
declare
  t_id   uuid;
  mat    uuid;
  ves    uuid;
  noc    uuid;
begin
  select id into t_id from public.tenants where slug = 'grupo-multimedia';
  if t_id is null then return; end if;

  insert into public.turnos (tenant_id, clave, nombre, hora_entrada, hora_salida,
                             minutos_comida, color)
  values
    (t_id,'MAT','Matutino','09:00','18:00',60,'#2EC4B6'),
    (t_id,'VES','Vespertino','14:00','22:00',30,'#F4795B'),
    (t_id,'NOC','Nocturno','22:00','06:00',30,'#6366F1')
  on conflict (tenant_id, clave) do nothing;

  select id into mat from public.turnos where tenant_id=t_id and clave='MAT';
  select id into ves from public.turnos where tenant_id=t_id and clave='VES';
  select id into noc from public.turnos where tenant_id=t_id and clave='NOC';

  -- Rotación semanal de tres turnos
  insert into public.patrones_rotacion (tenant_id, nombre, secuencia, unidad)
  values (t_id, 'Rotativo 3 turnos (semanal)', array[mat,ves,noc], 'semana')
  on conflict (tenant_id, nombre) do nothing;

  -- 4x3: cuatro días matutino, tres de descanso
  insert into public.patrones_rotacion (tenant_id, nombre, secuencia, unidad)
  values (t_id, '4x3 Matutino',
          array[mat,mat,mat,mat,null,null,null]::uuid[], 'dia')
  on conflict (tenant_id, nombre) do nothing;

  insert into public.tipos_incidencia
    (tenant_id, clave, nombre, con_goce, descuenta_vac, requiere_doc, color)
  values
    (t_id,'VAC','Vacaciones',            true,  true,  false,'#2EC4B6'),
    (t_id,'INC','Incapacidad IMSS',      true,  false, true, '#6366F1'),
    (t_id,'PCG','Permiso con goce',      true,  false, false,'#14A085'),
    (t_id,'PSG','Permiso sin goce',      false, false, false,'#D97706'),
    (t_id,'FJ', 'Falta justificada',     false, false, true, '#8494A7'),
    (t_id,'FI', 'Falta injustificada',   false, false, false,'#DC2626'),
    (t_id,'MAT','Licencia de maternidad',true,  false, true, '#EC4899'),
    (t_id,'PAT','Licencia de paternidad',true,  false, true, '#0EA5E9')
  on conflict (tenant_id, clave) do nothing;

  -- Festivos oficiales art. 74 LFT para 2026
  insert into public.dias_no_laborables
    (tenant_id, fecha, descripcion, oficial)
  values
    (t_id,'2026-01-01','Ano Nuevo',true),
    (t_id,'2026-02-02','Dia de la Constitucion',true),
    (t_id,'2026-03-16','Natalicio de Benito Juarez',true),
    (t_id,'2026-05-01','Dia del Trabajo',true),
    (t_id,'2026-09-16','Independencia de Mexico',true),
    (t_id,'2026-11-16','Revolucion Mexicana',true),
    (t_id,'2026-12-25','Navidad',true)
  on conflict (tenant_id, centro_id, fecha) do nothing;
end $$;