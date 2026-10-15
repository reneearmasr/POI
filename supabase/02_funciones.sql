-- =====================================================================
-- POI 2027 – ATU · 02 · Funciones (reglas de negocio)
-- Pegar completo en Supabase → SQL Editor → Run (después del 01).
-- Se puede volver a ejecutar sin perder datos.
-- =====================================================================

-- ---------- Utilidades ----------
create or replace function poi.cfg(k text) returns text
language sql stable as $$ select valor from poi.config where clave = k $$;

create or replace function poi.falla(msg text, det text default null) returns void
language plpgsql as $$
begin
  if det is null then raise exception using errcode = 'PT400', message = msg;
  else raise exception using errcode = 'PT400', message = msg, detail = det; end if;
end $$;

-- Número desde JSON: vacío/nulo → 0; texto no numérico → null
create or replace function poi.n(v jsonb) returns numeric
language plpgsql immutable as $$
declare t text;
begin
  if v is null or jsonb_typeof(v) = 'null' then return 0; end if;
  if jsonb_typeof(v) = 'number' then return (v #>> '{}')::numeric; end if;
  if jsonb_typeof(v) <> 'string' then return null; end if;
  t := replace(trim(v #>> '{}'), ',', '');
  if t = '' then return 0; end if;
  if t ~ '^-?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$' then return t::numeric; end if;
  return null;
end $$;

-- Verdadero/falso al estilo JavaScript (!!x)
create or replace function poi.b(v jsonb) returns boolean
language sql immutable as $$
  select case jsonb_typeof(v)
    when 'boolean' then (v #>> '{}')::boolean
    when 'number'  then (v #>> '{}')::numeric <> 0
    when 'string'  then (v #>> '{}') <> ''
    when 'object'  then true
    when 'array'   then true
    else false end
$$;

create or replace function poi.t(v text, largo int default 2000) returns text
language sql immutable as $$ select left(trim(coalesce(v, '')), largo) $$;

-- Formato numérico peruano: 1,234,567.5
create or replace function poi.fmt(x numeric) returns text
language sql immutable as $$ select rtrim(to_char(round(coalesce(x, 0), 2), 'FM999,999,999,999,990.99'), '.') $$;

create or replace function poi.arr(j jsonb) returns numeric[]
language sql immutable as $$
  select coalesce(array_agg(x::numeric order by o), array_fill(0::numeric, array[12]))
  from jsonb_array_elements_text(j) with ordinality as e(x, o)
$$;

create or replace function poi.ceros() returns numeric[]
language sql immutable as $$ select array_fill(0::numeric, array[12]) $$;

-- Total anual: acumulativo = suma; no acumulativo = máximo mensual
create or replace function poi.tot(m numeric[], acum boolean) returns numeric
language sql immutable as $$
  select case when acum then round(coalesce((select sum(x) from unnest(m) x), 0), 2)
              else greatest(0, coalesce((select max(x) from unnest(m) x), 0)) end
$$;

create or replace function poi.suma(m numeric[]) returns numeric
language sql immutable as $$ select round(coalesce((select sum(x) from unnest(m) x), 0), 2) $$;

create or replace function poi.padre(c text) returns text
language sql immutable as $$
  select coalesce(array_to_string((string_to_array(c, '.'))[1:greatest(array_length(string_to_array(c, '.'), 1) - 1, 0)], '.'), '')
$$;

-- Lee {"2027":[12],"2028":[12],"2029":[12]} validando montos
create or replace function poi.anios(y jsonb, etiqueta text) returns jsonb
language plpgsql immutable as $$
declare o jsonb := '{}'; a text; arr jsonb; vals numeric[]; v numeric; i int;
begin
  foreach a in array array['2027', '2028', '2029'] loop
    arr := case when y is not null and jsonb_typeof(y) = 'object' then y -> a else null end;
    if arr is null or jsonb_typeof(arr) <> 'array' then
      vals := poi.ceros();
    else
      if jsonb_array_length(arr) <> 12 then perform poi.falla(etiqueta || ': cada año debe traer 12 meses.'); end if;
      vals := '{}';
      for i in 0..11 loop
        v := poi.n(arr -> i);
        if v is null or v < 0 then perform poi.falla(etiqueta || ': los valores deben ser números positivos.'); end if;
        vals := vals || round(v, 2);
      end loop;
    end if;
    o := o || jsonb_build_object(a, to_jsonb(vals));
  end loop;
  return o;
end $$;

-- ---------- Sesión ----------
create or replace function poi.hash(u text, clave text) returns text
language sql stable as $$
  select encode(extensions.digest(u || ':' || clave || ':' || poi.cfg('salt'), 'sha256'), 'hex')
$$;

create or replace function poi.token(u poi.usuario) returns text
language plpgsql stable as $$
declare payload text;
begin
  payload := replace(encode(convert_to(jsonb_build_object(
      'u', u.usuario, 'cc', u.centro_costo, 'r', u.rol, 'n', u.nombre,
      'exp', floor(extract(epoch from now()) * 1000 + poi.cfg('sesion_horas')::numeric * 3600000))::text, 'UTF8'), 'base64'), E'\n', '');
  return payload || '~' || encode(extensions.hmac(payload, poi.cfg('secret'), 'sha256'), 'hex');
end $$;

create or replace function poi.sesion(tok text) returns jsonb
language plpgsql stable as $$
declare p1 text := split_part(coalesce(tok, ''), '~', 1); f text := split_part(coalesce(tok, ''), '~', 2); s jsonb;
begin
  if p1 = '' or f = '' or encode(extensions.hmac(p1, poi.cfg('secret'), 'sha256'), 'hex') <> f then
    raise exception using errcode = 'PT401', message = 'Sesión vencida. Vuelve a ingresar.';
  end if;
  s := convert_from(decode(p1, 'base64'), 'UTF8')::jsonb;
  if (s ->> 'exp')::numeric < extract(epoch from now()) * 1000 then
    raise exception using errcode = 'PT401', message = 'Sesión vencida. Vuelve a ingresar.';
  end if;
  if not exists (select 1 from poi.usuario where usuario = s ->> 'u' and activo) then
    raise exception using errcode = 'PT401', message = 'Usuario desactivado.';
  end if;
  return s;
end $$;

create or replace function poi.login(p jsonb) returns jsonb
language plpgsql as $$
declare u poi.usuario; nombre_u text := lower(trim(coalesce(p ->> 'usuario', ''))); fallos int;
begin
  select count(*) into fallos from poi.bitacora
   where accion = 'login_fallido' and usuario = nombre_u and fecha > now() - interval '15 minutes';
  if fallos >= 8 then
    return jsonb_build_object('ok', false, 'error', 'Demasiados intentos fallidos. Espera 15 minutos o pide a OPP que restablezca tu contraseña.');
  end if;
  select * into u from poi.usuario where lower(usuario) = nombre_u;
  if not found or not u.activo or u.hash <> poi.hash(u.usuario, coalesce(p ->> 'clave', '')) then
    insert into poi.bitacora (usuario, accion, detalle) values (nombre_u, 'login_fallido', null);
    return jsonb_build_object('ok', false, 'error', 'Usuario o contraseña incorrectos.');
  end if;
  insert into poi.bitacora (usuario, accion) values (u.usuario, 'login');
  return jsonb_build_object('ok', true, 'token', poi.token(u), 'usuario', u.usuario, 'nombre', u.nombre,
                            'centro_costo', u.centro_costo, 'rol', u.rol);
end $$;

-- ---------- Datos del área ----------
create or replace function poi.datos(s jsonb, cc text) returns jsonb
language plpgsql stable as $$
declare
  centros jsonb; ses jsonb; aos jsonb; partidas jsonb; tareas jsonb; recursos jsonb; nmp jsonb; bandeja jsonb := '[]';
begin
  ses := jsonb_build_object('usuario', s ->> 'u', 'nombre', s ->> 'n', 'rol', s ->> 'r', 'cc', cc);
  if s ->> 'r' = 'OPP' then
    select coalesce(jsonb_agg(c order by c), '[]') into centros from (select distinct centro_costo c from poi.ao) x;
    select coalesce(jsonb_agg(jsonb_build_object('numero', numero, 'cc', cc_, 'fecha', to_char(fecha, 'DD/MM/YYYY'),
             'credito', cred, 'anulacion', anul, 'estado', est, 'solicitante', sol) order by numero), '[]')
      into bandeja
      from (select numero, min(centro_costo) cc_, min(fecha) fecha, sum(credito) cred, sum(anulacion) anul,
                   min(estado) est, min(solicitante) sol
              from poi.nmp group by numero having min(estado) like 'EN REVISI%') b;
  else
    centros := jsonb_build_array(cc);
  end if;
  if coalesce(cc, '') = '' then
    return jsonb_build_object('ok', true, 'sesion', ses, 'centros', centros, 'aos', '[]'::jsonb, 'partidas', '[]'::jsonb,
                              'tareas', '[]'::jsonb, 'recursos', '[]'::jsonb, 'nmp', '[]'::jsonb, 'bandeja', bandeja);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id_ao', a.id_ao, 'cu_efp', a.cu_efp, 'uo', coalesce(a.unidad_organica, ''), 'oei', coalesce(a.oei, ''), 'aei', coalesce(a.aei, ''),
      'tipo', coalesce(a.tipo, ''), 'producto', coalesce(a.producto, ''), 'actividad_efp', coalesce(a.actividad_efp, ''),
      'finalidad', coalesce(a.finalidad, ''), 'nombre_ao', coalesce(a.nombre_ao, ''), 'descripcion', coalesce(a.descripcion, ''),
      'beneficiarios', coalesce(a.beneficiarios, ''), 'indicador', coalesce(a.indicador, ''), 'medio', coalesce(a.medio_verificacion, ''),
      'unidad_medida', coalesce(a.unidad_medida, ''),
      'meta_2027', a.meta_2027, 'meta_2028', a.meta_2028, 'meta_2029', a.meta_2029,
      'apm_2027', coalesce(t.a27, 0), 'apm_2028', coalesce(t.a28, 0), 'apm_2029', coalesce(t.a29, 0),
      'sec_func', coalesce(nullif(a.sec_func_2027, ''), lpad(coalesce(a.sec_func_2026, ''), 4, '0'))
    ) order by a.orden, a.id_ao), '[]') into aos
  from poi.ao a
  left join (select id_ao, sum(apm_2027) a27, sum(apm_2028) a28, sum(apm_2029) a29 from poi.partida group by id_ao) t on t.id_ao = a.id_ao
  where a.centro_costo = cc;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id_ao', p.id_ao, 'ff', coalesce(p.ff, ''), 'rubro', p.rubro, 'clasificador', coalesce(p.clasificador, ''),
      'clasificador_desc', coalesce(p.clasificador_desc, ''), 'concepto', coalesce(nullif(p.concepto2, ''), p.concepto1, ''),
      'reserva', coalesce(p.reserva, ''), 'apm_2027', p.apm_2027, 'apm_2028', p.apm_2028, 'apm_2029', p.apm_2029,
      'meses', to_jsonb(p.meses), 'llave', p.llave,
      'programado_vigente', s2.programado_vigente, 'credito', s2.credito, 'anulacion', s2.anulacion,
      'certificado', s2.certificado, 'saldo', s2.saldo, 'anulacion_en_revision', coalesce(r.pend, 0)
    ) order by p.orden, p.llave), '[]') into partidas
  from poi.partida p
  join poi.ao a on a.id_ao = p.id_ao and a.centro_costo = cc
  join poi.saldo s2 on s2.llave = p.llave
  left join (select llave, sum(anulacion) pend from poi.nmp where estado like 'EN REVISI%' group by llave) r on r.llave = p.llave;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', t.id_tarea, 'id_ao', t.id_ao, 'codigo', coalesce(t.codigo, ''), 'nombre', coalesce(t.nombre, ''),
      'repr', t.repr, 'acum', t.acum, 'um', coalesce(t.um, ''),
      'y', jsonb_build_object('2027', to_jsonb(t.m2027), '2028', to_jsonb(t.m2028), '2029', to_jsonb(t.m2029))
    ) order by t.id_tarea), '[]') into tareas
  from poi.pm2_tarea t join poi.ao a on a.id_ao = t.id_ao and a.centro_costo = cc
  where upper(t.estado) <> 'ELIMINADA';

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', r.id_rec, 'demanda', upper(r.estado) = 'DEMANDA ADICIONAL', 'ff', coalesce(r.ff, ''), 'clasificador', coalesce(r.clasificador, ''),
      'id_ao', r.id_ao, 'tarea', coalesce(r.codigo_tarea, ''), 'nombre', coalesce(r.recurso, ''), 'um', coalesce(r.um, ''),
      'llave', coalesce(r.llave, ''), 'prev', coalesce(r.n_prevision, ''),
      'cant', jsonb_build_object('2027', coalesce(r.cant_2027, ''), '2028', coalesce(r.cant_2028, ''), '2029', coalesce(r.cant_2029, '')),
      'y', jsonb_build_object('2027', to_jsonb(r.m2027), '2028', to_jsonb(r.m2028), '2029', to_jsonb(r.m2029))
    ) order by r.id_rec), '[]') into recursos
  from poi.pm3_recurso r join poi.ao a on a.id_ao = r.id_ao and a.centro_costo = cc
  where upper(r.estado) <> 'ELIMINADA';

  select coalesce(jsonb_agg(g order by g ->> 'numero' desc), '[]') into nmp
  from (
    select jsonb_build_object('numero', numero, 'fecha', to_char(min(fecha), 'DD/MM/YYYY'), 'estado', min(estado),
             'observacion', coalesce(min(observacion), ''), 'sustento', coalesce(min(sustento), ''), 'version', coalesce(min(version_poi), ''),
             'credito', sum(credito), 'anulacion', sum(anulacion),
             'filas', jsonb_agg(jsonb_build_object('id_ao', id_ao, 'rubro', rubro, 'clasificador', clasificador, 'credito', credito,
                                                   'anulacion', anulacion, 'meta_antes', coalesce(meta_antes, ''), 'meta_despues', coalesce(meta_despues, '')) order by id)) g
    from poi.nmp where centro_costo = cc group by numero
  ) x;

  return jsonb_build_object('ok', true, 'sesion', ses, 'centros', centros, 'aos', aos, 'partidas', partidas,
                            'tareas', tareas, 'recursos', recursos, 'nmp', nmp, 'bandeja', bandeja);
