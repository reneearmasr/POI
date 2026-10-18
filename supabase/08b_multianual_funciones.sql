-- =====================================================================
-- POI – ATU · 08b · Multianual por periodos (funciones y vistas)
-- Se puede volver a ejecutar sin perder datos.
-- =====================================================================

-- ---------- Periodos ----------
create or replace function poi.per_activo() returns int
language sql stable as $$ select coalesce((select max(anio_ini) from poi.periodo where estado = 'ACTIVO'), (select max(anio_ini) from poi.periodo)) $$;

create or replace function poi.ys(per int) returns text[]
language sql immutable as $$ select array[per::text, (per + 1)::text, (per + 2)::text] $$;

create or replace function poi.periodos() returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('anio_ini', anio_ini, 'nombre', nombre, 'estado', estado,
           'anios', to_jsonb(poi.ys(anio_ini))) order by anio_ini desc), '[]') from poi.periodo
$$;

-- Lee {"<año1>":[12],"<año2>":[12],"<año3>":[12]} validando montos; devuelve {"1":[..],"2":[..],"3":[..]}
create or replace function poi.anios(y jsonb, etiqueta text, ys text[]) returns jsonb
language plpgsql immutable as $$
declare o jsonb := '{}'; k int; arr jsonb; vals numeric[]; v numeric; i int;
begin
  for k in 1..3 loop
    arr := case when y is not null and jsonb_typeof(y) = 'object' then y -> ys[k] else null end;
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
    o := o || jsonb_build_object(k::text, to_jsonb(vals));
  end loop;
  return o;
end $$;

-- ---------- Saldos por periodo (año 1 del periodo) ----------
create or replace view poi.saldo_m as
select p.llave, p.periodo, p.orden, p.id_ao, p.cu_efp, p.centro_costo, p.ff, p.rubro, p.clasificador,
       p.apm_a1,
       coalesce(n.cred, 0)                                          as credito,
       coalesce(n.anul, 0)                                          as anulacion,
       p.apm_a1 + coalesce(n.cred, 0) - coalesce(n.anul, 0)         as programado_vigente,
       coalesce(c.cert, 0)                                          as certificado,
       p.apm_a1 + coalesce(n.cred, 0) - coalesce(n.anul, 0) - coalesce(c.cert, 0) as saldo,
       p.apm_a2 + coalesce(v.p2, 0)                                 as previsto_a2,
       p.apm_a3 + coalesce(v.p3, 0)                                 as previsto_a3
from poi.partida p
left join (select llave, sum(credito) cred, sum(anulacion) anul from poi.nmp where estado = 'APROBADO' group by llave) n on n.llave = p.llave
left join (select llave, sum(monto) cert from poi.ccp where estado = 'APROBADO' group by llave) c on c.llave = p.llave
left join (select llave, sum(prevision_2028) p2, sum(prevision_2029) p3 from poi.prevision where estado = 'APROBADO' group by llave) v on v.llave = p.llave;

-- ---------- Datos del área para un periodo ----------
create or replace function poi.datos(s jsonb, cc text, per int) returns jsonb
language plpgsql stable as $$
declare
  ys text[]; pe jsonb;
  centros jsonb; ses jsonb; aos jsonb; partidas jsonb; tareas jsonb; recursos jsonb; nmp jsonb; bandeja jsonb := '[]';
