// ═══════════════════════════════════════════════════════════
//  RHoo! · Módulo Asistencia
//  Una pantalla, dos usos: el colaborador registra, RH observa.
// ═══════════════════════════════════════════════════════════

let _asisTab = 'dia';
let _miDia   = null;
let _geo     = null;     // { lat, lng, precision } o null
let _geoErr  = null;
let _mapa    = null;     // instancia de Leaflet

const EST_ASIS = {
  completa:   { txt:'A tiempo',    color:'var(--ok)',      bg:'#E3F5F0' },
  retardo:    { txt:'Retardo',     color:'var(--alerta)',  bg:'#FEF3E2' },
  falta:      { txt:'Falta',       color:'var(--error)',   bg:'#FEF2F2' },
  incompleta: { txt:'Sin salida',  color:'#B45309',        bg:'#FEF3E2' },
  incidencia: { txt:'Incidencia',  color:'#4F46E5',        bg:'#EEF2FF' },
  descanso:   { txt:'Descanso',    color:'var(--txt-3)',   bg:'var(--linea-s)' },
  festivo:    { txt:'Festivo',     color:'#0E7490',        bg:'#ECFEFF' },
  pendiente:  { txt:'Sin registro',color:'var(--txt-3)',   bg:'var(--linea-s)' }
};

const hhmm = iso => iso
  ? new Date(iso).toLocaleTimeString('es-MX',{hour:'2-digit',minute:'2-digit'})
  : '—';

const dur = min => {
  if(min == null) return '—';
  const h = Math.floor(min/60), m = min%60;
  return h ? h+' h '+(m?m+' min':'') : m+' min';
};

/* La ubicación se pide al ENTRAR, no al oprimir el botón. El GPS
   tarda hasta 8 segundos: pedirla al oprimir hace que el usuario
   crea que el botón no funciona y lo oprima otra vez. */
function pedirUbicacion(){
  return new Promise(resolve => {
    if(!navigator.geolocation){
      _geoErr = 'Este dispositivo no comparte ubicación.';
      return resolve(null);
    }
    navigator.geolocation.getCurrentPosition(
      p => {
        _geo = { lat:p.coords.latitude, lng:p.coords.longitude,
                 precision:p.coords.accuracy };
        _geoErr = null;
        resolve(_geo);
      },
      err => {
        _geoErr = err.code === 1
          ? 'Permiso de ubicación denegado. Actívalo para poder checar.'
          : 'No se pudo obtener tu ubicación. Intenta al aire libre.';
        resolve(null);
      },
      { enableHighAccuracy:true, timeout:9000, maximumAge:30000 }
    );
  });
}

function distMetros(a, b){
  const R = 6371000, r = Math.PI/180;
  return Math.round(R * Math.acos(Math.min(1,
    Math.sin(a.lat*r)*Math.sin(b.lat*r) +
    Math.cos(a.lat*r)*Math.cos(b.lat*r)*Math.cos((b.lng-a.lng)*r))));
}

