// ═══════════════════════════════════════════════════════════
//  RHoo! · Cumplimiento / NOM-035
//  Todo el analisis por PORCENTAJE DE TRABAJADORES en cada
//  nivel, nunca por promedio: la Norma califica por trabajador.
// ═══════════════════════════════════════════════════════════

const NIV = {
  'Nulo':      { c:'#8494A7', t:'Nulo' },
  'Bajo':      { c:'#14A085', t:'Bajo' },
  'Medio':     { c:'#D97706', t:'Medio' },
  'Alto':      { c:'#EA580C', t:'Alto' },
  'Muy alto':  { c:'#B91C1C', t:'Muy alto' }
};
const ORDEN_NIV = ['Nulo','Bajo','Medio','Alto','Muy alto'];

let _cuTab = 'campanas';
let _cuCamp = null;      // campaña seleccionada
let _cuAgg = null;
let _cuPerfil = 'turno';

const pct = (n,d) => d > 0 ? Math.round(n*100/d) : 0;

/* ── Barra 100% apilada: el primitivo correcto para esta norma ── */
function barraNiveles(dist, total, alto){
  const segs = ORDEN_NIV.filter(n => dist[n]).map(n => {
    const p = dist[n]/total*100;
    return '<div style="width:'+p+'%;background:'+NIV[n].c+'" '
      + 'title="'+n+': '+dist[n]+' de '+total+' ('+Math.round(p)+'%)"></div>';
  }).join('');
  return '<div class="nv-barra" style="height:'+(alto||16)+'px">'+segs+'</div>';
}

function leyendaNiveles(){
  return '<div class="nv-leyenda">'
    + ORDEN_NIV.map(n =>
        '<span><i style="background:'+NIV[n].c+'"></i>'+n+'</span>').join('')
    + '</div>';
}

/* ── Lista de campañas ── */
async function pintarCampanas(){
  const cont = document.getElementById('cu-cuerpo');
  cont.innerHTML = '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando...</p>';

  const [camp, vig] = await Promise.all([
    sb.rpc('nom035_campanas_lista'),
    sb.rpc('nom035_vigencia')
  ]);

  const lista = camp.data || [];
  const vigencia = vig.data || [];

  // La vigencia va arriba: es la obligación que se incumple sin
  // que nadie lo note, porque vence 24 meses después.
  const alertas = vigencia.filter(v => v.estado !== 'vigente');

  cont.innerHTML =
    (alertas.length
      ? '<div class="cu-vig">'
        + '<h4><i class="fas fa-shield-halved"></i>Vigencia de la evaluación</h4>'
        + alertas.map(v => {
            const et = { sin_evaluar:['Sin evaluar nunca','#B91C1C'],
                         vencida:['Vencida','#B91C1C'],
                         por_vencer:['Por vencer','#B45309'] }[v.estado];
            return '<div class="cu-vig-f">'
              + '<b>'+v.centro+'</b>'
              + '<span style="color:'+et[1]+'">'+et[0]
              + (v.dias != null && v.estado==='por_vencer' ? ' · '+v.dias+' días' : '')
              + (v.dias != null && v.estado==='vencida' ? ' · hace '+Math.abs(v.dias)+' días' : '')
              + '</span></div>';
          }).join('')
        + '</div>'
      : '')

    + '<div class="cu-head">'
    + '<div><h3>Campañas de evaluación</h3>'
    + '<p>Cada campaña congela su universo al abrirse, para que la participación '
    + 'sea comparable entre periodos.</p></div>'
    + '<button class="btn-pri" onclick="nuevaCampana()">'
    + '<i class="fas fa-plus"></i> Nueva campaña</button></div>'

    + (lista.length
        ? '<div class="cu-camps">'
          + lista.map(c => {
              const p = pct(c.respuestas, c.universo);
              const okMuestra = c.respuestas >= (c.muestra_minima||0);
              return '<div class="cu-camp" onclick="verCampana(\''+c.id+'\')">'
                + '<div class="cu-camp-t">'
                + '<div><b>'+c.nombre+'</b>'
                + '<span>'+(c.centro||'Todos los centros')
                + ' · '+(c.guia||'').replace('guia','Guía ')
                + ' · desde '+new Date(c.abre+'T12:00').toLocaleDateString('es-MX')
                + '</span></div>'
                + '<span class="cu-est cu-'+c.estado+'">'+c.estado+'</span></div>'
                + '<div class="cu-camp-p">'
                + '<div class="cu-prog"><div style="width:'+Math.min(100,p)+'%"></div></div>'
                + '<span class="num"><b>'+c.respuestas+'</b>/'+c.universo
                + ' · '+p+'%</span></div>'
                + '<p class="cu-camp-m'+(okMuestra?' ok':'')+'">'
                + (okMuestra
                    ? 'Alcanza la muestra mínima ('+c.muestra_minima+')'
                    : 'Faltan '+((c.muestra_minima||0)-c.respuestas)
                      + ' para la muestra mínima de '+c.muestra_minima)
                + '</p></div>';
            }).join('')
          + '</div>'
        : '<div class="vacio"><i class="fas fa-clipboard-list"></i>'
          + '<h3>Sin campañas</h3><p>Abre una campaña para empezar a evaluar.</p></div>');
}

