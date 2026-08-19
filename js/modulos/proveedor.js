// ═══════════════════════════════════════════════════════════
//  RHoo! · Módulo proveedor
//  Solo visible para el superadmin. Muestra USO, no contenido:
//  poder entrar a los datos de un cliente es una cosa, tenerlos
//  en tu tablero por defecto es otra.
// ═══════════════════════════════════════════════════════════

let _pvTab = 'clientes';

async function pintarClientes(){
  const cont = document.getElementById('pv-cuerpo');
  cont.innerHTML = '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando...</p>';

  const [lista, res] = await Promise.all([
    sb.rpc('tenants_lista'),
    sb.rpc('proveedor_resumen')
  ]);

  const ts = (lista.data || []).filter(t => !t.es_proveedor);
  const r = res.data || {};

  const dias = iso => iso
    ? Math.floor((Date.now() - new Date(iso)) / 86400000)
    : null;

  cont.innerHTML =
    '<div class="cu-kpis">'
    + '<div class="cu-kpi"><b class="num">'+(r.clientes||0)+'</b>'
    + '<span>clientes</span></div>'
    + '<div class="cu-kpi"><b class="num">'+(r.empleados||0)+'</b>'
    + '<span>empleados totales</span></div>'
    + '<div class="cu-kpi"><b class="num">'+(r.respuestas_nom035||0)+'</b>'
    + '<span>evaluaciones</span></div>'
    + '<div class="cu-kpi'+(r.inactivos_30d?' alerta':'')+'">'
    + '<b class="num">'+(r.inactivos_30d||0)+'</b>'
    + '<span>sin actividad 30 días</span></div>'
    + '</div>'

    + (r.inactivos_30d
        ? '<p class="aviso" style="background:#FEF3E2;color:#92400E">'
          + '<i class="fas fa-user-clock" style="color:#B45309"></i>'
          + r.inactivos_30d+' cliente(s) sin actividad en 30 días. Un cliente que '
          + 'se dio de alta y no volvió es una cancelación que todavía se puede '
          + 'evitar.</p>'
        : '')

    + '<div class="cu-head"><div><h3>Clientes</h3>'
    + '<p>Los catálogos base (turnos, incidencias, documentos y festivos) se '
    + 'siembran solos al crear el cliente.</p></div>'
    + '<button class="btn-pri" onclick="nuevoCliente()">'
    + '<i class="fas fa-plus"></i> Nuevo cliente</button></div>'

    + (ts.length
        ? '<div class="pv-lista">'
          + ts.map(t => {
              const d = dias(t.ultima_actividad);
              const lleno = t.limite && t.empleados >= t.limite;
              return '<div class="pv-cli'+(t.suspendido?' susp':'')+'" '
                + 'onclick="verCliente(\''+t.id+'\')">'
                + '<div class="pv-cli-t">'
                + '<div><b>'+t.nombre+'</b>'
                + '<span>'+t.slug+' · '+(t.plan_nombre||t.plan)
                + (t.contacto ? ' · '+t.contacto : '')+'</span></div>'
                + (t.suspendido
                    ? '<span class="cu-est" style="background:#FEF2F2;color:#B91C1C">'
                      + 'Suspendido</span>'
                    : '<span class="cu-est cu-abierta">Activo</span>')
                + '</div>'
                + '<div class="pv-cli-m">'
                + '<span'+(lleno?' class="lleno"':'')+'>'
                + '<b class="num">'+t.empleados+'</b>'
                + (t.limite ? '/'+t.limite : '')+' empleados</span>'
                + '<span><b class="num">'+t.centros+'</b> centros</span>'
                + '<span><b class="num">'+t.usuarios+'</b> usuarios</span>'
                + '<span><b class="num">'+t.respuestas+'</b> evaluaciones</span>'
                + (d !== null
                    ? '<span'+(d > 30 ? ' class="frio"':'')+'>'
                      + (d === 0 ? 'activo hoy' : 'hace '+d+' d')+'</span>'
                    : '<span class="frio">sin actividad</span>')
                + '</div>'
                + (lleno
                    ? '<p class="pv-lleno">Alcanzó el límite de su plan. No puede '
                      + 'dar de alta más empleados.</p>' : '')
                + '</div>';
            }).join('')
          + '</div>'
        : '<div class="vacio"><i class="fas fa-building"></i>'
          + '<h3>Sin clientes</h3><p>Da de alta el primero.</p></div>');
}

