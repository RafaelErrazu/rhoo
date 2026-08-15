// ═══════════════════════════════════════════════════════════
//  RHoo! · Módulo Configuración
//  Los parámetros los define el admin de cada cliente. Los
//  mínimos de ley se muestran como referencia fija, no como
//  campo editable.
// ═══════════════════════════════════════════════════════════

const CFG_SECCIONES = [
  {
    id: 'asistencia',
    titulo: 'Asistencia',
    ayuda: 'Cómo se interpretan las checadas al calcular el día.',
    campos: [
      { k:'tolerancia_retardo_min', t:'num', min:0, max:60, sufijo:'min',
        label:'Tolerancia antes de contar retardo',
        nota:'Llegar dentro de este margen cuenta como puntual.' },
      { k:'minutos_para_falta', t:'num', min:0, max:480, sufijo:'min',
        label:'Retraso que ya se considera falta',
        nota:'Pasado este punto el día se marca como falta, no como retardo.' },
      { k:'retardos_para_falta', t:'num', min:0, max:10, sufijo:'retardos',
        label:'Retardos que equivalen a una falta',
        nota:'0 desactiva la acumulación.' },
      { k:'descuenta_tiempo_retardo', t:'bool',
        label:'Descontar del sueldo el tiempo del retardo',
        nota:'Si se apaga, el retardo solo se registra y acumula.' },
      { k:'checada_faltante', t:'opc',
        opciones:[
          ['incompleta','Dejar el día incompleto para que RH lo revise'],
          ['asumir_salida','Asumir la hora de salida del turno']
        ],
        label:'Cuando falta la checada de salida',
        nota:'Asumir la salida inventa un dato que puede terminar en un juicio laboral. Recomendado: dejarlo incompleto.' }
    ]
  },
  {
    id: 'ubicacion',
    titulo: 'Registro y ubicación',
    ayuda: 'Requisitos para que una checada se acepte.',
    campos: [
      { k:'geocerca_activa', t:'bool',
        label:'Validar que la checada ocurra en el centro de trabajo' },
      { k:'geocerca_radio_m', t:'num', min:20, max:2000, sufijo:'m',
        label:'Radio permitido', dep:'geocerca_activa',
        nota:'Menos de 100 m genera falsos rechazos: el GPS de un celular dentro de un edificio se desvía fácil.' },
      { k:'requiere_selfie', t:'bool',
        label:'Pedir fotografía al checar' }
    ]
  },
  {
    id: 'extras',
    titulo: 'Horas extra',
    ayuda: 'La LFT topa las extras en 3 horas diarias y 3 veces por semana (art. 66), y las primeras 9 de la semana se pagan al doble (art. 67).',
    campos: [
      { k:'extras_modo', t:'opc',
        opciones:[
          ['autorizacion','Requieren autorización previa del jefe'],
          ['automatico','Se cuentan solas al quedarse después del turno']
        ],
        label:'Cómo se generan',
        nota:'En automático, cualquier persona que se queda platicando genera tiempo extra pagable.' },
      { k:'extras_min_para_contar', t:'num', min:0, max:120, sufijo:'min',
        label:'Mínimo para empezar a contar',
        nota:'Evita registrar extras por 3 minutos de más.' }
    ]
  },
  {
    id: 'vacaciones',
    titulo: 'Vacaciones',
    ayuda: 'Los días de ley los calcula el sistema según el art. 76 de la LFT y no se editan. Aquí defines lo que tu empresa da POR ENCIMA de la ley.',
    fija: 'Días de ley: 12 al primer año, +2 por año hasta 20 al quinto, y +2 por cada 5 años después.',
    campos: [
      { k:'vac_dias_extra', t:'num', min:0, max:30, sufijo:'días',
        label:'Días adicionales sobre la ley',
        nota:'Se suman a lo que corresponde por antigüedad.' },
      { k:'prima_vacacional_pct', t:'num', min:25, max:100, sufijo:'%',
        label:'Prima vacacional',
        nota:'Mínimo legal 25% (LFT art. 80). El sistema rechaza valores menores.' },
      { k:'vac_anticipacion_dias', t:'num', min:0, max:90, sufijo:'días',
        label:'Anticipación mínima para solicitar' },
      { k:'vac_max_dias_continuos', t:'num', min:0, max:60, sufijo:'días',
        label:'Máximo de días continuos',
        nota:'0 = sin límite. Ojo: el art. 78 obliga a otorgar al menos 12 días continuos si el trabajador los pide.' }
    ]
  },
  {
    id: 'incidencias',
    titulo: 'Permisos e incidencias',
    campos: [
      { k:'inc_aprueba', t:'opc',
        opciones:[['rh','Recursos Humanos'],['jefe','El jefe directo'],['ambos','Ambos deben aprobar']],
        label:'Quién autoriza' },
      { k:'inc_requiere_doc_dias', t:'num', min:0, max:30, sufijo:'días',
        label:'Exigir comprobante a partir de',
        nota:'Ausencias más largas que esto piden documento adjunto.' }
    ]
  },
  {
    id: 'checadores',
    titulo: 'Checadores físicos',
    ayuda: 'Los dispositivos se registran uno por uno en Asistencia. Aquí van solo las reglas generales.',
    campos: [
      { k:'metodo_checada_default', t:'opc',
        opciones:[
          ['ambos','Checador o celular, según convenga'],
          ['dispositivo','Solo en el checador del centro'],
          ['movil','Solo desde el celular'],
          ['ninguno','No registran asistencia']
        ],
        label:'Método para empleados nuevos',
        nota:'Se cambia por persona: los foráneos y el personal REPSE casi siempre son la excepción.' },
      { k:'dispositivo_alerta_horas', t:'num', min:1, max:72, sufijo:'horas',
        label:'Avisar si un checador deja de reportar',
        nota:'Un reloj desconectado no se nota hasta que falta un día completo de registros.' }
    ]
  },
  {
    id: 'cumplimiento',
    titulo: 'Cumplimiento (NOM-035)',
    ayuda: 'Criterios de la evaluación de riesgo psicosocial.',
    fija: 'Centros de 1 a 15 trabajadores solo aplican la Guía I. Ese umbral lo fija la Norma y no se configura.',
    campos: [
      { k:'nom035_meses_vigencia', t:'num', min:1, max:24, sufijo:'meses',
        label:'Vigencia de la evaluación',
        nota:'La Norma pide repetirla al menos cada 24 meses. Puedes evaluar más seguido, no menos.' },
      { k:'nom035_dias_aviso', t:'num', min:1, max:365, sufijo:'días',
        label:'Avisar antes del vencimiento',
        nota:'Aplicar el cuestionario a un centro completo toma semanas: avisar con 30 días es avisar tarde.' },
      { k:'nom035_min_publicable', t:'num', min:1, max:50, sufijo:'respuestas',
        label:'Mínimo para publicar resultados al personal',
        nota:'Con pocas respuestas los porcentajes permiten deducir quién contestó qué.' },
      { k:'nom035_umbral_centro_pct', t:'num', min:1, max:100, sufijo:'%',
        label:'Concentración que define el nivel del centro',
        nota:'Criterio interno: el nivel del centro es el más alto donde se concentra al menos este porcentaje.' },
      { k:'nom035_ajustar_rango_parcial', t:'bool',
        label:'Ajustar rangos cuando se omiten preguntas',
        nota:'Escala los cortes en proporción a las preguntas aplicables. Criterio interno documentado, no viene del DOF.' }
    ]
  }
];

