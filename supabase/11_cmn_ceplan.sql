-- =====================================================================
-- POI – ATU · 11 · Cuadro Multianual de Necesidades (CMN) y elementos
-- de la Guía para el Planeamiento Institucional (CEPLAN, RPCD N° 0055-2024)
--  • AO: prioridad (Muy Alta / Alta / Media) y ubigeo (Tabla 9)
--  • PM3: código de ítem SIGA/CUBSO por recurso (el área arma su CMN)
--  • CMN del SIGA (Fase Identificación) cargado por OPP y cuadre con la PM3
--  • Anexo B-4: POI Multianual con programación física y de costeo
-- Ejecutar después de 10_historial.sql. No borra datos.
-- =====================================================================

-- ---------- Columnas nuevas (al final, para que las versiones sigan alineadas) ----------
alter table poi.ao          add column if not exists prioridad text;
alter table poi.version_ao  add column if not exists prioridad text;
alter table poi.pm3_recurso add column if not exists item_codigo text;
alter table poi.version_pm3 add column if not exists item_codigo text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'ao_prioridad_chk') then
    alter table poi.ao add constraint ao_prioridad_chk check (prioridad is null or prioridad in ('MUY ALTA', 'ALTA', 'MEDIA'));
  end if;
end $$;

-- ---------- CMN del SIGA ----------
create table if not exists poi.cmn_carga (
  id           bigserial primary key,
  periodo      int not null,
  fecha        timestamptz not null default now(),
  usuario      text,
  archivo      text,
  formato      text,
  filas        int,
  total        numeric
);
create table if not exists poi.cmn (
  id                bigserial primary key,
  carga             bigint not null references poi.cmn_carga (id),
  periodo           int not null,
  anio              int not null,
  centro_costo      text not null,
  meta              text,
  ff                text,
  rubro             text,
  clasificador      text,
  clasif_key        text,
  clasificador_desc text,
  item_codigo       text,
  item_desc         text,
  unidad            text,
  tipo              text,
  cantidad          numeric,
  m                 numeric[] not null default array_fill(0::numeric, array[12]),
  total             numeric not null default 0,
  vigente           boolean not null default true
);
create index if not exists cmn_cc on poi.cmn (periodo, centro_costo, anio) where vigente;
alter table poi.cmn_carga enable row level security;
alter table poi.cmn       enable row level security;

-- Clasificador sin puntos ni espacios: 2.3.2.1.2.1 = "2.3. 2 1. 2 1" (formato SIGA) = 232121
create or replace function poi.clasif_key(c text) returns text
language sql immutable as $$ select regexp_replace(coalesce(c, ''), '[^0-9]', '', 'g') $$;

-- ¿El clasificador va al CMN? Bienes y servicios (2.3) y activos no financieros (2.6).
-- No van: personal (2.1), pensiones (2.2), CAS (2.3.2.8) y demás genéricas (se costean aparte, Tabla 9 de la guía).
create or replace function poi.en_cmn(c text) returns boolean
language sql immutable as $$
  select (poi.clasif_key(c) like '23%' or poi.clasif_key(c) like '26%') and poi.clasif_key(c) not like '2328%'
$$;

-- Cuadre POI (PM3) vs CMN por actividad, clasificador y año
create or replace function poi.cmn_cuadre(per int) returns table (
  centro_costo text, id_ao text, meta text, clasificador text, clasificador_desc text, anio int,
  prio numeric, nopri numeric, cmn numeric, items int)
