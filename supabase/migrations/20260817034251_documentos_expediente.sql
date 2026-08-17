-- ═══════════════════════════════════════════════════════════
--  RHoo! · Documentos del expediente
-- ═══════════════════════════════════════════════════════════

create table public.tipos_documento (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  clave       text not null,
  nombre      text not null,
  obligatorio boolean not null default false,
  vence       boolean not null default false,   -- ¿tiene caducidad?
  -- Qué campos del expediente puede llenar el OCR de este tipo.
  -- Se declara aquí y no en el código: así un cliente puede
  -- agregar un tipo propio sin tocar la aplicación.
  campos_ocr  text[] not null default '{}',
  orden       integer not null default 100,
  activo      boolean not null default true,

  unique (tenant_id, clave)
);

create table public.documentos (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  empleado_id  uuid not null references public.empleados(id) on delete cascade,
  tipo_id      uuid references public.tipos_documento(id) on delete set null,

  nombre       text not null,
  ruta         text not null unique,      -- tenant/empleado/archivo
  mime         text,
  tamano       integer,

  fecha_doc    date,
  fecha_vence  date,

  -- Resultado del OCR. Se guarda el texto completo además de los
  -- campos: ocupa poco y permite auditar de donde salio un dato.
  ocr_estado   text not null default 'pendiente'
               check (ocr_estado in ('pendiente','procesado','sin_datos','error','omitido')),
  ocr_texto    text,
  ocr_campos   jsonb,
  ocr_error    text,

  subido_por   uuid references public.perfiles(id),
  creado_en    timestamptz not null default now()
);

create index docs_emp_idx on public.documentos (tenant_id, empleado_id, creado_en desc);
create index docs_vence_idx on public.documentos (tenant_id, fecha_vence)
  where fecha_vence is not null;

alter table public.tipos_documento enable row level security;
alter table public.documentos      enable row level security;

create policy tipos_doc_leer on public.tipos_documento
  for select using (tenant_id = app.mi_tenant());
create policy tipos_doc_escribir on public.tipos_documento
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

-- El empleado ve SUS documentos. Es su derecho: son sus papeles.
create policy docs_leer on public.documentos
  for select using (
    tenant_id = app.mi_tenant() and (
      app.es_admin()
      or empleado_id = (select empleado_id from public.perfiles where id = auth.uid())
    )
  );
create policy docs_escribir on public.documentos
  for all using (tenant_id = app.mi_tenant() and app.es_admin())
  with check (tenant_id = app.mi_tenant() and app.es_admin());

create policy zz_proveedor_documentos on public.documentos
  for all using (app.es_proveedor()) with check (app.es_proveedor());
create policy zz_proveedor_tipos_doc on public.tipos_documento
  for all using (app.es_proveedor()) with check (app.es_proveedor());

grant select, insert, update, delete
  on public.documentos, public.tipos_documento to authenticated;

-- ═══════════════════════════════════════════════════════════
--  POLÍTICAS DE STORAGE
--
--  La ruta es 'tenant_id/empleado_id/archivo'. Estas politicas
--  leen la PRIMERA carpeta y la comparan con el tenant del
--  usuario: por eso la estructura de carpetas no es cosmetica,
--  es el mecanismo de aislamiento.
-- ═══════════════════════════════════════════════════════════

create policy "expedientes_leer"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'expedientes'
    and (
      (storage.foldername(name))[1] = app.mi_tenant()::text
      or app.es_proveedor()
    )
  );

create policy "expedientes_subir"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'expedientes'
    and (storage.foldername(name))[1] = app.mi_tenant()::text
    and app.es_admin()
  );

create policy "expedientes_borrar"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'expedientes'
    and (storage.foldername(name))[1] = app.mi_tenant()::text
    and app.es_admin()
  );

-- ═══════════════════════════════════════════════════════════
--  ENDPOINTS
-- ═══════════════════════════════════════════════════════════

