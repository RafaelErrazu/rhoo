// ═══════════════════════════════════════════════════════════
// RHoo! · Prenómina
// Tablero de periodos y detalle por empleado. Todo pasa por
// RPCs: la nomina necesita bitacora y recalculo automatico, y
// eso no se puede dejar a que el front se acuerde de pedirlo.
// ═══════════════════════════════════════════════════════════

let _nmTab = null;      // respuesta de nomina_periodos
let _nmDet = null;      // respuesta de nomina_detalle
let _nmAnio = new Date().getFullYear();
let _nmBusca = '';
let _nmSoloAvisos = false;

const NM_EST = {
  abierto:  { t:'Abierto',     c:'var(--brand-p)', bg:'var(--brand-s)' },
  revision: { t:'En revisión', c:'#B45309',        bg:'#FEF3E2' },
  cerrado:  { t:'Cerrado',     c:'var(--txt-3)',   bg:'var(--linea-s)' }
};

const NM_DIAS_FREC = { semanal:7, decenal:10, catorcenal:14 };

function nmE(s){
  return (s==null?'':String(s))
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/"/g,'&quot;');
}

/* Dinero siempre con dos decimales y separador de miles: en una
   nomina, "1234.5" y "1,234.50" se leen distinto bajo presion. */
function nmM(n){
  return (Number(n)||0).toLocaleString('es-MX',
    { minimumFractionDigits:2, maximumFractionDigits:2 });
}

function nmNum(n){
  const v = Number(n)||0;
  return v % 1 === 0 ? String(v) : v.toFixed(2).replace(/0$/,'');
}

function nmFecha(f){
  if(!f) return '—';
  return new Date(f+'T12:00').toLocaleDateString('es-MX',
    { day:'2-digit', month:'short' });
}

/* ── Tablero ────────────────────────────────────────────── */

async function moduloPrenomina(){
  document.getElementById('contenido').innerHTML =
    '<p class="cargando">Cargando prenómina...</p>';
  _nmDet = null;
  if(await nmCargarTab()) nmPintarTab();
}

async function nmCargarTab(){
  const { data, error } = await sb.rpc('nomina_periodos', { p_anio: _nmAnio });
  if(error){ toast('error', error.message); return false; }
  _nmTab = data;
  return true;
}

function nmPintarTab(){
  const g = _nmTab.grupos || [];
  const p = _nmTab.periodos || [];
  const admin = _nmTab.es_admin;
  const anios = (_nmTab.anios || []).length ? _nmTab.anios : [_nmAnio];

  const totNeto = p.reduce((a,x) => a + Number(x.neto||0), 0);
  const abiertos = p.filter(x => x.estado !== 'cerrado').length;

  document.getElementById('contenido').innerHTML =
    '<div class="nm-top">'
    + '<div class="nm-top-izq">'
    + '<select id="nm-anio" onchange="nmAnio(this.value)">'
    + anios.map(a => '<option value="'+a+'"'+(a==_nmAnio?' selected':'')+'>'
        + a + '</option>').join('')
    + (anios.includes(_nmAnio) ? '' : '<option selected>'+_nmAnio+'</option>')
    + '</select>'
    + '<span class="nm-top-dato">'+p.length+' periodo(s) · '
    + abiertos+' sin cerrar</span>'
    + '</div>'
    + (admin
      ? '<div class="nm-top-der">'
        + '<button class="btn-sec-claro" onclick="nmGrupos()">'
        + '<i class="fas fa-layer-group"></i> Grupos de pago</button>'
        + '<button class="btn-pri" onclick="nmPeriodoNuevo()">'
        + '<i class="fas fa-plus"></i> Nuevo periodo</button>'
        + '</div>'
      : '')
    + '</div>'

    // Grupos: una tira compacta, no tarjetas. Son metadatos, no
    // el contenido principal de la pantalla.
    + (g.length
      ? '<div class="nm-grupos-tira">'
        + g.map(x => '<span class="nm-gr'+(x.activo?'':' off')+'">'
            + '<b>'+nmE(x.clave)+'</b> '+nmE(x.nombre)
            + ' <em>'+x.frecuencia+' · '+x.empleados+' persona(s)</em></span>').join('')
        + '</div>'
      : '')

    + (p.length
      ? '<div class="nm-scroll"><div class="tb-tabla"><table>'
        + '<thead><tr>'
        + '<th>Periodo</th><th>Grupo</th><th>Rango</th><th>Pago</th>'
        + '<th>Estado</th><th class="der">Personas</th>'
        + '<th class="der">Percepciones</th><th class="der">Deducciones</th>'
        + '<th class="der">Neto estimado</th>'
        + '</tr></thead><tbody>'
        + p.map(x => {
            const e = NM_EST[x.estado] || NM_EST.abierto;
            return '<tr class="nm-clic" onclick="nmAbrir(\''+x.id+'\')">'
              + '<td><b>#'+x.numero+'</b>'
              + (x.con_avisos > 0
                ? '<span class="nm-flag" title="'+x.con_avisos
                  + ' renglón(es) con avisos"><i class="fas fa-triangle-exclamation"></i> '
                  + x.con_avisos+'</span>' : '')
              + '</td>'
              + '<td>'+nmE(x.grupo_clave)+'<span class="tb-sub">'
              + nmE(x.grupo)+'</span></td>'
              + '<td class="num">'+nmFecha(x.desde)+' al '+nmFecha(x.hasta)
              + '<span class="tb-sub">'+x.dias+' días</span></td>'
              + '<td class="num">'+nmFecha(x.fecha_pago)+'</td>'
              + '<td><span class="tb-badge" style="color:'+e.c
              + ';background:'+e.bg+'">'+e.t+'</span></td>'
              + '<td class="num der">'+x.empleados+'</td>'
              + '<td class="num der">'+nmM(x.percepciones)+'</td>'
              + '<td class="num der">'+nmM(x.deducciones)+'</td>'
              + '<td class="num der"><b>'+nmM(x.neto)+'</b></td>'
              + '</tr>';
          }).join('')
        + '</tbody>'
        + (p.length > 1
          ? '<tfoot><tr><td colspan="8">Total del año</td>'
            + '<td class="num der"><b>'+nmM(totNeto)+'</b></td></tr></tfoot>'
          : '')
        + '</table></div></div>'

      : '<div class="vacio"><i class="fas fa-file-invoice-dollar"></i>'
        + '<h3>Sin periodos en '+_nmAnio+'</h3>'
        + '<p>Un periodo agrupa las fechas que se van a pagar. Crea el primero '
        + 'y RHoo! calcula días, faltas, tiempo extra y prima dominical a partir '
        + 'de la asistencia ya registrada.</p>'
        + (g.length
          ? ''
          : '<p style="margin-top:10px">Primero necesitas un <b>grupo de pago</b>: '
            + 'define cada cuándo se paga y a quién.</p>')
        + '</div>');
}

