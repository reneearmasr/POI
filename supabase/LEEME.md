# Scripts de base de datos (orden de instalación desde cero)

1. `01_esquema.sql`, `02_funciones.sql` – versión inicial (años 2027–2029 fijos)
2. carga de datos inicial (no está en el repositorio)
3. `05_panel.sql`, `06_versiones.sql`
4. `08a_multianual_estructura.sql`, `08b_multianual_funciones.sql` – **multianual por periodos** (2027–2029, 2028–2030…). Reemplaza las funciones de 02, 05 y 06.
5. `09_panel_carg.sql` – panel con el techo APM de las actividades ya cargadas (gráfica "Propuesta frente al techo").
6. `10_historial.sql` – **historial de cambios**: triggers en PM1, APM, PM2, PM3 y NMP que guardan quién, cuándo, valor anterior y nuevo; acción `historial` en la API. Reemplaza `poi_api` de 08b (ejecutar siempre después de 08b).
7. `11_cmn_ceplan.sql` – **Cuadro Multianual de Necesidades y Guía CEPLAN**: prioridad y ubigeo de la AO, código de ítem SIGA en la PM3, carga del CMN del SIGA (`poi.cmn`), cuadre POI–CMN, Anexo B-4 y CMN del POI. Parchea `guardar_ao` y reemplaza `poi_api` y `poi.panel` (ejecutar después de 10).
8. `12_guia_mejoras.sql` – **mejoras según la guía CEPLAN**: estado del registro por centro de costo (`poi.registro_cc`: en registro → enviado → observado/validado, cerrado), prioridad obligatoria y prelación de lo no priorizado, contenido mínimo del POI (tabla 10), CUI de inversiones y revisión de calidad. Reemplaza `poi_api`, `poi.panel`, `poi.datos_ext` y `poi.anexo_b4` (ejecutar después de 11). El periodo del PEI se guarda en `poi.config` clave `pei_periodo`.
9. `13_pei.sql` – **matriz del PEI 2024-2030 Actualizado** (anexo B-3): OEI/AEI con ruta estratégica, 31 indicadores con línea de base y logros 2024-2030 (`poi.pei_elemento`, `poi.pei_indicador`), `poi.pei_json`, prelación por ruta estratégica y la matriz en `datos_ext` (ejecutar después de 12; re-ejecutable).
10. `14_nmp_anexos.sql` – **NMP con los Anexos 01, 02 y 03 oficiales**: detalle de reprogramación física (`poi.nmp_fisica`) y de recursos (`poi.nmp_recurso`); el Anexo 01 se deriva del Anexo 03; al aprobar, OPP aplica los anexos a la PM2/PM3 del año 1 (con control de cambios posteriores al envío); acción `nmpAnexos` para descargar el Excel. Parchea `guardar_ao` (techo del año 1 = APM + NMP aprobadas), `datos_ext` y `poi_api` (ejecutar después de 13; re-ejecutable).