begin
  per := coalesce(per, poi.per_activo());
  if not exists (select 1 from poi.periodo where anio_ini = per) then per := poi.per_activo(); end if;
  ys := poi.ys(per);
  select jsonb_build_object('anio_ini', anio_ini, 'nombre', nombre, 'estado', estado) into pe from poi.periodo where anio_ini = per;
  ses := jsonb_build_object('usuario', s ->> 'u', 'nombre', s ->> 'n', 'rol', s ->> 'r', 'cc', cc);
  if s ->> 'r' = 'OPP' then
    select coalesce(jsonb_agg(c order by c), '[]') into centros from (select distinct centro_costo c from poi.ao where periodo = per) x;
    select coalesce(jsonb_agg(jsonb_build_object('numero', numero, 'cc', cc_, 'fecha', to_char(fecha, 'DD/MM/YYYY'),
             'credito', cred, 'anulacion', anul, 'estado', est, 'solicitante', sol) order by numero), '[]')
      into bandeja
      from (select numero, min(centro_costo) cc_, min(fecha) fecha, sum(credito) cred, sum(anulacion) anul,
                   min(estado) est, min(solicitante) sol
              from poi.nmp where periodo = per group by numero having min(estado) like 'EN REVISI%') b;
  else
    centros := jsonb_build_array(cc);
  end if;
  if coalesce(cc, '') = '' then
    return jsonb_build_object('ok', true, 'sesion', ses, 'centros', centros, 'aos', '[]'::jsonb, 'partidas', '[]'::jsonb,
                              'tareas', '[]'::jsonb, 'recursos', '[]'::jsonb, 'nmp', '[]'::jsonb, 'bandeja', bandeja,
                              'periodo', pe, 'anios', to_jsonb(ys), 'periodos', poi.periodos(),
                              'panel', case when s ->> 'r' = 'OPP' then poi.panel(per) else '[]'::jsonb end);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id_ao', a.id_ao, 'cu_efp', a.cu_efp, 'uo', coalesce(a.unidad_organica, ''), 'oei', coalesce(a.oei, ''), 'aei', coalesce(a.aei, ''),
      'tipo', coalesce(a.tipo, ''), 'producto', coalesce(a.producto, ''), 'actividad_efp', coalesce(a.actividad_efp, ''),
      'finalidad', coalesce(a.finalidad, ''), 'nombre_ao', coalesce(a.nombre_ao, ''), 'descripcion', coalesce(a.descripcion, ''),
      'beneficiarios', coalesce(a.beneficiarios, ''), 'indicador', coalesce(a.indicador, ''), 'medio', coalesce(a.medio_verificacion, ''),
      'unidad_medida', coalesce(a.unidad_medida, ''),
      'meta_' || ys[1], a.meta_a1, 'meta_' || ys[2], a.meta_a2, 'meta_' || ys[3], a.meta_a3,
      'apm_' || ys[1], coalesce(t.a1, 0), 'apm_' || ys[2], coalesce(t.a2, 0), 'apm_' || ys[3], coalesce(t.a3, 0),
      'sec_func', coalesce(nullif(a.sec_func_2027, ''), lpad(coalesce(a.sec_func_2026, ''), 4, '0'))
    ) order by a.orden, a.id_ao), '[]') into aos
  from poi.ao a
  left join (select id_ao, sum(apm_a1) a1, sum(apm_a2) a2, sum(apm_a3) a3 from poi.partida group by id_ao) t on t.id_ao = a.id_ao
  where a.centro_costo = cc and a.periodo = per;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id_ao', p.id_ao, 'ff', coalesce(p.ff, ''), 'rubro', p.rubro, 'clasificador', coalesce(p.clasificador, ''),
      'clasificador_desc', coalesce(p.clasificador_desc, ''), 'concepto', coalesce(nullif(p.concepto2, ''), p.concepto1, ''),
      'reserva', coalesce(p.reserva, ''), 'apm_' || ys[1], p.apm_a1, 'apm_' || ys[2], p.apm_a2, 'apm_' || ys[3], p.apm_a3,
      'meses', to_jsonb(p.meses), 'llave', p.llave,
      'programado_vigente', s2.programado_vigente, 'credito', s2.credito, 'anulacion', s2.anulacion,
      'certificado', s2.certificado, 'saldo', s2.saldo, 'anulacion_en_revision', coalesce(r.pend, 0)
    ) order by p.orden, p.llave), '[]') into partidas
  from poi.partida p
  join poi.ao a on a.id_ao = p.id_ao and a.centro_costo = cc and a.periodo = per
  join poi.saldo_m s2 on s2.llave = p.llave
  left join (select llave, sum(anulacion) pend from poi.nmp where estado like 'EN REVISI%' group by llave) r on r.llave = p.llave;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', t.id_tarea, 'id_ao', t.id_ao, 'codigo', coalesce(t.codigo, ''), 'nombre', coalesce(t.nombre, ''),
      'repr', t.repr, 'acum', t.acum, 'um', coalesce(t.um, ''), 'propio', t.propio,
      'y', jsonb_build_object(ys[1], to_jsonb(t.m_a1), ys[2], to_jsonb(t.m_a2), ys[3], to_jsonb(t.m_a3))
    ) order by t.id_tarea), '[]') into tareas
  from poi.pm2_tarea t join poi.ao a on a.id_ao = t.id_ao and a.centro_costo = cc and a.periodo = per
  where upper(t.estado) <> 'ELIMINADA';

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', r.id_rec, 'demanda', upper(r.estado) = 'DEMANDA ADICIONAL', 'ff', coalesce(r.ff, ''), 'clasificador', coalesce(r.clasificador, ''),
      'id_ao', r.id_ao, 'tarea', coalesce(r.codigo_tarea, ''), 'nombre', coalesce(r.recurso, ''), 'um', coalesce(r.um, ''),
      'llave', coalesce(r.llave, ''), 'prev', coalesce(r.n_prevision, ''),
      'cant', jsonb_build_object(ys[1], coalesce(r.cant_a1, ''), ys[2], coalesce(r.cant_a2, ''), ys[3], coalesce(r.cant_a3, '')),
      'y', jsonb_build_object(ys[1], to_jsonb(r.m_a1), ys[2], to_jsonb(r.m_a2), ys[3], to_jsonb(r.m_a3))
    ) order by r.id_rec), '[]') into recursos
  from poi.pm3_recurso r join poi.ao a on a.id_ao = r.id_ao and a.centro_costo = cc and a.periodo = per
  where upper(r.estado) <> 'ELIMINADA';

  select coalesce(jsonb_agg(g order by g ->> 'numero' desc), '[]') into nmp
  from (
    select jsonb_build_object('numero', numero, 'fecha', to_char(min(fecha), 'DD/MM/YYYY'), 'estado', min(estado),
             'observacion', coalesce(min(observacion), ''), 'sustento', coalesce(min(sustento), ''), 'version', coalesce(min(version_poi), ''),
             'credito', sum(credito), 'anulacion', sum(anulacion),
             'filas', jsonb_agg(jsonb_build_object('id_ao', id_ao, 'rubro', rubro, 'clasificador', clasificador, 'credito', credito,
                                                   'anulacion', anulacion, 'meta_antes', coalesce(meta_antes, ''), 'meta_despues', coalesce(meta_despues, '')) order by id)) g
    from poi.nmp where centro_costo = cc and periodo = per group by numero
  ) x;

  return jsonb_build_object('ok', true, 'sesion', ses, 'centros', centros, 'aos', aos, 'partidas', partidas,
                            'tareas', tareas, 'recursos', recursos, 'nmp', nmp, 'bandeja', bandeja,
                            'periodo', pe, 'anios', to_jsonb(ys), 'periodos', poi.periodos());
end $$;

-- ---------- Guardar PM1 + PM2 + PM3 de una AO (periodo de la AO) ----------
create or replace function poi.guardar_ao(s jsonb, cc text, b jsonb) returns jsonb
language plpgsql as $$
declare
  v_id     text := poi.t(b ->> 'id_ao');
  a        poi.ao;
  p1       jsonb := coalesce(b -> 'pa1', '{}');
  v_origen text := case when b ->> 'origen' = 'Importado' and s ->> 'r' = 'OPP' then 'Importado' else 'Portal' end;
  v_user   text := s ->> 'u';
  ys text[]; k int;
  e jsonb; v_tid text; v_rid text; max_t int; max_r int; v_elim boolean; v_dem boolean;
  v_cod text; v_nom text; an jsonb; avisos text[] := '{}'; excesos text[] := '{}';
  tot numeric; d int; maxd int; x text; y2 text;
  pr poi.partida; hay_p boolean; ex poi.pm3_recurso; hay_ex boolean;
  r record; apm numeric; prog numeric; ndem int; mdem numeric;
