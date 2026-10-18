-- =====================================================================
-- POI – ATU · 10 · Historial de cambios
-- Registra automáticamente (por triggers) cada dato que cambia en
-- PM1 (ao), APM (partida), PM2 (pm2_tarea), PM3 (pm3_recurso) y NMP:
-- quién, cuándo, con qué acción, valor anterior y valor nuevo.
-- Ejecutar después de 08b y 09. No borra nada.
-- =====================================================================

create table if not exists poi.historial (
  id           bigserial primary key,
  fecha        timestamptz not null default now(),
  lote         bigint not null default txid_current(),   -- agrupa los cambios de una misma operación
  usuario      text,
  accion       text,
  origen       text,
  centro_costo text,
  periodo      int,
  id_ao        text,
  seccion      text,
  registro     text,
  descripcion  text,
  operacion    text,      -- Nuevo / Cambio / Evento
  campo        text,
  antes        text,
  despues      text
);
create index if not exists historial_fecha on poi.historial (fecha desc);
create index if not exists historial_cc    on poi.historial (centro_costo, fecha desc);
create index if not exists historial_lote  on poi.historial (lote);
alter table poi.historial enable row level security;

-- Nombre legible de cada dato (null = no se registra: campos técnicos o calculados)
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

-- Valor legible
create or replace function poi.hist_val(k text, j jsonb) returns text
language sql immutable as $$
  select case
    when j is null or jsonb_typeof(j) = 'null' then ''
    when jsonb_typeof(j) = 'boolean' then case when j::text = 'true' then 'Sí' else 'No' end
    when k = 'estado' then case j #>> '{}' when 'ACTIVA' then 'Activa' when 'ELIMINADA' then 'Eliminada'
                                           when 'DEMANDA ADICIONAL' then 'No priorizada' else j #>> '{}' end
    when jsonb_typeof(j) in ('array', 'object') then j::text
    else j #>> '{}'
  end
$$;

create or replace function poi.tg_historial() returns trigger
language plpgsql as $$
declare
  o   jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) else null end;
  n   jsonb := to_jsonb(new);
  usr text  := coalesce(nullif(current_setting('poi.usuario', true), ''), 'Carga directa');
  acc text  := coalesce(nullif(current_setting('poi.accion', true), ''), 'directo');
  per int;
  sec text; reg text; des text; nue text := '';
  k text; lbl text; i int;
  mes text[] := array['Ene','Feb','Mar','Abr','May','Jun','Jul','Ago','Set','Oct','Nov','Dic'];