async function nuevoCliente(){
  const { data: planes } = await sb.from('planes')
    .select('clave,nombre,limite_empleados').order('orden');

  const r = await modal({
    titulo:'Nuevo cliente',
    subtitulo:'Se crean el tenant, su primer centro de trabajo y todos los '
      + 'catálogos base. El cliente puede operar desde el primer minuto.',
    ok:'Crear cliente',
    campos:[
      { k:'nombre', label:'Razón social o nombre comercial', t:'texto', req:true },
      { k:'rfc', label:'RFC', t:'texto', max:13, ancho:'mitad' },
      { k:'plan', label:'Plan', t:'select', req:true, ancho:'mitad',
        opciones:(planes||[]).map(p => [p.clave,
          p.nombre + (p.limite_empleados ? ' · hasta '+p.limite_empleados : ' · sin límite')]),
        valor:'trial' },
      { k:'centro_nombre', label:'Primer centro de trabajo', t:'texto', req:true,
        valor:'Oficina Matriz', ancho:'mitad',
        nota:'La NOM-035 evalúa por centro, no por empresa.' },
      { k:'centro_clave', label:'Clave del centro', t:'texto', req:true,
        valor:'MATRIZ', max:12, ancho:'mitad' },
      { k:'contacto_nombre', label:'Contacto', t:'texto', ancho:'mitad' },
      { k:'contacto_email', label:'Correo del contacto', t:'mail', ancho:'mitad' },
      { k:'contacto_tel', label:'Teléfono', t:'tel', ancho:'mitad' },
      { k:'notas', label:'Notas internas', t:'area',
        nota:'Solo tú las ves. El cliente no.' }
    ]
  });
  if(!r) return;

  const { data, error } = await sb.rpc('crear_tenant', { p_datos: {
    nombre: r.nombre, rfc: r.rfc, plan: r.plan,
    contacto_nombre: r.contacto_nombre, contacto_email: r.contacto_email,
    contacto_tel: r.contacto_tel, notas: r.notas,
    centros: [{ clave: r.centro_clave, nombre: r.centro_nombre,
                razon_social: r.nombre }]
  }});

  if(error){ toast('error', error.message); return; }

  const s = data.semilla || {};
  await modal({
    titulo:'Cliente creado',
    subtitulo:'Identificador: '+data.slug+'. Se sembraron '+s.turnos+' turnos, '
      + s.incidencias+' tipos de incidencia, '+s.documentos+' tipos de documento '
      + 'y '+s.festivos+' días festivos.\n\n'
      + 'Falta su usuario administrador: créalo en Supabase → Authentication → '
      + 'Users (con Auto Confirm activado) y después asígnalo aquí.',
    ok:'Asignar administrador', cancelar:'Después'
  }).then(ok => { if(ok) asignarAdmin(data.id, r.nombre); });

  pintarClientes();
}

async function asignarAdmin(tenantId, nombreCliente){
  const r = await modal({
    titulo:'Asignar administrador',
    subtitulo:'El usuario debe existir ya en Supabase → Authentication → Users. '
      + 'Aquí se le da su perfil y su rol dentro de '+nombreCliente+'.',
    ok:'Asignar',
    campos:[
      { k:'email', label:'Correo del usuario', t:'mail', req:true,
        nota:'El mismo con el que lo creaste en Authentication.' },
      { k:'nombre', label:'Nombre para mostrar', t:'texto' }
    ]
  });
  if(!r) return;

  const { error } = await sb.rpc('asignar_admin', {
    p_email: r.email, p_tenant_id: tenantId, p_nombre: r.nombre || null });

  if(error){ toast('error', error.message); return; }
  toast('ok','Administrador asignado. Ya puede entrar.');
}