end $$;

-- ---------- Guardar PM1 (ficha) + PM2 (tareas) + PM3 (recursos) de una AO ----------
create or replace function poi.guardar_ao(s jsonb, cc text, b jsonb) returns jsonb
language plpgsql as $$
declare
  v_id     text := poi.t(b ->> 'id_ao');
  a        poi.ao;
  p1       jsonb := coalesce(b -> 'pa1', '{}');
  v_origen text := case when b ->> 'origen' = 'Importado' and s ->> 'r' = 'OPP' then 'Importado' else 'Portal' end;
  v_user   text := s ->> 'u';
  e jsonb; v_tid text; v_rid text; max_t int; max_r int; v_elim boolean; v_dem boolean;
  v_cod text; v_nom text; an jsonb; avisos text[] := '{}'; excesos text[] := '{}';
  yy text; meta numeric; tot numeric; d int; maxd int; x text; y2 text;
  pr poi.partida; hay_p boolean; ex poi.pm3_recurso; hay_ex boolean;
  r record; apm numeric; prog numeric; ndem int; mdem numeric;
begin
  select * into a from poi.ao where id_ao = v_id;
  if not found then perform poi.falla('La actividad operativa ' || v_id || ' no existe.'); end if;
  if a.centro_costo <> cc then perform poi.falla('La actividad ' || v_id || ' no pertenece a tu centro de costo.'); end if;
  if poi.t(p1 ->> 'nombre_ao') = '' then perform poi.falla('El nombre de la actividad operativa no puede quedar vacío.'); end if;

  -- ===== PM2 =====
  drop table if exists _t;
  create temp table _t (id text, codigo text, nombre text, repr boolean, acum boolean, um text,
                        m2027 numeric[], m2028 numeric[], m2029 numeric[], elim boolean, padre text, prof int) on commit drop;
  select coalesce(max(substring(id_tarea from '-T(\d+)$')::int), 0) into max_t from poi.pm2_tarea where id_ao = v_id;
  for e in select value from jsonb_array_elements(case when jsonb_typeof(b -> 'pm2') = 'array' then b -> 'pm2' else '[]' end) loop
    v_tid := poi.t(e ->> 'id');
    if v_tid <> '' and not exists (select 1 from poi.pm2_tarea where id_tarea = v_tid and id_ao = v_id) then
      perform poi.falla('Una de las tareas no pertenece a ' || v_id || '.');
    end if;
    v_elim := poi.b(e -> 'eliminar');
    if v_tid = '' and v_elim then continue; end if;
    if v_tid = '' then max_t := max_t + 1; v_tid := v_id || '-T' || lpad(max_t::text, 2, '0'); end if;
    v_cod := poi.t(e ->> 'codigo');
    v_nom := poi.t(e ->> 'nombre', 500);
    an := poi.anios(e -> 'y', 'Tarea ' || coalesce(nullif(v_cod, ''), v_nom));
    if not v_elim then
      if v_cod !~ '^\d+(\.\d+)*$' then perform poi.falla('El código de la tarea "' || v_nom || '" debe ser tipo 1, 1.1, 1.1.1.'); end if;
      if v_nom = '' then perform poi.falla('Hay una tarea sin nombre (código ' || v_cod || ').'); end if;
      if poi.t(e ->> 'um') = '' then perform poi.falla('La tarea ' || v_cod || ' necesita unidad de medida.'); end if;
    end if;
    insert into _t values (v_tid, v_cod, v_nom, poi.b(e -> 'repr'), poi.b(e -> 'acum'), poi.t(e ->> 'um'),
                           poi.arr(an -> '2027'), poi.arr(an -> '2028'), poi.arr(an -> '2029'), v_elim,
                           poi.padre(v_cod), coalesce(array_length(string_to_array(v_cod, '.'), 1), 0));
  end loop;
  if not exists (select 1 from _t where not elim) then perform poi.falla('La actividad debe tener al menos una tarea (PM2).'); end if;
  select codigo into x from _t where not elim group by codigo having count(*) > 1 limit 1;
  if x is not null then perform poi.falla('El código de tarea ' || x || ' está repetido.'); end if;
  select t.codigo, t.padre into x, y2 from _t t
   where not t.elim and t.padre <> '' and not exists (select 1 from _t q where not q.elim and q.codigo = t.padre) limit 1;
  if x is not null then perform poi.falla('La tarea ' || x || ' no tiene tarea padre ' || y2 || '.'); end if;
  -- Los padres suman a sus hijos, de abajo hacia arriba
  select max(prof) into maxd from _t where not elim;
  for d in reverse (maxd - 1)..1 loop
    update _t p set
      m2027 = (select array_agg(round(sm, 2) order by i) from (select i, sum(c.m2027[i]) sm from _t c cross join generate_series(1, 12) i where not c.elim and c.padre = p.codigo group by i) z),
      m2028 = (select array_agg(round(sm, 2) order by i) from (select i, sum(c.m2028[i]) sm from _t c cross join generate_series(1, 12) i where not c.elim and c.padre = p.codigo group by i) z),
      m2029 = (select array_agg(round(sm, 2) order by i) from (select i, sum(c.m2029[i]) sm from _t c cross join generate_series(1, 12) i where not c.elim and c.padre = p.codigo group by i) z)
    where not p.elim and p.prof = d and exists (select 1 from _t c where not c.elim and c.padre = p.codigo);
  end loop;
  if not exists (select 1 from _t where not elim and repr and prof = 1) then
    perform poi.falla('Marca como representativa al menos una tarea de primer nivel (1, 2, …) en la PM2.');
  end if;
  foreach yy in array array['2027', '2028', '2029'] loop
    meta := case yy when '2027' then a.meta_2027 when '2028' then a.meta_2028 else a.meta_2029 end;
    select round(coalesce(sum(poi.tot(case yy when '2027' then m2027 when '2028' then m2028 else m2029 end, acum)), 0), 2)
      into tot from _t where not elim and repr and prof = 1;
    if round(coalesce(meta, 0), 2) <> tot then
      avisos := avisos || ('PM2 ' || yy || ': las tareas representativas suman ' || poi.fmt(tot) || ' y la meta física APM es ' || poi.fmt(meta) || '.');
    end if;
  end loop;

  -- ===== PM3 =====
  drop table if exists _r;
  create temp table _r (id text, tarea text, nombre text, um text, llave text, prev text, cant jsonb,
                        m2027 numeric[], m2028 numeric[], m2029 numeric[], elim boolean, dem boolean,
                        ff text, rubro text, clasificador text) on commit drop;
  select coalesce(max(substring(id_rec from '-R(\d+)$')::int), 0) into max_r from poi.pm3_recurso where id_ao = v_id;
  for e in select value from jsonb_array_elements(case when jsonb_typeof(b -> 'pm3') = 'array' then b -> 'pm3' else '[]' end) loop
    v_rid := poi.t(e ->> 'id');
    if v_rid <> '' and not exists (select 1 from poi.pm3_recurso where id_rec = v_rid and id_ao = v_id) then
      perform poi.falla('Uno de los recursos no pertenece a ' || v_id || '.');
    end if;
    v_elim := poi.b(e -> 'eliminar');
    if v_rid = '' and v_elim then continue; end if;
    if v_rid = '' then max_r := max_r + 1; v_rid := v_id || '-R' || lpad(max_r::text, 2, '0'); end if;
    v_nom := poi.t(e ->> 'nombre', 300);
    an := poi.anios(e -> 'y', 'Recurso ' || v_nom);
    v_dem := poi.b(e -> 'demanda');
    select * into pr from poi.partida where id_ao = v_id and llave = poi.t(e ->> 'llave'); hay_p := found;
    select * into ex from poi.pm3_recurso where id_rec = v_rid; hay_ex := found;
    if v_dem then
      if not v_elim and v_nom = '' then perform poi.falla('Hay una demanda adicional sin descripción.'); end if;
      insert into _r values (v_rid, poi.t(e ->> 'tarea'), coalesce(nullif(v_nom, ''), ex.recurso, ''), poi.t(e ->> 'um', 60), poi.t(e ->> 'llave'),
        poi.t(e ->> 'prev', 60), e -> 'cant', poi.arr(an -> '2027'), poi.arr(an -> '2028'), poi.arr(an -> '2029'), v_elim, true,
        case when hay_p then pr.ff else poi.t(e ->> 'ff') end,
        case when hay_p then pr.rubro::text else '' end,
        coalesce(nullif(case when hay_p then pr.clasificador else poi.t(e ->> 'clasificador') end, ''), ex.clasificador, ''));
      continue;
    end if;
    if not v_elim then
      if v_nom = '' then perform poi.falla('Hay un recurso sin descripción.'); end if;
      if not hay_p then perform poi.falla('El recurso "' || v_nom || '" debe usar una partida (FF y clasificador) de la APM de esta actividad.'); end if;
      if not exists (select 1 from _t where not elim and codigo = poi.t(e ->> 'tarea')) then
        perform poi.falla('El recurso "' || v_nom || '" apunta a la tarea ' || poi.t(e ->> 'tarea') || ', que no existe.');
      end if;
    end if;
    insert into _r values (v_rid, poi.t(e ->> 'tarea'), coalesce(nullif(v_nom, ''), ex.recurso, ''), poi.t(e ->> 'um', 60), poi.t(e ->> 'llave'),
      poi.t(e ->> 'prev', 60), e -> 'cant', poi.arr(an -> '2027'), poi.arr(an -> '2028'), poi.arr(an -> '2029'), v_elim, false,
      coalesce(nullif(case when hay_p then pr.ff end, ''), ex.ff, ''),
      coalesce(nullif(case when hay_p then pr.rubro::text end, ''), ex.rubro, ''),
      coalesce(nullif(case when hay_p then pr.clasificador end, ''), ex.clasificador, ''));
    update _r set llave = coalesce(nullif(llave, ''), ex.llave, '') where id = v_rid;
  end loop;
  if not exists (select 1 from _r where not dem and not elim) then perform poi.falla('La actividad debe tener al menos un recurso (PM3).'); end if;

  -- Cuadre contra el techo APM de cada partida
  for r in select p.* from poi.partida p where p.id_ao = v_id order by p.orden, p.llave loop
    foreach yy in array array['2027', '2028', '2029'] loop
      apm := round(coalesce(case yy when '2027' then r.apm_2027 when '2028' then r.apm_2028 else r.apm_2029 end, 0), 2);
      select round(coalesce(sum(poi.suma(case yy when '2027' then m2027 when '2028' then m2028 else m2029 end)), 0), 2)
        into prog from _r where not elim and not dem and llave = r.llave;
      if prog > apm then
        excesos := excesos || (coalesce(r.clasificador, '') || ' (FF' || split_part(coalesce(r.ff, ''), '-', 1) || ') ' || yy || ': S/ ' || poi.fmt(prog) || ' supera la APM de S/ ' || poi.fmt(apm));
      elsif apm <> prog then
        avisos := avisos || ('PM3 ' || yy || ' ' || coalesce(r.clasificador, '') || ' (' || split_part(coalesce(r.ff, ''), '-', 1) || '): programado S/ ' || poi.fmt(prog) || ' de S/ ' || poi.fmt(apm) || '.');
      end if;
    end loop;
  end loop;
  if array_length(excesos, 1) > 0 then
    perform poi.falla('La programación debe ajustarse a la APM. ' || array_to_string(excesos[1:4], '; ')
      || case when array_length(excesos, 1) > 4 then '; y ' || (array_length(excesos, 1) - 4) || ' más' else '' end
      || '. Registra lo que falta como demanda adicional o solicita una NMP.');
  end if;
  select count(*), coalesce(sum(poi.suma(m2027)), 0) into ndem, mdem from _r where dem and not elim;
  if ndem > 0 then
    avisos := avisos || ('Demanda adicional registrada (fuera de la APM): ' || ndem || ' recurso(s), S/ ' || poi.fmt(mdem) || ' en 2027.');
  end if;

  -- ===== Escritura =====
  update poi.ao set nombre_ao = poi.t(p1 ->> 'nombre_ao'), descripcion = poi.t(p1 ->> 'descripcion'),
         beneficiarios = poi.t(p1 ->> 'beneficiarios'), indicador = poi.t(p1 ->> 'indicador'),
         medio_verificacion = poi.t(p1 ->> 'medio'), actualizado = now(), actualizado_por = v_user
   where id_ao = v_id;

  insert into poi.pm2_tarea as q (id_tarea, id_ao, centro_costo, codigo, nombre, repr, acum, um, m2027, m2028, m2029,
                                  total_2027, total_2028, total_2029, estado, origen, actualizado, actualizado_por)
  select id, v_id, cc, codigo, nombre, repr, acum, um, m2027, m2028, m2029,
         poi.tot(m2027, acum), poi.tot(m2028, acum), poi.tot(m2029, acum),
         case when elim then 'ELIMINADA' else 'ACTIVA' end, v_origen, now(), v_user
  from _t
  on conflict (id_tarea) do update set
    codigo = excluded.codigo, nombre = coalesce(nullif(excluded.nombre, ''), q.nombre), repr = excluded.repr, acum = excluded.acum,
    um = excluded.um, m2027 = excluded.m2027, m2028 = excluded.m2028, m2029 = excluded.m2029,
    total_2027 = excluded.total_2027, total_2028 = excluded.total_2028, total_2029 = excluded.total_2029,
    estado = excluded.estado, origen = excluded.origen, actualizado = excluded.actualizado, actualizado_por = excluded.actualizado_por;

  insert into poi.pm3_recurso as q (id_rec, id_ao, centro_costo, codigo_tarea, recurso, um, ff, rubro, clasificador, llave, n_prevision,
                                    cant_2027, cant_2028, cant_2029, m2027, m2028, m2029, total_2027, total_2028, total_2029,
                                    estado, origen, actualizado, actualizado_por)
  select id, v_id, cc, tarea, nombre, um, ff, rubro, clasificador, llave, prev,
         poi.t(cant ->> '2027', 20), poi.t(cant ->> '2028', 20), poi.t(cant ->> '2029', 20),
         m2027, m2028, m2029, poi.suma(m2027), poi.suma(m2028), poi.suma(m2029),
         case when elim then 'ELIMINADA' when dem then 'DEMANDA ADICIONAL' else 'ACTIVA' end, v_origen, now(), v_user
  from _r
  on conflict (id_rec) do update set
    codigo_tarea = excluded.codigo_tarea, recurso = excluded.recurso, um = excluded.um, ff = excluded.ff, rubro = excluded.rubro,
    clasificador = excluded.clasificador, llave = excluded.llave, n_prevision = excluded.n_prevision,
    cant_2027 = excluded.cant_2027, cant_2028 = excluded.cant_2028, cant_2029 = excluded.cant_2029,
    m2027 = excluded.m2027, m2028 = excluded.m2028, m2029 = excluded.m2029,
    total_2027 = excluded.total_2027, total_2028 = excluded.total_2028, total_2029 = excluded.total_2029,
    estado = excluded.estado, origen = excluded.origen, actualizado = excluded.actualizado, actualizado_por = excluded.actualizado_por;

  -- Cada guardado es la versión completa de la AO: lo que no vino queda como ELIMINADA (no se borra)
  update poi.pm2_tarea set estado = 'ELIMINADA', origen = v_origen, actualizado = now(), actualizado_por = v_user
   where id_ao = v_id and estado <> 'ELIMINADA' and id_tarea not in (select id from _t);
  update poi.pm3_recurso set estado = 'ELIMINADA', origen = v_origen, actualizado = now(), actualizado_por = v_user
   where id_ao = v_id and estado <> 'ELIMINADA' and id_rec not in (select id from _r);

  insert into poi.bitacora (usuario, accion, detalle)
  values (v_user, 'guardarAO', v_id || ' · ' || v_origen || ' · ' || (select count(*) from _t) || ' tareas, ' || (select count(*) from _r) || ' recursos');

  return jsonb_build_object('ok', true, 'id_ao', v_id, 'avisos', to_jsonb(avisos));
