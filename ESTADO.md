# RHoo! · Estado del proyecto

> Bitácora viva. Se actualiza al cerrar cada módulo o al descubrir un pendiente.
> Última actualización: 22 de agosto de 2026, 23:50.

---

## Qué es

SaaS multi-tenant de Recursos Humanos (PWA). Compite con Bizneo e Integratec.
Origen: proyecto anterior "RRHH Prisma" (Apps Script + Sheets), reescrito.

| Pieza | Dónde |
|---|---|
| Base de datos y auth | Supabase (un proyecto, base compartida, `tenant_id` + RLS) |
| Código | GitHub `RafaelErrazu/rhoo` |
| Hosting | Cloudflare Pages |
| Respaldos | GitHub Actions → Cloudflare R2 (base semanal, storage mensual) |
| Proveedor / superadmin | `desarrollo.soporte001@gmail.com`, tenant slug `rhoo` |

Marca: turquesa `#2EC4B6` acción, coral `#F4795B` atención, tipografía Nunito.
Sidebar y login oscuros, contenido claro.

---

## Estructura empresarial

Cuatro niveles, **siempre presentes**:

    Tenant                el cliente que paga la suscripción
      └─ Grupo            agrupación comercial: consolida y hereda reglas
          └─ Razón social RFC, registro patronal, prima de riesgo
              └─ Centro   domicilio físico donde se checa

Un cliente con una sola empresa tiene un grupo con una razón social y no se
entera: la UI oculta los niveles con un solo elemento. Se decidió así para no
tener dos modelos y llenar el código de condicionales.

**Lo configurable es el comportamiento, no la estructura.** La llave
`grupos_empresariales.reglas_desde` decide de dónde salen las reglas:

- `grupo`: el grupo estandariza, la config de la empresa se ignora.
- `empresa`: cada razón social define lo suyo, con el grupo como respaldo.

La cadena de resolución es **empresa → grupo → tenant → defaults**, vía
`app.cfg_razon()`. Con eso un grupo homogéneo no captura nada y uno heterogéneo
ajusta solo sus excepciones.

### Reglas duras de este modelo

- **La nómina cuelga de la razón social, no del grupo.** El CFDI se timbra con
  un RFC específico; un periodo que abarque dos empresas sería imposible de
  timbrar.
- **El empleado pertenece a una razón social** (`empleados.razon_id`), no a
  `sueldos`. Cambiar de empresa es legalmente baja y alta con contrato nuevo, se
  registra como movimiento laboral.
- **Un trigger valida que el centro y el empleado sean de la misma empresa.**
  Al mover a alguien, se mueve primero el centro; poner `razon_id = null` hace
  que el trigger la tome del centro.
- **La prima de riesgo va historizada** (`primas_riesgo`, con vigencias). Se
  declara cada febrero y cambia: recalcular un periodo viejo debe usar la de
  entonces. Se captura como fracción (0.005425), no como porcentaje.

---

## Módulos terminados

Todos probados en SQL y en la app.

- **Shell y auth** · login, roles, navegación, PWA instalable, service worker
- **Proveedor / superadmin** · alta de tenants, catálogos semilla, planes, suspensión
- **Usuarios** · alta con contraseña temporal, reset, baja, antiescalación
- **Configuración** · JSONB por tenant con validaciones legales y bitácora
- **Empleados** · listado, expediente, alta, baja, reactivación
- **Sueldos** · captura desde el expediente, historial con vigencias, SDI desglosado
- **Turnos** · catálogo, patrones de rotación, asignación
- **Asistencia** · motor de jornadas, checadores, geocerca, ubicaciones autorizadas
- **Documentos** · bucket privado, OCR con Gemini, aplicar al expediente
- **Vacaciones e incidencias** · solicitud, doble firma, saldo con ledger
- **Organigrama** · jerarquía sin ciclos, vista "mi equipo"
- **NOM-035** · campañas, cuestionarios, dashboard, informe 7.7, intervención, difusión
- **Notificaciones** · campana, generador diario, cumpleaños y aniversarios
- **Calendario** · vista mes y ausencias del equipo, tablero de inicio
- **Prenómina** · completa, ver detalle abajo
- **Grupos y razones sociales** · estructura, herencia de config, prima de riesgo

---

## Prenómina · qué calcula y qué no

**Sí calcula** (validado al centavo contra cálculo manual):

| Concepto | Regla |
|---|---|
| Sueldo | días trabajados + descanso + permiso con goce |
| Séptimo día | proporcional, se pierde por faltas (art. 73) |
| Tiempo extra | dobles hasta 3 h/día (art. 67); excedente semanal al triple (art. 66/68) |
| Festivo laborado | 200% adicional (art. 75), respeta la bandera `paga_doble` |
| Descanso laborado | salario doble adicional (art. 73) |
| Prima dominical | 25% del diario (art. 71) |
| Vacaciones | días + prima vacacional (art. 80) |
| Incapacidad | en cero con aviso: la paga el IMSS |
| Permiso sin goce | no se paga |
| Retardos | política configurable por tenant, ver abajo |
| Movimientos | bonos, préstamos y demás conceptos capturados |

