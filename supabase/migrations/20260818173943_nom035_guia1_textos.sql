-- ═══════════════════════════════════════════════════════════
--  RHoo! · NOM-035 · Guía de Referencia I
--
--  Cuestionario para identificar a los trabajadores que fueron
--  sujetos a acontecimientos traumaticos severos.
--  Fuente: NOM-035-STPS-2018, DOF 23-10-2018, Guia I.
--
--  CONFIDENCIAL por naturaleza: detecta posible trastorno de
--  estres postraumatico. Sus resultados van al area de salud
--  ocupacional, nunca al jefe directo ni al informe colectivo.
-- ═══════════════════════════════════════════════════════════

-- Los titulos oficiales completos
update public.nom035_guia1 set
  seccion_tit = 'I. Acontecimiento traumático severo',
  instruccion = '¿Ha presenciado o sufrido alguna vez, durante o con motivo del trabajo un acontecimiento como los siguientes:'
where seccion = 1;

update public.nom035_guia1 set
  seccion_tit = 'II. Recuerdos persistentes sobre el acontecimiento',
  instruccion = 'Durante el último mes:'
where seccion = 2;

update public.nom035_guia1 set
  seccion_tit = 'III. Esfuerzo por evitar circunstancias parecidas o asociadas al acontecimiento',
  instruccion = 'Durante el último mes:'
where seccion = 3;

update public.nom035_guia1 set
  seccion_tit = 'IV. Afectación',
  instruccion = 'Durante el último mes:'
where seccion = 4;

-- Los 20 textos
update public.nom035_guia1 set texto = v.txt
from (values
  -- Sección I · 6 incisos de una misma pregunta
  ('s1_1','¿Accidente que tenga como consecuencia la muerte, la pérdida de un miembro o una lesión grave?'),
  ('s1_2','¿Asaltos?'),
  ('s1_3','¿Actos violentos que derivaron en lesiones graves?'),
  ('s1_4','¿Secuestro?'),
  ('s1_5','¿Amenazas?'),
  ('s1_6','¿Cualquier otro que ponga en riesgo su vida o salud, y/o la de otras personas?'),
  -- Sección II
  ('s2_1','¿Ha tenido recuerdos recurrentes sobre el acontecimiento que le provocan malestares?'),
  ('s2_2','¿Ha tenido sueños de carácter recurrente sobre el acontecimiento, que le producen malestar?'),
  -- Sección III
  ('s3_1','¿Se ha esforzado por evitar todo tipo de sentimientos, conversaciones o situaciones que le puedan recordar el acontecimiento?'),
  ('s3_2','¿Se ha esforzado por evitar todo tipo de actividades, lugares o personas que motivan recuerdos del acontecimiento?'),
  ('s3_3','¿Ha tenido dificultad para recordar alguna parte importante del evento?'),
  ('s3_4','¿Ha disminuido su interés en sus actividades cotidianas?'),
  ('s3_5','¿Se ha sentido usted alejado o distante de los demás?'),
  ('s3_6','¿Ha notado que tiene dificultad para expresar sus sentimientos?'),
  ('s3_7','¿Ha tenido la impresión de que su vida se va a acortar, que va a morir antes que otras personas o que tiene un futuro limitado?'),
  -- Sección IV
  ('s4_1','¿Ha tenido usted dificultades para dormir?'),
  ('s4_2','¿Ha estado particularmente irritable o le han dado arranques de coraje?'),
  ('s4_3','¿Ha tenido dificultad para concentrarse?'),
  ('s4_4','¿Ha estado nervioso o constantemente en alerta?'),
  ('s4_5','¿Se ha sobresaltado fácilmente por cualquier cosa?')
) as v(cl, txt)
where clave = v.cl;

-- ─────────────────────────────────────────────────────────────
--  ESTRUCTURA PARA EL CUESTIONARIO
--
--  Devuelve la Guia I lista para pintar, con sus secciones
--  agrupadas. La ramificacion la decide el cliente: si todas las
--  respuestas de la Seccion I son "No", el cuestionario termina
--  ahi y las secciones II a IV nunca se muestran.
-- ─────────────────────────────────────────────────────────────
create or replace function public.nom035_estructura_guia1()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'titulo', 'Guía de Referencia I. Acontecimientos traumáticos severos',
    'confidencial', true,
    'aviso', 'Este cuestionario es confidencial. Sus respuestas solo las conoce '
           || 'el área de salud ocupacional y sirven para ofrecerle atención si '
           || 'la necesita.',
    'secciones', coalesce((
      select jsonb_agg(s order by s->>'numero')
      from (
        select jsonb_build_object(
          'numero', seccion,
          'titulo', seccion_tit,
          'instruccion', instruccion,
          'preguntas', jsonb_agg(
            jsonb_build_object('clave', clave, 'texto', texto)
            order by orden)
        ) as s
        from public.nom035_guia1
        group by seccion, seccion_tit, instruccion
      ) x
    ), '[]'::jsonb)
  )
$$;

grant execute on function public.nom035_estructura_guia1() to authenticated, anon;