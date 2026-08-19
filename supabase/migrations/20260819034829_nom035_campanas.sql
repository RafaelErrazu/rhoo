-- ═══════════════════════════════════════════════════════════
--  RHoo! · NOM-035 · campañas y captura
-- ═══════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────
--  INVITACIONES
--
--  Un token por trabajador. Un link generico significa que
--  cualquiera contesta por cualquiera, no se sabe quien falta y
--  la participacion deja de ser medible.
--
--  Se guarda el token en claro a proposito: RH necesita poder
--  reenviarlo por correo o imprimirlo en un QR. No es una
--  credencial de acceso al sistema, solo abre un cuestionario, y
--  se invalida al usarse.
-- ─────────────────────────────────────────────────────────────
create table public.nom035_invitaciones (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  campana_id   uuid not null references public.nom035_campanas(id) on delete cascade,
  empleado_id  uuid not null references public.empleados(id) on delete cascade,

  token        text not null unique,
  guia         public.guia_nom035 not null,
  aplica_frp   boolean not null default true,

  usado_en     timestamptz,
  enviado_en   timestamptz,
  intentos     integer not null default 0,

  creado_en    timestamptz not null default now(),
  unique (campana_id, empleado_id)
);

create index inv_camp_idx on public.nom035_invitaciones (campana_id, usado_en);
create index inv_token_idx on public.nom035_invitaciones (token) where usado_en is null;

alter table public.nom035_campanas
  add column if not exists muestra_minima integer,
  add column if not exists nota text;

-- ─────────────────────────────────────────────────────────────
--  TAMAÑO DE MUESTRA · numeral III.1
--
--  n = 0.9604·N / (0.0025·(N−1) + 0.9604)
--
--  Un centro de 300 personas necesita 169 respuestas, no 300.
--  Saberlo cambia la meta de la campaña y hace alcanzable el
--  cumplimiento; ignorarlo hace que RH persiga un 100% que la
--  Norma no exige.
-- ─────────────────────────────────────────────────────────────
create or replace function public.nom035_muestra(p_total integer)
returns integer
language sql
immutable
as $$
  select case
    when p_total is null or p_total <= 0 then 0
    -- Hasta 50 la Norma pide a TODOS (numeral 7.1 inciso a):
    -- la muestra solo aplica a centros de mas de 50.
    when p_total <= 50 then p_total
    else ceil(0.9604 * p_total / (0.0025 * (p_total - 1) + 0.9604))::integer
  end
$$;

comment on function public.nom035_muestra is
  'Tamano minimo de muestra, Ecuacion 1 del numeral III.1. Centros de hasta 50 trabajadores requieren aplicacion total.';