begin
  if acc = 'nuevoPeriodo' then return null; end if;   -- la copia al nuevo periodo se registra como un solo evento
  per := coalesce(nullif(n ->> 'periodo', '')::int, poi.per_activo());
  case tg_table_name
    when 'ao' then
      sec := 'PM1 · Ficha'; reg := n ->> 'id_ao'; des := n ->> 'nombre_ao';
    when 'partida' then
      sec := 'APM'; reg := n ->> 'llave'; des := coalesce(n ->> 'clasificador', '') || ' · FF ' || split_part(coalesce(n ->> 'ff', ''), '-', 1);
      nue := 'Techo ' || per || ': S/ ' || coalesce(n ->> 'apm_a1', '0');
    when 'pm2_tarea' then
      sec := 'PM2 · Tareas'; reg := n ->> 'id_tarea'; des := coalesce(n ->> 'codigo', '') || ' ' || coalesce(n ->> 'nombre', '');
      nue := 'Meta ' || per || ': ' || coalesce(n ->> 'total_a1', '0') || ' ' || coalesce(n ->> 'um', '');
    when 'pm3_recurso' then
      sec := 'PM3 · Recursos'; reg := n ->> 'id_rec';
      des := coalesce(n ->> 'recurso', '') || ' (tarea ' || coalesce(n ->> 'codigo_tarea', '') || ', ' || coalesce(n ->> 'clasificador', '') || ')';
      nue := case when n ->> 'estado' = 'DEMANDA ADICIONAL' then 'No priorizada · ' else '' end || per || ': S/ ' || coalesce(n ->> 'total_a1', '0');
    when 'nmp' then
      sec := 'NMP'; reg := n ->> 'numero'; des := coalesce(n ->> 'clasificador', '') || ' · FF ' || split_part(coalesce(n ->> 'ff', ''), '-', 1);
      nue := 'Crédito S/ ' || coalesce(n ->> 'credito', '0') || ' · Anulación S/ ' || coalesce(n ->> 'anulacion', '0');
    else sec := tg_table_name; reg := ''; des := '';
  end case;

  if tg_op = 'INSERT' then
    insert into poi.historial (usuario, accion, origen, centro_costo, periodo, id_ao, seccion, registro, descripcion, operacion, campo, antes, despues)
    values (usr, acc, n ->> 'origen', n ->> 'centro_costo', per, n ->> 'id_ao', sec, reg, des, 'Nuevo', null, null, nue);
    return null;
  end if;

  for k in select jsonb_object_keys(n) loop
    continue when (o -> k) is not distinct from (n -> k);
    lbl := poi.hist_campo(k, per);
    continue when lbl is null;
    continue when jsonb_typeof(o -> k) = 'number' and jsonb_typeof(n -> k) = 'number' and (o ->> k)::numeric = (n ->> k)::numeric;
    if jsonb_typeof(n -> k) = 'array' or jsonb_typeof(o -> k) = 'array' then
      for i in 1..greatest(coalesce(jsonb_array_length(case when jsonb_typeof(n -> k) = 'array' then n -> k end), 0),
                           coalesce(jsonb_array_length(case when jsonb_typeof(o -> k) = 'array' then o -> k end), 0)) loop
        if (o -> k -> (i - 1)) is distinct from (n -> k -> (i - 1))
           and coalesce((o -> k ->> (i - 1))::numeric, 0) is distinct from coalesce((n -> k ->> (i - 1))::numeric, 0) then
          insert into poi.historial (usuario, accion, origen, centro_costo, periodo, id_ao, seccion, registro, descripcion, operacion, campo, antes, despues)
          values (usr, acc, n ->> 'origen', n ->> 'centro_costo', per, n ->> 'id_ao', sec, reg, des, 'Cambio',
                  lbl || ' ' || coalesce(mes[i], i::text), coalesce(o -> k ->> (i - 1), '0'), coalesce(n -> k ->> (i - 1), '0'));
        end if;
      end loop;
    else
      insert into poi.historial (usuario, accion, origen, centro_costo, periodo, id_ao, seccion, registro, descripcion, operacion, campo, antes, despues)
      values (usr, acc, n ->> 'origen', n ->> 'centro_costo', per, n ->> 'id_ao', sec, reg, des, 'Cambio',
              lbl, poi.hist_val(k, o -> k), poi.hist_val(k, n -> k));
    end if;
  end loop;
  return null;
end $$;

create or replace trigger historial_ao  after insert or update on poi.ao          for each row execute function poi.tg_historial();
create or replace trigger historial_par after insert or update on poi.partida     for each row execute function poi.tg_historial();
create or replace trigger historial_pm2 after insert or update on poi.pm2_tarea   for each row execute function poi.tg_historial();
create or replace trigger historial_pm3 after insert or update on poi.pm3_recurso for each row execute function poi.tg_historial();
create or replace trigger historial_nmp after insert or update on poi.nmp         for each row execute function poi.tg_historial();

-- Eventos que no son cambios de una fila (versiones, periodos, contraseñas)
create or replace function poi.hist_evento(usr text, acc text, cc text, per int, des text) returns void
language sql as $$
  insert into poi.historial (usuario, accion, centro_costo, periodo, seccion, descripcion, operacion)
  values (usr, acc, nullif(cc, ''), per, 'Sistema', des, 'Evento');
$$;

