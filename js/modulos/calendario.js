// ═══════════════════════════════════════════════════════════
//  RHoo! · Calendario
//  Dos vistas porque son dos preguntas distintas: el mes sirve
//  para planear, la tira por persona para detectar traslapes.
// ═══════════════════════════════════════════════════════════

const CLASES_CAL = {
  ausencia:    { t:'Ausencias',    i:'fa-umbrella-beach' },
  festivo:     { t:'Festivos',     i:'fa-star' },
  cumple:      { t:'Cumpleaños',   i:'fa-cake-candles' },
  aniversario: { t:'Aniversarios', i:'fa-trophy' },
  campana:     { t:'Campañas',     i:'fa-clipboard-list' },
  accion:      { t:'Compromisos',  i:'fa-list-check' }
};

let _calMes = null;          // primer día del mes visible
let _calVista = 'mes';
let _calEventos = [];
let _calFiltros = new Set(Object.keys(CLASES_CAL));

const DIAS_CORTOS = ['Lu','Ma','Mi','Ju','Vi','Sá','Do'];
const MESES = ['enero','febrero','marzo','abril','mayo','junio','julio',
               'agosto','septiembre','octubre','noviembre','diciembre'];

const iso = d => d.toLocaleDateString('sv-SE');

function mesActual(){
  if(!_calMes){
    const h = new Date();
    _calMes = new Date(h.getFullYear(), h.getMonth(), 1);
  }
  return _calMes;
}

async function cargarCalendario(){
  const m = mesActual();
  // Se pide el mes completo más los días de relleno de la
  // rejilla: sin eso, un evento del lunes anterior no se pinta
  // en la primera fila y el calendario se ve incompleto.
  const primero = new Date(m.getFullYear(), m.getMonth(), 1);
  const ultimo  = new Date(m.getFullYear(), m.getMonth() + 1, 0);
  const desde = new Date(primero); desde.setDate(desde.getDate() - 7);
  const hasta = new Date(ultimo);  hasta.setDate(hasta.getDate() + 7);

  const { data, error } = await sb.rpc('calendario', {
    p_desde: iso(desde), p_hasta: iso(hasta),
    p_centro_id: null, p_solo_mias: false });

  if(error){ toast('error', error.message); return false; }
  _calEventos = data.eventos || [];
  return true;
}

/* Expande un evento de varios días a las fechas que ocupa. */
function eventosPorDia(){
  const mapa = {};
  _calEventos.forEach(e => {
    if(!_calFiltros.has(e.clase)) return;
    const d1 = new Date(e.desde + 'T12:00');
    const d2 = new Date(e.hasta + 'T12:00');
    for(let d = new Date(d1); d <= d2; d.setDate(d.getDate() + 1)){
      const k = iso(d);
      (mapa[k] = mapa[k] || []).push(e);
    }
  });
  return mapa;
}

