-- ═══════════════════════════════════════════════════════════
--  RHoo! · Vacaciones e incidencias con doble aprobacion
-- ═══════════════════════════════════════════════════════════

-- Se agrega el estado intermedio: aprobada por el jefe pero
-- pendiente de RH. Sin el, no se puede distinguir "nadie la ha
-- visto" de "el jefe ya dijo si".
alter type public.estatus_solicitud add value if not exists 'aprobada_jefe'
  before 'aprobada';

create table public.aprobaciones (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  incidencia_id uuid not null references public.incidencias(id) on delete cascade,

  nivel         text not null check (nivel in ('jefe','rh')),
  decision      text not null check (decision in ('aprobada','rechazada')),
  actor_id      uuid references public.perfiles(id),
  actor_nombre  text,               -- se copia: el perfil puede borrarse
  nota          text,
  creado_en     timestamptz not null default now(),

  unique (incidencia_id, nivel)
);

create index aprob_inc_idx on public.aprobaciones (incidencia_id, creado_en);

alter table public.aprobaciones enable row level security;

create policy aprob_leer on public.aprobaciones
  for select using (tenant_id = app.mi_tenant());
create policy zz_proveedor_aprob on public.aprobaciones
  for all using (app.es_proveedor()) with check (app.es_proveedor());

grant select on public.aprobaciones to authenticated;

/* Quién falta por aprobar.
   El orden es jefe primero, RH después: el jefe sabe si el
   equipo aguanta esos días; RH valida saldo y ley. Al revés, RH
   aprobaría algo que el jefe puede rechazar cuando el trabajador
   ya compró el boleto. */
