-- ═══════════════════════════════════════════════════════════
--  RHoo! · NOM-035 · agregados, dashboard e informe
-- ═══════════════════════════════════════════════════════════

/* Agregado de una campaña.
   Todo el analisis se construye sobre CUANTOS TRABAJADORES hay
   en cada nivel, no sobre promedios: la Norma califica por
   trabajador, y un promedio "Medio" puede ocultar a dos personas
   en Muy alto que son justo las que obligan a intervenir. */
create or replace function public.nom035_agregado(p_campana_id uuid)
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
  v_cat    jsonb;
  v_nivel  text := 'Nulo';
  v_niveles text[] := array['Nulo','Bajo','Medio','Alto','Muy alto'];
  k        integer;
  v_pct    numeric;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  select * into c from public.nom035_campanas
   where id = p_campana_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Campana no encontrada'; end if;

  v_umbral := app.cfg_int('nom035_umbral_centro_pct', c.tenant_id);

  select count(*) into v_tot from public.nom035_respuestas
   where campana_id = p_campana_id and aplica_frp;

  if v_tot = 0 then
    return jsonb_build_object(
      'status','success', 'total', 0,
      'campana', jsonb_build_object('nombre', c.nombre, 'estado', c.estado,
                                    'universo', c.universo),
      'mensaje','Sin respuestas con factores de riesgo todavía.');
  end if;

  -- Distribucion general por nivel
  select jsonb_object_agg(nivel_total, n) into v_dist
  from (select nivel_total, count(*) as n
        from public.nom035_respuestas
        where campana_id = p_campana_id and aplica_frp and nivel_total is not null
        group by nivel_total) s;

  -- Nivel del centro: el mas alto donde se concentra al menos el
  -- umbral configurado. Se recorre de mayor a menor y gana el
  -- primero que lo alcanza.
  for k in reverse 5..1 loop
    v_pct := coalesce((v_dist->>v_niveles[k])::numeric, 0) * 100.0 / v_tot;
    if v_pct >= v_umbral then v_nivel := v_niveles[k]; exit; end if;
  end loop;

  -- Por dominio: cuenta de trabajadores en cada nivel.
  -- Se recorre el JSON de cada respuesta en lugar de recalcular:
  -- el nivel ya lo determino el motor al guardar.
  select jsonb_object_agg(dom, niveles) into v_dom
  from (
    select d.key as dom,
           jsonb_object_agg(d.nivel, d.n) as niveles
    from (
      select kv.key,
             kv.value->>'nivel' as nivel,
             count(*) as n
      from public.nom035_respuestas r,
           jsonb_each(r.por_dominio) kv
      where r.campana_id = p_campana_id and r.aplica_frp
        and kv.value->>'nivel' is not null
      group by kv.key, kv.value->>'nivel'
    ) d
    group by d.key
  ) x;

  select jsonb_object_agg(cat, niveles) into v_cat
  from (
    select d.key as cat, jsonb_object_agg(d.nivel, d.n) as niveles
    from (
      select kv.key, kv.value->>'nivel' as nivel, count(*) as n
      from public.nom035_respuestas r,
           jsonb_each(r.por_categoria) kv
      where r.campana_id = p_campana_id and r.aplica_frp
        and kv.value->>'nivel' is not null
      group by kv.key, kv.value->>'nivel'
    ) d
    group by d.key
  ) x;

  return jsonb_build_object(
    'status','success',
    'campana', jsonb_build_object(
      'id', c.id, 'nombre', c.nombre, 'estado', c.estado,
      'abre', c.abre, 'cierra', c.cierra,
      'universo', c.universo, 'muestra_minima', c.muestra_minima,
      'centro', (select nombre from public.centros_trabajo where id = c.centro_id)),
    'total', v_tot,
    'participacion_pct', case when c.universo > 0
                        then round(v_tot * 100.0 / c.universo) else 0 end,
    'alcanzo_muestra', v_tot >= coalesce(c.muestra_minima, 0),
    'distribucion', coalesce(v_dist, '{}'::jsonb),
    'nivel_centro', v_nivel,
    'umbral_pct', v_umbral,
    'en_riesgo', coalesce((v_dist->>'Alto')::integer,0)
                 + coalesce((v_dist->>'Muy alto')::integer,0),
    'por_dominio', coalesce(v_dom, '{}'::jsonb),
    'por_categoria', coalesce(v_cat, '{}'::jsonb),
    -- Guia I es aparte: no se promedia con el riesgo psicosocial
    -- porque mide algo distinto (acontecimientos traumaticos).
    'guia1_valoracion', (select count(*) from public.nom035_respuestas
                         where campana_id = p_campana_id
                           and gi_requiere_valoracion),
    'guia1_total', (select count(*) from public.nom035_respuestas
                    where campana_id = p_campana_id)
  );
end;
$$;

