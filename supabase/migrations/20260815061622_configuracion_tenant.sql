-- ═══════════════════════════════════════════════════════════
--  RHoo! · Configuración por tenant + auditoría
--
--  Los parámetros operativos los define el admin de cada
--  cliente. El superadmin (proveedor) solo controla plan,
--  límites y banderas de funciones.
--
--  Los mínimos de ley NO son configurables: se validan aquí, en
--  la base, porque una validación que solo vive en el navegador
--  no es una validación.
-- ═══════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────
--  AUDITORÍA
--
--  Sin esto, el acceso cruzado del proveedor (migración 03) es
--  indefendible ante un cliente corporativo, y la LFPDPPP pide
--  poder demostrar quién accedió a qué.
-- ─────────────────────────────────────────────────────────────
create table public.auditoria (
  id          bigserial primary key,
  tenant_id   uuid references public.tenants(id) on delete set null,
  actor_id    uuid references public.perfiles(id) on delete set null,
  actor_email text,                      -- se copia: el perfil puede borrarse
  actor_rol   text,
  accion      text not null,             -- 'config.actualizar', 'empleado.baja'
  entidad     text,                      -- tabla o módulo
  entidad_id  text,
  antes       jsonb,
  despues     jsonb,
  creado_en   timestamptz not null default now()
);

create index auditoria_tenant_idx on public.auditoria (tenant_id, creado_en desc);
create index auditoria_accion_idx on public.auditoria (tenant_id, accion, creado_en desc);

alter table public.auditoria enable row level security;

-- Solo lectura, y solo para quien administra. La auditoría se
-- escribe por funciones SECURITY DEFINER, nunca desde el cliente:
-- un registro que el usuario puede insertar a mano no sirve como
-- evidencia de nada.
create policy auditoria_leer on public.auditoria
  for select using (
    (tenant_id = app.mi_tenant() and app.es_admin())
    or app.es_proveedor()
  );

create or replace function app.auditar(
  p_accion     text,
  p_entidad    text default null,
  p_entidad_id text default null,
  p_antes      jsonb default null,
  p_despues    jsonb default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  p public.perfiles;
begin
  select * into p from public.perfiles where id = auth.uid();
  insert into public.auditoria
    (tenant_id, actor_id, actor_email, actor_rol,
     accion, entidad, entidad_id, antes, despues)
  values
    (p.tenant_id, p.id, p.email, p.rol::text,
     p_accion, p_entidad, p_entidad_id, p_antes, p_despues);
end;
$$;

-- ─────────────────────────────────────────────────────────────
--  VALORES POR OMISIÓN
--
--  Reflejan el uso común en México, no una preferencia mía. Un
--  tenant nuevo tiene que funcionar sin que nadie configure
--  nada; el cliente después ajusta lo suyo.
-- ─────────────────────────────────────────────────────────────
create or replace function app.config_defaults()
returns jsonb
language sql
immutable
as $$
  select '{
    "tolerancia_retardo_min":   10,
    "retardos_para_falta":      3,
    "minutos_para_falta":       60,
    "checada_faltante":         "incompleta",
    "descuenta_tiempo_retardo": false,

    "geocerca_activa":          false,
    "geocerca_radio_m":         150,
    "requiere_selfie":          false,

    "extras_modo":              "autorizacion",
    "extras_min_para_contar":   15,

    "vac_dias_extra":           0,
    "prima_vacacional_pct":     25,
    "vac_anticipacion_dias":    15,
    "vac_max_dias_continuos":   0,

    "inc_aprueba":              "rh",
    "inc_requiere_doc_dias":    3,

    "nom035_meses_vigencia":       24,
    "nom035_dias_aviso":           90,
    "nom035_min_publicable":       5,
    "nom035_ajustar_rango_parcial": true,
    "nom035_umbral_centro_pct":    25,

    "zona_horaria":             "America/Mexico_City",
    "semana_inicia_lunes":      true
  }'::jsonb
$$;

comment on function app.config_defaults is
  'Valores por omision de un tenant nuevo. Agregar una clave aqui la habilita para todos los clientes sin migrar datos.';

/* Lee un parámetro: lo del tenant si existe, si no el default.
   Toda la aplicación debe leer config por aquí y nunca tocando
   `tenants.config` directo, porque ahí faltan claves. */
create or replace function app.cfg(p_clave text, p_tenant uuid default null)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(
    (select config -> p_clave
       from public.tenants
      where id = coalesce(p_tenant, app.mi_tenant())
        and config ? p_clave),
    app.config_defaults() -> p_clave
  )
$$;

-- Atajos tipados, para no andar casteando en cada consulta
create or replace function app.cfg_int(p_clave text, p_tenant uuid default null)
returns integer language sql stable as $$
  select (app.cfg(p_clave, p_tenant))::text::integer
$$;

create or replace function app.cfg_bool(p_clave text, p_tenant uuid default null)
returns boolean language sql stable as $$
  select (app.cfg(p_clave, p_tenant))::text::boolean
$$;

create or replace function app.cfg_txt(p_clave text, p_tenant uuid default null)
returns text language sql stable as $$
  select trim(both '"' from (app.cfg(p_clave, p_tenant))::text)
