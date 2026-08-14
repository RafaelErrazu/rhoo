// ═══════════════════════════════════════════════════════════
//  RHoo! · Configuración
//  La anon key es publica a proposito: el acceso lo controla
//  Row Level Security en la base, no el secreto de esta llave.
// ═══════════════════════════════════════════════════════════
const RHOO = {
  SUPABASE_URL:  'https://gocdmnnwwlkbewtmwpxa.supabase.co',
  SUPABASE_ANON: 'sb_publishable_AU0uL_C4Y1JJ9wK1RQjh3A_-BlfrK-5',
  VERSION:       '0.1.0'
};

const sb = supabase.createClient(RHOO.SUPABASE_URL, RHOO.SUPABASE_ANON, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: false
  }
});

// Sesión en memoria. Se llena en el arranque y en cada cambio de
// estado de auth; nunca se lee de localStorage a mano.
const Sesion = {
  user: null,
  perfil: null,
  tenant: null,
  get rol()  { return this.perfil?.rol || null },
  get esAdmin() { return ['superadmin','admin','rh'].includes(this.rol) },
  get esJefe()  { return this.esAdmin || this.rol === 'jefe' }
};
