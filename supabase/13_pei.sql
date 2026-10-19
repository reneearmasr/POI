-- =====================================================================
-- POI – ATU · 13 · Matriz del PEI 2024-2030 Actualizado (anexo B-3)
-- OEI y AEI con su prioridad en la ruta estratégica, indicadores, línea de base
-- y logros esperados 2024-2030. Fuente: PEI 2024-2030 Actualizado de la ATU (abril 2026).
-- Ejecutar después de 12_guia_mejoras.sql. No borra datos (re-ejecutable).
-- =====================================================================

create table if not exists poi.pei_elemento (
  codigo      text primary key,          -- OEI.01, AEI.01.01
  tipo        text not null check (tipo in ('OEI', 'AEI')),
  oei         text not null,
  descripcion text not null,
  prioridad   int,                        -- ruta estratégica (OEI: entre OEI; AEI: dentro de su OEI)
  responsable text,
  pgg         text
);
create table if not exists poi.pei_indicador (
  codigo      text not null references poi.pei_elemento (codigo),
  orden       int  not null,
  nombre      text not null,
  linea_anio  int,
  linea_valor text,
  logros      jsonb not null default '{}',  -- {"2024": "63.00%", ...}
  responsable text,
  primary key (codigo, orden)
);
alter table poi.pei_elemento  enable row level security;
alter table poi.pei_indicador enable row level security;

insert into poi.pei_elemento (codigo, tipo, oei, descripcion, prioridad, responsable, pgg) values
 ('OEI.01', 'OEI', 'OEI.01', 'Mejorar los servicios del Sistema Integrado de Transporte urbano en Lima y Callao', 1, 'Dirección de Operaciones', 'EJE.2 LIN.2.2'),
 ('OEI.02', 'OEI', 'OEI.02', 'Mejorar la infraestructura del Sistema Integrado de Transporte urbano en Lima y Callao', 2, 'Dirección de Integración de Transporte Urbano y Recaudo', 'EJE.2 LIN.2.2'),
 ('OEI.03', 'OEI', 'OEI.03', 'Fortalecer la gestión institucional', 3, 'Oficina de Planeamiento y Presupuesto', 'EJE.2 LIN.2.2'),
 ('OEI.04', 'OEI', 'OEI.04', 'Promover la Gestión del Riesgo de Desastres', 4, 'Oficina de Procesos y Gestión de Riesgos', 'EJE.2 LIN.2.1'),
 ('AEI.01.01', 'AEI', 'OEI.01', 'Sistema del Metro operativo en Lima y Callao', 2, 'Dirección de Operaciones', 'EJE.2 LIN.2.2'),
 ('AEI.01.02', 'AEI', 'OEI.01', 'Servicios de transporte regular de buses habilitados en Lima y Callao', 1, 'Dirección de Operaciones', 'EJE.2 LIN.2.2'),
 ('AEI.01.03', 'AEI', 'OEI.01', 'Servicios de transporte especial habilitados en Lima y Callao', 3, 'Dirección de Operaciones', 'EJE.2 LIN.2.2'),
 ('AEI.01.04', 'AEI', 'OEI.01', 'Sistema de recaudo único del transporte público urbano masivo implementado en Lima y Callao', 5, 'Dirección de Integración de Transporte Urbano y Recaudo', 'EJE.2 LIN.2.2'),
 ('AEI.01.05', 'AEI', 'OEI.01', 'Cumplimiento efectivo de la normatividad de transporte urbano de personas de Lima y Callao', 4, 'Dirección de Fiscalización y Sanción', 'EJE.1 LIN.1.1'),
 ('AEI.01.06', 'AEI', 'OEI.01', 'Programa de fortalecimiento de conocimientos y capacidades de usuarios, operadores y sociedad civil acerca del Sistema Integrado de Transporte urbano implementado en Lima y Callao', 7, 'Dirección de Gestión Comercial', 'EJE.2 LIN.2.2'),
 ('AEI.01.07', 'AEI', 'OEI.01', 'Instrumentos de planificación y regulación del Sistema Integrado de Transporte articulado con el desarrollo urbano de Lima y Callao', 6, 'Dirección de Integración de Transporte Urbano y Recaudo', 'EJE.2 LIN.2.2'),
 ('AEI.01.08', 'AEI', 'OEI.01', 'Mecanismos de movilidad ambientalmente sostenible implementados en el Sistema Integrado de Transporte de Lima y Callao', 8, 'Dirección de Asuntos Ambientales y Sociales', 'EJE.2 LIN.2.2'),
 ('AEI.01.09', 'AEI', 'OEI.01', 'Medidas con enfoque de género implementadas en el Sistema Integrado de Transporte Urbano de Lima y Callao', 10, 'Dirección de Asuntos Ambientales y Sociales', 'EJE.2 LIN.2.2'),
 ('AEI.01.10', 'AEI', 'OEI.01', 'Mecanismos implementados para prevenir conflictos sociales asociados al transporte urbano de Lima y Callao', 9, 'Dirección de Asuntos Ambientales y Sociales', 'EJE.2 LIN.2.2'),
 ('AEI.02.01', 'AEI', 'OEI.02', 'Infraestructura de transporte e infraestructura complementaria implementada del Sistema Integrado de Transporte urbano en Lima y Callao', 1, 'Dirección de Infraestructura', 'EJE.2 LIN.2.2'),
 ('AEI.03.01', 'AEI', 'OEI.03', 'Gestión administrativa fortalecida en la ATU', 1, 'Oficina de Planeamiento y Presupuesto', 'EJE.2 LIN.2.2'),
 ('AEI.03.02', 'AEI', 'OEI.03', 'Modelo de integridad y lucha contra la corrupción implementado en la ATU', 4, 'Oficina de Integridad y Lucha contra la Corrupción', 'EJE.2 LIN.2.2'),
 ('AEI.03.03', 'AEI', 'OEI.03', 'Gestión por procesos y riesgos implementada en la ATU', 2, 'Oficina de Procesos y Gestión de Riesgos', 'EJE.2 LIN.2.2'),
 ('AEI.03.04', 'AEI', 'OEI.03', 'Gestión de la transformación digital implementada en la ATU', 3, 'Oficina de Administración', 'EJE.2 LIN.2.2'),
 ('AEI.04.01', 'AEI', 'OEI.04', 'Instrumentos implementados para la gestión del riesgo de desastres en la ATU', 1, 'Oficina de Procesos y Gestión de Riesgos', 'EJE.2 LIN.2.1')
