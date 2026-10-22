-- =====================================================================
-- 14 · NMP con los tres anexos oficiales (22/10/2026)
--   Anexo 01: solicitud por partida (se deriva del Anexo 03), por fuente.
--   Anexo 02: reprogramación física anual de las tareas (PM2, año 1).
--   Anexo 03: modificación de recursos (PM3, año 1), mes a mes.
--   Al aprobar, OPP aplica los Anexos 02 y 03 a la PM2 y PM3 del año 1
--   y el techo del año 1 pasa a ser APM + NMP aprobadas (PIM vigente).
-- Se ejecuta después de 13_pei.sql. No borra nada.
-- =====================================================================

alter table poi.nmp add column if not exists sustento_credito   text;
alter table poi.nmp add column if not exists sustento_anulacion text;
alter table poi.nmp add column if not exists pim                numeric;
alter table poi.nmp add column if not exists certificado        numeric;
alter table poi.nmp add column if not exists saldo              numeric;
alter table poi.nmp add column if not exists sec_func           text;
alter table poi.nmp add column if not exists categoria          text;
alter table poi.nmp add column if not exists producto           text;
alter table poi.nmp add column if not exists actividad          text;

-- Anexo 02: todas las tareas de cada actividad reprogramada (antes / después, año 1)
create table if not exists poi.nmp_fisica (
  id          bigserial primary key,
  numero      text not null,
  periodo     int,
  id_ao       text,
  id_tarea    text,
  codigo      text,
  nombre      text,
  repr        boolean,
  acum        boolean,
  um          text,
  tipo_medida text,
  antes       numeric[],
  despues     numeric[]
);
create index if not exists nmp_fisica_num on poi.nmp_fisica (numero);

-- Anexo 03: recursos modificados (id_rec vacío = recurso nuevo, se crea al aprobar)
create table if not exists poi.nmp_recurso (
  id           bigserial primary key,
  numero       text not null,
  periodo      int,
  id_ao        text,
  id_rec       text,
  codigo_tarea text,
  tarea_nombre text,
  recurso      text,
  um           text,
  ff           text,
  rubro        int,
  clasificador text,
  llave        text,
  cant_antes   text,
  cant_despues text,
  antes        numeric[],
  despues      numeric[]
);
create index if not exists nmp_recurso_num on poi.nmp_recurso (numero);

alter table poi.nmp_fisica  enable row level security;
alter table poi.nmp_recurso enable row level security;

-- 12 meses no negativos
create or replace function poi.m12(j jsonb, etq text) returns numeric[]
language plpgsql immutable as $$
declare a numeric[] := '{}'; v numeric; x jsonb;
begin
  if j is null or jsonb_typeof(j) <> 'array' or jsonb_array_length(j) <> 12 then perform poi.falla(etq || ': se esperan los 12 meses.'); end if;
  for x in select value from jsonb_array_elements(j) loop
    v := poi.n(x);
    if v is null or v < 0 then perform poi.falla(etq || ': hay un valor no válido.'); end if;
    a := a || round(v, 2);
  end loop;
  return a;
end $$;

-- ---------- Envío de la NMP (año 1 del periodo activo) ----------
create or replace function poi.enviar_nmp(s jsonb, cc text, b jsonb) returns jsonb
language plpgsql as $$
declare
  per int := poi.per_activo();
  sust_c text := poi.t(b ->> 'sustento_credito', 4000);
  sust_a text := poi.t(b ->> 'sustento_anulacion', 4000);
  errores text[] := '{}'; usados text[] := '{}';
  e jsonb; i int; m numeric[]; x record; pr poi.partida; r record; disp numeric; d int; maxd int;
  v_cant text; v_id text;
  v_num text; v_max int; v_total numeric; ahora timestamp := now() at time zone 'America/Lima';
