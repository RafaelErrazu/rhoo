-- ═══════════════════════════════════════════════════════════
--  RHoo! · Migración 01 · Base multi-tenant
--
--  Un solo Postgres para todos los clientes. El aislamiento lo
--  garantiza Row Level Security, no el código de la aplicación:
--  ninguna consulta del frontend filtra por tenant a mano.
-- ═══════════════════════════════════════════════════════════

create schema if not exists app;

-- ─────────────────────────────────────────────────────────────
--  TENANTS · un renglón por empresa cliente
-- ─────────────────────────────────────────────────────────────
create table public.tenants (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique,          -- 'grupo-multimedia'
  nombre       text not null,                 -- 'Grupo Multimedia México'
  rfc          text,
  activo       boolean not null default true,

  -- Config por cliente en JSON y no en columnas: cada empresa
  -- pide sus propios ajustes (umbrales, logo, colores) y no vale
  -- la pena una migración por cada uno.
  config       jsonb not null default '{}'::jsonb,

  plan         text not null default 'trial'
               check (plan in ('trial','basico','pro','enterprise')),
  creado_en    timestamptz not null default now()
);

comment on column public.tenants.slug is
  'Identificador corto en URLs y rutas de Storage. Inmutable.';

-- ─────────────────────────────────────────────────────────────
--  PERFILES · liga auth.users con su tenant y su rol
--
--  Se separa de `empleados` a propósito: no todo usuario del
--  sistema es empleado del cliente (tú como proveedor, un
--  consultor externo), y no todo empleado tiene acceso.
-- ─────────────────────────────────────────────────────────────
create type public.rol_usuario as enum (
  'superadmin',    -- tú: cruza tenants
  'admin',         -- administrador del cliente
  'rh',            -- opera el sistema
  'jefe',          -- ve a su equipo
  'colaborador'    -- se ve a sí mismo
);

create table public.perfiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  rol          public.rol_usuario not null default 'colaborador',
  nombre       text not null,
  email        text not null,
  empleado_id  uuid,                          -- FK se agrega abajo
  activo       boolean not null default true,
  creado_en    timestamptz not null default now()
);

create index perfiles_tenant_idx on public.perfiles (tenant_id, activo);

-- ─────────────────────────────────────────────────────────────
--  FUNCIONES DE CONTEXTO
--
--  SECURITY DEFINER a propósito: estas funciones se usan DENTRO
--  de las políticas de RLS, así que si respetaran RLS al leer
--  `perfiles` se llamarían a sí mismas en un ciclo infinito.
--  Definidas así, leen la tabla sin pasar por las políticas.
--
--  search_path fijo en la firma: sin eso, una función
--  SECURITY DEFINER es un vector de escalada de privilegios.
-- ─────────────────────────────────────────────────────────────
create or replace function app.mi_tenant()
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select tenant_id from public.perfiles where id = auth.uid()
$$;

create or replace function app.mi_rol()
returns public.rol_usuario
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select rol from public.perfiles where id = auth.uid()
$$;

-- ¿Puede administrar datos del tenant?
create or replace function app.es_admin()
returns boolean
language sql
stable
as $$
  select app.mi_rol() in ('superadmin','admin','rh')
$$;

-- ─────────────────────────────────────────────────────────────
--  CENTROS DE TRABAJO
--
--  Es la unidad que la NOM-035 usa para todo: la evaluación se
--  aplica por centro, el nivel de riesgo es del centro y la
--  vigencia de 2 años se cuenta por centro. En Prisma esto era
--  el "grupo comercial" deducido de la empresa; aquí es una
--  entidad de verdad, porque un cliente puede tener diez.
-- ─────────────────────────────────────────────────────────────
create table public.centros_trabajo (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  clave         text not null,                -- 'CITADELLA'
  nombre        text not null,
  razon_social  text,
  direccion     text,
  activo        boolean not null default true,
  creado_en     timestamptz not null default now(),

  unique (tenant_id, clave)
);

create index centros_tenant_idx on public.centros_trabajo (tenant_id, activo);

-- ─────────────────────────────────────────────────────────────
--  EMPLEADOS
--
--  Nombre partido en tres campos aunque hoy la hoja lo tenga en
--  uno solo. Con el nombre completo en un solo campo no se puede
--  ordenar por apellido ni buscar bien, y partirlo después
--  significa reprocesar todo el histórico a mano.
--  `nombre_completo` se genera solo: nunca puede desincronizarse.
-- ─────────────────────────────────────────────────────────────
create table public.empleados (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id) on delete cascade,
  centro_id         uuid references public.centros_trabajo(id) on delete set null,

  no_empleado       text not null,            -- el número que usa la gente
  apellido_paterno  text not null default '',
  apellido_materno  text not null default '',
  nombres           text not null default '',
  nombre_completo   text generated always as (
                      trim(both ' ' from
                        coalesce(apellido_paterno,'') || ' ' ||
                        coalesce(apellido_materno,'') || ' ' ||
                        coalesce(nombres,''))
                    ) stored,

  -- Datos personales
  sexo              text check (sexo in ('Masculino','Femenino','Otro')),
  fecha_nacimiento  date,
  estado_civil      text,
  escolaridad       text,
  curp              text,
  rfc               text,
  nss               text,
  email             text,
  telefono          text,

  -- Datos laborales
  puesto            text,
  departamento      text,
  tipo_puesto       text check (tipo_puesto in
                      ('Operativo','Supervisor','Profesional o técnico','Gerente')),
  tipo_contrato      text,
  tipo_personal     text check (tipo_personal in
                      ('Sindicalizado','Confianza','Ninguno')),
  fecha_ingreso     date,
  fecha_baja        date,
  motivo_baja       text,
  jefe_id           uuid references public.empleados(id) on delete set null,

  estatus           text not null default 'Activo'
                    check (estatus in ('Activo','Baja','Suspendido')),

  -- La edad NO se guarda: se calcula. Una columna 'edad' queda
  -- mal al día siguiente del cumpleaños y nadie la actualiza.
  creado_en         timestamptz not null default now(),
  actualizado_en    timestamptz not null default now(),

  unique (tenant_id, no_empleado)
);