async function nuevaCampana(){
  const { data: cs } = await sb.from('centros_trabajo')
    .select('id,clave,nombre').eq('activo',true).order('clave');
  if(!cs?.length){ toast('error','Registra primero un centro de trabajo'); return; }

  const hoy = new Date();
  const fin = new Date(hoy.getTime() + 30*86400000);

  const r = await modal({
    titulo:'Nueva campaña de evaluación',
    subtitulo:'La guía se determina sola según cuántos trabajadores activos '
      + 'tenga el centro: hasta 15 solo Guía I, hasta 50 Guía II, más de 50 Guía III.',
    ok:'Abrir campaña',
    campos:[
      { k:'nombre', label:'Nombre', t:'texto', req:true,
        valor:'Evaluación NOM-035 '+hoy.getFullYear() },
      { k:'centro', label:'Centro de trabajo', t:'select', req:true,
        opciones: cs.map(c => [c.id, c.nombre]),
        nota:'La Norma evalúa por centro de trabajo, no por empresa.' },
      { k:'cierra', label:'Cierra el', t:'fecha',
        valor: fin.toLocaleDateString('sv-SE'),
        nota:'Después de esta fecha los enlaces dejan de funcionar.' }
    ]
  });
  if(!r) return;

  const { data, error } = await sb.rpc('nom035_abrir_campana', {
    p_nombre: r.nombre, p_centro_id: r.centro, p_cierra: r.cierra || null });

  if(error){ toast('error', error.message); return; }

  modal({
    titulo:'Campaña abierta',
    subtitulo: 'Se generaron '+data.invitaciones+' enlaces individuales. '
      + 'Le corresponde la '+data.guia.replace('guia','Guía ')+'. '
      + 'Con '+data.universo+' trabajadores, la muestra mínima es de '
      + data.muestra_minima+' respuestas.',
    ok:'Ver campaña', cancelar:''
  }).then(() => verCampana(data.id));

  pintarCampanas();
}

/* ── Detalle: avance e invitaciones ── */
async function verCampana(id){
  _cuCamp = id;
  const cont = document.getElementById('cu-cuerpo');
  cont.innerHTML = '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando...</p>';

  const { data, error } = await sb.rpc('nom035_avance', { p_campana_id: id });
  if(error){ cont.innerHTML = '<p class="cargando">'+error.message+'</p>'; return; }

  const c = data.campana;
  const base = location.origin + '/cuestionario.html?t=';

  cont.innerHTML =
    '<button class="cu-volver" onclick="cuIr(\'campanas\')">'
    + '<i class="fas fa-chevron-left"></i> Campañas</button>'

    + '<div class="cu-head"><div><h3>'+c.nombre+'</h3>'
    + '<p>'+c.estado+' · '+c.universo+' trabajadores</p></div>'
    + '<div style="display:flex;gap:8px">'
    + (c.estado === 'abierta'
        ? '<button class="btn-sec-claro" onclick="cerrarCampana(\''+id+'\')">'
          + 'Cerrar campaña</button>' : '')
    + '<button class="btn-pri" onclick="cuIr(\'dashboard\')">Ver resultados</button>'
    + '</div></div>'

    // Los tres números que importan: cuánto falta para cumplir
    + '<div class="cu-kpis">'
    + '<div class="cu-kpi"><b class="num">'+data.respuestas+'</b>'
    + '<span>respuestas</span></div>'
    + '<div class="cu-kpi"><b class="num">'+data.pct_universo+'%</b>'
    + '<span>del total</span></div>'
    + '<div class="cu-kpi'+(data.falta_para_muestra===0?' ok':'')+'">'
    + '<b class="num">'+(data.falta_para_muestra || '✓')+'</b>'
    + '<span>'+(data.falta_para_muestra
        ? 'faltan para la muestra' : 'muestra alcanzada')+'</span></div>'
    + '</div>'

    + '<div class="cu-prog gr"><div style="width:'+data.pct_muestra+'%"></div></div>'
    + '<p class="cu-nota">Meta: '+c.muestra_minima+' respuestas (numeral III.1). '
    + 'La Norma no exige el 100%, exige una muestra representativa.</p>'

    + (data.pendientes.length
        ? '<h4 class="cu-h">Pendientes ('+data.pendientes.length+')</h4>'
          + '<p class="cu-nota">Copia el enlace de cada persona o expórtalos todos. '
          + 'Cada enlace es individual y de un solo uso.</p>'
          + '<button class="btn-sec-claro" style="margin-bottom:12px" '
          + 'onclick="exportarEnlaces(\''+id+'\')">'
          + '<i class="fas fa-download"></i> Exportar enlaces (CSV)</button>'
          + '<div class="cu-pend">'
          + data.pendientes.slice(0,50).map(p =>
              '<div class="cu-pend-f">'
              + '<div><b>'+p.nombre+'</b><span>#'+p.no
              + (p.email ? ' · '+p.email : '')+'</span></div>'
              + '<button onclick="copiar(\''+base+p.token+'\')" title="Copiar enlace">'
              + '<i class="fas fa-link"></i></button></div>').join('')
          + (data.pendientes.length > 50
              ? '<p class="cu-nota">Y '+(data.pendientes.length-50)+' más. '
                + 'Usa la exportación para la lista completa.</p>' : '')
          + '</div>'
        : '<p class="doc-ok"><i class="fas fa-circle-check"></i>'
          + 'Todos contestaron</p>')

    + (data.contestaron.length
        ? '<h4 class="cu-h">Contestaron ('+data.contestaron.length+')</h4>'
          + '<p class="cu-nota">Solo se registra que participaron. Sus respuestas '
          + 'y resultados individuales no se muestran aquí.</p>'
          + '<div class="cu-hechos">'
          + data.contestaron.map(x =>
              '<span>'+x.nombre+'</span>').join('')
          + '</div>'
        : '');
}