begin
  if (select estado from poi.periodo where anio_ini = per) <> 'ACTIVO' then perform poi.falla('El periodo está cerrado.'); end if;
  if length(sust_c) < 20 then perform poi.falla('Escribe la justificación y sustento técnico del crédito (mínimo 20 caracteres).'); end if;
  if length(sust_a) < 20 then perform poi.falla('Escribe la justificación y sustento técnico de la anulación (mínimo 20 caracteres).'); end if;

  -- ===== Anexo 03: recursos =====
  create temp table if not exists _nr (orden int, id_rec text, id_ao text, codigo_tarea text, tarea_nombre text, recurso text, um text,
                        ff text, rubro int, clasificador text, llave text, cant_antes text, cant_despues text,
                        antes numeric[], despues numeric[]) on commit drop;
  for e, i in select value, ordinality from jsonb_array_elements(case when jsonb_typeof(b -> 'recursos') = 'array' then b -> 'recursos' else '[]' end) with ordinality loop
    v_id := poi.t(e ->> 'id_rec');
    select q.*, t.nombre tarea_nombre into x
      from poi.pm3_recurso q
      join poi.ao a on a.id_ao = q.id_ao
      left join poi.pm2_tarea t on t.id_ao = q.id_ao and t.codigo = q.codigo_tarea and t.estado <> 'ELIMINADA'
     where q.id_rec = v_id and a.centro_costo = cc and a.periodo = per and q.estado = 'ACTIVA' limit 1;
    if not found then errores := errores || ('Recurso ' || v_id || ': no pertenece a tu centro de costo o no está activo.'); continue; end if;
    if v_id = any (usados) then errores := errores || ('El recurso "' || x.recurso || '" está repetido.'); continue; end if;
    usados := usados || v_id;
    m := poi.m12(e -> 'm', 'Recurso "' || x.recurso || '"');
    v_cant := case when e ? 'cant' then poi.t(e ->> 'cant', 20) else coalesce(x.cant_a1, '') end;
    if m = coalesce(x.m_a1, poi.ceros()) and v_cant = coalesce(x.cant_a1, '') then continue; end if;
    select * into pr from poi.partida where llave = x.llave;
    insert into _nr values (i, x.id_rec, x.id_ao, x.codigo_tarea, coalesce(x.tarea_nombre, ''), x.recurso, coalesce(x.um, ''),
                            coalesce(pr.ff, x.ff), coalesce(pr.rubro, nullif(x.rubro, '')::int), coalesce(pr.clasificador, x.clasificador), x.llave,
                            coalesce(x.cant_a1, ''), v_cant, coalesce(x.m_a1, poi.ceros()), m);
  end loop;
  for e, i in select value, ordinality from jsonb_array_elements(case when jsonb_typeof(b -> 'nuevos') = 'array' then b -> 'nuevos' else '[]' end) with ordinality loop
    select p.* into pr from poi.partida p join poi.ao a on a.id_ao = p.id_ao
     where p.llave = poi.t(e ->> 'llave') and p.id_ao = poi.t(e ->> 'id_ao') and a.centro_costo = cc and a.periodo = per;
    if not found then errores := errores || ('Recurso nuevo ' || i || ': elige una partida de la actividad.'); continue; end if;
    if poi.t(e ->> 'nombre', 300) = '' then errores := errores || ('Recurso nuevo ' || i || ' (' || pr.clasificador || '): escribe la descripción.'); continue; end if;
    select t.nombre into v_id from poi.pm2_tarea t where t.id_ao = pr.id_ao and t.codigo = poi.t(e ->> 'tarea') and t.estado <> 'ELIMINADA' limit 1;
    if not found then errores := errores || ('Recurso nuevo "' || poi.t(e ->> 'nombre', 300) || '": elige una tarea de la actividad.'); continue; end if;
    m := poi.m12(e -> 'm', 'Recurso nuevo "' || poi.t(e ->> 'nombre', 300) || '"');
    if poi.suma(m) = 0 then errores := errores || ('Recurso nuevo "' || poi.t(e ->> 'nombre', 300) || '": programa al menos un mes.'); continue; end if;
    insert into _nr values (1000 + i, null, pr.id_ao, poi.t(e ->> 'tarea'), v_id, poi.t(e ->> 'nombre', 300), poi.t(e ->> 'um', 60),
                            pr.ff, pr.rubro, pr.clasificador, pr.llave, '', poi.t(e ->> 'cant', 20), poi.ceros(), m);
  end loop;

  -- ===== Anexo 01: crédito o anulación por partida = cambio neto de sus recursos =====
  create temp table if not exists _np (llave text, net numeric) on commit drop;
  insert into _np select llave, round(sum(poi.suma(despues) - poi.suma(antes)), 2) from _nr group by llave;
  for r in select n.llave, n.net, p.clasificador, p.ff, sd.saldo,
                  coalesce((select sum(q.anulacion) from poi.nmp q where q.llave = n.llave and q.estado like 'EN REVISI%'), 0) pend
             from _np n join poi.partida p on p.llave = n.llave join poi.saldo_m sd on sd.llave = n.llave
            where n.net <> 0 order by p.orden, n.llave loop
    if r.net <> trunc(r.net) then
      errores := errores || (r.clasificador || ' (FF' || split_part(r.ff, '-', 1) || '): la variación de S/ ' || poi.fmt(r.net) || ' debe ser un monto entero.');
    end if;
    if r.net < 0 and -r.net > coalesce(r.saldo, 0) - r.pend then
      errores := errores || (r.clasificador || ' (FF' || split_part(r.ff, '-', 1) || '): la anulación S/ ' || poi.fmt(-r.net) || ' supera el saldo por certificar disponible S/ ' || poi.fmt(coalesce(r.saldo, 0) - r.pend) || '.');
    end if;
  end loop;
  if not exists (select 1 from _np where net > 0) or not exists (select 1 from _np where net < 0) then
    errores := errores || 'La NMP necesita al menos una partida con crédito y una con anulación: modifica los recursos del Anexo 03.'::text;
  end if;
  for r in select p.rubro, min(p.ff) ff, sum(greatest(n.net, 0)) c, sum(greatest(-n.net, 0)) a
             from _np n join poi.partida p on p.llave = n.llave group by p.rubro order by p.rubro loop
    if r.c <> r.a then
      errores := errores || ('Fuente ' || r.ff || ': créditos S/ ' || poi.fmt(r.c) || ' y anulaciones S/ ' || poi.fmt(r.a) || ' deben ser iguales (PIM inicial = PIM final).');
    end if;
  end loop;

  -- ===== Anexo 02: reprogramación física =====
  create temp table if not exists _nf (id_tarea text, id_ao text, codigo text, nombre text, repr boolean, acum boolean, um text, tipo text,
                        propio boolean, padre text, prof int, antes numeric[], despues numeric[]) on commit drop;
  for e in select value from jsonb_array_elements(case when jsonb_typeof(b -> 'fisica') = 'array' then b -> 'fisica' else '[]' end) loop
    select t.id_ao into v_id from poi.pm2_tarea t join poi.ao a on a.id_ao = t.id_ao
     where t.id_tarea = poi.t(e ->> 'id_tarea') and a.centro_costo = cc and a.periodo = per and t.estado <> 'ELIMINADA';
    if not found then errores := errores || ('Tarea ' || poi.t(e ->> 'id_tarea') || ': no pertenece a tu centro de costo.'); continue; end if;
    if not exists (select 1 from _nf where id_ao = v_id) then
      insert into _nf select t.id_tarea, t.id_ao, t.codigo, t.nombre, t.repr, t.acum, coalesce(t.um, ''), '', t.propio, poi.padre(t.codigo),
                             coalesce(array_length(string_to_array(t.codigo, '.'), 1), 0), coalesce(t.m_a1, poi.ceros()), coalesce(t.m_a1, poi.ceros())
                        from poi.pm2_tarea t where t.id_ao = v_id and t.estado <> 'ELIMINADA';
    end if;
    update _nf set despues = poi.m12(e -> 'm', 'Tarea ' || codigo), tipo = poi.t(e ->> 'tipo', 40) where id_tarea = poi.t(e ->> 'id_tarea');
  end loop;
  select max(prof) into maxd from _nf;
  for d in reverse (coalesce(maxd, 1) - 1)..1 loop
    update _nf p set despues = (select array_agg(round(sm, 2) order by k) from (select k, sum(c.despues[k]) sm from _nf c cross join generate_series(1, 12) k
                                where c.id_ao = p.id_ao and c.padre = p.codigo group by k) z)
     where not p.propio and p.prof = d and exists (select 1 from _nf c where c.id_ao = p.id_ao and c.padre = p.codigo);
  end loop;
  delete from _nf where id_ao in (select id_ao from _nf group by id_ao having bool_and(antes = despues) and max(tipo) = '');

  if array_length(errores, 1) > 0 then perform poi.falla('La NMP tiene observaciones.', to_jsonb(errores)::text); end if;

  perform pg_advisory_xact_lock(2027001);
  select coalesce(max(substring(numero from '(\d+)$')::int), 0) into v_max from poi.nmp where numero like 'NMP-' || per || '-%';
  v_num := 'NMP-' || per || '-' || lpad((v_max + 1)::text, 4, '0');

  insert into poi.nmp (numero, fecha, centro_costo, id_ao, cu_efp, ff, rubro, clasificador, llave, credito, anulacion,
                       meta_antes, meta_despues, sustento, sustento_credito, sustento_anulacion, estado, observacion, solicitante, periodo,
                       pim, certificado, saldo, sec_func, categoria, producto, actividad)
  select v_num, ahora::date, cc, p.id_ao, p.cu_efp, p.ff, p.rubro, p.clasificador, p.llave, greatest(n.net, 0), greatest(-n.net, 0),
         coalesce(trim_scale(a.meta_a1)::text, ''),
         coalesce((select trim_scale(round(sum(poi.tot(f.despues, f.acum)), 2))::text from _nf f where f.id_ao = p.id_ao and f.repr and f.prof = 1),
                  coalesce(trim_scale(a.meta_a1)::text, '')),
         'CRÉDITO: ' || sust_c || ' | ANULACIÓN: ' || sust_a, sust_c, sust_a, 'EN REVISIÓN OPP',
         'Registrado desde el portal ' || to_char(ahora, 'DD/MM/YYYY HH24:MI') || '. Cuadra por fuente y respeta saldos.', s ->> 'u', per,
         sd.programado_vigente, sd.certificado, sd.saldo,
         coalesce(nullif(a.sec_func_2027, ''), lpad(coalesce(a.sec_func_2026, ''), 4, '0')), coalesce(a.programa, ''), coalesce(a.cod_producto, ''),
         split_part(coalesce(a.actividad_efp, ''), '.', 1)
    from _np n join poi.partida p on p.llave = n.llave join poi.ao a on a.id_ao = p.id_ao join poi.saldo_m sd on sd.llave = n.llave
   where n.net <> 0 order by p.rubro, p.orden, p.llave;

  insert into poi.nmp_recurso (numero, periodo, id_ao, id_rec, codigo_tarea, tarea_nombre, recurso, um, ff, rubro, clasificador, llave,
                               cant_antes, cant_despues, antes, despues)
  select v_num, per, id_ao, id_rec, codigo_tarea, tarea_nombre, recurso, um, ff, rubro, clasificador, llave, cant_antes, cant_despues, antes, despues
    from _nr order by orden;
  insert into poi.nmp_fisica (numero, periodo, id_ao, id_tarea, codigo, nombre, repr, acum, um, tipo_medida, antes, despues)
  select v_num, per, id_ao, id_tarea, codigo, nombre, repr, acum, um, tipo, antes, despues from _nf;

  select sum(greatest(net, 0)) into v_total from _np;
  insert into poi.bitacora (usuario, accion, detalle) values (s ->> 'u', 'enviarNMP', v_num || ' · ' || cc || ' · S/ ' || poi.fmt(v_total));
  return jsonb_build_object('ok', true, 'numero', v_num, 'total', v_total);
