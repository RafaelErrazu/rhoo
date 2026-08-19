-- Fix: la variable `x` declarada en la funcion chocaba con el
-- alias `x` del jsonb_array_elements en el insert de items
-- ("column reference x is ambiguous"). Se elimina la variable,
-- que no se usaba, y el alias se renombra a `it_x` para que no
-- vuelva a colisionar con nada.
create or replace function public.nom035_guardar(
  p_token      text,
  p_guia1      jsonb default '{}'::jsonb,
  p_items      jsonb default '[]'::jsonb,
  p_clientes   boolean default null,
  p_jefe       boolean default null,
  p_datos      jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  i     public.nom035_invitaciones;
  c     public.nom035_campanas;
  e     public.empleados;
  v_g1  jsonb;
  v_frp jsonb := '{}'::jsonb;
  v_id  uuid;
begin
  select * into i from public.nom035_invitaciones where token = p_token;
  if not found then
    return jsonb_build_object('status','error','message','Enlace no válido');
  end if;
  if i.usado_en is not null then
    return jsonb_build_object('status','error','message','Ya registramos tus respuestas');
  end if;

  select * into c from public.nom035_campanas where id = i.campana_id;
  if c.estado <> 'abierta' then
    return jsonb_build_object('status','error','message','El periodo ya cerró');
  end if;

  select * into e from public.empleados where id = i.empleado_id;

  v_g1 := public.nom035_calificar_guia1(coalesce(p_guia1,'{}'::jsonb));

  if i.aplica_frp and jsonb_array_length(coalesce(p_items,'[]'::jsonb)) > 0 then
    v_frp := public.nom035_calificar(i.guia, p_items, p_clientes, p_jefe);
  end if;

  insert into public.nom035_respuestas (
    tenant_id, campana_id, empleado_id, centro_id, guia, aplica_frp,
    atiende_clientes, es_jefe,
    items_aplicables, items_totales, rango_ajustado,
    puntaje_total, nivel_total,
    gi_requiere_valoracion, gi_detalle,
    por_categoria, por_dominio, por_dimension
  ) values (
    i.tenant_id, i.campana_id, i.empleado_id, e.centro_id, i.guia, i.aplica_frp,
    p_clientes, p_jefe,
    (v_frp->>'items_aplicables')::integer,
    (v_frp->>'items_respondidos')::integer,
    coalesce((v_frp->>'rango_ajustado')::boolean, false),
    (v_frp->>'puntaje_total')::integer,
    v_frp->>'nivel_total',
    coalesce((v_g1->>'requiere_valoracion')::boolean, false),
    v_g1,
    v_frp->'por_categoria', v_frp->'por_dominio', v_frp->'por_dimension'
  ) returning id into v_id;

  if jsonb_array_length(coalesce(p_items,'[]'::jsonb)) > 0 then
    insert into public.nom035_respuestas_item (respuesta_id, item_id, numero, valor, puntaje)
    select v_id, it.id, (it_x->>'numero')::integer, (it_x->>'valor')::smallint,
           app.nom035_puntaje((it_x->>'valor')::smallint, it.direccion)
    from jsonb_array_elements(p_items) as it_x
    join public.nom035_items it
      on it.guia = i.guia and it.numero = (it_x->>'numero')::integer;
  end if;

  if p_datos is not null and p_datos <> '{}'::jsonb then
    insert into public.nom035_fichas
      (tenant_id, campana_id, respuesta_id, empleado_id, centro_id, datos)
    values (i.tenant_id, i.campana_id, v_id, i.empleado_id, e.centro_id, p_datos);
  end if;

  update public.nom035_invitaciones set usado_en = now() where id = i.id;

  return jsonb_build_object(
    'status','success',
    'nivel', v_frp->>'nivel_total',
    'requiere_valoracion', coalesce((v_g1->>'requiere_valoracion')::boolean, false)
  );
end;
$$;