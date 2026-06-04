# Informe Técnico — MapReduce

## Job MapReduce de Agregación de Métricas en WebHardMon

---

## 1. Papel en la arquitectura

MapReduce es el **motor de la capa batch** del Lambda Architecture. Su único job (`MetricsAggregationJob`) transforma los registros de telemetría individuales almacenados en HDFS en **agregados horarios por dispositivo**, que se escriben directamente en HBase para ser consultados por Grafana y la webapp.

```
HDFS /data/telemetry/**/*.parquet
        │
        │  (cada hora a :10, cron en 10.10.1.21)
        ▼
  MetricsAggregationJob (MapReduce modo local, dentro del contenedor NameNode)
        │
        ▼
  HBase webhardmon_hourly   (capa served, GCP-B)
        │
        ▼
  Grafana / webapp Spring Boot
```

Sin MapReduce no existiría ningún histórico agregado. La capa hot (Cassandra) almacena registros individuales recientes; la capa served (HBase) solo tiene valor si hay un proceso que la pueble. MapReduce es ese proceso.

La capa batch coexiste con la capa streaming sin interferencia: ambas leen de fuentes distintas (HDFS vs. Cassandra), producen salidas distintas (HBase vs. Cassandra) y sus fallos son independientes.

---

## 2. De dónde llegan los datos y cómo

La fuente es HDFS, directorio `/data/telemetry`. Los ficheros fueron escritos por el Java Bridge (GCP-A, node-02) en formato **Parquet particionado por fecha** (ver `INFORME-HDFS.md`). El job lee la ruta raíz y procesa **recursivamente todos los subdirectorios y ficheros `.parquet`** que encuentre, independientemente del año/mes/día. Cada ejecución del cron procesa la totalidad del directorio.

Si se quiere ejecutar el job sobre una partición concreta (p.ej., solo una hora):

```bash
docker exec webhardmon-hdfs-namenode \
  hadoop jar /opt/webhardmon-mr.jar \
  com.webhardmon.mr.MetricsAggregationJob \
  /data/telemetry/2024/01/15/14 \
  webhardmon_hourly \
  10.0.0.30,10.30.2.11,10.30.2.12
```

---

## 3. Qué hace en el procesamiento batch

El proyecto Maven vive en `docker/mapreduce-job/` y está compuesto por cuatro clases Java en `src/main/java/com/webhardmon/mr/`:

```
docker/mapreduce-job/
├── Dockerfile                                   ← build multi-stage (Maven → JAR)
├── pom.xml                                      ← fat JAR con shade plugin
└── src/main/java/com/webhardmon/mr/
    ├── MetricsAggregationJob.java               ← driver (main + configuración job)
    ├── MetricsMapper.java                       ← lee Parquet, emite (key, writable)
    ├── MetricsWritable.java                     ← transporta 8 métricas entre M y R
    └── MetricsReducer.java                      ← extiende TableReducer, escribe HBase
```

### 3.1 MetricsMapper

Lee cada `GenericRecord` Parquet mediante `AvroParquetInputFormat`. Los campos que lee corresponden al esquema que escribe `HdfsParquetWriter` en el bridge Java:

```
empresa_id, nombre, ts, cpu_percent, ram_percent, disco_percent,
temperatura, bateria_percent, ram, almacenamiento, procesador, stress_score
```

Por cada registro:

1. Extrae `empresa_id`. Si es `<= 0` **descarta el registro** e incrementa el counter `registros_sin_empresa_id` (registros sin empresa asociada no son agregables).
2. Extrae `ram` y `almacenamiento` (capacidades en GB) y los redondea a entero para obtener el **tier de hardware**: `ramGb` y `stoGb`.
3. Extrae `ts` (epoch ms) y lo convierte a ventana horaria UTC en formato `yyyyMMddHH`.
4. Construye la clave: `empresaId|ramGb|stoGb|yyyyMMddHH`.
5. Extrae las 8 métricas: `cpu_percent`, `ram_percent`, `ram` (GB), `disco_percent`, `almacenamiento` (GB), `bateria_percent`, `temperatura`, `stress_score`.
6. **Emite**: clave = `Text("empresaId|ramGb|stoGb|yyyyMMddHH")`, valor = `MetricsWritable`.

La segmentación por tier de hardware (`ramGb|stoGb`) garantiza que todos los registros de un mismo grupo tengan la misma capacidad de RAM y disco, haciendo que los percentiles de uso sean comparables entre sí (un equipo de 8 GB al 80% de RAM no se mezcla con uno de 32 GB al 80%). El framework MapReduce agrupa los valores por clave mediante shuffle + sort.