end $$;

-- ---------- Anexos 01-03 NMP ----------
create or replace function poi.enviar_nmp(s jsonb, cc text, b jsonb) returns jsonb
language plpgsql as $$
declare
  filas jsonb := case when jsonb_typeof(b -> 'filas') = 'array' then b -> 'filas' else '[]' end;
  sust_c text := poi.t(b ->> 'sustento_credito', 4000);
  sust_a text := poi.t(b ->> 'sustento_anulacion', 4000);
  errores text[] := '{}'; usadas text[] := '{}';
  f jsonb; i int; v_llave text; pr record; v_cred numeric; v_anul numeric; disp numeric; r record;
  v_num text; v_max int; v_total numeric; ahora timestamp := now() at time zone 'America/Lima';
begin
  if jsonb_array_length(filas) < 2 then perform poi.falla('Una NMP necesita al menos una fila de crédito y una de anulación.'); end if;
  if length(sust_c) < 20 then perform poi.falla('Escribe la justificación y sustento técnico del crédito (mínimo 20 caracteres).'); end if;
  if length(sust_a) < 20 then perform poi.falla('Escribe la justificación y sustento técnico de la anulación (mínimo 20 caracteres).'); end if;

  drop table if exists _n;
  create temp table _n (orden int, llave text, id_ao text, cu_efp text, ff text, rubro int, clasificador text,
                        cred numeric, anul numeric, meta_antes text, meta_despues text) on commit drop;
  for f, i in select value, ordinality from jsonb_array_elements(filas) with ordinality loop
    v_llave := poi.t(f ->> 'llave');
    select p.*, a.meta_2027 into pr from poi.partida p join poi.ao a on a.id_ao = p.id_ao
     where p.llave = v_llave and a.centro_costo = cc;
    if not found then errores := errores || ('Fila ' || i || ': la partida no pertenece a tu centro de costo.'); continue; end if;
    if v_llave = any (usadas) then errores := errores || ('Fila ' || i || ': la partida ' || pr.clasificador || ' está repetida.'); continue; end if;
    usadas := usadas || v_llave;
    v_cred := poi.n(f -> 'credito'); v_anul := poi.n(f -> 'anulacion');
    if v_cred is null or v_anul is null or v_cred < 0 or v_anul < 0 then errores := errores || ('Fila ' || i || ': montos inválidos.'); continue; end if;
    if v_cred <> trunc(v_cred) or v_anul <> trunc(v_anul) then errores := errores || ('Fila ' || i || ': los montos deben ser enteros.'); continue; end if;
    if (v_cred > 0) = (v_anul > 0) then errores := errores || ('Fila ' || i || ': indica crédito o anulación, no ambos ni ninguno.'); continue; end if;
    if v_anul > 0 then
      select coalesce(sd.saldo, 0) - coalesce((select sum(n.anulacion) from poi.nmp n where n.llave = v_llave and n.estado like 'EN REVISI%'), 0)
        into disp from poi.saldo sd where sd.llave = v_llave;
      if v_anul > coalesce(disp, 0) then
        errores := errores || ('Fila ' || i || ' (' || pr.clasificador || '): la anulación S/ ' || poi.fmt(v_anul) || ' supera el saldo disponible S/ ' || poi.fmt(disp) || '.');
      end if;
    end if;
    insert into _n values (i, v_llave, pr.id_ao, pr.cu_efp, pr.ff, pr.rubro, pr.clasificador, v_cred, v_anul,
                           coalesce(trim_scale(pr.meta_2027)::text, ''), poi.t(f ->> 'meta_despues', 60));
  end loop;
  for r in select rubro, min(ff) ff, sum(cred) c, sum(anul) a from _n group by rubro order by rubro loop
    if r.c <> r.a then
      errores := errores || ('Fuente ' || r.ff || ': créditos S/ ' || poi.fmt(r.c) || ' y anulaciones S/ ' || poi.fmt(r.a) || ' deben ser iguales (PIM inicial = PIM final).');
    end if;
  end loop;
  if array_length(errores, 1) > 0 then perform poi.falla('La NMP tiene observaciones.', to_jsonb(errores)::text); end if;

  perform pg_advisory_xact_lock(2027001);
  select coalesce(max(substring(numero from '(\d+)$')::int), 0) into v_max from poi.nmp;
  v_num := 'NMP-2027-' || lpad((v_max + 1)::text, 4, '0');
  insert into poi.nmp (numero, fecha, centro_costo, id_ao, cu_efp, ff, rubro, clasificador, llave, credito, anulacion,
                       meta_antes, meta_despues, sustento, estado, observacion, solicitante)
  select v_num, ahora::date, cc, id_ao, cu_efp, ff, rubro, clasificador, llave, cred, anul, meta_antes, meta_despues,
         'CRÉDITO: ' || sust_c || ' | ANULACIÓN: ' || sust_a, 'EN REVISIÓN OPP',
         'Registrado desde el portal ' || to_char(ahora, 'DD/MM/YYYY HH24:MI') || '. Cuadra por fuente y respeta saldos.', s ->> 'u'
  from _n order by orden;
  select sum(cred) into v_total from _n;
  insert into poi.bitacora (usuario, accion, detalle) values (s ->> 'u', 'enviarNMP', v_num || ' · ' || cc || ' · S/ ' || poi.fmt(v_total));
  return jsonb_build_object('ok', true, 'numero', v_num, 'total', v_total);