on conflict (codigo) do update set tipo = excluded.tipo, oei = excluded.oei, descripcion = excluded.descripcion,
  prioridad = excluded.prioridad, responsable = excluded.responsable, pgg = excluded.pgg;

with d(codigo, orden, nombre, la, lv, l24, l25, l26, l27, l28, l29, l30, resp) as (values
 ('OEI.01', 1, 'Porcentaje de usuarios que manifiestan su satisfacción por los servicios de transporte público urbano en Lima y Callao', 2023, '59.94%', '63.00%', '66.00%', '69.00%', '72.00%', '75.00%', '80.25%', '82.00%', 'Dirección de Operaciones'),
 ('OEI.01', 2, 'Tasa de siniestralidad por cada 100,000 pasajeros del servicio de transporte regular', 2023, '1.57', '1.24', '1.20', '1.16', '1.12', '1.08', '1.04', '1.00', 'Dirección de Operaciones'),
 ('AEI.01.01', 1, 'Promedio diario de viajes anuales realizados en la Red Básica del Metro de Lima y Callao', 2023, '520,000', '614,349', '623,116', '634,269', '645,422', '656,576', '667,729', '678,882', 'Dirección de Operaciones'),
 ('AEI.01.02', 1, 'Número de habilitaciones vehiculares para el servicio de transporte regular de personas', 2023, '5,267', '17,000', '4,200', '4,410', '4,830', '5,460', '6,300', '7,350', 'Dirección de Operaciones'),
 ('AEI.01.02', 2, 'Promedio diario de viajes anuales realizados en los servicios de transporte regular masivo', 2023, '693,777', '758,056', '822,335', '886,614', '950,893', '1,015,172', '1,079,451', '1,143,730', 'Dirección de Operaciones'),
 ('AEI.01.03', 1, 'Porcentaje de solicitudes atendidas para la emisión de títulos habilitantes dentro del plazo normado', 2023, '100%', '100%', '100%', '100%', '100%', '100%', '100%', '100%', 'Dirección de Operaciones'),
 ('AEI.01.04', 1, 'Porcentaje de avance en la implementación del Sistema de Recaudo Único', 2021, '2.50%', '30.00%', '90.00%', '95.00%', '98.00%', '98.00%', '98.00%', '100.00%', 'Dirección de Integración de Transporte Urbano y Recaudo'),
 ('AEI.01.05', 1, 'Tasa de variación de las acciones de fiscalización a los operadores del SIT', 2022, '-47.7%', '0.50%', '0.75%', '1.00%', '1.25%', '1.50%', '1.75%', '2.00%', 'Dirección de Fiscalización y Sanción'),
 ('AEI.01.05', 2, 'Tasa de variación de puntos estratégicos fiscalizados con medios electrónicos', 2022, '-81.03%', '33%', '34%', '35%', '36%', '37%', '38%', '39%', 'Dirección de Fiscalización y Sanción'),
 ('AEI.01.05', 3, 'Porcentaje de infracciones detectadas y tramitadas mediante Proceso Administrativo Sancionador que alcanzan resolución de sanción o pago', 2023, '30.9%', '33.0%', '35.0%', '37.0%', '39.0%', '41.0%', '43.0%', '45.0%', 'Dirección de Fiscalización y Sanción'),
 ('AEI.01.05', 4, 'Porcentaje de expedientes para Procedimiento Administrativo Sancionador con sanción firme evaluados para inicio del Procedimiento de Ejecución Coactiva', 2023, '86.13%', '88.00%', '90.00%', '92.00%', '94.00%', '96.00%', '98.00%', '100.00%', 'Oficina de Administración'),
 ('AEI.01.06', 1, 'Número de asistencias técnicas en obligaciones, derechos, normativa, TUPA, autorizaciones realizadas', 2023, '253', '301', '349', '396', '444', '492', '540', '588', 'Dirección de Gestión Comercial'),
 ('AEI.01.06', 2, 'Número de asistencias técnicas en temas de accesibilidad realizadas', 2023, '23', '27', '32', '36', '40', '45', '49', '53', 'Dirección de Gestión Comercial'),
 ('AEI.01.06', 3, 'Número de asistencias técnicas en temas de género realizadas', 2023, '6', '7', '8', '9', '10', '11', '12', '13', 'Dirección de Gestión Comercial'),
 ('AEI.01.06', 4, 'Número de asistencias técnicas en temas de seguridad vial realizadas', 2023, '99', '118', '136', '155', '174', '193', '211', '230', 'Dirección de Gestión Comercial'),
 ('AEI.01.07', 1, 'Porcentaje de instrumentos de planificación y regulación del Sistema Integrado de Transporte de Lima y Callao aprobados', 2023, '31.25%', '43.75%', '56.25%', '62.50%', '75.00%', '81.25%', '87.50%', '100.00%', 'Dirección de Integración de Transporte Urbano y Recaudo'),
 ('AEI.01.08', 1, 'Porcentaje de mecanismos de difusión sobre cicloparqueaderos implementados en el Sistema Integrado de Transporte de Lima y Callao', 2025, '100%', '-', '-', '100%', '100%', '100%', '100%', '100%', 'Dirección de Asuntos Ambientales y Sociales'),
 ('AEI.01.08', 2, 'Número de vehículos chatarreados con valorización realizada', 2023, '37', '100', '120', '120', '120', '120', '120', '120', 'Dirección de Asuntos Ambientales y Sociales'),
 ('AEI.01.09', 1, 'Porcentaje de acciones de gestión social con enfoque de género implementadas en el Sistema Integrado de Transporte Urbano de Lima y Callao', 2025, '100%', '-', '-', '100%', '100%', '100%', '100%', '100%', 'Dirección de Asuntos Ambientales y Sociales'),
 ('AEI.01.10', 1, 'Porcentaje de medidas para prevenir conflictos sociales asociados al transporte urbano implementados', 2023, '79.90%', '80.88%', '82.11%', '84.07%', '86.03%', '88.24%', '90.20%', '92.16%', 'Dirección de Asuntos Ambientales y Sociales'),
 ('OEI.02', 1, 'Porcentaje de viajes de pasajeros atendidos por el transporte urbano público masivo en vías exclusivas', 2023, '7.50%', '8.63%', '9.11%', '9.60%', '10.09%', '10.59%', '11.08%', '11.57%', 'Dirección de Integración de Transporte Urbano y Recaudo'),
 ('AEI.02.01', 1, 'Porcentaje de ejecución de obra de los proyectos del SIT', 2023, '8.29%', '9.90%', '10.88%', '11.87%', '18.11%', '36.77%', '36.86%', '48.97%', 'Dirección de Infraestructura'),
 ('OEI.03', 1, 'Índice de efectividad de la gestión institucional', 2023, '0.9906', '0.9850', '0.9850', '0.9850', '0.9850', '0.9850', '0.9850', '0.9850', 'Oficina de Planeamiento y Presupuesto'),
 ('AEI.03.01', 1, 'Porcentaje de instrumentos de gestión de planeamiento y presupuesto aprobados oportunamente', 2023, '100%', '100%', '100%', '100%', '100%', '100%', '100%', '100%', 'Oficina de Planeamiento y Presupuesto'),
 ('AEI.03.02', 1, 'Porcentaje de metas del Programa de Integridad de la ATU implementadas', 2023, '100%', '100%', '100%', '100%', '100%', '100%', '100%', '100%', 'Oficina de Integridad y Lucha contra la Corrupción'),
 ('AEI.03.02', 2, 'Porcentaje de Objetivos Antisoborno del Sistema de Gestión Antisoborno de la ATU que alcanzan su meta', 2023, '100%', '100%', '100%', '100%', '100%', '100%', '100%', '100%', 'Oficina de Integridad y Lucha contra la Corrupción'),
 ('AEI.03.03', 1, 'Porcentaje de mejoras en procesos implementadas', 2023, '100%', '100%', '100%', '100%', '100%', '100%', '100%', '100%', 'Oficina de Procesos y Gestión de Riesgos'),
 ('AEI.03.03', 2, 'Porcentaje de medidas de control de riesgos del Plan de Acción Anual implementadas', 2023, '93.75%', '90%', '90%', '90%', '90%', '90%', '90%', '90%', 'Oficina de Procesos y Gestión de Riesgos'),
 ('AEI.03.04', 1, 'Porcentaje de proyectos del Plan de Gobierno Digital implementados', 2023, '100%', '100%', '100%', '100%', '100%', '100%', '100%', '100%', 'Oficina de Administración'),
 ('OEI.04', 1, 'Porcentaje de acciones del Plan de Trabajo del Grupo de Trabajo para la Gestión del Riesgo de Desastres implementadas', 2023, '100%', '100%', '100%', '100%', '100%', '100%', '100%', '100%', 'Oficina de Procesos y Gestión de Riesgos'),
 ('AEI.04.01', 1, 'Porcentaje de instrumentos para la Gestión del Riesgo de Desastres implementados', 2023, '100%', '100%', '100%', '100%', '100%', '100%', '100%', '100%', 'Oficina de Procesos y Gestión de Riesgos')
)
insert into poi.pei_indicador (codigo, orden, nombre, linea_anio, linea_valor, logros, responsable)
select codigo, orden, nombre, la, lv,
       jsonb_build_object('2024', l24, '2025', l25, '2026', l26, '2027', l27, '2028', l28, '2029', l29, '2030', l30), resp
  from d
