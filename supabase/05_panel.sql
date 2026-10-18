-- POI 2027 – ATU · Panel de control para OPP (resumen por centro de costo)
create or replace function poi.panel() returns jsonb
language sql stable as $$
  with pp as (
    select p.id_ao, p.apm_2027, p.apm_2028, p.apm_2029,
           coalesce(g.g27, 0) g27, coalesce(g.g28, 0) g28, coalesce(g.g29, 0) g29
      from poi.partida p
      left join (select llave, sum(total_2027) g27, sum(total_2028) g28, sum(total_2029) g29
                   from poi.pm3_recurso where estado = 'ACTIVA' group by llave) g on g.llave = p.llave
  ),
  aoc as (
    select a.id_ao, a.centro_costo, a.unidad_organica, a.actualizado,
           a.actualizado is not null as cargada,
           (coalesce(a.descripcion, '') <> '' and coalesce(a.indicador, '') <> '' and coalesce(a.medio_verificacion, '') <> '') as ficha,
           (a.meta_2027 > 0 and a.meta_2028 > 0 and a.meta_2029 > 0) as fisica,
           coalesce((select bool_and(round(g27, 2) = round(apm_2027, 2) and round(g28, 2) = round(apm_2028, 2) and round(g29, 2) = round(apm_2029, 2))
                       from pp where pp.id_ao = a.id_ao), true) as cuadra,
           coalesce((select sum(apm_2027) from pp where pp.id_ao = a.id_ao), 0) as apm27,
           coalesce((select sum(g27) from pp where pp.id_ao = a.id_ao), 0) as prog27
      from poi.ao a
  ),
  dem as (select centro_costo, sum(total_2027) d27 from poi.pm3_recurso where estado = 'DEMANDA ADICIONAL' group by centro_costo),
  nmp as (select centro_costo, count(distinct numero) n from poi.nmp where estado like 'EN REVISI%' group by centro_costo)
  select coalesce(jsonb_agg(jsonb_build_object(
           'cc', x.centro_costo, 'uo', x.uo, 'aos', x.aos, 'cargadas', x.cargadas, 'completas', x.completas,
           'apm_2027', x.apm27, 'prog_2027', x.prog27, 'demanda_2027', coalesce(dem.d27, 0),
           'nmp_pendientes', coalesce(nmp.n, 0), 'actualizado', to_char(x.ult at time zone 'America/Lima', 'DD/MM/YYYY HH24:MI')
         ) order by x.centro_costo), '[]')
    from (select centro_costo, min(unidad_organica) uo, count(*) aos,
                 count(*) filter (where cargada) cargadas,
                 count(*) filter (where cargada and ficha and fisica and cuadra) completas,
                 sum(apm27) apm27, sum(prog27) prog27, max(actualizado) ult
            from aoc group by centro_costo) x
    left join dem on dem.centro_costo = x.centro_costo
    left join nmp on nmp.centro_costo = x.centro_costo
$$;
