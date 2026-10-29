-- =====================================================================
-- 16 · Cargador de la APM del MEF (29/10/2026)
--   Lee la hoja DATA_APM del módulo de Programación Multianual (una fila por
--   meta × rubro × clasificador, con PRESUPUESTO, PRESUPUESTO 2 y PRESUPUESTO 3)
--   y actualiza los techos del periodo activo:
--     · llave = periodo | CU_EFP | rubro | clasificador (la misma de la carga inicial)
--     · partidas que existen → se actualizan los tres años
--     · partidas nuevas de una actividad existente → se crean
--     · metas nuevas → se crea la actividad si el archivo trae el centro de costo
--       (columna S.UO), si no se informan como "sin actividad"
--     · partidas del periodo que ya no están en la APM → techo en 0 (no se borran)
--   modo = 'vista' solo calcula el resumen; modo = 'aplicar' escribe.
-- Se ejecuta después de 15_cmn_siga_plano.sql. Re-ejecutable.
-- =====================================================================

create or replace function poi.cargar_apm(s jsonb, per int, p jsonb) returns jsonb
language plpgsql as $$
declare
  aplicar boolean := coalesce(p ->> 'modo', '') = 'aplicar';
  pre text; v_max int; v_ord int; r record; n_ao int := 0; n_upd int := 0; n_new int := 0; n_cero int := 0;
  malos text[]; res jsonb;