on conflict (codigo, orden) do update set nombre = excluded.nombre, linea_anio = excluded.linea_anio, linea_valor = excluded.linea_valor,
  logros = excluded.logros, responsable = excluded.responsable;

-- Matriz del PEI con lo que el POI programa en cada AEI (periodo dado)
create or replace function poi.pei_json(per int) returns jsonb
language sql stable as $$
  with g as (
    select a.cod_aei, count(distinct a.id_ao) aos, count(distinct a.id_ao) filter (where a.actualizado is not null) cargadas,
           jsonb_agg(distinct a.centro_costo) ccs,
           coalesce(sum(r.total_a1) filter (where r.estado = 'ACTIVA'), 0) prio,
           coalesce(sum(r.total_a1) filter (where r.estado = 'DEMANDA ADICIONAL'), 0) nopri
      from poi.ao a left join poi.pm3_recurso r on r.id_ao = a.id_ao and r.estado in ('ACTIVA', 'DEMANDA ADICIONAL')
     where a.periodo = per group by a.cod_aei
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'codigo', e.codigo, 'tipo', e.tipo, 'oei', e.oei, 'descripcion', e.descripcion, 'prioridad', e.prioridad,
           'responsable', e.responsable, 'pgg', e.pgg,
           'aos', coalesce(g.aos, 0), 'cargadas', coalesce(g.cargadas, 0), 'ccs', coalesce(g.ccs, '[]'), 'prio', coalesce(g.prio, 0), 'nopri', coalesce(g.nopri, 0),
           'indicadores', coalesce((select jsonb_agg(jsonb_build_object('nombre', i.nombre, 'linea_anio', i.linea_anio, 'linea_valor', i.linea_valor,
                                                                        'logros', i.logros, 'responsable', i.responsable) order by i.orden)
                                      from poi.pei_indicador i where i.codigo = e.codigo), '[]')
         ) order by e.oei, case when e.tipo = 'OEI' then 0 else 1 end, e.prioridad), '[]')
    from poi.pei_elemento e left join g on g.cod_aei = e.codigo
