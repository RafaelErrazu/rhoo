-- Permisos de tabla para usuarios autenticados.
-- El proyecto se creo con "expose new tables" apagado, asi que
-- cada tabla necesita su grant explicito. Esto NO afecta la
-- seguridad: son dos capas distintas. El grant da acceso a la
-- tabla; RLS decide QUE FILAS se devuelven.
-- `anon` queda sin acceso a proposito: nada se lee sin sesion.

grant select, insert, update, delete
  on all tables in schema public
  to authenticated;

grant usage, select on all sequences in schema public to authenticated;

-- Para las tablas que se creen despues
alter default privileges in schema public
  grant select, insert, update, delete on tables to authenticated;

alter default privileges in schema public
  grant usage, select on sequences to authenticated;