begin
  select * into a from poi.ao where id_ao = v_id;
  if not found then perform poi.falla('La actividad operativa ' || v_id || ' no existe.'); end if;
  if a.centro_costo <> cc then perform poi.falla('La actividad ' || v_id || ' no pertenece a tu centro de costo.'); end if;
  if (select estado from poi.periodo where anio_ini = a.periodo) <> 'ACTIVO' then
    perform poi.falla('El periodo ' || a.periodo || '–' || (a.periodo + 2) || ' está cerrado: solo se puede consultar.');
  end if;
  if poi.t(p1 ->> 'nombre_ao') = '' then perform poi.falla('El nombre de la actividad operativa no puede quedar vacío.'); end if;
  ys := poi.ys(a.periodo);

  -- ===== PM2 =====
  create temp table if not exists _t (id text, codigo text, nombre text, repr boolean, acum boolean, um text,
                        m1 numeric[], m2 numeric[], m3 numeric[], elim boolean, padre text, prof int, propio boolean) on commit drop;
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
    an := poi.anios(e -> 'y', 'Tarea ' || coalesce(nullif(v_cod, ''), v_nom), ys);
    if not v_elim then
      if v_cod !~ '^\d+(\.\d+)*$' then perform poi.falla('El código de la tarea "' || v_nom || '" debe ser tipo 1, 1.1, 1.1.1.'); end if;
      if v_nom = '' then perform poi.falla('Hay una tarea sin nombre (código ' || v_cod || ').'); end if;
      if poi.t(e ->> 'um') = '' then perform poi.falla('La tarea ' || v_cod || ' necesita unidad de medida.'); end if;
    end if;
    insert into _t values (v_tid, v_cod, v_nom, poi.b(e -> 'repr'), poi.b(e -> 'acum'), poi.t(e ->> 'um'),
                           poi.arr(an -> '1'), poi.arr(an -> '2'), poi.arr(an -> '3'), v_elim,
                           poi.padre(v_cod), coalesce(array_length(string_to_array(v_cod, '.'), 1), 0), poi.b(e -> 'propio'));
  end loop;
  if not exists (select 1 from _t where not elim) then perform poi.falla('La actividad debe tener al menos una tarea (PM2).'); end if;
  select codigo into x from _t where not elim group by codigo having count(*) > 1 limit 1;
  if x is not null then perform poi.falla('El código de tarea ' || x || ' está repetido.'); end if;
  select t.codigo, t.padre into x, y2 from _t t
   where not t.elim and t.padre <> '' and not exists (select 1 from _t q where not q.elim and q.codigo = t.padre) limit 1;
  if x is not null then perform poi.falla('La tarea ' || x || ' no tiene tarea padre ' || y2 || '.'); end if;
  select max(prof) into maxd from _t where not elim;
  for d in reverse (maxd - 1)..1 loop
    update _t p set
      m1 = (select array_agg(round(sm, 2) order by i) from (select i, sum(c.m1[i]) sm from _t c cross join generate_series(1, 12) i where not c.elim and c.padre = p.codigo group by i) z),
      m2 = (select array_agg(round(sm, 2) order by i) from (select i, sum(c.m2[i]) sm from _t c cross join generate_series(1, 12) i where not c.elim and c.padre = p.codigo group by i) z),
      m3 = (select array_agg(round(sm, 2) order by i) from (select i, sum(c.m3[i]) sm from _t c cross join generate_series(1, 12) i where not c.elim and c.padre = p.codigo group by i) z)
    where not p.elim and not p.propio and p.prof = d and exists (select 1 from _t c where not c.elim and c.padre = p.codigo);
  end loop;
  if not exists (select 1 from _t where not elim and repr and prof = 1) then
    perform poi.falla('Marca como representativa al menos una tarea de primer nivel (1, 2, …) en la PM2.');
  end if;
  -- La meta física la define el área (tareas representativas de primer nivel); la APM solo limita el presupuesto
  for k in 1..3 loop
    select round(coalesce(sum(poi.tot(case k when 1 then m1 when 2 then m2 else m3 end, acum)), 0), 2)
      into tot from _t where not elim and repr and prof = 1;
    if tot = 0 then avisos := avisos || ('PM2 ' || ys[k] || ': la actividad no tiene meta física programada.'); end if;
    if k = 1 then a.meta_a1 := tot; elsif k = 2 then a.meta_a2 := tot; else a.meta_a3 := tot; end if;
  end loop;

  -- ===== PM3 =====
  create temp table if not exists _r (id text, tarea text, nombre text, um text, llave text, prev text, cant jsonb,
                        m1 numeric[], m2 numeric[], m3 numeric[], elim boolean, dem boolean,
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
    an := poi.anios(e -> 'y', 'Recurso ' || v_nom, ys);
    v_dem := poi.b(e -> 'demanda');
    select * into pr from poi.partida where id_ao = v_id and llave = poi.t(e ->> 'llave'); hay_p := found;
    select * into ex from poi.pm3_recurso where id_rec = v_rid; hay_ex := found;
    if v_dem then
      if not v_elim and v_nom = '' then perform poi.falla('Hay una propuesta no priorizada sin descripción.'); end if;
      insert into _r values (v_rid, poi.t(e ->> 'tarea'), coalesce(nullif(v_nom, ''), ex.recurso, ''), poi.t(e ->> 'um', 60), poi.t(e ->> 'llave'),
        poi.t(e ->> 'prev', 60), e -> 'cant', poi.arr(an -> '1'), poi.arr(an -> '2'), poi.arr(an -> '3'), v_elim, true,
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
      poi.t(e ->> 'prev', 60), e -> 'cant', poi.arr(an -> '1'), poi.arr(an -> '2'), poi.arr(an -> '3'), v_elim, false,
      coalesce(nullif(case when hay_p then pr.ff end, ''), ex.ff, ''),
      coalesce(nullif(case when hay_p then pr.rubro::text end, ''), ex.rubro, ''),
      coalesce(nullif(case when hay_p then pr.clasificador end, ''), ex.clasificador, ''));
    update _r set llave = coalesce(nullif(llave, ''), ex.llave, '') where id = v_rid;
  end loop;
  if not exists (select 1 from _r where not dem and not elim) then perform poi.falla('La actividad debe tener al menos un recurso (PM3).'); end if;

  -- Cuadre contra el techo APM de cada partida
  for r in select p.* from poi.partida p where p.id_ao = v_id order by p.orden, p.llave loop
    for k in 1..3 loop
      apm := round(coalesce(case k when 1 then r.apm_a1 when 2 then r.apm_a2 else r.apm_a3 end, 0), 2);
      select round(coalesce(sum(poi.suma(case k when 1 then m1 when 2 then m2 else m3 end)), 0), 2)
        into prog from _r where not elim and not dem and llave = r.llave;
      if prog > apm then
        excesos := excesos || (coalesce(r.clasificador, '') || ' (FF' || split_part(coalesce(r.ff, ''), '-', 1) || ') ' || ys[k] || ': S/ ' || poi.fmt(prog) || ' supera la APM de S/ ' || poi.fmt(apm));
      elsif apm <> prog then
        avisos := avisos || ('PM3 ' || ys[k] || ' ' || coalesce(r.clasificador, '') || ' (' || split_part(coalesce(r.ff, ''), '-', 1) || '): programado S/ ' || poi.fmt(prog) || ' de S/ ' || poi.fmt(apm) || '.');
      end if;
    end loop;
  end loop;
  if array_length(excesos, 1) > 0 then
    perform poi.falla('La programación debe ajustarse a la APM. ' || array_to_string(excesos[1:4], '; ')
      || case when array_length(excesos, 1) > 4 then '; y ' || (array_length(excesos, 1) - 4) || ' más' else '' end
      || '. Registra el exceso como propuesta no priorizada o solicita una NMP.');
  end if;
  select count(*), coalesce(sum(poi.suma(m1)), 0) into ndem, mdem from _r where dem and not elim;
  if ndem > 0 then
    avisos := avisos || ('Propuesta no priorizada (fuera del techo APM): ' || ndem || ' recurso(s), S/ ' || poi.fmt(mdem) || ' en ' || ys[1] || '.');
  end if;

  -- ===== Escritura =====
  update poi.ao set nombre_ao = poi.t(p1 ->> 'nombre_ao'), descripcion = poi.t(p1 ->> 'descripcion'),
         beneficiarios = poi.t(p1 ->> 'beneficiarios'), indicador = poi.t(p1 ->> 'indicador'),
         medio_verificacion = poi.t(p1 ->> 'medio'),
         unidad_medida = coalesce(nullif(poi.t(p1 ->> 'unidad_medida', 100), ''), unidad_medida),
         meta_a1 = a.meta_a1, meta_a2 = a.meta_a2, meta_a3 = a.meta_a3,
         actualizado = now(), actualizado_por = v_user
   where id_ao = v_id;

  insert into poi.pm2_tarea as q (id_tarea, id_ao, centro_costo, codigo, nombre, repr, acum, um, m_a1, m_a2, m_a3,
                                  total_a1, total_a2, total_a3, estado, origen, actualizado, actualizado_por, propio, periodo)
  select id, v_id, cc, codigo, nombre, repr, acum, um, m1, m2, m3,
         poi.tot(m1, acum), poi.tot(m2, acum), poi.tot(m3, acum),
         case when elim then 'ELIMINADA' else 'ACTIVA' end, v_origen, now(), v_user,
         propio and exists (select 1 from _t c where not c.elim and c.padre = _t.codigo), a.periodo
  from _t
  on conflict (id_tarea) do update set
    codigo = excluded.codigo, nombre = coalesce(nullif(excluded.nombre, ''), q.nombre), repr = excluded.repr, acum = excluded.acum,
    um = excluded.um, m_a1 = excluded.m_a1, m_a2 = excluded.m_a2, m_a3 = excluded.m_a3,
    total_a1 = excluded.total_a1, total_a2 = excluded.total_a2, total_a3 = excluded.total_a3,
    estado = excluded.estado, origen = excluded.origen, actualizado = excluded.actualizado, actualizado_por = excluded.actualizado_por,
    propio = excluded.propio;

  insert into poi.pm3_recurso as q (id_rec, id_ao, centro_costo, codigo_tarea, recurso, um, ff, rubro, clasificador, llave, n_prevision,
                                    cant_a1, cant_a2, cant_a3, m_a1, m_a2, m_a3, total_a1, total_a2, total_a3,
                                    estado, origen, actualizado, actualizado_por, periodo)
  select id, v_id, cc, tarea, nombre, um, ff, rubro, clasificador, llave, prev,
         poi.t(cant ->> ys[1], 20), poi.t(cant ->> ys[2], 20), poi.t(cant ->> ys[3], 20),
         m1, m2, m3, poi.suma(m1), poi.suma(m2), poi.suma(m3),
         case when elim then 'ELIMINADA' when dem then 'DEMANDA ADICIONAL' else 'ACTIVA' end, v_origen, now(), v_user, a.periodo
  from _r
  on conflict (id_rec) do update set
    codigo_tarea = excluded.codigo_tarea, recurso = excluded.recurso, um = excluded.um, ff = excluded.ff, rubro = excluded.rubro,
    clasificador = excluded.clasificador, llave = excluded.llave, n_prevision = excluded.n_prevision,
    cant_a1 = excluded.cant_a1, cant_a2 = excluded.cant_a2, cant_a3 = excluded.cant_a3,
    m_a1 = excluded.m_a1, m_a2 = excluded.m_a2, m_a3 = excluded.m_a3,
    total_a1 = excluded.total_a1, total_a2 = excluded.total_a2, total_a3 = excluded.total_a3,
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

-- ---------- NMP (año 1 del periodo activo) ----------
create or replace function poi.enviar_nmp(s jsonb, cc text, b jsonb) returns jsonb
language plpgsql as $$
declare
  per int := poi.per_activo();
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

  create temp table if not exists _n (orden int, llave text, id_ao text, cu_efp text, ff text, rubro int, clasificador text,
                        cred numeric, anul numeric, meta_antes text, meta_despues text) on commit drop;
  for f, i in select value, ordinality from jsonb_array_elements(filas) with ordinality loop
    v_llave := poi.t(f ->> 'llave');
    select p.*, a.meta_a1 into pr from poi.partida p join poi.ao a on a.id_ao = p.id_ao
     where p.llave = v_llave and a.centro_costo = cc and a.periodo = per;
    if not found then errores := errores || ('Fila ' || i || ': la partida no pertenece a tu centro de costo.'); continue; end if;
    if v_llave = any (usadas) then errores := errores || ('Fila ' || i || ': la partida ' || pr.clasificador || ' está repetida.'); continue; end if;
    usadas := usadas || v_llave;
    v_cred := poi.n(f -> 'credito'); v_anul := poi.n(f -> 'anulacion');
    if v_cred is null or v_anul is null or v_cred < 0 or v_anul < 0 then errores := errores || ('Fila ' || i || ': montos inválidos.'); continue; end if;
    if v_cred <> trunc(v_cred) or v_anul <> trunc(v_anul) then errores := errores || ('Fila ' || i || ': los montos deben ser enteros.'); continue; end if;
    if (v_cred > 0) = (v_anul > 0) then errores := errores || ('Fila ' || i || ': indica crédito o anulación, no ambos ni ninguno.'); continue; end if;
    if v_anul > 0 then
      select coalesce(sd.saldo, 0) - coalesce((select sum(n.anulacion) from poi.nmp n where n.llave = v_llave and n.estado like 'EN REVISI%'), 0)
        into disp from poi.saldo_m sd where sd.llave = v_llave;
      if v_anul > coalesce(disp, 0) then
        errores := errores || ('Fila ' || i || ' (' || pr.clasificador || '): la anulación S/ ' || poi.fmt(v_anul) || ' supera el saldo disponible S/ ' || poi.fmt(disp) || '.');
      end if;
    end if;
    insert into _n values (i, v_llave, pr.id_ao, pr.cu_efp, pr.ff, pr.rubro, pr.clasificador, v_cred, v_anul,
                           coalesce(trim_scale(pr.meta_a1)::text, ''), poi.t(f ->> 'meta_despues', 60));
  end loop;
  for r in select rubro, min(ff) ff, sum(cred) c, sum(anul) a from _n group by rubro order by rubro loop
    if r.c <> r.a then
      errores := errores || ('Fuente ' || r.ff || ': créditos S/ ' || poi.fmt(r.c) || ' y anulaciones S/ ' || poi.fmt(r.a) || ' deben ser iguales (PIM inicial = PIM final).');
    end if;
  end loop;
  if array_length(errores, 1) > 0 then perform poi.falla('La NMP tiene observaciones.', to_jsonb(errores)::text); end if;

  perform pg_advisory_xact_lock(2027001);
  select coalesce(max(substring(numero from '(\d+)$')::int), 0) into v_max from poi.nmp where numero like 'NMP-' || per || '-%';
  v_num := 'NMP-' || per || '-' || lpad((v_max + 1)::text, 4, '0');
  insert into poi.nmp (numero, fecha, centro_costo, id_ao, cu_efp, ff, rubro, clasificador, llave, credito, anulacion,
                       meta_antes, meta_despues, sustento, estado, observacion, solicitante, periodo)
  select v_num, ahora::date, cc, id_ao, cu_efp, ff, rubro, clasificador, llave, cred, anul, meta_antes, meta_despues,
         'CRÉDITO: ' || sust_c || ' | ANULACIÓN: ' || sust_a, 'EN REVISIÓN OPP',
         'Registrado desde el portal ' || to_char(ahora, 'DD/MM/YYYY HH24:MI') || '. Cuadra por fuente y respeta saldos.', s ->> 'u', per
  from _n order by orden;
  select sum(cred) into v_total from _n;
  insert into poi.bitacora (usuario, accion, detalle) values (s ->> 'u', 'enviarNMP', v_num || ' · ' || cc || ' · S/ ' || poi.fmt(v_total));
  return jsonb_build_object('ok', true, 'numero', v_num, 'total', v_total);
end $$;

create or replace function poi.resolver_nmp(s jsonb, b jsonb) returns jsonb
language plpgsql as $$
declare v_num text := poi.t(b ->> 'numero'); v_est text := upper(poi.t(b ->> 'estado')); v_obs text := poi.t(b ->> 'observacion', 2000);
        v_ver text; n int; per int;
begin
  if s ->> 'r' <> 'OPP' then perform poi.falla('Solo OPP puede resolver solicitudes.'); end if;
  if v_est not in ('APROBADO', 'OBSERVADO') then perform poi.falla('Estado no válido.'); end if;
  if v_est = 'OBSERVADO' and length(v_obs) < 5 then perform poi.falla('Escribe la observación para el área.'); end if;
  select min(periodo) into per from poi.nmp where numero = v_num and estado like 'EN REVISI%';
  if per is null then perform poi.falla('La solicitud ' || v_num || ' no está pendiente.'); end if;
  if v_est = 'APROBADO' then
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

-- ---------- Panel de control (por periodo) ----------
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

-- ---------- Versiones (por periodo) ----------
create or replace function poi.cerrar_version(s jsonb, b jsonb) returns jsonb
language plpgsql as $$
declare v int; per int := poi.per_activo();
        v_nom text := poi.t(b ->> 'nombre', 120); v_eta text := coalesce(nullif(poi.t(b ->> 'etapa', 60), ''), 'Proyecto de ley');
begin
  if s ->> 'r' <> 'OPP' then perform poi.falla('Solo OPP puede cerrar versiones.'); end if;
  if length(v_nom) < 3 then perform poi.falla('Escribe un nombre para la versión.'); end if;
  insert into poi.version (nombre, etapa, creada_por, periodo) values (v_nom, v_eta, s ->> 'u', per) returning id into v;
  insert into poi.version_ao      select v, a.* from poi.ao a where a.periodo = per;
  insert into poi.version_partida select v, p.* from poi.partida p where p.periodo = per;
  insert into poi.version_pm2     select v, t.* from poi.pm2_tarea t where t.estado <> 'ELIMINADA' and t.periodo = per;
  insert into poi.version_pm3     select v, r.* from poi.pm3_recurso r where r.estado <> 'ELIMINADA' and r.periodo = per;
  insert into poi.bitacora (usuario, accion, detalle) values (s ->> 'u', 'cerrarVersion', v || ' · ' || v_nom);
  return jsonb_build_object('ok', true, 'id', v, 'nombre', v_nom);
end $$;

create or replace function poi.versiones(per int) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', v.id, 'nombre', v.nombre, 'etapa', coalesce(v.etapa, ''), 'por', coalesce(v.creada_por, ''),
           'fecha', to_char(v.creada at time zone 'America/Lima', 'DD/MM/YYYY HH24:MI'),
           'priorizado_a1', coalesce((select sum(total_a1) from poi.version_pm3 r where r.version_id = v.id and r.estado = 'ACTIVA'), 0),
           'no_priorizado_a1', coalesce((select sum(total_a1) from poi.version_pm3 r where r.version_id = v.id and r.estado = 'DEMANDA ADICIONAL'), 0)
         ) order by v.id desc), '[]')
    from poi.version v where v.periodo = per