language sql stable as $$
  with a as (
    select x.id_ao, x.centro_costo, lpad(coalesce(nullif(x.sec_func_2027, ''), x.sec_func_2026, ''), 4, '0') meta
      from poi.ao x where x.periodo = per
  ),
  p as (
    select r.centro_costo, r.id_ao, poi.clasif_key(r.clasificador) ck, min(r.clasificador) cl, per + v.k - 1 anio,
           coalesce(sum(case when r.estado = 'ACTIVA' then v.t end), 0) prio,
           coalesce(sum(case when r.estado = 'DEMANDA ADICIONAL' then v.t end), 0) nopri
      from poi.pm3_recurso r
      cross join lateral (values (1, r.total_a1), (2, r.total_a2), (3, r.total_a3)) v(k, t)
     where r.periodo = per and r.estado in ('ACTIVA', 'DEMANDA ADICIONAL') and poi.en_cmn(r.clasificador)
     group by 1, 2, 3, 5
  ),
  c as (
    select m.centro_costo, a.id_ao, lpad(coalesce(m.meta, ''), 4, '0') meta, m.clasif_key ck, min(m.clasificador) cl,
           min(m.clasificador_desc) cd, m.anio, sum(m.total) cmn, count(*)::int items
      from poi.cmn m
      left join a on a.centro_costo = m.centro_costo and a.meta = lpad(coalesce(m.meta, ''), 4, '0')
     where m.periodo = per and m.vigente
     group by 1, 2, 3, 4, 7
  )
  select coalesce(p.centro_costo, c.centro_costo), coalesce(p.id_ao, c.id_ao),
         coalesce(c.meta, (select a.meta from a where a.id_ao = p.id_ao)),
         coalesce(p.cl, c.cl), c.cd, coalesce(p.anio, c.anio),
         round(coalesce(p.prio, 0), 2), round(coalesce(p.nopri, 0), 2), round(coalesce(c.cmn, 0), 2), coalesce(c.items, 0)
    from p full join c on c.centro_costo = p.centro_costo and c.id_ao = p.id_ao and c.ck = p.ck and c.anio = p.anio
$$;

-- Filas que no cuadran (solo en centros de costo y años con CMN cargado).
-- Cuadra si el CMN es igual a la propuesta total (priorizado + no priorizado) o solo a lo priorizado (±1 sol).
create or replace function poi.cmn_dif(per int) returns table (centro_costo text, id_ao text)
language sql stable as $$
  select q.centro_costo, q.id_ao
    from poi.cmn_cuadre(per) q
   where exists (select 1 from poi.cmn m where m.periodo = per and m.vigente and m.centro_costo = q.centro_costo and m.anio = q.anio)
     and not (abs(q.cmn - (q.prio + q.nopri)) <= 1 or abs(q.cmn - q.prio) <= 1)
$$;

-- ---------- Panel (agrega el estado del CMN y lo exige para "Completa") ----------
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
  difs as (select * from poi.cmn_dif(per)),
  cmncc as (select centro_costo, max(c.fecha) fecha from poi.cmn m join poi.cmn_carga c on c.id = m.carga
             where m.periodo = per and m.vigente group by centro_costo),
  aoc as (
    select a.id_ao, a.centro_costo, a.unidad_organica, a.actualizado,
           a.actualizado is not null as cargada,
           (coalesce(a.descripcion, '') <> '' and coalesce(a.indicador, '') <> '' and coalesce(a.medio_verificacion, '') <> '') as ficha,
           (a.meta_a1 > 0 and a.meta_a2 > 0 and a.meta_a3 > 0) as fisica,
           coalesce((select bool_and(round(g1, 2) = round(apm_a1, 2) and round(g2, 2) = round(apm_a2, 2) and round(g3, 2) = round(apm_a3, 2))
                       from pp where pp.id_ao = a.id_ao), true) as cuadra,
           not exists (select 1 from difs d where d.id_ao = a.id_ao) as cmn_ok,
           coalesce((select sum(apm_a1) from pp where pp.id_ao = a.id_ao), 0) as apm1,
           coalesce((select sum(g1) from pp where pp.id_ao = a.id_ao), 0) as prog1
      from poi.ao a where a.periodo = per
  ),
  dem as (select centro_costo, sum(total_a1) d1 from poi.pm3_recurso where estado = 'DEMANDA ADICIONAL' and periodo = per group by centro_costo),
  nmp as (select centro_costo, count(distinct numero) n from poi.nmp where estado like 'EN REVISI%' and periodo = per group by centro_costo)
  select coalesce(jsonb_agg(jsonb_build_object(
           'cc', x.centro_costo, 'uo', x.uo, 'aos', x.aos, 'cargadas', x.cargadas, 'completas', x.completas,
           'apm_a1', x.apm1, 'apm_carg_a1', x.apm_carg1, 'prog_a1', x.prog1, 'demanda_a1', coalesce(dem.d1, 0),
           'nmp_pendientes', coalesce(nmp.n, 0), 'actualizado', to_char(x.ult at time zone 'America/Lima', 'DD/MM/YYYY HH24:MI'),
           'cmn', case when cmncc.centro_costo is null then 'sin'
                       when x.aos_dif > 0 or exists (select 1 from difs d where d.centro_costo = x.centro_costo and d.id_ao is null) then 'dif'
                       else 'ok' end,
           'cmn_difs', x.aos_dif,
           'cmn_fecha', to_char(cmncc.fecha at time zone 'America/Lima', 'DD/MM/YYYY')
         ) order by x.centro_costo), '[]')
    from (select centro_costo, min(unidad_organica) uo, count(*) aos,
                 count(*) filter (where cargada) cargadas,
                 count(*) filter (where cargada and ficha and fisica and cuadra and cmn_ok) completas,
                 count(*) filter (where not cmn_ok) aos_dif,
                 sum(apm1) apm1, sum(apm1) filter (where cargada) apm_carg1, sum(prog1) prog1, max(actualizado) ult
            from aoc group by centro_costo) x
    left join dem on dem.centro_costo = x.centro_costo
    left join nmp on nmp.centro_costo = x.centro_costo
    left join cmncc on cmncc.centro_costo = x.centro_costo