async function nmAnio(a){
  _nmAnio = Number(a);
  if(await nmCargarTab()) nmPintarTab();
}

/* ── Detalle del periodo ────────────────────────────────── */

async function nmAbrir(id){
  document.getElementById('contenido').innerHTML =
    '<p class="cargando">Abriendo periodo...</p>';
  const { data, error } = await sb.rpc('nomina_detalle', { p_periodo_id: id });
  if(error){ toast('error', error.message); moduloPrenomina(); return; }
  _nmDet = data;
  _nmBusca = '';
  _nmSoloAvisos = false;
  nmPintarDet();
}

function nmFilasVisibles(){
  const q = _nmBusca.trim().toLowerCase();
  return (_nmDet.filas || []).filter(f => {
    if(_nmSoloAvisos && !(f.avisos||[]).length) return false;
    if(!q) return true;
    return (f.nombre||'').toLowerCase().includes(q)
        || (f.no_empleado||'').toLowerCase().includes(q);
  });
}

function nmPintarDet(){
  const per = _nmDet.periodo;
  const admin = _nmDet.es_admin;
  const cerrado = per.estado === 'cerrado';
  const filas = _nmDet.filas || [];
  const pend = _nmDet.pendientes || [];
  const vis = nmFilasVisibles();
  const e = NM_EST[per.estado] || NM_EST.abierto;

  const tot = filas.reduce((a,f) => ({
    perc: a.perc + Number(f.total_percepciones||0),
    ded:  a.ded  + Number(f.total_deducciones||0),
    neto: a.neto + Number(f.neto||0)
  }), { perc:0, ded:0, neto:0 });

  const conAvisos = filas.filter(f => (f.avisos||[]).length).length;

  document.getElementById('contenido').innerHTML =
    '<div class="nm-det-top">'
    + '<button class="nm-volver" onclick="moduloPrenomina()">'
    + '<i class="fas fa-arrow-left"></i> Periodos</button>'
    + '<div class="nm-det-tit">'
    + '<h3>'+nmE(per.grupo)+' · periodo #'+per.numero+'</h3>'
    + '<p>'+nmFecha(per.desde)+' al '+nmFecha(per.hasta)+' de '+per.anio
    + ' · '+per.dias+' días · pago '+nmFecha(per.fecha_pago)+'</p>'
    + '</div>'
    + '<span class="tb-badge" style="color:'+e.c+';background:'+e.bg+'">'
    + e.t+'</span>'
    + '</div>'

    + (cerrado
      ? '<div class="nm-cerrado"><i class="fas fa-lock"></i>'
        + '<div><b>Periodo cerrado</b>'
        + '<p>Los importes quedaron congelados'
        + (per.cerrado_en
          ? ' el '+new Date(per.cerrado_en).toLocaleString('es-MX',
              {day:'2-digit', month:'short', year:'numeric',
               hour:'2-digit', minute:'2-digit'})
          : '')
        + '. Para modificar algo hay que reabrirlo, y eso queda en la bitácora.</p>'
        + '</div></div>'
      : '')

    + (admin
      ? '<div class="nm-acciones">'
        + (cerrado
          ? '<button class="btn-sec-claro" onclick="nmEstado(\'abierto\')">'
            + '<i class="fas fa-lock-open"></i> Reabrir</button>'
          : '<button class="btn-pri" onclick="nmCalcular()">'
            + '<i class="fas fa-calculator"></i> '
            + (filas.length ? 'Recalcular todo' : 'Calcular periodo')+'</button>'
            + (per.estado === 'abierto'
              ? '<button class="btn-sec-claro" onclick="nmEstado(\'revision\')">'
                + '<i class="fas fa-eye"></i> Pasar a revisión</button>'
              : '<button class="btn-sec-claro" onclick="nmEstado(\'abierto\')">'
                + '<i class="fas fa-rotate-left"></i> Volver a abierto</button>')
            + (filas.length
              ? '<button class="btn-sec-claro" onclick="nmEstado(\'cerrado\')">'
                + '<i class="fas fa-lock"></i> Cerrar periodo</button>'
              : ''))
        + (filas.length
          ? '<button class="btn-sec-claro" onclick="nmCSV()">'
            + '<i class="fas fa-file-csv"></i> Exportar</button>' : '')
        + '</div>'
      : '')

    // Huecos primero: el renglon que falta es mas grave que el
    // numero raro, porque nadie lo ve hasta que reclaman.
    + (pend.length
      ? '<div class="nm-hueco">'
        + '<i class="fas fa-user-slash"></i>'
        + '<div><b>'+pend.length+' persona(s) del grupo sin renglón</b>'
        + '<p>'+pend.slice(0,6).map(x =>
            nmE(x.nombre)+' <em>('+nmE(x.motivo)+')</em>').join(' · ')
        + (pend.length > 6 ? ' y '+(pend.length-6)+' más' : '')+'</p>'
        + '<p class="nm-hueco-tip">Los de "sin sueldo registrado" necesitan '
        + 'sueldo antes de poder calcularse.</p>'
        + '</div></div>'
      : '')

    + (filas.length
      ? '<div class="tb-resumen">'
        + '<div class="tb-kpi"><b class="num">'+filas.length+'</b>'
        + '<span>Renglones</span></div>'
        + '<div class="tb-kpi"><b class="num">'+nmM(tot.perc)+'</b>'
        + '<span>Percepciones</span></div>'
        + '<div class="tb-kpi"><b class="num">'+nmM(tot.ded)+'</b>'
        + '<span>Deducciones</span></div>'
        + '<div class="tb-kpi nm-kpi-neto"><b class="num">'+nmM(tot.neto)+'</b>'
        + '<span>Neto estimado</span></div>'
        + '</div>'

        + '<div class="nm-filtros">'
        + '<input id="nm-q" type="search" placeholder="Buscar por nombre o número"'
        + ' value="'+nmE(_nmBusca)+'" oninput="nmBuscar(this.value)">'
        + (conAvisos
          ? '<button class="nm-chip'+(_nmSoloAvisos?' on':'')+'"'
            + ' onclick="nmToggleAvisos()">'
            + '<i class="fas fa-triangle-exclamation"></i> '
            + conAvisos+' con avisos</button>'
          : '')
        + '<span class="nm-filtro-dato">'+vis.length+' de '+filas.length+'</span>'
        + '</div>'

        + nmTabla(vis)

        + '<p class="nm-legal">El neto es <b>estimado</b>: no incluye ISR ni '
        + 'cuotas del IMSS. Sirve para revisar y autorizar, no como recibo.</p>'

      : '<div class="vacio"><i class="fas fa-calculator"></i>'
        + '<h3>Periodo sin calcular</h3>'
        + '<p>Al calcular, RHoo! lee las jornadas y las incidencias aprobadas '
        + 'de estas fechas y arma el renglón de cada persona del grupo.</p></div>');
}

