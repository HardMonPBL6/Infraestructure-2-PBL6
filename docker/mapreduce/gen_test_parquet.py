#!/usr/bin/env python3
"""
gen_test_parquet.py — genera un fichero Parquet de prueba para el job MapReduce
WebHardMon.

Esquema real leído por MetricsMapper (campos que deben existir):
  empresa_id, nombre, ts, cpu_percent, ram_percent, disco_percent,
  temperatura, bateria_percent, ram, almacenamiento, procesador, stress_score

Row key que escribirá el Reducer en HBase:
  {empresa_id}|{ramGb}|{stoGb}|{yyyyMMddHH}   (ventana UTC de la hora anterior)

Requisitos:
  pip install pyarrow

Uso desde WSL (directorio raíz del repo):
  python3 docker/mapreduce/gen_test_parquet.py

El script imprime al final los comandos exactos para subir el fichero a HDFS y
lanzar el job manualmente.
"""

import datetime
import random
import sys

try:
    import pyarrow as pa
    import pyarrow.parquet as pq
except ImportError:
    print("ERROR: pyarrow no instalado. Ejecuta: pip install pyarrow", file=sys.stderr)
    sys.exit(1)

# ── Parámetros del test ──────────────────────────────────────────────────────
EMPRESA_ID = 1          # empresa_id numérico (long en Parquet)
RAM_GB     = 8.0        # GB de RAM → ramGb=8 en el row key
STO_GB     = 256.0      # GB de almacenamiento → stoGb=256 en el row key
N_RECORDS  = 36         # ~una muestra cada 100 s a lo largo de 1 hora

# Hora a agregar: la hora UTC completa inmediatamente anterior al momento actual.
# El job la reconoce porque ts cae dentro de esa ventana.
now_utc    = datetime.datetime.now(datetime.timezone.utc)
hour_start = now_utc.replace(minute=0, second=0, microsecond=0) - datetime.timedelta(hours=1)
hour_str   = hour_start.strftime("%Y%m%d%H")

expected_row_key = f"{EMPRESA_ID}|{int(round(RAM_GB))}|{int(round(STO_GB))}|{hour_str}"

print(f"Generando {N_RECORDS} registros para empresa_id={EMPRESA_ID}")
print(f"Ventana horaria:   {hour_start.strftime('%Y-%m-%d %H:00')} UTC")
print(f"Row key en HBase:  {expected_row_key}")

# ── Generación de datos ──────────────────────────────────────────────────────
cols = {
    "empresa_id":     [],
    "nombre":         [],
    "ts":             [],
    "cpu_percent":    [],
    "ram_percent":    [],
    "disco_percent":  [],
    "temperatura":    [],
    "bateria_percent":[],
    "ram":            [],
    "almacenamiento": [],
    "procesador":     [],
    "stress_score":   [],
}

rng      = random.Random(42)
interval = 3600 // N_RECORDS  # segundos entre muestras

for i in range(N_RECORDS):
    ts       = int((hour_start + datetime.timedelta(seconds=i * interval)).timestamp() * 1000)
    cpu      = rng.uniform(20.0, 80.0)
    ram_pct  = rng.uniform(30.0, 70.0)
    disco    = rng.uniform(20.0, 60.0)
    tmp      = rng.uniform(35.0, 65.0)
    bat      = rng.uniform(40.0, 100.0)
    # stress_score: réplica simplificada de la fórmula del bridge
    stress   = cpu * 0.4 + ram_pct * 0.3 + tmp * 0.1 + (100.0 - bat) * 0.2

    cols["empresa_id"].append(EMPRESA_ID)
    cols["nombre"].append("test-laptop-01")
    cols["ts"].append(ts)
    cols["cpu_percent"].append(round(cpu,   2))
    cols["ram_percent"].append(round(ram_pct, 2))
    cols["disco_percent"].append(round(disco, 2))
    cols["temperatura"].append(round(tmp,   2))
    cols["bateria_percent"].append(round(bat,   2))
    cols["ram"].append(RAM_GB)
    cols["almacenamiento"].append(STO_GB)
    cols["procesador"].append("Intel Core i5")
    cols["stress_score"].append(round(stress, 2))

# ── Escritura Parquet ────────────────────────────────────────────────────────
schema = pa.schema([
    ("empresa_id",      pa.int64()),
    ("nombre",          pa.string()),
    ("ts",              pa.int64()),
    ("cpu_percent",     pa.float64()),
    ("ram_percent",     pa.float64()),
    ("disco_percent",   pa.float64()),
    ("temperatura",     pa.float64()),
    ("bateria_percent", pa.float64()),
    ("ram",             pa.float64()),
    ("almacenamiento",  pa.float64()),
    ("procesador",      pa.string()),
    ("stress_score",    pa.float64()),
])

table    = pa.table(cols, schema=schema)
out_path = "/tmp/wh_test.parquet"
pq.write_table(table, out_path)

print(f"\nFichero generado: {out_path}  ({table.num_rows} filas)\n")

# ── Comandos para continuar ──────────────────────────────────────────────────
NAMENODE_HOST = "10.10.1.21"
NAMENODE_PORT = "2222"
CONTAINER     = "webhardmon-hdfs-namenode"
HDFS_PATH     = "/data/telemetry"
MR_HOST       = "10.10.1.24"

print("=" * 60)
print("PASO 1 — Subir el Parquet a HDFS")
print("=" * 60)
print(f"# Copiar al LXC NameNode")
print(f"scp -P {NAMENODE_PORT} {out_path} ubuntu@{NAMENODE_HOST}:/tmp/wh_test.parquet")
print()
print(f"# Copiar al contenedor HDFS y poner en HDFS")
print(f"ssh -p {NAMENODE_PORT} ubuntu@{NAMENODE_HOST} \\")
print(f"  'docker cp /tmp/wh_test.parquet {CONTAINER}:/tmp/ && \\")
print(f"   docker exec {CONTAINER} hdfs dfs -mkdir -p {HDFS_PATH} && \\")
print(f"   docker exec {CONTAINER} hdfs dfs -put -f /tmp/wh_test.parquet {HDFS_PATH}/'")
print()
print(f"# Verificar que está en HDFS")
print(f"ssh -p {NAMENODE_PORT} ubuntu@{NAMENODE_HOST} \\")
print(f"  'docker exec {CONTAINER} hdfs dfs -ls {HDFS_PATH}'")

print()
print("=" * 60)
print("PASO 2 — Lanzar el job manualmente desde el CT MapReduce")
print("=" * 60)
print(f"ssh -p {NAMENODE_PORT} ubuntu@{MR_HOST} \\")
print(f"  'sudo /usr/local/bin/run-webhardmon-aggregation.sh'")
print()
print(f"# Seguir el log en tiempo real (otra terminal):")
from datetime import datetime as dt
log_hour = dt.utcnow().strftime("%Y%m%d%H")
print(f"ssh -p {NAMENODE_PORT} ubuntu@{MR_HOST} \\")
print(f"  'sudo tail -f /var/log/webhardmon-mr-{log_hour}.log'")

print()
print("=" * 60)
print("PASO 3 — Verificar datos en HBase (desde gcp-b node-01)")
print("=" * 60)
print(f"# Row key esperado: {expected_row_key}")
print(f"ssh -p {NAMENODE_PORT} ubuntu@10.0.0.30 \\")
print(f"  'docker exec hbase-master hbase shell -n' <<\\'EOF\\'")
print(f"count 'webhardmon_hourly'")
print(f"get 'webhardmon_hourly', '{expected_row_key}'")
print(f"EOF")