$$;

-- ---------- Datos extra para la página (prioridad, ubigeo, ítem, CMN) ----------
create or replace function poi.datos_ext(r jsonb, cc text, per int) returns jsonb
language plpgsql stable as $$
declare aos jsonb; rec jsonb; cm jsonb;
begin
  if coalesce(cc, '') = '' or coalesce((r ->> 'ok')::boolean, false) is false then return r; end if;
  per := coalesce((r -> 'periodo' ->> 'anio_ini')::int, per, poi.per_activo());
  select coalesce(jsonb_agg(e.v || jsonb_build_object(
           'prioridad', coalesce(a.prioridad, ''), 'departamento', coalesce(a.departamento, ''), 'provincia', coalesce(a.provincia, ''),
           'distrito', coalesce(a.distrito, ''), 'cod_oei', coalesce(a.cod_oei, ''), 'cod_aei', coalesce(a.cod_aei, '')) order by e.o), '[]')
    into aos
    from jsonb_array_elements(r -> 'aos') with ordinality e(v, o) left join poi.ao a on a.id_ao = e.v ->> 'id_ao';
  select coalesce(jsonb_agg(e.v || jsonb_build_object('item', coalesce(x.item_codigo, '')) order by e.o), '[]')
    into rec
    from jsonb_array_elements(r -> 'recursos') with ordinality e(v, o) left join poi.pm3_recurso x on x.id_rec = e.v ->> 'id';
  select jsonb_build_object(
           'anios', coalesce((select jsonb_agg(distinct m.anio) from poi.cmn m where m.periodo = per and m.vigente and m.centro_costo = cc), '[]'),
           'fecha', (select to_char(max(c.fecha) at time zone 'America/Lima', 'DD/MM/YYYY HH24:MI') from poi.cmn m join poi.cmn_carga c on c.id = m.carga
                      where m.periodo = per and m.vigente and m.centro_costo = cc),
           'dif_aos', coalesce((select jsonb_agg(distinct d.id_ao) from poi.cmn_dif(per) d where d.centro_costo = cc and d.id_ao is not null), '[]'))
    into cm;
  return r || jsonb_build_object('aos', aos, 'recursos', rec, 'cmn', cm);
end $$;