end $$;

-- ---------- OPP: aprobar u observar una NMP ----------
create or replace function poi.resolver_nmp(s jsonb, b jsonb) returns jsonb
language plpgsql as $$
declare v_num text := poi.t(b ->> 'numero'); v_est text := upper(poi.t(b ->> 'estado')); v_obs text := poi.t(b ->> 'observacion', 2000);
        v_ver text; n int;
begin
  if s ->> 'r' <> 'OPP' then perform poi.falla('Solo OPP puede resolver solicitudes.'); end if;
  if v_est not in ('APROBADO', 'OBSERVADO') then perform poi.falla('Estado no válido.'); end if;
  if v_est = 'OBSERVADO' and length(v_obs) < 5 then perform poi.falla('Escribe la observación para el área.'); end if;
  if not exists (select 1 from poi.nmp where numero = v_num and estado like 'EN REVISI%') then
    perform poi.falla('La solicitud ' || v_num || ' no está pendiente.');
  end if;
  if v_est = 'APROBADO' then
    select count(distinct numero) + 1 into n from poi.nmp where estado = 'APROBADO';
    v_ver := 'POI 2027 v' || n;
  end if;
  update poi.nmp set estado = v_est, version_poi = v_ver,
         observacion = case when v_obs <> '' then v_obs else observacion end,
         resuelto = now(), resuelto_por = s ->> 'u'
   where numero = v_num;
  insert into poi.bitacora (usuario, accion, detalle) values (s ->> 'u', 'resolverNMP', v_num || ' → ' || v_est);
  return jsonb_build_object('ok', true, 'numero', v_num, 'estado', v_est, 'version', v_ver);