let _cfg = null;        // config vigente
let _cfgEdit = {};      // solo lo que el usuario tocó en esta sesión

async function cargarConfig(){
  const { data, error } = await sb.rpc('obtener_configuracion');
  if(error) throw error;
  _cfg = data.config;
  _cfgEdit = {};
  return data;
}

function _cfgInput(c){
  const val = (_cfgEdit[c.k] !== undefined) ? _cfgEdit[c.k] : _cfg[c.k];

  if(c.t === 'bool'){
    return '<button type="button" class="sw'+(val?' on':'')+'" '
      + 'onclick="cfgSet(\''+c.k+'\', '+(!val)+')" '
      + 'role="switch" aria-checked="'+(!!val)+'"><span></span></button>';
  }
  if(c.t === 'num'){
    return '<div class="cfg-num">'
      + '<input type="number" value="'+val+'" min="'+c.min+'" max="'+c.max+'" '
      + 'oninput="cfgSet(\''+c.k+'\', this.value === \'\' ? \'\' : Number(this.value))">'
      + (c.sufijo ? '<span>'+c.sufijo+'</span>' : '')
      + '</div>';
  }
  // Opciones: se pintan como lista y no como <select> porque las
  // etiquetas son frases completas y en un desplegable no se
  // pueden comparar sin abrirlo.
  return '<div class="cfg-ops">'
    + c.opciones.map(([v,txt]) =>
        '<label class="cfg-op'+(val===v?' on':'')+'">'
        + '<input type="radio" name="'+c.k+'" '+(val===v?'checked':'')+' '
        + 'onchange="cfgSet(\''+c.k+'\', \''+v+'\')">'
        + '<span>'+txt+'</span></label>'
      ).join('')
    + '</div>';
}