-- ---------- Vista CMN (cuadre por actividad o resumen de todas las áreas) ----------
create or replace function poi.cmn_vista(s jsonb, cc text, per int) returns jsonb
language plpgsql stable as $$
begin
  per := coalesce(per, poi.per_activo());
  if coalesce(cc, '') = '' then
    if s ->> 'r' <> 'OPP' then perform poi.falla('Selecciona un centro de costo.'); end if;
    return jsonb_build_object('ok', true,
      'resumen', coalesce((
        select jsonb_agg(jsonb_build_object('cc', z.cc, 'poi', z.poi, 'prio', z.prio, 'cmn', z.cmn, 'cargado', z.cargado, 'fecha', z.fecha,
                                            'difs', (select count(distinct d.id_ao) from poi.cmn_dif(per) d where d.centro_costo = z.cc and d.id_ao is not null),
                                            'sin_vinculo', (select count(*) from poi.cmn_cuadre(per) q where q.centro_costo = z.cc and q.id_ao is null))
                         order by z.cc)
          from (select a.centro_costo cc,
                       (select coalesce(sum(q.prio + q.nopri), 0) from poi.cmn_cuadre(per) q where q.centro_costo = a.centro_costo and q.anio = per) poi,
                       (select coalesce(sum(q.prio), 0) from poi.cmn_cuadre(per) q where q.centro_costo = a.centro_costo and q.anio = per) prio,
                       (select coalesce(sum(m.total), 0) from poi.cmn m where m.periodo = per and m.vigente and m.centro_costo = a.centro_costo and m.anio = per) cmn,
                       exists (select 1 from poi.cmn m where m.periodo = per and m.vigente and m.centro_costo = a.centro_costo) cargado,
                       (select to_char(max(c.fecha) at time zone 'America/Lima', 'DD/MM/YYYY') from poi.cmn m join poi.cmn_carga c on c.id = m.carga
                         where m.periodo = per and m.vigente and m.centro_costo = a.centro_costo) fecha
                  from (select distinct centro_costo from poi.ao where periodo = per) a) z), '[]'),
      'cargas', coalesce((select jsonb_agg(jsonb_build_object('fecha', to_char(c.fecha at time zone 'America/Lima', 'DD/MM/YYYY HH24:MI'),
                                    'usuario', c.usuario, 'archivo', c.archivo, 'formato', c.formato, 'filas', c.filas, 'total', c.total) order by c.id desc)
                            from (select * from poi.cmn_carga where periodo = per order by id desc limit 10) c), '[]'));
  end if;
  return jsonb_build_object('ok', true,
    'filas', coalesce((select jsonb_agg(jsonb_build_object('id_ao', q.id_ao, 'meta', q.meta, 'clasificador', q.clasificador,
                                'desc', coalesce(q.clasificador_desc, ''), 'anio', q.anio, 'prio', q.prio, 'nopri', q.nopri, 'cmn', q.cmn, 'items', q.items)
                              order by q.id_ao nulls last, q.anio, q.clasificador)
                         from poi.cmn_cuadre(per) q where q.centro_costo = cc), '[]'),
    'anios', coalesce((select jsonb_agg(distinct m.anio) from poi.cmn m where m.periodo = per and m.vigente and m.centro_costo = cc), '[]'),
    'items', coalesce((select jsonb_agg(jsonb_build_object('anio', m.anio, 'meta', m.meta, 'clasificador', m.clasificador, 'item', m.item_codigo,
                                'desc', m.item_desc, 'unidad', m.unidad, 'tipo', m.tipo, 'total', m.total) order by m.anio, m.clasif_key, m.item_codigo)
                         from poi.cmn m where m.periodo = per and m.vigente and m.centro_costo = cc), '[]'));
end $$;

-- ---------- Carga del CMN (OPP) ----------
create or replace function poi.cargar_cmn(s jsonb, per int, p jsonb) returns jsonb
language plpgsql as $$
declare
  ys text[]; v_carga bigint; e jsonb; n int := 0; tot numeric := 0; v_cc text; v_anio int; m numeric[];
  combos text[] := '{}'; malos text[] := '{}';
begin
  if s ->> 'r' <> 'OPP' then perform poi.falla('Solo OPP puede cargar el Cuadro Multianual de Necesidades.'); end if;
  per := coalesce(per, poi.per_activo());
  if (select estado from poi.periodo where anio_ini = per) <> 'ACTIVO' then perform poi.falla('El periodo está cerrado.'); end if;
  ys := poi.ys(per);
  if jsonb_typeof(p -> 'filas') <> 'array' or jsonb_array_length(p -> 'filas') = 0 then perform poi.falla('El archivo no tiene ítems del CMN.'); end if;
  if jsonb_array_length(p -> 'filas') > 20000 then perform poi.falla('El archivo tiene más de 20 000 ítems.'); end if;
  insert into poi.cmn_carga (periodo, usuario, archivo, formato) values (per, s ->> 'u', poi.t(p ->> 'archivo', 200), poi.t(p ->> 'formato', 40))
  returning id into v_carga;
  for e in select value from jsonb_array_elements(p -> 'filas') loop
    v_cc := upper(poi.t(e ->> 'cc', 40));
    v_anio := case when coalesce(e ->> 'anio', '') ~ '^\d{4}$' then (e ->> 'anio')::int end;
    if v_anio is null or v_anio::text <> all (ys) then perform poi.falla('Año ' || coalesce(e ->> 'anio', '(vacío)') || ' fuera del periodo ' || ys[1] || '–' || ys[3] || '.'); end if;
    if not exists (select 1 from poi.ao where periodo = per and centro_costo = v_cc) then
      if v_cc <> all (malos) then malos := malos || v_cc; end if;
      continue;
    end if;
    m := poi.arr(e -> 'm');
    if (v_cc || '|' || v_anio) <> all (combos) then
      combos := combos || (v_cc || '|' || v_anio);
      update poi.cmn set vigente = false where periodo = per and centro_costo = v_cc and anio = v_anio and vigente;
    end if;
    insert into poi.cmn (carga, periodo, anio, centro_costo, meta, ff, rubro, clasificador, clasif_key, clasificador_desc,
                         item_codigo, item_desc, unidad, tipo, cantidad, m, total)
    values (v_carga, per, v_anio, v_cc, nullif(poi.t(e ->> 'meta', 10), ''), poi.t(e ->> 'ff', 60), poi.t(e ->> 'rubro', 60),
            regexp_replace(poi.t(e ->> 'clasificador', 40), '[.[:space:]]+', '.', 'g'), poi.clasif_key(e ->> 'clasificador'), poi.t(e ->> 'clasificador_desc', 200),
            poi.t(e ->> 'item', 20), poi.t(e ->> 'desc', 300), poi.t(e ->> 'unidad', 60), poi.t(e ->> 'tipo', 30),
            case when coalesce(e ->> 'cant', '') ~ '^-?\d+(\.\d+)?$' then (e ->> 'cant')::numeric end,
            m, round(coalesce(nullif(e ->> 'total', '')::numeric, poi.suma(m)), 2));
    n := n + 1; tot := tot + round(coalesce(nullif(e ->> 'total', '')::numeric, poi.suma(m)), 2);
  end loop;
  if n = 0 then perform poi.falla('Ningún ítem corresponde a un centro de costo del POI' || case when array_length(malos, 1) > 0 then ' (no existen: ' || array_to_string(malos[1:5], ', ') || ')' else '' end || '.'); end if;
  update poi.cmn_carga set filas = n, total = tot where id = v_carga;
  perform poi.hist_evento(s ->> 'u', 'cargarCMN', case when array_length(combos, 1) = 1 then split_part(combos[1], '|', 1) end, per,
    'Cargó el CMN ' || coalesce(nullif(poi.t(p ->> 'formato', 40), ''), '') || ' (' || n || ' ítems, S/ ' || poi.fmt(tot) || '): ' || array_to_string(combos, ', '));
  return jsonb_build_object('ok', true, 'items', n, 'total', tot, 'grupos', to_jsonb(combos), 'omitidos', to_jsonb(malos));