function copiar(txt){
  navigator.clipboard.writeText(txt)
    .then(() => toast('ok','Enlace copiado'))
    .catch(() => toast('error','No se pudo copiar'));
}

async function exportarEnlaces(id){
  const { data } = await sb.rpc('nom035_avance', { p_campana_id: id });
  const base = location.origin + '/cuestionario.html?t=';
  const csv = 'Numero,Nombre,Correo,Enlace\n'
    + (data.pendientes||[]).map(p =>
        '"'+p.no+'","'+p.nombre+'","'+(p.email||'')+'","'+base+p.token+'"'
      ).join('\n');
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([csv], { type:'text/csv;charset=utf-8' }));
  a.download = 'enlaces-nom035.csv';
  a.click();
  toast('ok','Enlaces exportados');
}

async function cerrarCampana(id){
  const r = await confirmar({
    titulo:'Cerrar campaña',
    mensaje:'Los enlaces sin usar dejarán de funcionar. Esto no se puede revertir.',
    ok:'Cerrar campaña' });
  if(!r) return;

  const { data, error } = await sb.rpc('nom035_cerrar_campana', { p_id: id });
  if(error){ toast('error', error.message); return; }

  // Cerrar por debajo de la muestra deja el cumplimiento
  // incompleto: mejor que quede claro ahora que en la inspección.
  if(!data.alcanzo_muestra){
    modal({ titulo:'Campaña cerrada, con una advertencia',
      subtitulo:'Se cerró con '+data.respuestas+' respuestas y la muestra mínima '
        + 'era de '+data.muestra_minima+'. Ante una inspección, la evaluación '
        + 'podría considerarse insuficiente. Considera abrir una campaña '
        + 'complementaria.',
      ok:'Entendido', cancelar:'' });
  } else {
    toast('ok','Campaña cerrada');
  }
  verCampana(id);
}

