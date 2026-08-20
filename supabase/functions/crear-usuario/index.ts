// ═══════════════════════════════════════════════════════════
//  RHoo! · Crear usuario
//
//  Crear cuentas en auth.users requiere la service_role key. Si
//  esa llave estuviera en el frontend, cualquiera podria crear
//  cuentas con el rol que quisiera. Aqui vive en el servidor y
//  la funcion valida quien pide antes de tocar nada.
// ═══════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

/* Contraseña temporal legible.
   Se evitan caracteres ambiguos (l, 1, I, O, 0) a proposito:
   estas contrasenas se dictan por telefono o se copian de un
   WhatsApp, y un "l" confundido con un "1" genera una llamada a
   soporte. */
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

    const { email, nombre, rol, tenant_id, empleado_id } = await req.json();

    if (!email || !nombre || !rol || !tenant_id) {
      throw new Error('Faltan datos: correo, nombre, rol y empresa son obligatorios');
    }

    const url = Deno.env.get('SUPABASE_URL')!;

    // Cliente CON el token de quien pide: sirve para validar sus
    // permisos usando las mismas reglas de la base, no una copia
    // de esas reglas escrita aqui.
    const comoUsuario = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: auth } },
    });

    const { data: check, error: eCheck } = await comoUsuario
      .rpc('puede_crear_usuario', { p_tenant_id: tenant_id, p_rol: rol });

    if (eCheck) throw new Error('No se pudo validar el permiso: ' + eCheck.message);
    if (!check?.ok) throw new Error(check?.motivo ?? 'Sin permiso');

    // Ahora sí, con privilegios de servidor
    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

    const password = passwordTemporal();

    const { data: creado, error: eUser } = await admin.auth.admin.createUser({
      email: String(email).trim().toLowerCase(),
      password,
      // Se confirma de una vez: el flujo de correo de
      // confirmacion no esta configurado, y un usuario que no
      // puede entrar porque espera un correo que nunca llega es
      // una llamada a soporte garantizada.
      email_confirm: true,
      user_metadata: { nombre },
    });

    if (eUser) {
      const msg = eUser.message.includes('already been registered')
        ? 'Ya existe una cuenta con ese correo.'
        : eUser.message;
      throw new Error(msg);
    }

    // El perfil se crea aparte: si esto falla, el usuario de auth
    // ya existe y se puede reintentar sin duplicarlo.
    const { error: ePerfil } = await comoUsuario.rpc('crear_perfil', {
      p_user_id: creado.user.id,
      p_tenant_id: tenant_id,
      p_rol: rol,
      p_nombre: nombre,
      p_email: email,
      p_empleado_id: empleado_id ?? null,
    });

    if (ePerfil) {
      // Se deshace el usuario para no dejar una cuenta huerfana
      // que impida reintentar con el mismo correo.
      await admin.auth.admin.deleteUser(creado.user.id);
      throw new Error('No se pudo crear el perfil: ' + ePerfil.message);
    }

    return new Response(JSON.stringify({
      status: 'success',
      user_id: creado.user.id,
      email,
      password,          // se muestra UNA vez
    }), { headers: { ...CORS, 'Content-Type': 'application/json' } });

  } catch (e) {
    return new Response(
      JSON.stringify({ status: 'error', message: String(e).replace('Error: ', '') }),
      { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
  }
});