$$;

-- ---------- Iniciar el periodo siguiente (arrastra años 2 y 3 del actual) ----------
create or replace function poi.nuevo_periodo(s jsonb, b jsonb) returns jsonb
language plpgsql as $$
declare
  old int := poi.per_activo(); nue int := poi.per_activo() + 1;
  pre_o text := 'AO' || right(poi.per_activo()::text, 2) || '-';
  pre_n text := 'AO' || right((poi.per_activo() + 1)::text, 2) || '-';
  n_ao int; n_t int; n_r int;
begin
  if s ->> 'r' <> 'OPP' then perform poi.falla('Solo OPP puede iniciar un periodo.'); end if;
  if coalesce(b ->> 'anio_ini', '') <> nue::text then perform poi.falla('El siguiente periodo debe ser ' || nue || '–' || (nue + 2) || '. Recarga la página.'); end if;
  if nue > coalesce(nullif(poi.cfg('anio_actual'), '')::int, extract(year from now() at time zone 'America/Lima')::int) + 1 then
    perform poi.falla('El periodo ' || nue || '–' || (nue + 2) || ' se abre a partir de ' || (nue - 1) || '.');
  end if;
  if exists (select 1 from poi.periodo where anio_ini = nue) then perform poi.falla('El periodo ' || nue || '–' || (nue + 2) || ' ya existe.'); end if;

  insert into poi.periodo (anio_ini, nombre, estado, creado_por) values (nue, 'POI Multianual ' || nue || '–' || (nue + 2), 'ACTIVO', s ->> 'u');
  update poi.periodo set estado = 'CERRADO' where anio_ini = old;

  -- Actividades: mismas fichas; metas se corren un año (el último año queda en 0)
  insert into poi.ao (id_ao, orden, cu_efp, sec_func_2026, sec_func_2027, organo, centro_costo, unidad_organica, cod_oei, oei, cod_aei, aei,
                      tipo, cod_producto, producto, programa, actividad_efp, funcion, div_fun, grp_fun, finalidad, nombre_ao, descripcion,
                      beneficiarios, indicador, medio_verificacion, departamento, provincia, distrito, unidad_medida,
                      meta_a1, meta_a2, meta_a3, actualizado, actualizado_por, periodo)
  select pre_n || substr(id_ao, length(pre_o) + 1), orden, cu_efp, sec_func_2026, sec_func_2027, organo, centro_costo, unidad_organica, cod_oei, oei, cod_aei, aei,
         tipo, cod_producto, producto, programa, actividad_efp, funcion, div_fun, grp_fun, finalidad, nombre_ao, descripcion,
         beneficiarios, indicador, medio_verificacion, departamento, provincia, distrito, unidad_medida,
         meta_a2, meta_a3, 0, null, null, nue
    from poi.ao where periodo = old;
  get diagnostics n_ao = row_count;

  -- Partidas: techos se corren un año; el nuevo año queda en 0 hasta cargar la nueva APM
  insert into poi.partida (llave, orden, id_ao, cu_efp, centro_costo, ff, rubro, clasificador, clasificador_desc, concepto1, concepto2, reserva,
                           apm_a1, apm_a2, apm_a3, meses, periodo)
  select nue || substr(llave, 5), orden, pre_n || substr(id_ao, length(pre_o) + 1), cu_efp, centro_costo, ff, rubro, clasificador, clasificador_desc,
         concepto1, concepto2, reserva, apm_a2, apm_a3, 0, poi.ceros(), nue
    from poi.partida where periodo = old;

  -- PM2: programación de los años que se repiten; el nuevo año en blanco
  insert into poi.pm2_tarea (id_tarea, id_ao, centro_costo, codigo, nombre, repr, acum, um, m_a1, m_a2, m_a3, total_a1, total_a2, total_a3,
                             estado, origen, actualizado, actualizado_por, propio, periodo)
  select pre_n || substr(id_tarea, length(pre_o) + 1), pre_n || substr(id_ao, length(pre_o) + 1), centro_costo, codigo, nombre, repr, acum, um,
         m_a2, m_a3, poi.ceros(), total_a2, total_a3, 0, estado, 'Periodo ' || old, null, null, propio, nue
    from poi.pm2_tarea where periodo = old and estado <> 'ELIMINADA';
  get diagnostics n_t = row_count;

  -- PM3: idem (priorizado y no priorizado)
  insert into poi.pm3_recurso (id_rec, id_ao, centro_costo, codigo_tarea, recurso, um, ff, rubro, clasificador, llave, n_prevision,
                               cant_a1, cant_a2, cant_a3, m_a1, m_a2, m_a3, total_a1, total_a2, total_a3,
                               estado, origen, actualizado, actualizado_por, periodo)
  select pre_n || substr(id_rec, length(pre_o) + 1), pre_n || substr(id_ao, length(pre_o) + 1), centro_costo, codigo_tarea, recurso, um, ff, rubro,
         clasificador, case when coalesce(llave, '') = '' then llave else nue || substr(llave, 5) end, n_prevision,
         cant_a2, cant_a3, '', m_a2, m_a3, poi.ceros(), total_a2, total_a3, 0, estado, 'Periodo ' || old, null, null, nue
    from poi.pm3_recurso where periodo = old and estado <> 'ELIMINADA';
  get diagnostics n_r = row_count;

  insert into poi.bitacora (usuario, accion, detalle)
  values (s ->> 'u', 'nuevoPeriodo', nue || '–' || (nue + 2) || ' · ' || n_ao || ' AO, ' || n_t || ' tareas, ' || n_r || ' recursos');
  return jsonb_build_object('ok', true, 'periodo', nue, 'nombre', 'POI Multianual ' || nue || '–' || (nue + 2), 'aos', n_ao, 'tareas', n_t, 'recursos', n_r);
