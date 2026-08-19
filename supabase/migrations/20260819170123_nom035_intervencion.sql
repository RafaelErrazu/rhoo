-- ═══════════════════════════════════════════════════════════
--  RHoo! · NOM-035 · programa de intervención y difusión
-- ═══════════════════════════════════════════════════════════

create table public.nom035_programas (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  campana_id  uuid not null references public.nom035_campanas(id) on delete cascade,
  centro_id   uuid references public.centros_trabajo(id) on delete set null,

  nombre      text not null,
  nivel_origen text,            -- el nivel que lo detonó
  estado      text not null default 'borrador'
              check (estado in ('borrador','activo','concluido')),

  inicia      date not null default current_date,
  concluye    date,

  responsable_general uuid references public.empleados(id) on delete set null,
  creado_por  uuid references public.perfiles(id),
  creado_en   timestamptz not null default now(),

  unique (campana_id)
);

/* Acciones del programa.
   `nivel` es el nivel de intervención del numeral 8.4: primer
   nivel organizacional, segundo grupal, tercero individual. La
   Norma pide que las acciones se ubiquen en el plano correcto,
   no todas en capacitación. */
create table public.nom035_acciones (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  programa_id  uuid not null references public.nom035_programas(id) on delete cascade,

  dominio      text,            -- a qué dominio responde
  nivel_accion text not null default 'organizacional'
               check (nivel_accion in ('organizacional','grupal','individual')),

  accion       text not null,
  responsable_id uuid references public.empleados(id) on delete set null,
  responsable_txt text,          -- si es un área, no una persona

  fecha_meta   date,
  fecha_hecho  date,
  estado       text not null default 'pendiente'
               check (estado in ('pendiente','en_proceso','hecha','cancelada')),

  evidencia_ruta text,           -- Storage
  evidencia_nota text,
  nota         text,

  orden        integer not null default 100,
  creado_en    timestamptz not null default now()
);

create index acc_prog_idx on public.nom035_acciones (programa_id, orden);

/* Bitácora de difusión · numeral 7.8.
   La evidencia de difusion no es tener el informe guardado: es
   demostrar que la informacion llego a la gente. */
create table public.nom035_difusion (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  campana_id  uuid references public.nom035_campanas(id) on delete set null,
  empleado_id uuid references public.empleados(id) on delete set null,
  medio       text not null default 'consulta_web',
  consultado_en timestamptz not null default now()
);

create index dif_camp_idx on public.nom035_difusion (tenant_id, campana_id, consultado_en desc);

alter table public.nom035_programas enable row level security;
alter table public.nom035_acciones  enable row level security;
alter table public.nom035_difusion  enable row level security;

create policy prog_leer on public.nom035_programas
  for select using (tenant_id = app.mi_tenant());
create policy prog_escribir on public.nom035_programas
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

/* El responsable de una accion la ve y la puede marcar: si solo
   RH pudiera tocarla, cada avance seria un correo a RH y el
   programa se convertiria en trabajo administrativo. */
create policy acc_leer on public.nom035_acciones
  for select using (
    tenant_id = app.mi_tenant() and (
      app.es_admin()
      or responsable_id = (select empleado_id from public.perfiles where id = auth.uid()))
  );
create policy acc_escribir on public.nom035_acciones
  for all using (
    tenant_id = app.mi_tenant() and (
      app.es_admin()
      or responsable_id = (select empleado_id from public.perfiles where id = auth.uid()))
  )
  with check (tenant_id = app.mi_tenant());

create policy dif_leer on public.nom035_difusion
  for select using (tenant_id = app.mi_tenant() and app.es_admin());

create policy zz_prov_prog on public.nom035_programas
  for all using (app.es_proveedor()) with check (app.es_proveedor());
create policy zz_prov_acc on public.nom035_acciones
  for all using (app.es_proveedor()) with check (app.es_proveedor());
create policy zz_prov_dif on public.nom035_difusion
  for all using (app.es_proveedor()) with check (app.es_proveedor());

grant select, insert, update, delete
  on public.nom035_programas, public.nom035_acciones, public.nom035_difusion
  to authenticated;

