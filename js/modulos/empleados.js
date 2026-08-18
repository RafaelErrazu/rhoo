// ═══════════════════════════════════════════════════════════
//  RHoo! · Módulo Empleados
// ═══════════════════════════════════════════════════════════

let _empFiltro = { buscar:'', estatus:'Activo', centro:null, desde:0 };
let _empTotal  = 0;
let _centros   = null;
const EMP_PAG  = 50;

const CAT_SEXO = [['Masculino','Masculino'],['Femenino','Femenino'],['Otro','Otro']];
const CAT_TIPO_PUESTO = [
  ['Operativo','Operativo'],['Supervisor','Supervisor'],
  ['Profesional o técnico','Profesional o técnico'],['Gerente','Gerente']];
const CAT_PERSONAL = [
  ['Sindicalizado','Sindicalizado'],['Confianza','Confianza'],['Ninguno','Ninguno']];
const CAT_CONTRATO = [
  ['Tiempo indeterminado','Tiempo indeterminado'],
  ['Por tiempo determinado (temporal)','Por tiempo determinado (temporal)'],
  ['Por obra o proyecto','Por obra o proyecto'],
  ['Honorarios','Honorarios']];
const CAT_CIVIL = [
  ['Soltero','Soltero'],['Casado','Casado'],['Unión libre','Unión libre'],
  ['Divorciado','Divorciado'],['Viudo','Viudo']];
const CAT_ESCOLARIDAD = [
  ['Sin formación','Sin formación'],['Primaria','Primaria'],['Secundaria','Secundaria'],
  ['Preparatoria o Bachillerato','Preparatoria o Bachillerato'],
  ['Técnico Superior','Técnico Superior'],['Licenciatura','Licenciatura'],
  ['Maestría','Maestría'],['Doctorado','Doctorado']];
const CAT_METODO = [
  ['ambos','Checador o celular'],['dispositivo','Solo checador'],
  ['movil','Solo celular'],['ninguno','No registra asistencia']];

async function centrosOpc(){
  if(_centros) return _centros;
  const { data } = await sb.from('centros_trabajo')
    .select('id,clave,nombre').eq('activo', true).order('clave');
  _centros = (data||[]).map(c => [c.id, c.nombre]);
  return _centros;
}

const antig = m => {
  if(m == null) return '—';
  const a = Math.floor(m/12), r = m%12;
  if(!a) return r + ' mes' + (r===1?'':'es');
  return a + ' año' + (a===1?'':'s') + (r ? ' ' + r + ' m' : '');
};

