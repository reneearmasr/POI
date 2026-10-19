-- =====================================================================
-- POI – ATU · 12 · Mejoras según la Guía CEPLAN
--  1. Prioridad obligatoria para "Completa" y prelación de lo no priorizado
--  2. Estado del registro por centro de costo (rol Supervisor, anexo A-4)
--  3. Contenido mínimo del POI (tabla 10): genérica, rubro, centro de costo
--  4. Inversiones: denominación con CUI (código de producto de la APM)
--  5. Revisión de calidad: prioridad, redacción y unidades de medida uniformes
-- Ejecutar después de 11_cmn_ceplan.sql. No borra datos.
-- =====================================================================

create table if not exists poi.registro_cc (
  periodo         int  not null,
  centro_costo    text not null,
  estado          text not null default 'EN REGISTRO'
                  check (estado in ('EN REGISTRO', 'ENVIADO', 'OBSERVADO', 'VALIDADO', 'CERRADO')),
  observacion     text,
  actualizado     timestamptz not null default now(),
  actualizado_por text,
  primary key (periodo, centro_costo)
);
alter table poi.registro_cc enable row level security;

create or replace function poi.registro_estado(per int, cc text) returns text
language sql stable as $$
  select coalesce((select estado from poi.registro_cc where periodo = per and centro_costo = cc), 'EN REGISTRO')
$$;

-- Nombre normalizado (sin tildes, minúsculas, espacios simples)
create or replace function poi.nnorm(x text) returns text
language sql immutable as $$
  select trim(regexp_replace(translate(lower(coalesce(x, '')), 'áéíóúüñ', 'aeiouun'), '\s+', ' ', 'g'))
$$;

-- CUI de una inversión (código de producto de 7 dígitos)
create or replace function poi.cui(tipo text, cod text) returns text
language sql immutable as $$
  select case when tipo = 'Inversiones' and coalesce(cod, '') ~ '^\d{7}$' then cod end
$$;

-- ¿La denominación sigue la guía? AO: sustantivo derivado de verbo; inversión: tiene CUI
create or replace function poi.redaccion_ok(tipo text, cod text, nombre text) returns boolean
language sql immutable as $$
  select case when tipo = 'Inversiones' then poi.cui(tipo, cod) is not null
              else split_part(poi.nnorm(nombre), ' ', 1) ~ '(cion|sion)$' end
$$;

create or replace function poi.prio_orden(p text) returns int
language sql immutable as $$ select case p when 'MUY ALTA' then 1 when 'ALTA' then 2 when 'MEDIA' then 3 else 4 end $$;

-- ---------- Cambios de estado del registro ----------
create or replace function poi.registro_accion(s jsonb, cc text, per int, p jsonb) returns jsonb
language plpgsql as $$
declare
  op text := poi.t(p ->> 'op', 20); obs text := poi.t(p ->> 'observacion', 1000);
  est text; nuevo text; opp boolean := s ->> 'r' = 'OPP'; n int := 0; c record;