end $$;

-- ---------- Vistas de exportación genéricas (A1, A2, A3 = años del periodo) ----------
create or replace view poi.x_pa1_ao as
select a.periodo as "Periodo", a.id_ao as "ID_AO", a.cu_efp as "CU_EFP", a.sec_func_2026 as "Sec_func (ref.)", a.sec_func_2027 as "Sec_func",
 a.organo as "Órgano", a.centro_costo as "Centro de costo", a.unidad_organica as "Unidad orgánica", a.cod_oei as "Cód. OEI", a.oei as "Descripción OEI",
 a.cod_aei as "Cód. AEI", a.aei as "Descripción AEI", a.tipo as "Tipo", a.cod_producto as "Cód. inversión / producto", a.producto as "Descripción producto / proyecto",
 a.programa as "Programa", a.actividad_efp as "Actividad / acción", a.funcion as "Función", a.div_fun as "Div. Fun.", a.grp_fun as "Grp. Fun.", a.finalidad as "Finalidad",
 a.nombre_ao as "Actividad operativa o inversión", a.descripcion as "Descripción de la intervención", a.beneficiarios as "Beneficiarios", a.indicador as "Indicador",
 a.medio_verificacion as "Medio de verificación", a.departamento as "Departamento", a.provincia as "Provincia", a.distrito as "Distrito", a.unidad_medida as "Unidad de medida",
 a.meta_a1 as "Meta física A1", a.meta_a2 as "Meta física A2", a.meta_a3 as "Meta física A3",
 coalesce(t.a1, 0) as "APM A1 (S/)", coalesce(t.a2, 0) as "APM A2 (S/)", coalesce(t.a3, 0) as "APM A3 (S/)", coalesce(t.n, 0) as "N° filas PA3",
 a.actualizado as "Actualizado", a.actualizado_por as "Actualizado por"
