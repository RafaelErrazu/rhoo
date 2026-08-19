-- El on conflict apuntaba a la restriccion (tenant_id, centro_id,
-- fecha), que no cubre el caso centro_id NULL. Ahora se declara
-- sobre las mismas columnas del indice parcial para que el
-- duplicado se ignore en lugar de fallar.
create or replace function public.sembrar_catalogos(p_tenant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  mat uuid; ves uuid; noc uuid;
  v_t integer := 0; v_i integer := 0; v_d integer := 0; v_f integer := 0;
  v_anio integer := extract(year from current_date)::integer;
begin
  if not app.es_proveedor() then
    raise exception 'Solo el proveedor puede sembrar catalogos';
  end if;

  insert into public.turnos
    (tenant_id, clave, nombre, hora_entrada, hora_salida, minutos_comida, color)
  values
    (p_tenant_id,'MAT','Matutino','09:00','18:00',60,'#2EC4B6'),
    (p_tenant_id,'VES','Vespertino','14:00','22:00',30,'#F4795B'),
    (p_tenant_id,'NOC','Nocturno','22:00','06:00',30,'#6366F1')
  on conflict (tenant_id, clave) do nothing;

  select count(*) into v_t from public.turnos where tenant_id = p_tenant_id;

  select id into mat from public.turnos where tenant_id=p_tenant_id and clave='MAT';
  select id into ves from public.turnos where tenant_id=p_tenant_id and clave='VES';
  select id into noc from public.turnos where tenant_id=p_tenant_id and clave='NOC';

  insert into public.patrones_rotacion (tenant_id, nombre, secuencia, unidad)
  values
    (p_tenant_id,'Rotativo 3 turnos (semanal)', array[mat,ves,noc],'semana'),
    (p_tenant_id,'4x3 Matutino', array[mat,mat,mat,mat,null,null,null]::uuid[],'dia'),
    (p_tenant_id,'2x2 Continuo', array[noc,noc,null,null]::uuid[],'dia')
  on conflict (tenant_id, nombre) do nothing;

  insert into public.tipos_incidencia
    (tenant_id, clave, nombre, con_goce, descuenta_vac, requiere_doc, color)
  values
    (p_tenant_id,'VAC','Vacaciones',            true,  true,  false,'#2EC4B6'),
    (p_tenant_id,'INC','Incapacidad IMSS',      true,  false, true, '#6366F1'),
    (p_tenant_id,'PCG','Permiso con goce',      true,  false, false,'#14A085'),
    (p_tenant_id,'PSG','Permiso sin goce',      false, false, false,'#D97706'),
    (p_tenant_id,'FJ', 'Falta justificada',     false, false, true, '#8494A7'),
    (p_tenant_id,'FI', 'Falta injustificada',   false, false, false,'#DC2626'),
    (p_tenant_id,'MAT','Licencia de maternidad',true,  false, true, '#EC4899'),
    (p_tenant_id,'PAT','Licencia de paternidad',true,  false, true, '#0EA5E9'),
    (p_tenant_id,'DUE','Permiso por fallecimiento', true, false, false,'#64748B')
  on conflict (tenant_id, clave) do nothing;

  select count(*) into v_i from public.tipos_incidencia where tenant_id = p_tenant_id;

  insert into public.tipos_documento
    (tenant_id, clave, nombre, obligatorio, vence, campos_ocr, orden)
  values
    (p_tenant_id,'INE','Identificación oficial (INE)', true, true,
     array['curp','nombres','apellido_paterno','apellido_materno','fecha_nacimiento','sexo'], 10),
    (p_tenant_id,'CURP','Constancia de CURP', true, false,
     array['curp','nombres','apellido_paterno','apellido_materno','fecha_nacimiento','sexo'], 20),
    (p_tenant_id,'RFC','Constancia de situación fiscal', true, true, array['rfc','curp'], 30),
    (p_tenant_id,'NSS','Número de seguridad social', true, false, array['nss','curp'], 40),
    (p_tenant_id,'DOM','Comprobante de domicilio', false, true, array[]::text[], 50),
    (p_tenant_id,'ACTA','Acta de nacimiento', false, false,
     array['fecha_nacimiento','nombres','apellido_paterno','apellido_materno'], 60),
    (p_tenant_id,'ESTUDIOS','Comprobante de estudios', false, false, array['escolaridad'], 70),
    (p_tenant_id,'CONTRATO','Contrato de trabajo', true, true, array[]::text[], 80),
    (p_tenant_id,'BANCO','Cuenta bancaria', false, false, array[]::text[], 90),
    (p_tenant_id,'POLITICA','Política de prevención de riesgos psicosociales',
     false, false, array[]::text[], 95),
    (p_tenant_id,'OTRO','Otro documento', false, false, array[]::text[], 999)
  on conflict (tenant_id, clave) do nothing;

  select count(*) into v_d from public.tipos_documento where tenant_id = p_tenant_id;

  insert into public.dias_no_laborables (tenant_id, fecha, descripcion, oficial)
  select p_tenant_id, f.fecha, f.desc, true
  from (
    select make_date(a,1,1) as fecha, 'Año Nuevo' as desc from generate_series(v_anio, v_anio+1) a
    union all
    select (make_date(a,2,1) + ((8 - extract(dow from make_date(a,2,1))::integer) % 7))::date,
           'Día de la Constitución' from generate_series(v_anio, v_anio+1) a
    union all
    select (make_date(a,3,1) + ((8 - extract(dow from make_date(a,3,1))::integer) % 7) + 14)::date,
           'Natalicio de Benito Juárez' from generate_series(v_anio, v_anio+1) a
    union all
    select make_date(a,5,1), 'Día del Trabajo' from generate_series(v_anio, v_anio+1) a
    union all
    select make_date(a,9,16),'Independencia de México' from generate_series(v_anio, v_anio+1) a
    union all
    select (make_date(a,11,1) + ((8 - extract(dow from make_date(a,11,1))::integer) % 7) + 14)::date,
           'Revolución Mexicana' from generate_series(v_anio, v_anio+1) a
    union all
    select make_date(a,12,25),'Navidad' from generate_series(v_anio, v_anio+1) a
  ) f
  where not exists (
    select 1 from public.dias_no_laborables d
    where d.tenant_id = p_tenant_id and d.centro_id is null and d.fecha = f.fecha);

  select count(*) into v_f from public.dias_no_laborables where tenant_id = p_tenant_id;

  perform app.auditar('proveedor.sembrar', 'tenants', p_tenant_id::text, null,
    jsonb_build_object('turnos', v_t, 'incidencias', v_i,
                       'documentos', v_d, 'festivos', v_f));

  return jsonb_build_object('status','success',
    'turnos', v_t, 'incidencias', v_i, 'documentos', v_d, 'festivos', v_f);
end;
$$;