function nmTabla(vis){
  if(!vis.length){
    return '<div class="nm-nada">Ningún renglón coincide con el filtro.</div>';
  }
  return '<div class="nm-scroll"><div class="tb-tabla"><table>'
    + '<thead><tr>'
    + '<th>Colaborador</th><th class="der">Diario</th>'
    + '<th class="der">Trab</th><th class="der">Falt</th>'
    + '<th class="der">Vac</th><th class="der">Extra</th>'
    + '<th class="der">Percepciones</th><th class="der">Deducciones</th>'
    + '<th class="der">Neto</th>'
    + '</tr></thead><tbody>'
    + vis.map(f => {
        const ext = Number(f.horas_dobles||0) + Number(f.horas_triples||0);
        const av = (f.avisos||[]).length;
        return '<tr class="nm-clic" onclick="nmFila(\''+f.empleado_id+'\')">'
          + '<td><b>'+nmE(f.nombre)+'</b>'
          + '<span class="tb-sub">'+nmE(f.no_empleado||'')
          + (f.puesto ? ' · '+nmE(f.puesto) : '')+'</span></td>'
          + '<td class="num der">'+nmM(f.sueldo_diario)+'</td>'
          + '<td class="num der">'+nmNum(f.dias_trabajados)+'</td>'
          + '<td class="num der'+(Number(f.faltas)>0?' nm-mal':'')+'">'
          + nmNum(f.faltas)+'</td>'
          + '<td class="num der">'+nmNum(f.dias_vacaciones)+'</td>'
          + '<td class="num der">'+(ext ? nmNum(ext)+' h' : '—')+'</td>'
          + '<td class="num der">'+nmM(f.total_percepciones)+'</td>'
          + '<td class="num der">'+nmM(f.total_deducciones)+'</td>'
          + '<td class="num der"><b>'+nmM(f.neto)+'</b>'
          + (av ? ' <i class="fas fa-triangle-exclamation nm-av"></i>' : '')
          + '</td>'
          + '</tr>';
      }).join('')
    + '</tbody></table></div></div>';
}

