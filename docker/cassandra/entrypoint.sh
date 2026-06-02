#!/bin/bash
# Wrapper del entrypoint oficial de Cassandra.
# Arranca el daemon, espera a que acepte conexiones CQL y aplica el esquema
# WebHardMon una sola vez (marca /var/lib/cassandra/.webhardmon_init).
# Idempotente: si el marker existe, salta el init aunque el contenedor se reinicie.
set -euo pipefail

INIT_MARKER="/var/lib/cassandra/.webhardmon_init"
INIT_CQL="/docker-cassandra-init/webhardmon.cql"

# Arrancar Cassandra en background con el entrypoint original.
/usr/local/bin/docker-entrypoint.sh cassandra -f &
CASS_PID=$!

echo "[webhardmon] Esperando a que Cassandra acepte conexiones CQL..."
MAX_WAIT=120  # segundos máximo antes de abortar
elapsed=0
until cqlsh --cqlversion=3.4.6 -e "DESCRIBE keyspaces;" > /dev/null 2>&1; do
    if ! kill -0 "$CASS_PID" 2>/dev/null; then
        echo "[webhardmon] ERROR: el proceso de Cassandra terminó inesperadamente."
        exit 1
    fi
    if [ "$elapsed" -ge "$MAX_WAIT" ]; then
        echo "[webhardmon] ERROR: timeout esperando a Cassandra (${MAX_WAIT}s)."
        exit 1
    fi
    echo "[webhardmon] No listo todavía (${elapsed}s), reintentando en 5s..."
    sleep 5
    elapsed=$((elapsed + 5))
done
echo "[webhardmon] Cassandra lista."

# Aplicar esquema solo en el primer arranque del volumen.
if [ ! -f "$INIT_MARKER" ]; then
    echo "[webhardmon] Aplicando esquema WebHardMon..."
    cqlsh -f "$INIT_CQL"
    touch "$INIT_MARKER"
    echo "[webhardmon] Esquema aplicado."
else
    echo "[webhardmon] Esquema ya aplicado (marker encontrado), omitiendo."
fi

# Pasar el control al proceso de Cassandra.
wait "$CASS_PID"