begin
  per := coalesce(per, poi.per_activo());
  if (select estado from poi.periodo where anio_ini = per) <> 'ACTIVO' then perform poi.falla('El periodo está cerrado.'); end if;
  if op = 'cerrarTodos' then
    if not opp then perform poi.falla('Solo OPP puede cerrar el registro.'); end if;
    for c in select distinct a.centro_costo from poi.ao a where a.periodo = per
              and poi.registro_estado(per, a.centro_costo) in ('EN REGISTRO', 'OBSERVADO') loop
      insert into poi.registro_cc (periodo, centro_costo, estado, observacion, actualizado, actualizado_por)
      values (per, c.centro_costo, 'CERRADO', 'Plazo de registro vencido', now(), s ->> 'u')
      on conflict (periodo, centro_costo) do update set estado = 'CERRADO', observacion = excluded.observacion, actualizado = now(), actualizado_por = s ->> 'u';
      n := n + 1;
    end loop;
    perform poi.hist_evento(s ->> 'u', 'registro', null, per, 'Cerró el registro de ' || n || ' centros de costo pendientes');
    return jsonb_build_object('ok', true, 'cerrados', n);
  end if;
  if coalesce(cc, '') = '' then perform poi.falla('Selecciona un centro de costo.'); end if;
  est := poi.registro_estado(per, cc);
  if op = 'enviar' then
    if est not in ('EN REGISTRO', 'OBSERVADO') then perform poi.falla('El registro ya está ' || lower(est) || '.'); end if;
    if not exists (select 1 from poi.ao where periodo = per and centro_costo = cc and actualizado is not null) then
      perform poi.falla('Guarda al menos una actividad antes de enviar a OPP.');
    end if;
    nuevo := 'ENVIADO'; obs := null;
  elsif not opp then
    perform poi.falla('Solo OPP puede validar, observar, cerrar o habilitar el registro.');
  elsif op = 'validar' then
    if est <> 'ENVIADO' then perform poi.falla('Solo se valida un registro enviado por el área.'); end if;
    nuevo := 'VALIDADO'; obs := null;
  elsif op = 'observar' then
    if length(obs) < 10 then perform poi.falla('Escribe la observación para el área (mínimo 10 caracteres).'); end if;
    nuevo := 'OBSERVADO';
  elsif op = 'cerrar' then
    nuevo := 'CERRADO'; obs := coalesce(nullif(obs, ''), 'Registro cerrado por OPP');
  elsif op = 'habilitar' then
    nuevo := 'EN REGISTRO'; obs := null;
  else
    perform poi.falla('Operación no reconocida.');
  end if;
  insert into poi.registro_cc (periodo, centro_costo, estado, observacion, actualizado, actualizado_por)
  values (per, cc, nuevo, obs, now(), s ->> 'u')
  on conflict (periodo, centro_costo) do update set estado = excluded.estado, observacion = excluded.observacion,
    actualizado = now(), actualizado_por = excluded.actualizado_por;
  perform poi.hist_evento(s ->> 'u', 'registro', cc, per,
    case op when 'enviar' then 'Envió el registro a OPP para validación' when 'validar' then 'Validó el registro'
            when 'observar' then 'Observó el registro: ' || obs when 'cerrar' then 'Cerró el registro' else 'Habilitó el registro para edición' end);
  return jsonb_build_object('ok', true, 'estado', nuevo);
end $$;

-- ---------- Panel: registro, prioridad y CUI en "Completa" ----------
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
           (coalesce(a.descripcion, '') <> '' and coalesce(a.indicador, '') <> '' and coalesce(a.medio_verificacion, '') <> ''
            and a.prioridad is not null) as ficha,
           (a.meta_a1 > 0 and a.meta_a2 > 0 and a.meta_a3 > 0) as fisica,
           coalesce((select bool_and(round(g1, 2) = round(apm_a1, 2) and round(g2, 2) = round(apm_a2, 2) and round(g3, 2) = round(apm_a3, 2))
                       from pp where pp.id_ao = a.id_ao), true) as cuadra,
           not exists (select 1 from difs d where d.id_ao = a.id_ao) as cmn_ok,
           a.prioridad is null as sin_pri,
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
           'cmn_difs', x.aos_dif, 'sin_prioridad', x.sin_pri,
           'cmn_fecha', to_char(cmncc.fecha at time zone 'America/Lima', 'DD/MM/YYYY'),
           'registro', poi.registro_estado(per, x.centro_costo),
           'registro_fecha', (select to_char(r.actualizado at time zone 'America/Lima', 'DD/MM/YYYY') from poi.registro_cc r where r.periodo = per and r.centro_costo = x.centro_costo)
         ) order by x.centro_costo), '[]')
    from (select centro_costo, min(unidad_organica) uo, count(*) aos,
                 count(*) filter (where cargada) cargadas,
                 count(*) filter (where cargada and ficha and fisica and cuadra and cmn_ok) completas,
                 count(*) filter (where not cmn_ok) aos_dif,
                 count(*) filter (where sin_pri) sin_pri,
                 sum(apm1) apm1, sum(apm1) filter (where cargada) apm_carg1, sum(prog1) prog1, max(actualizado) ult
            from aoc group by centro_costo) x
    left join dem on dem.centro_costo = x.centro_costo
    left join nmp on nmp.centro_costo = x.centro_costo
    left join cmncc on cmncc.centro_costo = x.centro_costo
$$;