/* ── Tarjeta de checar ── */
function tarjetaChecar(){
  const d = _miDia;
  if(!d || !d.puede){
    const motivos = {
      sin_empleado:     'Tu usuario no está ligado a un expediente de empleado.',
      inactivo:         'Tu registro no está activo.',
      no_aplica:        'Tu puesto no registra asistencia.',
      solo_dispositivo: 'Registra tu asistencia en el checador de tu centro de trabajo.'
    };
    if(!d) return '';
    return '<div class="ck-card ck-off">'
      + '<i class="fas fa-circle-info"></i>'
      + '<p>'+(motivos[d.motivo] || 'No puedes registrar asistencia desde aquí.')+'</p></div>';
  }

  const n     = (d.checadas||[]).length;
  const sig   = n === 0 ? 'entrada' : (n % 2 === 0 ? 'entrada' : 'salida');
  const ultima = n ? d.checadas[n-1].momento : null;

  // Distancia a la ubicación más cercana, calculada en el cliente
  // solo para avisar antes de tiempo. La validación real es del
  // servidor: este número es cortesía, no seguridad.
  let aviso = '';
  if(d.geocerca && _geo && (d.ubicaciones||[]).length){
    let mejor = null;
    d.ubicaciones.forEach(u => {
      const m = distMetros(_geo, {lat:+u.lat, lng:+u.lng});
      if(!mejor || m < mejor.m) mejor = { m, u };
    });
    const dentro = mejor.m <= mejor.u.radio;
    aviso = '<p class="ck-geo'+(dentro?' ok':'')+'">'
      + '<i class="fas fa-location-'+(dentro?'dot':'crosshairs')+'"></i>'
      + (dentro
          ? 'En '+mejor.u.nombre
          : 'A '+mejor.m+' m de '+mejor.u.nombre+' (límite '+mejor.u.radio+' m)')
      + '</p>';
  } else if(d.geocerca && _geoErr){
    aviso = '<p class="ck-geo err"><i class="fas fa-triangle-exclamation"></i>'+_geoErr+'</p>';
  } else if(d.geocerca && !_geo){
    aviso = '<p class="ck-geo"><i class="fas fa-spinner fa-spin"></i>Obteniendo ubicación...</p>';
  }

  const esperando = d.geocerca && !_geo;

  return '<div class="ck-card">'
    + '<div class="ck-top">'
    + '<div><p class="ck-hora" id="ck-reloj">--:--</p>'
    + '<p class="ck-fecha">'+new Date().toLocaleDateString('es-MX',
        {weekday:'long', day:'numeric', month:'long'})+'</p></div>'
    + (d.turno
        ? '<span class="ck-turno">'+d.turno.nombre+'<br><b>'
          + d.turno.entrada.slice(0,5)+' a '+d.turno.salida.slice(0,5)+'</b></span>'
        : '<span class="ck-turno ck-descanso">Descanso</span>')
    + '</div>'
    + aviso
    // El botón no deja elegir entrada o salida: lo decide el
    // conteo. En Prisma la gente oprimía "entrada" dos veces.
    + '<button class="ck-btn" id="ck-btn" onclick="checar()"'
    + (esperando ? ' disabled' : '') + '>'
    + '<i class="fas fa-fingerprint"></i>'
    + '<span>Registrar '+sig+'</span></button>'
    + (n
        ? '<div class="ck-lista">'
          + d.checadas.map((c,i) =>
              '<span><b>'+(i%2===0?'Entrada':'Salida')+'</b>'+hhmm(c.momento)+'</span>'
            ).join('')
          + '</div>'
        : '<p class="ck-nada">Aún no tienes registros hoy</p>')
    + (d.jornada && d.jornada.retardo > 0
        ? '<p class="ck-retardo">Llegaste '+d.jornada.retardo+' min tarde</p>'
        : '')
    + '</div>';
}

async function checar(){
  const btn = document.getElementById('ck-btn');
  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin"></i><span>Registrando...</span>';

  // Se refresca la ubicación en el momento del registro: la de
  // hace cinco minutos ya no prueba dónde está la persona.
  if(_miDia.geocerca) await pedirUbicacion();

  const { data, error } = await sb.rpc('registrar_checada', {
    p_lat: _geo?.lat ?? null,
    p_lng: _geo?.lng ?? null,
    p_precision: _geo?.precision ?? null,
    p_dispositivo: navigator.userAgent.slice(0,120),
    p_selfie: null
  });

  if(error){ toast('error', error.message); }
  else if(data.status === 'error'){ toast('error', data.message); }
  else {
    toast('ok', data.ubicacion
      ? 'Registrado en ' + data.ubicacion
      : 'Asistencia registrada');
  }
  await cargarAsistencia();
}

/* ── Tablero del día ── */
async function pintarTablero(){
  const cont = document.getElementById('asis-cuerpo');
  cont.innerHTML = '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando...</p>';

  const fecha = document.getElementById('asis-fecha')?.value || null;
  const { data, error } = await sb.rpc('tablero_dia', { p_fecha: fecha });
  if(error){ cont.innerHTML = '<p class="cargando">'+error.message+'</p>'; return; }

  const filas = data.filas || [];
  if(!filas.length){
    cont.innerHTML = '<div class="vacio"><i class="fas fa-user-clock"></i>'
      + '<h3>Sin personal para mostrar</h3>'
      + '<p>No hay empleados activos con registro de asistencia.</p></div>';
    return;
  }

  // Resumen arriba: nadie lee 300 renglones para saber cuántos
  // faltaron. Los conteos que exigen acción van primero.
  const c = {};
  filas.forEach(f => c[f.estatus] = (c[f.estatus]||0) + 1);
  const orden = ['falta','incompleta','retardo','pendiente','completa','incidencia','descanso','festivo'];

  cont.innerHTML =
    '<div class="tb-resumen">'
    + orden.filter(k => c[k]).map(k => {
        const e = EST_ASIS[k];
        return '<div class="tb-kpi"><b style="color:'+e.color+'">'+c[k]+'</b>'
             + '<span>'+e.txt+'</span></div>';
      }).join('')
    + '</div>'
    + '<div class="tb-tabla">'
    + '<table><thead><tr>'
    + '<th>Colaborador</th><th>Turno</th><th>Entrada</th><th>Salida</th>'
    + '<th>Trabajado</th><th>Estado</th>'
    + '</tr></thead><tbody>'
    + filas.map(f => {
        const e = EST_ASIS[f.estatus] || EST_ASIS.pendiente;
        return '<tr>'
          + '<td data-l="Colaborador"><b>'+f.nombre+'</b>'
          + '<span class="tb-sub">'+(f.puesto||'')+(f.centro?' · '+f.centro:'')+'</span></td>'
          + '<td data-l="Turno">'+(f.turno||'—')+'</td>'
          + '<td data-l="Entrada" class="num">'+hhmm(f.entrada)
          + (f.retardo>0 ? '<span class="tb-tarde">+'+f.retardo+'</span>' : '')+'</td>'
          + '<td data-l="Salida" class="num">'+hhmm(f.salida)+'</td>'
          + '<td data-l="Trabajado" class="num">'+dur(f.trabajados)+'</td>'
          + '<td data-l="Estado"><span class="tb-badge" style="color:'+e.color
          + ';background:'+e.bg+'">'+e.txt+'</span></td>'
          + '</tr>';
      }).join('')
    + '</tbody></table></div>';
}

