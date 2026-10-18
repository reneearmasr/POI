-- =====================================================================
-- POI 2027 – ATU · Portal de áreas usuarias
-- 01 · Esquema de base de datos (Supabase / PostgreSQL)
-- Pegar completo en Supabase → SQL Editor → Run.
-- Las tablas viven en el esquema privado "poi" (no expuesto a la web).
-- La página solo puede llamar a la función public.poi_api (archivo 02).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;
create schema if not exists poi;
revoke all on schema poi from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on schema poi from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'revoke all on schema poi from authenticated'; end if;
end $$;

-- ---------- Configuración y usuarios ----------
create table if not exists poi.config (
  clave text primary key,
  valor text not null
);
insert into poi.config (clave, valor) values
  ('secret', encode(extensions.gen_random_bytes(32), 'hex')),
  ('salt', 'ATU-POI-2027'),
  ('sesion_horas', '10')
on conflict (clave) do nothing;

create table if not exists poi.usuario (
  usuario      text primary key,
  nombre       text not null,
  centro_costo text not null,
  organo       text,
  rol          text not null default 'AREA' check (rol in ('AREA', 'OPP')),
  hash         text not null,
  activo       boolean not null default true,
  creado       timestamptz not null default now()
);

-- ---------- PA1 · Actividades operativas (versión inicial APM 2027-2029) ----------
create table if not exists poi.ao (
  id_ao              text primary key,
  orden              int,
  cu_efp             text not null,
  sec_func_2026      text,
  sec_func_2027      text,
  organo             text,
  centro_costo       text not null,
  unidad_organica    text,
  cod_oei            text,
  oei                text,
  cod_aei            text,
  aei                text,
  tipo               text,
  cod_producto       text,
  producto           text,
  programa           text,
  actividad_efp      text,
  funcion            text,
  div_fun            text,
  grp_fun            text,
  finalidad          text,
  nombre_ao          text,
  descripcion        text,
  beneficiarios      text,
  indicador          text,
  medio_verificacion text,
  departamento       text,
  provincia          text,
  distrito           text,
  unidad_medida      text,
  meta_2027          numeric not null default 0,
  meta_2028          numeric not null default 0,
  meta_2029          numeric not null default 0,
  actualizado        timestamptz,
  actualizado_por    text
);
create index if not exists ao_cc on poi.ao (centro_costo);

-- ---------- PA3 · Partidas APM (techo por AO · fuente · clasificador) ----------
create table if not exists poi.partida (
  llave             text primary key,          -- 2027|CU_EFP|rubro|clasificador
  orden             int,
  id_ao             text not null references poi.ao (id_ao),
  cu_efp            text,
  centro_costo      text,
  ff                text,
  rubro             int,
  clasificador      text,
  clasificador_desc text,
  concepto1         text,
  concepto2         text,
  reserva           text,
  apm_2027          numeric not null default 0,
  apm_2028          numeric not null default 0,
  apm_2029          numeric not null default 0,
  meses             numeric[] not null default array_fill(0::numeric, array[12])
);
create index if not exists partida_ao on poi.partida (id_ao);

-- ---------- PM2 · Tareas (programación física mensual 2027-2029) ----------
create table if not exists poi.pm2_tarea (
  id_tarea        text primary key,
  id_ao           text not null references poi.ao (id_ao),
  centro_costo    text,
  codigo          text,
  nombre          text,
  repr            boolean not null default false,
  acum            boolean not null default false,
  um              text,
  m2027           numeric[] not null default array_fill(0::numeric, array[12]),
  m2028           numeric[] not null default array_fill(0::numeric, array[12]),
  m2029           numeric[] not null default array_fill(0::numeric, array[12]),
  total_2027      numeric not null default 0,
  total_2028      numeric not null default 0,
  total_2029      numeric not null default 0,
  estado          text not null default 'ACTIVA',
  origen          text,
  actualizado     timestamptz,
  actualizado_por text,
  propio          boolean not null default false   -- tarea padre con meta puesta por el área (no suma subtareas)
);
create index if not exists pm2_ao on poi.pm2_tarea (id_ao);