/* ── Dashboard ── */
async function pintarDashboard(){
  const cont = document.getElementById('cu-cuerpo');
  if(!_cuCamp){
    const { data } = await sb.rpc('nom035_campanas_lista');
    if(!data?.length){
      cont.innerHTML = '<div class="vacio"><i class="fas fa-chart-column"></i>'
        + '<h3>Sin datos</h3><p>Abre una campaña y captura respuestas.</p></div>';
      return;
    }
    _cuCamp = data[0].id;
  }

  cont.innerHTML = '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Calculando...</p>';

  const { data: a, error } = await sb.rpc('nom035_agregado', { p_campana_id: _cuCamp });
  if(error){ cont.innerHTML = '<p class="cargando">'+error.message+'</p>'; return; }
  _cuAgg = a;

  if(!a.total){
    cont.innerHTML = '<div class="vacio"><i class="fas fa-chart-column"></i>'
      + '<h3>Sin respuestas</h3><p>'+(a.mensaje||'')+'</p></div>';
    return;
  }

  const dist = a.distribucion || {};
  const nc = NIV[a.nivel_centro] || NIV['Nulo'];
  const pctRiesgo = pct(a.en_riesgo, a.total);

  // Dominios ordenados por gravedad: alfabético obliga a leer los
  // diez para encontrar el problema.
  const doms = Object.entries(a.por_dominio || {}).map(([nom, niv]) => {
    const tot = ORDEN_NIV.reduce((s,n) => s + (niv[n]||0), 0);
    const alto = (niv['Alto']||0) + (niv['Muy alto']||0);
    return { nom, niv, tot, alto, pct: pct(alto, tot) };
  }).sort((x,y) => y.pct - x.pct || y.alto - x.alto);

  cont.innerHTML =
    '<div class="cu-head"><div><h3>'+a.campana.nombre+'</h3>'
    + '<p>'+(a.campana.centro||'')+' · '+a.total+' de '+a.campana.universo
    + ' trabajadores ('+a.participacion_pct+'%)</p></div>'
    + '<div style="display:flex;gap:8px">'
    + '<button class="btn-sec-claro" onclick="verDifusion()">'
    + '<i class="fas fa-bullhorn"></i> Difusión</button>'
    + '<button class="btn-sec-claro" onclick="verInforme()">'
    + '<i class="fas fa-file-lines"></i> Informe 7.7</button></div></div>'

    + (!a.alcanzo_muestra
        ? '<p class="aviso" style="background:#FEF3E2;color:#92400E">'
          + '<i class="fas fa-triangle-exclamation" style="color:#B45309"></i>'
          + 'La participación no alcanza la muestra mínima de '
          + a.campana.muestra_minima+' respuestas del numeral III.1. '
          + 'Los resultados son indicativos, no concluyentes.</p>'
        : '')

    // Los dos números que definen todo
    + '<div class="da-top">'
    + '<div class="da-nivel" style="background:'+nc.c+'1a;border-color:'+nc.c+'">'
    + '<span>Nivel del centro de trabajo</span>'
    + '<b style="color:'+nc.c+'">'+a.nivel_centro+'</b>'
    + '<em>El nivel más alto donde se concentra al menos el '+a.umbral_pct
    + '% de los evaluados</em></div>'
    + '<div class="da-riesgo">'
    + '<span>En riesgo alto o muy alto</span>'
    + '<b class="num" style="color:'+(a.en_riesgo?'#B91C1C':'#14A085')+'">'
    + pctRiesgo+'%</b>'
    + '<em>'+a.en_riesgo+' de '+a.total+' trabajadores</em></div>'
    + '</div>'

    + '<div class="da-card">'
    + '<h4>Distribución por nivel de riesgo</h4>'
    + barraNiveles(dist, a.total, 24)
    + '<div class="da-nums">'
    + ORDEN_NIV.filter(n => dist[n]).map(n =>
        '<span><i style="background:'+NIV[n].c+'"></i>'+n
        + ' <b class="num">'+dist[n]+'</b> ('+pct(dist[n],a.total)+'%)</span>').join('')
    + '</div></div>'

    // Mapa de calor por dominio, con el umbral marcado
    + '<div class="da-card">'
    + '<h4>Dominios · trabajadores por nivel</h4>'
    + '<p class="cu-nota">La línea marca el '+a.umbral_pct+'%: los dominios cuya '
    + 'porción de riesgo alto la cruza son los que exigen intervención.</p>'
    + '<div class="da-doms">'
    + doms.map(d =>
        '<div class="da-dom">'
        + '<div class="da-dom-t">'
        + '<span>'+d.nom+'</span>'
        + '<b style="color:'+(d.pct >= a.umbral_pct ? '#B91C1C'
            : d.pct > 0 ? '#B45309' : '#8494A7')+'">'+d.pct+'%</b></div>'
        + '<div class="da-dom-b">'
        + barraNiveles(d.niv, d.tot, 14)
        + '<i class="da-umbral" style="left:'+(100-a.umbral_pct)+'%"></i>'
        + '</div></div>').join('')
    + '</div>'
    + leyendaNiveles()
    + '</div>'

    // Cruce por perfil: donde aparece el hallazgo
    + '<div class="da-card">'
    + '<h4>Dónde se concentra el riesgo</h4>'
    + '<div class="da-chips">'
    + [['turno','Turno'],['tipo_puesto','Tipo de puesto'],
       ['antiguedad','Antigüedad'],['rota','Rota turnos'],
       ['sexo','Sexo'],['edad','Edad']].map(([k,l]) =>
        '<button class="da-chip'+(_cuPerfil===k?' on':'')+'" '
        + 'onclick="cuPerfil(\''+k+'\')">'+l+'</button>').join('')
    + '</div>'
    + '<div id="da-perfil"></div></div>'

    + '<div class="da-card">'
    + '<h4>Acontecimientos traumáticos severos (Guía I)</h4>'
    + '<p class="cu-nota">Se reporta aparte: mide algo distinto al riesgo '
    + 'psicosocial y sus resultados son confidenciales del área de salud.</p>'
    + '<div class="da-g1">'
    + '<div><b class="num">'+a.guia1_total+'</b><span>evaluados</span></div>'
    + '<div><b class="num" style="color:'+(a.guia1_valoracion?'#B45309':'#14A085')+'">'
    + a.guia1_valoracion+'</b><span>requieren valoración</span></div>'
    + '</div>'
    + (a.guia1_valoracion
        ? '<p class="aviso" style="background:#FEF3E2;color:#92400E;margin:12px 0 0">'
          + '<i class="fas fa-user-doctor" style="color:#B45309"></i>'
          + 'Deben canalizarse a la institución de seguridad social o al médico '
          + 'del centro de trabajo (numeral 5.5). Consulta los nombres en el '
          + 'expediente de cada persona.</p>'
        : '')
    + '</div>';

  cuPerfil(_cuPerfil);
}