$$;

-- ─────────────────────────────────────────────────────────────
--  PISO LEGAL · validación en la base
-- ─────────────────────────────────────────────────────────────
create or replace function app.validar_config()
returns trigger
language plpgsql
as $$
declare
  c jsonb := coalesce(new.config, '{}'::jsonb);
  v numeric;
begin
  -- Prima vacacional: art. 80 LFT, 25% MINIMO. Se puede dar mas.
  if c ? 'prima_vacacional_pct' then
    v := (c->>'prima_vacacional_pct')::numeric;
    if v < 25 then
      raise exception 'La prima vacacional no puede ser menor al 25%% (LFT art. 80). Recibido: %', v;
    end if;
  end if;

  -- Dias extra sobre la ley: nunca negativos, porque restar dias
  -- de vacaciones al minimo legal no es una configuracion, es un
  -- incumplimiento.
  if c ? 'vac_dias_extra' then
    v := (c->>'vac_dias_extra')::numeric;
    if v < 0 then
      raise exception 'Los dias adicionales de vacaciones no pueden ser negativos: el minimo de la LFT es un piso, no una sugerencia.';
    end if;
  end if;

  -- NOM-035: la evaluacion se repite AL MENOS cada 2 anos.
  -- Se puede evaluar mas seguido, nunca menos.
  if c ? 'nom035_meses_vigencia' then
    v := (c->>'nom035_meses_vigencia')::numeric;
    if v > 24 or v < 1 then
      raise exception 'La vigencia de la evaluacion NOM-035 debe estar entre 1 y 24 meses. Recibido: %', v;
    end if;
  end if;

  -- Tolerancia de retardo: un numero absurdo vuelve inutil el
  -- control de asistencia y genera conflictos laborales.
  if c ? 'tolerancia_retardo_min' then
    v := (c->>'tolerancia_retardo_min')::numeric;
    if v < 0 or v > 60 then
      raise exception 'La tolerancia de retardo debe estar entre 0 y 60 minutos.';
    end if;
  end if;

  if c ? 'checada_faltante'
     and c->>'checada_faltante' not in ('incompleta','asumir_salida') then
    raise exception 'checada_faltante solo acepta: incompleta, asumir_salida';
  end if;

  if c ? 'extras_modo'
     and c->>'extras_modo' not in ('automatico','autorizacion') then
    raise exception 'extras_modo solo acepta: automatico, autorizacion';
  end if;

  if c ? 'inc_aprueba'
     and c->>'inc_aprueba' not in ('jefe','rh','ambos') then
    raise exception 'inc_aprueba solo acepta: jefe, rh, ambos';
  end if;

  return new;
end;
$$;

create trigger tenants_validar_config
  before insert or update of config on public.tenants
  for each row execute function app.validar_config();

-- ─────────────────────────────────────────────────────────────
--  ENDPOINTS
-- ─────────────────────────────────────────────────────────────

/* Config completa (defaults + lo del tenant) en un solo objeto.
   La UI nunca arma esta mezcla: si lo hiciera, un cliente con la
   pestaña abierta desde ayer trabajaria con defaults viejos. */
create or replace function public.obtener_configuracion()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  t public.tenants;
begin
  select * into t from public.tenants where id = app.mi_tenant();
  if not found then
    raise exception 'Sin tenant asignado';
  end if;

  return jsonb_build_object(
    'tenant',  jsonb_build_object(
                 'id', t.id, 'slug', t.slug,
                 'nombre', t.nombre, 'plan', t.plan
               ),
    'config',  app.config_defaults() || coalesce(t.config, '{}'::jsonb),
    'editable', app.es_admin()
  );
end;
$$;

/* Guarda solo las claves recibidas. Merge y no reemplazo: dos
   personas configurando secciones distintas no se pisan entre
   ellas, y una clave nueva del producto no se borra al guardar
   una pantalla vieja. */
create or replace function public.guardar_configuracion(p_cambios jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  t_id   uuid := app.mi_tenant();
  antes  jsonb;
  nuevo  jsonb;
begin
  if not app.es_admin() then
    raise exception 'No tienes permiso para cambiar la configuracion';
  end if;

  -- Las claves del proveedor no se tocan desde aqui: un cliente
  -- no puede subirse el plan editando su propia configuracion.
  p_cambios := p_cambios - 'es_proveedor' - 'plan' - 'limites' - 'features';

  select coalesce(config, '{}'::jsonb) into antes
  from public.tenants where id = t_id;

  nuevo := antes || p_cambios;

  update public.tenants set config = nuevo where id = t_id;

  perform app.auditar(
    'config.actualizar', 'tenants', t_id::text,
    -- Solo las claves que cambiaron: guardar la config completa
    -- en cada movimiento hace ilegible el historial.
    (select jsonb_object_agg(k, antes -> k)
       from jsonb_object_keys(p_cambios) k),
    p_cambios
  );

  return jsonb_build_object(
    'status','success',
    'config', app.config_defaults() || nuevo
  );
end;
$$;

grant execute on function public.obtener_configuracion() to authenticated;
grant execute on function public.guardar_configuracion(jsonb) to authenticated;