-- ---------- PM3 · Recursos (programación financiera mensual 2027-2029) ----------
create table if not exists poi.pm3_recurso (
  id_rec          text primary key,
  id_ao           text not null references poi.ao (id_ao),
  centro_costo    text,
  codigo_tarea    text,
  recurso         text,
  um              text,
  ff              text,
  rubro           text,
  clasificador    text,
  llave           text,
  n_prevision     text,
  cant_2027       text,
  cant_2028       text,
  cant_2029       text,
  m2027           numeric[] not null default array_fill(0::numeric, array[12]),
  m2028           numeric[] not null default array_fill(0::numeric, array[12]),
  m2029           numeric[] not null default array_fill(0::numeric, array[12]),
  total_2027      numeric not null default 0,
  total_2028      numeric not null default 0,
  total_2029      numeric not null default 0,
  estado          text not null default 'ACTIVA',   -- ACTIVA / ELIMINADA / DEMANDA ADICIONAL
  origen          text,                             -- APM / Portal / Importado
  actualizado     timestamptz,
  actualizado_por text
);
create index if not exists pm3_ao on poi.pm3_recurso (id_ao);

-- ---------- Anexos 01-03 NMP ----------
create table if not exists poi.nmp (
  id            bigserial primary key,
  numero        text not null,
  fecha         date not null default (now() at time zone 'America/Lima')::date,
  centro_costo  text,
  id_ao         text,
  cu_efp        text,
  ff            text,
  rubro         int,
  clasificador  text,
  llave         text,
  credito       numeric not null default 0,
  anulacion     numeric not null default 0,
  meta_antes    text,
  meta_despues  text,
  sustento      text,
  estado        text not null default 'EN REVISIÓN OPP',  -- EN REVISIÓN OPP / APROBADO / OBSERVADO
  version_poi   text,
  observacion   text,
  solicitante   text,
  registrado    timestamptz not null default now(),
  resuelto      timestamptz,
  resuelto_por  text
);
create index if not exists nmp_llave on poi.nmp (llave);
create index if not exists nmp_numero on poi.nmp (numero);

-- ---------- Anexo 01 CCP ----------
create table if not exists poi.ccp (
  id            bigserial primary key,
  numero        text,
  fecha         date,
  tipo          text,          -- INICIAL / AMPLIACION
  ccp_amplia    text,
  centro_costo  text,
  id_ao         text,
  cu_efp        text,
  ff            text,
  rubro         int,
  clasificador  text,
  llave         text,
  monto         numeric not null default 0,
  tarea_poi     text,
  justificacion text,
  estado        text,          -- EN REVISIÓN OPP / APROBADO / OBSERVADO
  observacion   text,
  solicitante   text
);
create index if not exists ccp_llave on poi.ccp (llave);

-- ---------- Anexo 02 Previsiones ----------
create table if not exists poi.prevision (
  id                  bigserial primary key,
  numero              text,
  fecha               date,
  centro_costo        text,
  ccp_2027            text,
  llave               text,
  monto_contrato      numeric default 0,
  devengado_2026      numeric default 0,
  certificado_2027    numeric default 0,
  prevision_2028      numeric default 0,
  prevision_2029      numeric default 0,
  prevision_2030      numeric default 0,
  estado              text,
  observacion         text
);
create index if not exists prevision_llave on poi.prevision (llave);

-- ---------- Bitácora ----------
create table if not exists poi.bitacora (
  id      bigserial primary key,
  fecha   timestamptz not null default now(),
  usuario text,
  accion  text,
  detalle text
);
create index if not exists bitacora_u on poi.bitacora (usuario, accion, fecha);

-- ---------- Saldos (equivale a la hoja Saldos_POI; se calcula sola) ----------
create or replace view poi.saldo as
select p.llave, p.orden, p.id_ao, p.cu_efp, p.centro_costo, p.ff, p.rubro, p.clasificador,
       p.apm_2027,
       coalesce(n.cred, 0)                                            as credito,
       coalesce(n.anul, 0)                                            as anulacion,
       p.apm_2027 + coalesce(n.cred, 0) - coalesce(n.anul, 0)         as programado_vigente,
       coalesce(c.cert, 0)                                            as certificado,
       p.apm_2027 + coalesce(n.cred, 0) - coalesce(n.anul, 0) - coalesce(c.cert, 0) as saldo,
       p.apm_2028 + coalesce(v.p28, 0)                                as previsto_2028,
       p.apm_2029 + coalesce(v.p29, 0)                                as previsto_2029
from poi.partida p
left join (select llave, sum(credito) cred, sum(anulacion) anul from poi.nmp where estado = 'APROBADO' group by llave) n on n.llave = p.llave
left join (select llave, sum(monto) cert from poi.ccp where estado = 'APROBADO' group by llave) c on c.llave = p.llave
left join (select llave, sum(prevision_2028) p28, sum(prevision_2029) p29 from poi.prevision where estado = 'APROBADO' group by llave) v on v.llave = p.llave;