/* Cruce por perfil, usando la ficha de la Guía V.
   Aqui aparece el hallazgo real: "quienes rotan turnos estan en
   Alto en carga de trabajo". Sin este cruce el diagnostico se
   queda en "esta mal" y el plan de accion sale a ciegas. */
create or replace function public.nom035_por_perfil(
  p_campana_id uuid,
  p_campo      text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare v_filas jsonb;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  -- Lista blanca: p_campo entra a una consulta y sin validarlo
  -- seria una via de inyeccion.
  if p_campo not in ('sexo','edad','antiguedad','tipo_puesto','turno','rota') then
    raise exception 'Campo no valido';
  end if;

  select jsonb_agg(x order by (x->>'en_riesgo_pct')::numeric desc) into v_filas
  from (
    select jsonb_build_object(
      'valor', coalesce(f.datos->>p_campo, 'Sin dato'),
      'total', count(*),
      'en_riesgo', count(*) filter (where r.nivel_total in ('Alto','Muy alto')),
      'en_riesgo_pct', round(
        count(*) filter (where r.nivel_total in ('Alto','Muy alto'))
        * 100.0 / count(*)),
      'distribucion', jsonb_object_agg(
        coalesce(r.nivel_total,'Sin dato'), 1)
    ) as x
    from public.nom035_respuestas r
    left join public.nom035_fichas f on f.respuesta_id = r.id
    where r.campana_id = p_campana_id and r.aplica_frp
    group by coalesce(f.datos->>p_campo, 'Sin dato')
    -- Menos de 3 respuestas por segmento permitiria deducir quien
    -- contesto que: se agrupa aparte en lugar de exponerlo.
    having count(*) >= 3
  ) s;

  return jsonb_build_object(
    'status','success', 'campo', p_campo,
    'filas', coalesce(v_filas, '[]'::jsonb),
    'nota','Los grupos con menos de 3 respuestas se omiten para proteger el anonimato.'
  );
end;
$$;

/* Comparativo entre campañas del mismo centro.
   Es lo que demuestra si las medidas de control sirvieron: sin
   comparativo, cada evaluacion es una foto suelta. */
create or replace function public.nom035_historico(p_centro_id uuid default null)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'campana', c.nombre, 'abre', c.abre, 'estado', c.estado,
    'respuestas', (select count(*) from public.nom035_respuestas r
                   where r.campana_id = c.id and r.aplica_frp),
    'en_riesgo', (select count(*) from public.nom035_respuestas r
                  where r.campana_id = c.id and r.nivel_total in ('Alto','Muy alto')),
    'universo', c.universo
  ) order by c.abre), '[]'::jsonb)
  from public.nom035_campanas c
  where c.tenant_id = app.mi_tenant()
    and (p_centro_id is null or c.centro_id = p_centro_id)
    and app.es_admin()
$$;

/* Informe del numeral 7.7, con sus ocho elementos.
   Se genera, no se redacta: armarlo a mano en Word cada dos anos
   es donde se pierde el cumplimiento. */