**NO calcula, a propósito:** ISR, cuotas IMSS, CFDI, timbrado, SUA, IDSE,
aguinaldo, PTU, finiquito. El resultado se llama **neto estimado** para que
nadie lo confunda con un recibo.

### Arquitectura

- **Grupos de pago** (`grupos_nomina`): la frecuencia vive en el grupo de pago,
  no en la persona. Permite semanales y quincenales en paralelo. Cada grupo
  pertenece a una razón social.
- **Empleado → grupo de pago** se asigna en `sueldos`, que está historizado.
- Los sueldos tienen vigencia: recalcular un periodo viejo usa el sueldo de
  entonces. **Probado.**
- Los movimientos recalculan el renglón en el mismo llamado.
- Cerrar un periodo congela los importes. Reabrir borra la firma y pide motivo.
- **Recibos imprimibles** individuales y masivos, vía impresión del navegador
  (sin librerías de PDF). Respetan el filtro activo de la pantalla.

### Retardos

Dos políticas en configuración, **nunca las dos a la vez**:

1. `retardos_para_falta` (default 3): cada N retardos se descuenta un día.
2. `descuenta_tiempo_retardo` (default false): descuenta los minutos exactos.

Si están las dos activas gana la acumulación y se levanta un aviso: cobrar el
día completo y además los minutos es sancionar dos veces lo mismo.

**Criterio adoptado:** la falta por retardos NO afecta el séptimo día. Una falta
real no se trabajó; un retardo sí. El descuento va como deducción visible, no
bajando días trabajados, para que el recibo diga de dónde salió.

---

## Bugs encontrados y corregidos

Vale la pena conservarlos: varios volverían a aparecer si alguien "simplifica"
el motor.

| # | Bug | Causa | Arreglo |
|---|---|---|---|
| 1 | `turno_horas` daba -16.50 en turnos nocturnos | tipo `time` es cíclico | epoch + 86400 |
| 2 | Guía V de NOM-035 no aparecía | service worker cache-first en navegaciones | network-first estructural |
| 3 | Gráfica de dominios mal | el front recalculaba el nivel con cortes de total | usar niveles del backend |
| 4 | Festivos duplicados al re-sembrar | NULL en unique con `centro_id` | `where not exists` idempotente |
| 5 | Usuarios desactivados podían entrar | el login no revisaba `perfil.activo` | validar en `cargarSesion` |
| 6 | Descanso trabajado pagaba día sencillo | art. 73 no implementado | doble adicional |
| 7 | Descanso trabajado se aplicaba a TODOS los días | usé `turno_del_dia() is null` sin verificar que hubiera turno asignado | solo aplica con asignación; si no, aviso `sin_turno` |
| 8 | Tope del art. 66 nunca disparaba | prorrateaba 9 h × (días/7) = 19.28 h en quincena | por semana calendario real |
| 9 | **Doble descuento de días por incidencias** | el trigger marca la jornada como `incidencia` y el motor volvía a restarla | restar solo los días que sí se contaron como trabajados |
| 10 | **El saldo cobraba días naturales** | `calcular_dias_incidencia` hacía `(fin - inicio) + 1` | `app.dias_consumibles`: días con turno, sin festivos |
| 11 | **No se pagaban los descansos dentro de vacaciones** | la asistencia marca todo como `incidencia`, incluidos domingos | en el motor, `incidencia` + sin turno = descanso pagado |
| 12 | `paga_doble` de festivos se ignoraba | el motor solo miraba si el día existía | leer la bandera |
| 13 | CSV se abría en una sola columna | separador y BOM peleados con Excel español | CSV estándar con comas, comillas y BOM |
| 14 | Campos numéricos rechazaban decimales | faltaba `step="any"` | agregado en `ui.js`, aplica a todo el sistema |
| 15 | Dos funciones calculaban días hábiles | `dias_habiles_empleado` y `dias_consumibles` por separado | la primera delega en la segunda |
| 16 | Recibo decía "Otras deducciones" en lugar del concepto | sumaba los movimientos en un renglón | desglose por nombre de concepto |

### Criterios que se decidieron y conviene no revertir sin pensar

- El descanso semanal (art. 69) y los festivos (art. 74) **no consumen
  vacaciones**. Cobrarlos al saldo le quita días ganados a la persona.
- Las horas extra **nunca se recortan**, solo se avisa y se reclasifica el
  excedente a triple. Esconder horas trabajadas es como nace una demanda.
- Una jornada sin checada de salida **se cuenta como trabajada** y se avisa.
  Castigar a alguien por una falla del sistema no es opción.
- Ausencia de dato ≠ dato en cero. Sin turno asignado no se infiere nada, se
  levanta aviso.
- `calcular_jornada` sigue marcando `incidencia` en descansos: como registro de
  asistencia es correcto. Quien decide el pago es la prenómina.
- El recibo dice explícitamente que **no sustituye al CFDI**. El papel sale de
  la oficina y alguien lo va a confundir.

---

## Pendientes

### Siguiente
- **UI de grupos y razones sociales.** La estructura existe pero solo se
  administra por SQL. Incluye mostrar la empresa en el tablero de nómina.