-- ---------- Revisión de calidad según la guía (para el panel de OPP) ----------
create or replace function poi.calidad(per int) returns jsonb
language sql stable as $$
  with a as (select x.*, coalesce(nullif(x.nombre_ao, ''), x.finalidad, '') nom from poi.ao x where x.periodo = per),
  um as (
    select poi.nnorm(nom) k, min(nom) nombre, jsonb_agg(distinct upper(trim(unidad_medida))) ums,
           jsonb_agg(jsonb_build_object('id', id_ao, 'cc', centro_costo, 'um', unidad_medida) order by centro_costo, id_ao) aos
      from a where coalesce(unidad_medida, '') <> '' group by 1 having count(distinct upper(trim(unidad_medida))) > 1
  )
  select jsonb_build_object(
    'total', (select count(*) from a),
    'sin_prioridad', (select count(*) from a where prioridad is null),
    'prioridad', (select jsonb_object_agg(k, n) from (select coalesce(prioridad, 'SIN DEFINIR') k, count(*) n from a group by 1) z),
    'redaccion', coalesce((select jsonb_agg(jsonb_build_object('id', id_ao, 'cc', centro_costo, 'nombre', nom) order by centro_costo, id_ao)
                             from a where not poi.redaccion_ok(tipo, cod_producto, nom)), '[]'),
    'inversiones', coalesce((select jsonb_agg(jsonb_build_object('id', id_ao, 'cc', centro_costo, 'nombre', nom, 'cui', poi.cui(tipo, cod_producto)) order by id_ao)
                               from a where tipo = 'Inversiones'), '[]'),
    'um', coalesce((select jsonb_agg(jsonb_build_object('nombre', nombre, 'ums', ums, 'aos', aos) order by nombre) from um), '[]'))
$$;

-- Prelación: lo no priorizado ordenado por prioridad (principio de prelación, numeral 3.2.3)
create or replace function poi.prelacion(per int) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', z.id_ao, 'cc', z.centro_costo, 'nombre', z.nom, 'prioridad', coalesce(z.prioridad, ''),
                                               'oei', coalesce(z.cod_oei, ''), 'aei', coalesce(z.cod_aei, ''), 'nopri', z.nopri, 'acum', z.acum) order by z.ord), '[]')
    from (select a.id_ao, a.centro_costo, coalesce(nullif(a.nombre_ao, ''), a.finalidad) nom, a.prioridad, a.cod_oei, a.cod_aei, d.nopri,
                 row_number() over (order by poi.prio_orden(a.prioridad), a.cod_oei, a.cod_aei, d.nopri desc, a.id_ao) ord,
                 sum(d.nopri) over (order by poi.prio_orden(a.prioridad), a.cod_oei, a.cod_aei, d.nopri desc, a.id_ao) acum
            from poi.ao a
            join (select id_ao, sum(total_a1) nopri from poi.pm3_recurso where periodo = per and estado = 'DEMANDA ADICIONAL' group by id_ao having sum(total_a1) > 0) d
              on d.id_ao = a.id_ao
           where a.periodo = per) z
$$;