begin
  if s ->> 'r' <> 'OPP' then perform poi.falla('Solo OPP puede cargar la APM.'); end if;
  per := coalesce(per, poi.per_activo());
  if (select estado from poi.periodo where anio_ini = per) is distinct from 'ACTIVO' then
    perform poi.falla('El periodo ' || per || '–' || (per + 2) || ' no está activo.');
  end if;
  if coalesce(p ->> 'anio', '') <> per::text then
    perform poi.falla('El archivo es la APM ' || coalesce(nullif(p ->> 'anio', ''), '(sin año)') || '; el periodo elegido es ' || per || '–' || (per + 2) || '. Elige el periodo correcto arriba.');
  end if;
  if jsonb_typeof(p -> 'filas') <> 'array' or jsonb_array_length(p -> 'filas') = 0 then perform poi.falla('El archivo no tiene filas de la APM.'); end if;
  pre := 'AO' || right(per::text, 2) || '-';

  create temp table if not exists _ap (cu text, rubro int, ff text, cl text, cd text, reserva text, c1 text, c2 text,
                        a1 numeric, a2 numeric, a3 numeric, cc text, org text, uo text, sf text, info jsonb, llave text) on commit drop;
  truncate _ap;
  insert into _ap
  select poi.t(e ->> 'cu_efp', 80), coalesce(poi.n(e -> 'rubro'), 0)::int, poi.t(e ->> 'ff', 80),
         trim(both '.' from regexp_replace(poi.t(e ->> 'clasificador', 40), '[.[:space:]]+', '.', 'g')), poi.t(e ->> 'clasificador_desc', 200),
         nullif(poi.t(e ->> 'reserva', 40), ''), nullif(poi.t(e ->> 'concepto1', 120), ''), nullif(poi.t(e ->> 'concepto2', 120), ''),
         round(coalesce(poi.n(e -> 'a1'), 0), 2), round(coalesce(poi.n(e -> 'a2'), 0), 2), round(coalesce(poi.n(e -> 'a3'), 0), 2),
         upper(poi.t(e ->> 'cc', 40)), poi.t(e ->> 'organo', 40), poi.t(e ->> 'uo', 200), poi.t(e ->> 'sf', 10), coalesce(e -> 'ao', '{}'), null
    from jsonb_array_elements(p -> 'filas') e;
  update _ap set llave = per || '|' || cu || '|' || rubro || '|' || cl;

  select array_agg(x) into malos from (select distinct cu || ' ' || cl x from _ap where cu !~ '^\d{4}-\d{7}-\d{7}-\d{2}-\d{3}-\d{4}-\d{7}-\d+$' or cl !~ '^2(\.\d+){5}$' limit 5) z;
  if malos is not null then perform poi.falla('Hay filas con meta o clasificador incompletos: ' || array_to_string(malos, '; ') || '.'); end if;
  select array_agg(x) into malos from (select llave x from _ap group by llave having count(*) > 1 limit 5) z;
  if malos is not null then perform poi.falla('El archivo repite la misma meta, rubro y clasificador: ' || array_to_string(malos, '; ') || '.'); end if;

  -- Actividad de cada meta: la existente del periodo o una nueva si se conoce el centro de costo
  create temp table if not exists _apao (cu text, id_ao text, cc text, nueva boolean, org text, uo text, sf text, info jsonb) on commit drop;
  truncate _apao;
  insert into _apao
  select a.cu, x.id_ao, coalesce(x.centro_costo, nullif(a.cc, '')), x.id_ao is null, a.org, a.uo, a.sf, a.info
    from (select distinct on (cu) cu, cc, org, uo, sf, info from _ap order by cu, cc desc) a
    left join poi.ao x on x.periodo = per and x.cu_efp = a.cu;
  -- Solo se crea la actividad si el centro de costo ya existe en el POI
  update _apao set cc = null where nueva and cc is not null and not exists (select 1 from poi.ao where centro_costo = _apao.cc);

  select jsonb_build_object(
    'ok', true, 'aplicado', aplicar, 'periodo', per,
    'totales', jsonb_build_object(
       'archivo', jsonb_build_array((select coalesce(sum(a1), 0) from _ap), (select coalesce(sum(a2), 0) from _ap), (select coalesce(sum(a3), 0) from _ap)),
       'antes', jsonb_build_array((select coalesce(sum(apm_a1), 0) from poi.partida where periodo = per), (select coalesce(sum(apm_a2), 0) from poi.partida where periodo = per),
                                  (select coalesce(sum(apm_a3), 0) from poi.partida where periodo = per))),
    'filas', (select count(*) from _ap),
    'partidas', jsonb_build_object(
       'iguales', (select count(*) from _ap a join poi.partida q on q.llave = a.llave where q.apm_a1 = a.a1 and q.apm_a2 = a.a2 and q.apm_a3 = a.a3),
       'cambian', (select count(*) from _ap a join poi.partida q on q.llave = a.llave where q.apm_a1 <> a.a1 or q.apm_a2 <> a.a2 or q.apm_a3 <> a.a3),
       'nuevas', (select count(*) from _ap a join _apao o on o.cu = a.cu where o.cc is not null and not exists (select 1 from poi.partida q where q.llave = a.llave)),
       'a_cero', (select count(*) from poi.partida q where q.periodo = per and (q.apm_a1 <> 0 or q.apm_a2 <> 0 or q.apm_a3 <> 0) and not exists (select 1 from _ap a where a.llave = q.llave))),
    'por_cc', (select coalesce(jsonb_agg(jsonb_build_object('cc', cc, 'antes', jsonb_build_array(b1, b2, b3), 'despues', jsonb_build_array(d1, d2, d3)) order by cc), '[]')
                 from (select cc, sum(b1) b1, sum(b2) b2, sum(b3) b3, sum(d1) d1, sum(d2) d2, sum(d3) d3 from (
                         select q.centro_costo cc, q.apm_a1 b1, q.apm_a2 b2, q.apm_a3 b3, 0 d1, 0 d2, 0 d3 from poi.partida q where q.periodo = per
                         union all
                         select o.cc, 0, 0, 0, a.a1, a.a2, a.a3 from _ap a join _apao o on o.cu = a.cu where o.cc is not null) u
                       group by cc having sum(b1) <> sum(d1) or sum(b2) <> sum(d2) or sum(b3) <> sum(d3)) z),
    'nuevas_ao', (select coalesce(jsonb_agg(jsonb_build_object('cu', o.cu, 'cc', o.cc, 'finalidad', o.info ->> 'finalidad',
                     'apm', jsonb_build_array((select sum(a1) from _ap a where a.cu = o.cu), (select sum(a2) from _ap a where a.cu = o.cu), (select sum(a3) from _ap a where a.cu = o.cu)))), '[]')
                    from _apao o where o.nueva and o.cc is not null),
    'sin_ao', (select coalesce(jsonb_agg(jsonb_build_object('cu', o.cu, 'finalidad', o.info ->> 'finalidad',
                  'apm', jsonb_build_array((select sum(a1) from _ap a where a.cu = o.cu), (select sum(a2) from _ap a where a.cu = o.cu), (select sum(a3) from _ap a where a.cu = o.cu)))), '[]')
                 from _apao o where o.cc is null),
    -- Partidas cuya PM3 priorizada quedaría por encima del nuevo techo
    'excesos', (select coalesce(jsonb_agg(jsonb_build_object('cc', cc, 'id_ao', id_ao, 'clasificador', clasificador, 'anio', anio, 'pm3', pm3, 'apm', apm) order by cc, id_ao, clasificador, anio), '[]')
                  from (select q.centro_costo cc, q.id_ao, q.clasificador, per + k - 1 anio,
                               round(sum(case k when 1 then rr.total_a1 when 2 then rr.total_a2 else rr.total_a3 end), 2) pm3,
                               coalesce(case k when 1 then a.a1 when 2 then a.a2 else a.a3 end, 0) apm
                          from poi.partida q cross join generate_series(1, 3) k
                          join poi.pm3_recurso rr on rr.llave = q.llave and rr.estado = 'ACTIVA'
                          left join _ap a on a.llave = q.llave
                         where q.periodo = per
                         group by 1, 2, 3, 4, q.llave, a.a1, a.a2, a.a3, k
                        having round(sum(case k when 1 then rr.total_a1 when 2 then rr.total_a2 else rr.total_a3 end), 2) > coalesce(case k when 1 then a.a1 when 2 then a.a2 else a.a3 end, 0)) z)
  ) into res;

  if not aplicar then return res; end if;

  -- ===== Escritura =====
  select coalesce(max(substring(id_ao from '-(\d+)$')::int), 0), coalesce(max(orden), 0) into v_max, v_ord from poi.ao where periodo = per;
  for r in select * from _apao where nueva and cc is not null order by cu loop
    v_max := v_max + 1; v_ord := v_ord + 1;
    insert into poi.ao (id_ao, orden, cu_efp, sec_func_2027, organo, centro_costo, unidad_organica, tipo, cod_producto, producto, programa,
                        actividad_efp, funcion, div_fun, grp_fun, finalidad, nombre_ao, departamento, provincia, distrito, unidad_medida,
                        meta_a1, meta_a2, meta_a3, actualizado, actualizado_por, periodo)
    values (pre || lpad(v_max::text, 3, '0'), v_ord, r.cu, nullif(r.sf, ''), coalesce(nullif(r.org, ''), r.cc), r.cc,
            coalesce(nullif(r.uo, ''), (select max(unidad_organica) from poi.ao where centro_costo = r.cc)),
            r.info ->> 'tipo', r.info ->> 'cod_producto', r.info ->> 'producto', r.info ->> 'programa', r.info ->> 'actividad_efp',
            r.info ->> 'funcion', r.info ->> 'div_fun', r.info ->> 'grp_fun', r.info ->> 'finalidad',
            regexp_replace(coalesce(r.info ->> 'finalidad', ''), '^\d+\.', ''),
            r.info ->> 'departamento', r.info ->> 'provincia', r.info ->> 'distrito', r.info ->> 'unidad_medida',
            0, 0, 0, now(), s ->> 'u', per);
    update _apao set id_ao = pre || lpad(v_max::text, 3, '0') where cu = r.cu;
    n_ao := n_ao + 1;
  end loop;

  update poi.partida q set apm_a1 = a.a1, apm_a2 = a.a2, apm_a3 = a.a3,
         ff = (case when a.ff = '' or split_part(a.ff, '-', 1) = split_part(coalesce(q.ff, ''), '-', 1) then q.ff else a.ff end), clasificador_desc = coalesce(nullif(a.cd, ''), q.clasificador_desc),
         reserva = coalesce(a.reserva, q.reserva), concepto1 = coalesce(a.c1, q.concepto1), concepto2 = coalesce(a.c2, q.concepto2)
    from _ap a where q.llave = a.llave
     and (q.apm_a1 <> a.a1 or q.apm_a2 <> a.a2 or q.apm_a3 <> a.a3 or q.ff is distinct from (case when a.ff = '' or split_part(a.ff, '-', 1) = split_part(coalesce(q.ff, ''), '-', 1) then q.ff else a.ff end)
          or q.reserva is distinct from coalesce(a.reserva, q.reserva) or q.concepto1 is distinct from coalesce(a.c1, q.concepto1)
          or q.concepto2 is distinct from coalesce(a.c2, q.concepto2));
  get diagnostics n_upd = row_count;

  select coalesce(max(orden), 0) into v_ord from poi.partida where periodo = per;
  insert into poi.partida (llave, orden, id_ao, cu_efp, centro_costo, ff, rubro, clasificador, clasificador_desc, concepto1, concepto2, reserva,
                           apm_a1, apm_a2, apm_a3, meses, periodo)
  select a.llave, v_ord + row_number() over (order by a.cu, a.rubro, a.cl), o.id_ao, a.cu, o.cc, a.ff, a.rubro, a.cl, a.cd, a.c1, a.c2, coalesce(a.reserva, 'Normal'),
         a.a1, a.a2, a.a3, poi.ceros(), per
    from _ap a join _apao o on o.cu = a.cu
   where o.id_ao is not null and not exists (select 1 from poi.partida q where q.llave = a.llave);
  get diagnostics n_new = row_count;

  update poi.partida q set apm_a1 = 0, apm_a2 = 0, apm_a3 = 0
   where q.periodo = per and (q.apm_a1 <> 0 or q.apm_a2 <> 0 or q.apm_a3 <> 0) and not exists (select 1 from _ap a where a.llave = q.llave);
  get diagnostics n_cero = row_count;

  perform poi.hist_evento(s ->> 'u', 'cargarAPM', null, per,
    'Cargó la APM ' || per || '–' || (per + 2) || ' (' || coalesce(nullif(poi.t(p ->> 'archivo', 120), ''), 'archivo') || '): ' || n_upd || ' partidas actualizadas, '
    || n_new || ' nuevas, ' || n_cero || ' en cero, ' || n_ao || ' actividades nuevas');
  insert into poi.bitacora (usuario, accion, detalle) values (s ->> 'u', 'cargarAPM', per || ' · ' || n_upd || ' act., ' || n_new || ' nuevas, ' || n_cero || ' en 0, ' || n_ao || ' AO nuevas');
  return res || jsonb_build_object('resultado', jsonb_build_object('actualizadas', n_upd, 'nuevas', n_new, 'a_cero', n_cero, 'aos_nuevas', n_ao));
end $$;

-- Acción cargarAPM en la API
do $do$
declare d text; viejo text; nuevo text;
begin
  d := pg_get_functiondef('public.poi_api(jsonb)'::regprocedure);
  viejo := $q$when 'nmpAnexos'        then return poi.nmp_anexos(s, p);$q$;
  nuevo := $q$when 'nmpAnexos'        then return poi.nmp_anexos(s, p);
    when 'cargarAPM'        then return poi.cargar_apm(s, per, p);$q$;
  if position('cargarAPM' in d) = 0 then
    if position(viejo in d) = 0 then raise exception 'poi_api: no se encontró nmpAnexos'; end if;
    execute replace(d, viejo, nuevo);
  end if;
end $do$;
