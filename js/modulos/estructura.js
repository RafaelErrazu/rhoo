// ═══════════════════════════════════════════════════════════
// RHoo! · Estructura empresarial
// Grupos comerciales, razones sociales y prima de riesgo.
// La jerarquia siempre existe en la base; aqui se oculta el
// nivel de grupo cuando solo hay uno, porque navegar un nivel
// con un solo elemento es burocracia visual.
// ═══════════════════════════════════════════════════════════

let _esData = null;

const ES_REGIMENES = [
  ['601','601 · General de Ley Personas Morales'],
  ['603','603 · Personas Morales con Fines no Lucrativos'],
  ['605','605 · Sueldos y Salarios'],
  ['606','606 · Arrendamiento'],
  ['612','612 · Actividades Empresariales y Profesionales'],
  ['620','620 · Sociedades Cooperativas de Producción'],
  ['622','622 · Actividades Agrícolas, Ganaderas, Silvícolas y Pesqueras'],
  ['626','626 · Régimen Simplificado de Confianza']
];

function esE(s){
  return (s==null?'':String(s))
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/"/g,'&quot;');
}

function esPct(n){
  if(n == null) return '—';
  return (Number(n) * 100).toFixed(4).replace(/0+$/,'').replace(/\.$/,'') + '%';
}

async function moduloEstructura(){
  document.getElementById('contenido').innerHTML =
    '<p class="cargando">Cargando estructura...</p>';
  if(await esCargar()) esPintar();
}

async function esCargar(){
  const { data, error } = await sb.rpc('estructura_empresarial');
  if(error){ toast('error', error.message); return false; }
  _esData = data;
  return true;
}

function esPintar(){
  const gs = _esData.grupos || [];
  const admin = _esData.es_admin;
  const multiGrupo = gs.length > 1;

  const empresas = gs.flatMap(g => (g.empresas||[]).map(e => ({...e, _g:g})));
  const sinDatos = empresas.filter(e => (e.faltantes||[]).length).length;

  document.getElementById('contenido').innerHTML =
    '<div class="es-top">'
    + '<div>'
    + '<h3>'+empresas.length+' empresa'+(empresas.length===1?'':'s')
    + (multiGrupo ? ' en '+gs.length+' grupos' : '')+'</h3>'
    + '<p>Cada empresa timbra con su propio RFC. Los centros y la nómina '
    + 'cuelgan de ella.</p>'
    + '</div>'
    + (admin
      ? '<div class="es-top-btns">'
        + '<button class="btn-sec-claro" onclick="esGrupoNuevo()">'
        + '<i class="fas fa-layer-group"></i> Nuevo grupo</button>'
        + '<button class="btn-pri" onclick="esRazonNueva()">'
        + '<i class="fas fa-plus"></i> Nueva empresa</button>'
        + '</div>'
      : '')
    + '</div>'

    // Lo que impide operar, antes que cualquier otra cosa: descubrir que falta
    // el registro patronal el dia del timbrado es tarde.
    + (sinDatos
      ? '<div class="es-alerta">'
        + '<i class="fas fa-triangle-exclamation"></i>'
        + '<div><b>'+sinDatos+' empresa(s) con datos fiscales incompletos</b>'
        + '<p>Sin RFC, registro patronal y régimen no se puede timbrar la nómina '
        + 'ni presentar movimientos al IMSS.</p></div>'
        + '</div>'
      : '')

    + (empresas.length
      ? gs.map(g => esGrupo(g, multiGrupo, admin)).join('')
      : '<div class="vacio"><i class="fas fa-building"></i>'
        + '<h3>Sin empresas</h3>'
        + '<p>Registra la razón social con la que se contrata al personal. '
        + 'Si el cliente tiene varias, cada una lleva su propio RFC y su '
        + 'propia nómina.</p></div>');
}

function esGrupo(g, multiGrupo, admin){
  const es = g.empresas || [];

  return '<section class="es-grupo">'
    + (multiGrupo
      ? '<header class="es-grupo-head">'
        + '<div><b>'+esE(g.nombre)+'</b>'
        + '<span>'+esE(g.clave)+' · reglas '
        + (g.reglas_desde === 'grupo' ? 'del grupo' : 'por empresa')
        + ' · '+es.length+' empresa'+(es.length===1?'':'s')+'</span></div>'
        + (admin
          ? '<button class="es-link" onclick="esGrupoEditar(\''+g.id+'\')">'
            + 'Editar</button>'
          : '')
        + '</header>'
      : '')

    + (es.length
      ? '<div class="es-lista">'
        + es.map(e => esEmpresa(e, admin)).join('')
        + '</div>'
      : '<p class="es-vacio-grupo">Este grupo no tiene empresas todavía.</p>')
    + '</section>';
}