-- Filtro del historial según rol, área, periodo, fechas, usuario y texto
create or replace function poi.hist_filtro(s jsonb, cc text, per int, p jsonb) returns setof poi.historial
language sql stable as $$
  select h.* from poi.historial h
   where (h.periodo = per or h.periodo is null)
     and case when s ->> 'r' = 'OPP' then coalesce(cc, '') = '' or h.centro_costo = cc
              else h.centro_costo = cc or (h.centro_costo is null and h.usuario = s ->> 'u') end
     and (coalesce(p ->> 'desde', '') !~ '^\d{4}-\d{2}-\d{2}$' or h.fecha >= ((p ->> 'desde')::date::timestamp at time zone 'America/Lima'))
     and (coalesce(p ->> 'hasta', '') !~ '^\d{4}-\d{2}-\d{2}$' or h.fecha < (((p ->> 'hasta')::date + 1)::timestamp at time zone 'America/Lima'))
     and (poi.t(p ->> 'usuario', 60) = '' or h.usuario = poi.t(p ->> 'usuario', 60))
     and (poi.t(p ->> 'q', 100) = '' or lower(concat_ws(' ', h.usuario, h.id_ao, h.centro_costo, h.registro, h.descripcion, h.campo, h.antes, h.despues, h.seccion))
                                         like '%' || lower(poi.t(p ->> 'q', 100)) || '%')
$$;

-- Consulta del historial (agrupado por operación; o plano para Excel con todo = true)
create or replace function poi.historial(s jsonb, cc text, per int, p jsonb) returns jsonb
language plpgsql stable as $$
declare
  off  int := greatest(coalesce(nullif(p ->> 'desde_n', '')::int, 0), 0);
  lim  int := 30;
  res  jsonb;
begin
  if per is null then per := poi.per_activo(); end if;
  if coalesce((p ->> 'todo')::boolean, false) then
    return jsonb_build_object('ok', true, 'filas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'Fecha', to_char(h.fecha at time zone 'America/Lima', 'DD/MM/YYYY HH24:MI:SS'), 'Usuario', h.usuario, 'Acción', h.accion,
               'Origen', h.origen, 'Centro de costo', h.centro_costo, 'Actividad', h.id_ao, 'Sección', h.seccion, 'Registro', h.registro,
               'Descripción', h.descripcion, 'Operación', h.operacion, 'Dato', h.campo, 'Antes', h.antes, 'Después', h.despues
             ) order by h.fecha desc, h.id)
        from (select * from poi.hist_filtro(s, cc, per, p) order by fecha desc, id limit 20000) h), '[]'::jsonb));
  end if;

  with f as materialized (select * from poi.hist_filtro(s, cc, per, p)),
  l as (select lote, max(fecha) f from f group by lote order by max(fecha) desc, lote desc offset off limit lim + 1)
  select jsonb_build_object(
    'ok', true,
    'mas', (select count(*) from l) > lim,
    'usuarios', coalesce((select jsonb_agg(distinct usuario) from f), '[]'::jsonb),
    'lotes', coalesce((
      select jsonb_agg(x order by x.f desc, x.lote desc) from (
        select l.lote, l.f,
               to_char(l.f at time zone 'America/Lima', 'DD/MM/YYYY HH24:MI') as fecha,
               (select min(h.usuario) from f h where h.lote = l.lote) as usuario,
               (select min(u.nombre) from f h join poi.usuario u on u.usuario = h.usuario where h.lote = l.lote) as nombre,
               (select min(h.accion) from f h where h.lote = l.lote) as accion,
               (select max(h.origen) from f h where h.lote = l.lote) as origen,
               (select coalesce(jsonb_agg(distinct h.centro_costo), '[]') from f h where h.lote = l.lote and h.centro_costo is not null) as centros,
               (select coalesce(jsonb_agg(distinct h.id_ao), '[]') from f h where h.lote = l.lote and h.id_ao is not null) as aos,
               (select count(*) from f h where h.lote = l.lote) as n,
               (select count(*) from f h where h.lote = l.lote and h.operacion = 'Nuevo') as nuevos,
               (select count(*) from f h where h.lote = l.lote and h.operacion = 'Cambio') as cambios_n,
               (select coalesce(jsonb_agg(jsonb_build_object('s', c.seccion, 'r', c.registro, 'd', c.descripcion, 'o', c.operacion,
                                                             'c', c.campo, 'a', c.antes, 'v', c.despues, 'ao', c.id_ao) order by c.id), '[]')
                  from (select * from f h where h.lote = l.lote order by h.id limit 400) c) as det
          from (select * from l order by f desc, lote desc limit lim) l
      ) x), '[]'::jsonb)
  ) into res;
  return res;
