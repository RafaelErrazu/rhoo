// ═══════════════════════════════════════════════════════════
//  RHoo! · Documentos del expediente
//  El OCR propone; RH confirma. Nunca escribe solo.
// ═══════════════════════════════════════════════════════════

const OCR_ETIQUETAS = {
  curp:'CURP', rfc:'RFC', nss:'NSS',
  nombres:'Nombre(s)', apellido_paterno:'Apellido paterno',
  apellido_materno:'Apellido materno',
  fecha_nacimiento:'Fecha de nacimiento', sexo:'Sexo',
  escolaridad:'Escolaridad'
};

let _docEmp = null;

async function pintarDocumentos(empId){
  const cont = document.getElementById('doc-cuerpo');
  if(!cont) return;
  cont.innerHTML = '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando...</p>';

  const { data, error } = await sb.rpc('documentos_empleado', { p_empleado_id: empId });
  if(error){ cont.innerHTML = '<p class="cargando">'+error.message+'</p>'; return; }

  _docEmp = { id: empId, tipos: data.tipos };
  const docs = data.documentos || [];
  const faltan = data.faltantes || [];

  cont.innerHTML =
    // Los faltantes primero: es el dato que se busca al abrir
    // esta pantalla, no la lista de lo que ya está.
    (faltan.length
      ? '<div class="doc-faltan">'
        + '<p><i class="fas fa-circle-exclamation"></i><b>Faltan '
        + faltan.length + ' documento(s) obligatorio(s)</b></p>'
        + '<div>'+faltan.map(f =>
            '<button onclick="subirDoc(\''+f.clave+'\')">'+f.nombre+'</button>'
          ).join('')+'</div></div>'
      : '<p class="doc-ok"><i class="fas fa-circle-check"></i>'
        + 'Expediente completo</p>')

    + '<button class="btn-pri doc-add" onclick="subirDoc(null)">'
    + '<i class="fas fa-arrow-up-from-bracket"></i> Subir documento</button>'

    + (docs.length
        ? '<div class="doc-lista">'
          + docs.map(d =>
              '<div class="doc-item'+(d.vencido?' venc':'')+'">'
              + '<i class="doc-ico fas fa-'
              + (d.mime?.includes('pdf') ? 'file-pdf' : 'file-image')+'"></i>'
              + '<div class="doc-info">'
              + '<b>'+(d.tipo || 'Documento')+'</b>'
              + '<span>'+d.nombre+'</span>'
              + (d.fecha_vence
                  ? '<em class="'+(d.vencido?'venc':(d.por_vencer?'pv':''))+'">'
                    + (d.vencido ? 'Venció el ' : 'Vence el ')
                    + new Date(d.fecha_vence+'T12:00').toLocaleDateString('es-MX')
                    + '</em>'
                  : '')
              + '</div>'
              + '<div class="doc-acc">'
              + (d.ocr_estado === 'procesado' && d.ocr_campos
                  && Object.keys(d.ocr_campos).length
                  ? '<button class="doc-ocr" onclick="revisarOcr(\''+d.id+'\')">'
                    + '<i class="fas fa-wand-magic-sparkles"></i>'
                    + Object.keys(d.ocr_campos).length+' dato(s)</button>'
                  : d.ocr_estado === 'pendiente'
                    ? '<span class="doc-est"><i class="fas fa-spinner fa-spin"></i></span>'
                    : '')
              + '<button onclick="verDoc(\''+d.ruta+'\')" title="Ver">'
              + '<i class="fas fa-eye"></i></button>'
              + '<button onclick="borrarDoc(\''+d.id+'\',\''
              + (d.tipo||'documento').replace(/'/g,"")+'\')" title="Eliminar">'
              + '<i class="fas fa-trash"></i></button>'
              + '</div></div>'
            ).join('')
          + '</div>'
        : '<p class="ub-nada" style="margin-top:14px">Sin documentos todavía.</p>');
}

async function subirDoc(clavePre){
  const tipos = _docEmp.tipos;

  const r = await modal({
    titulo: 'Subir documento',
    subtitulo: 'Si el tipo lo permite, la IA intentará leer los datos y te los '
      + 'propondrá para revisión.',
    ok: 'Subir',
    campos: [
      { k:'tipo', label:'Tipo de documento', t:'select', req:true,
        opciones: tipos.map(t => [t.clave, t.nombre]),
        valor: clavePre || tipos[0]?.clave },
      { k:'fecha_doc', label:'Fecha del documento', t:'fecha', ancho:'mitad' },
      { k:'fecha_vence', label:'Vence el', t:'fecha', ancho:'mitad',
        nota:'Déjalo vacío si no caduca. Con fecha, se avisa 30 días antes.' }
    ]
  });
  if(!r) return;

  // El input de archivo se crea aparte: dentro del modal el
  // navegador pierde el archivo al repintar.
  const inp = document.createElement('input');
  inp.type = 'file';
  inp.accept = 'image/jpeg,image/png,image/webp,application/pdf';
  inp.onchange = async () => {
    const f = inp.files[0];
    if(!f) return;
    if(f.size > 10 * 1024 * 1024){
      toast('error','El archivo pasa de 10 MB. Comprímelo o toma la foto con menos resolución.');
      return;
    }
    await procesarSubida(f, r);
  };
  inp.click();
}

async function procesarSubida(archivo, meta){
  toast('ok', 'Subiendo ' + archivo.name + '...');

  const ext = archivo.name.split('.').pop().toLowerCase();
  // La ruta empieza con el tenant: es lo que las políticas de
  // Storage comparan para aislar clientes.
  const ruta = Sesion.perfil.tenant_id + '/' + _docEmp.id + '/'
             + meta.tipo + '-' + Date.now() + '.' + ext;

  const { error: eUp } = await sb.storage
    .from('expedientes').upload(ruta, archivo, { contentType: archivo.type });

  if(eUp){ toast('error','No se pudo subir: '+eUp.message); return; }

  const { data, error } = await sb.rpc('registrar_documento', {
    p_empleado_id: _docEmp.id,
    p_tipo_clave: meta.tipo,
    p_nombre: archivo.name,
    p_ruta: ruta,
    p_mime: archivo.type,
    p_tamano: archivo.size,
    p_fecha_doc: meta.fecha_doc || null,
    p_fecha_vence: meta.fecha_vence || null
  });

  if(error){ toast('error', error.message); return; }

  await pintarDocumentos(_docEmp.id);

  // El OCR corre después de registrar: si Gemini falla o tarda,
  // el documento ya está guardado. Un OCR caído no debe impedir
  // subir un contrato.
  const tipo = _docEmp.tipos.find(t => t.clave === meta.tipo);
  if(tipo && tipo.campos_ocr?.length){
    toast('ok','Leyendo el documento con IA...');
    try{
      await sb.functions.invoke('ocr-documento', {
        body: { documento_id: data.id } });
    }catch(e){ /* el estado queda en la tabla */ }
    await pintarDocumentos(_docEmp.id);
  }
}

/* Revisión campo por campo. El OCR nunca escribe solo: una INE
   mal fotografiada puede dar un CURP con un caracter cambiado, y
   ese error reaparecería en el alta del IMSS meses después. */
async function revisarOcr(docId){
  const { data } = await sb.rpc('documentos_empleado', { p_empleado_id: _docEmp.id });
  const d = (data.documentos||[]).find(x => x.id === docId);
  if(!d?.ocr_campos) return;

  const campos = Object.entries(d.ocr_campos);

  const r = await modal({
    titulo: 'Datos leídos del documento',
    subtitulo: 'Revisa cada valor antes de guardarlo en el expediente. '
      + 'Corrige lo que esté mal o vacía lo que no quieras aplicar.',
    ok: 'Aplicar al expediente',
    campos: campos.map(([k,v]) => ({
      k, label: OCR_ETIQUETAS[k] || k, t: k === 'fecha_nacimiento' ? 'fecha' : 'texto',
      valor: v,
      ancho: ['nombres','apellido_paterno','apellido_materno'].includes(k) ? 'full' : 'mitad'
    }))
  });
  if(!r) return;

  // Los vacíos no se mandan: vaciar un campo en la revisión
  // significa "no apliques esto", no "bórralo del expediente".
  const limpio = {};
  Object.entries(r).forEach(([k,v]) => { if(v && v.trim()) limpio[k] = v.trim(); });

  if(!Object.keys(limpio).length){ toast('error','No hay nada que aplicar'); return; }

  const { error } = await sb.rpc('aplicar_ocr', {
    p_documento_id: docId, p_campos: limpio });

  if(error){ toast('error', error.message); return; }
  toast('ok', Object.keys(limpio).length + ' dato(s) aplicados al expediente');
  cerrarPanel();
  if(typeof verEmpleado === 'function') verEmpleado(_docEmp.id);
}

/* URL firmada con expiración: los archivos son privados y una
   URL eterna sería una fuga permanente. */
async function verDoc(ruta){
  const { data, error } = await sb.storage
    .from('expedientes').createSignedUrl(ruta, 300);
  if(error){ toast('error','No se pudo abrir'); return; }
  window.open(data.signedUrl, '_blank');
}

async function borrarDoc(id, nombre){
  const r = await confirmar({
    titulo: 'Eliminar documento',
    mensaje: 'Se eliminará "'+nombre+'". Queda registro en la bitácora.',
    ok: 'Eliminar', pedirMotivo: true
  });
  if(!r) return;

  const { data, error } = await sb.rpc('eliminar_documento', {
    p_id: id, p_motivo: r.motivo });
  if(error){ toast('error', error.message); return; }

  // El archivo se borra después del registro: si el borrado de
  // Storage falla, queda un huérfano en el bucket, que es un
  // problema menor que un registro apuntando a nada.
  await sb.storage.from('expedientes').remove([data.ruta]);
  toast('ok','Documento eliminado');
  pintarDocumentos(_docEmp.id);
}

/* Panel de documentos, se abre desde el expediente. */
function abrirDocumentos(empId, nombre){
  panel({
    titulo: 'Documentos',
    subtitulo: nombre,
    html: '<div id="doc-cuerpo"></div>'
  });
  pintarDocumentos(empId);
}