end $$;

-- ---------- Resolución: al aprobar se aplican los Anexos 02 y 03 a la PM2 / PM3 del año 1 ----------
create or replace function poi.resolver_nmp(s jsonb, b jsonb) returns jsonb
language plpgsql as $$
declare v_num text := poi.t(b ->> 'numero'); v_est text := upper(poi.t(b ->> 'estado')); v_obs text := poi.t(b ->> 'observacion', 2000);
        v_ver text; n int; per int; errores text[] := '{}'; r record; v_id text; v_max int;
begin
  if s ->> 'r' <> 'OPP' then perform poi.falla('Solo OPP puede resolver solicitudes.'); end if;
  if v_est not in ('APROBADO', 'OBSERVADO') then perform poi.falla('Estado no válido.'); end if;
  if v_est = 'OBSERVADO' and length(v_obs) < 5 then perform poi.falla('Escribe la observación para el área.'); end if;
  select min(periodo) into per from poi.nmp where numero = v_num and estado like 'EN REVISI%';
  if per is null then perform poi.falla('La solicitud ' || v_num || ' no está pendiente.'); end if;

  if v_est = 'APROBADO' then
    -- La programación debe seguir igual a la que el área tenía al enviar la NMP
    for r in select x.recurso, q.estado qe, q.m_a1 cur, x.antes from poi.nmp_recurso x left join poi.pm3_recurso q on q.id_rec = x.id_rec
              where x.numero = v_num and x.id_rec is not null loop
      if r.qe is distinct from 'ACTIVA' or coalesce(r.cur, poi.ceros()) <> r.antes then
        errores := errores || ('Recurso "' || r.recurso || '": su programación cambió después del envío.');
      end if;
    end loop;
    for r in select f.codigo, f.id_ao, t.estado te, t.m_a1 cur, f.antes from poi.nmp_fisica f left join poi.pm2_tarea t on t.id_tarea = f.id_tarea
              where f.numero = v_num loop
      if r.te is null or r.te = 'ELIMINADA' or coalesce(r.cur, poi.ceros()) <> r.antes then
        errores := errores || ('Tarea ' || r.codigo || ' de ' || r.id_ao || ': su programación física cambió después del envío.');
      end if;
    end loop;
    if array_length(errores, 1) > 0 then
      perform poi.falla('No se puede aprobar: la PM2/PM3 del área cambió después de enviar la NMP. Obsérvala para que la envíe de nuevo.', to_jsonb(errores)::text);
    end if;

    update poi.pm3_recurso q set m_a1 = x.despues, total_a1 = poi.suma(x.despues), cant_a1 = nullif(x.cant_despues, ''),
           origen = 'NMP', actualizado = now(), actualizado_por = s ->> 'u'
      from poi.nmp_recurso x where x.numero = v_num and x.id_rec = q.id_rec;
    for r in select x.* from poi.nmp_recurso x where x.numero = v_num and x.id_rec is null order by x.id loop
      select coalesce(max(substring(id_rec from '-R(\d+)$')::int), 0) into v_max from poi.pm3_recurso where id_ao = r.id_ao;
      v_id := r.id_ao || '-R' || lpad((v_max + 1)::text, 2, '0');
      insert into poi.pm3_recurso (id_rec, id_ao, centro_costo, codigo_tarea, recurso, um, ff, rubro, clasificador, llave, n_prevision,
                                   cant_a1, cant_a2, cant_a3, m_a1, m_a2, m_a3, total_a1, total_a2, total_a3, estado, origen, actualizado, actualizado_por, periodo)
      select v_id, r.id_ao, a.centro_costo, r.codigo_tarea, r.recurso, nullif(r.um, ''), r.ff, r.rubro::text, r.clasificador, r.llave, '',
             nullif(r.cant_despues, ''), null, null, r.despues, poi.ceros(), poi.ceros(), poi.suma(r.despues), 0, 0, 'ACTIVA', 'NMP', now(), s ->> 'u', r.periodo
        from poi.ao a where a.id_ao = r.id_ao;
      update poi.nmp_recurso set id_rec = v_id where id = r.id;
    end loop;

    update poi.pm2_tarea t set m_a1 = f.despues, total_a1 = poi.tot(f.despues, t.acum), origen = 'NMP', actualizado = now(), actualizado_por = s ->> 'u'
      from poi.nmp_fisica f where f.numero = v_num and f.id_tarea = t.id_tarea and f.antes <> f.despues;
    update poi.ao a set meta_a1 = (select round(coalesce(sum(poi.tot(t.m_a1, t.acum)), 0), 2) from poi.pm2_tarea t
                                    where t.id_ao = a.id_ao and t.estado <> 'ELIMINADA' and t.repr and t.codigo !~ '\.'),
           actualizado = now(), actualizado_por = s ->> 'u'
     where a.id_ao in (select distinct id_ao from poi.nmp_fisica where numero = v_num);

    select count(distinct numero) + 1 into n from poi.nmp where estado = 'APROBADO' and periodo = per;
    v_ver := 'POI ' || per || ' v' || n;
  end if;
  update poi.nmp set estado = v_est, version_poi = v_ver,
         observacion = case when v_obs <> '' then v_obs else observacion end,
         resuelto = now(), resuelto_por = s ->> 'u'
   where numero = v_num;
  insert into poi.bitacora (usuario, accion, detalle) values (s ->> 'u', 'resolverNMP', v_num || ' → ' || v_est);
  return jsonb_build_object('ok', true, 'numero', v_num, 'estado', v_est, 'version', v_ver);
