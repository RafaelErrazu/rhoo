# RHoo! · Estado del proyecto

> Bitácora viva. Se actualiza al cerrar cada módulo o al descubrir un pendiente.
> Última actualización: 22 de agosto de 2026.

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
- **Prenómina** · ver detalle abajo

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

- **Grupos de nómina** (`grupos_nomina`): la frecuencia vive en el grupo, no en
  la persona. Permite semanales y quincenales en paralelo con calendarios
  distintos. La frecuencia no se edita después de crear el grupo.
- **Empleado → grupo** se asigna en `sueldos`, que ya está historizado. Mover a
  alguien de semanal a quincenal deja el histórico intacto.
- Los sueldos tienen vigencia: recalcular un periodo viejo usa el sueldo de
  entonces. **Probado.**
- Los movimientos recalculan el renglón en el mismo llamado.
- Cerrar un periodo congela los importes. Reabrir borra la firma de cierre y
  pide motivo.

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

---

## Pendientes

### Siguiente
- **Recibo por persona en PDF.** Único pendiente abierto de prenómina.

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
- El correo con credenciales del primer admin se manda a mano.

### Resueltos que estaban mal anotados
- Incidencias traslapadas: **ya se validan** en `solicitar_incidencia`.
- Retardos en Configuración: **ya aparecen** en la sección Asistencia.

---

## Datos de prueba

Tenant demo `4629dbe5-8699-414f-b15f-4d761fd3d458` (Cliente Demo SA):
87 empleados, sueldos aleatorios 350-800, jornadas del 1 al 15 de agosto de
2026, turno matutino con domingo de descanso, festivo de prueba el 12 de agosto.

Grupos: `QNA` quincenal (82 personas) y `SEM` semanal (5).

Casos sembrados para validar el motor: faltas, 12 h extra en una semana,
domingo laborado, vacaciones, incapacidad, permiso sin goce y retardos.

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
- Respaldos probados de punta a punta, incluida la restauración y el login
  contra la base restaurada.