/* Registra el documento después de que el archivo ya subió a
   Storage. Se hace en dos pasos (subir, luego registrar) porque
   el archivo viaja directo del navegador a Storage sin pasar por
   la base: mandar un PDF de 8 MB dentro de un JSON sería lento y
   caro. */
create or replace function public.registrar_documento(
  p_empleado_id uuid,
  p_tipo_clave  text,
  p_nombre      text,
  p_ruta        text,
  p_mime        text default null,
  p_tamano      integer default null,
  p_fecha_doc   date default null,
  p_fecha_vence date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tipo uuid;
  v_id   uuid;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  if not exists (select 1 from public.empleados
                 where id = p_empleado_id and tenant_id = app.mi_tenant()) then
    raise exception 'Empleado no encontrado';
  end if;

  -- La ruta debe empezar con el tenant. Es lo mismo que valida
  -- Storage, revisado aqui tambien: defensa en dos capas.
  if split_part(p_ruta, '/', 1) <> app.mi_tenant()::text then
    raise exception 'Ruta invalida';
  end if;

  select id into v_tipo from public.tipos_documento
   where tenant_id = app.mi_tenant() and clave = p_tipo_clave;

  insert into public.documentos
    (tenant_id, empleado_id, tipo_id, nombre, ruta, mime, tamano,
     fecha_doc, fecha_vence, subido_por)
  values
    (app.mi_tenant(), p_empleado_id, v_tipo, p_nombre, p_ruta, p_mime, p_tamano,
     p_fecha_doc, p_fecha_vence, auth.uid())
  returning id into v_id;

  perform app.auditar('documento.subir', 'documentos', v_id::text, null,
    jsonb_build_object('empleado', p_empleado_id, 'tipo', p_tipo_clave,
                       'nombre', p_nombre));

  return jsonb_build_object('status','success','id', v_id);
end;
$$;

/* Documentos de un empleado, más qué obligatorios faltan.
   La lista de faltantes es el dato útil: nadie revisa 12
   documentos para descubrir cuál no está. */
create or replace function public.documentos_empleado(p_empleado_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare v_yo uuid;
begin
  select empleado_id into v_yo from public.perfiles where id = auth.uid();
  if not app.es_admin() and v_yo is distinct from p_empleado_id then
    raise exception 'Sin permiso';
  end if;

  return jsonb_build_object(
    'status','success',
    'documentos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', d.id, 'nombre', d.nombre, 'ruta', d.ruta, 'mime', d.mime,
        'tipo', t.nombre, 'tipo_clave', t.clave,
        'fecha_doc', d.fecha_doc, 'fecha_vence', d.fecha_vence,
        'vencido', d.fecha_vence is not null and d.fecha_vence < current_date,
        'por_vencer', d.fecha_vence is not null
                      and d.fecha_vence between current_date and current_date + 30,
        'ocr_estado', d.ocr_estado, 'ocr_campos', d.ocr_campos,
        'creado_en', d.creado_en
      ) order by d.creado_en desc)
      from public.documentos d
      left join public.tipos_documento t on t.id = d.tipo_id
      where d.empleado_id = p_empleado_id
    ), '[]'::jsonb),
    'faltantes', coalesce((
      select jsonb_agg(jsonb_build_object('clave', t.clave, 'nombre', t.nombre))
      from public.tipos_documento t
      where t.tenant_id = app.mi_tenant()
        and t.obligatorio and t.activo
        and not exists (
          select 1 from public.documentos d
          where d.empleado_id = p_empleado_id and d.tipo_id = t.id
        )
    ), '[]'::jsonb),
    'tipos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'clave', clave, 'nombre', nombre, 'vence', vence,
        'campos_ocr', campos_ocr) order by orden, nombre)
      from public.tipos_documento
      where tenant_id = app.mi_tenant() and activo
    ), '[]'::jsonb)
  );
end;
$$;

