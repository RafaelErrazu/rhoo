-- Permisos sobre el esquema app.
-- Las funciones app.mi_tenant() y app.mi_rol() se usan dentro de
-- las politicas de RLS, asi que los roles de Supabase necesitan
-- poder ejecutarlas. Sin esto, toda consulta devuelve
-- "permission denied for schema app".
grant usage on schema app to anon, authenticated, service_role;

grant execute on all functions in schema app
  to anon, authenticated, service_role;

-- Para las funciones que se creen despues en este esquema
alter default privileges in schema app
  grant execute on functions to anon, authenticated, service_role;