end $$;

-- ---------- Contraseñas ----------
create or replace function poi.cambiar_clave(s jsonb, b jsonb) returns jsonb
language plpgsql as $$
declare u poi.usuario; nueva text := coalesce(b ->> 'nueva', '');
begin
  select * into u from poi.usuario where usuario = s ->> 'u';
  if u.hash <> poi.hash(u.usuario, coalesce(b ->> 'actual', '')) then perform poi.falla('La contraseña actual no es correcta.'); end if;
  if length(nueva) < 8 then perform poi.falla('La nueva contraseña debe tener al menos 8 caracteres.'); end if;
  update poi.usuario set hash = poi.hash(u.usuario, nueva) where usuario = u.usuario;
  insert into poi.bitacora (usuario, accion) values (u.usuario, 'cambiarClave');
  return jsonb_build_object('ok', true);
end $$;

create or replace function poi.restablecer_clave(s jsonb, b jsonb) returns jsonb
language plpgsql as $$
declare u poi.usuario; nueva text := coalesce(b ->> 'nueva', '');
begin
  if s ->> 'r' <> 'OPP' then perform poi.falla('Solo OPP puede restablecer contraseñas.'); end if;
  select * into u from poi.usuario where lower(usuario) = lower(poi.t(b ->> 'usuario'));
  if not found then perform poi.falla('No existe el usuario ' || poi.t(b ->> 'usuario') || '.'); end if;
  if length(nueva) < 8 then perform poi.falla('La nueva contraseña debe tener al menos 8 caracteres.'); end if;
  update poi.usuario set hash = poi.hash(u.usuario, nueva) where usuario = u.usuario;
  delete from poi.bitacora where accion = 'login_fallido' and usuario = lower(u.usuario);
  insert into poi.bitacora (usuario, accion, detalle) values (s ->> 'u', 'restablecerClave', u.usuario);
  return jsonb_build_object('ok', true, 'usuario', u.usuario);