function nmBuscar(v){
  _nmBusca = v;
  const vis = nmFilasVisibles();
  document.querySelector('.nm-scroll').outerHTML = nmTabla(vis);
  const d = document.querySelector('.nm-filtro-dato');
  if(d) d.textContent = vis.length+' de '+(_nmDet.filas||[]).length;
}

function nmToggleAvisos(){
  _nmSoloAvisos = !_nmSoloAvisos;
  nmPintarDet();
  const q = document.getElementById('nm-q');
  if(q) q.focus();
}

/* ── Cálculo y estado ───────────────────────────────────── */

async function nmCalcular(){
  const per = _nmDet.periodo;
  toast('ok','Calculando...');
  const { data, error } = await sb.rpc('calcular_prenomina_periodo',
    { p_periodo_id: per.id });
  if(error){ toast('error', error.message); return; }

  if(data.errores > 0){
    // Los errores se muestran, no se resumen: "3 errores" no le
    // dice a nadie a quien le falta el sueldo.
    panel({
      titulo:'Cálculo terminado con avisos',
      subtitulo: data.calculados+' calculado(s), '+data.errores+' con problema',
      html:'<div class="nm-errs">'
        + (data.detalle||[]).map(x =>
            '<div class="nm-err"><b>'+nmE(x.empleado)+'</b>'
            + '<span>'+nmE(x.message)+'</span></div>').join('')
        + '</div>'
    });
  } else {
    toast('ok', data.calculados+' renglón(es) calculados');
  }
  nmAbrir(per.id);
}

async function nmEstado(estado){
  const per = _nmDet.periodo;

  if(estado === 'cerrado'){
    const r = await confirmar({
      titulo:'Cerrar el periodo',
      mensaje:'Los importes quedan congelados y no se podrá capturar ni '
        + 'recalcular hasta reabrirlo. Se registra quién y cuándo.',
      ok:'Cerrar periodo', peligro:false
    });
    if(!r) return;
  }
  if(estado === 'abierto' && per.estado === 'cerrado'){
    const r = await confirmar({
      titulo:'Reabrir el periodo',
      mensaje:'Se borra la firma de cierre y los importes vuelven a ser '
        + 'modificables. Si ya se pagó con estos números, cualquier cambio '
        + 'genera una diferencia que hay que explicar.',
      ok:'Reabrir', peligro:true, pedirMotivo:true
    });
    if(!r) return;
    return nmEstadoRpc(per.id, estado, r.motivo);
  }
  return nmEstadoRpc(per.id, estado, null);
}

async function nmEstadoRpc(id, estado, nota){
  const { error } = await sb.rpc('nomina_periodo_estado',
    { p_periodo_id: id, p_estado: estado, p_nota: nota });
  if(error){ toast('error', error.message); return; }
  toast('ok','Periodo actualizado');
  nmAbrir(id);
}

/* ── Desglose de una persona ────────────────────────────── */

