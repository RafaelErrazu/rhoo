-- ═══════════════════════════════════════════════════════════
--  RHoo! · NOM-035 · textos oficiales de los items
--
--  Verificados contra NOM-035-STPS-2018, DOF 23-10-2018,
--  Guias de Referencia II y III.
--
--  Solo se actualiza la columna `pregunta`: la agrupacion por
--  categoria, dominio y dimension ya quedo verificada por doble
--  fuente y no se toca desde aqui.
-- ═══════════════════════════════════════════════════════════

-- Preámbulo: los ítems condicionales y los de violencia son
-- fragmentos que no se entienden aislados. En el cuestionario
-- impreso van bajo un encabezado de bloque; aqui se guarda
-- aparte para que el texto quede idéntico al oficial.
alter table public.nom035_items
  add column if not exists preambulo text;

-- ══════════════════ GUÍA II ══════════════════
update public.nom035_items set pregunta = v.txt
from (values
  (1,'Mi trabajo me exige hacer mucho esfuerzo físico'),
  (2,'Me preocupa sufrir un accidente en mi trabajo'),
  (3,'Considero que las actividades que realizo son peligrosas'),
  (4,'Por la cantidad de trabajo que tengo debo quedarme tiempo adicional a mi turno'),
  (5,'Por la cantidad de trabajo que tengo debo trabajar sin parar'),
  (6,'Considero que es necesario mantener un ritmo de trabajo acelerado'),
  (7,'Mi trabajo exige que esté muy concentrado'),
  (8,'Mi trabajo requiere que memorice mucha información'),
  (9,'Mi trabajo exige que atienda varios asuntos al mismo tiempo'),
  (10,'En mi trabajo soy responsable de cosas de mucho valor'),
  (11,'Respondo ante mi jefe por los resultados de toda mi área de trabajo'),
  (12,'En mi trabajo me dan órdenes contradictorias'),
  (13,'Considero que en mi trabajo me piden hacer cosas innecesarias'),
  (14,'Trabajo horas extras más de tres veces a la semana'),
  (15,'Mi trabajo me exige laborar en días de descanso, festivos o fines de semana'),
  (16,'Considero que el tiempo en el trabajo es mucho y perjudica mis actividades familiares o personales'),
  (17,'Pienso en las actividades familiares o personales cuando estoy en mi trabajo'),
  (18,'Mi trabajo permite que desarrolle nuevas habilidades'),
  (19,'En mi trabajo puedo aspirar a un mejor puesto'),
  (20,'Durante mi jornada de trabajo puedo tomar pausas cuando las necesito'),
  (21,'Puedo decidir la velocidad a la que realizo mis actividades en mi trabajo'),
  (22,'Puedo cambiar el orden de las actividades que realizo en mi trabajo'),
  (23,'Me informan con claridad cuáles son mis funciones'),
  (24,'Me explican claramente los resultados que debo obtener en mi trabajo'),
  (25,'Me informan con quién puedo resolver problemas o asuntos de trabajo'),
  (26,'Me permiten asistir a capacitaciones relacionadas con mi trabajo'),
  (27,'Recibo capacitación útil para hacer mi trabajo'),
  (28,'Mi jefe tiene en cuenta mis puntos de vista y opiniones'),
  (29,'Mi jefe ayuda a solucionar los problemas que se presentan en el trabajo'),
  (30,'Puedo confiar en mis compañeros de trabajo'),
  (31,'Cuando tenemos que realizar trabajo de equipo los compañeros colaboran'),
  (32,'Mis compañeros de trabajo me ayudan cuando tengo dificultades'),
  (33,'En mi trabajo puedo expresarme libremente sin interrupciones'),
  (34,'Recibo críticas constantes a mi persona y/o trabajo'),
  (35,'Recibo burlas, calumnias, difamaciones, humillaciones o ridiculizaciones'),
  (36,'Se ignora mi presencia o se me excluye de las reuniones de trabajo y en la toma de decisiones'),
  (37,'Se manipulan las situaciones de trabajo para hacerme parecer un mal trabajador'),
  (38,'Se ignoran mis éxitos laborales y se atribuyen a otros trabajadores'),
  (39,'Me bloquean o impiden las oportunidades que tengo para obtener ascenso o mejora en mi trabajo'),
  (40,'He presenciado actos de violencia en mi centro de trabajo'),
  (41,'Atiendo clientes o usuarios muy enojados'),
  (42,'Mi trabajo me exige atender personas muy necesitadas de ayuda o enfermas'),
  (43,'Para hacer mi trabajo debo demostrar sentimientos distintos a los míos'),
  (44,'Comunican tarde los asuntos de trabajo'),
  (45,'Dificultan el logro de los resultados del trabajo'),
  (46,'Ignoran las sugerencias para mejorar su trabajo')
) as v(num, txt)
where guia = 'guia2' and numero = v.num;