function pintarCalendario(){
  const m = mesActual();
  const hoy = iso(new Date());
  const porDia = eventosPorDia();

  const primero = new Date(m.getFullYear(), m.getMonth(), 1);
  const ultimo  = new Date(m.getFullYear(), m.getMonth() + 1, 0);

  // La semana arranca en lunes: es la convención en México y es
  // como la gente planea el trabajo.
  const offset = (primero.getDay() + 6) % 7;
  const inicio = new Date(primero);
  inicio.setDate(inicio.getDate() - offset);

  const celdas = [];
  const cursor = new Date(inicio);
  while(cursor <= ultimo || celdas.length % 7 !== 0){
    celdas.push(new Date(cursor));
    cursor.setDate(cursor.getDate() + 1);
    if(celdas.length > 42) break;
  }

  document.getElementById('cal-cuerpo').innerHTML =
    '<div class="cal-nav">'
    + '<button onclick="calMes(-1)"><i class="fas fa-chevron-left"></i></button>'
    + '<span>'+MESES[m.getMonth()]+' '+m.getFullYear()+'</span>'
    + '<button onclick="calMes(1)"><i class="fas fa-chevron-right"></i></button>'
    + '<button class="cal-hoy" onclick="calHoyMes()">Hoy</button>'
    + '</div>'

    // Filtros por clase: con seis tipos encima, el calendario se
    // vuelve ilegible si no se pueden apagar.
    + '<div class="cal-filtros">'
    + Object.entries(CLASES_CAL).map(([k,c]) =>
        '<button class="cal-chip'+(_calFiltros.has(k)?' on':'')+'" '
        + 'onclick="calFiltro(\''+k+'\')">'
        + '<i class="fas '+c.i+'"></i>'+c.t+'</button>').join('')
    + '</div>'

    + '<div class="cal-rejilla">'
    + DIAS_CORTOS.map(d => '<div class="cal-dow">'+d+'</div>').join('')
    + celdas.map(d => {
        const k = iso(d);
        const fuera = d.getMonth() !== m.getMonth();
        const evs = porDia[k] || [];
        const finde = d.getDay() === 0 || d.getDay() === 6;
        return '<div class="cal-celda'+(fuera?' fuera':'')
          + (k === hoy ? ' hoy':'')+(finde?' finde':'')+'" '
          + (evs.length ? 'onclick="verDia(\''+k+'\')"' : '')+'>'
          + '<span class="cal-num">'+d.getDate()+'</span>'
          + '<div class="cal-evs">'
          + evs.slice(0,3).map(e =>
              '<span class="cal-ev'+(e.propio?' propio':'')+'" '
              + 'style="--c:'+(e.color||'#8494A7')+'" title="'+esc(e.titulo)+'">'
              + esc(e.clase === 'ausencia' && e.nombre
                    ? e.nombre.split(' ')[0] + ' · ' + e.titulo
                    : e.titulo)+'</span>').join('')
          + (evs.length > 3
              ? '<span class="cal-mas">+'+(evs.length-3)+' más</span>' : '')
          + '</div></div>';
      }).join('')
    + '</div>';
}

function esc(s){
  return (s==null?'':String(s))
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/"/g,'&quot;');
}

async function calMes(n){
  const m = mesActual();
  _calMes = new Date(m.getFullYear(), m.getMonth() + n, 1);
  if(await cargarCalendario()) pintarVista();
}

async function calHoyMes(){
  _calMes = null;
  if(await cargarCalendario()) pintarVista();
}

function calFiltro(k){
  if(_calFiltros.has(k)) _calFiltros.delete(k);
  else _calFiltros.add(k);
  pintarVista();
}

function verDia(fecha){
  const evs = (eventosPorDia()[fecha] || []);
  const d = new Date(fecha + 'T12:00');

  panel({
    titulo: d.toLocaleDateString('es-MX',
      { weekday:'long', day:'numeric', month:'long' }),
    subtitulo: evs.length + ' evento(s)',
    html: '<div class="dia-lista">'
      + evs.map(e => {
          const c = CLASES_CAL[e.clase] || { i:'fa-circle' };
          return '<div class="dia-ev">'
            + '<i class="fas '+c.i+'" style="color:'+(e.color||'#8494A7')+'"></i>'
            + '<div><b>'+esc(e.titulo)+'</b>'
            + (e.nombre && e.clase === 'ausencia'
                ? '<span>'+esc(e.nombre)+'</span>' : '')
            + (e.desde !== e.hasta
                ? '<span>Del '+e.desde+' al '+e.hasta
                  + (e.dias ? ' · '+e.dias+' día(s)' : '')+'</span>'
                : '')
            + (e.destacado ? '<span class="dia-dest">Aniversario destacado</span>' : '')
            + '</div></div>';
        }).join('')
      + '</div>'
  });
}

