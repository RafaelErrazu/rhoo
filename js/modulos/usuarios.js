// ═══════════════════════════════════════════════════════════
//  RHoo! · Usuarios
// ═══════════════════════════════════════════════════════════

const ROLES = {
  superadmin:  { t:'Proveedor',    d:'Acceso a todos los clientes', n:5 },
  admin:       { t:'Administrador',d:'Configura todo su empresa',   n:4 },
  rh:          { t:'Recursos Humanos', d:'Opera el sistema día a día', n:3 },
  jefe:        { t:'Jefe',         d:'Ve y autoriza a su equipo',   n:2 },
  colaborador: { t:'Colaborador',  d:'Solo sus propios datos',      n:1 }
};

const miNivel = () => ROLES[Sesion.rol]?.n || 0;

async function pintarUsuarios(){
  const cont = document.getElementById('us-cuerpo');
  cont.innerHTML = '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando...</p>';

  const { data, error } = await sb.rpc('usuarios_lista');
  if(error){ cont.innerHTML = '<p class="cargando">'+error.message+'</p>'; return; }

  const us = data || [];
  const nuncaEntraron = us.filter(u => u.nunca_entro && u.activo).length;

  cont.innerHTML =
    '<div class="cu-head"><div><h3>Usuarios</h3>'
    + '<p>Quienes pueden entrar a RHoo!. Distinto de los empleados: no todo '
    + 'empleado necesita cuenta, y no toda cuenta es de un empleado.</p></div>'
    + '<button class="btn-pri" onclick="nuevoUsuario()">'
    + '<i class="fas fa-user-plus"></i> Nuevo usuario</button></div>'

    // Cuenta creada y nunca usada: casi siempre significa que la
    // contraseña no llegó a su destino.
    + (nuncaEntraron
        ? '<p class="aviso" style="background:#FEF3E2;color:#92400E">'
          + '<i class="fas fa-envelope" style="color:#B45309"></i>'
          + nuncaEntraron+' cuenta(s) creadas que nunca han entrado. '
          + 'Probablemente la contraseña no les llegó: puedes restablecerla.</p>'
        : '')

    + '<div class="us-lista">'
    + us.map(u => {
        const r = ROLES[u.rol] || { t:u.rol, d:'' };
        const puedoEditar = (r.n || 0) < miNivel() || Sesion.rol === 'superadmin';
        return '<div class="us-item'+(u.activo?'':' off')+'">'
          + '<span class="avatar">'+iniciales(u.nombre)+'</span>'
          + '<div class="us-info">'
          + '<b>'+u.nombre+(u.es_yo?' <em>(tú)</em>':'')+'</b>'
          + '<span>'+u.email+'</span>'
          + (u.empleado ? '<span class="us-emp">Ligado a '+u.empleado+'</span>' : '')
          + (Sesion.rol === 'superadmin' && u.tenant
              ? '<span class="us-emp">'+u.tenant+'</span>' : '')
          + '</div>'
          + '<div class="us-meta">'
          + '<span class="us-rol">'+r.t+'</span>'
          + (!u.activo ? '<span class="us-est">Inactivo</span>' : '')
          + (u.nunca_entro && u.activo
              ? '<span class="us-nunca">Nunca ha entrado</span>'
              : u.ultimo_acceso
                ? '<span class="us-acc">'
                  + new Date(u.ultimo_acceso).toLocaleDateString('es-MX')+'</span>'
                : '')
          + (u.debe_cambiar ? '<span class="us-temp">Contraseña temporal</span>' : '')
          + '</div>'
          + (puedoEditar && !u.es_yo
              ? '<div class="us-acc-btn">'
                + '<button onclick="editarUsuario(\''+u.id+'\')" title="Editar">'
                + '<i class="fas fa-pen"></i></button>'
                + '<button onclick="resetPassword(\''+u.id+'\',\''
                + u.nombre.replace(/'/g,"")+'\')" title="Restablecer contraseña">'
                + '<i class="fas fa-key"></i></button>'
                + '<button onclick="activarUsuario(\''+u.id+'\','+(!u.activo)+',\''
                + u.nombre.replace(/'/g,"")+'\')" '
                + 'title="'+(u.activo?'Desactivar':'Activar')+'">'
                + '<i class="fas fa-'+(u.activo?'ban':'check')+'"></i></button>'
                + '</div>'
              : '')
          + '</div>';
      }).join('')
    + '</div>';
}

async function nuevoUsuario(){
  // Solo roles por debajo del propio: la interfaz refleja lo que
  // la base ya valida, para no ofrecer algo que va a fallar.
  const disponibles = Object.entries(ROLES)
    .filter(([,r]) => r.n < miNivel() || Sesion.rol === 'superadmin')
    .sort((a,b) => b[1].n - a[1].n)
    .map(([k,r]) => [k, r.t + ' · ' + r.d]);

  if(!disponibles.length){
    toast('error','Tu rol no permite crear usuarios');
    return;
  }

  let tenants = [];
  if(Sesion.rol === 'superadmin'){
    const { data } = await sb.rpc('tenants_lista');
    tenants = (data||[]).map(t => [t.id, t.nombre]);
  }

  const { data: emps } = await sb.rpc('empleados_sin_usuario');

  const r = await modal({
    titulo:'Nuevo usuario',
    subtitulo:'Se crea la cuenta y se genera una contraseña temporal que deberá '
      + 'cambiar al entrar.',
    ok:'Crear usuario',
    campos:[
      ...(tenants.length
          ? [{ k:'tenant_id', label:'Empresa', t:'select', req:true,
               opciones:tenants, valor:Sesion.perfil.tenant_id }]
          : []),
      { k:'nombre', label:'Nombre completo', t:'texto', req:true },
      { k:'email', label:'Correo', t:'mail', req:true,
        nota:'Con este correo va a entrar.' },
      { k:'rol', label:'Rol', t:'select', req:true, opciones:disponibles },
      { k:'empleado_id', label:'Ligar a un empleado', t:'select',
        opciones:[['','No ligar']].concat(
          (emps||[]).map(e => [e.id, e.nombre + ' · #' + e.no])),
        nota:'Necesario para que pueda checar asistencia y pedir vacaciones.' }
    ]
  });
  if(!r) return;

  const { data, error } = await sb.functions.invoke('crear-usuario', {
    body: {
      email: r.email, nombre: r.nombre, rol: r.rol,
      tenant_id: r.tenant_id || Sesion.perfil.tenant_id,
      empleado_id: r.empleado_id || null
    }
  });

  if(error || data?.status === 'error'){
    toast('error', data?.message || 'No se pudo crear el usuario');
    return;
  }

  // La contraseña se muestra UNA vez. No se guarda en ninguna
  // parte recuperable: si se pierde, se restablece.
  mostrarCredenciales(r.nombre, data.email, data.password);
  pintarUsuarios();
}

function mostrarCredenciales(nombre, email, password){
  const texto = 'Acceso a RHoo!\n\n'
    + 'Dirección: ' + location.origin + '\n'
    + 'Usuario: ' + email + '\n'
    + 'Contraseña temporal: ' + password + '\n\n'
    + 'Al entrar se te pedirá cambiarla.';

  panel({
    titulo:'Cuenta creada',
    subtitulo: nombre,
    html:
      '<div class="aviso" style="background:#FEF3E2;color:#92400E;margin-bottom:16px">'
      + '<i class="fas fa-triangle-exclamation" style="color:#B45309"></i>'
      + '<div><b>Esta contraseña se muestra una sola vez.</b> Cópiala ahora y '
      + 'compártela con la persona. Si se pierde, tendrás que restablecerla.</div></div>'
      + '<div class="cred">'
      + '<div class="cred-f"><span>Dirección</span><b>'+location.origin+'</b></div>'
      + '<div class="cred-f"><span>Usuario</span><b>'+email+'</b></div>'
      + '<div class="cred-f cred-pass"><span>Contraseña temporal</span>'
      + '<b>'+password+'</b></div>'
      + '</div>'
      + '<button class="btn-pri" style="width:100%;margin-top:14px" '
      + 'onclick="copiarCred()"><i class="fas fa-copy"></i> '
      + 'Copiar mensaje completo</button>'
      + '<textarea id="cred-txt" style="position:absolute;left:-9999px">'
      + texto + '</textarea>'
  });
}

function copiarCred(){
  const t = document.getElementById('cred-txt');
  navigator.clipboard.writeText(t.value)
    .then(() => toast('ok','Mensaje copiado. Pégalo donde vayas a compartirlo.'))
    .catch(() => { t.style.position='static'; t.select(); toast('error','Cópialo a mano'); });
}

async function editarUsuario(id){
  const { data } = await sb.rpc('usuarios_lista');
  const u = (data||[]).find(x => x.id === id);
  if(!u) return;

  const disponibles = Object.entries(ROLES)
    .filter(([,r]) => r.n < miNivel() || Sesion.rol === 'superadmin')
    .sort((a,b) => b[1].n - a[1].n)
    .map(([k,r]) => [k, r.t]);

  const { data: emps } = await sb.rpc('empleados_sin_usuario');
  const opcEmp = [['','No ligar']]
    .concat(u.empleado_id ? [[u.empleado_id, u.empleado + ' (actual)']] : [])
    .concat((emps||[]).map(e => [e.id, e.nombre + ' · #' + e.no]));

  const r = await modal({
    titulo:'Editar usuario',
    subtitulo: u.email,
    campos:[
      { k:'nombre', label:'Nombre', t:'texto', req:true, valor:u.nombre },
      { k:'rol', label:'Rol', t:'select', req:true,
        opciones:disponibles, valor:u.rol },
      { k:'empleado_id', label:'Ligado a', t:'select',
        opciones:opcEmp, valor:u.empleado_id || '' }
    ]
  });
  if(!r) return;

  const { error } = await sb.rpc('usuario_actualizar', { p_id:id, p_datos:r });
  if(error){ toast('error', error.message); return; }
  toast('ok','Usuario actualizado');
  pintarUsuarios();
}

async function resetPassword(id, nombre){
  const ok = await confirmar({
    titulo:'Restablecer contraseña',
    mensaje:'Se generará una contraseña temporal nueva para '+nombre
      + '. La anterior dejará de funcionar de inmediato.',
    ok:'Restablecer', peligro:false });
  if(!ok) return;

  const { data, error } = await sb.functions.invoke('reset-password',
    { body: { user_id: id } });

  if(error || data?.status === 'error'){
    toast('error', data?.message || 'No se pudo restablecer');
    return;
  }

  const { data: us } = await sb.rpc('usuarios_lista');
  const u = (us||[]).find(x => x.id === id);
  mostrarCredenciales(nombre, u?.email || '', data.password);
  pintarUsuarios();
}

async function activarUsuario(id, activar, nombre){
  const r = await modal({
    titulo: activar ? 'Activar usuario' : 'Desactivar usuario',
    subtitulo: activar
      ? nombre + ' podrá entrar de nuevo.'
      : nombre + ' no podrá entrar. Su cuenta y su rastro en la bitácora se '
        + 'conservan: desactivar no borra.',
    ok: activar ? 'Activar' : 'Desactivar',
    peligro: !activar,
    campos: activar ? [] : [{ k:'motivo', label:'Motivo', t:'area', req:true }]
  });
  if(!r) return;

  const { error } = await sb.rpc('usuario_activar', {
    p_id:id, p_activo:activar, p_motivo:r.motivo || null });
  if(error){ toast('error', error.message); return; }
  toast('ok', activar ? 'Usuario activado' : 'Usuario desactivado');
  pintarUsuarios();
}

/* Cambio de contraseña obligatorio.
   Se pide al entrar, no se sugiere: una contraseña temporal que
   nunca se cambia es una contraseña compartida por WhatsApp que
   sigue siendo válida meses después. */
async function pedirCambioPassword(){
  const r = await modal({
    titulo:'Cambia tu contraseña',
    subtitulo:'Tu cuenta se creó con una contraseña temporal. Elige una propia '
      + 'para continuar.',
    ok:'Guardar y continuar',
    cancelar:'',
    campos:[
      { k:'p1', label:'Nueva contraseña', t:'texto', req:true,
        nota:'Al menos 8 caracteres.' },
      { k:'p2', label:'Repítela', t:'texto', req:true }
    ]
  });
  if(!r) return pedirCambioPassword();   // no se puede cancelar

  if(r.p1.length < 8){
    toast('error','Debe tener al menos 8 caracteres');
    return pedirCambioPassword();
  }
  if(r.p1 !== r.p2){
    toast('error','Las contraseñas no coinciden');
    return pedirCambioPassword();
  }

  const { error } = await sb.auth.updateUser({ password: r.p1 });
  if(error){
    toast('error', error.message);
    return pedirCambioPassword();
  }

  await sb.rpc('password_cambiada');
  Sesion.perfil.debe_cambiar_password = false;
  toast('ok','Contraseña actualizada');
}

async function moduloUsuarios(){
  document.getElementById('contenido').innerHTML = '<div id="us-cuerpo"></div>';
  await pintarUsuarios();
}