function nmFila(empId){
  const f = (_nmDet.filas||[]).find(x => x.empleado_id === empId);
  if(!f) return;
  const cerrado = _nmDet.periodo.estado === 'cerrado';
  const movs = (_nmDet.movimientos||[]).filter(m => m.empleado_id === empId);

  const linea = (et, val, nota) =>
    Number(val) ? '<div class="nm-ln"><span>'+et
      + (nota ? ' <em>'+nota+'</em>' : '')+'</span>'
      + '<b class="num">'+nmM(val)+'</b></div>' : '';

  panel({
    titulo: f.nombre,
    subtitulo: (f.no_empleado ? f.no_empleado+' · ' : '')
      + 'Sueldo diario '+nmM(f.sueldo_diario)+' · SDI '+nmM(f.sdi),
    html:
      ((f.avisos||[]).length
        ? '<div class="nm-avisos">'
          + f.avisos.map(a => '<div class="nm-aviso">'
              + '<i class="fas fa-circle-info"></i>'
              + '<span>'+nmE(a.texto)+'</span></div>').join('')
          + '</div>'
        : '')

      + '<h4 class="nm-h">Días del periodo</h4>'
      + '<div class="nm-dias">'
      + [['Trabajados', f.dias_trabajados], ['Descanso', f.dias_descanso],
         ['Vacaciones', f.dias_vacaciones], ['Incapacidad', f.dias_incapacidad],
         ['Permiso c/goce', f.dias_permiso_cg], ['Permiso s/goce', f.dias_permiso_sg],
         ['Faltas', f.faltas], ['Retardos', f.retardos],
         ['Días por retardo', f.faltas_por_retardo],
         ['Festivo lab.', f.dias_festivo_lab],
         ['Descanso lab.', f.dias_descanso_lab],
         ['Domingos lab.', f.domingos_lab]]
        .filter(([,v]) => Number(v))
        .map(([t,v]) => '<span class="nm-dia"><b class="num">'+nmNum(v)+'</b>'
          + t+'</span>').join('')
      + '</div>'

      + '<h4 class="nm-h">Percepciones</h4><div class="nm-lns">'
      + linea('Sueldo', f.importe_sueldo)
      + linea('Tiempo extra', f.importe_extras,
          nmNum(f.horas_dobles)+' h dobles'
          + (Number(f.horas_triples) ? ' · '+nmNum(f.horas_triples)+' h triples' : ''))
      + linea('Festivo trabajado', f.importe_festivos, 'art. 75')
      + linea('Descanso trabajado', f.importe_descanso_lab, 'art. 73')
      + linea('Prima dominical', f.importe_prima_dom, 'art. 71')
      + linea('Vacaciones', f.importe_vacaciones)
      + linea('Prima vacacional', f.importe_prima_vac)
      + linea('Otras percepciones', f.otras_percepciones)
      + '<div class="nm-ln tot"><span>Total percepciones</span>'
      + '<b class="num">'+nmM(f.total_percepciones)+'</b></div>'
      + '</div>'

      + '<h4 class="nm-h">Deducciones</h4><div class="nm-lns">'
      + (Number(f.importe_septimo)
        ? '<div class="nm-ln"><span>Séptimo día perdido '
          + '<em>'+nmNum(f.septimo_perdido)+' día(s) por faltas</em></span>'
          + '<b class="num">'+nmM(Math.abs(f.importe_septimo))+'</b></div>' : '')
      + (Number(f.importe_retardos)
        ? '<div class="nm-ln"><span>Descuento por retardos '
          + '<em>'+f.retardos+' retardo(s)'
          + (Number(f.faltas_por_retardo)
              ? ' · '+nmNum(f.faltas_por_retardo)+' día(s) descontados'
              : ' · '+Math.round(f.minutos_retardo)+' minutos')
          + '</em></span>'
          + '<b class="num">'+nmM(f.importe_retardos)+'</b></div>' : '')
      + linea('Otras deducciones', f.otras_deducciones)
      + (Number(f.total_deducciones)
        ? '<div class="nm-ln tot"><span>Total deducciones</span>'
          + '<b class="num">'+nmM(f.total_deducciones)+'</b></div>'
        : '<div class="nm-ln"><span>Sin deducciones</span><b>—</b></div>')
      + '</div>'

      + '<div class="nm-neto"><span>Neto estimado</span>'
      + '<b class="num">'+nmM(f.neto)+'</b></div>'

      + '<h4 class="nm-h">Movimientos capturados'
      + (cerrado ? '' : ' <button class="nm-add" onclick="nmMovNuevo(\''
          + empId+'\')"><i class="fas fa-plus"></i> Agregar</button>')
      + '</h4>'
      + (movs.length
        ? '<div class="nm-movs">'
          + movs.map(m => '<div class="nm-mov">'
              + '<div><b>'+nmE(m.concepto)+'</b>'
              + '<span>'+(m.naturaleza === 'percepcion' ? 'Percepción' : 'Deducción')
              + (m.cantidad ? ' · '+nmNum(m.cantidad)+' u.' : '')
              + (m.nota ? ' · '+nmE(m.nota) : '')+'</span></div>'
              + '<b class="num">'+nmM(m.importe)+'</b>'
              + (cerrado ? ''
                : '<button class="nm-x" title="Quitar" onclick="nmMovBorrar(\''
                  + m.id+'\',\''+empId+'\')"><i class="fas fa-trash"></i></button>')
              + '</div>').join('')
          + '</div>'
        : '<p class="nm-nada-min">Sin bonos, préstamos ni otros conceptos.</p>')
  });
}