-- ─────────────────────────────────────────────────────────────
--  ABRIR CAMPAÑA
--
--  Congela el universo y genera un token por trabajador. El
--  universo se congela porque si se contara "activos hoy", el
--  porcentaje de participacion cambiaria cada vez que entra o
--  sale alguien, y dos reportes del mismo periodo no cuadrarian.
-- ─────────────────────────────────────────────────────────────
create or replace function public.nom035_abrir_campana(
  p_nombre    text,
  p_centro_id uuid,
  p_cierra    date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp, extensions
as $$
declare
  v_id      uuid;
  v_univ    integer;
  v_guia    public.guia_nom035;
  v_frp     boolean;
  v_n       integer := 0;
  r         record;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  if exists (select 1 from public.nom035_campanas
             where tenant_id = app.mi_tenant()
               and centro_id is not distinct from p_centro_id
               and estado = 'abierta') then
    raise exception 'Ya hay una campana abierta para ese centro de trabajo. Cierrala antes de abrir otra.';
  end if;

  select count(*) into v_univ
  from public.empleados
  where tenant_id = app.mi_tenant()
    and estatus = 'Activo'
    and (p_centro_id is null or centro_id = p_centro_id);

  if v_univ = 0 then
    raise exception 'No hay trabajadores activos en ese centro de trabajo';
  end if;

  -- La guia depende del tamano del CENTRO, no del tenant
  if v_univ <= 15 then v_guia := 'guia1'; v_frp := false;
  elsif v_univ <= 50 then v_guia := 'guia2'; v_frp := true;
  else v_guia := 'guia3'; v_frp := true; end if;

  insert into public.nom035_campanas
    (tenant_id, centro_id, nombre, abre, cierra, estado, universo,
     muestra_minima, creado_por)
  values
    (app.mi_tenant(), p_centro_id, p_nombre, current_date, p_cierra,
     'abierta', v_univ, public.nom035_muestra(v_univ), auth.uid())
  returning id into v_id;

  -- Un token por trabajador
  for r in
    select id from public.empleados
    where tenant_id = app.mi_tenant()
      and estatus = 'Activo'
      and (p_centro_id is null or centro_id = p_centro_id)
  loop
    insert into public.nom035_invitaciones
      (tenant_id, campana_id, empleado_id, token, guia, aplica_frp)
    values
      (app.mi_tenant(), v_id, r.id,
       encode(gen_random_bytes(16),'hex'), v_guia, v_frp);
    v_n := v_n + 1;
  end loop;

  perform app.auditar('nom035.abrir_campana', 'nom035_campanas', v_id::text, null,
    jsonb_build_object('nombre', p_nombre, 'universo', v_univ, 'guia', v_guia));

  return jsonb_build_object(
    'status','success', 'id', v_id,
    'universo', v_univ, 'invitaciones', v_n,
    'guia', v_guia, 'aplica_frp', v_frp,
    'muestra_minima', public.nom035_muestra(v_univ)
  );
end;
$$;

/* Cierra la campaña. Los tokens sin usar dejan de servir. */
create or replace function public.nom035_cerrar_campana(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_resp integer; v_min integer;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  select count(*) into v_resp from public.nom035_respuestas where campana_id = p_id;
  select muestra_minima into v_min from public.nom035_campanas
   where id = p_id and tenant_id = app.mi_tenant();

  update public.nom035_campanas
     set estado = 'cerrada', cierra = coalesce(cierra, current_date)
   where id = p_id and tenant_id = app.mi_tenant();

  perform app.auditar('nom035.cerrar_campana', 'nom035_campanas', p_id::text, null,
    jsonb_build_object('respuestas', v_resp, 'muestra_minima', v_min));

  return jsonb_build_object(
    'status','success', 'respuestas', v_resp, 'muestra_minima', v_min,
    -- Se avisa si cierra por debajo de la muestra: cerrar sin
    -- alcanzarla deja el cumplimiento incompleto y conviene que
    -- quede claro AHORA, no en la inspeccion.
    'alcanzo_muestra', v_resp >= coalesce(v_min, 0)
  );
end;
$$;

/* Avance de la campaña. Quién contestó y quién no, sin exponer
   ninguna respuesta: RH necesita perseguir a los que faltan. */
create or replace function public.nom035_avance(p_campana_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  c public.nom035_campanas;
  v_resp integer;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  select * into c from public.nom035_campanas
   where id = p_campana_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Campana no encontrada'; end if;

  select count(*) into v_resp from public.nom035_respuestas
   where campana_id = p_campana_id;

  return jsonb_build_object(
    'status','success',
    'campana', jsonb_build_object(
      'id', c.id, 'nombre', c.nombre, 'estado', c.estado,
      'abre', c.abre, 'cierra', c.cierra,
      'universo', c.universo, 'muestra_minima', c.muestra_minima),
    'respuestas', v_resp,
    'pct_universo', case when c.universo > 0
                    then round(v_resp * 100.0 / c.universo) else 0 end,
    'pct_muestra', case when coalesce(c.muestra_minima,0) > 0
                   then least(100, round(v_resp * 100.0 / c.muestra_minima)) else 0 end,
    'falta_para_muestra', greatest(0, coalesce(c.muestra_minima,0) - v_resp),
    'pendientes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'empleado_id', e.id, 'nombre', e.nombre_completo,
        'no', e.no_empleado, 'email', e.email,
        'token', i.token, 'enviado', i.enviado_en is not null)
        order by e.nombre_completo)
      from public.nom035_invitaciones i
      join public.empleados e on e.id = i.empleado_id
      where i.campana_id = p_campana_id and i.usado_en is null
    ), '[]'::jsonb),
    -- Solo nombres de quien SI contesto, nunca su resultado
    'contestaron', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nombre', e.nombre_completo, 'cuando', i.usado_en)
        order by i.usado_en desc)
      from public.nom035_invitaciones i
      join public.empleados e on e.id = i.empleado_id
      where i.campana_id = p_campana_id and i.usado_en is not null
    ), '[]'::jsonb)
  );
end;
$$;