end $$;

-- ---------- Datos para descargar los anexos de una NMP ----------
create or replace function poi.nmp_anexos(s jsonb, b jsonb) returns jsonb
language plpgsql stable as $$
declare v_num text := poi.t(b ->> 'numero'); v_cc text; per int;
begin
  select min(centro_costo), min(periodo) into v_cc, per from poi.nmp where numero = v_num;
  if v_cc is null then perform poi.falla('No existe la solicitud ' || v_num || '.'); end if;
  if s ->> 'r' <> 'OPP' and v_cc <> s ->> 'cc' then perform poi.falla('La solicitud ' || v_num || ' no es de tu centro de costo.'); end if;
  return jsonb_build_object('ok', true, 'numero', v_num, 'cc', v_cc, 'anio', per::text,
    'fecha', (select to_char(min(fecha), 'DD/MM/YYYY') from poi.nmp where numero = v_num),
    'estado', (select min(estado) from poi.nmp where numero = v_num),
    'sustento_credito', (select coalesce(min(sustento_credito), min(substring(sustento from 'CRÉDITO: (.*) \| ANULACIÓN')), '') from poi.nmp where numero = v_num),
    'sustento_anulacion', (select coalesce(min(sustento_anulacion), min(substring(sustento from '\| ANULACIÓN: (.*)$')), '') from poi.nmp where numero = v_num),
    'filas', (select coalesce(jsonb_agg(jsonb_build_object(
                'id_ao', n.id_ao, 'ff', n.ff, 'rubro', n.rubro, 'clasificador', n.clasificador,
                'sec_func', coalesce(n.sec_func, nullif(a.sec_func_2027, ''), lpad(coalesce(a.sec_func_2026, ''), 4, '0')),
                'categoria', coalesce(n.categoria, a.programa, ''), 'producto', coalesce(n.producto, a.cod_producto, ''),
                'actividad', coalesce(n.actividad, split_part(coalesce(a.actividad_efp, ''), '.', 1)),
                'finalidad', coalesce(a.finalidad, ''), 'um', coalesce(a.unidad_medida, ''),
                'meta_antes', coalesce(n.meta_antes, ''), 'meta_despues', coalesce(n.meta_despues, ''),
                'pim', n.pim, 'certificado', n.certificado, 'saldo', n.saldo, 'credito', n.credito, 'anulacion', n.anulacion) order by n.id), '[]')
              from poi.nmp n left join poi.ao a on a.id_ao = n.id_ao where n.numero = v_num),
    'aos', (select coalesce(jsonb_agg(jsonb_build_object('id_ao', a.id_ao, 'nombre', coalesce(nullif(a.nombre_ao, ''), a.finalidad, ''),
                                                         'um', coalesce(a.unidad_medida, '')) order by a.orden, a.id_ao), '[]')
              from poi.ao a where a.id_ao in (select id_ao from poi.nmp where numero = v_num
                                              union select id_ao from poi.nmp_fisica where numero = v_num
                                              union select id_ao from poi.nmp_recurso where numero = v_num)),
    'fisica', (select coalesce(jsonb_agg(jsonb_build_object('id_ao', id_ao, 'id', id_tarea, 'codigo', codigo, 'nombre', nombre, 'repr', repr, 'acum', acum,
                                                            'um', um, 'tipo', coalesce(tipo_medida, ''), 'antes', antes, 'despues', despues) order by id), '[]')
                 from poi.nmp_fisica where numero = v_num),
    'recursos', (select coalesce(jsonb_agg(jsonb_build_object('id_ao', id_ao, 'tarea', codigo_tarea, 'tarea_nombre', tarea_nombre, 'nombre', recurso,
                                                              'um', um, 'ff', ff, 'clasificador', clasificador, 'cant_antes', coalesce(cant_antes, ''),
                                                              'cant_despues', coalesce(cant_despues, ''), 'antes', antes, 'despues', despues) order by id), '[]')
                   from poi.nmp_recurso where numero = v_num));