async function nmMovNuevo(empId){
  const cs = _nmDet.conceptos || [];
  if(!cs.length){ toast('error','No hay conceptos activos'); return; }

  const r = await modal({
    titulo:'Agregar movimiento',
    subtitulo:'Se recalcula el renglón al guardar.',
    ok:'Guardar',
    campos:[
      { k:'concepto', label:'Concepto', t:'select', req:true,
        opciones: cs.map(c => [c.id,
          (c.naturaleza === 'percepcion' ? '+ ' : '− ') + c.nombre]) },
      { k:'importe', label:'Importe', t:'num', req:true, ancho:'mitad',
        nota:'Siempre en positivo: el signo lo pone el concepto.' },
      { k:'cantidad', label:'Cantidad', t:'num', ancho:'mitad',
        nota:'Opcional. Piezas, horas o unidades.' },
      { k:'nota', label:'Nota', t:'texto',
        nota:'Queda visible en el desglose y en la bitácora.' }
    ]
  });
  if(!r) return;

  const { data, error } = await sb.rpc('nomina_mov_guardar', {
    p_periodo_id: _nmDet.periodo.id,
    p_empleado_id: empId,
    p_concepto_id: r.concepto,
    p_importe: Number(r.importe),
    p_cantidad: r.cantidad ? Number(r.cantidad) : null,
    p_nota: r.nota || null
  });
  if(error){ toast('error', error.message); return; }

  const rec = data.recalculo || {};
  toast('ok', rec.neto != null
    ? 'Guardado. Nuevo neto: '+nmM(rec.neto)
    : 'Movimiento guardado');

  cerrarPanel();
  await nmRefrescar(empId);
}

async function nmMovBorrar(id, empId){
  const r = await confirmar({
    titulo:'Quitar el movimiento',
    mensaje:'Se elimina del periodo y el renglón se recalcula.',
    ok:'Quitar'
  });
  if(!r) return;

  const { error } = await sb.rpc('nomina_mov_borrar', { p_id: id });
  if(error){ toast('error', error.message); return; }
  toast('ok','Movimiento quitado');
  cerrarPanel();
  await nmRefrescar(empId);
}

/* Recarga el periodo y vuelve a abrir el desglose de la misma
   persona: cerrar el panel obligaria a buscarla de nuevo en la
   lista despues de cada captura. */
async function nmRefrescar(empId){
  const { data, error } = await sb.rpc('nomina_detalle',
    { p_periodo_id: _nmDet.periodo.id });
  if(error){ toast('error', error.message); return; }
  _nmDet = data;
  nmPintarDet();
  if(empId) nmFila(empId);
}

/* ── Periodos y grupos ──────────────────────────────────── */

/* Sugiere el siguiente rango a partir del ultimo periodo del
   grupo. Teclear fechas a mano en cada quincena es como se
   generan los periodos traslapados. */
function nmSugerir(grupo){
  const previos = (_nmTab.periodos||[])
    .filter(p => p.grupo_clave === grupo.clave)
    .sort((a,b) => a.hasta < b.hasta ? 1 : -1);

  const iso = d => d.toLocaleDateString('sv-SE');
  let desde;

  if(previos.length){
    desde = new Date(previos[0].hasta + 'T12:00');
    desde.setDate(desde.getDate() + 1);
  } else {
    const h = new Date();
    desde = new Date(h.getFullYear(), h.getMonth(), 1);
  }

  let hasta = new Date(desde);
  if(grupo.frecuencia === 'quincenal'){
    // Quincenas de calendario: del 1 al 15 y del 16 al fin de mes.
    hasta = desde.getDate() <= 15
      ? new Date(desde.getFullYear(), desde.getMonth(), 15)
      : new Date(desde.getFullYear(), desde.getMonth() + 1, 0);
  } else if(grupo.frecuencia === 'mensual'){
    hasta = new Date(desde.getFullYear(), desde.getMonth() + 1, 0);
  } else {
    hasta.setDate(hasta.getDate() + (NM_DIAS_FREC[grupo.frecuencia] || 7) - 1);
  }

  const pago = new Date(hasta);
  pago.setDate(pago.getDate() + (grupo.dias_para_pago || 5));

  return { desde: iso(desde), hasta: iso(hasta), pago: iso(pago) };
}

