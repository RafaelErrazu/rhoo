-- ═══════════════════════════════════════════════════════════
--  RHoo! · Gestión de usuarios
-- ═══════════════════════════════════════════════════════════

alter table public.perfiles
  add column if not exists debe_cambiar_password boolean not null default false,
  add column if not exists creado_por uuid references public.perfiles(id),
  add column if not exists ultimo_acceso timestamptz;

/* Jerarquía de roles. Un numero mas alto es mas privilegio.
   Se usa para impedir que alguien cree o edite un rol por
   encima del suyo: sin eso, el primer admin de cualquier
   cliente podria escalar a proveedor. */
create or replace function app.nivel_rol(p_rol public.rol_usuario)
returns integer
language sql
immutable
as $$
  select case p_rol
    when 'colaborador' then 1
    when 'jefe'        then 2
    when 'rh'          then 3
    when 'admin'       then 4
    when 'superadmin'  then 5
    else 0 end
$$;

/* Usuarios visibles. El proveedor ve todos; un admin solo los
   de su tenant. */
create or replace function public.usuarios_lista()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id,
    'nombre', p.nombre,
    'email', p.email,
    'rol', p.rol,
    'activo', p.activo,
    'debe_cambiar', p.debe_cambiar_password,
    'creado', p.creado_en,
    'ultimo_acceso', u.last_sign_in_at,
    -- Nunca entró: el indicador de que la cuenta se creó y el
    -- correo con la contraseña nunca llegó a su destino.
    'nunca_entro', u.last_sign_in_at is null,
    'empleado', (select nombre_completo from public.empleados e
                 where e.id = p.empleado_id),
    'empleado_id', p.empleado_id,
    'tenant', t.nombre,
    'tenant_id', p.tenant_id,
    'es_yo', p.id = auth.uid()
  ) order by p.creado_en desc), '[]'::jsonb)
  from public.perfiles p
  join public.tenants t on t.id = p.tenant_id
  left join auth.users u on u.id = p.id
  where (
    (p.tenant_id = app.mi_tenant() and app.es_admin())
    or app.es_proveedor()
  )
$$;

/* Valida que quien pide puede crear ese rol en ese tenant.
   La llama la Edge Function ANTES de tocar auth.users: si la
   validacion viviera en el JS de la funcion, cambiarla seria
   redesplegar; aqui es una migracion versionada. */