/* ── Vista de equipo: tira horizontal por persona ── */
function pintarEquipo(){
  const m = mesActual();
  const hoy = iso(new Date());
  const ultimo = new Date(m.getFullYear(), m.getMonth() + 1, 0).getDate();

  // Solo ausencias: es la vista para detectar traslapes, y meter
  // cumpleaños aquí sería ruido.
  const aus = _calEventos.filter(e => e.clase === 'ausencia');

  if(!aus.length){
    document.getElementById('cal-cuerpo').innerHTML =
      '<div class="cal-nav">'
      + '<button onclick="calMes(-1)"><i class="fas fa-chevron-left"></i></button>'
      + '<span>'+MESES[m.getMonth()]+' '+m.getFullYear()+'</span>'
      + '<button onclick="calMes(1)"><i class="fas fa-chevron-right"></i></button>'
      + '<button class="cal-hoy" onclick="calHoyMes()">Hoy</button></div>'
      + '<div class="vacio"><i class="fas fa-calendar-check"></i>'
      + '<h3>Sin ausencias este mes</h3>'
      + '<p>Cuando alguien tenga vacaciones o permisos aprobados, aparecerán '
      + 'aquí para ver traslapes de un vistazo.</p></div>';
    return;
  }

  // Agrupado por persona
  const porPersona = {};
  aus.forEach(e => {
    const k = e.nombre || 'Sin nombre';
    (porPersona[k] = porPersona[k] || []).push(e);
  });

  const dias = Array.from({length:ultimo}, (_,i) =>
    new Date(m.getFullYear(), m.getMonth(), i+1));

  document.getElementById('cal-cuerpo').innerHTML =
    '<div class="cal-nav">'
    + '<button onclick="calMes(-1)"><i class="fas fa-chevron-left"></i></button>'
    + '<span>'+MESES[m.getMonth()]+' '+m.getFullYear()+'</span>'
    + '<button onclick="calMes(1)"><i class="fas fa-chevron-right"></i></button>'
    + '<button class="cal-hoy" onclick="calHoyMes()">Hoy</button></div>'

    + '<div class="eq-scroll"><table class="eq-cal">'
    + '<thead><tr><th class="eq-nom">Colaborador</th>'
    + dias.map(d => {
        const finde = d.getDay() === 0 || d.getDay() === 6;
        return '<th class="'+(finde?'eq-finde':'')
          + (iso(d) === hoy ? ' eq-hoy':'')+'">'+d.getDate()+'</th>';
      }).join('')
    + '</tr></thead><tbody>'
    + Object.entries(porPersona).map(([nombre, evs]) =>
        '<tr><td class="eq-nom">'+esc(nombre)+'</td>'
        + dias.map(d => {
            const k = iso(d);
            const e = evs.find(x => k >= x.desde && k <= x.hasta);
            const finde = d.getDay() === 0 || d.getDay() === 6;
            return '<td class="'+(finde?'eq-finde':'')+'">'
              + (e ? '<span class="eq-b" style="background:'+(e.color||'#8494A7')
                     + '" title="'+esc(e.titulo)+'"></span>' : '')
              + '</td>';
          }).join('')
        + '</tr>').join('')
    + '</tbody></table></div>'

    // Traslapes: el dato que esta vista existe para dar
    + (() => {
        const conteo = {};
        aus.forEach(e => {
          const d1 = new Date(e.desde+'T12:00'), d2 = new Date(e.hasta+'T12:00');
          for(let d = new Date(d1); d <= d2; d.setDate(d.getDate()+1)){
            const k = iso(d);
            if(d.getMonth() === m.getMonth()) conteo[k] = (conteo[k]||0) + 1;
          }
        });
        const picos = Object.entries(conteo).filter(([,n]) => n >= 3)
          .sort((a,b) => b[1] - a[1]).slice(0,5);
        return picos.length
          ? '<div class="eq-alerta">'
            + '<h4><i class="fas fa-users-slash"></i>Días con más ausencias</h4>'
            + picos.map(([f,n]) =>
                '<span>'+new Date(f+'T12:00').toLocaleDateString('es-MX',
                  {weekday:'short', day:'numeric', month:'short'})
                + ' · <b>'+n+' personas</b></span>').join('')
            + '</div>'
          : '';
      })();
}

function pintarVista(){
  if(_calVista === 'mes') pintarCalendario();
  else pintarEquipo();
}