create or replace function app.siguiente_aprobador(p_incidencia_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  i        public.incidencias;
  v_modo   text;
  v_jefe   uuid;
begin
  select * into i from public.incidencias where id = p_incidencia_id;
  if not found then return null; end if;

  v_modo := app.cfg_txt('inc_aprueba', i.tenant_id);
  select jefe_id into v_jefe from public.empleados where id = i.empleado_id;

  -- Sin jefe asignado no hay a quien esperar: la solicitud
  -- quedaria atorada para siempre.
  if v_modo = 'jefe' and v_jefe is null then v_modo := 'rh'; end if;
  if v_modo = 'ambos' and v_jefe is null then v_modo := 'rh'; end if;

  if v_modo = 'rh' then
    if exists (select 1 from public.aprobaciones
               where incidencia_id = p_incidencia_id and nivel = 'rh')
      then return null; else return 'rh'; end if;
  end if;

  if v_modo = 'jefe' then
    if exists (select 1 from public.aprobaciones
               where incidencia_id = p_incidencia_id and nivel = 'jefe')
      then return null; else return 'jefe'; end if;
  end if;

  -- ambos: jefe y luego RH
  if not exists (select 1 from public.aprobaciones
                 where incidencia_id = p_incidencia_id and nivel = 'jefe') then
    return 'jefe';
  end if;
  if not exists (select 1 from public.aprobaciones
                 where incidencia_id = p_incidencia_id and nivel = 'rh') then
    return 'rh';
  end if;
  return null;
end;
$$;

/* Días hábiles según el turno del empleado.
   No se cuentan días naturales: pedir del viernes al lunes con
   descanso en domingo son 3 días de vacaciones, no 4. Descontar
   el descanso semanal como vacaciones es cobrarle al trabajador
   un día que ya era suyo. */
create or replace function public.dias_habiles_empleado(
  p_empleado_id uuid,
  p_desde       date,
  p_hasta       date
)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select count(*)::integer
  from generate_series(p_desde, p_hasta, '1 day') d
  where public.turno_del_dia(p_empleado_id, d::date) is not null
    and not exists (
      select 1 from public.dias_no_laborables n
      join public.empleados e on e.id = p_empleado_id
      where n.tenant_id = e.tenant_id
        and n.fecha = d::date
        and (n.centro_id is null or n.centro_id = e.centro_id)
    )
$$;

/* Crea una solicitud. La puede pedir el propio empleado o RH. */
create or replace function public.solicitar_incidencia(
  p_tipo_clave  text,
  p_desde       date,
  p_hasta       date,
  p_comentario  text default null,
  p_empleado_id uuid default null      -- solo RH puede pedir por otro
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_yo     uuid;
  v_emp    uuid;
  e        public.empleados;
  t        public.tipos_incidencia;
  v_dias   integer;
  v_saldo  numeric;
  v_antic  integer;
  v_max    integer;
  v_id     uuid;
begin
  select empleado_id into v_yo from public.perfiles where id = auth.uid();

  v_emp := coalesce(p_empleado_id, v_yo);
  if v_emp is null then
    raise exception 'Tu usuario no esta ligado a un expediente de empleado';
  end if;
  if p_empleado_id is not null and p_empleado_id <> v_yo and not app.es_admin() then
    raise exception 'Solo Recursos Humanos puede solicitar por otra persona';
  end if;

  select * into e from public.empleados
   where id = v_emp and tenant_id = app.mi_tenant();
  if not found then raise exception 'Empleado no encontrado'; end if;
  if e.estatus <> 'Activo' then
    raise exception 'El empleado no esta activo';
  end if;

  select * into t from public.tipos_incidencia
   where tenant_id = app.mi_tenant() and clave = p_tipo_clave and activo;
  if not found then raise exception 'Tipo de incidencia no valido'; end if;

  if p_hasta < p_desde then
    raise exception 'La fecha final no puede ser anterior a la inicial';
  end if;

  -- Traslape: dos incidencias el mismo dia significan que alguien
  -- esta de vacaciones e incapacitado a la vez.
  if exists (
    select 1 from public.incidencias
    where empleado_id = v_emp
      and estatus in ('pendiente','aprobada_jefe','aprobada')
      and daterange(fecha_inicio, fecha_fin, '[]') && daterange(p_desde, p_hasta, '[]')
  ) then
    raise exception 'Ya existe una solicitud que se traslapa con esas fechas';
  end if;

  v_dias := public.dias_habiles_empleado(v_emp, p_desde, p_hasta);
  if v_dias = 0 then
    raise exception 'El periodo elegido no incluye dias laborables';
  end if;

  -- ── Reglas propias de vacaciones ──
  if t.descuenta_vac then
    v_saldo := public.saldo_vacaciones(v_emp);
    if v_dias > v_saldo then
      raise exception 'Solo tienes % dia(s) disponibles y estas pidiendo %',
        round(v_saldo), v_dias;
    end if;

    v_antic := app.cfg_int('vac_anticipacion_dias', e.tenant_id);
    if p_desde < current_date + v_antic and not app.es_admin() then
      raise exception 'Las vacaciones se solicitan con al menos % dias de anticipacion',
        v_antic;
    end if;

    v_max := app.cfg_int('vac_max_dias_continuos', e.tenant_id);
    -- El tope de la empresa no puede impedir los 12 dias continuos
    -- que el articulo 78 de la LFT garantiza si el trabajador los
    -- pide. Por eso el limite solo aplica arriba de 12.
    if v_max > 0 and v_dias > greatest(v_max, 12) then
      raise exception 'El maximo de dias continuos es %', greatest(v_max, 12);
    end if;
  end if;

  if t.requiere_doc and v_dias >= app.cfg_int('inc_requiere_doc_dias', e.tenant_id) then
    -- No se bloquea: el comprobante se adjunta despues, en
    -- Documentos. Bloquear aqui impediria registrar una
    -- incapacidad el mismo dia que ocurre.
    null;
  end if;

  insert into public.incidencias
    (tenant_id, empleado_id, tipo_id, fecha_inicio, fecha_fin,
     comentario, estatus, solicitado_por)
  values
    (e.tenant_id, v_emp, t.id, p_desde, p_hasta,
     p_comentario, 'pendiente', auth.uid())
  returning id into v_id;

  -- Los dias se actualizan al del calculo habil
  update public.incidencias set dias = v_dias where id = v_id;

  perform app.auditar('incidencia.solicitar', 'incidencias', v_id::text, null,
    jsonb_build_object('tipo', p_tipo_clave, 'desde', p_desde,
                       'hasta', p_hasta, 'dias', v_dias));

  return jsonb_build_object(
    'status','success', 'id', v_id, 'dias', v_dias,
    'espera', app.siguiente_aprobador(v_id)
  );
end;
$$;

/* Resuelve una firma. Cuando cae la última, la incidencia queda
   aprobada y se descuentan los días. */
create or replace function public.resolver_incidencia(
  p_id       uuid,
  p_decision text,
  p_nota     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  i        public.incidencias;
  t        public.tipos_incidencia;
  e        public.empleados;
  v_nivel  text;
  v_yo     uuid;
  p        public.perfiles;
  v_saldo  numeric;
  v_falta  text;
begin
  select * into p from public.perfiles where id = auth.uid();
  select empleado_id into v_yo from public.perfiles where id = auth.uid();

  select * into i from public.incidencias
   where id = p_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Solicitud no encontrada'; end if;

  if i.estatus not in ('pendiente','aprobada_jefe') then
    raise exception 'Esta solicitud ya fue resuelta (%)', i.estatus;
  end if;

  v_nivel := app.siguiente_aprobador(p_id);
  if v_nivel is null then raise exception 'No hay aprobaciones pendientes'; end if;

  select * into e from public.empleados where id = i.empleado_id;
  select * into t from public.tipos_incidencia where id = i.tipo_id;

  -- ── Quien puede firmar cada nivel ──
  if v_nivel = 'jefe' then
    if not (e.jefe_id = v_yo or app.es_admin()) then
      raise exception 'Solo el jefe directo puede dar esta autorizacion';
    end if;
  else
    if not app.es_admin() then
      raise exception 'Solo Recursos Humanos puede dar esta autorizacion';
    end if;
  end if;

  -- Nadie aprueba lo propio, ni siendo RH: es control interno
  -- basico y lo primero que revisa una auditoria.
  if i.empleado_id = v_yo then
    raise exception 'No puedes autorizar tu propia solicitud';
  end if;

  insert into public.aprobaciones
    (tenant_id, incidencia_id, nivel, decision, actor_id, actor_nombre, nota)
  values
    (i.tenant_id, p_id, v_nivel, p_decision, auth.uid(), p.nombre, p_nota);

  -- ── Rechazo: termina aqui ──
  if p_decision = 'rechazada' then
    update public.incidencias
       set estatus = 'rechazada', resuelto_por = auth.uid(),
           resuelto_en = now(), resuelto_nota = p_nota
     where id = p_id;

    perform app.auditar('incidencia.rechazar', 'incidencias', p_id::text, null,
      jsonb_build_object('nivel', v_nivel, 'nota', p_nota));

    return jsonb_build_object('status','success','estatus','rechazada');
  end if;

  -- ── Aprobacion: falta otra firma? ──
  v_falta := app.siguiente_aprobador(p_id);

  if v_falta is not null then
    update public.incidencias set estatus = 'aprobada_jefe' where id = p_id;
    return jsonb_build_object('status','success','estatus','aprobada_jefe',
                              'espera', v_falta);
  end if;

  -- ── Ultima firma: se valida saldo OTRA VEZ ──
  -- Entre la solicitud y esta firma pudieron pasar dias y otra
  -- solicitud pudo consumir el saldo. Validar solo al inicio
  -- permite quedar en negativo.
  if t.descuenta_vac then
    v_saldo := public.saldo_vacaciones(i.empleado_id);
    if i.dias > v_saldo then
      raise exception 'El saldo ya no alcanza: tiene % dia(s) y la solicitud es de %',
        round(v_saldo), i.dias;
    end if;
  end if;

  update public.incidencias
     set estatus = 'aprobada', resuelto_por = auth.uid(),
         resuelto_en = now(), resuelto_nota = p_nota
   where id = p_id;

  -- Los dias se descuentan AQUI, no al solicitar: una solicitud
  -- rechazada dejaria dias fantasma que devolver a mano.
  if t.descuenta_vac then
    insert into public.vacaciones_movimientos
      (tenant_id, empleado_id, tipo, dias, fecha_efecto, incidencia_id, nota, creado_por)
    values
      (i.tenant_id, i.empleado_id, 'tomado', -i.dias, i.fecha_inicio, p_id,
       'Vacaciones del ' || i.fecha_inicio || ' al ' || i.fecha_fin, auth.uid());
  end if;

  -- El trigger inc_recalcular (migracion 02) recalcula las
  -- jornadas de esos dias solo.

  perform app.auditar('incidencia.aprobar', 'incidencias', p_id::text, null,
    jsonb_build_object('nivel', v_nivel, 'dias', i.dias));

  return jsonb_build_object('status','success','estatus','aprobada');
end;
$$;

/* Cancelar. El empleado puede cancelar lo suyo si no arrancó. */
create or replace function public.cancelar_incidencia(p_id uuid, p_motivo text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  i    public.incidencias;
  v_yo uuid;
begin
  select empleado_id into v_yo from public.perfiles where id = auth.uid();
  select * into i from public.incidencias
   where id = p_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'No encontrada'; end if;

  if not (app.es_admin() or i.empleado_id = v_yo) then
    raise exception 'Sin permiso';
  end if;
  if i.estatus = 'cancelada' then raise exception 'Ya esta cancelada'; end if;

  -- Cancelar algo ya aprobado y en curso devuelve dias que la
  -- persona pudo haber disfrutado: eso lo decide RH, no el
  -- empleado.
  if i.estatus = 'aprobada' and i.fecha_inicio <= current_date
     and not app.es_admin() then
    raise exception 'Estas vacaciones ya iniciaron. Solicita el ajuste a Recursos Humanos.';
  end if;

  update public.incidencias
     set estatus = 'cancelada', resuelto_nota = p_motivo, resuelto_en = now()
   where id = p_id;

  -- Si ya se habian descontado dias, se devuelven con un
  -- movimiento de ajuste. No se borra el 'tomado': el libro
  -- mayor no se edita, se corrige con otro movimiento.
  if i.estatus = 'aprobada' then
    insert into public.vacaciones_movimientos
      (tenant_id, empleado_id, tipo, dias, fecha_efecto, incidencia_id, nota, creado_por)
    select i.tenant_id, i.empleado_id, 'ajuste', i.dias, current_date, p_id,
           'Devolucion por cancelacion: ' || p_motivo, auth.uid()
    from public.tipos_incidencia t
    where t.id = i.tipo_id and t.descuenta_vac;

    perform public.calcular_jornada(i.empleado_id, d::date)
    from generate_series(i.fecha_inicio, i.fecha_fin, '1 day') d;
  end if;

  perform app.auditar('incidencia.cancelar', 'incidencias', p_id::text,
    jsonb_build_object('estatus', i.estatus),
    jsonb_build_object('motivo', p_motivo));

  return jsonb_build_object('status','success');
end;
$$;

/* Bandeja: lo que ve cada quien.
   'mias' para el empleado, 'poraprobar' para quien firma. */
create or replace function public.bandeja_incidencias(
  p_vista   text default 'mias',
  p_estatus text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_yo    uuid;
  v_admin boolean := app.es_admin();
  v_filas jsonb;
begin
  select empleado_id into v_yo from public.perfiles where id = auth.uid();

  select jsonb_agg(x order by x->>'creado_en' desc) into v_filas
  from (
    select jsonb_build_object(
      'id', i.id,
      'empleado', e.nombre_completo,
      'empleado_id', e.id,
      'no', e.no_empleado,
      'tipo', t.nombre, 'tipo_clave', t.clave,
      'color', t.color, 'descuenta_vac', t.descuenta_vac,
      'desde', i.fecha_inicio, 'hasta', i.fecha_fin, 'dias', i.dias,
      'comentario', i.comentario,
      'estatus', i.estatus,
      'espera', app.siguiente_aprobador(i.id),
      'creado_en', i.creado_en,
      'nota', i.resuelto_nota,
      'firmas', coalesce((
        select jsonb_agg(jsonb_build_object(
          'nivel', a.nivel, 'decision', a.decision,
          'quien', a.actor_nombre, 'cuando', a.creado_en, 'nota', a.nota)
          order by a.creado_en)
        from public.aprobaciones a where a.incidencia_id = i.id
      ), '[]'::jsonb),
      -- Puedo firmar YO esta solicitud ahora mismo
      'puedo_firmar', (
        i.estatus in ('pendiente','aprobada_jefe')
        and i.empleado_id is distinct from v_yo
        and (
          (app.siguiente_aprobador(i.id) = 'jefe' and (e.jefe_id = v_yo or v_admin))
          or (app.siguiente_aprobador(i.id) = 'rh' and v_admin)
        )
      )
    ) as x
    from public.incidencias i
    join public.empleados e on e.id = i.empleado_id
    join public.tipos_incidencia t on t.id = i.tipo_id
    where i.tenant_id = app.mi_tenant()
      and (p_estatus is null or i.estatus::text = p_estatus)
      and case p_vista
            when 'mias' then i.empleado_id = v_yo
            when 'poraprobar' then
              i.estatus in ('pendiente','aprobada_jefe')
              and i.empleado_id is distinct from v_yo
              and (v_admin or e.jefe_id = v_yo)
            else v_admin or e.jefe_id = v_yo or i.empleado_id = v_yo
          end
    limit 200
  ) s;

  return jsonb_build_object('status','success', 'filas', coalesce(v_filas,'[]'::jsonb));
end;
$$;

/* Estado de vacaciones de una persona, con el desglose del
   libro mayor. Un saldo sin su origen no se puede defender
   cuando el trabajador lo cuestiona. */
create or replace function public.estado_vacaciones(p_empleado_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_yo  uuid;
  v_emp uuid;
  e     public.empleados;
  v_anios integer;
begin
  select empleado_id into v_yo from public.perfiles where id = auth.uid();
  v_emp := coalesce(p_empleado_id, v_yo);
  if v_emp is null then
    return jsonb_build_object('status','error','message','Sin empleado ligado');
  end if;
  if v_emp <> v_yo and not app.es_admin() then
    -- El jefe tambien puede ver el saldo de su equipo: lo necesita
    -- para autorizar con criterio.
    if not exists (select 1 from public.empleados
                   where id = v_emp and jefe_id = v_yo) then
      raise exception 'Sin permiso';
    end if;
  end if;

  select * into e from public.empleados where id = v_emp;
  v_anios := coalesce(public.antiguedad_meses(e.*), 0) / 12;

  return jsonb_build_object(
    'status','success',
    'empleado', e.nombre_completo,
    'ingreso', e.fecha_ingreso,
    'anios', v_anios,
    'saldo', public.saldo_vacaciones(v_emp),
    'dias_por_ley', public.dias_vacaciones_lft(v_anios),
    'dias_extra', app.cfg_int('vac_dias_extra', e.tenant_id),
    'prima_pct', app.cfg_int('prima_vacacional_pct', e.tenant_id),
    'movimientos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'tipo', tipo, 'dias', dias, 'fecha', fecha_efecto,
        'periodo', periodo_anio, 'nota', nota)
        order by fecha_efecto desc, creado_en desc)
      from public.vacaciones_movimientos
      where empleado_id = v_emp
    ), '[]'::jsonb)
  );
end;
$$;

/* CARGA DE HISTORICO.
   Al migrar desde otro sistema, todos aparecen con el saldo
   completo desde su ingreso, como si nunca hubieran tomado
   vacaciones. Eso no es un saldo, es un pasivo inventado. Esta
   funcion registra los dias ya disfrutados. */
create or replace function public.cargar_vacaciones_tomadas(
  p_empleado_id uuid,
  p_dias        numeric,
  p_nota        text default 'Carga inicial de historico'
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare e public.empleados;
begin
  if not app.es_admin() then raise exception 'Sin permiso'; end if;
  if p_dias <= 0 then raise exception 'Los dias deben ser positivos'; end if;

  select * into e from public.empleados
   where id = p_empleado_id and tenant_id = app.mi_tenant();
  if not found then raise exception 'Empleado no encontrado'; end if;

  insert into public.vacaciones_movimientos
    (tenant_id, empleado_id, tipo, dias, fecha_efecto, nota, creado_por)
  values
    (e.tenant_id, p_empleado_id, 'tomado', -abs(p_dias), current_date,
     p_nota, auth.uid());

  perform app.auditar('vacaciones.carga_historico', 'empleados',
    p_empleado_id::text, null,
    jsonb_build_object('dias_tomados', p_dias, 'nota', p_nota));

  return jsonb_build_object('status','success',
    'saldo', public.saldo_vacaciones(p_empleado_id));
end;
$$;

grant execute on function public.dias_habiles_empleado(uuid,date,date)                to authenticated;
grant execute on function public.solicitar_incidencia(text,date,date,text,uuid)       to authenticated;
grant execute on function public.resolver_incidencia(uuid,text,text)                  to authenticated;
grant execute on function public.cancelar_incidencia(uuid,text)                       to authenticated;
grant execute on function public.bandeja_incidencias(text,text)                       to authenticated;
grant execute on function public.estado_vacaciones(uuid)                              to authenticated;
grant execute on function public.cargar_vacaciones_tomadas(uuid,numeric,text)          to authenticated;

-- El empleado necesita poder crear su propia solicitud
create policy inc_crear_propia_2 on public.incidencias
  for insert with check (
    tenant_id = app.mi_tenant()
    and empleado_id = (select empleado_id from public.perfiles where id = auth.uid())
  );