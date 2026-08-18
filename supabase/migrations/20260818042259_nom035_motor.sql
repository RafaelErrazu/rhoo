-- ═══════════════════════════════════════════════════════════
--  RHoo! · NOM-035 · esquema y motor de calificacion
--
--  El motor vive COMPLETO en Postgres. En el sistema anterior
--  estaba partido entre el backend y el navegador, y el
--  navegador recalculaba niveles con los cortes del puntaje
--  total en lugar de los del dominio: los diez dominios salian
--  en "Nulo" mientras el global decia "Alto". Una sola fuente de
--  verdad evita esa clase de bug por construccion.
-- ═══════════════════════════════════════════════════════════

create type public.guia_nom035 as enum ('guia1','guia2','guia3');

-- ─────────────────────────────────────────────────────────────
--  CATALOGO DE ITEMS
--
--  En tabla y no en codigo: permite el editor para el admin, y
--  que el texto oficial se corrija sin desplegar. La columna
--  `oficial` marca los que vienen del DOF para que nadie los
--  edite por error.
-- ─────────────────────────────────────────────────────────────
create table public.nom035_items (
  id          uuid primary key default gen_random_uuid(),
  guia        public.guia_nom035 not null,
  numero      integer not null,
  pregunta    text not null,

  categoria   text,
  dominio     text,
  dimension   text,

  -- 'directa': Siempre=4 ... Nunca=0
  -- 'inversa': Siempre=0 ... Nunca=4
  -- Confundirlas invierte el resultado de ese item por completo.
  direccion   text not null default 'directa'
              check (direccion in ('directa','inversa')),

  -- 'clientes' o 'jefe': solo aplica si el trabajador atiende
  -- clientes o supervisa personal.
  condicional text check (condicional in ('clientes','jefe')),

  oficial     boolean not null default true,
  activo      boolean not null default true,

  unique (guia, numero)
);

create index nom035_items_guia_idx on public.nom035_items (guia, numero)
  where activo;

/* Guía I: acontecimientos traumáticos severos.
   Estructura distinta (secciones con ramificación), así que va
   en su propia tabla en lugar de forzarla al mismo molde. */
create table public.nom035_guia1 (
  id          uuid primary key default gen_random_uuid(),
  seccion     integer not null,
  seccion_tit text not null,
  instruccion text,
  clave       text not null unique,      -- 's1_1', 's2_1'
  orden       integer not null,
  texto       text not null
);

-- ─────────────────────────────────────────────────────────────
--  RANGOS DEL DOF
--
--  Cuatro cortes por escala: Nulo < c1 <= Bajo < c2 <= Medio <
--  c3 <= Alto < c4 <= Muy alto. Van como DATOS y no como codigo
--  para poder escalarlos proporcionalmente cuando se omiten
--  items condicionales.
-- ─────────────────────────────────────────────────────────────
create table public.nom035_rangos (
  id      uuid primary key default gen_random_uuid(),
  guia    public.guia_nom035 not null,
  ambito  text not null check (ambito in ('total','categoria','dominio')),
  nombre  text not null,                 -- '' para total
  cortes  integer[] not null check (array_length(cortes,1) = 4),

  unique (guia, ambito, nombre)
);

-- ── Guia II (46 items) ──
insert into public.nom035_rangos (guia, ambito, nombre, cortes) values
  ('guia2','total','', array[20,45,70,90]),

  ('guia2','categoria','Ambiente de trabajo',                      array[3,5,7,9]),
  ('guia2','categoria','Factores propios de la actividad',          array[10,20,30,40]),
  ('guia2','categoria','Organizacion del tiempo de trabajo',        array[4,6,9,12]),
  ('guia2','categoria','Liderazgo y relaciones en el trabajo',      array[10,18,28,38]),

  ('guia2','dominio','Condiciones en el ambiente de trabajo',       array[3,5,7,9]),
  ('guia2','dominio','Carga de trabajo',                            array[12,16,20,24]),
  ('guia2','dominio','Falta de control sobre el trabajo',            array[5,8,11,14]),
  ('guia2','dominio','Jornada de trabajo',                           array[1,2,4,6]),
  ('guia2','dominio','Interferencia en la relacion trabajo-familia', array[1,2,4,6]),
  ('guia2','dominio','Liderazgo',                                    array[3,5,8,11]),
  ('guia2','dominio','Relaciones en el trabajo',                     array[5,8,11,14]),
  ('guia2','dominio','Violencia',                                    array[7,10,13,16])
