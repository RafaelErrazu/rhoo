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
      + (Sesion.esAdmin
          ? '<button class="btn-sec-claro" onclick="verSueldo(\'' + id + '\')">'
            + '<i class="fas fa-money-bill-wave"></i> Sueldo</button>'
          : '')
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
/* ═══════════════════════════════════════════════════════════
   Sueldo y prestaciones
   En panel aparte y solo para admin/RH: el salario no se pone
   inline en el expediente porque cualquier jefe que revise a su
   equipo lo veria, y eso no se puede deshacer.
   ═══════════════════════════════════════════════════════════ */

const SD_TIPO = { fijo:'Fijo', variable:'Variable', mixto:'Mixto' };

function sdM(n){
  return (Number(n)||0).toLocaleString('es-MX',
    { minimumFractionDigits:2, maximumFractionDigits:2 });
}

function sdFecha(f){
  if(!f) return '—';
  return new Date(f+'T12:00').toLocaleDateString('es-MX',
    { day:'2-digit', month:'short', year:'numeric' });
}

async function verSueldo(empId){
  const { data, error } = await sb.rpc('nomina_sueldo_historial',
    { p_empleado_id: empId });
  if(error){ toast('error', error.message); return; }

  const e = data.empleado;
  const h = data.historial || [];
  const vig = h.find(x => x.vigente);
  const sdi = data.sdi || {};

  panel({
    titulo:'Sueldo · '+e.nombre,
    subtitulo:'#'+e.no_empleado+' · ingreso '+sdFecha(e.fecha_ingreso),
    html:
      (vig
        ? '<div class="sd-hoy">'
          + '<div class="sd-hoy-num">'
          + '<b>'+sdM(vig.sueldo_diario)+'</b>'
          + '<span>sueldo diario</span></div>'
          + '<div class="sd-hoy-num">'
          + '<b>'+sdM(sdi.sdi)+'</b>'
          + '<span>SDI</span></div>'
          + '<div class="sd-hoy-num">'
          + '<b>'+sdM(Number(vig.sueldo_diario) * 30.4)+'</b>'
          + '<span>mensual aprox.</span></div>'
          + '</div>'

          // El SDI armado paso a paso: es el numero que se reporta al IMSS y
          // nadie lo recuerda de memoria. Verlo desglosado evita la llamada
          // al contador cada vez que alguien lo cuestiona.
          + '<h4 class="sd-h">Cómo se integra el SDI</h4>'
          + '<div class="sd-calc">'
          + '<div class="sd-ln"><span>Sueldo diario</span>'
          + '<b>'+sdM(sdi.sueldo_diario)+'</b></div>'
          + (Number(sdi.otras_prestaciones)
            ? '<div class="sd-ln"><span>Otras prestaciones que integran</span>'
              + '<b>'+sdM(sdi.otras_prestaciones)+'</b></div>' : '')
          + '<div class="sd-ln"><span>Factor de integración'
          + ' <em>'+sdi.dias_aguinaldo+' días de aguinaldo · '
          + sdi.dias_vacaciones+' de vacaciones × '
          + Math.round(Number(sdi.prima_vac_pct)*100)+'% de prima</em></span>'
          + '<b>'+Number(sdi.factor).toFixed(4)+'</b></div>'
          + '<div class="sd-ln tot"><span>SDI</span>'
          + '<b>'+sdM(sdi.sdi)+'</b></div>'
          + (sdi.excede_tope
            ? '<div class="sd-tope"><i class="fas fa-triangle-exclamation"></i>'
              + '<span>El SDI rebasa el tope de 25 UMAs ('
              + sdM(sdi.tope)+'). Para IMSS se cotiza topado en '
              + sdM(sdi.sdi_topado)+'.</span></div>'
            : '')
          + '</div>'

          + '<h4 class="sd-h">Datos del registro vigente</h4>'
          + '<div class="ex-grid">'
          + '<div class="ex-dato"><span>Grupo de pago</span><b>'
          + (vig.grupo ? vig.grupo+' · '+vig.grupo_nombre
              : '<em class="sd-falta">Sin asignar</em>')+'</b></div>'
          + '<div class="ex-dato"><span>Tipo</span><b>'
          + (SD_TIPO[vig.tipo]||vig.tipo)+'</b></div>'
          + '<div class="ex-dato"><span>Vigente desde</span><b>'
          + sdFecha(vig.desde)+'</b></div>'
          + '<div class="ex-dato"><span>Zona</span><b>'
          + (vig.zona_frontera ? 'Frontera norte' : 'General')+'</b></div>'
          + '<div class="ex-dato"><span>Banco</span><b>'
          + (vig.banco || '—')+'</b></div>'
          + '<div class="ex-dato"><span>CLABE</span><b>'
          + (vig.clabe || '—')+'</b></div>'
          + '</div>'

        : '<div class="sd-sin">'
          + '<i class="fas fa-circle-exclamation"></i>'
          + '<div><b>Sin sueldo registrado</b>'
          + '<p>Sin esto no entra a ningún periodo de nómina: al calcular '
          + 'aparece en la lista de pendientes y nadie le paga.</p></div>'
          + '</div>')

      + (h.length
        ? '<h4 class="sd-h">Historial</h4>'
          + '<div class="sd-hist">'
          + h.map(s => '<div class="sd-item'+(s.vigente?' on':'')+'">'
              + '<div class="sd-item-top">'
              + '<b>'+sdM(s.sueldo_diario)+'</b>'
              + '<span class="sd-rango">'+sdFecha(s.desde)+' → '
              + (s.hasta ? sdFecha(s.hasta) : 'actual')+'</span>'
              + (s.vigente ? '<span class="sd-tag">Vigente</span>' : '')
              + '</div>'
              + '<span class="sd-item-sub">'
              + (s.grupo ? s.grupo+' · ' : '')
              + (SD_TIPO[s.tipo]||s.tipo)
              + ' · aguinaldo '+s.dias_aguinaldo+' d'
              + ' · prima '+Math.round(Number(s.prima_vac_pct)*100)+'%'
              + (Number(s.otras_prestaciones)
                  ? ' · prestaciones '+sdM(s.otras_prestaciones) : '')
              + '</span>'
              + (s.motivo ? '<span class="sd-motivo">'+s.motivo+'</span>' : '')
              + (s.capturo
                  ? '<span class="sd-item-sub">Capturó '+s.capturo+'</span>' : '')
              + '</div>').join('')
          + '</div>'
        : '')

      + '<p class="sd-nota">Un cambio de sueldo no reescribe el registro '
      + 'anterior: cierra su vigencia y crea uno nuevo. Así la nómina de un '
      + 'periodo pasado se puede recalcular con el sueldo que la persona '
      + 'tenía entonces.</p>',

    acciones:'<button class="btn-pri" onclick="nuevoSueldo(\''+empId+'\')">'
      + '<i class="fas '+(vig?'fa-arrow-trend-up':'fa-plus')+'"></i> '
      + (vig ? 'Registrar cambio' : 'Registrar sueldo')+'</button>'
  });
}

