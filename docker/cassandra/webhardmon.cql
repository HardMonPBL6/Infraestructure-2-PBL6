-- WebHardMon — esquema Cassandra
-- RF=3: cada dato se replica en los 3 nodos del anillo (sin SPoF).
-- El entrypoint lo aplica una vez al arrancar el primer nodo.

CREATE KEYSPACE IF NOT EXISTS webhardmon
  WITH replication = {
    'class': 'SimpleStrategy',
    'replication_factor': 3
  }
  AND durable_writes = true;

USE webhardmon;

-- ─── metricas ────────────────────────────────────────────────────────────────
-- Serie temporal de hardware por ordenador y día.
-- PK: ((empresa_id, ordenador_uuid, fecha), ts DESC)
--   · Partición por empresa + ordenador + día → ~86400 filas/partición (una por segundo).
--   · ts DESC: la consulta "últimas N métricas" es una lectura secuencial eficiente.
-- TTL 30 días: los datos más antiguos expiran automáticamente.

CREATE TABLE IF NOT EXISTS metricas (
    empresa_id     TEXT,
    ordenador_uuid TEXT,
    fecha          DATE,
    ts             TIMESTAMP,
    cpu_uso        FLOAT,
    cpu_temp       FLOAT,
    ram_uso        FLOAT,
    ram_total      FLOAT,
    disco_uso      FLOAT,
    disco_total    FLOAT,
    red_rx         BIGINT,
    red_tx         BIGINT,
    PRIMARY KEY ((empresa_id, ordenador_uuid, fecha), ts)
) WITH CLUSTERING ORDER BY (ts DESC)
   AND default_time_to_live = 2592000
   AND comment = 'Serie temporal de métricas de hardware — TTL 30 días';

-- ─── metricas_ultimo ─────────────────────────────────────────────────────────
-- Caché del último valor conocido por ordenador.
-- Usado por el dashboard "live": una sola lectura por (empresa, ordenador).
-- Sin TTL: se sobreescribe con cada nueva muestra (UPSERT).

CREATE TABLE IF NOT EXISTS metricas_ultimo (
    empresa_id     TEXT,
    ordenador_uuid TEXT,
    ts             TIMESTAMP,
    cpu_uso        FLOAT,
    cpu_temp       FLOAT,
    ram_uso        FLOAT,
    ram_total      FLOAT,
    disco_uso      FLOAT,
    disco_total    FLOAT,
    red_rx         BIGINT,
    red_tx         BIGINT,
    PRIMARY KEY (empresa_id, ordenador_uuid)
) WITH comment = 'Último valor conocido por ordenador — caché para dashboard live';
