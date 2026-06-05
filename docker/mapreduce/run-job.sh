#!/bin/bash
# run-job.sh — ENTRYPOINT del contenedor MapReduce de WebHardMon.
# Lanza el job de agregación batch (HDFS Parquet → HBase webhardmon_hourly) en
# modo local. La configuración llega por variables de entorno (las inyecta el
# `docker run` del cron en el CT dedicado, ver roles/mapreduce):
#
#   MR_INPUT        URI HDFS completa de entrada (p.ej. hdfs://10.10.1.21:9000/data/telemetry)
#   MR_HBASE_TABLE  tabla HBase destino           (p.ej. webhardmon_hourly)
#   MR_ZK_QUORUM    quorum ZooKeeper de HBase      (p.ej. 10.0.0.30,10.30.2.11,10.30.2.12)
#   MR_ZK_PORT      puerto ZooKeeper               (opcional, default 2181)
set -euo pipefail

: "${MR_INPUT:?MR_INPUT no definido}"
: "${MR_HBASE_TABLE:?MR_HBASE_TABLE no definido}"
: "${MR_ZK_QUORUM:?MR_ZK_QUORUM no definido}"
MR_ZK_PORT="${MR_ZK_PORT:-2181}"

echo "[webhardmon-mr] input=${MR_INPUT} table=${MR_HBASE_TABLE} zk=${MR_ZK_QUORUM}:${MR_ZK_PORT}"

exec hadoop jar /opt/webhardmon-mr.jar \
  com.webhardmon.mr.MetricsAggregationJob \
  "${MR_INPUT}" \
  "${MR_HBASE_TABLE}" \
  "${MR_ZK_QUORUM}" \
  "${MR_ZK_PORT}"