async function verCliente(id){
  const { data } = await sb.rpc('tenants_lista');
  const t = (data||[]).find(x => x.id === id);
  if(!t) return;

  const { data: planes } = await sb.from('planes')
    .select('clave,nombre,limite_empleados').order('orden');

  panel({
    titulo: t.nombre,
    subtitulo: t.slug + ' · ' + (t.plan_nombre || t.plan)
      + (t.suspendido ? ' · SUSPENDIDO' : ''),
    html:
      (t.suspendido
        ? '<div class="aviso" style="background:#FEF2F2;color:#B91C1C;margin-bottom:16px">'
          + '<i class="fas fa-ban" style="color:#DC2626"></i>'
          + '<div>Suspendido'+(t.motivo ? ': '+t.motivo : '')+'. Sus usuarios no '
          + 'pueden entrar, pero los datos se conservan intactos.</div></div>'
        : '')
      + '<section class="ex-sec"><h4>Uso</h4><div class="ex-grid">'
      + '<div class="ex-dato"><span>Empleados activos</span><b>'+t.empleados
      + (t.limite ? ' de '+t.limite : '')+'</b></div>'
      + '<div class="ex-dato"><span>Centros</span><b>'+t.centros+'</b></div>'
      + '<div class="ex-dato"><span>Usuarios</span><b>'+t.usuarios+'</b></div>'
      + '<div class="ex-dato"><span>Campañas NOM-035</span><b>'+t.campanas+'</b></div>'
      + '<div class="ex-dato"><span>Evaluaciones</span><b>'+t.respuestas+'</b></div>'
      + '<div class="ex-dato"><span>Documentos</span><b>'+t.documentos+'</b></div>'
      + '</div></section>'

      + '<section class="ex-sec"><h4>Contacto</h4><div class="ex-grid">'
      + '<div class="ex-dato"><span>Nombre</span><b>'+(t.contacto||'—')+'</b></div>'
      + '<div class="ex-dato"><span>Correo</span><b>'+(t.email||'—')+'</b></div>'
      + '</div></section>'

      + '<section class="ex-sec"><h4>Alta</h4>'
      + '<p style="font-size:.82rem;color:var(--txt-2)">Cliente desde '
      + new Date(t.creado).toLocaleDateString('es-MX')+'. '
      + (t.ultima_actividad
          ? 'Última actividad el '
            + new Date(t.ultima_actividad).toLocaleDateString('es-MX')+'.'
          : 'Sin actividad registrada.')+'</p></section>',
    acciones:
      '<button class="btn-sec-claro" onclick="editarCliente(\''+id+'\')">'
      + 'Editar</button>'
      + '<button class="btn-sec-claro" onclick="resembrar(\''+id+'\')" '
      + 'title="Vuelve a aplicar los catálogos base sin duplicar nada">'
      + 'Re-sembrar</button>'
      + (t.suspendido
          ? '<button class="btn-pri" onclick="suspender(\''+id+'\',false)">'
            + 'Reactivar</button>'
          : '<button class="btn-peligro" onclick="suspender(\''+id+'\',true)">'
            + 'Suspender</button>')
  });
}

async function editarCliente(id){
  const { data } = await sb.rpc('tenants_lista');
  const t = (data||[]).find(x => x.id === id);
  const { data: planes } = await sb.from('planes')
    .select('clave,nombre,limite_empleados').order('orden');

  const r = await modal({
    titulo:'Editar cliente',
    subtitulo: t.nombre,
    campos:[
      { k:'nombre', label:'Nombre', t:'texto', req:true, valor:t.nombre },
      { k:'plan', label:'Plan', t:'select', req:true, ancho:'mitad',
        opciones:(planes||[]).map(p => [p.clave, p.nombre]), valor:t.plan },
      { k:'limite_empleados', label:'Límite de empleados', t:'num', ancho:'mitad',
        valor:t.limite || '',
        nota:'Vacío usa el límite del plan. Aquí puedes hacer una excepción.' },
      { k:'contacto_nombre', label:'Contacto', t:'texto', valor:t.contacto||'',
        ancho:'mitad' },
      { k:'contacto_email', label:'Correo', t:'mail', valor:t.email||'',
        ancho:'mitad' },
      { k:'notas', label:'Notas internas', t:'area' }
    ]
  });
  if(!r) return;

  const { error } = await sb.rpc('tenant_actualizar', { p_id:id, p_datos:r });
  if(error){ toast('error', error.message); return; }
  toast('ok','Cliente actualizado');
  cerrarPanel();
  pintarClientes();
}