-- ══════════════════ GUÍA III ══════════════════
update public.nom035_items set pregunta = v.txt
from (values
  (1,'El espacio donde trabajo me permite realizar mis actividades de manera segura e higiénica'),
  (2,'Mi trabajo me exige hacer mucho esfuerzo físico'),
  (3,'Me preocupa sufrir un accidente en mi trabajo'),
  (4,'Considero que en mi trabajo se aplican las normas de seguridad y salud en el trabajo'),
  (5,'Considero que las actividades que realizo son peligrosas'),
  (6,'Por la cantidad de trabajo que tengo debo quedarme tiempo adicional a mi turno'),
  (7,'Por la cantidad de trabajo que tengo debo trabajar sin parar'),
  (8,'Considero que es necesario mantener un ritmo de trabajo acelerado'),
  (9,'Mi trabajo exige que esté muy concentrado'),
  (10,'Mi trabajo requiere que memorice mucha información'),
  (11,'En mi trabajo tengo que tomar decisiones difíciles muy rápido'),
  (12,'Mi trabajo exige que atienda varios asuntos al mismo tiempo'),
  (13,'En mi trabajo soy responsable de cosas de mucho valor'),
  (14,'Respondo ante mi jefe por los resultados de toda mi área de trabajo'),
  (15,'En el trabajo me dan órdenes contradictorias'),
  (16,'Considero que en mi trabajo me piden hacer cosas innecesarias'),
  (17,'Trabajo horas extras más de tres veces a la semana'),
  (18,'Mi trabajo me exige laborar en días de descanso, festivos o fines de semana'),
  (19,'Considero que el tiempo en el trabajo es mucho y perjudica mis actividades familiares o personales'),
  (20,'Debo atender asuntos de trabajo cuando estoy en casa'),
  (21,'Pienso en las actividades familiares o personales cuando estoy en mi trabajo'),
  (22,'Pienso que mis responsabilidades familiares afectan mi trabajo'),
  (23,'Mi trabajo permite que desarrolle nuevas habilidades'),
  (24,'En mi trabajo puedo aspirar a un mejor puesto'),
  (25,'Durante mi jornada de trabajo puedo tomar pausas cuando las necesito'),
  (26,'Puedo decidir cuánto trabajo realizo durante la jornada laboral'),
  (27,'Puedo decidir la velocidad a la que realizo mis actividades en mi trabajo'),
  (28,'Puedo cambiar el orden de las actividades que realizo en mi trabajo'),
  (29,'Los cambios que se presentan en mi trabajo dificultan mi labor'),
  (30,'Cuando se presentan cambios en mi trabajo se tienen en cuenta mis ideas o aportaciones'),
  (31,'Me informan con claridad cuáles son mis funciones'),
  (32,'Me explican claramente los resultados que debo obtener en mi trabajo'),
  (33,'Me explican claramente los objetivos de mi trabajo'),
  (34,'Me informan con quién puedo resolver problemas o asuntos de trabajo'),
  (35,'Me permiten asistir a capacitaciones relacionadas con mi trabajo'),
  (36,'Recibo capacitación útil para hacer mi trabajo'),
  (37,'Mi jefe ayuda a organizar mejor el trabajo'),
  (38,'Mi jefe tiene en cuenta mis puntos de vista y opiniones'),
  (39,'Mi jefe me comunica a tiempo la información relacionada con el trabajo'),
  (40,'La orientación que me da mi jefe me ayuda a realizar mejor mi trabajo'),
  (41,'Mi jefe ayuda a solucionar los problemas que se presentan en el trabajo'),
  (42,'Puedo confiar en mis compañeros de trabajo'),
  (43,'Entre compañeros solucionamos los problemas de trabajo de forma respetuosa'),
  (44,'En mi trabajo me hacen sentir parte del grupo'),
  (45,'Cuando tenemos que realizar trabajo de equipo los compañeros colaboran'),
  (46,'Mis compañeros de trabajo me ayudan cuando tengo dificultades'),
  (47,'Me informan sobre lo que hago bien en mi trabajo'),
  (48,'La forma como evalúan mi trabajo en mi centro de trabajo me ayuda a mejorar mi desempeño'),
  (49,'En mi centro de trabajo me pagan a tiempo mi salario'),
  (50,'El pago que recibo es el que merezco por el trabajo que realizo'),
  (51,'Si obtengo los resultados esperados en mi trabajo me recompensan o reconocen'),
  (52,'Las personas que hacen bien el trabajo pueden crecer laboralmente'),
  (53,'Considero que mi trabajo es estable'),
  (54,'En mi trabajo existe continua rotación de personal'),
  (55,'Siento orgullo de laborar en este centro de trabajo'),
  (56,'Me siento comprometido con mi trabajo'),
  (57,'En mi trabajo puedo expresarme libremente sin interrupciones'),
  (58,'Recibo críticas constantes a mi persona y/o trabajo'),
  (59,'Recibo burlas, calumnias, difamaciones, humillaciones o ridiculizaciones'),
  (60,'Se ignora mi presencia o se me excluye de las reuniones de trabajo y en la toma de decisiones'),
  (61,'Se manipulan las situaciones de trabajo para hacerme parecer un mal trabajador'),
  (62,'Se ignoran mis éxitos laborales y se atribuyen a otros trabajadores'),
  (63,'Me bloquean o impiden las oportunidades que tengo para obtener ascenso o mejora en mi trabajo'),
  (64,'He presenciado actos de violencia en mi centro de trabajo'),
  (65,'Atiendo clientes o usuarios muy enojados'),
  (66,'Mi trabajo me exige atender personas muy necesitadas de ayuda o enfermas'),
  (67,'Para hacer mi trabajo debo demostrar sentimientos distintos a los míos'),
  (68,'Mi trabajo me exige atender situaciones de violencia'),
  (69,'Comunican tarde los asuntos de trabajo'),
  (70,'Dificultan el logro de los resultados del trabajo'),
  (71,'Cooperan poco cuando se necesita'),
  (72,'Ignoran las sugerencias para mejorar su trabajo')
) as v(num, txt)
where guia = 'guia3' and numero = v.num;

-- ─────────────────────────────────────────────────────────────
--  PREÁMBULOS DE BLOQUE
--
--  Sin ellos, "Comunican tarde los asuntos de trabajo" no dice
--  QUIEN comunica tarde, y el trabajador contesta sobre lo que
--  supone. El DOF los pone como encabezado del bloque.
-- ─────────────────────────────────────────────────────────────
update public.nom035_items
   set preambulo = 'Para responder las siguientes preguntas, considere las condiciones de su centro de trabajo. Los trabajadores que usted supervisa:'
 where condicional = 'jefe';

update public.nom035_items
   set preambulo = 'Para responder las siguientes preguntas piense en qué medida se presentan las siguientes situaciones en su centro de trabajo. En mi trabajo:'
 where dominio = 'Violencia'
   and direccion = 'directa';

-- Los ítems de atención a clientes también son de un bloque
update public.nom035_items
   set preambulo = 'Las siguientes preguntas aplican si en su trabajo brinda servicio a clientes o usuarios:'
 where condicional = 'clientes';