function cfgSet(clave, valor){
  _cfgEdit[clave] = valor;
  pintarConfig();          // repinta para que las dependencias reaccionen
  document.getElementById('cfg-barra')?.classList.add('on');
}

function pintarConfig(){
  const sinCambios = Object.keys(_cfgEdit).length === 0;

  document.getElementById('contenido').innerHTML =
    '<div class="cfg-wrap">'
    + CFG_SECCIONES.map(s => {
        const campos = s.campos.map(c => {
          // Campo dependiente: se atenúa en lugar de desaparecer,
          // así se ve que existe y por qué está inactivo.
          const activo = !c.dep || !!((_cfgEdit[c.dep] !== undefined) ? _cfgEdit[c.dep] : _cfg[c.dep]);
          return '<div class="cfg-fila'+(activo?'':' off')+'">'
            + '<div class="cfg-txt">'
            + '<label>'+c.label+'</label>'
            + (c.nota ? '<p>'+c.nota+'</p>' : '')
            + '</div>'
            + '<div class="cfg-ctrl">'+_cfgInput(c)+'</div>'
            + '</div>';
        }).join('');

        return '<section class="cfg-sec">'
          + '<div class="cfg-head">'
          + '<h3>'+s.titulo+'</h3>'
          + (s.ayuda ? '<p>'+s.ayuda+'</p>' : '')
          + '</div>'
          + (s.fija ? '<p class="cfg-ley"><i class="fas fa-scale-balanced"></i>'+s.fija+'</p>' : '')
          + campos
          + '</section>';
      }).join('')
    + '</div>'
    // Barra flotante: guardar arriba obligaría a subir 6 secciones
    // para confirmar un cambio hecho al final.
    + '<div class="cfg-barra'+(sinCambios?'':' on')+'" id="cfg-barra">'
    + '<span id="cfg-cuenta">'+Object.keys(_cfgEdit).length+' cambio(s) sin guardar</span>'
    + '<div>'
    + '<button class="btn-sec" onclick="cfgDescartar()">Descartar</button>'
    + '<button class="btn-pri" onclick="cfgGuardar()" id="cfg-btn">Guardar cambios</button>'
    + '</div></div>';
}

function cfgDescartar(){
  _cfgEdit = {};
  pintarConfig();
}

async function cfgGuardar(){
  const btn = document.getElementById('cfg-btn');
  btn.disabled = true;
  btn.textContent = 'Guardando...';

  const { data, error } = await sb.rpc('guardar_configuracion', { p_cambios: _cfgEdit });

  if(error){
    // El mensaje del trigger es legible a propósito: dice qué
    // regla se violó y cuál es el mínimo. Se muestra tal cual.
    toast('error', error.message);
    btn.disabled = false;
    btn.textContent = 'Guardar cambios';
    return;
  }
  _cfg = data.config;
  _cfgEdit = {};
  pintarConfig();
  toast('ok', 'Configuración guardada');
}

async function moduloConfig(){
  document.getElementById('contenido').innerHTML =
    '<p class="cargando"><i class="fas fa-spinner fa-spin"></i> Cargando configuración...</p>';
  try{
    const d = await cargarConfig();
    if(!d.editable){
      document.getElementById('contenido').innerHTML =
        '<div class="vacio"><i class="fas fa-lock"></i>'
        + '<h3>Sin permiso</h3><p>Solo administradores pueden ver la configuración.</p></div>';
      return;
    }
    pintarConfig();
  }catch(e){
    document.getElementById('contenido').innerHTML =
      '<div class="vacio"><i class="fas fa-triangle-exclamation"></i>'
      + '<h3>No se pudo cargar</h3><p>'+e.message+'</p></div>';
  }
}