async function suspender(id, susp){
  const r = await modal({
    titulo: susp ? 'Suspender cliente' : 'Reactivar cliente',
    subtitulo: susp
      ? 'Sus usuarios no podrán entrar. Los datos se conservan completos y se '
        + 'puede reactivar en cualquier momento.'
      : 'Sus usuarios podrán entrar de nuevo.',
    ok: susp ? 'Suspender' : 'Reactivar',
    peligro: susp,
    campos: susp
      ? [{ k:'motivo', label:'Motivo', t:'area', req:true,
           nota:'Queda en la bitácora. Ej: impago, fin de contrato.' }]
      : []
  });
  if(!r) return;

  const { error } = await sb.rpc('tenant_suspender', {
    p_id:id, p_susp:susp, p_motivo:r.motivo || null });
  if(error){ toast('error', error.message); return; }
  toast('ok', susp ? 'Cliente suspendido' : 'Cliente reactivado');
  cerrarPanel();
  pintarClientes();
}

/* Re-sembrar: para aplicar catálogos nuevos a clientes viejos.
   Es idempotente, así que no duplica nada. */
async function resembrar(id){
  const { data, error } = await sb.rpc('sembrar_catalogos', { p_tenant_id: id });
  if(error){ toast('error', error.message); return; }
  toast('ok','Catálogos verificados: '+data.turnos+' turnos, '+data.incidencias
    + ' incidencias, '+data.documentos+' documentos, '+data.festivos+' festivos');
}

/* Planes */
async function pintarPlanes(){
  const cont = document.getElementById('pv-cuerpo');
  const { data } = await sb.from('planes')
    .select('*').order('orden');

  cont.innerHTML =
    '<div class="cu-head"><div><h3>Planes</h3>'
    + '<p>Los límites se aplican en la base de datos, no en la interfaz: un '
    + 'cliente no puede pasarse aunque manipule el navegador.</p></div></div>'
    + '<div class="pv-lista">'
    + (data||[]).map(p =>
        '<div class="pv-cli"><div class="pv-cli-t">'
        + '<div><b>'+p.nombre+'</b><span>'+p.clave+'</span></div></div>'
        + '<div class="pv-cli-m">'
        + '<span><b class="num">'+(p.limite_empleados||'∞')+'</b> empleados</span>'
        + '<span><b class="num">'+(p.limite_centros||'∞')+'</b> centros</span>'
        + Object.entries(p.features||{}).filter(([,v]) => v).map(([k]) =>
            '<span class="pv-feat">'+k+'</span>').join('')
        + '</div></div>').join('')
    + '</div>';
}

function pvIr(t){
  _pvTab = t;
  document.querySelectorAll('.pv-tab').forEach(b =>
    b.classList.toggle('on', b.dataset.t === t));
  if(t === 'clientes') pintarClientes();
  if(t === 'planes')   pintarPlanes();
}

async function moduloProveedor(){
  document.getElementById('contenido').innerHTML =
    '<div class="asis-barra"><div class="asis-tabs">'
    + '<button class="asis-tab pv-tab on" data-t="clientes" onclick="pvIr(\'clientes\')">'
    + 'Clientes</button>'
    + '<button class="asis-tab pv-tab" data-t="planes" onclick="pvIr(\'planes\')">'
    + 'Planes</button>'
    + '</div></div><div id="pv-cuerpo"></div>';
  pvIr(_pvTab);
}