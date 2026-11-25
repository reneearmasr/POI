-- =====================================================================
-- 17 · Fuentes del techo presupuestal (25/11/2026)
--   poi.techo_fuente guarda, por etapa (PROYECTO_LEY, LEY, PIA…), el
--   presupuesto oficial por llave CU_EFP | rubro | clasificador, tal como
--   vino del MEF. El techo del año 1 en poi.partida se carga desde aquí con
--   poi.cargar_apm (16): año 1 = monto de la etapa, años 2 y 3 sin cambio.
--   Sirve de referencia para la consistencia POI–PIA.
-- Re-ejecutable.
-- =====================================================================
create table if not exists poi.techo_fuente (
  etapa   text,
  periodo int,
  cu      text,
  rb      int,
  cl      text,
  monto   numeric,
  cargado timestamptz default now(),
  primary key (etapa, periodo, cu, rb, cl)
);
alter table poi.techo_fuente enable row level security;

-- Carga del techo del año 1 desde una etapa (ejemplo: LEY 2027)
-- with l as (select * from poi.techo_fuente where etapa = 'LEY' and periodo = 2027), …
--   filas = partidas del periodo con a1 = monto de la etapa (0 si no figura), a2/a3 sin cambio
--         + llaves de la etapa que no existen como partida (a2/a3 = 0)
--   poi.cargar_apm(s, 2027, {modo: 'vista' | 'aplicar', anio: '2027', filas})