-- ─────────────────────────────────────────────────────────────
--  CATÁLOGO DE ACCIONES SUGERIDAS · numeral 8.2
--
--  Precargar no es hacerle el trabajo al cliente: es que empiece
--  desde algo. Un programa en blanco es un programa que no se
--  hace, y la Norma ya dice qué acciones espera para cada tipo
--  de factor de riesgo.
-- ─────────────────────────────────────────────────────────────
create or replace function app.nom035_acciones_sugeridas(p_dominio text)
returns jsonb
language sql
immutable
as $$
  select case p_dominio
    when 'Carga de trabajo' then '[
      {"n":"organizacional","a":"Revisar y redistribuir la carga de trabajo de forma equitativa, considerando el número de trabajadores y su capacitación"},
      {"n":"organizacional","a":"Planificar el trabajo con pausas o periodos de descanso y rotación de tareas para evitar ritmos acelerados"},
      {"n":"grupal","a":"Elaborar instructivos o procedimientos que definan claramente tareas y responsabilidades"}
    ]'::jsonb
    when 'Falta de control sobre el trabajo' then '[
      {"n":"organizacional","a":"Involucrar a los trabajadores en la toma de decisiones sobre la organización de su trabajo"},
      {"n":"grupal","a":"Realizar reuniones para abordar áreas de oportunidad y determinar soluciones en el lugar de trabajo"},
      {"n":"organizacional","a":"Detectar necesidades de capacitación e integrarlas al programa anual"}
    ]'::jsonb
    when 'Jornada de trabajo' then '[
      {"n":"organizacional","a":"Establecer medidas y límites que eviten jornadas superiores a las previstas en la Ley Federal del Trabajo"},
      {"n":"organizacional","a":"Involucrar a los trabajadores en la definición de horarios cuando las condiciones lo permitan"}
    ]'::jsonb
    when 'Interferencia en la relación trabajo-familia' then '[
      {"n":"organizacional","a":"Definir apoyos para que los trabajadores puedan atender emergencias familiares comprobables"},
      {"n":"grupal","a":"Promover actividades de integración familiar, previo acuerdo con los trabajadores"}
    ]'::jsonb
    when 'Liderazgo' then '[
      {"n":"organizacional","a":"Capacitar y sensibilizar a directivos, gerentes y supervisores en prevención de factores de riesgo psicosocial"},
      {"n":"grupal","a":"Establecer mecanismos que fomenten la comunicación entre supervisores y trabajadores"},
      {"n":"grupal","a":"Difundir instrucciones claras para la atención de problemas que limiten el desarrollo del trabajo"}
    ]'::jsonb
    when 'Relaciones en el trabajo' then '[
      {"n":"grupal","a":"Implementar acciones para el manejo de conflictos en el trabajo"},
      {"n":"grupal","a":"Promover la ayuda mutua y el intercambio de conocimientos entre trabajadores"},
      {"n":"organizacional","a":"Establecer lineamientos que prohíban la discriminación y fomenten la equidad y el respeto"}
    ]'::jsonb
    when 'Violencia' then '[
      {"n":"organizacional","a":"Difundir información para sensibilizar sobre la violencia laboral a trabajadores y mandos"},
      {"n":"organizacional","a":"Establecer procedimientos de actuación y seguimiento para casos de violencia laboral, y capacitar al responsable"},
      {"n":"organizacional","a":"Informar la forma en que se denuncian los actos de violencia laboral y garantizar la confidencialidad"}
    ]'::jsonb
    when 'Reconocimiento del desempeño' then '[
      {"n":"organizacional","a":"Establecer mecanismos para reconocer el desempeño sobresaliente de los trabajadores"},
      {"n":"grupal","a":"Difundir los logros de los trabajadores destacados"},
      {"n":"individual","a":"Comunicar a cada trabajador sus posibilidades de desarrollo"}
    ]'::jsonb
    when 'Insuficiente sentido de pertenencia e inestabilidad' then '[
      {"n":"organizacional","a":"Realizar acciones que promuevan el sentido de pertenencia a la organización"},
      {"n":"grupal","a":"Difundir entre los trabajadores los cambios en la organización o condiciones de trabajo"}
    ]'::jsonb
    when 'Condiciones en el ambiente de trabajo' then '[
      {"n":"organizacional","a":"Atender las condiciones peligrosas, inseguras, deficientes o insalubres identificadas"},
      {"n":"organizacional","a":"Integrar los hallazgos al diagnóstico de seguridad y salud de la NOM-030-STPS-2009"}
    ]'::jsonb
    else '[]'::jsonb
  end