from poi.ao a left join (select id_ao, sum(apm_a1) a1, sum(apm_a2) a2, sum(apm_a3) a3, count(*) n from poi.partida group by id_ao) t on t.id_ao = a.id_ao
order by a.orden, a.id_ao;

create or replace view poi.x_pa3_recursos as
select p.periodo as "Periodo", p.id_ao as "ID_AO", p.cu_efp as "CU_EFP", p.centro_costo as "Centro de costo", p.ff as "FF", p.rubro as "Rubro", p.clasificador as "Clasificador",
 p.clasificador_desc as "Clasificador – descripción", p.concepto1 as "Concepto 1", p.concepto2 as "Concepto 2", p.reserva as "Reserva",
 p.apm_a1 as "APM A1 (S/)", p.apm_a2 as "APM A2 (S/)", p.apm_a3 as "APM A3 (S/)", p.llave as "Llave"
from poi.partida p order by p.orden, p.llave;

create or replace view poi.x_pm2_tareas as
select periodo as "Periodo", id_tarea as "ID_TAREA", id_ao as "ID_AO", centro_costo as "Centro de costo", codigo as "Código", nombre as "Actividad / Tarea / Acción",
 case when repr then 'Sí' else 'No' end as "Repr.", case when acum then 'Sí' else 'No' end as "Acum.", um as "Unidad de medida",
 m_a1[1] as "A1 Ene", m_a1[2] as "A1 Feb", m_a1[3] as "A1 Mar", m_a1[4] as "A1 Abr", m_a1[5] as "A1 May", m_a1[6] as "A1 Jun", m_a1[7] as "A1 Jul", m_a1[8] as "A1 Ago", m_a1[9] as "A1 Set", m_a1[10] as "A1 Oct", m_a1[11] as "A1 Nov", m_a1[12] as "A1 Dic", total_a1 as "A1 Total",
 m_a2[1] as "A2 Ene", m_a2[2] as "A2 Feb", m_a2[3] as "A2 Mar", m_a2[4] as "A2 Abr", m_a2[5] as "A2 May", m_a2[6] as "A2 Jun", m_a2[7] as "A2 Jul", m_a2[8] as "A2 Ago", m_a2[9] as "A2 Set", m_a2[10] as "A2 Oct", m_a2[11] as "A2 Nov", m_a2[12] as "A2 Dic", total_a2 as "A2 Total",
 m_a3[1] as "A3 Ene", m_a3[2] as "A3 Feb", m_a3[3] as "A3 Mar", m_a3[4] as "A3 Abr", m_a3[5] as "A3 May", m_a3[6] as "A3 Jun", m_a3[7] as "A3 Jul", m_a3[8] as "A3 Ago", m_a3[9] as "A3 Set", m_a3[10] as "A3 Oct", m_a3[11] as "A3 Nov", m_a3[12] as "A3 Dic", total_a3 as "A3 Total",
 case when propio then 'Sí' else 'No' end as "Valor propio", estado as "Estado", origen as "Origen", actualizado as "Actualizado", actualizado_por as "Actualizado por"