on conflict (guia, ambito, nombre) do nothing;

-- ── Guia III (72 items) ──
insert into public.nom035_rangos (guia, ambito, nombre, cortes) values
  ('guia3','total','', array[50,75,99,140]),

  ('guia3','categoria','Ambiente de trabajo',                        array[5,9,11,14]),
  ('guia3','categoria','Factores propios de la actividad',           array[15,30,45,60]),
  ('guia3','categoria','Organizacion del tiempo de trabajo',         array[5,7,10,13]),
  ('guia3','categoria','Liderazgo y relaciones en el trabajo',       array[14,29,42,58]),
  ('guia3','categoria','Entorno organizacional',                     array[10,14,18,23]),

  ('guia3','dominio','Condiciones en el ambiente de trabajo',        array[5,9,11,14]),
  ('guia3','dominio','Carga de trabajo',                             array[15,21,27,37]),
  ('guia3','dominio','Falta de control sobre el trabajo',            array[11,16,21,25]),
  ('guia3','dominio','Jornada de trabajo',                           array[1,2,4,6]),
  ('guia3','dominio','Interferencia en la relacion trabajo-familia', array[4,6,8,10]),
  ('guia3','dominio','Liderazgo',                                    array[9,12,16,20]),
  ('guia3','dominio','Relaciones en el trabajo',                     array[10,13,17,21]),
  ('guia3','dominio','Violencia',                                    array[7,10,13,16]),
  ('guia3','dominio','Reconocimiento del desempeno',                 array[6,10,14,18]),
  ('guia3','dominio','Insuficiente sentido de pertenencia, inestabilidad', array[4,6,8,10])
on conflict (guia, ambito, nombre) do nothing;

-- ─────────────────────────────────────────────────────────────
--  CAMPAÑAS DE EVALUACION
--
--  Lo que faltaba contra la competencia: una evaluacion con
--  apertura, cierre y universo definido. Sin esto la encuesta
--  esta siempre abierta, no se sabe a quien insistirle y la
--  participacion no es medible. Y la participacion es el
--  problema real: 2% no cumple con nada.
-- ─────────────────────────────────────────────────────────────
create table public.nom035_campanas (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  centro_id    uuid references public.centros_trabajo(id) on delete cascade,

  nombre       text not null,
  abre         date not null default current_date,
  cierra       date,

  estado       text not null default 'abierta'
               check (estado in ('borrador','abierta','cerrada')),

  -- Se congela el universo al abrir: si se contara "activos hoy",
  -- el porcentaje de participacion cambiaria cada vez que entra o
  -- sale alguien, y dos reportes del mismo periodo no cuadrarian.
  universo     integer,

  creado_por   uuid references public.perfiles(id),
  creado_en    timestamptz not null default now()
);

create index camp_tenant_idx on public.nom035_campanas (tenant_id, estado, abre desc);

-- ─────────────────────────────────────────────────────────────
--  RESPUESTAS
-- ─────────────────────────────────────────────────────────────
create table public.nom035_respuestas (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  campana_id    uuid references public.nom035_campanas(id) on delete set null,
  empleado_id   uuid not null references public.empleados(id) on delete cascade,
  centro_id     uuid references public.centros_trabajo(id) on delete set null,

  guia          public.guia_nom035 not null,
  aplica_frp    boolean not null default true,

  -- Filtros que determinan que items aplicaron
  atiende_clientes boolean,
  es_jefe          boolean,

  items_aplicables integer,
  items_totales    integer,
  rango_ajustado   boolean not null default false,

  -- Resultado
  puntaje_total integer,
  nivel_total   text,
  gi_requiere_valoracion boolean not null default false,
  gi_detalle    jsonb,

  -- Desglose calculado, para no recalcular en cada consulta
  por_categoria jsonb,
  por_dominio   jsonb,
  por_dimension jsonb,

  contestado_en timestamptz not null default now(),

  -- Una respuesta por persona por campana: contestar dos veces
  -- duplicaria su peso en el agregado del centro.
  unique (campana_id, empleado_id)
);

create index resp_tenant_idx on public.nom035_respuestas (tenant_id, contestado_en desc);
create index resp_camp_idx   on public.nom035_respuestas (campana_id, centro_id);

