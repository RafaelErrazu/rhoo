// ═══════════════════════════════════════════════════════════
//  RHoo! · Módulo Turnos
// ═══════════════════════════════════════════════════════════

let _tuTab = 'calendario';
let _tuCat = null;
let _calDesde = null;

const DIAS_SEM = ['Do','Lu','Ma','Mi','Ju','Vi','Sá'];

async function catTurnos(refrescar){
  if(_tuCat && !refrescar) return _tuCat;
  const { data, error } = await sb.rpc('catalogo_turnos');
  if(error) throw error;
  _tuCat = data;
  return data;
}

/* ── Calendario ── */
async function pintarCalendario(){
  const cont = document.getElementById('tu-cuerpo');
  cont.innerHTML = '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando...</p>';

  // Arranca el lunes de la semana en curso: un calendario que
  // empieza "hoy" parte la semana y se lee peor.
  if(!_calDesde){
    const h = new Date();
    const dow = (h.getDay() + 6) % 7;      // 0 = lunes
    h.setDate(h.getDate() - dow);
    _calDesde = h.toLocaleDateString('sv-SE');
  }
  const desde = _calDesde;
  const hasta = new Date(new Date(desde + 'T12:00').getTime() + 13*86400000)
                  .toLocaleDateString('sv-SE');

  const { data, error } = await sb.rpc('calendario_turnos', {
    p_desde: desde, p_hasta: hasta, p_centro_id: null });

  if(error){ cont.innerHTML = '<p class="cargando">'+error.message+'</p>'; return; }

  const filas = data.filas || [];
  if(!filas.length){
    cont.innerHTML = '<div class="vacio"><i class="fas fa-calendar-days"></i>'
      + '<h3>Sin personal</h3><p>Da de alta empleados para ver su calendario.</p></div>';
    return;
  }

  const cols = filas[0].dias;
  const hoy = new Date().toLocaleDateString('sv-SE');

  cont.innerHTML =
    '<div class="cal-nav">'
    + '<button onclick="calMover(-14)"><i class="fas fa-chevron-left"></i></button>'
    + '<span>'+fechaCorta(desde)+' al '+fechaCorta(hasta)+'</span>'
    + '<button onclick="calMover(14)"><i class="fas fa-chevron-right"></i></button>'
    + '<button class="cal-hoy" onclick="calHoy()">Hoy</button>'
    + '</div>'
    + '<div class="cal-scroll"><table class="cal">'
    + '<thead><tr><th class="cal-nom">Colaborador</th>'
    + cols.map(d => {
        const f = new Date(d.f + 'T12:00');
        const finde = f.getDay() === 0 || f.getDay() === 6;
        return '<th class="'+(finde?'cal-finde':'')
          + (d.f === hoy ? ' cal-hoy-col':'')+'">'
          + '<span>'+DIAS_SEM[f.getDay()]+'</span>'
          + '<b>'+f.getDate()+'</b></th>';
      }).join('')
    + '</tr></thead><tbody>'
    + filas.map(r =>
        '<tr><td class="cal-nom">'+r.nombre
        + '<span>#'+r.no+'</span></td>'
        + r.dias.map(d =>
            '<td class="cal-c'+(d.fest?' cal-fest':'')+'"'
            + (d.col && d.c !== 'D' ? ' style="--c:'+d.col+'"' : '')+'>'
            + '<span class="'+(d.c === 'D' ? 'cal-d' : 'cal-t')+'">'
            + (d.fest && d.c === 'D' ? 'F' : d.c)+'</span></td>'
          ).join('')
        + '</tr>'
      ).join('')
    + '</tbody></table></div>'
    + '<div class="cal-leyenda">'
    + (_tuCat?.turnos||[]).filter(t => t.activo).map(t =>
        '<span><i style="background:'+t.color+'"></i>'+t.clave+' · '+t.nombre+'</span>'
      ).join('')
    + '<span><i class="cal-li-d"></i>D · Descanso</span>'
    + '<span><i class="cal-li-f"></i>F · Festivo</span>'
    + '</div>';
}

const fechaCorta = s => new Date(s + 'T12:00')
  .toLocaleDateString('es-MX',{day:'numeric', month:'short'});

function calMover(d){
  _calDesde = new Date(new Date(_calDesde + 'T12:00').getTime() + d*86400000)
                .toLocaleDateString('sv-SE');
  pintarCalendario();
}
function calHoy(){ _calDesde = null; pintarCalendario(); }