from poi.pm2_tarea order by id_tarea;

create or replace view poi.x_pm3_recursos as
select periodo as "Periodo", id_rec as "ID_REC", id_ao as "ID_AO", centro_costo as "Centro de costo", codigo_tarea as "Código tarea", recurso as "Recurso", um as "Unidad de medida",
 ff as "FF", rubro as "Rubro", clasificador as "Clasificador", llave as "Llave", n_prevision as "N° previsión",
 cant_a1 as "Cant A1", m_a1[1] as "A1 Ene", m_a1[2] as "A1 Feb", m_a1[3] as "A1 Mar", m_a1[4] as "A1 Abr", m_a1[5] as "A1 May", m_a1[6] as "A1 Jun", m_a1[7] as "A1 Jul", m_a1[8] as "A1 Ago", m_a1[9] as "A1 Set", m_a1[10] as "A1 Oct", m_a1[11] as "A1 Nov", m_a1[12] as "A1 Dic", total_a1 as "A1 Total",
 cant_a2 as "Cant A2", m_a2[1] as "A2 Ene", m_a2[2] as "A2 Feb", m_a2[3] as "A2 Mar", m_a2[4] as "A2 Abr", m_a2[5] as "A2 May", m_a2[6] as "A2 Jun", m_a2[7] as "A2 Jul", m_a2[8] as "A2 Ago", m_a2[9] as "A2 Set", m_a2[10] as "A2 Oct", m_a2[11] as "A2 Nov", m_a2[12] as "A2 Dic", total_a2 as "A2 Total",
 cant_a3 as "Cant A3", m_a3[1] as "A3 Ene", m_a3[2] as "A3 Feb", m_a3[3] as "A3 Mar", m_a3[4] as "A3 Abr", m_a3[5] as "A3 May", m_a3[6] as "A3 Jun", m_a3[7] as "A3 Jul", m_a3[8] as "A3 Ago", m_a3[9] as "A3 Set", m_a3[10] as "A3 Oct", m_a3[11] as "A3 Nov", m_a3[12] as "A3 Dic", total_a3 as "A3 Total",
 case when estado = 'DEMANDA ADICIONAL' then 'NO PRIORIZADA' else estado end as "Estado", origen as "Origen", actualizado as "Actualizado", actualizado_por as "Actualizado por"