async function pintarEmpleados(){
  const cont = document.getElementById('emp-cuerpo');
  cont.innerHTML = '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando...</p>';

  const { data, error } = await sb.rpc('listar_empleados', {
    p_buscar:  _empFiltro.buscar || null,
    p_estatus: _empFiltro.estatus,
    p_centro_id: _empFiltro.centro,
    p_limite:  EMP_PAG,
    p_desde:   _empFiltro.desde
  });

  if(error){ cont.innerHTML = '<p class="cargando">'+error.message+'</p>'; return; }

  _empTotal = data.total;
  const filas = data.filas || [];

  if(!filas.length){
    cont.innerHTML = '<div class="vacio"><i class="fas fa-users"></i>'
      + '<h3>'+(_empFiltro.buscar ? 'Sin resultados' : 'Sin empleados')+'</h3>'
      + '<p>'+(_empFiltro.buscar
          ? 'Nada coincide con "'+_empFiltro.buscar+'".'
          : 'Da de alta al primero con el botón de arriba.')+'</p></div>';
    return;
  }

  const paginas = Math.ceil(_empTotal / EMP_PAG);
  const pagina  = Math.floor(_empFiltro.desde / EMP_PAG) + 1;

  cont.innerHTML =
    '<div class="tb-tabla"><table><thead><tr>'
    + '<th>Colaborador</th><th>Puesto</th><th>Centro</th>'
    + '<th>Antigüedad</th><th>Vacaciones</th><th></th>'
    + '</tr></thead><tbody>'
    + filas.map(f =>
        '<tr onclick="verEmpleado(\''+f.id+'\')" class="emp-fila">'
        + '<td data-l="Colaborador"><b>'+f.nombre+'</b>'
        + '<span class="tb-sub">#'+f.no
        + (f.estatus !== 'Activo' ? ' · <i>'+f.estatus+'</i>' : '')+'</span></td>'
        + '<td data-l="Puesto">'+(f.puesto||'—')
        + (f.departamento ? '<span class="tb-sub">'+f.departamento+'</span>' : '')+'</td>'
        + '<td data-l="Centro">'+(f.centro||'—')+'</td>'
        + '<td data-l="Antigüedad" class="num">'+antig(f.antiguedad_meses)+'</td>'
        // El saldo va aquí porque es la pregunta más frecuente
        // que recibe RH, y tenerlo a la vista evita abrir el
        // expediente para responderla.
        + '<td data-l="Vacaciones" class="num">'
        + '<b>'+(+f.saldo_vacaciones).toFixed(0)+'</b> días</td>'
        + '<td class="emp-ver"><i class="fas fa-chevron-right"></i></td>'
        + '</tr>'
      ).join('')
    + '</tbody></table></div>'
    + (paginas > 1
        ? '<div class="emp-pag">'
          + '<button '+(pagina===1?'disabled':'')+' onclick="empPagina(-1)">'
          + '<i class="fas fa-chevron-left"></i> Anterior</button>'
          + '<span>'+pagina+' de '+paginas+' · '+_empTotal+' registros</span>'
          + '<button '+(pagina===paginas?'disabled':'')+' onclick="empPagina(1)">'
          + 'Siguiente <i class="fas fa-chevron-right"></i></button></div>'
        : '<p class="emp-cuenta">'+_empTotal+' registro(s)</p>');
}

function empPagina(d){
  _empFiltro.desde = Math.max(0, _empFiltro.desde + d * EMP_PAG);
  pintarEmpleados();
}

let _busqTimer = null;
function empBuscar(v){
  // Se espera 350 ms: una consulta por tecla castiga la base sin
  // que el usuario alcance a leer los resultados intermedios.
  clearTimeout(_busqTimer);
  _busqTimer = setTimeout(() => {
    _empFiltro.buscar = v;
    _empFiltro.desde = 0;
    pintarEmpleados();
  }, 350);
}

function empEstatus(v){
  _empFiltro.estatus = v;
  _empFiltro.desde = 0;
  pintarEmpleados();
}

/* ── Alta ── */
async function nuevoEmpleado(){
  const { data: sig } = await sb.rpc('siguiente_no_empleado');
  const centros = await centrosOpc();

  const r = await modal({
    titulo: 'Alta de empleado',
    subtitulo: 'Solo lo indispensable. El resto del expediente se completa después.',
    ok: 'Dar de alta',
    campos: [
      { k:'no_empleado', label:'Número de empleado', t:'texto', req:true,
        valor: sig, ancho:'mitad',
        nota:'Se sugiere el siguiente, pero puedes usar tu propia numeración.' },
      { k:'fecha_ingreso', label:'Fecha de ingreso', t:'fecha', req:true,
        valor: new Date().toLocaleDateString('sv-SE'), ancho:'mitad' },
      { k:'apellido_paterno', label:'Apellido paterno', t:'texto', req:true, ancho:'mitad' },
      { k:'apellido_materno', label:'Apellido materno', t:'texto', ancho:'mitad' },
      { k:'nombres', label:'Nombre(s)', t:'texto', req:true },
      { k:'centro_id', label:'Centro de trabajo', t:'select', req:true,
        opciones: centros, ancho:'mitad' },
      { k:'puesto', label:'Puesto', t:'texto', ancho:'mitad' }
    ]
  });
  if(!r) return;

  const { data, error } = await sb.rpc('crear_empleado', { p_datos: r });
  if(error){ toast('error', error.message); return; }
  toast('ok', 'Empleado dado de alta');
  _empFiltro.buscar = '';
  await pintarEmpleados();
  verEmpleado(data.id);
}

