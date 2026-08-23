create or replace function public.nomina_sueldo_historial(p_empleado_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_t uuid := app.mi_tenant();
  e public.empleados;
begin
  -- El sueldo lo ve RH y administracion, no cualquiera con acceso a
  -- expedientes. Un jefe puede ver a su equipo pero no lo que gana.
  if not app.es_admin() then
    raise exception 'No tienes permiso para consultar sueldos.';
  end if;

  select * into e from public.empleados
   where id = p_empleado_id and tenant_id = v_t;
  if not found then raise exception 'Empleado no encontrado'; end if;

  return jsonb_build_object(
    'empleado', jsonb_build_object(
      'id', e.id, 'nombre', e.nombre_completo,
      'no_empleado', e.no_empleado, 'fecha_ingreso', e.fecha_ingreso),
    'sdi', public.sdi_empleado(p_empleado_id, current_date),
    'minimos', jsonb_build_object(
      'general', app.param('salario_minimo', current_date),
      'frontera', app.param('salario_minimo_znf', current_date)),
    'grupos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', g.id, 'clave', g.clave, 'nombre', g.nombre,
               'frecuencia', g.frecuencia) order by g.clave), '[]'::jsonb)
        from public.grupos_nomina g
       where g.tenant_id = v_t and g.activo),
    'historial', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', s.id, 'sueldo_diario', s.sueldo_diario, 'tipo', s.tipo,
               'dias_aguinaldo', s.dias_aguinaldo,
               'prima_vac_pct', s.prima_vac_pct,
               'otras_prestaciones', s.otras_prestaciones,
               'zona_frontera', s.zona_frontera,
               'banco', s.banco, 'clabe', s.clabe,
               'desde', s.desde, 'hasta', s.hasta, 'motivo', s.motivo,
               'grupo', g.clave, 'grupo_nombre', g.nombre,
               'grupo_id', s.grupo_id,
               'vigente', (s.hasta is null or s.hasta >= current_date)
                          and s.desde <= current_date,
               'creado_en', s.creado_en,
               'capturo', pf.nombre)
             order by s.desde desc), '[]'::jsonb)
        from public.sueldos s
        left join public.grupos_nomina g on g.id = s.grupo_id
        left join public.perfiles pf on pf.id = s.creado_por
       where s.empleado_id = p_empleado_id)
  );
end;
$$;

revoke all on function public.nomina_sueldo_historial(uuid) from public;
grant execute on function public.nomina_sueldo_historial(uuid) to authenticated;