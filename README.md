# POI 2027 · ATU — Portal de áreas usuarias

Página estática (GitHub Pages) conectada a una base de datos Supabase.

- `index.html` — el portal (PM1/PM2/PM3, NMP, bandeja OPP, importador y descarga Excel).
- `config.js` — dirección del proyecto Supabase y clave pública.
- `supabase/01_esquema.sql`, `supabase/02_funciones.sql` — estructura y reglas de negocio de la base.
- `.github/workflows/mantener-activa.yml` — consulta la base cada 3 días para que el plan gratuito no la pause.

Los datos (AO, partidas APM, programación) y los usuarios **no** están en este repositorio: viven solo en Supabase.