- **El recibo debe llevar razón social y RFC**, no el nombre del tenant. Hoy
  dice "Cliente Demo SA" porque toma el tenant.
- **Historial laboral** (`movimientos_laborales`): puesto, departamento, centro,
  jefe, tipo de contrato y razón social no tienen historia, se sobreescriben.
  `auditoria` no sirve para eso: es registro técnico, no línea de tiempo del
  expediente ni base para una constancia laboral.

### Alta de empleado, comparada con la competencia
Funciona, pero incompleta para vender:
- **Asistente de alta por pasos.** Hoy un empleado nuevo no puede cobrar ni
  checar: falta sueldo (otro panel), turno (otro panel) y usuario (otro módulo).
  Tres viajes que hay que recordar.
- **Faltan campos**: domicilio (no existe la columna), contacto de emergencia,
  beneficiarios, nacionalidad, entidad de nacimiento.
- **Checklist de documentos** obligatorios por puesto.
- **Contrato**: generación y firma, avisos de vencimiento de temporal y de
  periodo de prueba.

### Módulos no empezados
- Muro social (publicaciones, reacciones, comentarios)
- Capacitaciones, con integración al calendario
- Nómina real: ISR, IMSS, SUA, CFDI, timbrado
- Aguinaldo, PTU, finiquito

### Detalles menores
- Notificaciones por correo: esperan dominio y proveedor de envío.
- Contador de Guía III muestra 72 antes de filtros y guarda 64. Cosmético.
- Retardos no se acumulan entre periodos, cada periodo cuenta los suyos. Si un
  cliente lo pide acumulativo hay que guardar saldo en tabla.
- `centros_trabajo.razon_social` sigue como texto, marcada obsoleta. Se borra
  cuando se confirme que la migración quedó bien.
- Los grupos migrados se llaman igual que su razón social (heredaron el nombre
  del tenant). Cosmético, se renombra desde la UI.
- El módulo de Configuración escribe en el tenant. Hay que decidir qué llaves se
  administran en cada nivel de la jerarquía.
- El correo con credenciales del primer admin se manda a mano.

### Resueltos que estaban mal anotados
- Incidencias traslapadas: **ya se validan** en `solicitar_incidencia`.
- Retardos en Configuración: **ya aparecen** en la sección Asistencia.

---

## Datos de prueba

Tenant demo `4629dbe5-8699-414f-b15f-4d761fd3d458` (Cliente Demo SA):
87 empleados, sueldos aleatorios 350-800, jornadas del 1 al 15 de agosto de
2026, turno matutino con domingo de descanso, festivo de prueba el 12 de agosto.

Estructura: grupo `GRAL` con dos razones sociales, `RS01` (57 empleados) y
`RS02` (30, "Servicios Demo Dos SA de CV"). Grupos de pago: `QNA` quincenal y
`SEM` semanal.

Casos sembrados para validar el motor: faltas, 12 h extra en una semana,
domingo laborado, vacaciones, incapacidad, permiso sin goce y retardos.

Netos de control del periodo #15 quincenal, útiles como regresión:

| Empleado | Neto | Qué valida |
|---|---|---|
| SC-019 | 13,879.36 | vacaciones, prima, descansos pagados, Fonacot |
| SC-025 | 11,329.12 | retardos con descuento, festivo laborado |
| PN-039 | 11,043.44 | vacaciones parciales |
| PN-053 | 6,744.50 | incapacidad sin pago |
| PN-017 | 7,094.20 | festivo + descanso laborado + prima dominical |
| PN-016 | 8,872.61 | faltas, séptimo perdido, bono capturado |
| SC-023 | 10,756.37 | 9 h dobles + 3 h triples |

### Cómo probar funciones en el SQL Editor

Las funciones dependen de `app.mi_tenant()`, que lee `auth.uid()`. En el editor
no hay sesión, así que hay que simularla **en la misma transacción** (el
`set_config` se pierde entre statements):

```sql
begin;
select set_config('request.jwt.claims',
  json_build_object('sub',(select id::text from perfiles
    where tenant_id='4629dbe5-8699-414f-b15f-4d761fd3d458'
      and activo and rol in ('admin','rh') limit 1))::text, true);

-- aquí va lo que quieras probar

commit;
```

El editor muestra solo el resultado del último statement.

---

## Notas de operación

- `npx supabase db push` avisa que Docker no está: es solo el caché local del
  catálogo, no afecta al remoto. Lo que importa es `Finished supabase db push`.
- Al pegar un artefacto en una migración, incluir **solo el SQL**, sin los
  encabezados de pasos.
- **Cuidado al pegar strings partidos en varias líneas**: el editor de Windows a
  veces junta las líneas y rompe la concatenación con `||`. Si un `raise
  exception` da error de sintaxis, ponerlo en una sola línea.
- `node --check archivo.js` antes de cada push del front: cacha errores de
  sintaxis sin esperar el deploy.
- `UPDATE` no acepta `order by ... limit`. Filtrar con `where id = (subconsulta)`.
- Respaldos probados de punta a punta, incluida la restauración y el login
  contra la base restaurada.
