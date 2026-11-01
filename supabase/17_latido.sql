-- 17. Latido: el ping de "Mantener activa la base" lee poi.ao y deja un registro,
-- para que Supabase vea actividad real de base de datos y no pause el proyecto.
create table if not exists poi.latido (fecha timestamptz primary key default clock_timestamp(), aos int);
alter table poi.latido enable row level security;
do $$ declare d text := pg_get_functiondef('public.poi_api(jsonb)'::regprocedure); n text;
begin
  n := replace(d, $a$if accion = 'ping' then return jsonb_build_object('ok', true, 'hora', now()); end if;$a$,
    $b$if accion = 'ping' then insert into poi.latido(aos) select count(*) from poi.ao; return jsonb_build_object('ok', true, 'hora', now(), 'aos', (select count(*) from poi.ao)); end if;$b$);
  if n = d then raise exception 'no aplicó'; end if;
  execute n;
end $$;
