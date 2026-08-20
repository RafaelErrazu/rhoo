-- ═══════════════════════════════════════════════════════════
--  RHoo! · Notificaciones internas
-- ═══════════════════════════════════════════════════════════

create type public.nivel_notif as enum ('info','aviso','urgente','celebra');

create table public.notificaciones (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  -- Destinatario concreto. Las notificaciones "para RH" se
  -- expanden a un renglon por persona al generarse, no se
  -- resuelven al leer: asi cada quien marca la suya como leida
  -- sin afectar a los demas.
  perfil_id    uuid not null references public.perfiles(id) on delete cascade,

  tipo         text not null,
  nivel        public.nivel_notif not null default 'info',
  titulo       text not null,
  cuerpo       text,

  modulo       text,
  entidad_id   text,

  -- Menor = mas urgente. En el sistema anterior la urgencia se
  -- deducia leyendo el texto con expresiones regulares: un parche
  -- que se rompia al cambiar la redaccion.
  dias         integer,

  leida        boolean not null default false,
  leida_en     timestamptz,

  -- Deduplicacion real: un indice unico, no una comprobacion en
  -- el navegador.
  clave        text not null,

  expira_en    timestamptz,
  creado_en    timestamptz not null default now()
);

create unique index notif_clave_unq
  on public.notificaciones (perfil_id, clave);

create index notif_perfil_idx
  on public.notificaciones (perfil_id, leida, dias nulls last, creado_en desc);

alter table public.notificaciones enable row level security;

-- Cada quien ve SOLO las suyas, ni siendo admin: una
-- notificacion puede decir "tu incapacidad fue aprobada".
create policy notif_propias on public.notificaciones
  for select using (perfil_id = auth.uid());
create policy notif_marcar on public.notificaciones
  for update using (perfil_id = auth.uid())
  with check (perfil_id = auth.uid());

grant select, update on public.notificaciones to authenticated;

