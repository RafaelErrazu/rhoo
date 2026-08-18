// ═══════════════════════════════════════════════════════════
//  RHoo! · Organigrama
//  Árbol plegable con sangría, no diagrama de cajitas: con 300
//  personas un diagrama no cabe en pantalla y obliga a hacer
//  zoom para leer un nombre.
// ═══════════════════════════════════════════════════════════

let _orgPlegados = new Set();
let _orgDatos = null;

async function pintarOrganigrama(){
  const cont = document.getElementById('org-cuerpo');
  if(!cont) return;
  cont.innerHTML = '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando...</p>';

  const { data, error } = await sb.rpc('organigrama', { p_centro_id: null });
  if(error){ cont.innerHTML = '<p class="cargando">'+error.message+'</p>'; return; }
  _orgDatos = data;

  const arbol = data.arbol || [];
  const solos = data.sin_jefe || [];

  if(!arbol.length && !solos.length){
    cont.innerHTML = '<div class="vacio"><i class="fas fa-sitemap"></i>'
      + '<h3>Sin personal activo</h3><p>Da de alta empleados primero.</p></div>';
    return;
  }

  // Se calcula qué filas ocultar: si un nodo está plegado, todos
  // sus descendientes se van. Se detecta por nivel, no por
  // relación: el arreglo ya viene en orden de recorrido.
  const visibles = [];
  let ocultarHasta = -1;
  arbol.forEach(n => {
    if(ocultarHasta >= 0){
      if(n.nivel > ocultarHasta) return;      // sigue siendo descendiente
      ocultarHasta = -1;
    }
    visibles.push(n);
    if(_orgPlegados.has(n.id) && n.equipo > 0) ocultarHasta = n.nivel;
  });

  cont.innerHTML =
    (arbol.length
      ? '<div class="org-arbol">'
        + visibles.map(n => {
            const plegado = _orgPlegados.has(n.id);
            return '<div class="org-fila" style="--n:'+n.nivel+'">'
              + (n.equipo > 0
                  ? '<button class="org-toggle" onclick="orgPlegar(\''+n.id+'\')" '
                    + 'aria-label="Plegar"><i class="fas fa-chevron-'
                    + (plegado ? 'right' : 'down')+'"></i></button>'
                  : '<span class="org-hoja"></span>')
              + '<div class="org-info" onclick="verEmpleado(\''+n.id+'\')">'
              + '<b>'+n.nombre+'</b>'
              + '<span>'+(n.puesto || 'Sin puesto')
              + (n.departamento ? ' · '+n.departamento : '')+'</span></div>'
              + (n.equipo > 0
                  ? '<span class="org-eq">'+n.equipo+'</span>'
                  : '')
              + '<button class="org-mover" onclick="cambiarJefe(\''+n.id+'\',\''
              + n.nombre.replace(/'/g,"")+'\')" title="Cambiar jefe">'
              + '<i class="fas fa-arrows-up-down-left-right"></i></button>'
              + '</div>';
          }).join('')
        + '</div>'
      : '')

    // Los huérfanos no se esconden: son el pendiente real. Un
    // organigrama que los oculta parece completo cuando no lo está.
    + (solos.length
        ? '<div class="org-solos">'
          + '<h4><i class="fas fa-user-plus"></i>Sin jefe asignado ('+solos.length+')</h4>'
          + '<p>Mientras no tengan jefe, nadie puede autorizar sus solicitudes '
          + 'como jefe directo: pasan directo a Recursos Humanos.</p>'
          + '<div class="org-chips">'
          + solos.map(s =>
              '<button onclick="cambiarJefe(\''+s.id+'\',\''
              + s.nombre.replace(/'/g,"")+'\')">'
              + s.nombre + (s.puesto ? ' · '+s.puesto : '')
              + '<i class="fas fa-plus"></i></button>'
            ).join('')
          + '</div></div>'
        : '');
}

function orgPlegar(id){
  if(_orgPlegados.has(id)) _orgPlegados.delete(id);
  else _orgPlegados.add(id);
  pintarOrganigrama();
}

async function cambiarJefe(empId, nombre){
  const { data } = await sb.rpc('listar_empleados',
    { p_buscar:null, p_estatus:'Activo', p_centro_id:null, p_limite:300, p_desde:0 });

  // La propia persona no puede ser opción: el ciclo de un paso
  // se evita aquí, y los de varios pasos los ataja el trigger.
  const opciones = (data?.filas || [])
    .filter(f => f.id !== empId)
    .map(f => [f.id, f.nombre + (f.puesto ? ' · '+f.puesto : '')]);

  const eq = (_orgDatos?.arbol || []).find(n => n.id === empId)?.equipo || 0;

  const r = await modal({
    titulo: 'Cambiar jefe directo',
    subtitulo: nombre + (eq > 0
      ? '. Tiene ' + eq + ' persona(s) a su cargo, que se mueven con ella.'
      : ''),
    ok: 'Guardar',
    campos: [
      { k:'jefe', label:'Reporta a', t:'select',
        opciones: [['','Nadie (sin jefe)']].concat(opciones),
        nota:'Deja "Nadie" para dejarlo en la raíz del organigrama.' }
    ]
  });
  if(!r) return;

  const { error } = await sb.rpc('asignar_jefe', {
    p_empleado_id: empId, p_jefe_id: r.jefe || null });

  if(error){ toast('error', error.message); return; }
  toast('ok','Jerarquía actualizada');
  pintarOrganigrama();
}

/* ── Mi equipo: la vista del jefe ── */
async function pintarMiEquipo(){
  const cont = document.getElementById('org-cuerpo');
  cont.innerHTML = '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando...</p>';

  const { data, error } = await sb.rpc('mi_equipo');
  if(error){ cont.innerHTML = '<p class="cargando">'+error.message+'</p>'; return; }

  const filas = data.filas || [];
  if(!filas.length){
    cont.innerHTML = '<div class="vacio"><i class="fas fa-users"></i>'
      + '<h3>Sin equipo asignado</h3>'
      + '<p>Nadie te reporta directamente todavía.</p></div>';
    return;
  }

  cont.innerHTML = '<div class="eq-lista">'
    + filas.map(f => {
        const e = EST_ASIS[f.hoy] || EST_ASIS.pendiente;
        return '<div class="eq-item" onclick="verEmpleado(\''+f.id+'\')">'
          + '<span class="avatar">'+iniciales(f.nombre)+'</span>'
          + '<div class="eq-info"><b>'+f.nombre+'</b>'
          + '<span>'+(f.puesto||'')+'</span></div>'
          + '<div class="eq-meta">'
          + '<span class="tb-badge" style="color:'+e.color+';background:'+e.bg+'">'
          + e.txt+'</span>'
          + '<span class="eq-vac">'+Math.round(f.saldo)+' días</span>'
          + (f.pendientes > 0
              ? '<span class="eq-pend">'+f.pendientes+' por autorizar</span>'
              : '')
          + '</div></div>';
      }).join('')
    + '</div>';
}

let _orgTab = 'equipo';

function orgIr(t){
  _orgTab = t;
  document.querySelectorAll('.org-tab').forEach(b =>
    b.classList.toggle('on', b.dataset.t === t));
  if(t === 'equipo') pintarMiEquipo();
  else pintarOrganigrama();
}

async function moduloOrganigrama(){
  document.getElementById('contenido').innerHTML =
    '<div class="asis-barra"><div class="asis-tabs">'
    + '<button class="asis-tab org-tab on" data-t="equipo" onclick="orgIr(\'equipo\')">'
    + 'Mi equipo</button>'
    + (Sesion.esAdmin
        ? '<button class="asis-tab org-tab" data-t="todo" onclick="orgIr(\'todo\')">'
          + 'Organigrama completo</button>'
        : '')
    + '</div></div><div id="org-cuerpo"></div>';
  orgIr(_orgTab);
}