// ═══════════════════════════════════════════════════════════
//  RHoo! · Vacaciones e incidencias
//  Jefe primero, RH despues: el jefe sabe si el equipo aguanta;
//  RH valida saldo y ley.
// ═══════════════════════════════════════════════════════════

let _incVista = 'mias';
let _incTipos = null;

const EST_INC = {
  pendiente:     { txt:'Pendiente',        color:'#B45309', bg:'#FEF3E2' },
  aprobada_jefe: { txt:'Falta RH',         color:'#4F46E5', bg:'#EEF2FF' },
  aprobada:      { txt:'Aprobada',         color:'var(--ok)', bg:'#E3F5F0' },
  rechazada:     { txt:'Rechazada',        color:'var(--error)', bg:'#FEF2F2' },
  cancelada:     { txt:'Cancelada',        color:'var(--txt-3)', bg:'var(--linea-s)' },
  borrador:      { txt:'Borrador',         color:'var(--txt-3)', bg:'var(--linea-s)' }
};

const fDia = s => s
  ? new Date(s+'T12:00').toLocaleDateString('es-MX',{day:'2-digit',month:'short'})
  : '—';

async function tiposInc(){
  if(_incTipos) return _incTipos;
  const { data } = await sb.from('tipos_incidencia')
    .select('clave,nombre,descuenta_vac,requiere_doc,con_goce')
    .eq('activo', true).order('nombre');
  _incTipos = data || [];
  return _incTipos;
}

/* ── Solicitar ── */
async function nuevaSolicitud(paraOtro){
  const tipos = await tiposInc();
  let emps = [];

  if(paraOtro){
    const { data } = await sb.rpc('listar_empleados',
      { p_buscar:null, p_estatus:'Activo', p_centro_id:null, p_limite:200, p_desde:0 });
    emps = (data?.filas || []).map(f => [f.id, f.nombre + ' · #' + f.no]);
    if(!emps.length){ toast('error','Sin empleados activos'); return; }
  }

  const hoy = new Date().toLocaleDateString('sv-SE');

  const r = await modal({
    titulo: paraOtro ? 'Registrar incidencia' : 'Solicitar días',
    subtitulo: paraOtro
      ? 'Se registra a nombre del colaborador que elijas.'
      : 'Los días se cuentan según tu turno: los descansos y festivos no se descuentan.',
    ok: 'Enviar solicitud',
    campos: [
      ...(paraOtro ? [{ k:'empleado', label:'Colaborador', t:'select', req:true,
        opciones: emps }] : []),
      { k:'tipo', label:'Tipo', t:'select', req:true,
        opciones: tipos.map(t => [t.clave, t.nombre
          + (t.descuenta_vac ? ' (descuenta vacaciones)' : '')]) },
      { k:'desde', label:'Del', t:'fecha', req:true, valor:hoy, ancho:'mitad' },
      { k:'hasta', label:'Al', t:'fecha', req:true, valor:hoy, ancho:'mitad' },
      { k:'comentario', label:'Comentario', t:'area',
        nota:'Opcional, pero ayuda a quien autoriza.' }
    ]
  });
  if(!r) return;

  const { data, error } = await sb.rpc('solicitar_incidencia', {
    p_tipo_clave: r.tipo,
    p_desde: r.desde,
    p_hasta: r.hasta,
    p_comentario: r.comentario || null,
    p_empleado_id: paraOtro ? r.empleado : null
  });

  if(error){ toast('error', error.message); return; }

  toast('ok', data.dias + ' día(s) hábiles solicitados'
    + (data.espera === 'jefe' ? '. Espera autorización de tu jefe.'
      : data.espera === 'rh' ? '. Espera autorización de Recursos Humanos.'
      : ''));
  pintarIncidencias();
}

/* ── Firmar ── */
async function firmar(id, decision, quien){
  const r = await modal({
    titulo: decision === 'aprobada' ? 'Autorizar solicitud' : 'Rechazar solicitud',
    subtitulo: quien + (decision === 'aprobada'
      ? '. Si eres la última firma, los días se descuentan al confirmar.'
      : '. El motivo se le muestra al colaborador.'),
    ok: decision === 'aprobada' ? 'Autorizar' : 'Rechazar',
    peligro: decision === 'rechazada',
    campos: [{ k:'nota', label:'Nota', t:'area',
      req: decision === 'rechazada',
      nota: decision === 'rechazada'
        ? 'Obligatoria: rechazar sin explicación genera más trabajo del que ahorra.'
        : 'Opcional.' }]
  });
  if(!r) return;

  const { data, error } = await sb.rpc('resolver_incidencia', {
    p_id: id, p_decision: decision, p_nota: r.nota || null });

  if(error){ toast('error', error.message); return; }

  toast('ok', data.estatus === 'aprobada_jefe'
    ? 'Autorizada. Pasa a Recursos Humanos.'
    : data.estatus === 'rechazada' ? 'Solicitud rechazada'
    : 'Solicitud aprobada');
  pintarIncidencias();
}

