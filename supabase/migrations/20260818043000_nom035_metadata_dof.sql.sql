-- ═══════════════════════════════════════════════════════════
--  RHoo! · NOM-035 · metadata oficial
--
--  Fuente: NOM-035-STPS-2018, DOF 23-10-2018.
--    Guia II  · Tabla 2 (direccion) y Tabla 3 (agrupacion)
--    Guia III · Tabla 5 (direccion) y Tabla 6 (agrupacion)
--
--  DOS CORRECCIONES sobre la version publicada de la Tabla 6:
--    · "Carga mental" son los items 9, 10 y 11. La fuente decia
--      «8, 19, 11»: el 8 pertenece a "Ritmos de trabajo
--      acelerado" y el 19 a "Influencia del trabajo fuera del
--      centro laboral". Con la version publicada los items suman
--      71 y no 72.
--    · La dimension de los items 53 y 54 es "Inestabilidad
--      laboral". La fuente repetia "Limitado sentido de
--      pertenencia", que corresponde a los items 55 y 56.
--
--  Los nombres van CON ACENTOS y deben coincidir exactamente
--  entre items y rangos: ese desajuste es lo que provocaba que
--  los diez dominios salieran en "Nulo" en el sistema anterior.
-- ═══════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────
--  RANGOS · se reemplazan los de la migracion anterior para
--  corregir nombres (acentos y "e inestabilidad")
-- ─────────────────────────────────────────────────────────────
delete from public.nom035_rangos;

insert into public.nom035_rangos (guia, ambito, nombre, cortes) values
  -- ══ GUIA II · 46 items ══
  ('guia2','total','', array[20,45,70,90]),

  ('guia2','categoria','Ambiente de trabajo',                        array[3,5,7,9]),
  ('guia2','categoria','Factores propios de la actividad',           array[10,20,30,40]),
  ('guia2','categoria','Organización del tiempo de trabajo',         array[4,6,9,12]),
  ('guia2','categoria','Liderazgo y relaciones en el trabajo',       array[10,18,28,38]),

  ('guia2','dominio','Condiciones en el ambiente de trabajo',        array[3,5,7,9]),
  ('guia2','dominio','Carga de trabajo',                             array[12,16,20,24]),
  ('guia2','dominio','Falta de control sobre el trabajo',            array[5,8,11,14]),
  ('guia2','dominio','Jornada de trabajo',                           array[1,2,4,6]),
  ('guia2','dominio','Interferencia en la relación trabajo-familia', array[1,2,4,6]),
  ('guia2','dominio','Liderazgo',                                    array[3,5,8,11]),
  ('guia2','dominio','Relaciones en el trabajo',                     array[5,8,11,14]),
  ('guia2','dominio','Violencia',                                    array[7,10,13,16]),

  -- ══ GUIA III · 72 items ══
  ('guia3','total','', array[50,75,99,140]),

  ('guia3','categoria','Ambiente de trabajo',                        array[5,9,11,14]),
  ('guia3','categoria','Factores propios de la actividad',           array[15,30,45,60]),
  ('guia3','categoria','Organización del tiempo de trabajo',         array[5,7,10,13]),
  ('guia3','categoria','Liderazgo y relaciones en el trabajo',       array[14,29,42,58]),
  ('guia3','categoria','Entorno organizacional',                     array[10,14,18,23]),

  ('guia3','dominio','Condiciones en el ambiente de trabajo',        array[5,9,11,14]),
  ('guia3','dominio','Carga de trabajo',                             array[15,21,27,37]),
  ('guia3','dominio','Falta de control sobre el trabajo',            array[11,16,21,25]),
  ('guia3','dominio','Jornada de trabajo',                           array[1,2,4,6]),
  ('guia3','dominio','Interferencia en la relación trabajo-familia', array[4,6,8,10]),
  ('guia3','dominio','Liderazgo',                                    array[9,12,16,20]),
  ('guia3','dominio','Relaciones en el trabajo',                     array[10,13,17,21]),
  ('guia3','dominio','Violencia',                                    array[7,10,13,16]),
  ('guia3','dominio','Reconocimiento del desempeño',                 array[6,10,14,18]),
  ('guia3','dominio','Insuficiente sentido de pertenencia e inestabilidad', array[4,6,8,10]);