function esEmpresa(e, admin){
  const falta = e.faltantes || [];

  return '<article class="es-emp'+(falta.length?' incompleta':'')
    + (e.activo?'':' off')+'">'
    + '<div class="es-emp-head">'
    + '<div class="es-emp-id">'
    + '<b>'+esE(e.razon_social)+'</b>'
    + '<span>'+esE(e.clave)
    + (e.nombre_comercial ? ' · '+esE(e.nombre_comercial) : '')
    + (e.activo ? '' : ' · inactiva')+'</span>'
    + '</div>'
    + (admin
      ? '<div class="es-emp-btns">'
        + '<button class="es-link" onclick="esRazonEditar(\''+e.id+'\')">'
        + 'Editar</button>'
        + '<button class="es-link" onclick="esPrima(\''+e.id+'\')">'
        + 'Prima</button>'
        + '</div>'
      : '')
    + '</div>'

    + '<div class="es-emp-datos">'
    + esDato('RFC', e.rfc)
    + esDato('Registro patronal', e.registro_patronal)
    + esDato('Régimen', e.regimen_fiscal)
    + esDato('C.P.', e.codigo_postal)
    + esDato('Prima de riesgo', e.prima != null ? esPct(e.prima) : null)
    + '</div>'

    + '<div class="es-emp-pie">'
    + '<span><b>'+e.centros+'</b> centro'+(e.centros===1?'':'s')+'</span>'
    + '<span><b>'+e.empleados+'</b> empleado'+(e.empleados===1?'':'s')+'</span>'
    + (falta.length
      ? '<span class="es-falta"><i class="fas fa-circle-exclamation"></i> Falta '
        + falta.map(esE).join(', ')+'</span>'
      : '<span class="es-ok"><i class="fas fa-circle-check"></i> Lista para timbrar</span>')
    + '</div>'
    + '</article>';
}

function esDato(et, v){
  return '<div class="es-dato"><span>'+et+'</span>'
    + '<b'+(v?'':' class="es-nulo"')+'>'+(v ? esE(v) : 'Pendiente')+'</b></div>';
}

/* ── Grupos ─────────────────────────────────────────────── */

async function esGrupoNuevo(){
  const r = await modal({
    titulo:'Nuevo grupo',
    subtitulo:'Un grupo agrupa empresas para consolidar reportes y compartir '
      + 'reglas de operación.',
    ok:'Crear',
    campos:[
      { k:'clave', label:'Clave', t:'texto', req:true, ancho:'mitad', max:12,
        nota:'Corta. Ej. NORTE, GRAL.' },
      { k:'nombre', label:'Nombre del grupo', t:'texto', req:true, ancho:'mitad' },
      { k:'reglas', label:'¿Quién define las reglas?', t:'opc', req:true,
        valor:'grupo',
        opciones:[
          ['grupo','El grupo, iguales para todas sus empresas'],
          ['empresa','Cada empresa define las suyas']
        ],
        nota:'Aplica a tolerancias, retardos y políticas de vacaciones. '
           + 'Se puede cambiar después.' }
    ]
  });
  if(!r) return;

  const { error } = await sb.rpc('grupo_emp_guardar', {
    p_clave: r.clave, p_nombre: r.nombre,
    p_reglas_desde: r.reglas, p_activo: true, p_id: null
  });
  if(error){ toast('error', error.message); return; }

  toast('ok','Grupo creado');
  if(await esCargar()) esPintar();
}

async function esGrupoEditar(id){
  const g = (_esData.grupos||[]).find(x => x.id === id);
  if(!g) return;

  const r = await modal({
    titulo:'Editar '+g.clave,
    subtitulo:'La clave no se puede cambiar: se usa en reportes ya emitidos.',
    ok:'Guardar',
    campos:[
      { k:'nombre', label:'Nombre del grupo', t:'texto', req:true, valor:g.nombre },
      { k:'reglas', label:'¿Quién define las reglas?', t:'opc', req:true,
        valor:g.reglas_desde,
        opciones:[
          ['grupo','El grupo, iguales para todas sus empresas'],
          ['empresa','Cada empresa define las suyas']
        ] },
      { k:'activo', label:'Activo', t:'select', req:true, ancho:'mitad',
        valor:g.activo?'si':'no', opciones:[['si','Sí'],['no','No']] }
    ]
  });
  if(!r) return;

  const { error } = await sb.rpc('grupo_emp_guardar', {
    p_clave: g.clave, p_nombre: r.nombre, p_reglas_desde: r.reglas,
    p_activo: r.activo === 'si', p_id: g.id
  });
  if(error){ toast('error', error.message); return; }

  toast('ok','Grupo actualizado');
  if(await esCargar()) esPintar();
}