from poi.pm3_recurso order by id_rec;

create or replace view poi.x_saldos as
select periodo as "Periodo", llave as "Llave", id_ao as "ID_AO", cu_efp as "CU_EFP", centro_costo as "Centro de costo", rubro as "Rubro", clasificador as "Clasificador",
 apm_a1 as "APM A1 (S/)", credito as "Crédito NMP (S/)", anulacion as "Anulación NMP (S/)", programado_vigente as "Programado vigente (S/)",
 certificado as "Certificado (S/)", saldo as "Saldo por certificar (S/)", previsto_a2 as "Previsto A2 (S/)", previsto_a3 as "Previsto A3 (S/)"
from poi.saldo_m order by orden, llave;

create or replace view poi.x_nmp as
select periodo as "Periodo", numero as "N° NMP", to_char(fecha, 'DD/MM/YYYY') as "Fecha", centro_costo as "Centro de costo", id_ao as "ID_AO", cu_efp as "CU_EFP", ff as "FF", rubro as "Rubro",
 clasificador as "Clasificador", llave as "Llave", credito as "Crédito (S/)", anulacion as "Anulación (S/)", meta_antes as "Meta física antes", meta_despues as "Meta física después",
 sustento as "Sustento", estado as "Estado", version_poi as "Versión POI resultante", observacion as "Observación", solicitante as "Solicitante",
 resuelto as "Resuelto", resuelto_por as "Resuelto por"
from poi.nmp order by numero, id;

create or replace function poi.exportar(s jsonb, per int) returns jsonb
language plpgsql stable as $$
declare cols jsonb := '{}'; h text; vista text;
begin
  if s ->> 'r' <> 'OPP' then perform poi.falla('Solo OPP puede descargar la base completa.'); end if;
  per := coalesce(per, poi.per_activo());
  foreach h in array array['PA1_AO:x_pa1_ao', 'PA3_Recursos:x_pa3_recursos', 'PM2_Tareas:x_pm2_tareas', 'PM3_Recursos:x_pm3_recursos', 'Saldos_POI:x_saldos', 'NMP_Registro:x_nmp'] loop
    vista := split_part(h, ':', 2);
    cols := cols || jsonb_build_object(split_part(h, ':', 1),
      (select to_jsonb(array_agg(attname order by attnum)) from pg_attribute where attrelid = ('poi.' || vista)::regclass and attnum > 0));
  end loop;
  return jsonb_build_object('ok', true, 'anios', to_jsonb(poi.ys(per)), 'columnas', cols, 'hojas', jsonb_build_array(
    jsonb_build_object('nombre', 'PA1_AO',       'filas', (select coalesce(json_agg(v), '[]')::jsonb from poi.x_pa1_ao v where v."Periodo" = per)),
    jsonb_build_object('nombre', 'PA3_Recursos', 'filas', (select coalesce(json_agg(v), '[]')::jsonb from poi.x_pa3_recursos v where v."Periodo" = per)),
    jsonb_build_object('nombre', 'PM2_Tareas',   'filas', (select coalesce(json_agg(v), '[]')::jsonb from poi.x_pm2_tareas v where v."Periodo" = per)),
    jsonb_build_object('nombre', 'PM3_Recursos', 'filas', (select coalesce(json_agg(v), '[]')::jsonb from poi.x_pm3_recursos v where v."Periodo" = per)),
    jsonb_build_object('nombre', 'Saldos_POI',   'filas', (select coalesce(json_agg(v), '[]')::jsonb from poi.x_saldos v where v."Periodo" = per)),
    jsonb_build_object('nombre', 'NMP_Registro', 'filas', (select coalesce(json_agg(v), '[]')::jsonb from poi.x_nmp v where v."Periodo" = per))
  ));
end $$;

-- ---------- Punto de entrada único para la página ----------
create or replace function public.poi_api(p jsonb) returns jsonb
language plpgsql security definer
set search_path = poi, extensions, public
as $$
declare accion text := coalesce(p ->> 'accion', ''); s jsonb; cc text; det text; r jsonb; per int;
begin
  if accion = 'ping' then return jsonb_build_object('ok', true, 'hora', now()); end if;
  if accion = 'login' then return poi.login(p); end if;
  s := poi.sesion(p ->> 'token');
  cc := s ->> 'cc';
  if s ->> 'r' = 'OPP' then cc := poi.t(p ->> 'cc'); end if;
  per := case when coalesce(p ->> 'periodo', '') ~ '^\d{4}$' then (p ->> 'periodo')::int else null end;
  if accion in ('guardarAO', 'enviarNMP') and coalesce(cc, '') = '' then perform poi.falla('Selecciona un centro de costo.'); end if;
  case accion
    when 'datos' then
      r := poi.datos(s, cc, per);
      if s ->> 'r' = 'OPP' and coalesce(cc, '') = '' then r := r || jsonb_build_object('versiones', poi.versiones((r -> 'periodo' ->> 'anio_ini')::int)); end if;
      return r;
    when 'guardarAO'        then return poi.guardar_ao(s, cc, p);
    when 'enviarNMP'        then return poi.enviar_nmp(s, cc, p);
    when 'resolverNMP'      then return poi.resolver_nmp(s, p);
    when 'cambiarClave'     then return poi.cambiar_clave(s, p);
    when 'restablecerClave' then return poi.restablecer_clave(s, p);
    when 'exportar'         then return poi.exportar(s, per);
    when 'cerrarVersion'    then return poi.cerrar_version(s, p);
    when 'nuevoPeriodo'     then return poi.nuevo_periodo(s, p);
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