/* ── Expediente ── */
async function verEmpleado(id){
  const { data, error } = await sb.rpc('obtener_empleado', { p_id: id });
  if(error || data.status !== 'success'){
    toast('error', error?.message || data.message); return;
  }
  const e = data.empleado;

  const dato = (et, v) => '<div class="ex-dato"><span>'+et+'</span><b>'
    + (v ?? '—') + '</b></div>';

  const jorn = (data.ultimas_jornadas||[]).slice(0,6);

  panel({
    titulo: e.nombre_completo,
    subtitulo: '#'+e.no_empleado + (e.puesto ? ' · '+e.puesto : '')
      + (e.estatus !== 'Activo' ? ' · ' + e.estatus : ''),
    html:
      '<section class="ex-sec"><h4>Situación</h4>'
      + '<div class="ex-grid">'
      + dato('Estatus', e.estatus)
      + dato('Centro', data.centro?.nombre)
      + dato('Ingreso', e.fecha_ingreso)
      + dato('Antigüedad', antig(e.antiguedad_meses))
      + dato('Turno', data.turno ? data.turno.nombre + ' ('
          + data.turno.entrada.slice(0,5)+'-'+data.turno.salida.slice(0,5)+')' : 'Sin asignar')
      + '<div class="ex-dato"><span>Jefe</span><b>'
      + (data.jefe?.nombre || '—')
      + '<button class="ex-link" onclick="cambiarJefe(\''+id+'\',\''
      + e.nombre_completo.replace(/'/g,"\\'")+'\')">Cambiar</button>'
      + '</b></div>'
      + '</div>'
      // El saldo con su desglose: "20 días" sin contexto no dice
      // si es lo que le toca por ley o si trae días acumulados.
      + '<div class="ex-vac">'
      + '<div><b>'+(+e.saldo_vacaciones).toFixed(0)+'</b><span>días disponibles</span></div>'
      + '<p>Le corresponden <b>'+e.dias_lft+'</b> días por año según el '
      + 'artículo 76 de la LFT con su antigüedad actual.'
      + '<button class="ex-link" onclick="cargarHistoricoVac(\''+id+'\',\''
      + e.nombre_completo.replace(/'/g,"\\'")+'\','+e.saldo_vacaciones+')">'
      + 'Registrar días ya tomados</button></p></div>'
      + '</section>'

      + '<section class="ex-sec"><h4>Datos personales</h4>'
      + '<div class="ex-grid">'
      + dato('Sexo', e.sexo) + dato('Edad', e.edad ? e.edad+' años' : null)
      + dato('Estado civil', e.estado_civil) + dato('Escolaridad', e.escolaridad)
      + dato('CURP', e.curp) + dato('RFC', e.rfc) + dato('NSS', e.nss)
      + dato('Teléfono', e.telefono) + dato('Correo', e.email)
      + '</div></section>'

      + '<section class="ex-sec"><h4>Datos laborales</h4>'
      + '<div class="ex-grid">'
      + dato('Departamento', e.departamento)
      + dato('Tipo de puesto', e.tipo_puesto)
      + dato('Contratación', e.tipo_contrato)
      + dato('Tipo de personal', e.tipo_personal)
      + dato('Registra asistencia',
          (CAT_METODO.find(m => m[0] === e.metodo_checada)||[])[1])
      + '</div></section>'

      + (jorn.length
          ? '<section class="ex-sec"><h4>Últimos días</h4>'
            + '<div class="ex-jorn">'
            + jorn.map(j => {
                const est = EST_ASIS[j.estatus] || EST_ASIS.pendiente;
                return '<div class="ex-j">'
                  + '<span class="ex-jf">'+new Date(j.fecha+'T12:00').toLocaleDateString(
                      'es-MX',{day:'2-digit',month:'short'})+'</span>'
                  + '<span class="tb-badge" style="color:'+est.color+';background:'+est.bg+'">'
                  + est.txt+'</span>'
                  + '<span class="ex-jh num">'+hhmm(j.entrada)+' – '+hhmm(j.salida)+'</span>'
                  + '</div>';
              }).join('')
            + '</div></section>'
          : ''),
    acciones:
      '<button class="btn-sec-claro" onclick="editarEmpleado(\''+id+'\')">'
      + '<i class="fas fa-pen"></i> Editar</button>'
      + '<button class="btn-sec-claro" onclick="asignarTurnoA(\''+id+'\',\''
      + e.nombre_completo.replace(/'/g,"\\'")+'\')">'
      + '<i class="fas fa-clock-rotate-left"></i> Turno</button>'
      + '<button class="btn-sec-claro" onclick="abrirDocumentos(\''+id+'\',\''
      + e.nombre_completo.replace(/'/g,"\\'")+'\')">'
      + '<i class="fas fa-folder-open"></i> Documentos</button>'
      + (e.estatus === 'Activo'
          ? '<button class="btn-peligro" onclick="bajaEmpleado(\''+id+'\',\''
            + e.nombre_completo.replace(/'/g,"\\'")+'\')">Dar de baja</button>'
          : '<button class="btn-pri" onclick="reactivarEmpleado(\''+id+'\')">'
            + 'Reactivar</button>')
  });
}

async function editarEmpleado(id){
  const { data } = await sb.rpc('obtener_empleado', { p_id: id });
  const e = data.empleado;
  const centros = await centrosOpc();

  const r = await modal({
    titulo: 'Editar expediente',
    subtitulo: e.nombre_completo,
    campos: [
      { k:'apellido_paterno', label:'Apellido paterno', t:'texto', req:true,
        valor:e.apellido_paterno, ancho:'mitad' },
      { k:'apellido_materno', label:'Apellido materno', t:'texto',
        valor:e.apellido_materno, ancho:'mitad' },
      { k:'nombres', label:'Nombre(s)', t:'texto', req:true, valor:e.nombres },

      { k:'sexo', label:'Sexo', t:'select', opciones:CAT_SEXO,
        valor:e.sexo, ancho:'mitad' },
      { k:'fecha_nacimiento', label:'Fecha de nacimiento', t:'fecha',
        valor:e.fecha_nacimiento, ancho:'mitad' },
      { k:'estado_civil', label:'Estado civil', t:'select', opciones:CAT_CIVIL,
        valor:e.estado_civil, ancho:'mitad' },
      { k:'escolaridad', label:'Escolaridad', t:'select', opciones:CAT_ESCOLARIDAD,
        valor:e.escolaridad, ancho:'mitad' },

      // 18 y 13 caracteres: se valida forma, no existencia.
      // Verificar contra RENAPO o el SAT requiere sus servicios;
      // un CURP de 12 letras sí es un error de dedo atrapable.
      { k:'curp', label:'CURP', t:'texto', valor:e.curp, max:18, ancho:'mitad',
        patron:'[A-Za-z]{4}\\d{6}[A-Za-z0-9]{8}',
        nota:'18 caracteres' },
      { k:'rfc', label:'RFC', t:'texto', valor:e.rfc, max:13, ancho:'mitad',
        patron:'[A-Za-z]{3,4}\\d{6}[A-Za-z0-9]{3}',
        nota:'13 caracteres con homoclave' },
      { k:'nss', label:'NSS', t:'texto', valor:e.nss, max:11, ancho:'mitad',
        nota:'11 dígitos' },
      { k:'telefono', label:'Teléfono', t:'tel', valor:e.telefono, ancho:'mitad' },
      { k:'email', label:'Correo', t:'mail', valor:e.email },

      { k:'centro_id', label:'Centro de trabajo', t:'select', opciones:centros,
        valor:e.centro_id, ancho:'mitad' },
      { k:'fecha_ingreso', label:'Fecha de ingreso', t:'fecha',
        valor:e.fecha_ingreso, ancho:'mitad',
        nota:'Cambiarla recalcula sus días de vacaciones.' },
      { k:'puesto', label:'Puesto', t:'texto', valor:e.puesto, ancho:'mitad' },
      { k:'departamento', label:'Departamento', t:'texto',
        valor:e.departamento, ancho:'mitad' },
      { k:'tipo_puesto', label:'Tipo de puesto', t:'select', opciones:CAT_TIPO_PUESTO,
        valor:e.tipo_puesto, ancho:'mitad' },
      { k:'tipo_contrato', label:'Contratación', t:'select', opciones:CAT_CONTRATO,
        valor:e.tipo_contrato, ancho:'mitad' },
      { k:'tipo_personal', label:'Tipo de personal', t:'select', opciones:CAT_PERSONAL,
        valor:e.tipo_personal, ancho:'mitad' },
      { k:'metodo_checada', label:'Registra asistencia', t:'select',
        opciones:CAT_METODO, valor:e.metodo_checada, ancho:'mitad',
        nota:'REPSE, honorarios y directivos suelen ser "no registra".' }
    ]
  });
  if(!r) return;

  const { error } = await sb.rpc('actualizar_empleado', { p_id:id, p_datos:r });
  if(error){ toast('error', error.message); return; }
  toast('ok', 'Expediente actualizado');
  cerrarPanel();
  await pintarEmpleados();
  verEmpleado(id);
}

async function bajaEmpleado(id, nombre){
  const r = await modal({
    titulo: 'Dar de baja',
    subtitulo: nombre + '. El expediente se conserva completo: la baja no borra nada.',
    ok: 'Confirmar baja', peligro: true,
    campos: [
      { k:'fecha', label:'Fecha de baja', t:'fecha', req:true,
        valor: new Date().toLocaleDateString('sv-SE') },
      { k:'motivo', label:'Motivo', t:'area', req:true,
        nota:'Queda en la bitácora con tu nombre y la fecha.' }
    ]
  });
  if(!r) return;

  const { data, error } = await sb.rpc('dar_baja_empleado', {
    p_id:id, p_fecha:r.fecha, p_motivo:r.motivo });
  if(error){ toast('error', error.message); return; }

  cerrarPanel();
  await pintarEmpleados();

  // Se avisa el saldo pendiente: callarlo sería esconder una
  // obligación de pago que RH tiene que finiquitar.
  const saldo = +data.saldo_vacaciones;
  if(saldo > 0){
    modal({
      titulo: 'Baja registrada',
      subtitulo: nombre + ' tenía ' + saldo.toFixed(0) + ' día(s) de vacaciones '
        + 'sin disfrutar. Deben cubrirse en el finiquito junto con la prima '
        + 'vacacional correspondiente.',
      ok: 'Entendido', cancelar: ''
    });
  } else {
    toast('ok', 'Baja registrada');
  }
}

async function reactivarEmpleado(id){
  const r = await confirmar({
    titulo: 'Reactivar empleado',
    mensaje: 'Volverá a aparecer como activo y se recalcularán sus vacaciones.',
    ok: 'Reactivar', peligro: false, pedirMotivo: true
  });
  if(!r) return;
  const { error } = await sb.rpc('reactivar_empleado', { p_id:id, p_motivo:r.motivo });
  if(error){ toast('error', error.message); return; }
  toast('ok', 'Empleado reactivado');
  cerrarPanel();
  pintarEmpleados();
}

async function moduloEmpleados(){
  const cont = document.getElementById('contenido');
  cont.innerHTML =
    '<div class="emp-barra">'
    + '<div class="emp-busca">'
    + '<i class="fas fa-magnifying-glass"></i>'
    + '<input type="search" placeholder="Buscar por nombre, número o puesto" '
    + 'oninput="empBuscar(this.value)" value="'+_empFiltro.buscar+'">'
    + '</div>'
    + '<select onchange="empEstatus(this.value)" class="emp-sel">'
    + '<option value="Activo">Activos</option>'
    + '<option value="Baja">Bajas</option>'
    + '<option value="Todos">Todos</option>'
    + '</select>'
    + (Sesion.esAdmin
        ? '<button class="btn-pri" onclick="nuevoEmpleado()">'
          + '<i class="fas fa-plus"></i> Nuevo empleado</button>'
        : '')
    + '</div>'
    + '<div id="emp-cuerpo"></div>';

  document.querySelector('.emp-sel').value = _empFiltro.estatus;
  await pintarEmpleados();
}