/* Campañas del tenant, para la lista. */
create or replace function public.nom035_campanas_lista()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'nombre', c.nombre, 'estado', c.estado,
    'abre', c.abre, 'cierra', c.cierra,
    'centro', (select clave from public.centros_trabajo where id = c.centro_id),
    'universo', c.universo, 'muestra_minima', c.muestra_minima,
    'respuestas', (select count(*) from public.nom035_respuestas r
                   where r.campana_id = c.id),
    'guia', (select guia from public.nom035_invitaciones i
             where i.campana_id = c.id limit 1)
  ) order by c.abre desc, c.creado_en desc), '[]'::jsonb)
  from public.nom035_campanas c
  where c.tenant_id = app.mi_tenant() and app.es_admin()
$$;

-- ═══════════════════════════════════════════════════════════
--  CUESTIONARIO PÚBLICO
-- ═══════════════════════════════════════════════════════════

/* Abre el cuestionario con un token.
   Público a propósito: el trabajador no tiene sesión en RHoo!.
   Nunca devuelve el nombre de la persona: el token identifica
   para saber quién falta, no para etiquetar la respuesta. */
create or replace function public.nom035_abrir_cuestionario(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  i     public.nom035_invitaciones;
  c     public.nom035_campanas;
  v_est jsonb;
begin
  select * into i from public.nom035_invitaciones where token = p_token;
  if not found then
    return jsonb_build_object('status','error','motivo','token_invalido',
      'message','Este enlace no es válido. Solicita uno nuevo a Recursos Humanos.');
  end if;

  if i.usado_en is not null then
    return jsonb_build_object('status','error','motivo','ya_contestado',
      'message','Ya registramos tus respuestas. Gracias por participar.');
  end if;

  select * into c from public.nom035_campanas where id = i.campana_id;
  if c.estado <> 'abierta' then
    return jsonb_build_object('status','error','motivo','cerrada',
      'message','El periodo para contestar ya terminó.');
  end if;
  if c.cierra is not null and c.cierra < current_date then
    return jsonb_build_object('status','error','motivo','cerrada',
      'message','El periodo para contestar cerró el ' || c.cierra || '.');
  end if;

  update public.nom035_invitaciones
     set intentos = intentos + 1 where id = i.id;

  return jsonb_build_object(
    'status','success',
    'guia', i.guia,
    'aplica_frp', i.aplica_frp,
    'campana', c.nombre,
    'cierra', c.cierra,
    'guia1', public.nom035_estructura_guia1(),
    -- Los items condicionales se marcan pero NO se filtran aqui:
    -- el filtro depende de dos preguntas que el trabajador aun no
    -- contesta.
    'items', case when i.aplica_frp then coalesce((
      select jsonb_agg(jsonb_build_object(
        'numero', numero, 'pregunta', pregunta,
        'preambulo', preambulo, 'condicional', condicional)
        order by numero)
      from public.nom035_items
      where guia = i.guia and activo
    ), '[]'::jsonb) else '[]'::jsonb end,
    'opciones', jsonb_build_array(
      'Siempre','Casi siempre','Algunas veces','Casi nunca','Nunca')
  );
end;
$$;

/* Guarda las respuestas. Corre el motor y sella el token. */
create or replace function public.nom035_guardar(
  p_token      text,
  p_guia1      jsonb default '{}'::jsonb,
  p_items      jsonb default '[]'::jsonb,
  p_clientes   boolean default null,
  p_jefe       boolean default null,
  p_datos      jsonb default null      -- ficha Guía V
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  i        public.nom035_invitaciones;
  c        public.nom035_campanas;
  e        public.empleados;
  v_g1     jsonb;
  v_frp    jsonb := '{}'::jsonb;
  v_id     uuid;
  x        jsonb;
begin
  select * into i from public.nom035_invitaciones where token = p_token;
  if not found then
    return jsonb_build_object('status','error','message','Enlace no válido');
  end if;
  if i.usado_en is not null then
    return jsonb_build_object('status','error','message','Ya registramos tus respuestas');
  end if;

  select * into c from public.nom035_campanas where id = i.campana_id;
  if c.estado <> 'abierta' then
    return jsonb_build_object('status','error','message','El periodo ya cerró');
  end if;

  select * into e from public.empleados where id = i.empleado_id;

  -- Guia I siempre se califica
  v_g1 := public.nom035_calificar_guia1(coalesce(p_guia1,'{}'::jsonb));

  -- FRP solo si aplica al centro
  if i.aplica_frp and jsonb_array_length(coalesce(p_items,'[]'::jsonb)) > 0 then
    v_frp := public.nom035_calificar(i.guia, p_items, p_clientes, p_jefe);
  end if;

  insert into public.nom035_respuestas (
    tenant_id, campana_id, empleado_id, centro_id, guia, aplica_frp,
    atiende_clientes, es_jefe,
    items_aplicables, items_totales, rango_ajustado,
    puntaje_total, nivel_total,
    gi_requiere_valoracion, gi_detalle,
    por_categoria, por_dominio, por_dimension
  ) values (
    i.tenant_id, i.campana_id, i.empleado_id, e.centro_id, i.guia, i.aplica_frp,
    p_clientes, p_jefe,
    (v_frp->>'items_aplicables')::integer,
    (v_frp->>'items_respondidos')::integer,
    coalesce((v_frp->>'rango_ajustado')::boolean, false),
    (v_frp->>'puntaje_total')::integer,
    v_frp->>'nivel_total',
    coalesce((v_g1->>'requiere_valoracion')::boolean, false),
    v_g1,
    v_frp->'por_categoria', v_frp->'por_dominio', v_frp->'por_dimension'
  ) returning id into v_id;

  -- Respuesta por item: permite reanalisis y auditoria del
  -- calculo. Sin esto, un cambio en el motor no se puede aplicar
  -- retroactivamente.
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb)) > 0 then
    insert into public.nom035_respuestas_item (respuesta_id, item_id, numero, valor, puntaje)
    select v_id, it.id, (x->>'numero')::integer, (x->>'valor')::smallint,
           app.nom035_puntaje((x->>'valor')::smallint, it.direccion)
    from jsonb_array_elements(p_items) x
    join public.nom035_items it
      on it.guia = i.guia and it.numero = (x->>'numero')::integer;
  end if;

  -- Ficha de datos del trabajador (Guía V)
  if p_datos is not null and p_datos <> '{}'::jsonb then
    insert into public.nom035_fichas
      (tenant_id, campana_id, respuesta_id, empleado_id, centro_id, datos)
    values (i.tenant_id, i.campana_id, v_id, i.empleado_id, e.centro_id, p_datos);
  end if;

  update public.nom035_invitaciones set usado_en = now() where id = i.id;

  return jsonb_build_object(
    'status','success',
    -- Se devuelve el resultado propio: es SU dato y tiene derecho
    -- a conocerlo. Lo que no se muestra es el de nadie mas.
    'nivel', v_frp->>'nivel_total',
    'requiere_valoracion', coalesce((v_g1->>'requiere_valoracion')::boolean, false)
  );
