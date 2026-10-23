-- =====================================================================
-- 15 · CMN: reporte plano del SIGA y limpieza de clasificadores (23/10/2026)
--   1) cargar_cmn: si el ítem no trae centro de costo (reporte plano del SIGA,
--      una fila por ítem con CLASIF_COD, META, MONT_xx_ANOx), se asigna el centro
--      de costo de la actividad con esa meta (sec_func). Las metas que no están
--      en el POI se omiten y se informan como "META 0000".
--   2) PM3 2027: clasificadores con espacios o puntos de más y fuente "00"/"RO"
--      en lo no priorizado (132 filas, aplicado una vez como "Carga directa").
-- Se ejecuta después de 14_nmp_anexos.sql. Re-ejecutable.
-- =====================================================================

do $do$
declare d text; viejo text; nuevo text;
begin
  d := pg_get_functiondef('poi.cargar_cmn(jsonb,integer,jsonb)'::regprocedure);
  viejo := $q$    v_cc := upper(poi.t(e ->> 'cc', 40));
$q$;
  nuevo := $q$    v_cc := upper(poi.t(e ->> 'cc', 40));
    -- Reporte plano del SIGA: sin centro de costo, se asigna por la meta (sec_func)
    if v_cc = '' and coalesce(e ->> 'meta', '') ~ '\d' then
      select min(x.centro_costo) into v_cc from poi.ao x
       where x.periodo = per and lpad(coalesce(nullif(x.sec_func_2027, ''), x.sec_func_2026, ''), 4, '0') = lpad(regexp_replace(e ->> 'meta', '\D', '', 'g'), 4, '0');
      v_cc := coalesce(v_cc, 'META ' || lpad(regexp_replace(e ->> 'meta', '\D', '', 'g'), 4, '0'));
    end if;
$q$;
  if position('Reporte plano del SIGA' in d) = 0 then
    if position(viejo in d) = 0 then raise exception 'cargar_cmn: no se encontró v_cc'; end if;
    execute replace(d, viejo, nuevo);
  end if;
end $do$;

-- Limpieza de la PM3 (queda en el historial como "Carga directa")
select set_config('poi.usuario', 'Carga directa', true), set_config('poi.accion', 'directo', true);
with f as (
  select id_rec,
         case when id_rec = 'AO27-048-R21' then '2.3.2.7.11.99'
              else trim(both '.' from regexp_replace(trim(clasificador), '[.[:space:]]+', '.', 'g')) end cl_nuevo,
         case when ff in ('00', 'RO') then '1-RECURSOS ORDINARIOS' else ff end ff_nuevo,
         case when ff in ('00', 'RO') and coalesce(rubro, '') = '' then '0' else rubro end rb_nuevo
    from poi.pm3_recurso
   where periodo = 2027 and upper(estado) <> 'ELIMINADA'
     and (clasificador ~ '[[:space:]]|\.$|\.\.' or id_rec = 'AO27-048-R21' or ff in ('00', 'RO'))
)
update poi.pm3_recurso r set clasificador = f.cl_nuevo, ff = f.ff_nuevo, rubro = f.rb_nuevo, actualizado = now(), actualizado_por = 'Carga directa'
  from f where r.id_rec = f.id_rec and (r.clasificador <> f.cl_nuevo or r.ff is distinct from f.ff_nuevo or r.rubro is distinct from f.rb_nuevo);