async function cuPerfil(campo){
  _cuPerfil = campo;
  document.querySelectorAll('.da-chip').forEach(b =>
    b.classList.toggle('on', b.textContent.trim() ===
      ({turno:'Turno',tipo_puesto:'Tipo de puesto',antiguedad:'Antigüedad',
        rota:'Rota turnos',sexo:'Sexo',edad:'Edad'})[campo]));

  const el = document.getElementById('da-perfil');
  if(!el) return;
  el.innerHTML = '<p class="cargando">Calculando...</p>';

  const { data, error } = await sb.rpc('nom035_por_perfil',
    { p_campana_id: _cuCamp, p_campo: campo });

  if(error){ el.innerHTML = '<p class="cu-nota">'+error.message+'</p>'; return; }

  const filas = data.filas || [];
  if(!filas.length){
    el.innerHTML = '<p class="cu-nota">Sin suficientes respuestas por grupo. '
      + data.nota + '</p>';
    return;
  }

  el.innerHTML = '<div class="da-perf">'
    + filas.map(f =>
        '<div class="da-perf-f">'
        + '<div class="da-perf-t"><span>'+f.valor+'</span>'
        + '<b style="color:'+(f.en_riesgo_pct >= 25 ? '#B91C1C'
            : f.en_riesgo_pct > 0 ? '#B45309' : '#8494A7')+'">'
        + f.en_riesgo_pct+'%</b></div>'
        + '<div class="da-perf-b"><div style="width:'+Math.max(f.en_riesgo_pct,2)
        + '%;background:'+(f.en_riesgo_pct >= 25 ? '#B91C1C' : '#EA580C')
        + '"></div></div>'
        + '<span class="da-perf-n num">'+f.en_riesgo+' de '+f.total+'</span>'
        + '</div>').join('')
    + '</div>'
    + '<p class="cu-nota">'+data.nota+'</p>';
}

/* ── Informe 7.7 ── */
async function verInforme(){
  const { data, error } = await sb.rpc('nom035_informe', { p_campana_id: _cuCamp });
  if(error){ toast('error', error.message); return; }

  const r = data.resultados;
  const dist = r.distribucion || {};

  const html =
    '<div class="inf">'
    + '<h2>Informe de resultados</h2>'
    + '<p class="inf-sub">Identificación y análisis de factores de riesgo '
    + 'psicosocial · NOM-035-STPS-2018, numeral 7.7</p>'

    + '<h3>1. Datos del centro de trabajo</h3>'
    + '<table class="inf-t">'
    + '<tr><td>Razón social</td><td>'+(data.centro.razon_social||'—')+'</td></tr>'
    + '<tr><td>Centro de trabajo</td><td>'+(data.centro.nombre||'—')+'</td></tr>'
    + '<tr><td>Domicilio</td><td>'+(data.centro.domicilio||'—')+'</td></tr>'
    + '<tr><td>Trabajadores</td><td>'+data.centro.trabajadores+'</td></tr>'
    + '</table>'

    + '<h3>2. Objetivo</h3><p>'+data.objetivo+'</p>'

    + '<h3>3. Método</h3>'
    + '<table class="inf-t">'
    + '<tr><td>Instrumento</td><td>'
    + (data.metodo.guia||'').replace('guia','Guía de Referencia ')+'</td></tr>'
    + '<tr><td>Aplicación</td><td>'+data.metodo.aplicacion+'</td></tr>'
    + '<tr><td>Periodo</td><td>'+data.metodo.periodo+'</td></tr>'
    + '<tr><td>Universo</td><td>'+data.metodo.universo+' trabajadores</td></tr>'
    + '<tr><td>Muestra mínima</td><td>'+data.metodo.muestra_minima
    + ' (Ecuación 1, numeral III.1)</td></tr>'
    + '<tr><td>Cuestionarios respondidos</td><td>'+data.metodo.respuestas+'</td></tr>'
    + '</table>'

    + '<h3>4. Resultados</h3>'
    + '<p><b>Nivel de riesgo del centro de trabajo: '+r.nivel_centro+'</b></p>'
    + '<table class="inf-t"><tr><th>Nivel</th><th>Trabajadores</th><th>%</th></tr>'
    + ORDEN_NIV.map(n =>
        '<tr><td>'+n+'</td><td>'+(dist[n]||0)+'</td><td>'
        + pct(dist[n]||0, r.total)+'%</td></tr>').join('')
    + '</table>'

    + '<h4>Por dominio</h4>'
    + '<table class="inf-t"><tr><th>Dominio</th><th>En riesgo alto o muy alto</th></tr>'
    + Object.entries(r.por_dominio||{}).map(([nom,niv]) => {
        const tot = ORDEN_NIV.reduce((s,n) => s+(niv[n]||0),0);
        const alto = (niv['Alto']||0)+(niv['Muy alto']||0);
        return '<tr><td>'+nom+'</td><td>'+alto+' de '+tot
          + ' ('+pct(alto,tot)+'%)</td></tr>';
      }).join('')
    + '</table>'

    + '<h3>5. Conclusiones</h3>'
    + '<p>El nivel de riesgo del centro de trabajo es <b>'
    + data.conclusiones.nivel_centro+'</b>, con una participación del '
    + data.conclusiones.participacion+'.</p>'
    + '<p>'+data.conclusiones.suficiencia+'</p>'
    + '<p class="inf-crit">'+data.conclusiones.criterio+'</p>'

    + '<h3>6. Recomendaciones y acciones de intervención</h3>'
    + '<p>'+data.acciones+'</p>'

    + '<h3>7. Acontecimientos traumáticos severos</h3>'
    + '<p>De '+data.acontecimientos_traumaticos.evaluados+' trabajadores '
    + 'evaluados con la Guía de Referencia I, '
    + '<b>'+data.acontecimientos_traumaticos.requieren_valoracion+'</b> '
    + 'requieren valoración clínica.</p>'
    + '<p class="inf-crit">'+data.acontecimientos_traumaticos.nota+'</p>'

    + '<h3>8. Responsable de la evaluación</h3>'
    + '<table class="inf-t">'
    + '<tr><td>Nombre completo</td><td class="inf-blank"></td></tr>'
    + '<tr><td>Cédula profesional</td><td class="inf-blank"></td></tr>'
    + '<tr><td>Firma</td><td class="inf-blank" style="height:52px"></td></tr>'
    + '</table>'
    + '<p class="inf-pie">Generado por RHoo! el '
    + new Date(data.generado_en).toLocaleString('es-MX')+'</p>'
    + '</div>';

  panel({
    titulo:'Informe numeral 7.7',
    subtitulo:'Los datos del responsable se llenan al imprimir y firmar.',
    html: html,
    acciones:'<button class="btn-sec-claro" onclick="cerrarPanel()">Cerrar</button>'
      + '<button class="btn-pri" onclick="imprimirInforme()">'
      + '<i class="fas fa-print"></i> Imprimir o guardar PDF</button>'
  });
}