async function nmPeriodoNuevo(){
  const gs = (_nmTab.grupos||[]).filter(g => g.activo);
  if(!gs.length){
    toast('error','Primero crea un grupo de pago');
    return nmGrupos();
  }

  let grupo = gs[0];
  if(gs.length > 1){
    const g = await modal({
      titulo:'Nuevo periodo',
      subtitulo:'¿Para qué grupo de pago?',
      ok:'Continuar',
      campos:[{ k:'grupo', label:'Grupo', t:'select', req:true,
        opciones: gs.map(x => [x.id, x.clave+' · '+x.nombre+' ('+x.frecuencia+')']) }]
    });
    if(!g) return;
    grupo = gs.find(x => x.id === g.grupo);
  }

  const s = nmSugerir(grupo);
  const r = await modal({
    titulo:'Nuevo periodo · '+grupo.nombre,
    subtitulo:'Frecuencia '+grupo.frecuencia+'. Las fechas vienen sugeridas '
      + 'a partir del último periodo.',
    ok:'Crear periodo',
    campos:[
      { k:'desde', label:'Desde', t:'fecha', req:true, ancho:'mitad', valor:s.desde },
      { k:'hasta', label:'Hasta', t:'fecha', req:true, ancho:'mitad', valor:s.hasta },
      { k:'pago',  label:'Fecha de pago', t:'fecha', valor:s.pago,
        nota:'Sugerida: '+grupo.dias_para_pago+' días después del corte.' }
    ]
  });
  if(!r) return;

  const { data, error } = await sb.rpc('nomina_periodo_crear', {
    p_grupo_id: grupo.id, p_desde: r.desde, p_hasta: r.hasta,
    p_fecha_pago: r.pago || null, p_numero: null
  });
  if(error){ toast('error', error.message); return; }

  toast('ok','Periodo #'+data.numero+' creado');
  await nmCargarTab();
  nmAbrir(data.id);
}

function nmGrupos(){
  const gs = _nmTab.grupos || [];
  panel({
    titulo:'Grupos de pago',
    subtitulo:'Cada grupo tiene su propia periodicidad y su propio calendario.',
    html:
      '<p class="nm-expl">La frecuencia vive en el grupo, no en la persona. '
      + 'Así puedes tener operativos semanales y administrativos quincenales '
      + 'al mismo tiempo, cada uno con sus fechas de corte.</p>'
      + (gs.length
        ? '<div class="nm-gr-lista">'
          + gs.map(g => '<button class="nm-gr-item'+(g.activo?'':' off')+'"'
              + ' onclick="nmGrupoEditar(\''+g.id+'\')">'
              + '<div><b>'+nmE(g.clave)+' · '+nmE(g.nombre)+'</b>'
              + '<span>'+g.frecuencia+' · pago '+g.dias_para_pago
              + ' días después · '+g.empleados+' persona(s)'
              + (g.activo ? '' : ' · inactivo')+'</span></div>'
              + '<i class="fas fa-chevron-right"></i></button>').join('')
          + '</div>'
        : '<p class="nm-nada-min">Todavía no hay grupos.</p>'),
    acciones:'<button class="btn-pri" onclick="nmGrupoNuevo()">'
      + '<i class="fas fa-plus"></i> Nuevo grupo</button>'
  });
}

async function nmGrupoNuevo(){
  const r = await modal({
    titulo:'Nuevo grupo de pago',
    ok:'Crear',
    campos:[
      { k:'clave', label:'Clave', t:'texto', req:true, ancho:'mitad', max:12,
        nota:'Corta, para identificarlo. Ej. QNA, SEM.' },
      { k:'nombre', label:'Nombre', t:'texto', req:true, ancho:'mitad' },
      { k:'frecuencia', label:'Frecuencia', t:'select', req:true, ancho:'mitad',
        opciones:[['semanal','Semanal'],['decenal','Decenal'],
                  ['catorcenal','Catorcenal'],['quincenal','Quincenal'],
                  ['mensual','Mensual']],
        nota:'No se puede cambiar después.' },
      { k:'dias', label:'Días para pagar', t:'num', ancho:'mitad', valor:5,
        nota:'Después del último día del periodo.' }
    ]
  });
  if(!r) return;

  const { error } = await sb.rpc('nomina_grupo_guardar', {
    p_clave: r.clave, p_nombre: r.nombre, p_frecuencia: r.frecuencia,
    p_dias_para_pago: Number(r.dias) || 5, p_activo: true,
    p_centro_id: null, p_id: null
  });
  if(error){ toast('error', error.message); return; }

  toast('ok','Grupo creado');
  cerrarPanel();
  await nmCargarTab();
  nmPintarTab();
}