create table public.nom035_respuestas_item (
  id           uuid primary key default gen_random_uuid(),
  respuesta_id uuid not null references public.nom035_respuestas(id) on delete cascade,
  item_id      uuid references public.nom035_items(id) on delete set null,
  numero       integer not null,
  valor        smallint not null check (valor between 0 and 4),
  puntaje      smallint not null,

  unique (respuesta_id, numero)
);

create index resp_item_idx on public.nom035_respuestas_item (respuesta_id);

-- ═══════════════════════════════════════════════════════════
--  EL MOTOR
-- ═══════════════════════════════════════════════════════════

/* Nivel según los cortes.
   Cuatro cortes, cinco niveles. Se compara con < porque los
   cortes del DOF son el piso de cada nivel. */
create or replace function app.nom035_nivel(p_puntaje numeric, p_cortes numeric[])
returns text
language sql
immutable
as $$
  select case
    when p_puntaje < p_cortes[1] then 'Nulo'
    when p_puntaje < p_cortes[2] then 'Bajo'
    when p_puntaje < p_cortes[3] then 'Medio'
    when p_puntaje < p_cortes[4] then 'Alto'
    else 'Muy alto' end
$$;

/* Escala los cortes a la proporción de ítems respondidos.
   Ejemplo: "Relaciones en el trabajo" tiene 6 ítems y su corte
   de Alto es 11. Si el trabajador no supervisa personal solo
   contesta 3, y su puntaje máximo posible (12) apenas rozaría
   ese corte. Sin escalar, quien contesta menos ítems sale
   sistemáticamente en niveles más bajos.

   CRITERIO INTERNO: el DOF no lo contempla. Queda documentado
   en el informe y en la columna rango_ajustado. */
create or replace function app.nom035_escalar(
  p_cortes      integer[],
  p_respondidos integer,
  p_esperados   integer
)
returns numeric[]
language sql
immutable
as $$
  select case
    when not coalesce(current_setting('rhoo.ajustar_rango', true)::boolean, true)
      then p_cortes::numeric[]
    when p_esperados is null or p_respondidos is null or p_esperados = 0
      then p_cortes::numeric[]
    when p_respondidos >= p_esperados
      then p_cortes::numeric[]
    else array(
      select round(c * p_respondidos::numeric / p_esperados, 2)
      from unnest(p_cortes) c
    )
  end
$$;

/* Puntaje de un ítem según su dirección.
   directa: Siempre=4, Casi siempre=3, Algunas veces=2, Casi
   nunca=1, Nunca=0. inversa al revés. El valor que llega del
   cuestionario es el índice de la opción (0 a 4). */
create or replace function app.nom035_puntaje(p_valor smallint, p_direccion text)
returns smallint
language sql
immutable
as $$
  select case when p_direccion = 'inversa' then p_valor else (4 - p_valor) end::smallint
$$;

/* CALIFICA una respuesta completa.
   Es el corazón del módulo: recibe los ítems contestados y
   devuelve puntaje, nivel y desglose por categoría, dominio y
   dimensión, con los rangos ya escalados si aplica. */