$$;

/* Genera el programa a partir de los resultados.
   Solo incluye los dominios que cruzaron el umbral: un programa
   con los diez dominios se vuelve inmanejable y RH no lo ejecuta. */
create or replace function public.nom035_generar_programa(p_campana_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  agg      jsonb;
  c        public.nom035_campanas;
  v_id     uuid;
  v_umbral integer;
  d        record;
  s        jsonb;
  v_ord    integer := 0;
  v_n      integer := 0;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  select * into c from public.nom035_campanas
   where id = p_campana_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Campana no encontrada'; end if;

  if exists (select 1 from public.nom035_programas where campana_id = p_campana_id) then
    raise exception 'Esta campana ya tiene un programa de intervencion';
  end if;

  agg := public.nom035_agregado(p_campana_id);
  if coalesce((agg->>'total')::integer,0) = 0 then
    raise exception 'La campana no tiene respuestas';
  end if;

  v_umbral := (agg->>'umbral_pct')::integer;

  insert into public.nom035_programas
    (tenant_id, campana_id, centro_id, nombre, nivel_origen, inicia, creado_por)
  values
    (c.tenant_id, p_campana_id, c.centro_id,
     'Programa de intervención · ' || c.nombre,
     agg->>'nivel_centro', current_date, auth.uid())
  returning id into v_id;

  -- Un dominio entra si su porcion en riesgo alto o muy alto
  -- cruza el umbral. Los demas no: la Norma pide intervenir
  -- donde hay riesgo, no en todo por igual.
  for d in
    select kv.key as dominio,
           (select sum((v)::integer) from jsonb_each_text(kv.value) as t(k,v)) as tot,
           coalesce((kv.value->>'Alto')::integer,0)
           + coalesce((kv.value->>'Muy alto')::integer,0) as alto
    from jsonb_each(agg->'por_dominio') kv
  loop
    if d.tot > 0 and (d.alto * 100.0 / d.tot) >= v_umbral then
      for s in select * from jsonb_array_elements(app.nom035_acciones_sugeridas(d.dominio))
      loop
        v_ord := v_ord + 10;
        insert into public.nom035_acciones
          (tenant_id, programa_id, dominio, nivel_accion, accion, orden)
        values
          (c.tenant_id, v_id, d.dominio, s->>'n', s->>'a', v_ord);
        v_n := v_n + 1;
      end loop;
    end if;
  end loop;

  -- Acciones que la Norma pide SIEMPRE, sin importar el nivel
  -- (numeral 8.1): son medidas de prevencion, no de control.
  foreach s in array array[
    '{"n":"organizacional","a":"Difundir la política de prevención de riesgos psicosociales en el centro de trabajo"}'::jsonb,
    '{"n":"organizacional","a":"Mantener disponibles los mecanismos seguros y confidenciales para denunciar violencia laboral y prácticas opuestas al entorno favorable"}'::jsonb,
    '{"n":"organizacional","a":"Difundir a los trabajadores los resultados de la evaluación y las medidas adoptadas"}'::jsonb
  ] loop
    v_ord := v_ord + 10;
    insert into public.nom035_acciones
      (tenant_id, programa_id, dominio, nivel_accion, accion, orden)
    values (c.tenant_id, v_id, null, s->>'n', s->>'a', v_ord);
    v_n := v_n + 1;
  end loop;

  perform app.auditar('nom035.programa_generar', 'nom035_programas', v_id::text, null,
    jsonb_build_object('campana', p_campana_id, 'acciones', v_n,
                       'nivel', agg->>'nivel_centro'));

  return jsonb_build_object('status','success', 'id', v_id, 'acciones', v_n,
    'nivel', agg->>'nivel_centro',
    -- Si el nivel es Nulo o Bajo el programa solo trae las
    -- medidas de prevencion generales, y eso es correcto.
    'requiere_control', agg->>'nivel_centro' in ('Medio','Alto','Muy alto'));
end;
$$;

create or replace function public.nom035_programa(p_campana_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare p public.nom035_programas;
begin
  select * into p from public.nom035_programas
   where campana_id = p_campana_id and tenant_id = app.mi_tenant();
  if not found then
    return jsonb_build_object('status','vacio');
  end if;

  return jsonb_build_object(
    'status','success',
    'programa', jsonb_build_object(
      'id', p.id, 'nombre', p.nombre, 'estado', p.estado,
      'nivel_origen', p.nivel_origen, 'inicia', p.inicia, 'concluye', p.concluye),
    'acciones', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id, 'dominio', a.dominio, 'nivel', a.nivel_accion,
        'accion', a.accion, 'estado', a.estado,
        'responsable', coalesce(
          (select nombre_completo from public.empleados where id = a.responsable_id),
          a.responsable_txt),
        'responsable_id', a.responsable_id,
        'meta', a.fecha_meta, 'hecho', a.fecha_hecho,
        'evidencia', a.evidencia_ruta, 'nota', a.nota,
        'vencida', a.fecha_meta is not null and a.fecha_meta < current_date
                   and a.estado not in ('hecha','cancelada'))
        order by a.orden, a.creado_en)
      from public.nom035_acciones a where a.programa_id = p.id
    ), '[]'::jsonb),
    'avance', (
      select case when count(*) = 0 then 0
             else round(count(*) filter (where estado = 'hecha') * 100.0 / count(*))
             end
      from public.nom035_acciones where programa_id = p.id
        and estado <> 'cancelada')
  );