/* Se imprime en ventana aparte: el CSS de la app tiene sidebar y
   paneles que no deben aparecer en el documento. */
function imprimirInforme(){
  const cuerpo = document.querySelector('.inf').outerHTML;
  const w = window.open('', '_blank');
  w.document.write(
    '<!doctype html><html lang="es"><head><meta charset="utf-8">'
    + '<title>Informe NOM-035</title>'
    + '<style>'
    + 'body{font-family:Georgia,serif;max-width:760px;margin:32px auto;padding:0 24px;'
    + 'color:#111;line-height:1.6}'
    + 'h2{font-size:1.4rem;margin-bottom:4px}'
    + '.inf-sub{color:#555;font-size:.85rem;margin-bottom:26px;font-style:italic}'
    + 'h3{font-size:1.05rem;margin:26px 0 8px;border-bottom:1px solid #ccc;'
    + 'padding-bottom:4px}'
    + 'h4{font-size:.95rem;margin:16px 0 6px}'
    + 'p{margin-bottom:10px;font-size:.92rem}'
    + '.inf-t{width:100%;border-collapse:collapse;margin-bottom:12px;font-size:.88rem}'
    + '.inf-t td,.inf-t th{border:1px solid #ccc;padding:7px 10px;text-align:left}'
    + '.inf-t th{background:#f2f2f2}'
    + '.inf-t td:first-child{width:38%;color:#444}'
    + '.inf-blank{height:26px}'
    + '.inf-crit{font-size:.83rem;color:#444;background:#f7f7f7;padding:10px 12px;'
    + 'border-radius:4px}'
    + '.inf-pie{margin-top:32px;font-size:.75rem;color:#888;text-align:right}'
    + '@media print{body{margin:0}}'
    + '</style></head><body>' + cuerpo + '</body></html>');
  w.document.close();
  setTimeout(() => w.print(), 400);
}

function cuIr(t){
  _cuTab = t;
  document.querySelectorAll('.cu-tab').forEach(b =>
    b.classList.toggle('on', b.dataset.t === t));
  if(t === 'campanas')  pintarCampanas();
  if(t === 'dashboard') pintarDashboard();
  if(t === 'programa')  pintarPrograma();
}

async function moduloCumplimiento(){
  document.getElementById('contenido').innerHTML =
    '<div class="asis-barra"><div class="asis-tabs">'
    + '<button class="asis-tab cu-tab on" data-t="campanas" onclick="cuIr(\'campanas\')">'
    + 'Campañas</button>'
    + '<button class="asis-tab cu-tab" data-t="dashboard" onclick="cuIr(\'dashboard\')">'
    + 'Resultados</button>'
    + '<button class="asis-tab cu-tab" data-t="programa" onclick="cuIr(\'programa\')">'
    + 'Programa de acción</button>'
    + '</div></div><div id="cu-cuerpo"></div>';
  cuIr(_cuTab);
}

/* ═══════════════════════════════════════════════════════════
   Programa de intervención · Capítulo 8
   Diagnosticar sin plan de acción es la mitad del trabajo: en
   una inspección el informe prueba que evaluaste, el programa
   prueba que actuaste.
   ═══════════════════════════════════════════════════════════ */

const NIV_ACC = {
  organizacional:{ t:'Organizacional', c:'#2EC4B6' },
  grupal:        { t:'Grupal',         c:'#6366F1' },
  individual:    { t:'Individual',     c:'#F4795B' }
};
const EST_ACC = {
  pendiente:  { t:'Pendiente',  c:'#8494A7', bg:'var(--linea-s)' },
  en_proceso: { t:'En proceso', c:'#B45309', bg:'#FEF3E2' },
  hecha:      { t:'Realizada',  c:'#14A085', bg:'#E3F5F0' },
  cancelada:  { t:'Cancelada',  c:'#8494A7', bg:'var(--linea-s)' }
};

