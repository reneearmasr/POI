-- POI 2027 – ATU · Versiones del POI (p. ej. "Proyecto de Ley 2027") para comparar con el PIA
create table if not exists poi.version (
  id         serial primary key,
  nombre     text not null,
  etapa      text,
  creada     timestamptz not null default now(),
  creada_por text
);
create table if not exists poi.version_ao      (version_id int not null references poi.version (id), like poi.ao);
create table if not exists poi.version_partida (version_id int not null references poi.version (id), like poi.partida);
create table if not exists poi.version_pm2     (version_id int not null references poi.version (id), like poi.pm2_tarea);
create table if not exists poi.version_pm3     (version_id int not null references poi.version (id), like poi.pm3_recurso);
alter table poi.version         enable row level security;
alter table poi.version_ao      enable row level security;
alter table poi.version_partida enable row level security;
alter table poi.version_pm2     enable row level security;
alter table poi.version_pm3     enable row level security;

create or replace function poi.cerrar_version(s jsonb, b jsonb) returns jsonb
language plpgsql as $$
declare v int; v_nom text := poi.t(b ->> 'nombre', 120); v_eta text := coalesce(nullif(poi.t(b ->> 'etapa', 60), ''), 'Proyecto de ley');
begin
  if s ->> 'r' <> 'OPP' then perform poi.falla('Solo OPP puede cerrar versiones.'); end if;
  if length(v_nom) < 3 then perform poi.falla('Escribe un nombre para la versión.'); end if;
  insert into poi.version (nombre, etapa, creada_por) values (v_nom, v_eta, s ->> 'u') returning id into v;
  insert into poi.version_ao      select v, a.* from poi.ao a;
  insert into poi.version_partida select v, p.* from poi.partida p;
  insert into poi.version_pm2     select v, t.* from poi.pm2_tarea t where t.estado <> 'ELIMINADA';
  insert into poi.version_pm3     select v, r.* from poi.pm3_recurso r where r.estado <> 'ELIMINADA';
  insert into poi.bitacora (usuario, accion, detalle) values (s ->> 'u', 'cerrarVersion', v || ' · ' || v_nom);
  return jsonb_build_object('ok', true, 'id', v, 'nombre', v_nom);
end $$;

create or replace function poi.versiones() returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', v.id, 'nombre', v.nombre, 'etapa', coalesce(v.etapa, ''), 'por', coalesce(v.creada_por, ''),
           'fecha', to_char(v.creada at time zone 'America/Lima', 'DD/MM/YYYY HH24:MI'),
           'priorizado_2027', coalesce((select sum(total_2027) from poi.version_pm3 r where r.version_id = v.id and r.estado = 'ACTIVA'), 0),
           'no_priorizado_2027', coalesce((select sum(total_2027) from poi.version_pm3 r where r.version_id = v.id and r.estado = 'DEMANDA ADICIONAL'), 0)
         ) order by v.id desc), '[]')
    from poi.version v
$$;

create or replace function public.poi_api(p jsonb) returns jsonb
language plpgsql security definer
set search_path = poi, extensions, public
as $$
declare accion text := coalesce(p ->> 'accion', ''); s jsonb; cc text; det text; r jsonb;
begin
  if accion = 'ping' then return jsonb_build_object('ok', true, 'hora', now()); end if;
  if accion = 'login' then return poi.login(p); end if;
  s := poi.sesion(p ->> 'token');
  cc := s ->> 'cc';
  if s ->> 'r' = 'OPP' then cc := poi.t(p ->> 'cc'); end if;
  if accion in ('guardarAO', 'enviarNMP') and coalesce(cc, '') = '' then perform poi.falla('Selecciona un centro de costo.'); end if;
  case accion
    when 'datos' then
      r := poi.datos(s, cc);
      if s ->> 'r' = 'OPP' and coalesce(cc, '') = '' then r := r || jsonb_build_object('versiones', poi.versiones()); end if;
      return r;
    when 'guardarAO'        then return poi.guardar_ao(s, cc, p);
    when 'enviarNMP'        then return poi.enviar_nmp(s, cc, p);
    when 'resolverNMP'      then return poi.resolver_nmp(s, p);
    when 'cambiarClave'     then return poi.cambiar_clave(s, p);
    when 'restablecerClave' then return poi.restablecer_clave(s, p);
    when 'exportar'         then return poi.exportar(s);
    when 'cerrarVersion'    then return poi.cerrar_version(s, p);
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
