-- Limpia duplicados dejando el mas antiguo de cada fecha
delete from public.dias_no_laborables d
where d.centro_id is null
  and exists (
    select 1 from public.dias_no_laborables x
    where x.tenant_id = d.tenant_id
      and x.centro_id is null
      and x.fecha = d.fecha
      and x.creado_en < d.creado_en);

-- La restriccion unique no cubre el caso centro_id NULL porque
-- en SQL NULL nunca es igual a NULL: cada re-siembra insertaba
-- los mismos 14 festivos otra vez. Un indice parcial si lo cubre.
create unique index if not exists dnl_tenant_fecha_unq
  on public.dias_no_laborables (tenant_id, fecha)
  where centro_id is null;