end $$;

-- ---------- Parches sobre funciones vigentes (se reemplaza solo el fragmento indicado) ----------
do $do$
declare d text; viejo text; nuevo text;
begin
  -- 1) PM3 del año 1: el techo es APM + NMP aprobadas (PIM vigente)
  d := pg_get_functiondef('poi.guardar_ao(jsonb,text,jsonb)'::regprocedure);
  viejo := $q$apm := round(coalesce(case k when 1 then r.apm_a1 when 2 then r.apm_a2 else r.apm_a3 end, 0), 2);$q$;
  nuevo := $q$apm := round(coalesce(case k when 1 then r.apm_a1 + coalesce((select sum(q.credito - q.anulacion) from poi.nmp q where q.llave = r.llave and q.estado = 'APROBADO'), 0) when 2 then r.apm_a2 else r.apm_a3 end, 0), 2);$q$;
  if position(nuevo in d) = 0 then
    if position(viejo in d) = 0 then raise exception 'guardar_ao: no se encontró el cálculo del techo APM'; end if;
    execute replace(d, viejo, nuevo);
  end if;

  -- 2) Datos de la actividad para el Anexo 01 (categoría presupuestal y producto)
  d := pg_get_functiondef('poi.datos_ext(jsonb,text,integer)'::regprocedure);
  viejo := $q$'cui', coalesce(poi.cui(a.tipo, a.cod_producto), ''),$q$;
  nuevo := $q$'cui', coalesce(poi.cui(a.tipo, a.cod_producto), ''), 'programa', coalesce(a.programa, ''), 'cod_producto', coalesce(a.cod_producto, ''),$q$;
  if position(nuevo in d) = 0 then
    if position(viejo in d) = 0 then raise exception 'datos_ext: no se encontró el campo cui'; end if;
    execute replace(d, viejo, nuevo);
  end if;

  -- 3) Acción nmpAnexos en la API
  d := pg_get_functiondef('public.poi_api(jsonb)'::regprocedure);
  viejo := $q$when 'resolverNMP'      then return poi.resolver_nmp(s, p);$q$;
  nuevo := $q$when 'resolverNMP'      then return poi.resolver_nmp(s, p);
    when 'nmpAnexos'        then return poi.nmp_anexos(s, p);$q$;
  if position('nmpAnexos' in d) = 0 then
    if position(viejo in d) = 0 then raise exception 'poi_api: no se encontró resolverNMP'; end if;
    execute replace(d, viejo, nuevo);
  end if;
end $do$;