-- ---------- Seguridad: nadie entra a las tablas desde la web ----------
alter table poi.config      enable row level security;
alter table poi.usuario     enable row level security;
alter table poi.ao          enable row level security;
alter table poi.partida     enable row level security;
alter table poi.pm2_tarea   enable row level security;
alter table poi.pm3_recurso enable row level security;
alter table poi.nmp         enable row level security;
alter table poi.ccp         enable row level security;
alter table poi.prevision   enable row level security;
alter table poi.bitacora    enable row level security;

-- ---------- Vistas con encabezados del Sheet (para descargas de OPP) ----------
create or replace view poi.v_pa1_ao as
select a.id_ao as "ID_AO", a.cu_efp as "CU_EFP", a.sec_func_2026 as "Sec_func 2026 (ref.)", a.sec_func_2027 as "Sec_func 2027",
 a.organo as "Órgano", a.centro_costo as "Centro de costo", a.unidad_organica as "Unidad orgánica", a.cod_oei as "Cód. OEI", a.oei as "Descripción OEI",
 a.cod_aei as "Cód. AEI", a.aei as "Descripción AEI", a.tipo as "Tipo", a.cod_producto as "Cód. inversión / producto", a.producto as "Descripción producto / proyecto",
 a.programa as "Programa", a.actividad_efp as "Actividad / acción", a.funcion as "Función", a.div_fun as "Div. Fun.", a.grp_fun as "Grp. Fun.", a.finalidad as "Finalidad",
 a.nombre_ao as "Actividad operativa o inversión", a.descripcion as "Descripción de la intervención", a.beneficiarios as "Beneficiarios", a.indicador as "Indicador",
 a.medio_verificacion as "Medio de verificación", a.departamento as "Departamento", a.provincia as "Provincia", a.distrito as "Distrito", a.unidad_medida as "Unidad de medida",
 a.meta_2027 as "Meta física 2027", a.meta_2028 as "Meta física 2028", a.meta_2029 as "Meta física 2029",
 coalesce(t.a27,0) as "APM 2027 (S/)", coalesce(t.a28,0) as "APM 2028 (S/)", coalesce(t.a29,0) as "APM 2029 (S/)", coalesce(t.n,0) as "N° filas PA3",
 a.actualizado as "Actualizado", a.actualizado_por as "Actualizado por"
from poi.ao a left join (select id_ao, sum(apm_2027) a27, sum(apm_2028) a28, sum(apm_2029) a29, count(*) n from poi.partida group by id_ao) t on t.id_ao = a.id_ao
order by a.orden, a.id_ao;

create or replace view poi.v_pa3_recursos as
select p.id_ao as "ID_AO", p.cu_efp as "CU_EFP", p.centro_costo as "Centro de costo", p.ff as "FF", p.rubro as "Rubro", p.clasificador as "Clasificador", p.clasificador_desc as "Clasificador – descripción", p.concepto1 as "Concepto 1", p.concepto2 as "Concepto 2", p.reserva as "Reserva", p.apm_2027 as "APM 2027 (S/)", p.meses[1] as "Ene", p.meses[2] as "Feb", p.meses[3] as "Mar", p.meses[4] as "Abr", p.meses[5] as "May", p.meses[6] as "Jun", p.meses[7] as "Jul", p.meses[8] as "Ago", p.meses[9] as "Set", p.meses[10] as "Oct", p.meses[11] as "Nov", p.meses[12] as "Dic", p.apm_2028 as "APM 2028 (S/)", p.apm_2029 as "APM 2029 (S/)", p.llave as "Llave"
from poi.partida p order by p.orden, p.llave;