create or replace function public.puede_crear_usuario(
  p_tenant_id uuid,
  p_rol       text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_mi_rol public.rol_usuario := app.mi_rol();
  v_rol    public.rol_usuario;
begin
  begin
    v_rol := p_rol::public.rol_usuario;
  exception when others then
    return jsonb_build_object('ok', false, 'motivo','Rol no válido');
  end;

  if v_mi_rol is null then
    return jsonb_build_object('ok', false, 'motivo','Sin perfil');
  end if;

  -- Solo el proveedor crea usuarios en otros tenants
  if p_tenant_id <> app.mi_tenant() and not app.es_proveedor() then
    return jsonb_build_object('ok', false,
      'motivo','No puedes crear usuarios en otra empresa');
  end if;

  if not app.es_admin() then
    return jsonb_build_object('ok', false,
      'motivo','Solo administradores pueden crear usuarios');
  end if;

  -- Nadie crea un rol igual o superior al suyo, salvo el
  -- proveedor. Es lo que impide la escalada de privilegios.
  if app.nivel_rol(v_rol) >= app.nivel_rol(v_mi_rol)
     and not app.es_proveedor() then
    return jsonb_build_object('ok', false,
      'motivo','No puedes asignar un rol igual o superior al tuyo');
  end if;

  if v_rol = 'superadmin' and not app.es_proveedor() then
    return jsonb_build_object('ok', false,
      'motivo','El rol de proveedor solo lo asigna el proveedor');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

/* Crea el perfil después de que la Edge Function creó el usuario
   en auth. Separado a propósito: si el perfil falla, el usuario
   de auth ya existe y se puede reintentar sin duplicar. */
create or replace function public.crear_perfil(
  p_user_id    uuid,
  p_tenant_id  uuid,
  p_rol        text,
  p_nombre     text,
  p_email      text,
  p_empleado_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_check jsonb;
begin
  v_check := public.puede_crear_usuario(p_tenant_id, p_rol);
  if not (v_check->>'ok')::boolean then
    raise exception '%', v_check->>'motivo';
  end if;

  insert into public.perfiles
    (id, tenant_id, rol, nombre, email, empleado_id,
     debe_cambiar_password, creado_por)
  values
    (p_user_id, p_tenant_id, p_rol::public.rol_usuario,
     trim(p_nombre), lower(trim(p_email)), p_empleado_id,
     true, auth.uid())
  on conflict (id) do update set
    tenant_id = excluded.tenant_id,
    rol = excluded.rol,
    nombre = excluded.nombre,
    empleado_id = excluded.empleado_id;

  perform app.auditar('usuario.crear', 'perfiles', p_user_id::text, null,
    jsonb_build_object('email', p_email, 'rol', p_rol, 'tenant', p_tenant_id));

  return jsonb_build_object('status','success');
end;
$$;

create or replace function public.usuario_actualizar(
  p_id    uuid,
  p_datos jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  p        public.perfiles;
  v_mi_rol public.rol_usuario := app.mi_rol();
  v_nuevo  public.rol_usuario;
begin
  select * into p from public.perfiles where id = p_id;
  if not found then raise exception 'Usuario no encontrado'; end if;

  if p.tenant_id <> app.mi_tenant() and not app.es_proveedor() then
    raise exception 'Sin permiso';
  end if;
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  -- No puedes editar a alguien de rol igual o superior al tuyo
  if app.nivel_rol(p.rol) >= app.nivel_rol(v_mi_rol)
     and p.id <> auth.uid() and not app.es_proveedor() then
    raise exception 'No puedes modificar a un usuario de rol igual o superior al tuyo';
  end if;

  if p_datos ? 'rol' then
    v_nuevo := (p_datos->>'rol')::public.rol_usuario;
    if app.nivel_rol(v_nuevo) >= app.nivel_rol(v_mi_rol)
       and not app.es_proveedor() then
      raise exception 'No puedes asignar un rol igual o superior al tuyo';
    end if;
    -- Nadie se cambia su propio rol: es la puerta de atras mas
    -- obvia para escalar privilegios.
    if p.id = auth.uid() then
      raise exception 'No puedes cambiar tu propio rol';
    end if;
  end if;

  update public.perfiles set
    nombre      = coalesce(nullif(p_datos->>'nombre',''), nombre),
    rol         = coalesce(v_nuevo, rol),
    empleado_id = case when p_datos ? 'empleado_id'
                  then nullif(p_datos->>'empleado_id','')::uuid
                  else empleado_id end
  where id = p_id;

  perform app.auditar('usuario.actualizar', 'perfiles', p_id::text,
    jsonb_build_object('rol', p.rol, 'nombre', p.nombre), p_datos);

  return jsonb_build_object('status','success');
end;
$$;

/* Activa o desactiva. No borra: un usuario eliminado convierte
   su rastro en la auditoria en "usuario desconocido" justo
   cuando alguien pregunta quien autorizo que. */
create or replace function public.usuario_activar(
  p_id     uuid,
  p_activo boolean,
  p_motivo text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare p public.perfiles;
begin
  select * into p from public.perfiles where id = p_id;
  if not found then raise exception 'Usuario no encontrado'; end if;

  if p.tenant_id <> app.mi_tenant() and not app.es_proveedor() then
    raise exception 'Sin permiso';
  end if;
  if not app.es_admin() then raise exception 'Sin permiso'; end if;

  -- Desactivarte a ti mismo te deja fuera sin manera de volver
  if p_id = auth.uid() then
    raise exception 'No puedes desactivar tu propia cuenta';
  end if;

  if app.nivel_rol(p.rol) >= app.nivel_rol(app.mi_rol())
     and not app.es_proveedor() then
    raise exception 'No puedes desactivar a un usuario de rol igual o superior al tuyo';
  end if;

  update public.perfiles set activo = p_activo where id = p_id;

  perform app.auditar(
    case when p_activo then 'usuario.activar' else 'usuario.desactivar' end,
    'perfiles', p_id::text, null,
    jsonb_build_object('motivo', p_motivo, 'email', p.email));

  return jsonb_build_object('status','success');
end;
$$;

/* Empleados que aún no tienen usuario: para ligar cuenta a
   expediente sin adivinar. */
create or replace function public.empleados_sin_usuario()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id, 'nombre', e.nombre_completo, 'no', e.no_empleado,
    'email', e.email, 'puesto', e.puesto
  ) order by e.nombre_completo), '[]'::jsonb)
  from public.empleados e
  where e.tenant_id = app.mi_tenant()
    and e.estatus = 'Activo'
    and app.es_admin()
    and not exists (select 1 from public.perfiles p where p.empleado_id = e.id)
$$;

/* Marca que ya cambió su contraseña. */
create or replace function public.password_cambiada()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.perfiles
     set debe_cambiar_password = false
   where id = auth.uid();
  perform app.auditar('usuario.password', 'perfiles', auth.uid()::text, null, null);
  return jsonb_build_object('status','success');
end;
$$;

grant execute on function public.usuarios_lista()                        to authenticated;
grant execute on function public.puede_crear_usuario(uuid,text)           to authenticated;
grant execute on function public.crear_perfil(uuid,uuid,text,text,text,uuid) to authenticated;
grant execute on function public.usuario_actualizar(uuid,jsonb)           to authenticated;
grant execute on function public.usuario_activar(uuid,boolean,text)       to authenticated;
grant execute on function public.empleados_sin_usuario()                  to authenticated;
grant execute on function public.password_cambiada()                      to authenticated;