/* ── Ubicaciones con mapa ── */
async function pintarUbicaciones(){
  const cont = document.getElementById('asis-cuerpo');
  cont.innerHTML = '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando...</p>';

  const [cen, ubi] = await Promise.all([
    sb.from('centros_trabajo').select('id,clave,nombre,lat,lng,radio_m').order('clave'),
    sb.from('ubicaciones').select('id,nombre,tipo,lat,lng,radio_m,activa').order('nombre')
  ]);

  const centros = cen.data || [];
  const sinCoord = centros.filter(c => !c.lat).length;

  cont.innerHTML =
    (sinCoord
      ? '<p class="aviso"><i class="fas fa-circle-info"></i>'
        + sinCoord + ' centro(s) sin coordenadas. La geocerca no puede validar '
        + 'un lugar que no tiene ubicación registrada.</p>'
      : '')
    + '<div class="ub-grid">'
    + '<div>'
    + '<h4 class="ub-h">Centros de trabajo</h4>'
    + centros.map(c =>
        '<button class="ub-item'+(c.lat?'':' sin')+'" onclick="editarPunto(\'centro\',\''+c.id+'\')">'
        + '<div><b>'+c.nombre+'</b><span>'+c.clave+'</span></div>'
        + '<span class="ub-coord">'+(c.lat
            ? (+c.lat).toFixed(4)+', '+(+c.lng).toFixed(4)+' · '+c.radio_m+' m'
            : 'Sin ubicar')+'</span></button>'
      ).join('')
    + '<h4 class="ub-h" style="margin-top:22px">Ubicaciones autorizadas'
    + '<button class="ub-add" onclick="nuevaUbicacion()">'
    + '<i class="fas fa-plus"></i>Nueva</button></h4>'
    + ((ubi.data||[]).length
        ? ubi.data.map(u =>
            '<button class="ub-item" onclick="editarPunto(\'ubicacion\',\''+u.id+'\')">'
            + '<div><b>'+u.nombre+'</b><span>'+u.tipo+'</span></div>'
            + '<span class="ub-coord">'+(+u.lat).toFixed(4)+', '+(+u.lng).toFixed(4)
            + ' · '+u.radio_m+' m</span></button>'
          ).join('')
        : '<p class="ub-nada">Sin ubicaciones adicionales. Sirven para autorizar '
          + 'registros fuera del centro: obras, sedes de cliente, comisiones.</p>')
    + '</div>'
    + '<div><div id="mapa"></div>'
    + '<p class="ub-tip">Arrastra el marcador para ajustar la posición.</p></div>'
    + '</div>';

  // Se centra en el primer punto con coordenadas, o en la CDMX
  const ref = centros.find(c => c.lat) || (ubi.data||[]).find(u => u.lat);
  montarMapa(ref ? [+ref.lat, +ref.lng] : [19.4326, -99.1332]);
}

function montarMapa(centro){
  const div = document.getElementById('mapa');
  if(!div || !window.L) return;
  if(_mapa){ _mapa.remove(); _mapa = null; }
  _mapa = L.map('mapa').setView(centro, 16);
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    attribution:'&copy; OpenStreetMap', maxZoom:19
  }).addTo(_mapa);
}

let _pt = null;   // { tipo, id, marcador, circulo }

