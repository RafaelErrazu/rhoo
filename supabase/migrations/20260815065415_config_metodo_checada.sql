-- ═══════════════════════════════════════════════════════════
--  Se agregan al catalogo de valores por omision:
--    metodo_checada_default    con que metodo nace un empleado
--    dispositivo_alerta_horas  cuando avisar que un reloj callo
--
--  Se reescribe la funcion completa en lugar de encadenarla con
--  la version anterior: una cadena de config_defaults_v1, _v2,
--  _v3 se vuelve imposible de leer a la tercera vez.
-- ═══════════════════════════════════════════════════════════

create or replace function app.config_defaults()
returns jsonb
language sql
immutable
as $$
  select '{
    "tolerancia_retardo_min":   10,
    "retardos_para_falta":      3,
    "minutos_para_falta":       60,
    "checada_faltante":         "incompleta",
    "descuenta_tiempo_retardo": false,

    "geocerca_activa":          false,
    "geocerca_radio_m":         150,
    "requiere_selfie":          false,

    "extras_modo":              "autorizacion",
    "extras_min_para_contar":   15,

    "vac_dias_extra":           0,
    "prima_vacacional_pct":     25,
    "vac_anticipacion_dias":    15,
    "vac_max_dias_continuos":   0,

    "inc_aprueba":              "rh",
    "inc_requiere_doc_dias":    3,

    "nom035_meses_vigencia":       24,
    "nom035_dias_aviso":           90,
    "nom035_min_publicable":       5,
    "nom035_ajustar_rango_parcial": true,
    "nom035_umbral_centro_pct":    25,

    "zona_horaria":             "America/Mexico_City",
    "semana_inicia_lunes":      true,

    "metodo_checada_default":   "ambos",
    "dispositivo_alerta_horas": 12
  }'::jsonb
$$;

comment on function app.config_defaults is
  'Valores por omision de un tenant nuevo. Agregar una clave aqui la habilita para todos los clientes sin migrar datos.';