function calVista(v){
  _calVista = v;
  document.querySelectorAll('.cal-tab').forEach(b =>
    b.classList.toggle('on', b.dataset.v === v));
  pintarVista();
}

async function moduloCalendario(){
  document.getElementById('contenido').innerHTML =
    '<div class="asis-barra"><div class="asis-tabs">'
    + '<button class="asis-tab cal-tab on" data-v="mes" onclick="calVista(\'mes\')">'
    + 'Mes</button>'
    + '<button class="asis-tab cal-tab" data-v="equipo" onclick="calVista(\'equipo\')">'
    + 'Ausencias del equipo</button>'
    + '</div></div>'
    + '<div id="cal-cuerpo"><p class="cargando">'
    + '<i class="fas fa-spinner fa-spin"></i> Cargando...</p></div>';

  if(await cargarCalendario()) pintarVista();
}

/* ═══════════════════════════════════════════════════════════
   Tablero de Inicio · el resumen del día
   ═══════════════════════════════════════════════════════════ */
async function moduloInicio(){
  const cont = document.getElementById('contenido');
  cont.innerHTML = '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando...</p>';

  const { data, error } = await sb.rpc('hoy_resumen');
  if(error){ cont.innerHTML = '<p class="cargando">'+error.message+'</p>'; return; }

  const nombre = (Sesion.perfil.nombre || '').split(' ')[0];
  const h = new Date().getHours();
  const saludo = h < 12 ? 'Buenos días' : h < 19 ? 'Buenas tardes' : 'Buenas noches';

  cont.innerHTML =
    '<div class="in-saludo">'
    + '<h2>'+saludo+', '+nombre+'</h2>'
    + '<p>'+new Date().toLocaleDateString('es-MX',
        {weekday:'long', day:'numeric', month:'long'})
    + (data.festivo ? ' · <b>'+data.festivo+'</b>' : '')+'</p></div>'

    // Lo que exige acción, primero
    + (data.por_autorizar > 0
        ? '<div class="in-accion" onclick="irA(\'incidencias\')">'
          + '<i class="fas fa-clipboard-check"></i>'
          + '<div><b>'+data.por_autorizar+' solicitud(es) por autorizar</b>'
          + '<span>Alguien está esperando tu respuesta</span></div>'
          + '<i class="fas fa-chevron-right"></i></div>'
        : '')

    + '<div class="in-grid">'

    + '<div class="in-card">'
    + '<h4><i class="fas fa-user-clock"></i>Hoy no están</h4>'
    + ((data.ausentes||[]).length
        ? '<div class="in-lista">'
          + data.ausentes.map(a =>
              '<div><b>'+esc(a.nombre)+'</b>'
              + '<span>'+esc(a.tipo)+' · hasta el '
              + new Date(a.hasta+'T12:00').toLocaleDateString('es-MX',
                  {day:'numeric', month:'short'})+'</span></div>').join('')
          + '</div>'
        : '<p class="in-vacio">Todo el equipo presente</p>')
    + '</div>'

    + ((data.cumples||[]).length || (data.aniversarios||[]).length
        ? '<div class="in-card in-celebra">'
          + '<h4><i class="fas fa-cake-candles"></i>Para celebrar</h4>'
          + '<div class="in-lista">'
          + (data.cumples||[]).map(n =>
              '<div><b>'+esc(n)+'</b><span>Cumple años hoy</span></div>').join('')
          + (data.aniversarios||[]).map(a =>
              '<div><b>'+esc(a.nombre)+'</b><span>'+a.anios+' año'
              + (a.anios===1?'':'s')+' en la empresa</span></div>').join('')
          + '</div></div>'
        : '')

    + '<div class="in-card in-link" onclick="irA(\'calendario\')">'
    + '<h4><i class="fas fa-calendar-days"></i>Calendario</h4>'
    + '<p class="in-vacio">Ausencias, festivos y celebraciones del mes.</p>'
    + '</div>'

    + '</div>';
}