create or replace function public.nom035_calificar(
  p_guia          public.guia_nom035,
  p_respuestas    jsonb,      -- [{numero, valor}]
  p_clientes      boolean default null,
  p_jefe          boolean default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_total     integer := 0;
  v_nresp     integer := 0;
  v_esperados integer;
  v_cortes    integer[];
  v_esc       numeric[];
  v_ajuste    boolean := false;
  v_cat       jsonb := '{}'::jsonb;
  v_dom       jsonb := '{}'::jsonb;
  v_dim       jsonb := '{}'::jsonb;
  r           record;
begin
  -- Puntajes item por item, uniendo con el catalogo para saber
  -- direccion, categoria y dominio.
  create temp table if not exists _cal (
    numero integer, valor smallint, puntaje smallint,
    categoria text, dominio text, dimension text
  ) on commit drop;
  delete from _cal;

  insert into _cal (numero, valor, puntaje, categoria, dominio, dimension)
  select i.numero,
         (x->>'valor')::smallint,
         app.nom035_puntaje((x->>'valor')::smallint, i.direccion),
         i.categoria, i.dominio, i.dimension
  from jsonb_array_elements(p_respuestas) x
  join public.nom035_items i
    on i.guia = p_guia and i.numero = (x->>'numero')::integer and i.activo;

  select coalesce(sum(puntaje),0), count(*) into v_total, v_nresp from _cal;

  -- ── TOTAL ──
  select cortes into v_cortes from public.nom035_rangos
   where guia = p_guia and ambito = 'total';

  -- Items que APLICABAN a esta persona segun sus filtros
  select count(*) into v_esperados
  from public.nom035_items i
  where i.guia = p_guia and i.activo
    and (i.condicional is null
         or (i.condicional = 'clientes' and coalesce(p_clientes,false))
         or (i.condicional = 'jefe' and coalesce(p_jefe,false)));

  v_esc := app.nom035_escalar(v_cortes, v_nresp, v_esperados);
  if v_esc::text <> v_cortes::text then v_ajuste := true; end if;

  -- ── POR CATEGORIA ──
  for r in
    select c.categoria, sum(c.puntaje) as pts, count(*) as n,
           (select count(*) from public.nom035_items i
             where i.guia = p_guia and i.activo and i.categoria = c.categoria
               and (i.condicional is null
                    or (i.condicional='clientes' and coalesce(p_clientes,false))
                    or (i.condicional='jefe' and coalesce(p_jefe,false)))) as esp,
           (select cortes from public.nom035_rangos
             where guia = p_guia and ambito='categoria' and nombre = c.categoria) as ct
    from _cal c where c.categoria is not null
    group by c.categoria
  loop
    if r.ct is null then
      v_cat := v_cat || jsonb_build_object(r.categoria, jsonb_build_object(
        'puntaje', r.pts, 'nivel', 'Sin rango', 'items', r.n));
    else
      v_esc := app.nom035_escalar(r.ct, r.n::integer, r.esp::integer);
      if v_esc::text <> r.ct::text then v_ajuste := true; end if;
      v_cat := v_cat || jsonb_build_object(r.categoria, jsonb_build_object(
        'puntaje', r.pts,
        'nivel', app.nom035_nivel(r.pts, v_esc),
        'items', r.n, 'esperados', r.esp,
        'parcial', r.n < r.esp));
    end if;
  end loop;

  -- ── POR DOMINIO ──
  for r in
    select c.dominio, sum(c.puntaje) as pts, count(*) as n,
           (select count(*) from public.nom035_items i
             where i.guia = p_guia and i.activo and i.dominio = c.dominio
               and (i.condicional is null
                    or (i.condicional='clientes' and coalesce(p_clientes,false))
                    or (i.condicional='jefe' and coalesce(p_jefe,false)))) as esp,
           (select cortes from public.nom035_rangos
             where guia = p_guia and ambito='dominio' and nombre = c.dominio) as ct
    from _cal c where c.dominio is not null
    group by c.dominio
  loop
    if r.ct is null then
      v_dom := v_dom || jsonb_build_object(r.dominio, jsonb_build_object(
        'puntaje', r.pts, 'nivel', 'Sin rango', 'items', r.n));
    else
      v_esc := app.nom035_escalar(r.ct, r.n::integer, r.esp::integer);
      if v_esc::text <> r.ct::text then v_ajuste := true; end if;
      v_dom := v_dom || jsonb_build_object(r.dominio, jsonb_build_object(
        'puntaje', r.pts,
        'nivel', app.nom035_nivel(r.pts, v_esc),
        'items', r.n, 'esperados', r.esp,
        'parcial', r.n < r.esp));
    end if;
  end loop;

  -- ── POR DIMENSION ──
  -- El DOF no publica rangos por dimension, asi que se reporta
  -- el puntaje y su maximo posible: sirve para diagnostico fino
  -- sin inventar un nivel que la norma no define.
  for r in
    select c.dimension, sum(c.puntaje) as pts, count(*) as n
    from _cal c where c.dimension is not null
    group by c.dimension
  loop
    v_dim := v_dim || jsonb_build_object(r.dimension, jsonb_build_object(
      'puntaje', r.pts, 'items', r.n, 'maximo', r.n * 4));
  end loop;

  -- Se recalcula el total escalado al final
  select cortes into v_cortes from public.nom035_rangos
   where guia = p_guia and ambito = 'total';
  v_esc := app.nom035_escalar(v_cortes, v_nresp, v_esperados);

  return jsonb_build_object(
    'guia', p_guia,
    'puntaje_total', v_total,
    'nivel_total', app.nom035_nivel(v_total, v_esc),
    'items_respondidos', v_nresp,
    'items_aplicables', v_esperados,
    'rango_ajustado', v_ajuste,
    'por_categoria', v_cat,
    'por_dominio', v_dom,
    'por_dimension', v_dim
  );
end;
$$;

/* Guía I: ramificación oficial.
   Solo si hay al menos un "Sí" en la Sección I se aplican las
   demás. Requiere valoración si además se cumple el criterio de
   alguna sección posterior. */
create or replace function public.nom035_calificar_guia1(p_resp jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_s1 boolean := false;
  v_s2 boolean := false;
  v_c3 integer := 0;
  v_c4 integer := 0;
  i    integer;
begin
  for i in 1..6 loop
    if lower(coalesce(p_resp->>('s1_'||i),'')) = 'si' then v_s1 := true; end if;
  end loop;

  if not v_s1 then
    return jsonb_build_object('requiere_valoracion', false,
      'motivo','Seccion I negativa', 'seccion1', false);
  end if;

  for i in 1..2 loop
    if lower(coalesce(p_resp->>('s2_'||i),'')) = 'si' then v_s2 := true; end if;
  end loop;
  for i in 1..7 loop
    if lower(coalesce(p_resp->>('s3_'||i),'')) = 'si' then v_c3 := v_c3 + 1; end if;
  end loop;
  for i in 1..5 loop
    if lower(coalesce(p_resp->>('s4_'||i),'')) = 'si' then v_c4 := v_c4 + 1; end if;
  end loop;

  return jsonb_build_object(
    'requiere_valoracion', v_s2 or v_c3 >= 3 or v_c4 >= 2,
    'seccion1', true, 'seccion2', v_s2,
    'seccion3', v_c3 >= 3, 'seccion4', v_c4 >= 2,
    'conteo3', v_c3, 'conteo4', v_c4
  );
end;
$$;

/* Qué guía le toca a un empleado.
   Depende del tamaño del CENTRO, no del tenant: la Norma habla
   de centro de trabajo. De 1 a 15 solo Guía I; de 16 a 50 Guía
   II; más de 50 Guía III.
   Lo decide el servidor: si el cliente mandara la guía, un
   navegador manipulado podría pedir la más corta. */
create or replace function public.nom035_guia_de(p_empleado_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  e       public.empleados;
  v_n     integer;
  v_guia  public.guia_nom035;
begin
  select * into e from public.empleados where id = p_empleado_id;
  if not found then return jsonb_build_object('error','Empleado no encontrado'); end if;

  select count(*) into v_n from public.empleados
   where tenant_id = e.tenant_id
     and centro_id is not distinct from e.centro_id
     and estatus = 'Activo';

  if v_n <= 15 then v_guia := 'guia1';
  elsif v_n <= 50 then v_guia := 'guia2';
  else v_guia := 'guia3'; end if;

  return jsonb_build_object(
    'guia', v_guia,
    'activos_centro', v_n,
    -- Con 15 o menos solo se identifican acontecimientos
    -- traumaticos: el numeral 2 inciso a) no pide identificar
    -- factores de riesgo psicosocial en centros tan chicos.
    'aplica_frp', v_n > 15
  );
end;
$$;

grant execute on function public.nom035_calificar(public.guia_nom035,jsonb,boolean,boolean) to authenticated, anon;
grant execute on function public.nom035_calificar_guia1(jsonb) to authenticated, anon;
grant execute on function public.nom035_guia_de(uuid) to authenticated, anon;

-- ═══════════════════════════════════════════════════════════
--  IMPORTACION DE ITEMS
-- ═══════════════════════════════════════════════════════════

/* Recibe el JSON exportado del sistema anterior.
   Los items del DOF son los mismos para todos los clientes, asi
   que la tabla NO lleva tenant_id: es catalogo global. */
create or replace function public.nom035_importar_items(p_datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  g      text;
  x      jsonb;
  s      jsonb;
  p      jsonb;
  v_n    integer := 0;
  v_g1   integer := 0;
  v_sec  integer;
  v_ord  integer;
begin
  if not app.es_proveedor() then
    raise exception 'Solo el proveedor puede importar el catalogo oficial';
  end if;

  foreach g in array array['guia1','guia2','guia3'] loop
    if p_datos ? g then
      for x in select * from jsonb_array_elements(p_datos->g) loop
        insert into public.nom035_items
          (guia, numero, pregunta, categoria, dominio, dimension,
           direccion, condicional, oficial)
        values (
          g::public.guia_nom035,
          (x->>'item')::integer,
          x->>'pregunta',
          nullif(x->>'categoria',''),
          nullif(x->>'dominio',''),
          nullif(x->>'dimension',''),
          coalesce(nullif(x->>'direccion',''),'directa'),
          nullif(x->>'condicional',''),
          true
        )
        on conflict (guia, numero) do update set
          pregunta   = excluded.pregunta,
          categoria  = excluded.categoria,
          dominio    = excluded.dominio,
          dimension  = excluded.dimension,
          direccion  = excluded.direccion,
          condicional= excluded.condicional;
        v_n := v_n + 1;
      end loop;
    end if;
  end loop;

  -- Guia I
  if p_datos ? 'guia1_secciones' then
    v_sec := 0;
    for s in select * from jsonb_array_elements(p_datos->'guia1_secciones') loop
      v_sec := v_sec + 1;
      v_ord := 0;
      for p in select * from jsonb_array_elements(s->'preguntas') loop
        v_ord := v_ord + 1;
        insert into public.nom035_guia1
          (seccion, seccion_tit, instruccion, clave, orden, texto)
        values (v_sec, s->>'titulo', nullif(s->>'instruccion',''),
                p->>'id', v_ord, p->>'texto')
        on conflict (clave) do update set
          seccion = excluded.seccion,
          seccion_tit = excluded.seccion_tit,
          instruccion = excluded.instruccion,
          texto = excluded.texto;
        v_g1 := v_g1 + 1;
      end loop;
    end loop;
  end if;

  return jsonb_build_object('status','success',
    'items_frp', v_n, 'preguntas_guia1', v_g1);
end;
$$;

grant execute on function public.nom035_importar_items(jsonb) to authenticated;

-- ═══════════════════════════════════════════════════════════
--  RLS
-- ═══════════════════════════════════════════════════════════
alter table public.nom035_items           enable row level security;
alter table public.nom035_guia1           enable row level security;
alter table public.nom035_rangos          enable row level security;
alter table public.nom035_campanas        enable row level security;
alter table public.nom035_respuestas      enable row level security;
alter table public.nom035_respuestas_item enable row level security;

-- Catálogo oficial: lo lee cualquiera (incluso sin sesión, para
-- el cuestionario público), solo el proveedor lo escribe.
create policy items_leer on public.nom035_items for select using (true);
create policy g1_leer    on public.nom035_guia1 for select using (true);
create policy rangos_leer on public.nom035_rangos for select using (true);

create policy items_escribir on public.nom035_items
  for all using (app.es_proveedor()) with check (app.es_proveedor());
create policy g1_escribir on public.nom035_guia1
  for all using (app.es_proveedor()) with check (app.es_proveedor());
create policy rangos_escribir on public.nom035_rangos
  for all using (app.es_proveedor()) with check (app.es_proveedor());

create policy camp_leer on public.nom035_campanas
  for select using (tenant_id = app.mi_tenant() or app.es_proveedor());
create policy camp_escribir on public.nom035_campanas
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

/* Las respuestas individuales SOLO las ve RH y el propio
   trabajador. Un jefe NO puede ver los resultados de su equipo:
   la Guía I detecta acontecimientos traumáticos y la II y III
   miden, entre otras cosas, la calidad de su liderazgo. Dejarlo
   verlas invalidaría las respuestas. */
create policy resp_leer on public.nom035_respuestas
  for select using (
    tenant_id = app.mi_tenant() and (
      app.es_admin()
      or empleado_id = (select empleado_id from public.perfiles where id = auth.uid())
    )
  );
create policy resp_escribir on public.nom035_respuestas
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());
create policy zz_prov_resp on public.nom035_respuestas
  for all using (app.es_proveedor()) with check (app.es_proveedor());

create policy respitem_leer on public.nom035_respuestas_item
  for select using (exists (
    select 1 from public.nom035_respuestas r
    where r.id = respuesta_id
      and r.tenant_id = app.mi_tenant()
      and (app.es_admin()
           or r.empleado_id = (select empleado_id from public.perfiles where id = auth.uid()))
  ));
create policy zz_prov_respitem on public.nom035_respuestas_item
  for all using (app.es_proveedor()) with check (app.es_proveedor());

grant select on public.nom035_items, public.nom035_guia1, public.nom035_rangos
  to authenticated, anon;
grant select, insert, update, delete
  on public.nom035_campanas, public.nom035_respuestas, public.nom035_respuestas_item
  to authenticated;