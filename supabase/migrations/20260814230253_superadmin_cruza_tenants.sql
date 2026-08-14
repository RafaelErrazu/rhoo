-- ═══════════════════════════════════════════════════════════
--  RHoo! · Migración 03 · El superadmin cruza tenants
--
--  El superadmin es el proveedor del producto y vive en su
--  propio tenant ('rhoo'), no dentro de un cliente. Las
--  políticas de la migración 01 filtran por
--  `tenant_id = app.mi_tenant()`, así que sin esto el proveedor
--  no vería datos de ningún cliente y no podría dar soporte.
--
--  Se implementa como una política ADICIONAL en lugar de
--  modificar las existentes: en Postgres las políticas de un
--  mismo comando se combinan con OR, así que agregar una no
--  debilita las demás. Y si algún día se quita el acceso del
--  proveedor, se borra esta política y nada más.
--
--  ADVERTENCIA: esto le da al proveedor acceso de lectura y
--  escritura a los datos de todos los clientes. Es lo normal en
--  SaaS, pero debe ir acompañado de una tabla de auditoría
--  antes de tener clientes en producción.
-- ═══════════════════════════════════════════════════════════

create or replace function app.es_proveedor()
returns boolean
language sql
stable
as $$
  select app.mi_rol() = 'superadmin'
$$;

comment on function app.es_proveedor is
  'Verdadero solo para el superadmin (proveedor del producto). Usada por las politicas que cruzan tenants.';

do $$
declare
  t text;
  tablas text[] := array[
    'perfiles','centros_trabajo','empleados',
    'dias_no_laborables','turnos','patrones_rotacion',
    'asignaciones_turno','checadas','jornadas',
    'tipos_incidencia','incidencias','vacaciones_movimientos'
  ];
begin
  foreach t in array tablas loop
    execute format(
      'drop policy if exists %I on public.%I',
      'zz_proveedor_' || t, t
    );
    execute format(
      'create policy %I on public.%I for all
         using (app.es_proveedor())
         with check (app.es_proveedor())',
      'zz_proveedor_' || t, t
    );
  end loop;
end $$;