end;
$$;

create or replace function public.nom035_accion_guardar(
  p_id     uuid,
  p_datos  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  a       public.nom035_acciones;
  v_yo    uuid;
  v_est   text;
begin
  select empleado_id into v_yo from public.perfiles where id = auth.uid();
  select * into a from public.nom035_acciones
   where id = p_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Accion no encontrada'; end if;

  if not (app.es_admin() or a.responsable_id = v_yo) then
    raise exception 'Solo el responsable o Recursos Humanos pueden actualizar esta accion';
  end if;

  v_est := coalesce(p_datos->>'estado', a.estado);

  -- Una accion sin evidencia no existe para una Unidad de
  -- Verificacion: marcarla hecha sin respaldo es documentar un
  -- cumplimiento que no se puede probar.
  if v_est = 'hecha'
     and coalesce(p_datos->>'evidencia_ruta', a.evidencia_ruta) is null
     and coalesce(trim(p_datos->>'evidencia_nota'), trim(coalesce(a.evidencia_nota,''))) = '' then
    raise exception 'Para marcar la accion como realizada adjunta un documento o describe la evidencia';
  end if;

  update public.nom035_acciones set
    accion        = coalesce(nullif(p_datos->>'accion',''), accion),
    nivel_accion  = coalesce(nullif(p_datos->>'nivel_accion',''), nivel_accion),
    responsable_id = case when p_datos ? 'responsable_id'
                     then nullif(p_datos->>'responsable_id','')::uuid
                     else responsable_id end,
    responsable_txt = case when p_datos ? 'responsable_txt'
                      then nullif(p_datos->>'responsable_txt','')
                      else responsable_txt end,
    fecha_meta    = case when p_datos ? 'fecha_meta'
                    then nullif(p_datos->>'fecha_meta','')::date else fecha_meta end,
    estado        = v_est,
    fecha_hecho   = case when v_est = 'hecha' then coalesce(fecha_hecho, current_date)
                    else null end,
    evidencia_ruta = coalesce(nullif(p_datos->>'evidencia_ruta',''), evidencia_ruta),
    evidencia_nota = case when p_datos ? 'evidencia_nota'
                     then nullif(p_datos->>'evidencia_nota','') else evidencia_nota end,
    nota          = case when p_datos ? 'nota'
                    then nullif(p_datos->>'nota','') else nota end
  where id = p_id;

  perform app.auditar('nom035.accion', 'nom035_acciones', p_id::text,
    jsonb_build_object('estado', a.estado), p_datos);

  return jsonb_build_object('status','success');
end;
$$;

create or replace function public.nom035_accion_nueva(
  p_programa_id uuid,
  p_accion      text,
  p_dominio     text default null,
  p_nivel       text default 'organizacional'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_id uuid; v_ord integer;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  select coalesce(max(orden),0) + 10 into v_ord
  from public.nom035_acciones where programa_id = p_programa_id;

  insert into public.nom035_acciones
    (tenant_id, programa_id, dominio, nivel_accion, accion, orden)
  values (app.mi_tenant(), p_programa_id, p_dominio, p_nivel, p_accion, v_ord)
  returning id into v_id;

  return jsonb_build_object('status','success','id',v_id);
end;
$$;

-- ═══════════════════════════════════════════════════════════
--  DIFUSIÓN · numeral 7.8
-- ═══════════════════════════════════════════════════════════

/* Resultados colectivos para el trabajador.
   Publico: se identifica con su numero de empleado, no con
   sesion. Nunca devuelve datos individuales de nadie. */
create or replace function public.nom035_resultados_publicos(p_no_empleado text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  e       public.empleados;
  c       public.nom035_campanas;
  agg     jsonb;
  v_min   integer;
  v_dom   jsonb;
begin
  select * into e from public.empleados
   where no_empleado = trim(p_no_empleado) and estatus = 'Activo'
   limit 1;

  if not found then
    return jsonb_build_object('status','error',
      'message','No encontramos tu número de empleado. Verifícalo con Recursos Humanos.');
  end if;

  -- La campaña cerrada más reciente de SU centro
  select * into c from public.nom035_campanas
   where tenant_id = e.tenant_id
     and centro_id is not distinct from e.centro_id
     and estado = 'cerrada'
   order by abre desc limit 1;

  if not found then
    return jsonb_build_object('status','sin_datos',
      'message','Todavía no hay resultados publicados para tu centro de trabajo.');
  end if;

  agg := public.nom035_agregado_publico(c.id);
  v_min := app.cfg_int('nom035_min_publicable', e.tenant_id);

  -- Piso de anonimato: con pocas respuestas los porcentajes
  -- permiten deducir quien contesto que.
  if coalesce((agg->>'total')::integer,0) < v_min then
    insert into public.nom035_difusion (tenant_id, campana_id, empleado_id)
    values (e.tenant_id, c.id, e.id);
    return jsonb_build_object('status','reservado',
      'message','Tu centro de trabajo registró ' || (agg->>'total') ||
                ' respuesta(s). Para proteger el anonimato, los resultados se '
                'publican a partir de ' || v_min || '.');
  end if;

  insert into public.nom035_difusion (tenant_id, campana_id, empleado_id)
  values (e.tenant_id, c.id, e.id);

  -- Solo los dominios con riesgo: una lista de diez donde ocho
  -- estan bien no comunica nada.
  select jsonb_agg(x order by (x->>'pct')::numeric desc) into v_dom
  from (
    select jsonb_build_object('dominio', kv.key,
      'pct', round((coalesce((kv.value->>'Alto')::numeric,0)
                  + coalesce((kv.value->>'Muy alto')::numeric,0)) * 100
                  / nullif((select sum((v)::numeric) from jsonb_each_text(kv.value) t(k,v)),0))
    ) as x
    from jsonb_each(agg->'por_dominio') kv
  ) s
  where (x->>'pct')::numeric > 0;

  return jsonb_build_object(
    'status','success',
    'centro', (select nombre from public.centros_trabajo where id = e.centro_id),
    'campana', c.nombre,
    'periodo', c.abre || ' al ' || coalesce(c.cierra::text,''),
    'total', agg->'total',
    'universo', c.universo,
    'nivel_centro', agg->>'nivel_centro',
    'distribucion', agg->'distribucion',
    'dominios', coalesce(v_dom, '[]'::jsonb),
    'acciones', coalesce((
      select jsonb_agg(a.accion order by a.orden)
      from public.nom035_acciones a
      join public.nom035_programas p on p.id = a.programa_id
      where p.campana_id = c.id and a.estado <> 'cancelada'
      limit 8
    ), '[]'::jsonb)
  );
end;
$$;

/* Igual que nom035_agregado pero SIN requerir sesión de admin.
   Se separa a proposito: la version publica no debe poder
   llamarse con un id de campana de otro tenant. */
create or replace function public.nom035_agregado_publico(p_campana_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  c        public.nom035_campanas;
  v_tot    integer;
  v_umbral integer;
  v_dist   jsonb;
  v_dom    jsonb;
  v_nivel  text := 'Nulo';
  v_niveles text[] := array['Nulo','Bajo','Medio','Alto','Muy alto'];
  k        integer;
  v_pct    numeric;
begin
  select * into c from public.nom035_campanas where id = p_campana_id;
  if not found then return jsonb_build_object('total',0); end if;

  v_umbral := app.cfg_int('nom035_umbral_centro_pct', c.tenant_id);

  select count(*) into v_tot from public.nom035_respuestas
   where campana_id = p_campana_id and aplica_frp;
  if v_tot = 0 then return jsonb_build_object('total',0); end if;

  select jsonb_object_agg(nivel_total, n) into v_dist
  from (select nivel_total, count(*) as n from public.nom035_respuestas
        where campana_id = p_campana_id and aplica_frp and nivel_total is not null
        group by nivel_total) s;

  for k in reverse 5..1 loop
    v_pct := coalesce((v_dist->>v_niveles[k])::numeric,0) * 100.0 / v_tot;
    if v_pct >= v_umbral then v_nivel := v_niveles[k]; exit; end if;
  end loop;

  select jsonb_object_agg(dom, niveles) into v_dom
  from (
    select d.key as dom, jsonb_object_agg(d.nivel, d.n) as niveles
    from (
      select kv.key, kv.value->>'nivel' as nivel, count(*) as n
      from public.nom035_respuestas r, jsonb_each(r.por_dominio) kv
      where r.campana_id = p_campana_id and r.aplica_frp
        and kv.value->>'nivel' is not null
      group by kv.key, kv.value->>'nivel'
    ) d group by d.key
  ) x;

  return jsonb_build_object(
    'total', v_tot, 'nivel_centro', v_nivel,
    'distribucion', coalesce(v_dist,'{}'::jsonb),
    'por_dominio', coalesce(v_dom,'{}'::jsonb));
end;
$$;

/* Evidencia de difusión, para el expediente de cumplimiento. */
create or replace function public.nom035_evidencia_difusion(p_campana_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'status','success',
    'consultas', (select count(*) from public.nom035_difusion
                  where campana_id = p_campana_id),
    'personas', (select count(distinct empleado_id) from public.nom035_difusion
                 where campana_id = p_campana_id),
    'detalle', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nombre', e.nombre_completo, 'no', e.no_empleado,
        'cuando', d.consultado_en, 'medio', d.medio)
        order by d.consultado_en desc)
      from public.nom035_difusion d
      left join public.empleados e on e.id = d.empleado_id
      where d.campana_id = p_campana_id
      limit 500), '[]'::jsonb))
  where app.es_admin()
$$;

grant execute on function public.nom035_generar_programa(uuid)            to authenticated;
grant execute on function public.nom035_programa(uuid)                    to authenticated;
grant execute on function public.nom035_accion_guardar(uuid,jsonb)        to authenticated;
grant execute on function public.nom035_accion_nueva(uuid,text,text,text) to authenticated;
grant execute on function public.nom035_evidencia_difusion(uuid)          to authenticated;
-- Publicas: las llama el trabajador sin sesion
grant execute on function public.nom035_resultados_publicos(text)         to anon, authenticated;
grant execute on function public.nom035_agregado_publico(uuid)            to anon, authenticated;