end $$;

-- ---------- CMN armado desde la PM3 del portal (para Abastecimiento / SIGA) ----------
create or replace function poi.cmn_poi(s jsonb, cc text, per int) returns jsonb
language sql stable as $$
  select jsonb_build_object('ok', true, 'filas', coalesce(jsonb_agg(jsonb_build_object(
           'Año', per + v.k - 1, 'Centro de costo', r.centro_costo,
           'Meta', lpad(coalesce(nullif(a.sec_func_2027, ''), a.sec_func_2026, ''), 4, '0'), 'Actividad operativa', r.id_ao,
           'FF', split_part(coalesce(nullif(r.ff, ''), p.ff, ''), '-', 1), 'Rubro', coalesce(r.rubro, p.rubro::text, ''),
           'Clasificador', r.clasificador, 'Código ítem', coalesce(r.item_codigo, ''), 'Descripción', r.recurso, 'Unidad', coalesce(r.um, ''),
           'Tipo', case when poi.clasif_key(r.clasificador) like '231%' or poi.clasif_key(r.clasificador) like '26%' then 'BIEN' else 'SERVICIO' end,
           'Cantidad', case v.k when 1 then r.cant_a1 when 2 then r.cant_a2 else r.cant_a3 end,
           'Ene', v.m[1], 'Feb', v.m[2], 'Mar', v.m[3], 'Abr', v.m[4], 'May', v.m[5], 'Jun', v.m[6],
           'Jul', v.m[7], 'Ago', v.m[8], 'Set', v.m[9], 'Oct', v.m[10], 'Nov', v.m[11], 'Dic', v.m[12],
           'Total', v.t, 'Estado POI', case when r.estado = 'ACTIVA' then 'PRIORIZADO' else 'NO PRIORIZADO' end
         ) order by r.centro_costo, r.id_ao, v.k, r.clasificador, r.id_rec), '[]'))
    from poi.pm3_recurso r
    join poi.ao a on a.id_ao = r.id_ao
    left join poi.partida p on p.llave = r.llave
    cross join lateral (values (1, r.m_a1, r.total_a1), (2, r.m_a2, r.total_a2), (3, r.m_a3, r.total_a3)) v(k, m, t)
   where r.periodo = per and r.estado in ('ACTIVA', 'DEMANDA ADICIONAL') and poi.en_cmn(r.clasificador) and v.t <> 0
     and (coalesce(cc, '') = '' or r.centro_costo = cc)
$$;

