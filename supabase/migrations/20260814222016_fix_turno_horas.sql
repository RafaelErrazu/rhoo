-- ═══════════════════════════════════════════════════════════
--  Fix: turno_horas() con turnos que cruzan medianoche.
--
--  El tipo `time` es ciclico: time '06:00' + interval '24 hours'
--  devuelve 06:00, no 30:00. Por eso el nocturno daba -16.50.
--  Se resta primero y se corrige sobre el intervalo resultante,
--  que si acepta valores mayores a 24 horas.
-- ═══════════════════════════════════════════════════════════

create or replace function public.turno_horas(t public.turnos)
returns numeric
language sql
immutable
as $$
  select round(
    (
      (
        extract(epoch from (t.hora_salida - t.hora_entrada))
        + case when t.hora_salida <= t.hora_entrada then 86400 else 0 end
      ) / 3600
    )::numeric
    - case when t.comida_computa then 0 else t.minutos_comida / 60.0 end
  , 2)
$$;

comment on function public.turno_horas is
  'Horas efectivas del turno, descontando comida si no computa. Maneja turnos que cruzan medianoche.';