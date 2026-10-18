-- =====================================================================
-- POI – ATU · 08a · Multianual por periodos (estructura)
-- Cada periodo cubre 3 años: 2027–2029, 2028–2030, 2029–2031…
-- Las columnas de año pasan a ser posiciones del periodo: a1, a2, a3.
-- No borra datos: renombra columnas y agrega el periodo (2027 para lo existente).
-- =====================================================================

create table if not exists poi.periodo (
  anio_ini   int primary key,
  nombre     text not null,
  estado     text not null default 'ACTIVO' check (estado in ('ACTIVO', 'CERRADO')),
  creado     timestamptz not null default now(),
  creado_por text
);
alter table poi.periodo enable row level security;
insert into poi.periodo (anio_ini, nombre, estado) values (2027, 'POI Multianual 2027–2029', 'ACTIVO')
on conflict (anio_ini) do nothing;

-- Renombrar columnas de año fijo a posición del periodo (solo si aún tienen el nombre antiguo)
do $$
declare r record;
begin
  for r in
    select * from (values
      ('ao','meta_2027','meta_a1'), ('ao','meta_2028','meta_a2'), ('ao','meta_2029','meta_a3'),
      ('partida','apm_2027','apm_a1'), ('partida','apm_2028','apm_a2'), ('partida','apm_2029','apm_a3'),
      ('pm2_tarea','m2027','m_a1'), ('pm2_tarea','m2028','m_a2'), ('pm2_tarea','m2029','m_a3'),
      ('pm2_tarea','total_2027','total_a1'), ('pm2_tarea','total_2028','total_a2'), ('pm2_tarea','total_2029','total_a3'),
      ('pm3_recurso','m2027','m_a1'), ('pm3_recurso','m2028','m_a2'), ('pm3_recurso','m2029','m_a3'),
      ('pm3_recurso','total_2027','total_a1'), ('pm3_recurso','total_2028','total_a2'), ('pm3_recurso','total_2029','total_a3'),
      ('pm3_recurso','cant_2027','cant_a1'), ('pm3_recurso','cant_2028','cant_a2'), ('pm3_recurso','cant_2029','cant_a3'),
      ('version_ao','meta_2027','meta_a1'), ('version_ao','meta_2028','meta_a2'), ('version_ao','meta_2029','meta_a3'),
      ('version_partida','apm_2027','apm_a1'), ('version_partida','apm_2028','apm_a2'), ('version_partida','apm_2029','apm_a3'),
      ('version_pm2','m2027','m_a1'), ('version_pm2','m2028','m_a2'), ('version_pm2','m2029','m_a3'),
      ('version_pm2','total_2027','total_a1'), ('version_pm2','total_2028','total_a2'), ('version_pm2','total_2029','total_a3'),
      ('version_pm3','m2027','m_a1'), ('version_pm3','m2028','m_a2'), ('version_pm3','m2029','m_a3'),
      ('version_pm3','total_2027','total_a1'), ('version_pm3','total_2028','total_a2'), ('version_pm3','total_2029','total_a3'),
      ('version_pm3','cant_2027','cant_a1'), ('version_pm3','cant_2028','cant_a2'), ('version_pm3','cant_2029','cant_a3')
    ) as t(tabla, viejo, nuevo)
  loop
    if exists (select 1 from information_schema.columns where table_schema = 'poi' and table_name = r.tabla and column_name = r.viejo) then
      execute format('alter table poi.%I rename column %I to %I', r.tabla, r.viejo, r.nuevo);
    end if;
  end loop;
end $$;

-- Periodo de cada registro (lo existente es 2027–2029)
alter table poi.ao          add column if not exists periodo int not null default 2027 references poi.periodo (anio_ini);
alter table poi.partida     add column if not exists periodo int not null default 2027 references poi.periodo (anio_ini);
alter table poi.pm2_tarea   add column if not exists periodo int not null default 2027 references poi.periodo (anio_ini);
alter table poi.pm3_recurso add column if not exists periodo int not null default 2027 references poi.periodo (anio_ini);
alter table poi.nmp         add column if not exists periodo int not null default 2027 references poi.periodo (anio_ini);
alter table poi.version     add column if not exists periodo int not null default 2027;
alter table poi.version_ao      add column if not exists periodo int;
alter table poi.version_partida add column if not exists periodo int;
alter table poi.version_pm2     add column if not exists periodo int;
alter table poi.version_pm3     add column if not exists periodo int;
create index if not exists ao_periodo  on poi.ao (periodo, centro_costo);
create index if not exists pm2_periodo on poi.pm2_tarea (periodo);
create index if not exists pm3_periodo on poi.pm3_recurso (periodo);
create index if not exists nmp_periodo on poi.nmp (periodo);