-- tenant_id primero en todos los índices: ver nota 1 del encabezado
create index empleados_tenant_estatus_idx
  on public.empleados (tenant_id, estatus);
create index empleados_tenant_centro_idx
  on public.empleados (tenant_id, centro_id, estatus);
create index empleados_tenant_jefe_idx
  on public.empleados (tenant_id, jefe_id);

-- Búsqueda por nombre sin importar acentos ni mayúsculas
create extension if not exists unaccent;

-- unaccent() es STABLE porque depende de un diccionario que
-- podria cambiar. En la practica el diccionario nunca cambia, y
-- Postgres exige IMMUTABLE para indexar, asi que se envuelve.
create or replace function public.sin_acentos(txt text)
returns text
language sql
immutable
strict
parallel safe
set search_path = public, pg_catalog, pg_temp
as $$
  select lower(unaccent('public.unaccent'::regdictionary, txt))
$$;

create index empleados_nombre_busqueda_idx
  on public.empleados (tenant_id, public.sin_acentos(nombre_completo));

-- Ahora sí, la FK que faltaba en perfiles
alter table public.perfiles
  add constraint perfiles_empleado_fk
  foreign key (empleado_id) references public.empleados(id) on delete set null;

-- Edad y antigüedad como funciones, no como columnas
create or replace function public.edad(e public.empleados)
returns integer
language sql
stable
as $$
  select case when e.fecha_nacimiento is null then null
         else extract(year from age(e.fecha_nacimiento))::int end
$$;

create or replace function public.antiguedad_meses(e public.empleados)
returns integer
language sql
stable
as $$
  select case when e.fecha_ingreso is null then null
         else (extract(year  from age(coalesce(e.fecha_baja, current_date), e.fecha_ingreso)) * 12
             + extract(month from age(coalesce(e.fecha_baja, current_date), e.fecha_ingreso)))::int
         end
$$;

-- ─────────────────────────────────────────────────────────────
--  actualizado_en automático
-- ─────────────────────────────────────────────────────────────
create or replace function app.tocar_actualizado_en()
returns trigger
language plpgsql
as $$
begin
  new.actualizado_en := now();
  return new;
end;
$$;

create trigger empleados_actualizado_en
  before update on public.empleados
  for each row execute function app.tocar_actualizado_en();

-- ═══════════════════════════════════════════════════════════
--  ROW LEVEL SECURITY
--
--  Todo bloqueado, y se abre caso por caso. El orden importa:
--  primero enable, después las políticas. Una tabla con RLS
--  activo y sin políticas no devuelve nada, que es el estado
--  seguro por omisión.
-- ═══════════════════════════════════════════════════════════

alter table public.tenants         enable row level security;
alter table public.perfiles        enable row level security;
alter table public.centros_trabajo enable row level security;
alter table public.empleados       enable row level security;

-- ── TENANTS ──
-- Cada quien ve su propia empresa y nada más.
create policy tenants_leer_propio on public.tenants
  for select using (id = app.mi_tenant() or app.mi_rol() = 'superadmin');

create policy tenants_editar_admin on public.tenants
  for update using (
    (id = app.mi_tenant() and app.mi_rol() in ('admin','superadmin'))
  );

-- ── PERFILES ──
create policy perfiles_leer on public.perfiles
  for select using (
    id = auth.uid()                                    -- siempre el propio
    or (tenant_id = app.mi_tenant() and app.es_admin())
    or app.mi_rol() = 'superadmin'
  );

create policy perfiles_admin_escribe on public.perfiles
  for all using (
    tenant_id = app.mi_tenant() and app.mi_rol() in ('admin','superadmin')
  )
  with check (
    tenant_id = app.mi_tenant() and app.mi_rol() in ('admin','superadmin')
  );

-- ── CENTROS DE TRABAJO ──
-- Lectura para todo el tenant: el colaborador necesita saber a
-- qué centro pertenece para consultar resultados colectivos.
create policy centros_leer on public.centros_trabajo
  for select using (tenant_id = app.mi_tenant());

create policy centros_escribir on public.centros_trabajo
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

-- ── EMPLEADOS ──
-- Tres niveles de visibilidad en una sola política:
-- RH ve todo su tenant, el jefe ve a su equipo, el colaborador
-- se ve a sí mismo. Sin esto, cualquier usuario autenticado
-- podría leer el padrón completo.
create policy empleados_leer on public.empleados
  for select using (
    tenant_id = app.mi_tenant()
    and (
      app.es_admin()
      or id = (select empleado_id from public.perfiles where id = auth.uid())
      or jefe_id = (select empleado_id from public.perfiles where id = auth.uid())
    )
  );

create policy empleados_escribir on public.empleados
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

-- ═══════════════════════════════════════════════════════════
--  DATOS INICIALES · tu propio tenant
-- ═══════════════════════════════════════════════════════════
insert into public.tenants (slug, nombre, plan)
values ('grupo-multimedia', 'Grupo Multimedia México', 'pro')
on conflict (slug) do nothing;

insert into public.centros_trabajo (tenant_id, clave, nombre)
select t.id, c.clave, c.nombre
from public.tenants t
cross join (values
  ('GLOBALMEDIA', 'GlobalMedia'),
  ('CITADELLA',   'Citadella')
) as c(clave, nombre)
where t.slug = 'grupo-multimedia'
on conflict (tenant_id, clave) do nothing;