### 3.2 MetricsWritable

Clase serializable (implementa `Writable`) que transporta las 8 métricas entre Mapper y Reducer a través de la red del framework.

### 3.3 MetricsReducer

Extiende `TableReducer` de HBase (`hbase-mapreduce`). Por cada clave `empresaId|ramGb|stoGb|yyyyMMddHH` recibe todos los `MetricsWritable` de esa ventana y:

1. **Acumula** suma, mínimo, máximo y conteo por cada métrica.
2. **Calcula** el promedio como `avg = sum / count`.
3. **Escribe** un `Put` a HBase en la fila `empresaId|ramGb|stoGb|yyyyMMddHH`, familia de columnas `m`.

Columnas escritas en HBase:

```
m:cpu_avg   m:cpu_min   m:cpu_max
m:ram_avg   m:ram_min   m:ram_max   m:ram_gb
m:sto_avg   m:sto_min   m:sto_max   m:sto_gb
m:bat_avg   m:bat_min   m:bat_max
m:tmp_avg   m:tmp_min   m:tmp_max
m:str_avg   m:str_min   m:str_max
m:count
```

### 3.4 MetricsAggregationJob (driver)

Configura el job: `InputFormat`, `Mapper`, `Reducer`, `TableOutputFormat` apuntando a la tabla HBase, número de reducers (8, coincide con las pre-split regions de HBase para paralelismo óptimo), y los parámetros del quorum ZooKeeper de HBase.

**Modo de ejecución**: el job corre en **modo local** (`-Dmapreduce.framework.name=local`) dentro del contenedor `webhardmon-hdfs-namenode`. No se usa YARN porque las imágenes `bde2020/hadoop-*` no incluyen NodeManager/ResourceManager configurados. El modo local ejecuta Mapper y Reducer en el mismo proceso JVM.

### Flujo completo del job

```
HDFS /data/telemetry/**/*.parquet
         │
         │  AvroParquetInputFormat<GenericRecord>
         ▼
  MetricsMapper
    - Descarta si empresa_id <= 0  (counter: registros_sin_empresa_id)
    - Extrae: empresa_id, ts, ram/almacenamiento (GB → tier entero), 8 métricas
    - Calcula ventana: yyyyMMddHH (UTC)
    - Emite: (Text "empresaId|ramGb|stoGb|yyyyMMddHH", MetricsWritable)
         │
         │  shuffle + sort por key
         ▼
  MetricsReducer (TableReducer → HBase)
    - Acumula: sum, min, max, count por métrica
    - Calcula: avg = sum / count
    - Escribe: Put a HBase webhardmon_hourly (fila = "empresaId|ramGb|stoGb|yyyyMMddHH")
```

---

## 4. Cómo se mandan los resultados a HBase

El Reducer usa `TableOutputFormat` de HBase, que mediante el cliente HBase (`hbase-client 2.5.10`) conecta directamente al clúster HBase de GCP-B a través del **quorum ZooKeeper** (configurado en `ansible/group_vars/mapreduce.yml`):

```
NameNode (10.10.1.21) → WireGuard → ZK quorum GCP-B:
  - 10.0.0.30   (node-01, gateway WireGuard de GCP-B)
  - 10.30.2.11  (node-02, rutado por el gateway)
  - 10.30.2.12  (node-03, rutado por el gateway)
```

El `Put` viaja desde el NameNode a través de la malla WireGuard hasta el RegionServer de GCP-B que gestiona la región correspondiente al row key.

Verificar conectividad antes de lanzar el job:

```bash
ssh root@10.10.1.21 \
  "docker exec webhardmon-hdfs-namenode \
    bash -c 'echo ruok | nc 10.0.0.30 2181'"
# Respuesta esperada: imok
```

---

## 5. Cómo se desplegó

El rol Ansible `mapreduce` (playbook `ansible/mapreduce.yml`) ejecuta los siguientes pasos sobre el grupo `[mapreduce]` (único miembro: `hdfs-namenode ansible_host=10.10.1.21`):

1. **Copia el código fuente** de `docker/mapreduce-job/` al nodo de control (`/tmp/`).
2. **Compila el fat JAR** ejecutando `docker build` localmente sobre la imagen multi-stage (Maven → extrae JAR). Imagen: `webhardmon-mr-builder:latest`.
3. **Extrae el JAR** de la imagen con `docker create` + `docker cp`.
4. **Copia el JAR** al host `10.10.1.21` vía SSH y lo inyecta en el contenedor NameNode en `/opt/webhardmon-mr.jar`.
5. **Añade la ruta IP** hacia GCP-B (`10.30.0.0/16 via <gateway-local>`) si no existe.
6. **Instala el script wrapper** `/usr/local/bin/run-webhardmon-aggregation.sh` (generado desde `ansible/roles/mapreduce/templates/run-aggregation.sh.j2`).
7. **Crea el cron job** de root en `10.10.1.21`: `10 * * * * /usr/local/bin/run-webhardmon-aggregation.sh`.