-- ---------- Anexo B-4: POI Multianual con programación física y de costeo ----------
create or replace function poi.anexo_b4(s jsonb, cc text, per int) returns jsonb
language sql stable as $$
  with a as (
    select x.* from poi.ao x where x.periodo = per and (coalesce(cc, '') = '' or x.centro_costo = cc)
  ),
  fis as (   -- meta física mensual = tareas representativas de primer nivel
    select t.id_ao, v.k,
           array(select coalesce(sum(t2.m[i]), 0) from poi.pm2_tarea q
                   cross join lateral (select case v.k when 1 then q.m_a1 when 2 then q.m_a2 else q.m_a3 end m) t2
                   cross join generate_series(1, 12) i
                  where q.id_ao = t.id_ao and q.estado = 'ACTIVA' and q.repr and position('.' in q.codigo) = 0
                  group by i order by i) m
      from (select distinct id_ao from poi.pm2_tarea where estado = 'ACTIVA') t cross join (values (1), (2), (3)) v(k)
  ),
  cos as (   -- costeo mensual = recursos de la PM3 (priorizado + no priorizado)
    select r.id_ao, v.k, array(select coalesce(sum(case v.k when 1 then r2.m_a1[i] when 2 then r2.m_a2[i] else r2.m_a3[i] end), 0)
                                 from poi.pm3_recurso r2 cross join generate_series(1, 12) i
                                where r2.id_ao = r.id_ao and r2.estado in ('ACTIVA', 'DEMANDA ADICIONAL') group by i order by i) m
      from (select distinct id_ao from poi.pm3_recurso where estado in ('ACTIVA', 'DEMANDA ADICIONAL')) r cross join (values (1), (2), (3)) v(k)
  )
  select jsonb_build_object('ok', true, 'filas', coalesce(jsonb_agg(jsonb_build_object(
           'cod_oei', coalesce(a.cod_oei, ''), 'oei', coalesce(a.oei, ''), 'cod_aei', coalesce(a.cod_aei, ''), 'aei', coalesce(a.aei, ''),
           'cc', a.centro_costo, 'id_ao', a.id_ao, 'ao', coalesce(nullif(a.nombre_ao, ''), a.finalidad, ''),
           'ubigeo', concat_ws(' / ', nullif(a.departamento, ''), nullif(a.provincia, ''), nullif(a.distrito, '')),
           'um', coalesce(a.unidad_medida, ''), 'prioridad', coalesce(a.prioridad, ''), 'anio', per + v.k - 1,
           'fisico', to_jsonb(coalesce(f.m, array_fill(0::numeric, array[12]))),
           'meta', case v.k when 1 then a.meta_a1 when 2 then a.meta_a2 else a.meta_a3 end,
           'costeo', to_jsonb(coalesce(c.m, array_fill(0::numeric, array[12])))
         ) order by a.cod_oei, a.cod_aei, a.orden, a.id_ao, v.k), '[]'))
    from a cross join (values (1), (2), (3)) v(k)
    left join fis f on f.id_ao = a.id_ao and f.k = v.k
    left join cos c on c.id_ao = a.id_ao and c.k = v.k
$$;

-- ---------- guardar_ao: prioridad, ubigeo e ítem SIGA (parche sobre la función vigente) ----------
do $$
declare d text; o text; rep text[][] := array[
  array['ff text, rubro text, clasificador text) on commit drop;',
        'ff text, rubro text, clasificador text, item text) on commit drop;'],
  array[E'ex.clasificador, \'\'));\n      continue;',
        E'ex.clasificador, \'\'), case when e ? \'item\' then poi.t(e ->> \'item\', 20) else coalesce(ex.item_codigo, \'\') end);\n      continue;'],
  array[E'coalesce(nullif(case when hay_p then pr.clasificador end, \'\'), ex.clasificador, \'\'));',
        E'coalesce(nullif(case when hay_p then pr.clasificador end, \'\'), ex.clasificador, \'\'), case when e ? \'item\' then poi.t(e ->> \'item\', 20) else coalesce(ex.item_codigo, \'\') end);'],
  array['ff, rubro, clasificador, llave, n_prevision,', 'ff, rubro, clasificador, llave, n_prevision, item_codigo,'],
  array['clasificador, llave, prev,', E'clasificador, llave, prev, nullif(item, \'\'),'],
  array['n_prevision = excluded.n_prevision,', 'n_prevision = excluded.n_prevision, item_codigo = excluded.item_codigo,'],
  array[E'medio_verificacion = poi.t(p1 ->> \'medio\'),',
        E'medio_verificacion = poi.t(p1 ->> \'medio\'),\n         prioridad = case when upper(poi.t(p1 ->> \'prioridad\')) in (\'MUY ALTA\', \'ALTA\', \'MEDIA\') then upper(poi.t(p1 ->> \'prioridad\')) when p1 ? \'prioridad\' then null else prioridad end,\n         departamento = coalesce(nullif(upper(poi.t(p1 ->> \'departamento\', 60)), \'\'), departamento),\n         provincia = coalesce(nullif(upper(poi.t(p1 ->> \'provincia\', 60)), \'\'), provincia),\n         distrito = coalesce(nullif(upper(poi.t(p1 ->> \'distrito\', 60)), \'\'), distrito),']
]; i int;
begin
  d := pg_get_functiondef('poi.guardar_ao(jsonb,text,jsonb)'::regprocedure);
  if position('item_codigo' in d) > 0 then raise notice 'guardar_ao ya tiene el parche'; return; end if;
  for i in 1..array_length(rep, 1) loop
    o := d; d := replace(d, rep[i][1], rep[i][2]);
    if d = o then raise exception 'Parche % de guardar_ao no aplicó', i; end if;
  end loop;
  execute d;
