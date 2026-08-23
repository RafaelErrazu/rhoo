create or replace function public.dias_habiles_empleado(
  p_empleado_id uuid, p_desde date, p_hasta date)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  -- Delega en app.dias_consumibles para que exista UNA sola regla: dos
  -- funciones calculando lo mismo se desalinean el dia que alguien toca una y
  -- se olvida de la otra, y el sintoma aparece en el saldo de vacaciones.
  select app.dias_consumibles(p_empleado_id, p_desde, p_hasta)::integer
$$;