async function editarPunto(tipo, id){
  const tabla = tipo === 'centro' ? 'centros_trabajo' : 'ubicaciones';
  const { data } = await sb.from(tabla)
    .select('id,nombre,lat,lng,radio_m').eq('id', id).single();

  const lat = data.lat ? +data.lat : (_mapa.getCenter().lat);
  const lng = data.lng ? +data.lng : (_mapa.getCenter().lng);

  if(_pt){ _mapa.removeLayer(_pt.marcador); _mapa.removeLayer(_pt.circulo); }

  const marcador = L.marker([lat,lng], { draggable:true }).addTo(_mapa);
  const circulo  = L.circle([lat,lng], {
    radius: data.radio_m || 150,
    color:'#2EC4B6', fillColor:'#2EC4B6', fillOpacity:.12, weight:2
  }).addTo(_mapa);

  marcador.on('drag', ev => circulo.setLatLng(ev.target.getLatLng()));
  _mapa.setView([lat,lng], 17);
  _pt = { tipo, id, marcador, circulo, nombre:data.nombre };

  document.getElementById('mapa').insertAdjacentHTML('afterend',
    '<div class="ub-editor" id="ub-editor">'
    + '<p><b>'+data.nombre+'</b></p>'
    + '<label>Radio permitido'
    + '<span class="cfg-num"><input type="number" id="ub-radio" '
    + 'value="'+(data.radio_m||150)+'" min="20" max="5000" '
    + 'oninput="cambiarRadio(this.value)"><span>m</span></span></label>'
    + '<p class="ub-nota">Menos de 100 m genera rechazos a gente que sí está '
    + 'en su lugar: el GPS de un celular dentro de un edificio se desvía fácil.</p>'
    + '<button class="btn-pri" onclick="guardarPunto()">Guardar ubicación</button>'
    + '</div>');
}

function cambiarRadio(v){
  if(_pt) _pt.circulo.setRadius(Number(v) || 150);
}

async function guardarPunto(){
  if(!_pt) return;
  const p = _pt.marcador.getLatLng();
  const radio = Number(document.getElementById('ub-radio').value) || 150;

  let error;
  if(_pt.tipo === 'centro'){
    ({ error } = await sb.rpc('guardar_coordenadas_centro', {
      p_centro_id: _pt.id, p_lat: p.lat, p_lng: p.lng, p_radio: radio }));
  } else {
    ({ error } = await sb.from('ubicaciones')
      .update({ lat:p.lat, lng:p.lng, radio_m:radio }).eq('id', _pt.id));
  }

  if(error) toast('error', error.message);
  else { toast('ok', 'Ubicación guardada'); pintarUbicaciones(); }
}

async function nuevaUbicacion(){
  const nombre = prompt('Nombre de la ubicación (ej. Obra Cliente Norte)');
  if(!nombre) return;
  const tipo = prompt('Tipo: sede, cliente, proyecto, temporal, domicilio', 'cliente');
  if(!tipo) return;

  const c = _mapa ? _mapa.getCenter() : { lat:19.4326, lng:-99.1332 };
  const { error } = await sb.from('ubicaciones').insert({
    tenant_id: Sesion.perfil.tenant_id,
    nombre, tipo, lat:c.lat, lng:c.lng, radio_m:150
  });
  if(error) toast('error', error.message);
  else { toast('ok','Ubicación creada. Ajusta el pin en el mapa.'); pintarUbicaciones(); }
}

/* ── Dispositivos ── */
async function pintarDispositivos(){
  const cont = document.getElementById('asis-cuerpo');
  cont.innerHTML = '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando...</p>';

  const { data } = await sb.from('dispositivos')
    .select('id,nombre,marca,modelo,modo,activo,ultimo_contacto,llave_pista,centro_id')
    .order('nombre');

  const horas = 12;   // se muestra el criterio, viene de config
  const frio = d => !d.ultimo_contacto
    || (Date.now() - new Date(d.ultimo_contacto)) > horas*3600*1000;

  cont.innerHTML =
    '<div class="dv-top">'
    + '<p class="aviso" style="margin:0"><i class="fas fa-circle-info"></i>'
    + 'Un checador físico no puede ser llamado desde internet: es él quien envía '
    + 'sus registros, o un agente instalado en la oficina los sube por él.</p>'
    + '<button class="btn-pri" onclick="nuevoDispositivo()">'
    + '<i class="fas fa-plus"></i> Registrar checador</button></div>'
    + ((data||[]).length
        ? '<div class="dv-lista">'
          + data.map(d =>
              '<div class="dv-item">'
              + '<div class="dv-ico'+(d.activo?'':' off')+'">'
              + '<i class="fas fa-clock"></i></div>'
              + '<div class="dv-info"><b>'+d.nombre+'</b>'
              + '<span>'+[d.marca,d.modelo].filter(Boolean).join(' ')
              + ' · modo '+d.modo+' · llave ...'+(d.llave_pista||'')+'</span></div>'
              + '<span class="dv-est'+(frio(d)?' frio':'')+'">'
              + (d.ultimo_contacto
                  ? (frio(d) ? 'Sin reportar' : 'Activo')
                  : 'Nunca ha reportado')
              + '</span></div>'
            ).join('')
          + '</div>'
        : '<div class="vacio"><i class="fas fa-clock"></i>'
          + '<h3>Sin checadores registrados</h3>'
          + '<p>Mientras no haya ninguno, el personal registra desde el celular.</p></div>');
}