async function nmGrupoEditar(id){
  const g = (_nmTab.grupos||[]).find(x => x.id === id);
  if(!g) return;

  const r = await modal({
    titulo:'Editar '+g.clave,
    subtitulo:'La frecuencia ('+g.frecuencia+') no se puede cambiar: los '
      + 'periodos ya creados quedarían con una periodicidad que no coincide '
      + 'con sus fechas.',
    ok:'Guardar',
    campos:[
      { k:'nombre', label:'Nombre', t:'texto', req:true, valor:g.nombre },
      { k:'dias', label:'Días para pagar', t:'num', ancho:'mitad',
        valor:g.dias_para_pago },
      { k:'activo', label:'Activo', t:'select', ancho:'mitad', req:true,
        opciones:[['si','Sí'],['no','No']], valor:g.activo?'si':'no',
        nota:'Inactivo no permite crear periodos nuevos.' }
    ]
  });
  if(!r) return;

  const { error } = await sb.rpc('nomina_grupo_guardar', {
    p_clave: g.clave, p_nombre: r.nombre, p_frecuencia: g.frecuencia,
    p_dias_para_pago: Number(r.dias) || 5, p_activo: r.activo === 'si',
    p_centro_id: null, p_id: g.id
  });
  if(error){ toast('error', error.message); return; }

  toast('ok','Grupo actualizado');
  cerrarPanel();
  await nmCargarTab();
  nmPintarTab();
}

/* ── Exportar ───────────────────────────────────────────── */

/* CSV con punto y coma y BOM: Excel en español abre las comas
   como decimales y rompe la columna de importes. */
function nmCSV(){
  const per = _nmDet.periodo;
  const cols = [
    ['No. empleado','no_empleado'], ['Colaborador','nombre'], ['Puesto','puesto'],
    ['Sueldo diario','sueldo_diario'], ['SDI','sdi'],
    ['Días trabajados','dias_trabajados'], ['Descanso','dias_descanso'],
    ['Vacaciones','dias_vacaciones'], ['Incapacidad','dias_incapacidad'],
    ['Permiso c/goce','dias_permiso_cg'], ['Permiso s/goce','dias_permiso_sg'],
    ['Faltas','faltas'], ['Séptimo perdido','septimo_perdido'],
    ['Retardos','retardos'], ['Minutos de retardo','minutos_retardo'],
    ['Días por retardo','faltas_por_retardo'],
    ['Descuento retardos','importe_retardos'],
    ['Horas dobles','horas_dobles'], ['Horas triples','horas_triples'],
    ['Horas excedidas','horas_excedidas'],
    ['Festivo lab.','dias_festivo_lab'], ['Descanso lab.','dias_descanso_lab'],
    ['Domingos lab.','domingos_lab'],
    ['Sueldo','importe_sueldo'], ['Séptimo','importe_septimo'],
    ['Extras','importe_extras'], ['Festivos','importe_festivos'],
    ['Descanso trabajado','importe_descanso_lab'],
    ['Prima dominical','importe_prima_dom'],
    ['Vacaciones $','importe_vacaciones'], ['Prima vacacional','importe_prima_vac'],
    ['Otras percepciones','otras_percepciones'],
    ['Otras deducciones','otras_deducciones'],
    ['Total percepciones','total_percepciones'],
    ['Total deducciones','total_deducciones'],
    ['Neto estimado','neto']
  ];

  const filas = nmFilasVisibles();
  // Comillas siempre y coma como separador: es CSV estandar, y el BOM al
  // inicio (sin nada antes) es lo unico que hace que Excel lea los acentos.
  const limpia = v => '"' + (v == null ? ''
    : String(v).replace(/"/g,'""').replace(/[\r\n]+/g,' ')) + '"';

  const csv = '﻿'
    + cols.map(c => limpia(c[0])).join(',') + '\r\n'
    + filas.map(f => cols.map(c => limpia(f[c[1]])).join(',')).join('\r\n');

  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([csv], { type:'text/csv;charset=utf-8' }));
  a.download = 'prenomina_'+per.grupo_clave+'_'+per.anio+'_'+per.numero+'.csv';
  a.click();
  URL.revokeObjectURL(a.href);
  toast('ok', filas.length+' renglón(es) exportados');
}