/* Guarda el resultado del OCR. La llama la Edge Function. */
create or replace function public.guardar_ocr(
  p_documento_id uuid,
  p_estado       text,
  p_texto        text default null,
  p_campos       jsonb default null,
  p_error        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.documentos
     set ocr_estado = p_estado,
         ocr_texto  = p_texto,
         ocr_campos = p_campos,
         ocr_error  = p_error
   where id = p_documento_id;

  return jsonb_build_object('status','success');
end;
$$;

/* Aplica los campos que RH confirmó. El OCR propone; esto
   escribe, y solo con confirmación explícita. */
create or replace function public.aplicar_ocr(
  p_documento_id uuid,
  p_campos       jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  d public.documentos;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  select * into d from public.documentos
   where id = p_documento_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Documento no encontrado'; end if;

  -- Se reusa actualizar_empleado: tiene la lista blanca de
  -- campos y su propia auditoria. Duplicar la logica aqui seria
  -- crear una segunda puerta con reglas distintas.
  perform public.actualizar_empleado(d.empleado_id, p_campos);

  perform app.auditar('ocr.aplicar', 'documentos', p_documento_id::text, null,
    p_campos);

  return jsonb_build_object('status','success');
end;
$$;

create or replace function public.eliminar_documento(p_id uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare d public.documentos;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;
  if coalesce(trim(p_motivo),'') = '' then
    raise exception 'Indica el motivo';
  end if;

  select * into d from public.documentos
   where id = p_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'No encontrado'; end if;

  delete from public.documentos where id = p_id;

  perform app.auditar('documento.eliminar', 'documentos', p_id::text,
    jsonb_build_object('nombre', d.nombre, 'ruta', d.ruta),
    jsonb_build_object('motivo', p_motivo));

  return jsonb_build_object('status','success','ruta', d.ruta);
end;
$$;

grant execute on function public.registrar_documento(uuid,text,text,text,text,integer,date,date) to authenticated;
grant execute on function public.documentos_empleado(uuid)                    to authenticated;
grant execute on function public.guardar_ocr(uuid,text,text,jsonb,text)       to authenticated;
grant execute on function public.aplicar_ocr(uuid,jsonb)                      to authenticated;
grant execute on function public.eliminar_documento(uuid,text)                to authenticated;

-- ═══════════════════════════════════════════════════════════
--  SEMILLA · tipos de documento por tenant
--
--  campos_ocr declara qué puede extraer la IA de cada tipo. Es
--  lo que evita que el prompt intente sacar un NSS de un
--  comprobante de domicilio.
-- ═══════════════════════════════════════════════════════════
do $$
declare t record;
begin
  for t in select id from public.tenants loop
    insert into public.tipos_documento
      (tenant_id, clave, nombre, obligatorio, vence, campos_ocr, orden)
    values
      (t.id,'INE','Identificacion oficial (INE)', true, true,
       array['curp','nombres','apellido_paterno','apellido_materno',
             'fecha_nacimiento','sexo'], 10),
      (t.id,'CURP','Constancia de CURP', true, false,
       array['curp','nombres','apellido_paterno','apellido_materno',
             'fecha_nacimiento','sexo'], 20),
      (t.id,'RFC','Constancia de situacion fiscal', true, true,
       array['rfc','curp'], 30),
      (t.id,'NSS','Numero de seguridad social', true, false,
       array['nss','curp'], 40),
      (t.id,'DOM','Comprobante de domicilio', false, true,
       array[]::text[], 50),
      (t.id,'ACTA','Acta de nacimiento', false, false,
       array['fecha_nacimiento','nombres','apellido_paterno','apellido_materno'], 60),
      (t.id,'ESTUDIOS','Comprobante de estudios', false, false,
       array['escolaridad'], 70),
      (t.id,'CONTRATO','Contrato de trabajo', true, true,
       array[]::text[], 80),
      (t.id,'BANCO','Cuenta bancaria', false, false,
       array[]::text[], 90),
      (t.id,'OTRO','Otro documento', false, false,
       array[]::text[], 999)
    on conflict (tenant_id, clave) do nothing;
  end loop;
end $$;