-- ─────────────────────────────────────────────────────────────
--  ITEMS · metadata
--
--  Se insertan con el numero como texto provisional. El texto
--  real lo escribe la importacion, que solo toca la columna
--  `pregunta`: asi la metadata verificada aqui no se puede
--  sobrescribir por accidente.
-- ─────────────────────────────────────────────────────────────

-- ══════════════════ GUIA II ══════════════════
insert into public.nom035_items
  (guia, numero, pregunta, categoria, dominio, dimension, direccion, condicional)
values
-- Ambiente de trabajo
('guia2', 1,'[pendiente]','Ambiente de trabajo','Condiciones en el ambiente de trabajo','Condiciones deficientes e insalubres','directa',null),
('guia2', 2,'[pendiente]','Ambiente de trabajo','Condiciones en el ambiente de trabajo','Condiciones peligrosas e inseguras','directa',null),
('guia2', 3,'[pendiente]','Ambiente de trabajo','Condiciones en el ambiente de trabajo','Trabajos peligrosos','directa',null),
-- Carga de trabajo
('guia2', 4,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas cuantitativas','directa',null),
('guia2', 5,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Ritmos de trabajo acelerado','directa',null),
('guia2', 6,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Ritmos de trabajo acelerado','directa',null),
('guia2', 7,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Carga mental','directa',null),
('guia2', 8,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Carga mental','directa',null),
('guia2', 9,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas cuantitativas','directa',null),
('guia2',10,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas de alta responsabilidad','directa',null),
('guia2',11,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas de alta responsabilidad','directa',null),
('guia2',12,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas contradictorias o inconsistentes','directa',null),
('guia2',13,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas contradictorias o inconsistentes','directa',null),
-- Organizacion del tiempo de trabajo
('guia2',14,'[pendiente]','Organización del tiempo de trabajo','Jornada de trabajo','Jornadas de trabajo extensas','directa',null),
('guia2',15,'[pendiente]','Organización del tiempo de trabajo','Jornada de trabajo','Jornadas de trabajo extensas','directa',null),
('guia2',16,'[pendiente]','Organización del tiempo de trabajo','Interferencia en la relación trabajo-familia','Influencia del trabajo fuera del centro laboral','directa',null),
('guia2',17,'[pendiente]','Organización del tiempo de trabajo','Interferencia en la relación trabajo-familia','Influencia de las responsabilidades familiares','directa',null),
-- Falta de control (items 18 a 33 son INVERSOS, Tabla 2)
('guia2',18,'[pendiente]','Factores propios de la actividad','Falta de control sobre el trabajo','Limitada o nula posibilidad de desarrollo','inversa',null),
('guia2',19,'[pendiente]','Factores propios de la actividad','Falta de control sobre el trabajo','Limitada o nula posibilidad de desarrollo','inversa',null),
('guia2',20,'[pendiente]','Factores propios de la actividad','Falta de control sobre el trabajo','Falta de control y autonomía sobre el trabajo','inversa',null),
('guia2',21,'[pendiente]','Factores propios de la actividad','Falta de control sobre el trabajo','Falta de control y autonomía sobre el trabajo','inversa',null),
('guia2',22,'[pendiente]','Factores propios de la actividad','Falta de control sobre el trabajo','Falta de control y autonomía sobre el trabajo','inversa',null),
('guia2',23,'[pendiente]','Liderazgo y relaciones en el trabajo','Liderazgo','Escasa claridad de funciones','inversa',null),
('guia2',24,'[pendiente]','Liderazgo y relaciones en el trabajo','Liderazgo','Escasa claridad de funciones','inversa',null),
('guia2',25,'[pendiente]','Liderazgo y relaciones en el trabajo','Liderazgo','Escasa claridad de funciones','inversa',null),
('guia2',26,'[pendiente]','Factores propios de la actividad','Falta de control sobre el trabajo','Limitada o inexistente capacitación','inversa',null),
('guia2',27,'[pendiente]','Factores propios de la actividad','Falta de control sobre el trabajo','Limitada o inexistente capacitación','inversa',null),
('guia2',28,'[pendiente]','Liderazgo y relaciones en el trabajo','Liderazgo','Características del liderazgo','inversa',null),
('guia2',29,'[pendiente]','Liderazgo y relaciones en el trabajo','Liderazgo','Características del liderazgo','inversa',null),
('guia2',30,'[pendiente]','Liderazgo y relaciones en el trabajo','Relaciones en el trabajo','Relaciones sociales en el trabajo','inversa',null),
('guia2',31,'[pendiente]','Liderazgo y relaciones en el trabajo','Relaciones en el trabajo','Relaciones sociales en el trabajo','inversa',null),
('guia2',32,'[pendiente]','Liderazgo y relaciones en el trabajo','Relaciones en el trabajo','Relaciones sociales en el trabajo','inversa',null),
('guia2',33,'[pendiente]','Liderazgo y relaciones en el trabajo','Violencia','Violencia laboral','inversa',null),
-- Violencia (34 a 40 vuelven a ser DIRECTOS)
('guia2',34,'[pendiente]','Liderazgo y relaciones en el trabajo','Violencia','Violencia laboral','directa',null),
('guia2',35,'[pendiente]','Liderazgo y relaciones en el trabajo','Violencia','Violencia laboral','directa',null),
('guia2',36,'[pendiente]','Liderazgo y relaciones en el trabajo','Violencia','Violencia laboral','directa',null),
('guia2',37,'[pendiente]','Liderazgo y relaciones en el trabajo','Violencia','Violencia laboral','directa',null),
('guia2',38,'[pendiente]','Liderazgo y relaciones en el trabajo','Violencia','Violencia laboral','directa',null),
('guia2',39,'[pendiente]','Liderazgo y relaciones en el trabajo','Violencia','Violencia laboral','directa',null),
('guia2',40,'[pendiente]','Liderazgo y relaciones en el trabajo','Violencia','Violencia laboral','directa',null),
-- Condicionales: solo aplican a quien atiende clientes
('guia2',41,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas psicológicas emocionales','directa','clientes'),
('guia2',42,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas psicológicas emocionales','directa','clientes'),
('guia2',43,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas psicológicas emocionales','directa','clientes'),
-- Condicionales: solo aplican a quien supervisa personal
('guia2',44,'[pendiente]','Liderazgo y relaciones en el trabajo','Relaciones en el trabajo','Deficiente relación con los colaboradores que supervisa','directa','jefe'),
('guia2',45,'[pendiente]','Liderazgo y relaciones en el trabajo','Relaciones en el trabajo','Deficiente relación con los colaboradores que supervisa','directa','jefe'),
('guia2',46,'[pendiente]','Liderazgo y relaciones en el trabajo','Relaciones en el trabajo','Deficiente relación con los colaboradores que supervisa','directa','jefe')
on conflict (guia, numero) do update set
  categoria = excluded.categoria, dominio = excluded.dominio,
  dimension = excluded.dimension, direccion = excluded.direccion,
  condicional = excluded.condicional;

-- ══════════════════ GUIA III ══════════════════
insert into public.nom035_items
  (guia, numero, pregunta, categoria, dominio, dimension, direccion, condicional)
values
-- Ambiente de trabajo (1 y 4 inversos, Tabla 5)
('guia3', 1,'[pendiente]','Ambiente de trabajo','Condiciones en el ambiente de trabajo','Condiciones peligrosas e inseguras','inversa',null),
('guia3', 2,'[pendiente]','Ambiente de trabajo','Condiciones en el ambiente de trabajo','Condiciones deficientes e insalubres','directa',null),
('guia3', 3,'[pendiente]','Ambiente de trabajo','Condiciones en el ambiente de trabajo','Condiciones peligrosas e inseguras','directa',null),
('guia3', 4,'[pendiente]','Ambiente de trabajo','Condiciones en el ambiente de trabajo','Condiciones deficientes e insalubres','inversa',null),
('guia3', 5,'[pendiente]','Ambiente de trabajo','Condiciones en el ambiente de trabajo','Trabajos peligrosos','directa',null),
-- Carga de trabajo
('guia3', 6,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas cuantitativas','directa',null),
('guia3', 7,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Ritmos de trabajo acelerado','directa',null),
('guia3', 8,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Ritmos de trabajo acelerado','directa',null),
-- CORRECCION: carga mental son 9, 10 y 11 (la fuente decia «8, 19, 11»)
('guia3', 9,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Carga mental','directa',null),
('guia3',10,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Carga mental','directa',null),
('guia3',11,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Carga mental','directa',null),
('guia3',12,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas cuantitativas','directa',null),
('guia3',13,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas de alta responsabilidad','directa',null),
('guia3',14,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas de alta responsabilidad','directa',null),
('guia3',15,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas contradictorias o inconsistentes','directa',null),
('guia3',16,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas contradictorias o inconsistentes','directa',null),
-- Organizacion del tiempo de trabajo
('guia3',17,'[pendiente]','Organización del tiempo de trabajo','Jornada de trabajo','Jornadas de trabajo extensas','directa',null),
('guia3',18,'[pendiente]','Organización del tiempo de trabajo','Jornada de trabajo','Jornadas de trabajo extensas','directa',null),
('guia3',19,'[pendiente]','Organización del tiempo de trabajo','Interferencia en la relación trabajo-familia','Influencia del trabajo fuera del centro laboral','directa',null),
('guia3',20,'[pendiente]','Organización del tiempo de trabajo','Interferencia en la relación trabajo-familia','Influencia del trabajo fuera del centro laboral','directa',null),
('guia3',21,'[pendiente]','Organización del tiempo de trabajo','Interferencia en la relación trabajo-familia','Influencia de las responsabilidades familiares','directa',null),
('guia3',22,'[pendiente]','Organización del tiempo de trabajo','Interferencia en la relación trabajo-familia','Influencia de las responsabilidades familiares','directa',null),
-- Falta de control sobre el trabajo
('guia3',23,'[pendiente]','Factores propios de la actividad','Falta de control sobre el trabajo','Limitada o nula posibilidad de desarrollo','inversa',null),
('guia3',24,'[pendiente]','Factores propios de la actividad','Falta de control sobre el trabajo','Limitada o nula posibilidad de desarrollo','inversa',null),
('guia3',25,'[pendiente]','Factores propios de la actividad','Falta de control sobre el trabajo','Falta de control y autonomía sobre el trabajo','inversa',null),
('guia3',26,'[pendiente]','Factores propios de la actividad','Falta de control sobre el trabajo','Falta de control y autonomía sobre el trabajo','inversa',null),
('guia3',27,'[pendiente]','Factores propios de la actividad','Falta de control sobre el trabajo','Falta de control y autonomía sobre el trabajo','inversa',null),
('guia3',28,'[pendiente]','Factores propios de la actividad','Falta de control sobre el trabajo','Falta de control y autonomía sobre el trabajo','inversa',null),
-- 29 directo y 30 inverso: asi lo define la Tabla 5
('guia3',29,'[pendiente]','Factores propios de la actividad','Falta de control sobre el trabajo','Insuficiente participación y manejo del cambio','directa',null),
('guia3',30,'[pendiente]','Factores propios de la actividad','Falta de control sobre el trabajo','Insuficiente participación y manejo del cambio','inversa',null),
-- Liderazgo
('guia3',31,'[pendiente]','Liderazgo y relaciones en el trabajo','Liderazgo','Escasa claridad de funciones','inversa',null),
('guia3',32,'[pendiente]','Liderazgo y relaciones en el trabajo','Liderazgo','Escasa claridad de funciones','inversa',null),
('guia3',33,'[pendiente]','Liderazgo y relaciones en el trabajo','Liderazgo','Escasa claridad de funciones','inversa',null),
('guia3',34,'[pendiente]','Liderazgo y relaciones en el trabajo','Liderazgo','Escasa claridad de funciones','inversa',null),
('guia3',35,'[pendiente]','Factores propios de la actividad','Falta de control sobre el trabajo','Limitada o inexistente capacitación','inversa',null),
('guia3',36,'[pendiente]','Factores propios de la actividad','Falta de control sobre el trabajo','Limitada o inexistente capacitación','inversa',null),
('guia3',37,'[pendiente]','Liderazgo y relaciones en el trabajo','Liderazgo','Características del liderazgo','inversa',null),
('guia3',38,'[pendiente]','Liderazgo y relaciones en el trabajo','Liderazgo','Características del liderazgo','inversa',null),
('guia3',39,'[pendiente]','Liderazgo y relaciones en el trabajo','Liderazgo','Características del liderazgo','inversa',null),
('guia3',40,'[pendiente]','Liderazgo y relaciones en el trabajo','Liderazgo','Características del liderazgo','inversa',null),
('guia3',41,'[pendiente]','Liderazgo y relaciones en el trabajo','Liderazgo','Características del liderazgo','inversa',null),
-- Relaciones en el trabajo
('guia3',42,'[pendiente]','Liderazgo y relaciones en el trabajo','Relaciones en el trabajo','Relaciones sociales en el trabajo','inversa',null),
('guia3',43,'[pendiente]','Liderazgo y relaciones en el trabajo','Relaciones en el trabajo','Relaciones sociales en el trabajo','inversa',null),
('guia3',44,'[pendiente]','Liderazgo y relaciones en el trabajo','Relaciones en el trabajo','Relaciones sociales en el trabajo','inversa',null),
('guia3',45,'[pendiente]','Liderazgo y relaciones en el trabajo','Relaciones en el trabajo','Relaciones sociales en el trabajo','inversa',null),
('guia3',46,'[pendiente]','Liderazgo y relaciones en el trabajo','Relaciones en el trabajo','Relaciones sociales en el trabajo','inversa',null),
-- Entorno organizacional · Reconocimiento del desempeño
('guia3',47,'[pendiente]','Entorno organizacional','Reconocimiento del desempeño','Escasa o nula retroalimentación del desempeño','inversa',null),
('guia3',48,'[pendiente]','Entorno organizacional','Reconocimiento del desempeño','Escasa o nula retroalimentación del desempeño','inversa',null),
('guia3',49,'[pendiente]','Entorno organizacional','Reconocimiento del desempeño','Escaso o nulo reconocimiento y compensación','inversa',null),
('guia3',50,'[pendiente]','Entorno organizacional','Reconocimiento del desempeño','Escaso o nulo reconocimiento y compensación','inversa',null),
('guia3',51,'[pendiente]','Entorno organizacional','Reconocimiento del desempeño','Escaso o nulo reconocimiento y compensación','inversa',null),
('guia3',52,'[pendiente]','Entorno organizacional','Reconocimiento del desempeño','Escaso o nulo reconocimiento y compensación','inversa',null),
-- CORRECCION: 53 y 54 son "Inestabilidad laboral" (la fuente
-- repetia "Limitado sentido de pertenencia", que es 55 y 56)
('guia3',53,'[pendiente]','Entorno organizacional','Insuficiente sentido de pertenencia e inestabilidad','Inestabilidad laboral','inversa',null),
('guia3',54,'[pendiente]','Entorno organizacional','Insuficiente sentido de pertenencia e inestabilidad','Inestabilidad laboral','directa',null),
('guia3',55,'[pendiente]','Entorno organizacional','Insuficiente sentido de pertenencia e inestabilidad','Limitado sentido de pertenencia','inversa',null),
('guia3',56,'[pendiente]','Entorno organizacional','Insuficiente sentido de pertenencia e inestabilidad','Limitado sentido de pertenencia','inversa',null),
-- Violencia (57 inverso, 58 a 64 directos)
('guia3',57,'[pendiente]','Liderazgo y relaciones en el trabajo','Violencia','Violencia laboral','inversa',null),
('guia3',58,'[pendiente]','Liderazgo y relaciones en el trabajo','Violencia','Violencia laboral','directa',null),
('guia3',59,'[pendiente]','Liderazgo y relaciones en el trabajo','Violencia','Violencia laboral','directa',null),
('guia3',60,'[pendiente]','Liderazgo y relaciones en el trabajo','Violencia','Violencia laboral','directa',null),
('guia3',61,'[pendiente]','Liderazgo y relaciones en el trabajo','Violencia','Violencia laboral','directa',null),
('guia3',62,'[pendiente]','Liderazgo y relaciones en el trabajo','Violencia','Violencia laboral','directa',null),
('guia3',63,'[pendiente]','Liderazgo y relaciones en el trabajo','Violencia','Violencia laboral','directa',null),
('guia3',64,'[pendiente]','Liderazgo y relaciones en el trabajo','Violencia','Violencia laboral','directa',null),
-- Condicionales: atienden clientes
('guia3',65,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas psicológicas emocionales','directa','clientes'),
('guia3',66,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas psicológicas emocionales','directa','clientes'),
('guia3',67,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas psicológicas emocionales','directa','clientes'),
('guia3',68,'[pendiente]','Factores propios de la actividad','Carga de trabajo','Cargas psicológicas emocionales','directa','clientes'),
-- Condicionales: supervisan personal
('guia3',69,'[pendiente]','Liderazgo y relaciones en el trabajo','Relaciones en el trabajo','Deficiente relación con los colaboradores que supervisa','directa','jefe'),
('guia3',70,'[pendiente]','Liderazgo y relaciones en el trabajo','Relaciones en el trabajo','Deficiente relación con los colaboradores que supervisa','directa','jefe'),
('guia3',71,'[pendiente]','Liderazgo y relaciones en el trabajo','Relaciones en el trabajo','Deficiente relación con los colaboradores que supervisa','directa','jefe'),
('guia3',72,'[pendiente]','Liderazgo y relaciones en el trabajo','Relaciones en el trabajo','Deficiente relación con los colaboradores que supervisa','directa','jefe')
on conflict (guia, numero) do update set
  categoria = excluded.categoria, dominio = excluded.dominio,
  dimension = excluded.dimension, direccion = excluded.direccion,
  condicional = excluded.condicional;

-- ─────────────────────────────────────────────────────────────
--  GUIA I · estructura
--
--  Solo la estructura de secciones y claves. El texto de las 20
--  preguntas viene de la importacion.
-- ─────────────────────────────────────────────────────────────
insert into public.nom035_guia1 (seccion, seccion_tit, instruccion, clave, orden, texto)
select 1, 'Sección I. Acontecimiento traumático severo',
       'Ha presenciado o sufrido alguna vez, durante o con motivo del trabajo un acontecimiento como los siguientes:',
       's1_' || g, g, '[pendiente]'
from generate_series(1,6) g
union all
select 2, 'Sección II. Recuerdos persistentes sobre el acontecimiento',
       'Si respondió SI en alguna de las preguntas anteriores, continúe. Si respondió NO en todas, el cuestionario termina aquí.',
       's2_' || g, g, '[pendiente]'
from generate_series(1,2) g
union all
select 3, 'Sección III. Esfuerzo por evitar circunstancias parecidas',
       null, 's3_' || g, g, '[pendiente]'
from generate_series(1,7) g
union all
select 4, 'Sección IV. Afectación negativa en su vida',
       null, 's4_' || g, g, '[pendiente]'
from generate_series(1,5) g
on conflict (clave) do update set
  seccion = excluded.seccion,
  seccion_tit = excluded.seccion_tit,
  instruccion = excluded.instruccion;

-- ─────────────────────────────────────────────────────────────
--  IMPORTACION DE TEXTOS
--
--  Solo actualiza `pregunta` y `texto`. La metadata verificada
--  arriba NO se puede sobrescribir desde aqui, ni por accidente
--  ni por un export con datos incompletos.
-- ─────────────────────────────────────────────────────────────
create or replace function public.nom035_importar_textos(p_datos jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  g     text;
  x     jsonb;
  s     jsonb;
  p     jsonb;
  v_n   integer := 0;
  v_g1  integer := 0;
begin
  if not app.es_proveedor() then
    raise exception 'Solo el proveedor puede actualizar el catalogo oficial';
  end if;

  foreach g in array array['guia2','guia3'] loop
    if p_datos ? g then
      for x in select * from jsonb_array_elements(p_datos->g) loop
        update public.nom035_items
           set pregunta = x->>'pregunta'
         where guia = g::public.guia_nom035
           and numero = (x->>'item')::integer
           and coalesce(trim(x->>'pregunta'),'') <> '';
        if found then v_n := v_n + 1; end if;
      end loop;
    end if;
  end loop;

  if p_datos ? 'guia1_secciones' then
    for s in select * from jsonb_array_elements(p_datos->'guia1_secciones') loop
      for p in select * from jsonb_array_elements(s->'preguntas') loop
        update public.nom035_guia1
           set texto = p->>'texto'
         where clave = p->>'id'
           and coalesce(trim(p->>'texto'),'') <> '';
        if found then v_g1 := v_g1 + 1; end if;
      end loop;
    end loop;
  end if;

  return jsonb_build_object('status','success',
    'textos_frp', v_n, 'textos_guia1', v_g1,
    'pendientes', (select count(*) from public.nom035_items where pregunta = '[pendiente]')
                + (select count(*) from public.nom035_guia1 where texto = '[pendiente]'));
end;
$$;

grant execute on function public.nom035_importar_textos(jsonb) to authenticated;