# Cassandra — PATRÓN: extender imagen oficial.
# Los recursos (heap topado por co-ubicación) los inyecta el deploy vía env
# (cassandra_max_heap_mb / cassandra_heap_newsize_mb en group_vars). Aquí solo
# va config estática del equipo, si la hay.
# Cassandra 4.1 con inicialización automática del keyspace WebHardMon.
# El entrypoint wrapper espera a que el nodo esté listo y luego aplica el CQL
# una sola vez (idempotente: usa CREATE ... IF NOT EXISTS).
FROM cassandra:4.1

COPY entrypoint.sh /usr/local/bin/webhardmon-entrypoint.sh
COPY webhardmon.cql /docker-cassandra-init/webhardmon.cql

RUN chmod +x /usr/local/bin/webhardmon-entrypoint.sh

EXPOSE 7000 7001 9042

ENTRYPOINT ["/usr/local/bin/webhardmon-entrypoint.sh"]
