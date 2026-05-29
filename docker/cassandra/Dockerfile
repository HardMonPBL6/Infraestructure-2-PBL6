# Cassandra — PATRÓN: extender imagen oficial.
# Los recursos (heap topado por co-ubicación) los inyecta el deploy vía env
# (cassandra_max_heap_mb / cassandra_heap_newsize_mb en group_vars). Aquí solo
# va config estática del equipo, si la hay.
FROM cassandra:5.0

# COPY cassandra.yaml /etc/cassandra/cassandra.yaml

EXPOSE 7000 7001 9042