end $$;

-- Etiquetas del historial para los datos nuevos
create or replace function poi.hist_campo(k text, per int) returns text
language sql immutable as $$
  select case
    when k in ('actualizado', 'actualizado_por', 'origen', 'periodo', 'creado', 'registrado', 'orden', 'id_ao', 'centro_costo',
               'id_tarea', 'id_rec', 'id', 'total_a1', 'total_a2', 'total_a3', 'resuelto', 'resuelto_por', 'solicitante',
               'fecha', 'numero', 'cu_efp') then null
    when k ~ '^meta_a[123]$' then 'Meta física ' || (per + right(k, 1)::int - 1)
    when k ~ '^apm_a[123]$'  then 'Techo APM ' || (per + right(k, 1)::int - 1)
    when k ~ '^cant_a[123]$' then 'Cantidad ' || (per + right(k, 1)::int - 1)
    when k ~ '^m_a[123]$'    then (per + right(k, 1)::int - 1)::text
    when k = 'meses'              then 'APM mensual'
    when k = 'nombre_ao'          then 'Nombre de la actividad'
    when k = 'descripcion'        then 'Descripción'
    when k = 'beneficiarios'      then 'Beneficiarios'
    when k = 'indicador'          then 'Indicador'
    when k = 'medio_verificacion' then 'Medio de verificación'
    when k = 'unidad_medida'      then 'Unidad de medida'
    when k = 'um'                 then 'Unidad de medida'
    when k = 'codigo'             then 'Código'
    when k = 'nombre'             then 'Nombre de la tarea'
    when k = 'repr'               then 'Representativa'
    when k = 'acum'               then 'Acumulable'
    when k = 'propio'             then 'Valor propio (tarea padre)'
    when k = 'codigo_tarea'       then 'Tarea'
    when k = 'recurso'            then 'Recurso'
    when k = 'ff'                 then 'Fuente de financiamiento'
    when k = 'rubro'              then 'Rubro'
    when k = 'clasificador'       then 'Clasificador'
    when k = 'llave'              then 'Partida'
    when k = 'n_prevision'        then 'N° previsión'
    when k = 'item_codigo'        then 'Código ítem SIGA'
    when k = 'prioridad'          then 'Prioridad'
    when k = 'departamento'       then 'Departamento'
    when k = 'provincia'          then 'Provincia'
    when k = 'distrito'           then 'Distrito'
    when k = 'estado'             then 'Estado'
    when k = 'credito'            then 'Crédito'
    when k = 'anulacion'          then 'Anulación'
    when k = 'meta_antes'         then 'Meta física antes'
    when k = 'meta_despues'       then 'Meta física después'
    when k = 'sustento'           then 'Sustento'
    when k = 'observacion'        then 'Observación'
    when k = 'version_poi'        then 'Versión POI'
    else k
  end
$$;