/* ── Empresas ───────────────────────────────────────────── */

function esCamposRazon(e, grupos){
  return [
    { k:'grupo', label:'Grupo', t:'select', req:true,
      valor: e ? e._g.id : (grupos.length === 1 ? grupos[0].id : ''),
      opciones: grupos.map(g => [g.id, g.clave+' · '+g.nombre]) },
    { k:'razon_social', label:'Razón social', t:'texto', req:true,
      valor: e ? e.razon_social : '',
      nota:'Tal como aparece en el acta constitutiva, con el tipo de sociedad.' },
    { k:'nombre_comercial', label:'Nombre comercial', t:'texto', ancho:'mitad',
      valor: e ? (e.nombre_comercial||'') : '',
      nota:'Opcional. Con el que la conoce la gente.' },
    { k:'rfc', label:'RFC', t:'texto', ancho:'mitad', max:13,
      valor: e ? (e.rfc||'') : '',
      nota:'12 caracteres para persona moral, 13 para física.' },
    { k:'registro_patronal', label:'Registro patronal IMSS', t:'texto',
      ancho:'mitad', max:11, valor: e ? (e.registro_patronal||'') : '',
      nota:'11 caracteres. Sin esto no se pueden presentar movimientos.' },
    { k:'regimen_fiscal', label:'Régimen fiscal', t:'select', ancho:'mitad',
      valor: e ? (e.regimen_fiscal||'') : '601',
      opciones: ES_REGIMENES },
    { k:'codigo_postal', label:'C.P. del domicilio fiscal', t:'texto',
      ancho:'mitad', max:5, valor: e ? (e.codigo_postal||'') : '',
      nota:'Va en el CFDI como lugar de expedición.' },
    { k:'representante_legal', label:'Representante legal', t:'texto',
      ancho:'mitad', valor: e ? (e.representante_legal||'') : '',
      nota:'Quien firma los contratos.' },
    { k:'domicilio', label:'Domicilio fiscal', t:'area',
      valor: e ? (e.domicilio||'') : '' }
  ];
}

async function esRazonNueva(){
  const grupos = (_esData.grupos||[]).filter(g => g.activo);
  if(!grupos.length){
    toast('error','Primero crea un grupo');
    return esGrupoNuevo();
  }

  const r = await modal({
    titulo:'Nueva empresa',
    subtitulo:'Los datos fiscales se pueden completar después, pero sin ellos '
      + 'no se puede timbrar.',
    ok:'Crear empresa',
    campos: esCamposRazon(null, grupos)
  });
  if(!r) return;

  const { error } = await sb.rpc('razon_guardar', {
    p_grupo_id: r.grupo,
    p_clave: null,   // se genera abajo si no se capturó
    p_razon_social: r.razon_social,
    p_nombre_comercial: r.nombre_comercial || null,
    p_rfc: r.rfc || null,
    p_registro_patronal: r.registro_patronal || null,
    p_regimen_fiscal: r.regimen_fiscal || null,
    p_codigo_postal: r.codigo_postal || null,
    p_domicilio: r.domicilio || null,
    p_representante_legal: r.representante_legal || null,
    p_activo: true, p_id: null
  });
  if(error){ toast('error', error.message); return; }

  toast('ok','Empresa creada');
  if(await esCargar()) esPintar();
}