create or replace view poi.v_pm2_tareas as
select id_tarea as "ID_TAREA", id_ao as "ID_AO", centro_costo as "Centro de costo", codigo as "Código", nombre as "Actividad / Tarea / Acción", case when repr then 'Sí' else 'No' end as "Repr.", case when acum then 'Sí' else 'No' end as "Acum.", um as "Unidad de medida", m2027[1] as "2027 Ene", m2027[2] as "2027 Feb", m2027[3] as "2027 Mar", m2027[4] as "2027 Abr", m2027[5] as "2027 May", m2027[6] as "2027 Jun", m2027[7] as "2027 Jul", m2027[8] as "2027 Ago", m2027[9] as "2027 Set", m2027[10] as "2027 Oct", m2027[11] as "2027 Nov", m2027[12] as "2027 Dic", total_2027 as "2027 Total", m2028[1] as "2028 Ene", m2028[2] as "2028 Feb", m2028[3] as "2028 Mar", m2028[4] as "2028 Abr", m2028[5] as "2028 May", m2028[6] as "2028 Jun", m2028[7] as "2028 Jul", m2028[8] as "2028 Ago", m2028[9] as "2028 Set", m2028[10] as "2028 Oct", m2028[11] as "2028 Nov", m2028[12] as "2028 Dic", total_2028 as "2028 Total", m2029[1] as "2029 Ene", m2029[2] as "2029 Feb", m2029[3] as "2029 Mar", m2029[4] as "2029 Abr", m2029[5] as "2029 May", m2029[6] as "2029 Jun", m2029[7] as "2029 Jul", m2029[8] as "2029 Ago", m2029[9] as "2029 Set", m2029[10] as "2029 Oct", m2029[11] as "2029 Nov", m2029[12] as "2029 Dic", total_2029 as "2029 Total", estado as "Estado", origen as "Origen", actualizado as "Actualizado", actualizado_por as "Actualizado por"
from poi.pm2_tarea order by id_tarea;

create or replace view poi.v_pm3_recursos as
select id_rec as "ID_REC", id_ao as "ID_AO", centro_costo as "Centro de costo", codigo_tarea as "Código tarea", recurso as "Recurso", um as "Unidad de medida", ff as "FF", rubro as "Rubro", clasificador as "Clasificador", llave as "Llave", n_prevision as "N° previsión", cant_2027 as "Cant 2027", m2027[1] as "2027 Ene", m2027[2] as "2027 Feb", m2027[3] as "2027 Mar", m2027[4] as "2027 Abr", m2027[5] as "2027 May", m2027[6] as "2027 Jun", m2027[7] as "2027 Jul", m2027[8] as "2027 Ago", m2027[9] as "2027 Set", m2027[10] as "2027 Oct", m2027[11] as "2027 Nov", m2027[12] as "2027 Dic", total_2027 as "2027 Total", cant_2028 as "Cant 2028", m2028[1] as "2028 Ene", m2028[2] as "2028 Feb", m2028[3] as "2028 Mar", m2028[4] as "2028 Abr", m2028[5] as "2028 May", m2028[6] as "2028 Jun", m2028[7] as "2028 Jul", m2028[8] as "2028 Ago", m2028[9] as "2028 Set", m2028[10] as "2028 Oct", m2028[11] as "2028 Nov", m2028[12] as "2028 Dic", total_2028 as "2028 Total", cant_2029 as "Cant 2029", m2029[1] as "2029 Ene", m2029[2] as "2029 Feb", m2029[3] as "2029 Mar", m2029[4] as "2029 Abr", m2029[5] as "2029 May", m2029[6] as "2029 Jun", m2029[7] as "2029 Jul", m2029[8] as "2029 Ago", m2029[9] as "2029 Set", m2029[10] as "2029 Oct", m2029[11] as "2029 Nov", m2029[12] as "2029 Dic", total_2029 as "2029 Total", estado as "Estado", origen as "Origen", actualizado as "Actualizado", actualizado_por as "Actualizado por"
from poi.pm3_recurso order by id_rec;

create or replace view poi.v_saldos_poi as
select llave as "Llave", '2027' as "Año", id_ao as "ID_AO", cu_efp as "CU_EFP", centro_costo as "Centro de costo", rubro as "Rubro", clasificador as "Clasificador",
 apm_2027 as "APM 2027 – versión inicial (S/)", credito as "Crédito NMP (S/)", anulacion as "Anulación NMP (S/)", programado_vigente as "Programado vigente (S/)",
 certificado as "Certificado (S/)", saldo as "Saldo por certificar (S/)", previsto_2028 as "Previsto 2028 (S/)", previsto_2029 as "Previsto 2029 (S/)"
from poi.saldo order by orden, llave;

create or replace view poi.v_nmp_registro as
select numero as "N° NMP", to_char(fecha, 'DD/MM/YYYY') as "Fecha", centro_costo as "Centro de costo", id_ao as "ID_AO", cu_efp as "CU_EFP", ff as "FF", rubro as "Rubro",
 clasificador as "Clasificador", llave as "Llave", credito as "Crédito (S/)", anulacion as "Anulación (S/)", meta_antes as "Meta física antes", meta_despues as "Meta física después",
 sustento as "Sustento", estado as "Estado", version_poi as "Versión POI resultante", observacion as "Observación", solicitante as "Solicitante",
 resuelto as "Resuelto", resuelto_por as "Resuelto por"
from poi.nmp order by numero, id;