async function nuevoDispositivo(){
  const { data: centros } = await sb.from('centros_trabajo')
    .select('id,clave,nombre').order('clave');
  if(!centros?.length){ toast('error','Primero registra un centro de trabajo'); return; }

  const nombre = prompt('Nombre del checador (ej. Entrada principal)');
  if(!nombre) return;
  const clave = prompt('Centro de trabajo:\n' +
    centros.map(c => c.clave).join('\n'), centros[0].clave);
  const centro = centros.find(c => c.clave === clave);
  if(!centro){ toast('error','Centro no encontrado'); return; }
  const marca = prompt('Marca (ZKTeco, Anviz, Hikvision...)') || null;
  const modelo = prompt('Modelo') || null;

  const { data, error } = await sb.rpc('crear_dispositivo', {
    p_centro_id: centro.id, p_nombre: nombre,
    p_marca: marca, p_modelo: modelo, p_serie: null, p_modo: 'agente'
  });

  if(error){ toast('error', error.message); return; }

  // La llave se muestra UNA vez. En la base solo queda el hash:
  // si se pierde, se regenera. Recuperable sería inseguro.
  alert('Checador registrado.\n\nLlave de acceso (se muestra una sola vez, '
    + 'guárdala ahora):\n\n' + data.llave
    + '\n\nSe usa para configurar el agente o el ADMS del equipo.');
  pintarDispositivos();
}

/* ── Armado del módulo ── */
function asisIr(tab){
  _asisTab = tab;
  document.querySelectorAll('.asis-tab').forEach(b =>
    b.classList.toggle('on', b.dataset.tab === tab));
  if(tab === 'dia')          pintarTablero();
  if(tab === 'ubicaciones')  pintarUbicaciones();
  if(tab === 'dispositivos') pintarDispositivos();
}

async function cargarAsistencia(){
  const { data } = await sb.rpc('mi_dia');
  _miDia = data;

  const hoy = new Date().toISOString().slice(0,10);
  const admin = Sesion.esJefe;

  document.getElementById('contenido').innerHTML =
    tarjetaChecar()
    + (admin
        ? '<div class="asis-barra">'
          + '<div class="asis-tabs">'
          + '<button class="asis-tab on" data-tab="dia" onclick="asisIr(\'dia\')">'
          + 'Tablero del día</button>'
          + (Sesion.esAdmin
              ? '<button class="asis-tab" data-tab="ubicaciones" onclick="asisIr(\'ubicaciones\')">'
                + 'Ubicaciones</button>'
                + '<button class="asis-tab" data-tab="dispositivos" onclick="asisIr(\'dispositivos\')">'
                + 'Checadores</button>'
              : '')
          + '</div>'
          + '<input type="date" id="asis-fecha" value="'+hoy+'" onchange="pintarTablero()">'
          + '</div>'
          + '<div id="asis-cuerpo"></div>'
        : '');

  if(admin) asisIr(_asisTab);

  // Reloj vivo. Un reloj congelado en una pantalla de checador
  // hace dudar de la hora que se va a registrar.
  if(window._ckTimer) clearInterval(window._ckTimer);
  const pinta = () => {
    const el = document.getElementById('ck-reloj');
    if(el) el.textContent = new Date().toLocaleTimeString('es-MX',
      {hour:'2-digit', minute:'2-digit', second:'2-digit'});
  };
  pinta();
  window._ckTimer = setInterval(pinta, 1000);
}

async function moduloAsistencia(){
  document.getElementById('contenido').innerHTML =
    '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando...</p>';
  await cargarAsistencia();
  // La ubicación se pide en paralelo: la tarjeta ya se ve
  // mientras el GPS resuelve.
  if(_miDia?.geocerca){ await pedirUbicacion(); await cargarAsistencia(); }
}