-- ---------- Punto de entrada único ----------
create or replace function public.poi_api(p jsonb) returns jsonb
language plpgsql security definer
set search_path = poi, extensions, public
as $$
declare accion text := coalesce(p ->> 'accion', ''); s jsonb; cc text; det text; r jsonb; per int; nue int;
begin
  if accion = 'ping' then return jsonb_build_object('ok', true, 'hora', now()); end if;
  if accion = 'login' then return poi.login(p); end if;
  s := poi.sesion(p ->> 'token');
  cc := s ->> 'cc';
  if s ->> 'r' = 'OPP' then cc := poi.t(p ->> 'cc'); end if;
  per := case when coalesce(p ->> 'periodo', '') ~ '^\d{4}$' then (p ->> 'periodo')::int else null end;
  perform set_config('poi.usuario', coalesce(s ->> 'u', ''), true), set_config('poi.accion', accion, true);
  if accion in ('guardarAO', 'enviarNMP') and coalesce(cc, '') = '' then perform poi.falla('Selecciona un centro de costo.'); end if;
  case accion
    when 'datos' then
      r := poi.datos(s, cc, per);
      if s ->> 'r' = 'OPP' and coalesce(cc, '') = '' then r := r || jsonb_build_object('versiones', poi.versiones((r -> 'periodo' ->> 'anio_ini')::int)); end if;
      return poi.datos_ext(r, cc, per);
    when 'guardarAO'        then return poi.guardar_ao(s, cc, p);
    when 'enviarNMP'        then return poi.enviar_nmp(s, cc, p);
    when 'resolverNMP'      then return poi.resolver_nmp(s, p);
    when 'cambiarClave'     then
      r := poi.cambiar_clave(s, p);
      if coalesce((r ->> 'ok')::boolean, false) then perform poi.hist_evento(s ->> 'u', accion, null, null, 'Cambió su contraseña'); end if;
      return r;
    when 'restablecerClave' then
      r := poi.restablecer_clave(s, p);
      if coalesce((r ->> 'ok')::boolean, false) then perform poi.hist_evento(s ->> 'u', accion, null, null, 'Restableció la contraseña del usuario ' || poi.t(p ->> 'usuario', 60)); end if;
      return r;
    when 'exportar'         then return poi.exportar(s, per);
    when 'cerrarVersion'    then
      r := poi.cerrar_version(s, p);
      if coalesce((r ->> 'ok')::boolean, false) then
        perform poi.hist_evento(s ->> 'u', accion, null, coalesce(per, poi.per_activo()),
          'Cerró la versión "' || poi.t(p ->> 'nombre', 120) || '" (' || coalesce(nullif(poi.t(p ->> 'etapa', 60), ''), 'Proyecto de ley') || ')');
      end if;
      return r;
    when 'nuevoPeriodo'     then
      r := poi.nuevo_periodo(s, p);
      if coalesce((r ->> 'ok')::boolean, false) then
        nue := (p ->> 'anio_ini')::int;
        update poi.ao n set prioridad = o.prioridad
          from poi.ao o where n.periodo = nue and o.periodo = nue - 1 and o.prioridad is not null
           and substr(n.id_ao, 5) = substr(o.id_ao, 5) and n.centro_costo = o.centro_costo;
        update poi.pm3_recurso n set item_codigo = o.item_codigo
          from poi.pm3_recurso o where n.periodo = nue and o.periodo = nue - 1 and o.item_codigo is not null
           and substr(n.id_rec, 5) = substr(o.id_rec, 5);
        perform poi.hist_evento(s ->> 'u', accion, null, nue,
          'Abrió el periodo ' || nue || '–' || (nue + 2) || ' (copió actividades y programación; cerró el periodo anterior)');
      end if;
      return r;
    when 'historial'        then
      if s ->> 'r' <> 'OPP' and coalesce(cc, '') = '' then perform poi.falla('Tu usuario no tiene centro de costo.'); end if;
      return poi.historial(s, cc, per, p);
    when 'cmn'              then return poi.cmn_vista(s, cc, per);
    when 'cargarCMN'        then return poi.cargar_cmn(s, per, p);
    when 'cmnPOI'           then return poi.cmn_poi(s, cc, coalesce(per, poi.per_activo()));
    when 'anexoB4'          then return poi.anexo_b4(s, cc, coalesce(per, poi.per_activo()));
    else perform poi.falla('Acción no reconocida.');
  end case;
  return null;
exception
  when sqlstate 'PT401' then
    return jsonb_build_object('ok', false, 'error', sqlerrm, 'relogin', true);
  when sqlstate 'PT400' then
    get stacked diagnostics det = pg_exception_detail;
    return jsonb_build_object('ok', false, 'error', sqlerrm)
        || case when coalesce(det, '') <> '' then jsonb_build_object('detalle', det::jsonb) else '{}'::jsonb end;
end $$;
revoke all on function public.poi_api(jsonb) from public;
grant execute on function public.poi_api(jsonb) to anon, authenticated;
