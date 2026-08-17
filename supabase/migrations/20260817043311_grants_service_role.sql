-- El rol service_role lo usan las Edge Functions. Cuando se
-- crearon los grants originales solo se incluyo `authenticated`,
-- asi que cualquier funcion del servidor quedaba sin acceso.
-- service_role omite RLS por diseno: es el rol de confianza del
-- servidor, y por eso su llave nunca sale del backend.
grant usage on schema public to service_role;
grant usage on schema app to service_role;

grant select, insert, update, delete
  on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;
grant execute on all functions in schema app to service_role;

alter default privileges in schema public
  grant select, insert, update, delete on tables to service_role;
alter default privileges in schema public
  grant execute on functions to service_role;