/* ── Catálogo de turnos ── */
async function pintarTurnos(){
  const cont = document.getElementById('tu-cuerpo');
  const cat = await catTurnos(true);

  cont.innerHTML =
    '<div class="tu-head">'
    + '<p class="aviso" style="margin:0;flex:1"><i class="fas fa-circle-info"></i>'
    + 'La tolerancia de cada turno manda sobre la general de Configuración: '
    + 'un nocturno suele necesitar más margen que un matutino.</p>'
    + '<button class="btn-pri" onclick="editarTurno(null)">'
    + '<i class="fas fa-plus"></i> Nuevo turno</button></div>'
    + '<div class="tu-lista">'
    + cat.turnos.map(t =>
        '<div class="tu-item'+(t.activo?'':' off')+'" onclick="editarTurno(\''+t.id+'\')">'
        + '<span class="tu-color" style="background:'+t.color+'">'+t.clave+'</span>'
        + '<div class="tu-info"><b>'+t.nombre+'</b>'
        + '<span>'+t.entrada.slice(0,5)+' a '+t.salida.slice(0,5)
        + (t.cruza ? ' (+1 día)' : '')
        + ' · '+t.horas+' h efectivas'
        + (t.comida ? ' · '+t.comida+' min comida' : '')+'</span></div>'
        + '<div class="tu-meta">'
        + '<span>tol. '+t.tolerancia+' min</span>'
        + '<b>'+t.asignados+'</b><em>asignados</em></div>'
        + '</div>'
      ).join('')
    + '</div>'

    + '<div class="tu-head" style="margin-top:26px">'
    + '<p class="aviso" style="margin:0;flex:1"><i class="fas fa-circle-info"></i>'
    + 'Un patrón es una secuencia que se repite. Sirve para rotación semanal, '
    + '4x3, 2x2 o cualquier esquema, sin configurar cada empleado por separado.</p>'
    + '<button class="btn-pri" onclick="editarPatron(null)">'
    + '<i class="fas fa-plus"></i> Nuevo patrón</button></div>'
    + ((cat.patrones||[]).length
        ? '<div class="tu-lista">'
          + cat.patrones.map(p =>
              '<div class="tu-item" onclick="editarPatron(\''+p.id+'\')">'
              + '<div class="tu-ciclo">'
              + (p.claves||[]).map(c =>
                  '<span class="'+(c==='D'?'cal-d':'cal-t')+'">'+c+'</span>'
                ).join('')
              + '</div>'
              + '<div class="tu-info"><b>'+p.nombre+'</b>'
              + '<span>ciclo de '+p.largo+' '+(p.unidad==='semana'?'semanas':'días')
              + '</span></div>'
              + '<div class="tu-meta"><b>'+p.asignados+'</b><em>asignados</em></div>'
              + '</div>'
            ).join('')
          + '</div>'
        : '<p class="ub-nada">Sin patrones. Con turnos fijos alcanza si nadie rota.</p>');
}

async function editarTurno(id){
  const cat = await catTurnos();
  const t = id ? cat.turnos.find(x => x.id === id) : null;

  const r = await modal({
    titulo: t ? 'Editar turno' : 'Nuevo turno',
    subtitulo: t ? t.nombre : 'Define el horario y sus tolerancias.',
    campos: [
      ...(t ? [] : [{ k:'clave', label:'Clave', t:'texto', req:true, max:6,
        ancho:'mitad', nota:'Corta: MAT, VES, NOC. No se puede cambiar después.' }]),
      { k:'nombre', label:'Nombre', t:'texto', req:true, valor:t?.nombre,
        ancho: t ? 'full' : 'mitad' },
      { k:'entrada', label:'Hora de entrada', t:'texto', req:true,
        valor: t?.entrada?.slice(0,5) || '09:00', ancho:'mitad',
        patron:'\\d{2}:\\d{2}', nota:'Formato 24 h, ej. 22:00' },
      { k:'salida', label:'Hora de salida', t:'texto', req:true,
        valor: t?.salida?.slice(0,5) || '18:00', ancho:'mitad',
        patron:'\\d{2}:\\d{2}',
        nota:'Si es menor que la entrada, el turno cruza medianoche.' },
      { k:'comida', label:'Minutos de comida', t:'num', valor:t?.comida ?? 60,
        ancho:'mitad' },
      { k:'comida_computa', label:'La comida cuenta como jornada', t:'select',
        opciones:[['false','No se cuenta'],['true','Sí se cuenta']],
        valor: String(t?.comida_computa ?? false), ancho:'mitad',
        nota:'Solo cuenta si el trabajador no puede salir del centro (art. 63 LFT).' },
      { k:'tolerancia', label:'Tolerancia de retardo', t:'num',
        valor:t?.tolerancia ?? 10, ancho:'mitad', nota:'minutos' },
      { k:'min_falta', label:'Retraso que ya es falta', t:'num',
        valor:t?.min_falta ?? 60, ancho:'mitad', nota:'minutos' },
      { k:'color', label:'Color en el calendario', t:'select',
        opciones:[['#2EC4B6','Turquesa'],['#F4795B','Coral'],['#6366F1','Índigo'],
                  ['#D97706','Ámbar'],['#14A085','Verde'],['#8494A7','Gris']],
        valor:t?.color || '#2EC4B6' }
    ]
  });
  if(!r) return;

  r.comida_computa = r.comida_computa === 'true';
  const { error } = await sb.rpc('guardar_turno', { p_id: id, p_datos: r });
  if(error){ toast('error', error.message); return; }
  toast('ok', 'Turno guardado');
  pintarTurnos();
}