$$;

-- Prelación: prioridad de la AO, luego la ruta estratégica del PEI (prioridad del OEI y de la AEI)
create or replace function poi.prelacion(per int) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', z.id_ao, 'cc', z.centro_costo, 'nombre', z.nom, 'prioridad', coalesce(z.prioridad, ''),
                                               'oei', coalesce(z.cod_oei, ''), 'aei', coalesce(z.cod_aei, ''), 'ruta', z.ruta,
                                               'nopri', z.nopri, 'acum', z.acum) order by z.ord), '[]')
    from (select a.id_ao, a.centro_costo, coalesce(nullif(a.nombre_ao, ''), a.finalidad) nom, a.prioridad, a.cod_oei, a.cod_aei, d.nopri,
                 coalesce(eo.prioridad::text, '–') || '.' || coalesce(ea.prioridad::text, '–') ruta,
                 row_number() over (order by poi.prio_orden(a.prioridad), coalesce(eo.prioridad, 99), coalesce(ea.prioridad, 99), d.nopri desc, a.id_ao) ord,
                 sum(d.nopri) over (order by poi.prio_orden(a.prioridad), coalesce(eo.prioridad, 99), coalesce(ea.prioridad, 99), d.nopri desc, a.id_ao) acum
            from poi.ao a
            join (select id_ao, sum(total_a1) nopri from poi.pm3_recurso where periodo = per and estado = 'DEMANDA ADICIONAL' group by id_ao having sum(total_a1) > 0) d
              on d.id_ao = a.id_ao
            left join poi.pei_elemento eo on eo.codigo = a.cod_oei
            left join poi.pei_elemento ea on ea.codigo = a.cod_aei
           where a.periodo = per) z
$$;

-- datos_ext: agrega la matriz del PEI (parche sobre la función vigente)
do $$
declare d text; o text;
begin
  d := pg_get_functiondef('poi.datos_ext(jsonb,text,integer)'::regprocedure);
  if position('pei_json' in d) > 0 then raise notice 'datos_ext ya incluye el PEI'; return; end if;
  o := d;
  d := replace(d, $x$return r || jsonb_build_object('calidad', poi.calidad(per),$x$, $x$return r || jsonb_build_object('pei', poi.pei_json(per), 'calidad', poi.calidad(per),$x$);
  if d = o then raise exception 'Parche 1 de datos_ext no aplicó'; end if;
  o := d;
  d := replace(d, $x$return r || jsonb_build_object('aos', aos,$x$, $x$return r || jsonb_build_object('pei', poi.pei_json(per), 'aos', aos,$x$);
  if d = o then raise exception 'Parche 2 de datos_ext no aplicó'; end if;
  execute d;
end $$;
