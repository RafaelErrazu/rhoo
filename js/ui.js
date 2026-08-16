// ═══════════════════════════════════════════════════════════
//  RHoo! · Componentes de interfaz
//  Modal con formulario declarativo: se describe qué campos se
//  quieren y devuelve una promesa con los valores. Evita repetir
//  el mismo HTML en cada módulo.
// ═══════════════════════════════════════════════════════════

let _modalCerrar = null;

/* Campos soportados:
   {k, label, t:'texto'|'num'|'fecha'|'select'|'area'|'tel'|'mail',
    req, opciones:[[valor,texto]], ancho:'full'|'mitad', nota, valor}  */
function modal({ titulo, subtitulo, campos = [], ok = 'Guardar',
                 cancelar = 'Cancelar', peligro = false }){
  return new Promise(resolve => {
    const cont = document.createElement('div');
    cont.className = 'md-fondo';
    cont.innerHTML =
      '<div class="md-caja" role="dialog" aria-modal="true">'
      + '<div class="md-top">'
      + '<div><h3>'+titulo+'</h3>'
      + (subtitulo ? '<p>'+subtitulo+'</p>' : '') + '</div>'
      + '<button class="md-x" aria-label="Cerrar"><i class="fas fa-xmark"></i></button>'
      + '</div>'
      + '<div class="md-cuerpo"><form id="md-form" class="md-campos">'
      + campos.map(c => {
          const id = 'md-' + c.k;
          const req = c.req ? ' required' : '';
          let ctl;
          if(c.t === 'select'){
            ctl = '<select id="'+id+'"'+req+'>'
              + (c.req ? '' : '<option value="">Sin especificar</option>')
              + (c.opciones||[]).map(([v,t]) =>
                  '<option value="'+v+'"'+(c.valor===v?' selected':'')+'>'+t+'</option>'
                ).join('')
              + '</select>';
          } else if(c.t === 'area'){
            ctl = '<textarea id="'+id+'" rows="3"'+req+'>'+(c.valor||'')+'</textarea>';
          } else {
            const tipo = { num:'number', fecha:'date', tel:'tel', mail:'email' }[c.t] || 'text';
            ctl = '<input type="'+tipo+'" id="'+id+'" value="'+(c.valor??'')+'"'
                + (c.max ? ' maxlength="'+c.max+'"' : '')
                + (c.patron ? ' pattern="'+c.patron+'"' : '')
                + req+'>';
          }
          return '<label class="md-campo '+(c.ancho||'full')+'">'
            + '<span>'+c.label+(c.req?' <b>*</b>':'')+'</span>'
            + ctl
            + (c.nota ? '<em>'+c.nota+'</em>' : '')
            + '</label>';
        }).join('')
      + '</form></div>'
      + '<div class="md-pie">'
      + '<button class="btn-sec-claro" id="md-no">'+cancelar+'</button>'
      + '<button class="'+(peligro?'btn-peligro':'btn-pri')+'" id="md-si">'+ok+'</button>'
      + '</div></div>';

    document.body.appendChild(cont);
    requestAnimationFrame(() => cont.classList.add('on'));

    const primero = cont.querySelector('input,select,textarea');
    if(primero) primero.focus();

    const cerrar = val => {
      document.removeEventListener('keydown', esc);
      cont.classList.remove('on');
      setTimeout(() => cont.remove(), 200);
      _modalCerrar = null;
      resolve(val);
    };
    _modalCerrar = () => cerrar(null);

    // Escape cierra. Un modal que solo se cierra con el botón
    // atrapa al usuario cuando el botón queda fuera de pantalla.
    const esc = ev => { if(ev.key === 'Escape') cerrar(null); };
    document.addEventListener('keydown', esc);

    cont.querySelector('.md-x').onclick = () => cerrar(null);
    cont.querySelector('#md-no').onclick = () => cerrar(null);
    // Clic en el fondo, pero NO si el clic empezó dentro: arrastrar
    // para seleccionar texto y soltar afuera no debe cerrar y
    // perder lo capturado.
    cont.onmousedown = ev => { if(ev.target === cont) cont._desdeFuera = true; };
    cont.onclick = ev => {
      if(ev.target === cont && cont._desdeFuera) cerrar(null);
      cont._desdeFuera = false;
    };

    const enviar = () => {
      const form = cont.querySelector('#md-form');
      if(!form.reportValidity()) return;
      const out = {};
      campos.forEach(c => {
        const el = cont.querySelector('#md-' + c.k);
        out[c.k] = el ? el.value.trim() : '';
      });
      cerrar(out);
    };
    cont.querySelector('#md-si').onclick = enviar;
    cont.querySelector('#md-form').onsubmit = ev => { ev.preventDefault(); enviar(); };
  });
}

/* Confirmación con motivo obligatorio, para acciones que dejan
   rastro en auditoría (bajas, anulaciones). */
function confirmar({ titulo, mensaje, ok = 'Confirmar', peligro = true, pedirMotivo = false }){
  return modal({
    titulo, subtitulo: mensaje, ok, peligro,
    campos: pedirMotivo
      ? [{ k:'motivo', label:'Motivo', t:'area', req:true,
           nota:'Queda registrado en la bitácora con tu nombre y la fecha.' }]
      : []
  });
}

/* Panel lateral. Para expedientes: deja la lista visible detrás
   y no obliga a navegar de vuelta. */
function panel({ titulo, subtitulo, html, acciones = '' }){
  cerrarPanel();
  const el = document.createElement('div');
  el.className = 'pn-fondo';
  el.id = 'pn-fondo';
  el.innerHTML =
    '<div class="pn-caja" role="dialog" aria-modal="true">'
    + '<div class="pn-top">'
    + '<div><h3>'+titulo+'</h3>'
    + (subtitulo ? '<p>'+subtitulo+'</p>' : '') + '</div>'
    + '<button class="md-x" onclick="cerrarPanel()" aria-label="Cerrar">'
    + '<i class="fas fa-xmark"></i></button></div>'
    + '<div class="pn-cuerpo" id="pn-cuerpo">'+html+'</div>'
    + (acciones ? '<div class="pn-pie">'+acciones+'</div>' : '')
    + '</div>';
  document.body.appendChild(el);
  requestAnimationFrame(() => el.classList.add('on'));
  el.onclick = ev => { if(ev.target === el) cerrarPanel(); };
  document.addEventListener('keydown', _escPanel);
}

function _escPanel(ev){ if(ev.key === 'Escape') cerrarPanel(); }

function cerrarPanel(){
  const el = document.getElementById('pn-fondo');
  if(!el) return;
  document.removeEventListener('keydown', _escPanel);
  el.classList.remove('on');
  setTimeout(() => el.remove(), 220);
}