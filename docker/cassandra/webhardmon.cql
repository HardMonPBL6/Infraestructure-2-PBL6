-- WebHardMon — esquema Cassandra (CANÓNICO, alineado con el repo de la app WebHardMon).
-- RF=3: cada dato se replica en los 3 nodos del anillo (sin SPoF).
-- El entrypoint lo aplica una vez al arrancar el primer nodo.
--
-- NOTA: se usa el modelo `mediciones` (no `metricas`): es el que consultan el panel
-- (CassandraTelemetryService), Grafana y el que escribe el servicio Java StressScore.

CREATE KEYSPACE IF NOT EXISTS webhardmon
  WITH replication = {
    'class': 'SimpleStrategy',
    'replication_factor': 3
  }
  AND durable_writes = true;

USE webhardmon;

-- ─── empresas ─────────────────────────────────────────────────────────────────
-- Espejo de la tabla empresa de MySQL (enlaza ambas BBDD por empresa_id).
CREATE TABLE IF NOT EXISTS empresas (
    empresa_id bigint,
    nombre     text,
    PRIMARY KEY (empresa_id)
);

-- ─── ordenadores ────────────────────────────────────────────────────────────
-- Inventario de ordenadores. codigo_licencia traza qué licencia (MySQL) registró
-- la máquina. `nombre` = usuario.nombre_ordenador en MySQL.
CREATE TABLE IF NOT EXISTS ordenadores (
    empresa_id      bigint,
    nombre          text,
    procesador      text,
    ram             text,
    almacenamiento  text,
    ultima_vez      timestamp,
    codigo_licencia text,
    PRIMARY KEY ((empresa_id), nombre)
);

-- ─── mediciones ────────────────────────────────────────────────────────────
-- Serie temporal de telemetría. El servicio Java escribe aquí con stress_score
-- ya calculado. ram/almacenamiento desnormalizados para rankings en Grafana sin JOINs.
CREATE TABLE IF NOT EXISTS mediciones (
    empresa_id      bigint,
    nombre          text,
    ts              timestamp,
    cpu_percent     double,
    ram_percent     double,
    disco_percent   double,
    temperatura     double,
    bateria_percent double,
    stress_score    double,
    ram             text,
    almacenamiento  text,
    PRIMARY KEY ((empresa_id), ts, nombre)
) WITH CLUSTERING ORDER BY (ts DESC, nombre ASC);
