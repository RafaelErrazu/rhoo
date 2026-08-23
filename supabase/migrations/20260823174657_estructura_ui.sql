/* Historial de primas de una empresa. */
create or replace function public.primas_historial(p_razon_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not app.es_admin() then
    raise exception 'Solo administración puede consultar la prima de riesgo.';
  end if;
  if not exists (select 1 from public.razones_sociales
                  where id = p_razon_id and tenant_id = app.mi_tenant()) then
    raise exception 'Empresa no encontrada';
  end if;

  return jsonb_build_object(
    'filas', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', p.id, 'prima', p.prima, 'clase', p.clase,
               'fraccion', p.fraccion, 'vigente_de', p.vigente_de,
               'vigente_a', p.vigente_a, 'nota', p.nota,
               'vigente', p.vigente_de <= current_date
                          and (p.vigente_a is null or p.vigente_a >= current_date)
             ) order by p.vigente_de desc), '[]'::jsonb)
        from public.primas_riesgo p where p.razon_id = p_razon_id)
  );
end;
$$;

/* La clave de la empresa se genera sola si no se captura: pedirle a RH que
   invente una clave corta es pedirle que teclee RS1, RS-1 y RAZON1 el mismo
   dia. */
create or replace function public.razon_guardar(
  p_grupo_id uuid, p_clave text, p_razon_social text,
  p_nombre_comercial text default null, p_rfc text default null,
  p_registro_patronal text default null, p_regimen_fiscal text default null,
  p_codigo_postal text default null, p_domicilio text default null,
  p_representante_legal text default null, p_activo boolean default true,
  p_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_t uuid := app.mi_tenant();
  v_id uuid;
  v_clave text;
  v_rfc text;
begin
  if not app.es_admin() then
    raise exception 'Solo administración puede administrar empresas.';
  end if;
  if not exists (select 1 from public.grupos_empresariales
                  where id = p_grupo_id and tenant_id = v_t) then
    raise exception 'Grupo no valido';
  end if;

  v_rfc := nullif(upper(trim(coalesce(p_rfc,''))),'');

  -- El RFC se valida al capturarlo, no en la tabla: los datos migrados traen
  -- RFC mal capturados de origen y bloquearlos impediria corregirlos.
  if v_rfc is not null and length(v_rfc) not between 12 and 13 then
    raise exception 'El RFC debe tener 12 caracteres (moral) o 13 (fisica). Recibi % de longitud %.', v_rfc, length(v_rfc);
  end if;

  if v_rfc is not null and exists (
    select 1 from public.razones_sociales
     where tenant_id = v_t and upper(trim(rfc)) = v_rfc
       and (p_id is null or id <> p_id))
  then
    raise exception 'Ya existe otra empresa con el RFC %.', v_rfc;
  end if;

  if p_id is null then
    v_clave := nullif(upper(trim(coalesce(p_clave,''))),'');
    if v_clave is null then
      select 'RS' || lpad((coalesce(max(
               nullif(regexp_replace(clave, '\D', '', 'g'), '')::integer), 0) + 1)::text,
             2, '0')
        into v_clave
        from public.razones_sociales where tenant_id = v_t;
    end if;

    insert into public.razones_sociales (
      tenant_id, grupo_id, clave, razon_social, nombre_comercial, rfc,
      registro_patronal, regimen_fiscal, codigo_postal, domicilio,
      representante_legal, activo)
    values (
      v_t, p_grupo_id, v_clave, trim(p_razon_social),
      nullif(trim(coalesce(p_nombre_comercial,'')),''), v_rfc,
      nullif(trim(coalesce(p_registro_patronal,'')),''),
      nullif(trim(coalesce(p_regimen_fiscal,'')),''),
      nullif(trim(coalesce(p_codigo_postal,'')),''),
      nullif(trim(coalesce(p_domicilio,'')),''),
      nullif(trim(coalesce(p_representante_legal,'')),''),
      coalesce(p_activo,true))
    returning id into v_id;
  else
    update public.razones_sociales
       set grupo_id = p_grupo_id,
           razon_social = trim(p_razon_social),
           nombre_comercial = nullif(trim(coalesce(p_nombre_comercial,'')),''),
           rfc = v_rfc,
           registro_patronal = nullif(trim(coalesce(p_registro_patronal,'')),''),
           regimen_fiscal = nullif(trim(coalesce(p_regimen_fiscal,'')),''),
           codigo_postal = nullif(trim(coalesce(p_codigo_postal,'')),''),
           domicilio = nullif(trim(coalesce(p_domicilio,'')),''),
           representante_legal = nullif(trim(coalesce(p_representante_legal,'')),''),
           activo = coalesce(p_activo,true)
     where id = p_id and tenant_id = v_t
    returning id into v_id;
    if v_id is null then raise exception 'Empresa no encontrada'; end if;
  end if;

  perform app.auditar('razon_social','razones_sociales', v_id::text, null,
    jsonb_build_object('razon_social', p_razon_social, 'rfc', v_rfc));
  return jsonb_build_object('status','success','id',v_id);
end;
$$;

revoke all on function public.primas_historial(uuid) from public;
grant execute on function public.primas_historial(uuid) to authenticated;