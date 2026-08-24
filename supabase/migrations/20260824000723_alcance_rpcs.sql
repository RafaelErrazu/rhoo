-- ══ 1. listar_empleados ══════════════════════════════════════════════════
-- Ya aplicado en el editor; se formaliza aquí para que viva en el repo.

create or replace function public.estructura_empresarial()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_t uuid := app.mi_tenant();
begin
  if v_t is null then raise exception 'Sin sesion valida'; end if;

  return jsonb_build_object(
    'es_admin', app.es_admin(),
    -- Un RH limitado ve solo sus empresas, y por lo tanto solo los grupos que
    -- las contienen. Un grupo que quede sin empresas visibles no se pinta.
    'grupos', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', g.id, 'clave', g.clave, 'nombre', g.nombre,
               'reglas_desde', g.reglas_desde, 'activo', g.activo,
               'empresas', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'id', r.id, 'clave', r.clave,
                          'razon_social', r.razon_social,
                          'nombre_comercial', r.nombre_comercial,
                          'rfc', r.rfc, 'registro_patronal', r.registro_patronal,
                          'regimen_fiscal', r.regimen_fiscal,
                          'codigo_postal', r.codigo_postal,
                          'domicilio', r.domicilio,
                          'representante_legal', r.representante_legal,
                          'activo', r.activo,
                          'prima', public.prima_riesgo(r.id),
                          'centros', (
                            select count(*) from public.centros_trabajo c
                             where c.razon_id = r.id and c.activo),
                          'empleados', (
                            select count(*) from public.empleados e
                             where e.razon_id = r.id and e.estatus = 'Activo'),
                          'faltantes', (
                            select coalesce(jsonb_agg(f.x), '[]'::jsonb) from (
                              select 'RFC' as x where r.rfc is null
                              union all
                              select 'Registro patronal' where r.registro_patronal is null
                              union all
                              select 'Regimen fiscal' where r.regimen_fiscal is null
                              union all
                              select 'Codigo postal' where r.codigo_postal is null
                              union all
                              select 'Prima de riesgo' where public.prima_riesgo(r.id) is null
                            ) f)
                        ) order by r.clave), '[]'::jsonb)
                   from public.razones_sociales r
                  where r.grupo_id = g.id
                    and r.id in (select app.mis_razones()))
             ) order by g.clave), '[]'::jsonb)
        from public.grupos_empresariales g
       where g.tenant_id = v_t
         and exists (select 1 from public.razones_sociales r
                      where r.grupo_id = g.id
                        and r.id in (select app.mis_razones())))
  );
end;
$$;