async function esRazonEditar(id){
  const e = (_esData.grupos||[])
    .flatMap(g => (g.empresas||[]).map(x => ({...x, _g:g})))
    .find(x => x.id === id);
  if(!e) return;

  const grupos = (_esData.grupos||[]).filter(g => g.activo);

  const r = await modal({
    titulo:'Editar '+e.clave,
    subtitulo: e.empleados
      ? e.empleados+' empleado(s) contratados por esta empresa. Cambiar el RFC '
        + 'afecta los CFDI que se emitan de aquí en adelante.'
      : 'La clave no se puede cambiar.',
    ok:'Guardar',
    campos: esCamposRazon(e, grupos).concat([
      { k:'activo', label:'Activa', t:'select', req:true, ancho:'mitad',
        valor: e.activo?'si':'no', opciones:[['si','Sí'],['no','No']],
        nota:'Inactiva no permite crear periodos de nómina.' }
    ])
  });
  if(!r) return;

  const { error } = await sb.rpc('razon_guardar', {
    p_grupo_id: r.grupo,
    p_clave: e.clave,
    p_razon_social: r.razon_social,
    p_nombre_comercial: r.nombre_comercial || null,
    p_rfc: r.rfc || null,
    p_registro_patronal: r.registro_patronal || null,
    p_regimen_fiscal: r.regimen_fiscal || null,
    p_codigo_postal: r.codigo_postal || null,
    p_domicilio: r.domicilio || null,
    p_representante_legal: r.representante_legal || null,
    p_activo: r.activo === 'si', p_id: e.id
  });
  if(error){ toast('error', error.message); return; }

  toast('ok','Empresa actualizada');
  if(await esCargar()) esPintar();
}

/* ── Prima de riesgo ────────────────────────────────────── */

async function esPrima(razonId){
  const e = (_esData.grupos||[])
    .flatMap(g => g.empresas||[]).find(x => x.id === razonId);
  if(!e) return;

  const { data, error } = await sb.rpc('primas_historial', { p_razon_id: razonId });
  if(error){ toast('error', error.message); return; }

  const h = data.filas || [];

  panel({
    titulo:'Prima de riesgo · '+e.clave,
    subtitulo: esE(e.razon_social),
    html:
      '<p class="es-expl">La prima se determina cada febrero ante el IMSS según '
      + 'la siniestralidad del año anterior. Se guarda con vigencia para que '
      + 'recalcular un periodo pasado use la prima que estaba vigente entonces.</p>'
      + (h.length
        ? '<div class="es-primas">'
          + h.map(p => '<div class="es-prima'+(p.vigente?' on':'')+'">'
              + '<div><b>'+esPct(p.prima)+'</b>'
              + '<span>Desde '+p.vigente_de
              + (p.vigente_a ? ' hasta '+p.vigente_a : ' (vigente)')
              + (p.clase ? ' · clase '+esE(p.clase) : '')
              + (p.fraccion ? ' · fracción '+esE(p.fraccion) : '')
              + '</span>'
              + (p.nota ? '<em>'+esE(p.nota)+'</em>' : '')
              + '</div>'
              + (p.vigente ? '<span class="sd-tag">Vigente</span>' : '')
              + '</div>').join('')
          + '</div>'
        : '<div class="sd-sin"><i class="fas fa-circle-exclamation"></i>'
          + '<div><b>Sin prima registrada</b>'
          + '<p>Se necesita para calcular las cuotas del IMSS. La encuentras en '
          + 'la determinación anual que presentaste en febrero.</p></div></div>'),
    acciones:'<button class="btn-pri" onclick="esPrimaNueva(\''+razonId+'\')">'
      + '<i class="fas fa-plus"></i> Registrar prima</button>'
  });
}

async function esPrimaNueva(razonId){
  const anio = new Date().getFullYear();

  const r = await modal({
    titulo:'Registrar prima de riesgo',
    subtitulo:'Se captura en porcentaje, como aparece en tu determinación anual.',
    ok:'Guardar',
    campos:[
      { k:'prima', label:'Prima', t:'num', req:true, ancho:'mitad',
        nota:'En porcentaje. Ej. 0.5425 para 0.5425%.' },
      { k:'desde', label:'Vigente desde', t:'fecha', req:true, ancho:'mitad',
        valor: anio+'-02-01',
        nota:'Normalmente el 1 de febrero.' },
      { k:'clase', label:'Clase', t:'texto', ancho:'mitad',
        nota:'Del catálogo del IMSS. Ej. I, II, III.' },
      { k:'fraccion', label:'Fracción', t:'texto', ancho:'mitad' },
      { k:'nota', label:'Nota', t:'texto', valor:'Determinación anual '+anio }
    ]
  });
  if(!r) return;

  // Se captura en % y se guarda como fracción: asi nadie mete 0.5 creyendo
  // que es medio por ciento.
  const { error } = await sb.rpc('prima_guardar', {
    p_razon_id: razonId,
    p_prima: Number(r.prima) / 100,
    p_vigente_de: r.desde,
    p_clase: r.clase || null,
    p_fraccion: r.fraccion || null,
    p_nota: r.nota || null
  });
  if(error){ toast('error', error.message); return; }

  toast('ok','Prima registrada');
  cerrarPanel();
  await esCargar();
  esPintar();
  esPrima(razonId);
}