create or replace function public.nom035_informe(p_campana_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  agg jsonb;
  c   public.nom035_campanas;
  t   public.tenants;
  ct  public.centros_trabajo;
begin
  agg := public.nom035_agregado(p_campana_id);

  select * into c from public.nom035_campanas where id = p_campana_id;
  select * into t from public.tenants where id = c.tenant_id;
  select * into ct from public.centros_trabajo where id = c.centro_id;

  return jsonb_build_object(
    'status','success',
    -- 1) Datos del centro de trabajo
    'centro', jsonb_build_object(
      'razon_social', coalesce(ct.razon_social, t.nombre),
      'nombre', coalesce(ct.nombre, t.nombre),
      'domicilio', ct.direccion,
      'trabajadores', c.universo),
    -- 2) Objetivo
    'objetivo','Identificar y analizar los factores de riesgo psicosocial y, '
      || 'en su caso, evaluar el entorno organizacional, conforme a la '
      || 'NOM-035-STPS-2018.',
    -- 3) Método
    'metodo', jsonb_build_object(
      'guia', (select guia from public.nom035_invitaciones
               where campana_id = p_campana_id limit 1),
      'aplicacion','Cuestionario digital autoaplicado, con acceso individual '
        || 'y respuestas confidenciales.',
      'universo', c.universo,
      'muestra_minima', c.muestra_minima,
      'respuestas', agg->'total',
      'periodo', c.abre || ' al ' || coalesce(c.cierra::text, 'en curso')),
    -- 4) Resultados
    'resultados', agg,
    -- 5) Conclusiones (se arman con los datos, no se inventan)
    'conclusiones', jsonb_build_object(
      'nivel_centro', agg->>'nivel_centro',
      'criterio','El nivel del centro corresponde al nivel de riesgo más alto '
        || 'en el que se concentra al menos el ' || (agg->>'umbral_pct')
        || '% de los trabajadores evaluados. Este criterio es interno: la '
        || 'Norma establece niveles por trabajador y no define cómo resumir '
        || 'un centro completo.',
      'participacion', (agg->>'participacion_pct') || '%',
      'suficiencia', case when (agg->>'alcanzo_muestra')::boolean
                     then 'La participación alcanza el tamaño mínimo de muestra '
                          || 'del numeral III.1.'
                     else 'ATENCIÓN: la participación NO alcanza el tamaño '
                          || 'mínimo de muestra que requiere el numeral III.1.'
                     end),
    -- 6) Recomendaciones según Tabla 4/7 de la Norma
    'acciones', case agg->>'nivel_centro'
      when 'Muy alto' then 'Se requiere el análisis de cada categoría y dominio '
        || 'para establecer las acciones de intervención apropiadas, mediante un '
        || 'Programa de intervención que deberá incluir evaluaciones específicas, '
        || 'campañas de sensibilización, revisión de la política de prevención de '
        || 'riesgos psicosociales y reforzar su aplicación y difusión.'
      when 'Alto' then 'Se requiere realizar un análisis de cada categoría y '
        || 'dominio para determinar las acciones de intervención mediante un '
        || 'Programa de intervención, que deberá incluir una campaña de '
        || 'sensibilización y revisar la política de prevención.'
      when 'Medio' then 'Se requiere revisar la política de prevención de riesgos '
        || 'psicosociales y los programas para la prevención de los factores de '
        || 'riesgo, así como reforzar su aplicación y difusión mediante un '
        || 'Programa de intervención.'
      when 'Bajo' then 'Es necesaria una mayor difusión de la política de '
        || 'prevención de riesgos psicosociales y de los programas para la '
        || 'prevención de los factores de riesgo psicosocial.'
      else 'El riesgo resulta despreciable, por lo que no se requieren medidas '
        || 'adicionales.' end,
    -- 7) Canalización de Guía I
    'acontecimientos_traumaticos', jsonb_build_object(
      'evaluados', agg->'guia1_total',
      'requieren_valoracion', agg->'guia1_valoracion',
      'nota','Los trabajadores identificados deben canalizarse a la institución '
        || 'de seguridad social o al médico del centro de trabajo (numeral 5.5). '
        || 'Sus nombres NO se incluyen en este informe: constan en el registro '
        || 'confidencial del numeral 5.8 inciso c).'),
    -- 8) Datos del responsable (los llena RH al firmar)
    'generado_en', now()
  );
end;
$$;

grant execute on function public.nom035_agregado(uuid)          to authenticated;
grant execute on function public.nom035_por_perfil(uuid,text)   to authenticated;
grant execute on function public.nom035_historico(uuid)         to authenticated;
grant execute on function public.nom035_informe(uuid)           to authenticated;

-- ═══════════════════════════════════════════════════════════
--  ALERTAS DE VIGENCIA · numeral 7.9
--
--  La evaluacion se repite al menos cada dos anos. Sin
--  recordatorio automatico esto se incumple sin que nadie lo
--  note: el plazo vence 24 meses despues de que el tema dejo de
--  estar sobre la mesa.
-- ═══════════════════════════════════════════════════════════
create or replace function public.nom035_vigencia()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with ultimas as (
    select c.centro_id,
           max(c.abre) as ultima,
           (select nombre from public.centros_trabajo where id = c.centro_id) as centro
    from public.nom035_campanas c
    where c.tenant_id = app.mi_tenant() and c.estado = 'cerrada'
    group by c.centro_id
  ),
  todos as (
    -- Los centros SIN evaluar tambien aparecen: son el pendiente
    -- mas grave y esconderlos haria ver el cumplimiento completo.
    select ct.id as centro_id, ct.nombre as centro, u.ultima
    from public.centros_trabajo ct
    left join ultimas u on u.centro_id = ct.id
    where ct.tenant_id = app.mi_tenant() and ct.activo
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'centro', centro,
    'ultima', ultima,
    'limite', case when ultima is null then null
              else (ultima + (app.cfg_int('nom035_meses_vigencia')
                              || ' months')::interval)::date end,
    'dias', case when ultima is null then null
            else ((ultima + (app.cfg_int('nom035_meses_vigencia')
                             || ' months')::interval)::date - current_date) end,
    'estado', case
      when ultima is null then 'sin_evaluar'
      when (ultima + (app.cfg_int('nom035_meses_vigencia') || ' months')::interval)::date
           < current_date then 'vencida'
      when (ultima + (app.cfg_int('nom035_meses_vigencia') || ' months')::interval)::date
           <= current_date + app.cfg_int('nom035_dias_aviso') then 'por_vencer'
      else 'vigente' end
  ) order by ultima nulls first), '[]'::jsonb)
  from todos
  where app.es_admin()
$$;

grant execute on function public.nom035_vigencia() to authenticated;