end $$;

-- ---------- OPP: descarga completa (reemplaza al Google Sheet) ----------
create or replace function poi.exportar(s jsonb) returns jsonb
language plpgsql stable as $$
begin
  if s ->> 'r' <> 'OPP' then perform poi.falla('Solo OPP puede descargar la base completa.'); end if;
  return jsonb_build_object('ok', true, 'hojas', jsonb_build_array(
    jsonb_build_object('nombre', 'PA1_AO',       'filas', (select coalesce(json_agg(v), '[]')::jsonb from poi.v_pa1_ao v)),
    jsonb_build_object('nombre', 'PA3_Recursos', 'filas', (select coalesce(json_agg(v), '[]')::jsonb from poi.v_pa3_recursos v)),
    jsonb_build_object('nombre', 'PM2_Tareas',   'filas', (select coalesce(json_agg(v), '[]')::jsonb from poi.v_pm2_tareas v)),
    jsonb_build_object('nombre', 'PM3_Recursos', 'filas', (select coalesce(json_agg(v), '[]')::jsonb from poi.v_pm3_recursos v)),
    jsonb_build_object('nombre', 'Saldos_POI',   'filas', (select coalesce(json_agg(v), '[]')::jsonb from poi.v_saldos_poi v)),
    jsonb_build_object('nombre', 'NMP_Registro', 'filas', (select coalesce(json_agg(v), '[]')::jsonb from poi.v_nmp_registro v))
  ), 'columnas', jsonb_build_object(
    'PA1_AO',       (select to_jsonb(array_agg(attname order by attnum)) from pg_attribute where attrelid = 'poi.v_pa1_ao'::regclass and attnum > 0),
    'PA3_Recursos', (select to_jsonb(array_agg(attname order by attnum)) from pg_attribute where attrelid = 'poi.v_pa3_recursos'::regclass and attnum > 0),
    'PM2_Tareas',   (select to_jsonb(array_agg(attname order by attnum)) from pg_attribute where attrelid = 'poi.v_pm2_tareas'::regclass and attnum > 0),
    'PM3_Recursos', (select to_jsonb(array_agg(attname order by attnum)) from pg_attribute where attrelid = 'poi.v_pm3_recursos'::regclass and attnum > 0),
    'Saldos_POI',   (select to_jsonb(array_agg(attname order by attnum)) from pg_attribute where attrelid = 'poi.v_saldos_poi'::regclass and attnum > 0),
    'NMP_Registro', (select to_jsonb(array_agg(attname order by attnum)) from pg_attribute where attrelid = 'poi.v_nmp_registro'::regclass and attnum > 0)
  ));