async function cancelarSol(id){
  const r = await confirmar({
    titulo:'Cancelar solicitud',
    mensaje:'Si ya estaba aprobada, los días se devuelven al saldo.',
    ok:'Cancelar solicitud', pedirMotivo:true });
  if(!r) return;
  const { error } = await sb.rpc('cancelar_incidencia', { p_id:id, p_motivo:r.motivo });
  if(error){ toast('error', error.message); return; }
  toast('ok','Solicitud cancelada');
  pintarIncidencias();
}

async function pintarIncidencias(){
  const cont = document.getElementById('inc-cuerpo');
  if(!cont) return;
  cont.innerHTML = '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando...</p>';

  const { data, error } = await sb.rpc('bandeja_incidencias',
    { p_vista: _incVista, p_estatus: null });
  if(error){ cont.innerHTML = '<p class="cargando">'+error.message+'</p>'; return; }

  const filas = data.filas || [];
  if(!filas.length){
    cont.innerHTML = '<div class="vacio"><i class="fas fa-calendar-check"></i>'
      + '<h3>'+(_incVista === 'poraprobar' ? 'Nada por autorizar' : 'Sin solicitudes')+'</h3>'
      + '<p>'+(_incVista === 'poraprobar'
          ? 'Cuando alguien solicite días, aparecerá aquí.'
          : 'Usa el botón para solicitar días.')+'</p></div>';
    return;
  }

  cont.innerHTML = '<div class="inc-lista">'
    + filas.map(f => {
        const e = EST_INC[f.estatus] || EST_INC.pendiente;
        return '<div class="inc-item">'
          + '<div class="inc-top">'
          + '<div class="inc-tit">'
          + (_incVista !== 'mias' ? '<b>'+f.empleado+'</b>' : '')
          + '<span>'+f.tipo+'</span></div>'
          + '<span class="tb-badge" style="color:'+e.color+';background:'+e.bg+'">'
          + e.txt+'</span></div>'

          + '<div class="inc-fechas">'
          + '<i class="fas fa-calendar"></i>'
          + fDia(f.desde)+' al '+fDia(f.hasta)
          + '<b>'+f.dias+' día'+(f.dias===1?'':'s')+'</b>'
          + (f.descuenta_vac ? '<em>de vacaciones</em>' : '')
          + '</div>'

          + (f.comentario ? '<p class="inc-com">'+f.comentario+'</p>' : '')

          // El rastro de firmas: quién autorizó y cuándo. Sin
          // esto, "aprobada" no dice quién se hizo responsable.
          + (f.firmas.length
              ? '<div class="inc-firmas">'
                + f.firmas.map(s =>
                    '<span class="'+(s.decision==='rechazada'?'no':'si')+'">'
                    + '<i class="fas fa-'+(s.decision==='rechazada'?'xmark':'check')+'"></i>'
                    + (s.nivel==='jefe'?'Jefe':'RH')+': '+s.quien
                    + (s.nota ? ' · '+s.nota : '')+'</span>'
                  ).join('')
                + '</div>'
              : '')

          + (f.espera
              ? '<p class="inc-espera">Esperando autorización de '
                + (f.espera==='jefe'?'su jefe directo':'Recursos Humanos')+'</p>'
              : '')

          + '<div class="inc-acc">'
          + (f.puedo_firmar
              ? '<button class="btn-pri" onclick="firmar(\''+f.id+'\',\'aprobada\',\''
                + f.empleado.replace(/'/g,"")+'\')">Autorizar</button>'
                + '<button class="btn-peligro" onclick="firmar(\''+f.id+'\',\'rechazada\',\''
                + f.empleado.replace(/'/g,"")+'\')">Rechazar</button>'
              : '')
          + (['pendiente','aprobada_jefe','aprobada'].includes(f.estatus)
              ? '<button class="btn-sec-claro" onclick="cancelarSol(\''+f.id+'\')">'
                + 'Cancelar</button>'
              : '')
          + '</div></div>';
      }).join('')
    + '</div>';
}

function incIr(v){
  _incVista = v;
  document.querySelectorAll('.inc-tab').forEach(b =>
    b.classList.toggle('on', b.dataset.v === v));
  pintarIncidencias();
}

async function moduloIncidencias(){
  const admin = Sesion.esJefe;
  document.getElementById('contenido').innerHTML =
    '<div class="asis-barra">'
    + '<div class="asis-tabs">'
    + '<button class="asis-tab inc-tab on" data-v="mias" onclick="incIr(\'mias\')">'
    + 'Mis solicitudes</button>'
    + (admin
        ? '<button class="asis-tab inc-tab" data-v="poraprobar" onclick="incIr(\'poraprobar\')">'
          + 'Por autorizar</button>'
          + '<button class="asis-tab inc-tab" data-v="todas" onclick="incIr(\'todas\')">'
          + 'Todas</button>'
        : '')
    + '</div>'
    + '<div style="display:flex;gap:8px">'
    + '<button class="btn-pri" onclick="nuevaSolicitud(false)">'
    + '<i class="fas fa-plus"></i> Solicitar</button>'
    + (Sesion.esAdmin
        ? '<button class="btn-sec-claro" onclick="nuevaSolicitud(true)">'
          + 'Registrar por otro</button>'
        : '')
    + '</div></div>'
    + '<div id="inc-cuerpo"></div>';
  await pintarIncidencias();
}

/* ═══════════════════════════════════════════════════════════
   VACACIONES · saldo con su desglose
   ═══════════════════════════════════════════════════════════ */

const MOV_TXT = {
  devengado:'Generado por antigüedad', tomado:'Días disfrutados',
  pagado:'Pagado', ajuste:'Ajuste', extra:'Días adicionales',
  prescrito:'Prescrito'
};

async function moduloVacaciones(empId){
  const cont = document.getElementById('contenido');
  cont.innerHTML = '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando...</p>';

  const { data, error } = await sb.rpc('estado_vacaciones',
    { p_empleado_id: empId || null });

  if(error || data.status !== 'success'){
    cont.innerHTML = '<div class="vacio"><i class="fas fa-umbrella-beach"></i>'
      + '<h3>Sin expediente ligado</h3>'
      + '<p>Tu usuario no está ligado a un empleado, así que no tiene saldo de '
      + 'vacaciones. Consulta el saldo de cada persona desde su expediente.</p></div>';
    return;
  }

  const mov = data.movimientos || [];

  cont.innerHTML =
    '<div class="vac-top">'
    + '<div class="vac-saldo">'
    + '<b>'+(+data.saldo).toFixed(0)+'</b>'
    + '<span>días disponibles</span></div>'
    + '<div class="vac-datos">'
    + '<p><span>Antigüedad</span><b>'+data.anios+' año'+(data.anios===1?'':'s')+'</b></p>'
    + '<p><span>Le corresponden por ley</span><b>'+data.dias_por_ley+' al año</b></p>'
    + (data.dias_extra > 0
        ? '<p><span>Días adicionales de la empresa</span><b>+'+data.dias_extra+'</b></p>'
        : '')
    + '<p><span>Prima vacacional</span><b>'+data.prima_pct+'%</b></p>'
    + '</div></div>'

    + '<p class="vac-ley"><i class="fas fa-scale-balanced"></i>'
    + 'Artículo 76 de la LFT: 12 días al primer año, aumentando 2 por año hasta 20 '
    + 'al quinto, y 2 más por cada 5 años de servicio.</p>'

    + '<button class="btn-pri" style="margin-bottom:18px" onclick="nuevaSolicitud(false)">'
    + '<i class="fas fa-plus"></i> Solicitar vacaciones</button>'

    // El desglose completo: un saldo sin su origen no se puede
    // defender cuando el trabajador lo cuestiona.
    + '<h4 class="ex-sec">Movimientos</h4>'
    + (mov.length
        ? '<div class="vac-mov">'
          + mov.map(m =>
              '<div class="vac-m">'
              + '<span class="vac-md">'+fDia(m.fecha)+'</span>'
              + '<span class="vac-mt">'+(MOV_TXT[m.tipo]||m.tipo)
              + (m.periodo ? ' · año '+m.periodo : '')
              + (m.nota ? '<em>'+m.nota+'</em>' : '')+'</span>'
              + '<span class="vac-mn '+(m.dias>0?'mas':'menos')+'">'
              + (m.dias>0?'+':'')+(+m.dias).toFixed(0)+'</span>'
              + '</div>'
            ).join('')
          + '</div>'
        : '<p class="ub-nada">Sin movimientos registrados.</p>');
}

/* Carga de histórico, desde el expediente. Sin esto, al migrar
   de otro sistema todos aparecen con años de vacaciones
   acumuladas que en realidad ya tomaron. */
async function cargarHistoricoVac(empId, nombre, saldoActual){
  const r = await modal({
    titulo: 'Registrar días ya tomados',
    subtitulo: nombre + ' tiene ' + Math.round(saldoActual) + ' día(s) de saldo. '
      + 'Si viene de otro sistema, registra aquí los días que YA disfrutó para '
      + 'que el saldo refleje la realidad.',
    ok: 'Registrar',
    campos: [
      { k:'dias', label:'Días ya tomados', t:'num', req:true, min:1, max:400,
        nota:'Se restan del saldo.' },
      { k:'nota', label:'Referencia', t:'texto',
        valor:'Carga inicial de histórico',
        nota:'Queda en el libro mayor y en la bitácora.' }
    ]
  });
  if(!r) return;

  const { data, error } = await sb.rpc('cargar_vacaciones_tomadas', {
    p_empleado_id: empId, p_dias: Number(r.dias), p_nota: r.nota });

  if(error){ toast('error', error.message); return; }
  toast('ok','Saldo actualizado a '+Math.round(data.saldo)+' días');
  cerrarPanel();
  if(typeof verEmpleado === 'function') verEmpleado(empId);
}