-- ---------- Contenido mínimo del POI (tabla 10) ----------
create or replace function poi.contenido_minimo(s jsonb, cc text, per int) returns jsonb
language sql stable as $$
  with a as (select x.* from poi.ao x where x.periodo = per and (coalesce(cc, '') = '' or x.centro_costo = cc)),
  r as (
    select r.*, a.centro_costo cca, coalesce(nullif(r.ff, ''), p.ff, '') ffx, coalesce(nullif(r.rubro, ''), p.rubro::text, '') rbx,
           split_part(r.clasificador, '.', 1) || '.' || split_part(r.clasificador, '.', 2) gen
      from poi.pm3_recurso r join a on a.id_ao = r.id_ao left join poi.partida p on p.llave = r.llave
     where r.estado in ('ACTIVA', 'DEMANDA ADICIONAL')
  ),
  agg as (
    select k, d,
           sum(case when estado = 'ACTIVA' then total_a1 else 0 end) p1, sum(case when estado <> 'ACTIVA' then total_a1 else 0 end) n1,
           sum(case when estado = 'ACTIVA' then total_a2 else 0 end) p2, sum(case when estado <> 'ACTIVA' then total_a2 else 0 end) n2,
           sum(case when estado = 'ACTIVA' then total_a3 else 0 end) p3, sum(case when estado <> 'ACTIVA' then total_a3 else 0 end) n3, t
      from (select 'gen' t, gen k, case gen when '2.1' then 'Personal y obligaciones sociales' when '2.2' then 'Pensiones y otras prestaciones sociales'
                                     when '2.3' then 'Bienes y servicios' when '2.4' then 'Donaciones y transferencias' when '2.5' then 'Otros gastos'
                                     when '2.6' then 'Adquisición de activos no financieros' when '2.7' then 'Adquisición de activos financieros'
                                     when '2.8' then 'Servicio de la deuda pública' else '' end d, estado, total_a1, total_a2, total_a3 from r
            union all
            select 'rub', coalesce(nullif(ffx, ''), 'Sin fuente') || case when rbx <> '' then ' · rubro ' || lpad(rbx, 2, '0') else '' end, '', estado, total_a1, total_a2, total_a3 from r
            union all
            select 'cc', cca, (select min(unidad_organica) from a where a.centro_costo = r.cca), estado, total_a1, total_a2, total_a3 from r) u
     group by t, k, d
  )
  select jsonb_build_object('ok', true,
    'presentacion', jsonb_build_object(
      'periodo', per || '–' || (per + 2),
      'pei', coalesce((select valor from poi.config where clave = 'pei_periodo'), ''),
      'oei', (select count(distinct cod_oei) from a), 'aei', (select count(distinct cod_aei) from a),
      'aos', (select count(*) from a), 'ccs', (select count(distinct centro_costo) from a),
      'inversiones', (select count(*) from a where tipo = 'Inversiones'),
      'prio_a1', (select coalesce(sum(total_a1), 0) from r where estado = 'ACTIVA'),
      'nopri_a1', (select coalesce(sum(total_a1), 0) from r where estado <> 'ACTIVA'),
      'prio_a2', (select coalesce(sum(total_a2), 0) from r where estado = 'ACTIVA'),
      'prio_a3', (select coalesce(sum(total_a3), 0) from r where estado = 'ACTIVA')),
    'filas', coalesce((select jsonb_agg(jsonb_build_object('t', t, 'k', k, 'd', d, 'p1', p1, 'n1', n1, 'p2', p2, 'n2', n2, 'p3', p3, 'n3', n3) order by t, k) from agg), '[]'))
$$;

