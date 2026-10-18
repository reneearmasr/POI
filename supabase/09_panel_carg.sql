create or replace function poi.panel(per int) returns jsonb
language sql stable as $$
  with pp as (
    select p.id_ao, p.apm_a1, p.apm_a2, p.apm_a3,
           coalesce(g.g1, 0) g1, coalesce(g.g2, 0) g2, coalesce(g.g3, 0) g3
      from poi.partida p
      left join (select llave, sum(total_a1) g1, sum(total_a2) g2, sum(total_a3) g3
                   from poi.pm3_recurso where estado = 'ACTIVA' group by llave) g on g.llave = p.llave
     where p.periodo = per
  ),
  aoc as (
    select a.id_ao, a.centro_costo, a.unidad_organica, a.actualizado,
           a.actualizado is not null as cargada,
           (coalesce(a.descripcion, '') <> '' and coalesce(a.indicador, '') <> '' and coalesce(a.medio_verificacion, '') <> '') as ficha,
           (a.meta_a1 > 0 and a.meta_a2 > 0 and a.meta_a3 > 0) as fisica,
           coalesce((select bool_and(round(g1, 2) = round(apm_a1, 2) and round(g2, 2) = round(apm_a2, 2) and round(g3, 2) = round(apm_a3, 2))
                       from pp where pp.id_ao = a.id_ao), true) as cuadra,
           coalesce((select sum(apm_a1) from pp where pp.id_ao = a.id_ao), 0) as apm1,
           coalesce((select sum(g1) from pp where pp.id_ao = a.id_ao), 0) as prog1
      from poi.ao a where a.periodo = per
  ),
  dem as (select centro_costo, sum(total_a1) d1 from poi.pm3_recurso where estado = 'DEMANDA ADICIONAL' and periodo = per group by centro_costo),
  nmp as (select centro_costo, count(distinct numero) n from poi.nmp where estado like 'EN REVISI%' and periodo = per group by centro_costo)
  select coalesce(jsonb_agg(jsonb_build_object(
           'cc', x.centro_costo, 'uo', x.uo, 'aos', x.aos, 'cargadas', x.cargadas, 'completas', x.completas,
           'apm_a1', x.apm1, 'apm_carg_a1', x.apm_carg1, 'prog_a1', x.prog1, 'demanda_a1', coalesce(dem.d1, 0),
           'nmp_pendientes', coalesce(nmp.n, 0), 'actualizado', to_char(x.ult at time zone 'America/Lima', 'DD/MM/YYYY HH24:MI')
         ) order by x.centro_costo), '[]')
    from (select centro_costo, min(unidad_organica) uo, count(*) aos,
                 count(*) filter (where cargada) cargadas,
                 count(*) filter (where cargada and ficha and fisica and cuadra) completas,
                 sum(apm1) apm1, sum(apm1) filter (where cargada) apm_carg1, sum(prog1) prog1, max(actualizado) ult
            from aoc group by centro_costo) x
    left join dem on dem.centro_costo = x.centro_costo
    left join nmp on nmp.centro_costo = x.centro_costo
$$;
