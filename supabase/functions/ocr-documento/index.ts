// ═══════════════════════════════════════════════════════════
//  RHoo! · OCR de documentos con Gemini
//
//  Corre en el servidor a proposito: la llave de Gemini nunca
//  toca el navegador. Una llave de IA expuesta en el frontend la
//  toma cualquiera con las herramientas de desarrollo.
// ═══════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// El modelo vive aqui, no en el frontend: cambiarlo es editar
// esta linea y redesplegar, sin que nadie actualice la PWA.
const MODELO = 'gemini-flash-latest';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

/* Prompt por tipo de documento. Se pide JSON estricto y se
   insiste en no inventar: un modelo que "completa" un CURP
   ilegible produce un dato plausible y falso, que es peor que
   un campo vacio. */
function prompt(tipo: string, campos: string[]) {
  const guia: Record<string, string> = {
    INE: 'Es una credencial para votar del INE (Mexico). El CURP aparece etiquetado como CURP. El nombre suele venir en tres lineas: apellido paterno, apellido materno, nombres. SEXO viene como H o M.',
    CURP: 'Es una constancia de CURP emitida por RENAPO.',
    RFC: 'Es una constancia de situacion fiscal del SAT. El RFC de persona fisica tiene 13 caracteres.',
    NSS: 'Es un documento del IMSS. El numero de seguridad social tiene 11 digitos.',
    ACTA: 'Es un acta de nacimiento mexicana.',
    ESTUDIOS: 'Es un comprobante de estudios. Devuelve el nivel maximo concluido.',
  };

  return `Analiza este documento mexicano de recursos humanos.
${guia[tipo] ?? ''}

Extrae UNICAMENTE estos campos: ${campos.join(', ')}

Reglas estrictas:
- Responde SOLO con un objeto JSON, sin explicaciones ni markdown.
- Si un campo no se lee con certeza, omitelo. NO adivines ni completes.
- fecha_nacimiento en formato AAAA-MM-DD.
- sexo debe ser exactamente "Masculino", "Femenino" u "Otro".
- escolaridad debe ser uno de: Sin formacion, Primaria, Secundaria,
  Preparatoria o Bachillerato, Tecnico Superior, Licenciatura, Maestria, Doctorado.
- curp en mayusculas, 18 caracteres. rfc en mayusculas, 13 caracteres.
- nss solo digitos, 11 caracteres.
- Agrega ademas "_texto" con todo el texto visible del documento.

Ejemplo de respuesta:
{"curp":"HEEH900101HDFRRC01","nombres":"JUAN CARLOS","_texto":"..."}`;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  try {
    const { documento_id } = await req.json();
    if (!documento_id) throw new Error('Falta documento_id');

    // Cliente con service_role: la funcion necesita leer el
    // archivo y escribir el resultado sin depender del usuario.
    const sb = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    );

    const { data: doc, error: eDoc } = await sb
      .from('documentos')
      .select('id, ruta, mime, tipo_id')
      .eq('id', documento_id)
      .single();
    // El mensaje incluye el detalle: "no encontrado" a secas
    // esconde si el problema fue permisos o la consulta misma.
    if (eDoc || !doc) throw new Error('Documento no encontrado: ' + (eDoc?.message ?? documento_id));

    // Dos consultas en lugar de una relacion embebida: el join
    // implicito de PostgREST no se resuelve de forma confiable
    // desde la Edge Function.
    let tipo = 'OTRO';
    let campos: string[] = [];
    if (doc.tipo_id) {
      const { data: t } = await sb
        .from('tipos_documento')
        .select('clave, campos_ocr')
        .eq('id', doc.tipo_id)
        .single();
      if (t) { tipo = t.clave; campos = t.campos_ocr ?? []; }
    }

    // Tipos sin campos declarados no se procesan: gastar una
    // llamada de IA en un comprobante de domicilio del que no se
    // extrae nada es tirar cuota.
    if (!campos.length) {
      await sb.rpc('guardar_ocr', {
        p_documento_id: documento_id, p_estado: 'omitido',
        p_error: 'Este tipo de documento no tiene campos para extraer.',
      });
      return new Response(JSON.stringify({ status: 'omitido' }),
        { headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    const llave = Deno.env.get('GEMINI_API_KEY');
    if (!llave) throw new Error('GEMINI_API_KEY no esta configurada');

    const { data: archivo, error: eArch } = await sb.storage
      .from('expedientes').download(doc.ruta);
    if (eArch || !archivo) throw new Error('No se pudo leer el archivo');

    const bytes = new Uint8Array(await archivo.arrayBuffer());
    // Se convierte por bloques: un apply() sobre un arreglo de 8
    // millones de elementos reventaria la pila de llamadas.
    let bin = '';
    const paso = 8192;
    for (let i = 0; i < bytes.length; i += paso) {
      bin += String.fromCharCode(...bytes.subarray(i, i + paso));
    }
    const b64 = btoa(bin);

    const r = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${MODELO}:generateContent?key=${llave}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          contents: [{
            parts: [
              { text: prompt(tipo, campos) },
              { inline_data: { mime_type: doc.mime ?? 'image/jpeg', data: b64 } },
            ],
          }],
          generationConfig: {
            // temperatura 0: para extraer datos no se quiere
            // creatividad, se quiere el mismo resultado siempre.
            temperature: 0,
            responseMimeType: 'application/json',
          },
        }),
      }
    );

    if (!r.ok) {
      const detalle = await r.text();
      // Mensaje distinguible: si el modelo se deprecio, hay que
      // saberlo de inmediato y no perseguir un "fallo el OCR".
      const msg = r.status === 404
        ? `El modelo ${MODELO} ya no esta disponible. Actualiza la constante MODELO en la Edge Function.`
        : `Gemini respondio ${r.status}: ${detalle.slice(0, 300)}`;
      await sb.rpc('guardar_ocr', {
        p_documento_id: documento_id, p_estado: 'error', p_error: msg });
      throw new Error(msg);
    }

    const salida = await r.json();
    const crudo = salida?.candidates?.[0]?.content?.parts?.[0]?.text ?? '{}';

    let campos_ok: Record<string, unknown> = {};
    let texto = '';
    try {
      const j = JSON.parse(crudo);
      texto = j._texto ?? '';
      delete j._texto;
      // Solo se conservan los campos declarados para este tipo:
      // si el modelo devuelve algo extra, se ignora.
      for (const k of campos) {
        if (j[k] != null && String(j[k]).trim() !== '') campos_ok[k] = j[k];
      }
    } catch {
      texto = crudo;
    }

    const hay = Object.keys(campos_ok).length > 0;
    await sb.rpc('guardar_ocr', {
      p_documento_id: documento_id,
      p_estado: hay ? 'procesado' : 'sin_datos',
      p_texto: texto.slice(0, 20000),
      p_campos: campos_ok,
      p_error: hay ? null : 'No se pudo leer ningun campo. Revisa que la imagen sea legible.',
    });

    return new Response(
      JSON.stringify({ status: hay ? 'procesado' : 'sin_datos', campos: campos_ok }),
      { headers: { ...CORS, 'Content-Type': 'application/json' } }
    );

  } catch (e) {
    return new Response(JSON.stringify({ status: 'error', message: String(e) }),
      { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
  }
});