create or replace function app.notificar(
  p_perfil_id  uuid,
  p_tipo       text,
  p_titulo     text,
  p_cuerpo     text default null,
  p_nivel      public.nivel_notif default 'info',
  p_modulo     text default null,
  p_entidad_id text default null,
  p_dias       integer default null,
  p_clave      text default null,
  p_expira     timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tenant uuid;
  v_id     uuid;
begin
  select tenant_id into v_tenant from public.perfiles
   where id = p_perfil_id and activo;
  if v_tenant is null then return null; end if;

  insert into public.notificaciones
    (tenant_id, perfil_id, tipo, nivel, titulo, cuerpo,
     modulo, entidad_id, dias, clave, expira_en)
  values
    (v_tenant, p_perfil_id, p_tipo, p_nivel, p_titulo, p_cuerpo,
     p_modulo, p_entidad_id, p_dias,
     coalesce(p_clave, p_tipo || ':' || coalesce(p_entidad_id, gen_random_uuid()::text)),
     p_expira)
  -- Misma clave = misma notificacion. Un vencimiento que pasa de
  -- 30 a 5 dias no es una notificacion nueva, es la misma con
  -- otro texto.
  on conflict (perfil_id, clave) do update set
    titulo    = excluded.titulo,
    cuerpo    = excluded.cuerpo,
    nivel     = excluded.nivel,
    dias      = excluded.dias,
    expira_en = excluded.expira_en,
    leida     = case
                  -- Si se volvio mas urgente, vuelve a no leida:
                  -- enterarse de "vence en un mes" no es
                  -- enterarse de "vence el viernes".
                  when excluded.dias is not null
                       and public.notificaciones.dias is not null
                       and excluded.dias < public.notificaciones.dias
                  then false
                  else public.notificaciones.leida
                end
  returning id into v_id;

  return v_id;
end;
$$;

create or replace function app.notificar_rol(
  p_tenant_id  uuid,
  p_roles      text[],
  p_tipo       text,
  p_titulo     text,
  p_cuerpo     text default null,
  p_nivel      public.nivel_notif default 'info',
  p_modulo     text default null,
  p_entidad_id text default null,
  p_dias       integer default null,
  p_clave      text default null,
  p_expira     timestamptz default null
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare r record; v_n integer := 0;
begin
  for r in
    select id from public.perfiles
    where tenant_id = p_tenant_id and activo
      and (p_roles = array['*'] or rol::text = any(p_roles))
  loop
    if app.notificar(r.id, p_tipo, p_titulo, p_cuerpo, p_nivel,
                     p_modulo, p_entidad_id, p_dias, p_clave, p_expira) is not null
    then v_n := v_n + 1; end if;
  end loop;
  return v_n;
end;
$$;

-- ═══════════════════════════════════════════════════════════
--  DISPARADORES EN TIEMPO REAL
--
--  TODOS van envueltos en un bloque que captura errores. Un
--  trigger corre dentro de la transaccion de la operacion, asi
--  que sin esto una notificacion rota tumbaria la aprobacion de
--  una incapacidad. Mejor perder el aviso que la operacion.
-- ═══════════════════════════════════════════════════════════

create or replace function app.notif_incidencia_nueva()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  e       public.empleados;
  t       public.tipos_incidencia;
  v_quien text;
  v_jefe  uuid;
begin
  begin
    select * into e from public.empleados where id = new.empleado_id;
    select * into t from public.tipos_incidencia where id = new.tipo_id;

    v_quien := app.siguiente_aprobador(new.id);
    if v_quien is null then return new; end if;

    if v_quien = 'jefe' then
      select p.id into v_jefe from public.perfiles p
       where p.empleado_id = e.jefe_id and p.activo limit 1;
      if v_jefe is not null then
        perform app.notificar(v_jefe, 'incidencia_pendiente',
          e.nombre_completo || ' solicita ' || lower(t.nombre),
          new.dias || ' día(s), del ' || new.fecha_inicio || ' al ' || new.fecha_fin
            || '. Espera tu autorización.',
          'aviso', 'incidencias', new.id::text, 0,
          'inc_firma:' || new.id::text);
      end if;
    else
      perform app.notificar_rol(new.tenant_id, array['admin','rh'],
        'incidencia_pendiente',
        e.nombre_completo || ' solicita ' || lower(t.nombre),
        new.dias || ' día(s), del ' || new.fecha_inicio || ' al ' || new.fecha_fin
          || '. Espera autorización de Recursos Humanos.',
        'aviso', 'incidencias', new.id::text, 0,
        'inc_firma:' || new.id::text);
    end if;
  exception when others then
    -- Se registra y se sigue: la solicitud vale mas que el aviso
    raise warning 'No se pudo notificar la incidencia %: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

create trigger inc_notif_nueva
  after insert on public.incidencias
  for each row execute function app.notif_incidencia_nueva();

create or replace function app.notif_incidencia_resuelta()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  e        public.empleados;
  t        public.tipos_incidencia;
  v_perfil uuid;
begin
  if new.estatus = old.estatus then return new; end if;

  begin
    select * into e from public.empleados where id = new.empleado_id;
    select * into t from public.tipos_incidencia where id = new.tipo_id;
    select id into v_perfil from public.perfiles
     where empleado_id = new.empleado_id and activo limit 1;

    if new.estatus = 'aprobada' and v_perfil is not null then
      perform app.notificar(v_perfil, 'incidencia_resuelta',
        'Tu solicitud de ' || lower(t.nombre) || ' fue aprobada',
        new.dias || ' día(s) del ' || new.fecha_inicio || ' al ' || new.fecha_fin
          || (case when t.descuenta_vac
                   then '. Se descontaron de tu saldo de vacaciones.'
                   else '' end),
        'info', 'incidencias', new.id::text, null,
        'inc_res:' || new.id::text);

    elsif new.estatus = 'rechazada' and v_perfil is not null then
      perform app.notificar(v_perfil, 'incidencia_resuelta',
        'Tu solicitud de ' || lower(t.nombre) || ' fue rechazada',
        coalesce(new.resuelto_nota, 'Consulta con Recursos Humanos.'),
        'aviso', 'incidencias', new.id::text, null,
        'inc_res:' || new.id::text);

    elsif new.estatus = 'aprobada_jefe' then
      perform app.notificar_rol(new.tenant_id, array['admin','rh'],
        'incidencia_pendiente',
        e.nombre_completo || ' solicita ' || lower(t.nombre),
        'Ya autorizada por su jefe. Falta tu autorización.',
        'aviso', 'incidencias', new.id::text, 0,
        'inc_firma:' || new.id::text);
    end if;

    -- La de "firma pendiente" se cierra sola: dejarla haria que
    -- el jefe la abra para descubrir que ya no hay nada que hacer.
    if new.estatus in ('aprobada','rechazada','cancelada') then
      update public.notificaciones
         set leida = true, leida_en = now()
       where clave = 'inc_firma:' || new.id::text and not leida;
    end if;

  exception when others then
    raise warning 'No se pudo notificar la resolucion %: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

create trigger inc_notif_resuelta
  after update of estatus on public.incidencias
  for each row execute function app.notif_incidencia_resuelta();

create or replace function app.notif_accion_asignada()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_perfil uuid;
begin
  if new.responsable_id is null
     or new.responsable_id is not distinct from old.responsable_id then
    return new;
  end if;

  begin
    select id into v_perfil from public.perfiles
     where empleado_id = new.responsable_id and activo limit 1;
    if v_perfil is null then return new; end if;

    perform app.notificar(v_perfil, 'accion_asignada',
      'Te asignaron una acción del programa NOM-035',
      new.accion || (case when new.fecha_meta is not null
                          then ' · Fecha compromiso: ' || new.fecha_meta
                          else '' end),
      'aviso', 'cumplimiento', new.id::text,
      case when new.fecha_meta is not null
           then (new.fecha_meta - current_date) else null end,
      'accion:' || new.id::text);
  exception when others then
    raise warning 'No se pudo notificar la accion %: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

create trigger acc_notif_asignada
  after insert or update of responsable_id on public.nom035_acciones
  for each row execute function app.notif_accion_asignada();

/* Guía I: se avisa el caso SIN decir quién. El nombre está en el
   expediente, no en una notificación que se puede leer por
   encima del hombro. */
create or replace function app.notif_guia1_valoracion()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not new.gi_requiere_valoracion then return new; end if;
  begin
    perform app.notificar_rol(new.tenant_id, array['admin','rh'],
      'guia1_valoracion',
      'Un trabajador requiere valoración por acontecimiento traumático',
      'La Guía I detectó un caso que debe canalizarse a la institución de '
        || 'seguridad social o al médico del centro de trabajo (numeral 5.5). '
        || 'Consulta el expediente correspondiente.',
      'urgente', 'cumplimiento', new.id::text, 0,
      'g1:' || new.id::text);
  exception when others then
    raise warning 'No se pudo notificar Guia I %: %', new.id, sqlerrm;
  end;
  return new;
end;
$$;

create trigger nom035_notif_g1
  after insert on public.nom035_respuestas
  for each row execute function app.notif_guia1_valoracion();

-- ═══════════════════════════════════════════════════════════
--  BARRIDO DIARIO
--  Para lo que tiene plazo, no momento. Idempotente.
-- ═══════════════════════════════════════════════════════════
create or replace function public.generar_notificaciones()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r     record;
  v_n   integer := 0;
  v_hoy date := current_date;
begin
  -- ── CUMPLEAÑOS ──
  -- A TODO el tenant, no solo a RH: un cumpleaños que solo
  -- conoce Recursos Humanos no le sirve a nadie.
  for r in
    select e.tenant_id, e.id, e.nombre_completo,
           to_char(e.fecha_nacimiento, 'DD/MM') as fecha
    from public.empleados e
    where e.estatus = 'Activo'
      and e.fecha_nacimiento is not null
      and extract(month from e.fecha_nacimiento) = extract(month from v_hoy)
      and extract(day   from e.fecha_nacimiento) = extract(day   from v_hoy)
  loop
    v_n := v_n + app.notificar_rol(r.tenant_id, array['*'],
      'cumpleanos',
      'Hoy cumple años ' || r.nombre_completo,
      'Aprovecha para felicitarle.',
      'celebra', 'empleados', r.id::text, 0,
      'cumple:' || r.id::text || ':' || extract(year from v_hoy)::text,
      -- Caduca en 2 dias: un cumpleanos de la semana pasada solo
      -- estorba en el panel.
      (v_hoy + 2)::timestamptz);
  end loop;

  -- ── ANIVERSARIOS DE INGRESO ──
  for r in
    select e.tenant_id, e.id, e.nombre_completo,
           extract(year from age(v_hoy, e.fecha_ingreso))::integer as anios
    from public.empleados e
    where e.estatus = 'Activo'
      and e.fecha_ingreso is not null
      and e.fecha_ingreso < v_hoy
      and extract(month from e.fecha_ingreso) = extract(month from v_hoy)
      and extract(day   from e.fecha_ingreso) = extract(day   from v_hoy)
  loop
    if r.anios >= 1 then
      v_n := v_n + app.notificar_rol(r.tenant_id, array['*'],
        'aniversario',
        r.nombre_completo || ' cumple ' || r.anios || ' año'
          || (case when r.anios = 1 then '' else 's' end) || ' en la empresa',
        case
          -- Los múltiplos de 5 son los que la empresa suele
          -- reconocer y los que peor se ve que se pasen.
          when r.anios % 5 = 0
          then 'Es un aniversario destacado: buen momento para un reconocimiento.'
          else 'Aprovecha para reconocer su trayectoria.'
        end,
        'celebra', 'empleados', r.id::text, 0,
        'aniv:' || r.id::text || ':' || extract(year from v_hoy)::text,
        (v_hoy + 2)::timestamptz);
    end if;
  end loop;

  -- ── DOCUMENTOS POR VENCER ──
  for r in
    select d.id, d.tenant_id, d.fecha_vence, e.nombre_completo,
           coalesce(t.nombre,'Documento') as tipo,
           (d.fecha_vence - v_hoy) as dias
    from public.documentos d
    join public.empleados e on e.id = d.empleado_id
    left join public.tipos_documento t on t.id = d.tipo_id
    where d.fecha_vence is not null
      and d.fecha_vence <= v_hoy + 30
      and e.estatus = 'Activo'
  loop
    v_n := v_n + app.notificar_rol(r.tenant_id, array['admin','rh'],
      'doc_vence',
      r.tipo || ' de ' || r.nombre_completo
        || (case when r.dias < 0 then ' está vencido' else ' por vencer' end),
      case when r.dias < 0
           then 'Venció hace ' || abs(r.dias) || ' día(s), el ' || r.fecha_vence || '.'
           when r.dias = 0 then 'Vence hoy.'
           else 'Vence en ' || r.dias || ' día(s), el ' || r.fecha_vence || '.' end,
      case when r.dias < 0 then 'urgente'::public.nivel_notif
           else 'aviso'::public.nivel_notif end,
      'empleados', r.id::text, r.dias,
      'doc:' || r.id::text,
      -- Si nadie lo atendio en dos meses, el aviso ya no ayuda
      (r.fecha_vence + 60)::timestamptz);
  end loop;

  -- ── VIGENCIA NOM-035 ──
  for r in
    select c.tenant_id, ct.nombre as centro,
           (max(c.abre) + (app.cfg_int('nom035_meses_vigencia', c.tenant_id)
                           || ' months')::interval)::date as limite
    from public.nom035_campanas c
    join public.centros_trabajo ct on ct.id = c.centro_id
    where c.estado = 'cerrada'
    group by c.tenant_id, ct.nombre
  loop
    if (r.limite - v_hoy) <= app.cfg_int('nom035_dias_aviso', r.tenant_id) then
      v_n := v_n + app.notificar_rol(r.tenant_id, array['admin','rh'],
        'nom035_vigencia',
        'La evaluación NOM-035 de ' || r.centro
          || (case when r.limite < v_hoy then ' está vencida' else ' por vencer' end),
        case when r.limite < v_hoy
             then 'Venció el ' || r.limite
                  || '. La Norma obliga a repetirla al menos cada dos años.'
             else 'Vence el ' || r.limite
                  || '. Aplicarla a un centro completo toma semanas: conviene programarla.' end,
        case when r.limite < v_hoy then 'urgente'::public.nivel_notif
             else 'aviso'::public.nivel_notif end,
        'cumplimiento', null, (r.limite - v_hoy),
        'nom035v:' || r.centro);
    end if;
  end loop;

  -- ── UBICACIONES TEMPORALES POR CADUCAR ──
  for r in
    select ue.tenant_id, e.nombre_completo, u.nombre as ubic, ue.hasta,
           (ue.hasta - v_hoy) as dias
    from public.ubicaciones_empleado ue
    join public.empleados e on e.id = ue.empleado_id
    join public.ubicaciones u on u.id = ue.ubicacion_id
    where ue.hasta is not null
      and ue.hasta between v_hoy and v_hoy + 7
      and e.estatus = 'Activo'
  loop
    v_n := v_n + app.notificar_rol(r.tenant_id, array['admin','rh'],
      'ubic_caduca',
      'Permiso de ubicación por caducar: ' || r.nombre_completo,
      'Su autorización para checar en ' || r.ubic || ' termina el ' || r.hasta
        || '. Si sigue ahí, renuévala o no podrá registrar asistencia.',
      'aviso', 'asistencia', null, r.dias,
      'ubic:' || r.nombre_completo || ':' || r.hasta::text,
      (r.hasta + 15)::timestamptz);
  end loop;

  -- ── JORNADAS DE AYER POR REVISAR ──
  -- Agrupadas: 30 avisos individuales entierran todo lo demas.
  for r in
    select j.tenant_id, count(*) as n
    from public.jornadas j
    where j.fecha_laboral = v_hoy - 1
      and j.estatus in ('incompleta','falta')
    group by j.tenant_id
  loop
    v_n := v_n + app.notificar_rol(r.tenant_id, array['admin','rh'],
      'jornadas_revisar',
      r.n || ' jornada(s) de ayer requieren revisión',
      'Hay registros incompletos o faltas sin justificar del ' || (v_hoy - 1) || '.',
      'aviso', 'asistencia', null, 1,
      'jorn:' || (v_hoy - 1)::text,
      (v_hoy + 15)::timestamptz);
  end loop;

  -- ── CAMPAÑAS QUE CIERRAN SIN MUESTRA ──
  for r in
    select c.tenant_id, c.nombre, c.muestra_minima, c.cierra,
           (select count(*) from public.nom035_respuestas x where x.campana_id = c.id) as resp,
           (c.cierra - v_hoy) as dias
    from public.nom035_campanas c
    where c.estado = 'abierta' and c.cierra is not null
      and c.cierra between v_hoy and v_hoy + 7
  loop
    if r.resp < coalesce(r.muestra_minima, 0) then
      v_n := v_n + app.notificar_rol(r.tenant_id, array['admin','rh'],
        'campana_cierra',
        'La campaña "' || r.nombre || '" cierra pronto y no alcanza la muestra',
        'Van ' || r.resp || ' de ' || r.muestra_minima || ' respuestas necesarias. '
          || 'Cierra el ' || r.cierra || '. Si cierra por debajo de la muestra, '
          || 'la evaluación podría considerarse insuficiente.',
        'urgente', 'cumplimiento', null, r.dias,
        'camp:' || r.nombre);
    end if;
  end loop;

  -- Limpieza de caducadas
  delete from public.notificaciones
   where expira_en is not null and expira_en < now();

  return jsonb_build_object('status','success','generadas', v_n);
end;
$$;

create or replace function public.mis_notificaciones(p_limite integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare v_filas jsonb; v_no_leidas integer;
begin
  select count(*) into v_no_leidas
  from public.notificaciones
  where perfil_id = auth.uid() and not leida
    and (expira_en is null or expira_en > now());

  select jsonb_agg(x) into v_filas
  from (
    select jsonb_build_object(
      'id', id, 'tipo', tipo, 'nivel', nivel,
      'titulo', titulo, 'cuerpo', cuerpo,
      'modulo', modulo, 'entidad_id', entidad_id,
      'dias', dias, 'leida', leida, 'creado', creado_en
    ) as x
    from public.notificaciones
    where perfil_id = auth.uid()
      and (expira_en is null or expira_en > now())
    -- No leidas primero; entre ellas, lo mas urgente arriba
    order by leida asc, dias asc nulls last, creado_en desc
    limit p_limite
  ) s;

  return jsonb_build_object(
    'status','success',
    'no_leidas', v_no_leidas,
    'filas', coalesce(v_filas, '[]'::jsonb));
end;
$$;

create or replace function public.notif_marcar_leidas(p_ids uuid[] default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.notificaciones
     set leida = true, leida_en = now()
   where perfil_id = auth.uid() and not leida
     and (p_ids is null or id = any(p_ids));
  return jsonb_build_object('status','success');
end;
$$;

grant execute on function public.generar_notificaciones()    to authenticated;
grant execute on function public.mis_notificaciones(integer)  to authenticated;
grant execute on function public.notif_marcar_leidas(uuid[])  to authenticated;