end $$;

-- ---------- Punto de entrada único para la página ----------
create or replace function public.poi_api(p jsonb) returns jsonb
language plpgsql security definer
set search_path = poi, extensions, public
as $$
declare accion text := coalesce(p ->> 'accion', ''); s jsonb; cc text; det text;
begin
  if accion = 'ping' then return jsonb_build_object('ok', true, 'hora', now()); end if;
  if accion = 'login' then return poi.login(p); end if;
  s := poi.sesion(p ->> 'token');
  cc := s ->> 'cc';
  if s ->> 'r' = 'OPP' then cc := poi.t(p ->> 'cc'); end if;
  if accion in ('guardarAO', 'enviarNMP') and coalesce(cc, '') = '' then perform poi.falla('Selecciona un centro de costo.'); end if;
  case accion
    when 'datos'            then return poi.datos(s, cc);
    when 'guardarAO'        then return poi.guardar_ao(s, cc, p);
    when 'enviarNMP'        then return poi.enviar_nmp(s, cc, p);
    when 'resolverNMP'      then return poi.resolver_nmp(s, p);
    when 'cambiarClave'     then return poi.cambiar_clave(s, p);
    when 'restablecerClave' then return poi.restablecer_clave(s, p);
    when 'exportar'         then return poi.exportar(s);
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
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'grant execute on function public.poi_api(jsonb) to anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'grant execute on function public.poi_api(jsonb) to authenticated'; end if;
end $$;