async function pintarPrograma(){
  const cont = document.getElementById('cu-cuerpo');
  if(!_cuCamp){ cuIr('campanas'); return; }

  cont.innerHTML = '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando...</p>';
  const { data, error } = await sb.rpc('nom035_programa', { p_campana_id: _cuCamp });
  if(error){ cont.innerHTML = '<p class="cargando">'+error.message+'</p>'; return; }

  if(data.status === 'vacio'){
    cont.innerHTML =
      '<div class="vacio" style="max-width:520px">'
      + '<i class="fas fa-list-check"></i>'
      + '<h3>Sin programa de intervención</h3>'
      + '<p>La Norma obliga a un Programa de intervención cuando el resultado es '
      + 'Medio, Alto o Muy alto (numerales 8.3 a 8.5). El sistema lo propone con '
      + 'las acciones que la Norma pide para los dominios en riesgo, y tú asignas '
      + 'responsables y fechas.</p>'
      + '<button class="btn-pri" style="margin-top:16px" onclick="generarPrograma()">'
      + '<i class="fas fa-wand-magic-sparkles"></i> Generar programa</button></div>';
    return;
  }

  const p = data.programa;
  const acc = data.acciones || [];
  const vencidas = acc.filter(a => a.vencida).length;
  const sinResp = acc.filter(a => !a.responsable && a.estado !== 'cancelada').length;

  // Se agrupa por dominio: la Norma pide analizar cada dominio,
  // y una lista plana de 25 acciones no se puede revisar.
  const grupos = {};
  acc.forEach(a => {
    const k = a.dominio || 'Medidas generales de prevención';
    (grupos[k] = grupos[k] || []).push(a);
  });

  cont.innerHTML =
    '<div class="cu-head"><div><h3>'+p.nombre+'</h3>'
    + '<p>Detonado por nivel '+(p.nivel_origen||'—')+' · desde '
    + new Date(p.inicia+'T12:00').toLocaleDateString('es-MX')+'</p></div>'
    + '<button class="btn-sec-claro" onclick="nuevaAccion(\''+p.id+'\')">'
    + '<i class="fas fa-plus"></i> Agregar acción</button></div>'

    + '<div class="cu-kpis">'
    + '<div class="cu-kpi'+(data.avance===100?' ok':'')+'">'
    + '<b class="num">'+data.avance+'%</b><span>avance</span></div>'
    + '<div class="cu-kpi"><b class="num">'+acc.length+'</b><span>acciones</span></div>'
    + '<div class="cu-kpi"><b class="num" style="color:'
    + (vencidas?'#B91C1C':'var(--txt)')+'">'+vencidas+'</b>'
    + '<span>vencidas</span></div>'
    + '</div>'

    + (sinResp
        ? '<p class="aviso" style="background:#FEF3E2;color:#92400E">'
          + '<i class="fas fa-user-slash" style="color:#B45309"></i>'
          + sinResp+' acción(es) sin responsable. Una acción sin dueño no se '
          + 'ejecuta, y en una inspección se lee como incumplimiento.</p>'
        : '')

    + Object.entries(grupos).map(([dom, lista]) =>
        '<div class="pr-grupo">'
        + '<h4>'+dom+'</h4>'
        + lista.map(a => {
            const e = EST_ACC[a.estado] || EST_ACC.pendiente;
            const n = NIV_ACC[a.nivel] || NIV_ACC.organizacional;
            return '<div class="pr-acc'+(a.vencida?' venc':'')+'" '
              + 'onclick="editarAccion(\''+a.id+'\')">'
              + '<div class="pr-acc-t">'
              + '<span class="pr-niv" style="color:'+n.c+'">'+n.t+'</span>'
              + '<span class="tb-badge" style="color:'+e.c+';background:'+e.bg+'">'
              + e.t+'</span></div>'
              + '<p>'+a.accion+'</p>'
              + '<div class="pr-acc-m">'
              + '<span><i class="fas fa-user"></i>'
              + (a.responsable || 'Sin responsable')+'</span>'
              + (a.meta
                  ? '<span'+(a.vencida?' class="venc"':'')+'>'
                    + '<i class="fas fa-calendar"></i>'
                    + new Date(a.meta+'T12:00').toLocaleDateString('es-MX')+'</span>'
                  : '<span class="falta"><i class="fas fa-calendar"></i>Sin fecha</span>')
              + (a.evidencia
                  ? '<span class="ok"><i class="fas fa-paperclip"></i>Con evidencia</span>'
                  : '')
              + '</div></div>';
          }).join('')
        + '</div>').join('');
}

async function generarPrograma(){
  const { data, error } = await sb.rpc('nom035_generar_programa',
    { p_campana_id: _cuCamp });
  if(error){ toast('error', error.message); return; }

  await modal({
    titulo:'Programa generado',
    subtitulo: data.acciones+' acciones propuestas'
      + (data.requiere_control
          ? ' para los dominios que cruzaron el umbral de riesgo, más las medidas '
            + 'de prevención que la Norma exige siempre.'
          : '. El nivel es '+data.nivel+', así que solo se incluyen las medidas de '
            + 'prevención generales del numeral 8.1: no se requieren medidas de '
            + 'control adicionales.')
      + ' Asigna responsables y fechas antes de activarlo.',
    ok:'Ver programa', cancelar:'' });
  pintarPrograma();
}