/* Constructor visual del patrón. La secuencia es uuid[] en la
   base, pero nadie va a escribir eso: aquí se toca cada día del
   ciclo y se elige turno o descanso. */
let _patCiclo = [];

async function editarPatron(id){
  const cat = await catTurnos();
  const p = id ? cat.patrones.find(x => x.id === id) : null;
  _patCiclo = p ? [...(p.claves||[])] : ['D'];

  panel({
    titulo: p ? 'Editar patrón' : 'Nuevo patrón de rotación',
    subtitulo: 'Arma la secuencia que se repite.',
    html: '<div id="pat-editor"></div>',
    acciones:
      '<button class="btn-sec-claro" onclick="cerrarPanel()">Cancelar</button>'
      + '<button class="btn-pri" onclick="guardarPatron(\''+(id||'')+'\')">Guardar</button>'
  });

  pintarPatEditor(p, cat.turnos.filter(t => t.activo));
}

function pintarPatEditor(p, turnos){
  const cont = document.getElementById('pat-editor');
  if(!cont) return;

  const seguidos = (() => {
    let max = 0, n = 0;
    _patCiclo.forEach(c => { if(c === 'D'){ n = 0 } else { n++; max = Math.max(max,n) } });
    return max;
  })();

  cont.innerHTML =
    '<div class="pat-campos">'
    + '<label class="md-campo full"><span>Nombre <b>*</b></span>'
    + '<input type="text" id="pat-nombre" value="'+(p?.nombre||'')+'" '
    + 'placeholder="Rotativo 3 turnos"></label>'
    + '<label class="md-campo full"><span>La secuencia avanza por</span>'
    + '<select id="pat-unidad">'
    + '<option value="dia"'+(p?.unidad!=='semana'?' selected':'')+'>Día</option>'
    + '<option value="semana"'+(p?.unidad==='semana'?' selected':'')+'>Semana</option>'
    + '</select>'
    + '<em>Por semana: cada posición dura 7 días. Por día: cambia diario, '
    + 'como en un 4x3.</em></label>'
    + '</div>'

    + '<h4 class="ex-sec" style="margin:18px 0 8px">Ciclo ('+_patCiclo.length
    + ' '+(p?.unidad==='semana'?'semanas':'días')+')</h4>'
    + '<div class="pat-ciclo">'
    + _patCiclo.map((c,i) =>
        '<div class="pat-slot">'
        + '<span class="pat-n">'+(i+1)+'</span>'
        + '<select onchange="patSet('+i+',this.value)">'
        + '<option value="D"'+(c==='D'?' selected':'')+'>Descanso</option>'
        + turnos.map(t =>
            '<option value="'+t.clave+'"'+(c===t.clave?' selected':'')+'>'
            + t.clave+'</option>').join('')
        + '</select>'
        + (_patCiclo.length > 1
            ? '<button class="pat-x" onclick="patQuitar('+i+')" '
              + 'aria-label="Quitar"><i class="fas fa-xmark"></i></button>'
            : '')
        + '</div>'
      ).join('')
    + '<button class="pat-add" onclick="patAgregar()">'
    + '<i class="fas fa-plus"></i></button>'
    + '</div>'

    // Aviso, no bloqueo: un rol quincenal con descansos
    // acumulados puede ser legítimo.
    + (seguidos > 6
        ? '<p class="pat-aviso"><i class="fas fa-scale-balanced"></i>'
          + seguidos + ' días de trabajo seguidos. El artículo 69 de la LFT pide '
          + 'un día de descanso por cada seis trabajados: verifica que este '
          + 'esquema lo compense.</p>'
        : '')

    + '<div class="pat-vista">'
    + '<h4 class="ex-sec" style="margin-bottom:8px">Cómo se ve en 4 semanas</h4>'
    + '<div class="pat-prev">'
    + Array.from({length:28}, (_,d) => {
        const idx = (p?.unidad === 'semana') ? Math.floor(d/7) : d;
        const c = _patCiclo[idx % _patCiclo.length];
        return '<span class="'+(c==='D'?'cal-d':'cal-t')+'">'+c+'</span>';
      }).join('')
    + '</div></div>';
}