El script wrapper encapsula el `docker exec hadoop jar ...`, añade logging con timestamp en `/var/log/webhardmon-mr-<yyyyMMddHH>.log` y rota logs con más de 7 días de antigüedad.

**Dependencias bundled en el fat JAR** (Maven Shade plugin):

| Librería | Versión | Scope | Rol |
|---|---|---|---|
| `hadoop-common` | 3.2.1 | provided | Framework MapReduce (ya en el contenedor NameNode) |
| `hadoop-mapreduce-client-core` | 3.2.1 | provided | API MapReduce (ya en el contenedor) |
| `hadoop-hdfs` | 3.2.1 | provided | Acceso HDFS (ya en el contenedor) |
| `parquet-avro` | 1.12.3 | bundled | Lectura de Parquet escritos por el bridge Java |
| `avro` | 1.11.3 | bundled | Soporte del esquema Avro embebido en Parquet |
| `hbase-client` | 2.5.10 | bundled | API cliente HBase (debe coincidir con la versión del clúster) |
| `hbase-mapreduce` | 2.5.10 | bundled | `TableReducer`, `TableOutputFormat`, `TableMapReduceUtil` |

Las dependencias Hadoop se declaran como `scope=provided` porque ya están en el contenedor NameNode de bde2020. El fat JAR sólo bundlea lo que no está en el classpath del contenedor: Parquet, Avro y HBase.

**Variables de configuración** (`ansible/group_vars/mapreduce.yml`):

| Variable | Valor | Descripción |
|---|---|---|
| `mr_hdfs_input_path` | `/data/telemetry` | Directorio raíz de Parquet en HDFS |
| `mr_hbase_zk_quorum` | `10.0.0.30,10.30.2.11,10.30.2.12` | ZK quorum de HBase (vía WireGuard) |
| `mr_hbase_table` | `webhardmon_hourly` | Tabla HBase de destino |
| `mr_cron_minute` | `10` | Minuto de ejecución del cron |
| `mr_num_reducers` | `8` | Coincide con las regiones HBase pre-split |

**Verificar el despliegue:**

```bash
# JAR en el contenedor
ssh root@10.10.1.21 \
  "docker exec webhardmon-hdfs-namenode ls -lh /opt/webhardmon-mr.jar"

# Cron activo
ssh root@10.10.1.21 "crontab -l | grep webhardmon"

# Ejecutar manualmente para poblar HBase antes del primer cron
ssh root@10.10.1.21 /usr/local/bin/run-webhardmon-aggregation.sh
```

---

## 6. Por qué se eligió MapReduce

- **Integración nativa con Hadoop/HDFS**: MapReduce en modo local corre directamente dentro del contenedor NameNode, donde ya están las librerías `hadoop jar`. No requiere YARN ni clúster adicional.
- **`TableReducer` de HBase**: la API `hbase-mapreduce` integra MapReduce con HBase directamente, permitiendo escribir `Put` al clúster sin código adicional de conexión.
- **Paralelismo alineado con sharding**: 8 reducers = 8 regiones HBase. Cada reducer escribe su región sin contención.
- **Desfase de :10 minutos**: dar margen para que el bridge Java de GCP-A haya flusheado los Parquet de la hora anterior antes de que el job los lea.
- **Idempotencia**: si el job se ejecuta dos veces sobre los mismos datos, HBase recibe los mismos `Put` y el resultado es idéntico (los valores se sobreescriben con el mismo valor). No hay duplicación.
- **Simplicidad operacional**: un cron + un script bash + un JAR. Sin frameworks adicionales (no Spark, no Flink), compatible con las imágenes `bde2020` ya usadas para HDFS.

---

## 7. Operativa y troubleshooting

```bash
# Ver log del job más reciente
ssh root@10.10.1.21 "ls -lt /var/log/webhardmon-mr-*.log | head -3"
ssh root@10.10.1.21 "cat /var/log/webhardmon-mr-<yyyyMMddHH>.log"

# Verificar datos escritos en HBase tras el job
docker exec hbase-master hbase shell -n <<'EOF'
count 'webhardmon_hourly'
scan 'webhardmon_hourly', {LIMIT => 5}
EOF
```