-- ---------- Anexo B-4 con CUI en las inversiones ----------
create or replace function poi.anexo_b4(s jsonb, cc text, per int) returns jsonb
language sql stable as $$
  with a as (
    select x.* from poi.ao x where x.periodo = per and (coalesce(cc, '') = '' or x.centro_costo = cc)
  ),
  fis as (
    select t.id_ao, v.k,
           array(select coalesce(sum(t2.m[i]), 0) from poi.pm2_tarea q
                   cross join lateral (select case v.k when 1 then q.m_a1 when 2 then q.m_a2 else q.m_a3 end m) t2
                   cross join generate_series(1, 12) i
                  where q.id_ao = t.id_ao and q.estado = 'ACTIVA' and q.repr and position('.' in q.codigo) = 0
                  group by i order by i) m
      from (select distinct id_ao from poi.pm2_tarea where estado = 'ACTIVA') t cross join (values (1), (2), (3)) v(k)
  ),
  cos as (
    select r.id_ao, v.k, array(select coalesce(sum(case v.k when 1 then r2.m_a1[i] when 2 then r2.m_a2[i] else r2.m_a3[i] end), 0)
                                 from poi.pm3_recurso r2 cross join generate_series(1, 12) i
                                where r2.id_ao = r.id_ao and r2.estado in ('ACTIVA', 'DEMANDA ADICIONAL') group by i order by i) m
      from (select distinct id_ao from poi.pm3_recurso where estado in ('ACTIVA', 'DEMANDA ADICIONAL')) r cross join (values (1), (2), (3)) v(k)
  )
  select jsonb_build_object('ok', true, 'filas', coalesce(jsonb_agg(jsonb_build_object(
           'cod_oei', coalesce(a.cod_oei, ''), 'oei', coalesce(a.oei, ''), 'cod_aei', coalesce(a.cod_aei, ''), 'aei', coalesce(a.aei, ''),
           'cc', a.centro_costo, 'id_ao', a.id_ao,
           'ao', coalesce(nullif(a.nombre_ao, ''), a.finalidad, '') || coalesce(' - CUI ' || poi.cui(a.tipo, a.cod_producto), ''),
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

-- ---------- Datos extra: CUI, unidades de medida de actividades similares, estado del registro ----------
create or replace function poi.datos_ext(r jsonb, cc text, per int) returns jsonb
language plpgsql stable as $$
declare aos jsonb; rec jsonb; cm jsonb; rg jsonb;
begin
  if coalesce((r ->> 'ok')::boolean, false) is false then return r; end if;
  per := coalesce((r -> 'periodo' ->> 'anio_ini')::int, per, poi.per_activo());
  if coalesce(cc, '') = '' then
    if r -> 'sesion' ->> 'rol' = 'OPP' then
      return r || jsonb_build_object('calidad', poi.calidad(per), 'prelacion', poi.prelacion(per));
    end if;
    return r;
  end if;
  select coalesce(jsonb_agg(e.v || jsonb_build_object(
           'prioridad', coalesce(a.prioridad, ''), 'departamento', coalesce(a.departamento, ''), 'provincia', coalesce(a.provincia, ''),
           'distrito', coalesce(a.distrito, ''), 'cod_oei', coalesce(a.cod_oei, ''), 'cod_aei', coalesce(a.cod_aei, ''),
           'cui', coalesce(poi.cui(a.tipo, a.cod_producto), ''),
           'um_otras', coalesce((select jsonb_agg(distinct upper(trim(o.unidad_medida))) from poi.ao o
                                  where o.periodo = a.periodo and o.id_ao <> a.id_ao and coalesce(o.unidad_medida, '') <> ''
                                    and poi.nnorm(coalesce(nullif(o.nombre_ao, ''), o.finalidad)) = poi.nnorm(coalesce(nullif(a.nombre_ao, ''), a.finalidad))
                                    and upper(trim(o.unidad_medida)) <> upper(trim(coalesce(a.unidad_medida, '')))), '[]')
         ) order by e.o), '[]')
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
  select jsonb_build_object('estado', poi.registro_estado(per, cc), 'observacion', coalesce(g.observacion, ''),
                            'fecha', coalesce(to_char(g.actualizado at time zone 'America/Lima', 'DD/MM/YYYY HH24:MI'), ''), 'por', coalesce(g.actualizado_por, ''))
    into rg
    from (select 1) one left join poi.registro_cc g on g.periodo = per and g.centro_costo = cc;
  return r || jsonb_build_object('aos', aos, 'recursos', rec, 'cmn', cm, 'registro', rg);
end $$;

insert into poi.config (clave, valor) values ('pei_periodo', '') on conflict (clave) do nothing;

-- ---------- Punto de entrada único ----------
create or replace function public.poi_api(p jsonb) returns jsonb
language plpgsql security definer
set search_path = poi, extensions, public
as $$
declare accion text := coalesce(p ->> 'accion', ''); s jsonb; cc text; det text; r jsonb; per int; nue int; est text;
begin
  if accion = 'ping' then return jsonb_build_object('ok', true, 'hora', now()); end if;
  if accion = 'login' then return poi.login(p); end if;
  s := poi.sesion(p ->> 'token');
  cc := s ->> 'cc';
  if s ->> 'r' = 'OPP' then cc := poi.t(p ->> 'cc'); end if;
  per := case when coalesce(p ->> 'periodo', '') ~ '^\d{4}$' then (p ->> 'periodo')::int else null end;
  perform set_config('poi.usuario', coalesce(s ->> 'u', ''), true), set_config('poi.accion', accion, true);
  if accion in ('guardarAO', 'enviarNMP') and coalesce(cc, '') = '' then perform poi.falla('Selecciona un centro de costo.'); end if;
  if accion = 'guardarAO' and s ->> 'r' <> 'OPP' then
    est := poi.registro_estado((select a.periodo from poi.ao a where a.id_ao = poi.t(p ->> 'id_ao')), cc);
    if est not in ('EN REGISTRO', 'OBSERVADO') then
      perform poi.falla('Tu registro está ' || lower(est) || ': no se puede modificar. Si necesitas corregir algo, pide a OPP que lo habilite.');
    end if;
  end if;
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
    when 'contenidoMinimo'  then return poi.contenido_minimo(s, cc, coalesce(per, poi.per_activo()));
    when 'registro'         then return poi.registro_accion(s, cc, per, p);
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