function patSet(i, v){ _patCiclo[i] = v; refrescarPatEditor(); }
function patQuitar(i){ _patCiclo.splice(i,1); refrescarPatEditor(); }
function patAgregar(){ _patCiclo.push('D'); refrescarPatEditor(); }

function refrescarPatEditor(){
  // Se conserva lo capturado antes de repintar
  const nom = document.getElementById('pat-nombre')?.value || '';
  const uni = document.getElementById('pat-unidad')?.value || 'dia';
  pintarPatEditor({ nombre:nom, unidad:uni, claves:_patCiclo },
                  _tuCat.turnos.filter(t => t.activo));
}

async function guardarPatron(id){
  const nombre = document.getElementById('pat-nombre').value.trim();
  if(!nombre){ toast('error','El patrón necesita un nombre'); return; }
  const unidad = document.getElementById('pat-unidad').value;

  const { data, error } = await sb.rpc('guardar_patron', {
    p_id: id || null, p_nombre: nombre, p_claves: _patCiclo, p_unidad: unidad });

  if(error){ toast('error', error.message); return; }
  cerrarPanel();
  toast('ok', 'Patrón guardado');
  if(data.aviso_lft) modal({ titulo:'Revisa el descanso semanal',
    subtitulo:data.aviso_lft, ok:'Entendido', cancelar:'' });
  pintarTurnos();
}

/* ── Asignar turno a un empleado (se usa desde el expediente) ── */
async function asignarTurnoA(empId, nombre){
  const cat = await catTurnos();
  const activos = cat.turnos.filter(t => t.activo);

  const r = await modal({
    titulo: 'Asignar turno',
    subtitulo: nombre + '. La asignación anterior se cierra automáticamente; '
      + 'el histórico se conserva.',
    ok: 'Asignar',
    campos: [
      { k:'tipo', label:'Esquema', t:'select', req:true,
        opciones: [['fijo','Turno fijo']].concat(
          (cat.patrones||[]).length ? [['patron','Patrón de rotación']] : []),
        valor:'fijo' },
      { k:'turno', label:'Turno fijo', t:'select',
        opciones: activos.map(t => [t.id, t.clave+' · '+t.nombre
          +' ('+t.entrada.slice(0,5)+'-'+t.salida.slice(0,5)+')']),
        nota:'Se usa si el esquema es turno fijo.' },
      { k:'patron', label:'Patrón', t:'select',
        opciones: (cat.patrones||[]).map(p => [p.id, p.nombre]),
        nota:'Se usa si el esquema es patrón.' },
      { k:'desde', label:'Vigente desde', t:'fecha', req:true,
        valor: new Date().toLocaleDateString('sv-SE'), ancho:'mitad' },
      { k:'descanso', label:'Día de descanso semanal', t:'select',
        opciones: DIAS_SEM.map((d,i) => [String(i), d==='Do'?'Domingo':
          d==='Lu'?'Lunes':d==='Ma'?'Martes':d==='Mi'?'Miércoles':
          d==='Ju'?'Jueves':d==='Vi'?'Viernes':'Sábado']),
        valor:'0', ancho:'mitad',
        nota:'Solo aplica a turno fijo. En patrón, el descanso va en la secuencia.' }
    ]
  });
  if(!r) return;

  const { error } = await sb.rpc('asignar_turno', {
    p_empleado_id: empId,
    p_turno_id:  r.tipo === 'fijo'   ? r.turno  : null,
    p_patron_id: r.tipo === 'patron' ? r.patron : null,
    p_desde: r.desde,
    p_descanso: r.tipo === 'fijo' ? [Number(r.descanso)] : [],
    p_ancla: r.tipo === 'patron' ? r.desde : null
  });

  if(error){ toast('error', error.message); return; }
  toast('ok', 'Turno asignado');
  cerrarPanel();
  if(typeof verEmpleado === 'function') verEmpleado(empId);
}

function tuIr(tab){
  _tuTab = tab;
  document.querySelectorAll('.tu-tab').forEach(b =>
    b.classList.toggle('on', b.dataset.tab === tab));
  if(tab === 'calendario') pintarCalendario();
  if(tab === 'catalogo')   pintarTurnos();
}

async function moduloTurnos(){
  document.getElementById('contenido').innerHTML =
    '<div class="asis-barra"><div class="asis-tabs">'
    + '<button class="asis-tab tu-tab on" data-tab="calendario" onclick="tuIr(\'calendario\')">'
    + 'Calendario</button>'
    + '<button class="asis-tab tu-tab" data-tab="catalogo" onclick="tuIr(\'catalogo\')">'
    + 'Turnos y patrones</button>'
    + '</div></div><div id="tu-cuerpo"></div>';
  await catTurnos(true);
  tuIr(_tuTab);
}