end;
$$;

/* Ficha de datos del trabajador · Guía V.
   En tabla aparte porque su ciclo de vida es distinto: sirve
   para segmentar el analisis, no para calificar riesgo. */
create table public.nom035_fichas (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  campana_id   uuid references public.nom035_campanas(id) on delete set null,
  respuesta_id uuid references public.nom035_respuestas(id) on delete cascade,
  empleado_id  uuid references public.empleados(id) on delete set null,
  centro_id    uuid references public.centros_trabajo(id) on delete set null,
  datos        jsonb not null default '{}'::jsonb,
  creado_en    timestamptz not null default now()
);

create index fichas_camp_idx on public.nom035_fichas (tenant_id, campana_id);

alter table public.nom035_fichas enable row level security;
create policy fichas_leer on public.nom035_fichas
  for select using (tenant_id = app.mi_tenant() and app.es_admin());
create policy zz_prov_fichas on public.nom035_fichas
  for all using (app.es_proveedor()) with check (app.es_proveedor());

alter table public.nom035_invitaciones enable row level security;
create policy inv_leer on public.nom035_invitaciones
  for select using (tenant_id = app.mi_tenant() and app.es_admin());
create policy inv_escribir on public.nom035_invitaciones
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());
create policy zz_prov_inv on public.nom035_invitaciones
  for all using (app.es_proveedor()) with check (app.es_proveedor());

grant select, insert, update, delete
  on public.nom035_invitaciones, public.nom035_fichas to authenticated;

grant execute on function public.nom035_muestra(integer)                   to authenticated, anon;
grant execute on function public.nom035_abrir_campana(text,uuid,date)      to authenticated;
grant execute on function public.nom035_cerrar_campana(uuid)               to authenticated;
grant execute on function public.nom035_avance(uuid)                       to authenticated;
grant execute on function public.nom035_campanas_lista()                   to authenticated;
-- El cuestionario lo abre gente SIN sesion: por eso anon.
grant execute on function public.nom035_abrir_cuestionario(text)           to anon, authenticated;
grant execute on function public.nom035_guardar(text,jsonb,jsonb,boolean,boolean,jsonb) to anon, authenticated;