end $$;

-- Registros previos al historial (de la bitácora): quedan como eventos, sin detalle de valores
insert into poi.historial (fecha, lote, usuario, accion, origen, centro_costo, periodo, id_ao, seccion, registro, descripcion, operacion)
select b.fecha, -b.id, b.usuario, b.accion,
       case when b.accion = 'guardarAO' then split_part(b.detalle, ' · ', 2) end,
       coalesce(a.centro_costo, case when b.accion = 'enviarNMP' then split_part(b.detalle, ' · ', 2) end,
                (select min(n.centro_costo) from poi.nmp n where b.accion = 'resolverNMP' and n.numero = split_part(b.detalle, ' → ', 1))),
       coalesce(a.periodo, (select min(n.periodo) from poi.nmp n where n.numero = split_part(split_part(b.detalle, ' · ', 1), ' → ', 1)), poi.per_activo()),
       a.id_ao,
       case when b.accion like '%NMP' then 'NMP' when b.accion = 'guardarAO' then 'Actividad' else 'Sistema' end,
       case when b.accion like '%NMP' then split_part(split_part(b.detalle, ' · ', 1), ' → ', 1) end,
       b.detalle || ' (registro anterior al historial: sin detalle de valores)', 'Evento'
  from poi.bitacora b
  left join poi.ao a on b.accion = 'guardarAO' and a.id_ao = split_part(b.detalle, ' · ', 1)
 where b.accion in ('guardarAO', 'enviarNMP', 'resolverNMP', 'cerrarVersion', 'nuevoPeriodo')
   and b.fecha < coalesce((select min(h.fecha) from poi.historial h where h.lote > 0), now())
   and not exists (select 1 from poi.historial h where h.lote = -b.id);

-- ---------- Punto de entrada único (agrega historial y el usuario en sesión para los triggers) ----------
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
  perform set_config('poi.usuario', coalesce(s ->> 'u', ''), true), set_config('poi.accion', accion, true);
  if accion in ('guardarAO', 'enviarNMP') and coalesce(cc, '') = '' then perform poi.falla('Selecciona un centro de costo.'); end if;
  case accion
    when 'datos' then
      r := poi.datos(s, cc, per);
      if s ->> 'r' = 'OPP' and coalesce(cc, '') = '' then r := r || jsonb_build_object('versiones', poi.versiones((r -> 'periodo' ->> 'anio_ini')::int)); end if;
      return r;
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
        perform poi.hist_evento(s ->> 'u', accion, null, coalesce(per, poi.per_activo()), 'Cerró la versión "' || poi.t(p ->> 'nombre', 120) || '"');
      end if;
      return r;
    when 'nuevoPeriodo'     then
      r := poi.nuevo_periodo(s, p);
      if coalesce((r ->> 'ok')::boolean, false) then
        perform poi.hist_evento(s ->> 'u', accion, null, (p ->> 'anio_ini')::int,
          'Abrió el periodo ' || (p ->> 'anio_ini') || '–' || ((p ->> 'anio_ini')::int + 2) || ' (copió actividades y programación; cerró el periodo anterior)');
      end if;
      return r;
    when 'historial'        then
      if s ->> 'r' <> 'OPP' and coalesce(cc, '') = '' then perform poi.falla('Tu usuario no tiene centro de costo.'); end if;
      return poi.historial(s, cc, per, p);
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