async function nuevoSueldo(empId){
  const { data, error } = await sb.rpc('nomina_sueldo_historial',
    { p_empleado_id: empId });
  if(error){ toast('error', error.message); return; }

  const h = data.historial || [];
  const vig = h.find(x => x.vigente);
  const gs = data.grupos || [];
  const min = data.minimos || {};

  if(!gs.length){
    toast('error','Primero crea un grupo de pago en Prenómina');
    return;
  }

  // El dia siguiente al ultimo cambio: registrar un sueldo con vigencia
  // anterior al actual dejaria dos sueldos vigentes el mismo dia.
  let sug = new Date().toLocaleDateString('sv-SE');
  if(vig){
    const d = new Date(vig.desde+'T12:00');
    d.setDate(d.getDate() + 1);
    const hoy = new Date();
    sug = (d > hoy ? d : hoy).toLocaleDateString('sv-SE');
  }

  const r = await modal({
    titulo: vig ? 'Cambio de sueldo' : 'Registrar sueldo',
    subtitulo: vig
      ? 'El sueldo actual de '+sdM(vig.sueldo_diario)+' se cierra el día '
        + 'anterior a la nueva vigencia.'
      : 'Mínimo vigente: '+sdM(min.general)+' general, '
        + sdM(min.frontera)+' en frontera norte.',
    ok: vig ? 'Aplicar cambio' : 'Guardar',
    campos:[
      { k:'sueldo', label:'Sueldo diario', t:'num', req:true, ancho:'mitad',
        valor: vig ? vig.sueldo_diario : '',
        nota:'No puede ser menor al salario mínimo.' },
      { k:'desde', label:'Vigente desde', t:'fecha', req:true, ancho:'mitad',
        valor: sug },
      { k:'grupo', label:'Grupo de pago', t:'select', req:true, ancho:'mitad',
        valor: vig ? vig.grupo_id : (gs.length === 1 ? gs[0].id : ''),
        opciones: gs.map(g => [g.id, g.clave+' · '+g.nombre+' ('+g.frecuencia+')']),
        nota:'Define cada cuándo se le paga.' },
      { k:'tipo', label:'Tipo de salario', t:'select', req:true, ancho:'mitad',
        valor: vig ? vig.tipo : 'fijo',
        opciones:[['fijo','Fijo'],['variable','Variable'],['mixto','Mixto']] },
      { k:'aguinaldo', label:'Días de aguinaldo', t:'num', req:true, ancho:'mitad',
        valor: vig ? vig.dias_aguinaldo : 15,
        nota:'Mínimo de ley: 15 días.' },
      { k:'prima', label:'Prima vacacional %', t:'num', req:true, ancho:'mitad',
        valor: vig ? Math.round(Number(vig.prima_vac_pct)*100) : 25,
        nota:'Mínimo de ley: 25%.' },
      { k:'prestaciones', label:'Otras prestaciones (diario)', t:'num',
        ancho:'mitad', valor: vig ? vig.otras_prestaciones : 0,
        nota:'Vales o bonos fijos que integran al SDI.' },
      { k:'frontera', label:'Zona frontera norte', t:'select', req:true,
        ancho:'mitad', valor: vig && vig.zona_frontera ? 'si' : 'no',
        opciones:[['no','No'],['si','Sí']] },
      { k:'banco', label:'Banco', t:'texto', ancho:'mitad',
        valor: vig ? (vig.banco||'') : '' },
      { k:'clabe', label:'CLABE', t:'texto', ancho:'mitad', max:18,
        valor: vig ? (vig.clabe||'') : '' },
      { k:'motivo', label:'Motivo', t:'texto',
        valor: vig ? '' : 'Alta',
        nota:'Queda en el historial. Ej. aumento anual, promoción, ajuste.' }
    ]
  });
  if(!r) return;

  const { data: res, error: err2 } = await sb.rpc('nomina_sueldo_guardar', {
    p_empleado_id: empId,
    p_sueldo_diario: Number(r.sueldo),
    p_grupo_id: r.grupo,
    p_desde: r.desde,
    p_tipo: r.tipo,
    p_dias_aguinaldo: Number(r.aguinaldo) || 15,
    // La prima se captura en % porque es como la piensa la gente, y se manda
    // como fraccion porque asi la guarda la base.
    p_prima_vac_pct: (Number(r.prima) || 25) / 100,
    p_otras_prestaciones: Number(r.prestaciones) || 0,
    p_zona_frontera: r.frontera === 'si',
    p_banco: r.banco || null,
    p_clabe: r.clabe || null,
    p_motivo: r.motivo || null
  });
  if(err2){ toast('error', err2.message); return; }

  const nsdi = res.sdi || {};
  toast('ok','Sueldo guardado. SDI '+sdM(nsdi.sdi));
  cerrarPanel();
  verSueldo(empId);
}