-- Los tipos sin campos declarados nunca pasan por el OCR, asi
-- que no deben nacer en 'pendiente': la interfaz muestra un
-- indicador de proceso mientras ese estado dure, y girando para
-- siempre parece que algo se colgo.
create or replace function app.doc_estado_inicial()
returns trigger
language plpgsql
as $$
declare v_campos text[];
begin
  if new.tipo_id is null then
    new.ocr_estado := 'omitido';
    return new;
  end if;

  select campos_ocr into v_campos
  from public.tipos_documento where id = new.tipo_id;

  if v_campos is null or array_length(v_campos, 1) is null then
    new.ocr_estado := 'omitido';
  end if;

  return new;
end;
$$;

create trigger docs_estado_inicial
  before insert on public.documentos
  for each row execute function app.doc_estado_inicial();

-- Arregla los que ya quedaron colgados
update public.documentos d
   set ocr_estado = 'omitido'
 where d.ocr_estado = 'pendiente'
   and (d.tipo_id is null or not exists (
     select 1 from public.tipos_documento t
     where t.id = d.tipo_id and array_length(t.campos_ocr,1) > 0));