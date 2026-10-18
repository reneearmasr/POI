# Scripts de base de datos (orden de instalación desde cero)

1. `01_esquema.sql`, `02_funciones.sql` – versión inicial (años 2027–2029 fijos)
2. carga de datos inicial (no está en el repositorio)
3. `05_panel.sql`, `06_versiones.sql`
4. `08a_multianual_estructura.sql`, `08b_multianual_funciones.sql` – **multianual por periodos** (2027–2029, 2028–2030…). Reemplaza las funciones de 02, 05 y 06.
5. `09_panel_carg.sql` – panel con el techo APM de las actividades ya cargadas (gráfica "Propuesta frente al techo").
6. `10_historial.sql` – **historial de cambios**: triggers en PM1, APM, PM2, PM3 y NMP que guardan quién, cuándo, valor anterior y nuevo; acción `historial` en la API. Reemplaza `poi_api` de 08b (ejecutar siempre después de 08b).
