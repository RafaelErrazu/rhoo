-- Fix: la version anterior usaba una tabla temporal dentro de
-- una funcion STABLE, y Postgres lo rechaza ("CREATE TABLE is
-- not allowed in a non-volatile function"). Se reescribe con
-- CTEs: mismo resultado, sin efectos secundarios y mas rapido.
create or replace function public.nom035_calificar(
  p_guia       public.guia_nom035,
  p_respuestas jsonb,
  p_clientes   boolean default null,
  p_jefe       boolean default null
)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
with cal as (
  select i.numero,
         app.nom035_puntaje((x->>'valor')::smallint, i.direccion) as puntaje,
         i.categoria, i.dominio, i.dimension
  from jsonb_array_elements(p_respuestas) x
  join public.nom035_items i
    on i.guia = p_guia and i.numero = (x->>'numero')::integer and i.activo
),
-- Items que APLICABAN segun los filtros del trabajador
aplicables as (
  select i.categoria, i.dominio
  from public.nom035_items i
  where i.guia = p_guia and i.activo
    and (i.condicional is null
         or (i.condicional = 'clientes' and coalesce(p_clientes,false))
         or (i.condicional = 'jefe'     and coalesce(p_jefe,false)))
),
tot as (
  select coalesce(sum(puntaje),0)::integer as pts, count(*)::integer as n from cal
),
esp as (
  select count(*)::integer as n from aplicables
),
dom as (
  select c.dominio,
         sum(c.puntaje)::integer as pts,
         count(*)::integer as n,
         (select count(*)::integer from aplicables a where a.dominio = c.dominio) as e,
         (select r.cortes from public.nom035_rangos r
           where r.guia = p_guia and r.ambito='dominio' and r.nombre = c.dominio) as ct
  from cal c where c.dominio is not null group by c.dominio
),
cat as (
  select c.categoria,
         sum(c.puntaje)::integer as pts,
         count(*)::integer as n,
         (select count(*)::integer from aplicables a where a.categoria = c.categoria) as e,
         (select r.cortes from public.nom035_rangos r
           where r.guia = p_guia and r.ambito='categoria' and r.nombre = c.categoria) as ct
  from cal c where c.categoria is not null group by c.categoria
),
dim as (
  select c.dimension, sum(c.puntaje)::integer as pts, count(*)::integer as n
  from cal c where c.dimension is not null group by c.dimension
),
ctot as (
  select r.cortes from public.nom035_rangos r
   where r.guia = p_guia and r.ambito='total'
)
select jsonb_build_object(
  'guia', p_guia,
  'puntaje_total', (select pts from tot),
  'nivel_total', app.nom035_nivel(
    (select pts from tot),
    app.nom035_escalar((select cortes from ctot), (select n from tot), (select n from esp))),
  'items_respondidos', (select n from tot),
  'items_aplicables',  (select n from esp),
  'rango_ajustado', (select n from tot) < (select n from esp),
  'por_dominio', coalesce((
    select jsonb_object_agg(d.dominio, jsonb_build_object(
      'puntaje', d.pts, 'items', d.n, 'esperados', d.e,
      'parcial', d.n < d.e,
      'nivel', case when d.ct is null then 'Sin rango'
                    else app.nom035_nivel(d.pts, app.nom035_escalar(d.ct, d.n, d.e)) end))
    from dom d), '{}'::jsonb),
  'por_categoria', coalesce((
    select jsonb_object_agg(c.categoria, jsonb_build_object(
      'puntaje', c.pts, 'items', c.n, 'esperados', c.e,
      'parcial', c.n < c.e,
      'nivel', case when c.ct is null then 'Sin rango'
                    else app.nom035_nivel(c.pts, app.nom035_escalar(c.ct, c.n, c.e)) end))
    from cat c), '{}'::jsonb),
  'por_dimension', coalesce((
    select jsonb_object_agg(x.dimension, jsonb_build_object(
      'puntaje', x.pts, 'items', x.n, 'maximo', x.n * 4))
    from dim x), '{}'::jsonb)
)
$$;