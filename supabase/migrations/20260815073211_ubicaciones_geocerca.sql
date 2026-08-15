-- ═══════════════════════════════════════════════════════════
--  RHoo! · Ubicaciones autorizadas para checar
--
--  Distinto de `centros_trabajo`: el centro es la unidad legal
--  (NOM-035, IMSS); la ubicacion es solo un punto geografico
--  donde se acepta una checada.
-- ═══════════════════════════════════════════════════════════

create type public.tipo_ubicacion as enum
  ('sede',        -- oficina o planta propia
   'cliente',     -- instalaciones de un cliente
   'proyecto',    -- obra o evento
   'temporal',    -- comision corta: exige fecha de fin
   'domicilio');  -- home office

create table public.ubicaciones (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  centro_id   uuid references public.centros_trabajo(id) on delete set null,

  nombre      text not null,
  tipo        public.tipo_ubicacion not null default 'sede',
  direccion   text,

  lat         numeric(10,7) not null,
  lng         numeric(10,7) not null,

  -- 150 m por omision. Menos de 100 genera falsos rechazos: el
  -- GPS de un celular dentro de una nave industrial se desvia
  -- facil 80 m, y el trabajador acaba culpando al sistema.
  radio_m     integer not null default 150 check (radio_m between 20 and 5000),

  activa      boolean not null default true,
  nota        text,
  creado_por  uuid references public.perfiles(id),
  creado_en   timestamptz not null default now(),

  unique (tenant_id, nombre)
);

create index ubic_tenant_idx on public.ubicaciones (tenant_id, activa);

/* Asignación empleado ↔ ubicación, con vigencia. */
create table public.ubicaciones_empleado (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  empleado_id   uuid not null references public.empleados(id) on delete cascade,
  ubicacion_id  uuid not null references public.ubicaciones(id) on delete cascade,

  desde         date not null default current_date,
  hasta         date,                    -- null = permanente

  motivo        text,
  creado_por    uuid references public.perfiles(id),
  creado_en     timestamptz not null default now(),

  constraint ubic_emp_rango check (hasta is null or hasta >= desde),
  unique (empleado_id, ubicacion_id, desde)
);

create index ubic_emp_idx
  on public.ubicaciones_empleado (tenant_id, empleado_id, desde desc);

/* Las temporales caducan por obligacion.
   Una autorizacion sin fin no se revoca nunca: nadie entra a
   limpiar permisos de un proyecto que ya termino. */
create or replace function app.validar_ubicacion_empleado()
returns trigger
language plpgsql
as $$
declare v_tipo public.tipo_ubicacion;
begin
  select tipo into v_tipo from public.ubicaciones where id = new.ubicacion_id;

  if v_tipo = 'temporal' and new.hasta is null then
    raise exception 'Una ubicacion temporal necesita fecha de fin. Sin ella la autorizacion no caduca nunca.';
  end if;

  return new;
end;
$$;

create trigger ubic_emp_validar
  before insert or update on public.ubicaciones_empleado
  for each row execute function app.validar_ubicacion_empleado();

-- ─────────────────────────────────────────────────────────────
--  DISTANCIA
--
--  Formula esferica simple. A distancias urbanas el error contra
--  una geodesica es de centimetros, y evita depender de PostGIS
--  (que ademas obligaria a reescribir esto si algun dia se migra
--  a un Postgres sin la extension).
-- ─────────────────────────────────────────────────────────────
create or replace function app.distancia_m(
  lat1 numeric, lng1 numeric, lat2 numeric, lng2 numeric
)
returns numeric
language sql
immutable
as $$
  select round((6371000 * acos(
    least(1, greatest(-1,
      sin(radians(lat1)) * sin(radians(lat2)) +
      cos(radians(lat1)) * cos(radians(lat2)) *
      cos(radians(lng2) - radians(lng1))
    ))
  ))::numeric, 1)
$$;

/* Ubicaciones válidas de un empleado hoy: su centro más las
   asignadas y vigentes. Una sola fuente, para que la geocerca y
   la pantalla de RH nunca discrepen. */