async function editarAccion(id){
  const { data } = await sb.rpc('nom035_programa', { p_campana_id: _cuCamp });
  const a = (data.acciones||[]).find(x => x.id === id);
  if(!a) return;

  const { data: emps } = await sb.rpc('listar_empleados',
    { p_buscar:null, p_estatus:'Activo', p_centro_id:null, p_limite:200, p_desde:0 });

  const r = await modal({
    titulo:'Acción del programa',
    subtitulo: a.dominio || 'Medida general de prevención',
    campos:[
      { k:'accion', label:'Acción', t:'area', req:true, valor:a.accion },
      { k:'nivel_accion', label:'Nivel de intervención', t:'select',
        opciones:[['organizacional','Organizacional (política y organización del trabajo)'],
                  ['grupal','Grupal (equipos y relaciones)'],
                  ['individual','Individual (persona específica)']],
        valor:a.nivel,
        nota:'El numeral 8.4 pide ubicar cada acción en su plano. No todo es capacitación.' },
      { k:'responsable_id', label:'Responsable', t:'select',
        opciones:[['','Sin asignar']].concat(
          (emps?.filas||[]).map(e => [e.id, e.nombre])),
        valor:a.responsable_id || '' },
      { k:'fecha_meta', label:'Fecha compromiso', t:'fecha', valor:a.meta || '',
        ancho:'mitad' },
      { k:'estado', label:'Estado', t:'select',
        opciones:[['pendiente','Pendiente'],['en_proceso','En proceso'],
                  ['hecha','Realizada'],['cancelada','Cancelada']],
        valor:a.estado, ancho:'mitad' },
      { k:'evidencia_nota', label:'Evidencia', t:'area', valor:a.nota || '',
        nota:'Describe el respaldo: minuta, lista de asistencia, comunicado. '
          + 'Obligatorio para marcarla como realizada.' }
    ]
  });
  if(!r) return;

  const { error } = await sb.rpc('nom035_accion_guardar', { p_id:id, p_datos:r });
  if(error){ toast('error', error.message); return; }
  toast('ok','Acción actualizada');
  pintarPrograma();
}

async function nuevaAccion(progId){
  const r = await modal({
    titulo:'Nueva acción',
    subtitulo:'Agrega una acción propia al programa.',
    campos:[
      { k:'accion', label:'Acción', t:'area', req:true },
      { k:'dominio', label:'Responde al dominio', t:'texto',
        nota:'Déjalo vacío si es una medida general.' },
      { k:'nivel', label:'Nivel', t:'select',
        opciones:[['organizacional','Organizacional'],['grupal','Grupal'],
                  ['individual','Individual']], valor:'organizacional' }
    ]
  });
  if(!r) return;
  const { error } = await sb.rpc('nom035_accion_nueva', {
    p_programa_id: progId, p_accion: r.accion,
    p_dominio: r.dominio || null, p_nivel: r.nivel });
  if(error){ toast('error', error.message); return; }
  toast('ok','Acción agregada');
  pintarPrograma();
}

/* Evidencia de difusión · 7.8 */
async function verDifusion(){
  const { data, error } = await sb.rpc('nom035_evidencia_difusion',
    { p_campana_id: _cuCamp });
  if(error){ toast('error', error.message); return; }

  const url = location.origin + '/resultados.html';

  panel({
    titulo:'Difusión de resultados',
    subtitulo:'Numeral 7.8 · evidencia de que la información llegó al personal',
    html:
      '<div class="aviso" style="margin-bottom:16px">'
      + '<i class="fas fa-circle-info"></i>'
      + '<div>Comparte esta dirección con el personal. Cada consulta se registra '
      + 'con nombre y fecha: <b>esa bitácora es la evidencia de difusión</b>. '
      + 'Un PDF en una carpeta no prueba que alguien lo abrió.</div></div>'
      + '<div class="dif-url">'
      + '<code>'+url+'</code>'
      + '<button onclick="copiar(\''+url+'\')"><i class="fas fa-link"></i></button>'
      + '</div>'
      + '<div class="cu-kpis" style="margin-top:16px">'
      + '<div class="cu-kpi"><b class="num">'+data.personas+'</b>'
      + '<span>personas</span></div>'
      + '<div class="cu-kpi"><b class="num">'+data.consultas+'</b>'
      + '<span>consultas</span></div></div>'
      + (data.detalle.length
          ? '<h4 class="cu-h">Bitácora</h4><div class="cu-pend">'
            + data.detalle.map(d =>
                '<div class="cu-pend-f"><div><b>'+(d.nombre||'—')+'</b>'
                + '<span>'+new Date(d.cuando).toLocaleString('es-MX')+'</span></div>'
                + '</div>').join('')
            + '</div>'
          : '<p class="cu-nota" style="margin-top:14px">Nadie ha consultado los '
            + 'resultados todavía. Comparte la dirección con el personal.</p>')
  });
}