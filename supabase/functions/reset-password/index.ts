// ═══════════════════════════════════════════════════════════
//  RHoo! · Restablecer contraseña
//  RH necesita poder resolver un "olvidé mi contraseña" sin
//  esperar correos ni entrar a Supabase.
// ═══════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function passwordTemporal(): string {
  const letras = 'abcdefghjkmnpqrstuvwxyz';
  const mayus  = 'ABCDEFGHJKMNPQRSTUVWXYZ';
  const nums   = '23456789';
  const r = (s: string) => s[Math.floor(Math.random() * s.length)];
  let p = '';
  for (let i = 0; i < 4; i++) p += r(letras);
  p += r(mayus) + r(mayus);
  for (let i = 0; i < 3; i++) p += r(nums);
  return p;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  try {
    const auth = req.headers.get('Authorization');
    if (!auth) throw new Error('Falta autenticación');

    const { user_id } = await req.json();
    if (!user_id) throw new Error('Falta el usuario');

    const url = Deno.env.get('SUPABASE_URL')!;
    const comoUsuario = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: auth } },
    });

    // Se reusa la validacion de la base: si puede actualizar al
    // usuario, puede restablecer su contrasena. Una regla, no dos.
    const { error: eVal } = await comoUsuario
      .rpc('usuario_actualizar', { p_id: user_id, p_datos: {} });
    if (eVal) throw new Error(eVal.message);

    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const password = passwordTemporal();

    const { error } = await admin.auth.admin.updateUserById(user_id, { password });
    if (error) throw new Error(error.message);

    // Se marca para que la cambie al entrar
    await admin.from('perfiles')
      .update({ debe_cambiar_password: true })
      .eq('id', user_id);

    return new Response(JSON.stringify({ status: 'success', password }),
      { headers: { ...CORS, 'Content-Type': 'application/json' } });

  } catch (e) {
    return new Response(
      JSON.stringify({ status: 'error', message: String(e).replace('Error: ', '') }),
      { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
  }
});