create or replace function public.ubicaciones_validas(
  p_empleado_id uuid,
  p_fecha date default current_date
)
returns table (
  ubicacion_id uuid,
  nombre       text,
  tipo         text,
  lat          numeric,
  lng          numeric,
  radio_m      integer
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  -- El centro de trabajo, si tiene coordenadas
  select c.id, c.nombre, 'centro'::text, c.lat, c.lng, c.radio_m
  from public.empleados e
  join public.centros_trabajo c on c.id = e.centro_id
  where e.id = p_empleado_id and c.lat is not null

  union all

  -- Ubicaciones asignadas y vigentes a la fecha
  select u.id, u.nombre, u.tipo::text, u.lat, u.lng, u.radio_m
  from public.ubicaciones_empleado ue
  join public.ubicaciones u on u.id = ue.ubicacion_id
  where ue.empleado_id = p_empleado_id
    and u.activa
    and p_fecha >= ue.desde
    and (ue.hasta is null or p_fecha <= ue.hasta)
$$;

grant execute on function public.ubicaciones_validas(uuid,date) to authenticated;

-- ═══════════════════════════════════════════════════════════
--  REGISTRAR CHECADA · versión con múltiples ubicaciones
--
--  Reemplaza la de la migración anterior, que solo comparaba
--  contra el centro.
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
  v_emp_id   uuid;
  e          public.empleados;
  v_fecha    date;
  v_id       uuid;
  v_mejor    record;
  v_dentro   boolean := false;
  v_cuantas  integer;
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
  if e.metodo_checada = 'ninguno' then
    return jsonb_build_object('status','error',
      'message','Tu puesto no registra asistencia.');
  end if;
  if e.metodo_checada = 'dispositivo' then
    return jsonb_build_object('status','error',
      'message','Debes registrar tu asistencia en el checador de tu centro de trabajo.');
  end if;

  -- ── Geocerca contra TODAS sus ubicaciones vigentes ──
  if app.cfg_bool('geocerca_activa', e.tenant_id) then
    if p_lat is null then
      return jsonb_build_object('status','error',
        'message','Activa la ubicacion de tu dispositivo para poder checar.');
    end if;

    -- La mas cercana. Se calcula aunque este dentro, porque el
    -- nombre sirve para el acuse: "registrado en Obra Citadella"
    -- le confirma al trabajador que quedo en el lugar correcto.
    select u.*, app.distancia_m(u.lat, u.lng, p_lat, p_lng) as dist
      into v_mejor
    from public.ubicaciones_validas(v_emp_id) u
    order by dist asc
    limit 1;

    if v_mejor is null then
      -- Sin ubicaciones configuradas y geocerca activa: se
      -- permite y se avisa. Bloquear aqui dejaria a toda la
      -- plantilla sin poder checar el dia que alguien active la
      -- geocerca antes de capturar las coordenadas.
      null;
    else
      v_dentro := v_mejor.dist <= v_mejor.radio_m;

      if not v_dentro then
        select count(*) into v_cuantas
        from public.ubicaciones_validas(v_emp_id);

        return jsonb_build_object(
          'status','error',
          'message', 'Estas a ' || round(v_mejor.dist) || ' m de '
                   || v_mejor.nombre || ' y el limite es de '
                   || v_mejor.radio_m || ' m.'
                   || case when v_cuantas > 1
                           then ' Es tu ubicacion autorizada mas cercana.'
                           else '' end
                   || ' Acercate o pide a RH un registro manual.',
          'distancia', round(v_mejor.dist),
          'ubicacion', v_mejor.nombre
        );
      end if;
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

  return jsonb_build_object(
    'status','success',
    'checada_id', v_id,
    'fecha_laboral', v_fecha,
    'ubicacion', coalesce(v_mejor.nombre, null),
    'numero', (select count(*) from public.checadas
               where empleado_id = v_emp_id
                 and fecha_laboral = v_fecha and not anulada)
  );
end;
$$;

grant execute on function public.registrar_checada(numeric,numeric,numeric,text,text)
  to authenticated;

-- ═══════════════════════════════════════════════════════════
--  RLS
-- ═══════════════════════════════════════════════════════════
alter table public.ubicaciones            enable row level security;
alter table public.ubicaciones_empleado   enable row level security;

-- Las ubicaciones las lee todo el tenant: el empleado necesita
-- ver donde tiene permitido checar. Solo RH las edita.
create policy ubic_leer on public.ubicaciones
  for select using (tenant_id = app.mi_tenant());
create policy ubic_escribir on public.ubicaciones
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());
create policy zz_proveedor_ubicaciones on public.ubicaciones
  for all using (app.es_proveedor()) with check (app.es_proveedor());

create policy ubic_emp_leer on public.ubicaciones_empleado
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
create policy ubic_emp_escribir on public.ubicaciones_empleado
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());
create policy zz_proveedor_ubic_emp on public.ubicaciones_empleado
  for all using (app.es_proveedor()) with check (app.es_proveedor());

grant select, insert, update, delete
  on public.ubicaciones, public.ubicaciones_empleado to authenticated;

-- ═══════════════════════════════════════════════════════════
--  ENDPOINTS DE ADMINISTRACIÓN
-- ═══════════════════════════════════════════════════════════

/* Guarda coordenadas de un centro de trabajo. */
create or replace function public.guardar_coordenadas_centro(
  p_centro_id uuid,
  p_lat numeric,
  p_lng numeric,
  p_radio integer default 150
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare antes jsonb;
begin
  if not app.es_admin() then
    raise exception 'Sin permiso';
  end if;

  select jsonb_build_object('lat', lat, 'lng', lng, 'radio_m', radio_m)
    into antes
  from public.centros_trabajo
  where id = p_centro_id and tenant_id = app.mi_tenant();

  if antes is null then
    raise exception 'Centro no encontrado';
  end if;

  update public.centros_trabajo
     set lat = p_lat, lng = p_lng, radio_m = p_radio
   where id = p_centro_id and tenant_id = app.mi_tenant();

  perform app.auditar('centro.coordenadas', 'centros_trabajo', p_centro_id::text,
    antes, jsonb_build_object('lat', p_lat, 'lng', p_lng, 'radio_m', p_radio));

  return jsonb_build_object('status','success');
end;
$$;

/* Asigna una ubicación a un empleado. */
create or replace function public.asignar_ubicacion(
  p_empleado_id  uuid,
  p_ubicacion_id uuid,
  p_desde date default current_date,
  p_hasta date default null,
  p_motivo text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_id uuid;
begin
  if not app.es_admin() then
    raise exception 'Sin permiso';
  end if;

  insert into public.ubicaciones_empleado
    (tenant_id, empleado_id, ubicacion_id, desde, hasta, motivo, creado_por)
  values
    (app.mi_tenant(), p_empleado_id, p_ubicacion_id, p_desde, p_hasta,
     p_motivo, auth.uid())
  returning id into v_id;

  perform app.auditar('ubicacion.asignar', 'ubicaciones_empleado', v_id::text,
    null, jsonb_build_object('empleado', p_empleado_id,
      'ubicacion', p_ubicacion_id, 'desde', p_desde, 'hasta', p_hasta));

  return jsonb_build_object('status','success','id',v_id);
end;
$$;

/* Vista para la pantalla de RH: qué está por caducar.
   Se avisa a 7 días porque una comisión que se extiende y nadie
   renovó deja al trabajador sin poder checar el lunes. */
create or replace function public.ubicaciones_por_caducar(p_dias integer default 7)
returns table (
  empleado    text,
  ubicacion   text,
  hasta       date,
  dias        integer
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select e.nombre_completo, u.nombre, ue.hasta,
         (ue.hasta - current_date)::integer
  from public.ubicaciones_empleado ue
  join public.empleados e   on e.id = ue.empleado_id
  join public.ubicaciones u on u.id = ue.ubicacion_id
  where ue.tenant_id = app.mi_tenant()
    and ue.hasta is not null
    and ue.hasta between current_date and current_date + p_dias
    and app.es_admin()
  order by ue.hasta
$$;

grant execute on function public.guardar_coordenadas_centro(uuid,numeric,numeric,integer) to authenticated;
grant execute on function public.asignar_ubicacion(uuid,uuid,date,date,text) to authenticated;
grant execute on function public.ubicaciones_por_caducar(integer) to authenticated;