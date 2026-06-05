# WebHardMon · Capa Batch: MapReduce + HBase

Documentación del pipeline batch del **Lambda Architecture** de WebHardMon.  
Cubre qué se ha implementado, cómo funciona y el orden exacto de despliegue.

---

## 1. Contexto arquitectónico

WebHardMon sigue el patrón **Lambda Architecture** con dos capas paralelas:

```
Agentes reales
     │
     ▼ (Cloudflare Tunnel → NiFi → Avro)
  Kafka  ──────────────────────────────────────────────────────► Cassandra  ◄── Grafana
  (GCP-A)          CAPA STREAMING (caliente)                     (GCP-A)
     │
     ▼ (Java bridge → Parquet)
  HDFS ──► MapReduce ──────────────────────────────────────────► HBase      ◄── Grafana
  (LOCAL)   (LOCAL)         CAPA BATCH (fría → servida)         (GCP-B)
```

| Dimensión | Streaming | Batch |
|-----------|-----------|-------|
| Latencia | Segundos | ~1 hora |
| Tecnología | Kafka → Java RMI → Cassandra | HDFS Parquet → MapReduce → HBase |
| Consulta | Hot (datos recientes) | Served (agregados históricos) |
| Ubicación | GCP-A | Local → GCP-B |

---

## 2. Qué se ha implementado

### 2.1 HBase — capa SERVED (GCP-B)

#### Imagen Docker actualizada

`docker/hbase/` — la imagen pasa de CMD fijo a un **entrypoint por rol**:

```
HBASE_ROLE=master       → hbase master start
HBASE_ROLE=regionserver → hbase regionserver start
HBASE_ROLE=rest         → hbase rest start -p 8085
```

Una sola imagen cubre los tres roles. El rol Ansible decide cuál arranca en cada nodo.

#### Clúster distribuido 3 nodos (GCP-B)

| Nodo | Rol HBase | IP interna GCP-B | IP WireGuard |
|------|-----------|------------------|--------------|
| node-01 | HMaster + RegionServer + REST | 10.30.1.10 | 10.0.0.30 |
| node-02 | RegionServer | 10.30.2.11 | — |
| node-03 | RegionServer | 10.30.2.12 | — |

- **ZooKeeper**: embebido en los 3 nodos HBase (quorum independiente del ZK de Kafka en GCP-A).
- **Rootdir**: `hdfs://10.10.1.21:9000/hbase` — HFiles almacenados en el HDFS de la nube local, accesible vía WireGuard. Esto garantiza que los datos sobreviven a la recreación de las VMs spot.
- **REST server**: puerto 8085 en node-01, para que la webapp y Grafana consuman los agregados sin necesidad de Apache Phoenix.

#### Tabla `webhardmon_hourly`

```
Row key   :  {licencia}|{yyyyMMddHH}
              └── licencia: código de API del dispositivo
              └── ventana : hora UTC (p.ej. 2024011514)

Column family: m  (una letra = menos overhead por HFile)
```

Columnas dentro de `m`:

| Columna | Métrica origen | Descripción |
|---------|----------------|-------------|
| `cpu_avg` / `cpu_min` / `cpu_max` | `uso_procesador` | % de uso de CPU |
| `ram_avg` / `ram_min` / `ram_max` | `uso_ram` | % de uso de RAM |
| `ram_gb` | `cantidad_ram` | RAM total del dispositivo (GB) |
| `sto_avg` / `sto_min` / `sto_max` | `uso_almacenamiento` | % de uso de almacenamiento |
| `sto_gb` | `cantidad_almacenamiento` | Almacenamiento total (GB) |
| `bat_avg` / `bat_min` / `bat_max` | `bateria` | % de batería |
| `tmp_avg` / `tmp_min` / `tmp_max` | `temperatura` | Temperatura en ºC |
| `str_avg` / `str_min` / `str_max` | `stressScore` | StressScore calculado por RMI (0-100) |
| `count` | — | Nº de muestras en esa hora |

**Pre-split**: 8 regiones distribuidas uniformemente entre los 3 RegionServers (requisito N2 de sharding). Los splits se basan en el primer byte del row key para distribución uniforme.

**TTL**: 90 días (7.776.000 segundos). Pasado ese tiempo HBase expira las celdas automáticamente.

---

### 2.2 MapReduce — capa BATCH (nube local)

#### Proyecto Maven + imagen runnable: `docker/mapreduce/`

```
docker/mapreduce/
├── Dockerfile                                   ← multi-stage: Maven build → imagen runnable (bde2020/hadoop-base + JAR)
├── run-job.sh                                   ← ENTRYPOINT: lee MR_* del entorno y lanza `hadoop jar`
├── pom.xml                                      ← fat JAR con shade plugin
└── src/main/java/com/webhardmon/mr/
    ├── MetricsAggregationJob.java               ← driver (main + configuración job)
    ├── MetricsMapper.java                       ← lee Parquet, emite (key, writable)
    ├── MetricsWritable.java                     ← transporta 8 métricas entre M y R
    └── MetricsReducer.java                      ← extiende TableReducer, escribe HBase
```

La imagen se construye y sube a Harbor con `docker/build-and-push.sh mapreduce`
(`[mapreduce]=local`), igual que el resto de imágenes de la nube local.

**Dependencias bundled** (fat JAR):

| Librería | Versión | Motivo |
|----------|---------|--------|
| Hadoop | 3.2.1 | `provided` — lo aporta la imagen base `bde2020/hadoop-base` |
| `parquet-avro` | 1.12.3 | Lectura de Parquet escrito por NiFi/Java |
| `hbase-client` | 2.5.10 | API cliente HBase (= versión del clúster) |
| `hbase-mapreduce` | 2.5.10 | `TableReducer`, `TableOutputFormat`, `TableMapReduceUtil` |

#### Flujo interno del job

```
HDFS /data/telemetry/**/*.parquet
         │
         │  AvroParquetInputFormat<GenericRecord>
         ▼
  MetricsMapper
    - Extrae: licencia, timestamp, 8 métricas numéricas
    - Calcula ventana horaria: yyyyMMddHH (UTC)
    - Emite: (Text "licencia|yyyyMMddHH",  MetricsWritable)
         │
         │  shuffle + sort por key
         ▼
  MetricsReducer (TableReducer → HBase)
    - Acumula: sum, min, max, count para cada métrica
    - Calcula: avg = sum / count
    - Escribe: Put a la fila "licencia|yyyyMMddHH" en webhardmon_hourly
```

#### Ejecución

El job corre en **modo local** (LocalJobRunner, no necesita YARN — que no está
configurado en las imágenes bde2020) dentro de un **contenedor dedicado y efímero**
en el CT `mapreduce` (10.10.1.24), no dentro del NameNode. El `docker run --rm` usa
`--network host` para alcanzar HDFS (10.10.1.21:9000) por la LAN y el quorum ZK de
HBase (10.30.0.0/16) por la ruta WireGuard. La configuración llega por variables de
entorno (`MR_*`); el ENTRYPOINT (`run-job.sh`) las traduce a `hadoop jar`:

```bash
docker run --rm --name webhardmon-mapreduce --network host \
  -e MR_INPUT="hdfs://10.10.1.21:9000/data/telemetry" \
  -e MR_HBASE_TABLE="webhardmon_hourly" \
  -e MR_ZK_QUORUM="10.0.0.30,10.30.2.11,10.30.2.12" \
  -e MR_ZK_PORT="2181" \
  harbor.<zona>/webhardmon/mapreduce:1.0
```

El **script wrapper** `/usr/local/bin/run-webhardmon-aggregation.sh` (desplegado por Ansible) encapsula este `docker run`, añade logging con timestamp y limpieza de logs viejos (> 7 días).

**Cron**: se ejecuta automáticamente **cada hora a los :10 minutos** (root en el CT mapreduce 10.10.1.24). El desfase de 10 minutos da margen para que el bridge Java haya flusheado los Parquet de la hora anterior.

---

### 2.3 Ansible — ficheros nuevos/modificados

| Fichero | Descripción |
|---------|-------------|
| `docker/hbase/entrypoint.sh` | Entrypoint por rol (nuevo) |
| `docker/hbase/Dockerfile` | Actualizado: ENTRYPOINT + puerto 8085 |
| `ansible/roles/hbase/defaults/main.yml` | Variables del rol con valores por defecto |
| `ansible/roles/hbase/tasks/main.yml` | Orquestación: config → master → RS → REST → tablas |
| `ansible/roles/hbase/tasks/master.yml` | Contenedor HMaster |
| `ansible/roles/hbase/tasks/regionserver.yml` | Contenedor RegionServer |
| `ansible/roles/hbase/tasks/rest.yml` | Contenedor REST server (puerto 8085) |
| `ansible/roles/hbase/tasks/create_tables.yml` | Crea `webhardmon_hourly` (idempotente) |
| `ansible/roles/hbase/templates/hbase-site.xml.j2` | Config HBase con ZK quorum y rootdir HDFS |
| `ansible/roles/hbase/handlers/main.yml` | Restart de los 3 contenedores |
| `ansible/hbase.yml` | Playbook: `serial: 1` (Master primero) |
| `ansible/group_vars/hbase.yml` | Extendido: rootdir, ZK quorum interno, tabla, REST port |
| `docker/mapreduce/Dockerfile` | Imagen runnable: Maven build → `bde2020/hadoop-base` + JAR (antes: solo extraía el JAR) |
| `docker/mapreduce/run-job.sh` | ENTRYPOINT del contenedor: lee `MR_*` y lanza `hadoop jar` |
| `ansible/roles/mapreduce/tasks/main.yml` | Pull imagen Harbor → ruta gcp-b → script + cron |
| `ansible/roles/mapreduce/templates/run-aggregation.sh.j2` | `docker run --rm` del job, con logging |
| `ansible/mapreduce.yml` | Playbook, targets `[mapreduce]`, roles `docker` + `mapreduce` |
| `ansible/group_vars/mapreduce.yml` | Imagen, URI HDFS, ZK quorum MR, ruta gcp-b, cron schedule |
| `ansible/inventory.tmpl` | Emite `[mapreduce]` desde `groups_by_role` (el CT dedicado lleva el rol `mapreduce` vía `var.mapreduce_node`) |
| `variables.tf` / `main.tf` / `outputs.tf` | `var.mapreduce_node` → CT dedicado `10.10.1.24` + grupo `[mapreduce]` |
| `ansible/site.yml` | Comentarios actualizados con el orden de despliegue |

---

## 3. Prerequisitos antes de desplegar

### 3.1 WireGuard operativo

El pipeline batch cruza tres nubes vía WireGuard. Verificar que:

```bash
# Desde el CT MapReduce (10.10.1.24, donde corre el job) se alcanza GCP-B
ping -c 2 10.0.0.30    # gateway gcp-b (node-01 WireGuard)
ping -c 2 10.30.2.11   # node-02 gcp-b (vía routing WireGuard)
ping -c 2 10.30.2.12   # node-03 gcp-b
```

`roles/mapreduce` añade la ruta a gcp-b automáticamente en el CT MapReduce. Si hace
falta a mano (el contenedor usa `--network host`):

```bash
# Dentro del CT 10.10.1.24:
ip route add 10.30.0.0/16 via 10.10.1.1   # donde 10.10.1.1 es el gateway local
```

Y desde GCP-B hacia HDFS local (para que HBase escriba en el rootdir):

```bash
# En cada nodo gcp-b (el gateway lo gestiona WireGuard automáticamente):
# node-01 (gateway): alcanza 10.10.0.0/16 por la malla WireGuard ✓
# node-02/03: necesitan ruta vía gateway interno gcp-b
ip route add 10.10.0.0/16 via 10.30.1.10  # via node-01 interno
```

### 3.2 HDFS corriendo y con datos

```bash
# Verificar que el clúster HDFS está sano (2 DataNodes)
ssh -p 2222 ubuntu@10.10.1.21 \
  "docker exec webhardmon-hdfs-namenode hdfs dfsadmin -report"

# Verificar que existe el directorio de telemetría
ssh -p 2222 ubuntu@10.10.1.21 \
  "docker exec webhardmon-hdfs-namenode hdfs dfs -ls /data/telemetry"
```

Si el directorio no existe, crearlo:
```bash
ssh -p 2222 ubuntu@10.10.1.21 \
  "docker exec webhardmon-hdfs-namenode hdfs dfs -mkdir -p /data/telemetry"
```

### 3.3 Imagen HBase construida y en el Artifact Registry de gcp-b

```bash
# Desde el nodo de control (con Docker y acceso al registro):
GCP_B_REGISTRY="europe-west1-docker.pkg.dev/<gcp_b_project_id>/webhardmon"
TAG="latest"

docker build -t "${GCP_B_REGISTRY}/hbase:${TAG}" docker/hbase/
docker push "${GCP_B_REGISTRY}/hbase:${TAG}"
```

> La variable `container_registry` de `group_vars/cloud_gcp_b.yml` debe apuntar a este registro.

### 3.4 Imagen MapReduce construida y en Harbor

El job ya no se compila en el nodo de control: es una imagen runnable que se
construye y sube a Harbor con `build-and-push.sh`, y `roles/mapreduce` la descarga
en el CT dedicado (`pull`). Construirla antes de desplegar:

```bash
# Desde el nodo de control (con Docker y `docker login` a Harbor hecho):
export GCP_A_PROJECT=... GCP_B_PROJECT=... HARBOR_HOST=harbor.<zona> IMAGE_TAG=1.0
./docker/build-and-push.sh mapreduce
```

> Harbor sirve con TLS (cert público de Let's Encrypt), así que el CT MapReduce
> hace `pull` por HTTPS sin `insecure-registries` ni CA extra. Solo necesita
> resolver `harbor.<zona>` (registro DNS creado por OpenTofu) y alcanzar su IP LAN.

---

## 4. Orden de despliegue

### Paso 1 — Seguridad y red (si no se ha hecho antes)

```bash
ansible-playbook -i ansible/inventory.ini ansible/security.yml
```

### Paso 2 — Desplegar HBase en GCP-B

```bash
ansible-playbook -i ansible/inventory.ini ansible/hbase.yml
```

El playbook:
1. Genera `hbase-site.xml` en cada nodo.
2. Arranca HMaster en node-01 (primero, por `serial: 1`).
3. Arranca RegionServer en los 3 nodos.
4. Arranca REST server en node-01 (puerto 8085).
5. Espera a que el Master esté listo (puerto 16000).
6. Crea la tabla `webhardmon_hourly` con 8 pre-splits (idempotente).

**Verificar** que el clúster HBase está sano:

```bash
# HMaster UI — debe listar 3 RegionServers
curl http://10.0.0.30:16010/master-status

# Desde dentro del contenedor
docker exec hbase-master hbase shell -n <<'EOF'
status 'detailed'
list_tables
EOF
```

### Paso 3 — Desplegar el job MapReduce en su CT dedicado

```bash
ansible-playbook -i ansible/inventory.ini ansible/mapreduce.yml
```

El playbook (roles `docker` + `mapreduce` sobre `[mapreduce]` = 10.10.1.24):
1. Instala Docker en el CT.
2. Hace `pull` de la imagen `mapreduce` desde Harbor.
3. Añade la ruta IP hacia GCP-B (`10.30.0.0/16` via gateway local) si no existe.
4. Instala el script `/usr/local/bin/run-webhardmon-aggregation.sh` (`docker run --rm`).
5. Crea el cron horario (`:10` de cada hora).

**Verificar** el despliegue:

```bash
# Imagen presente en el CT
ssh -p 2222 ubuntu@10.10.1.24 "docker images | grep mapreduce"

# Cron activo (el cron horario se instala en el crontab de root)
ssh -p 2222 ubuntu@10.10.1.24 "sudo crontab -l | grep webhardmon"
```

### Paso 4 — Ejecución manual del primer job

Ejecutar una vez para poblar HBase antes de que entre el cron:

```bash
ssh -p 2222 ubuntu@10.10.1.24 "sudo /usr/local/bin/run-webhardmon-aggregation.sh"
```

Monitorizar el progreso (el job imprime counters al stdout):

```bash
# Log del job actual
ssh -p 2222 ubuntu@10.10.1.24 "sudo tail -f /var/log/webhardmon-mr-$(date +%Y%m%d%H).log"
```

### Paso 5 — Verificar datos en HBase

```bash
# Desde el nodo gcp-b node-01
docker exec hbase-master hbase shell -n <<'EOF'
count 'webhardmon_hourly'
scan 'webhardmon_hourly', {LIMIT => 5}
EOF
```

Un registro típico tendrá este aspecto:

```
ROW                          COLUMN+CELL
licencia-XYZ|2024011514      column=m:cpu_avg, value=\x40...(double 45.3)
licencia-XYZ|2024011514      column=m:cpu_max, value=\x40...(double 89.1)
licencia-XYZ|2024011514      column=m:count,   value=\x00\x00\x00\x00\x00\x00\x00\x24 (36)
...
```

---

## 5. Consumo de los agregados (Grafana / webapp)

### Opción A — HBase REST API (puerto 8085)

El REST server de HBase expone una API JSON en node-01 GCP-B:

```bash
# Listar tablas
curl http://10.0.0.30:8085/

# Leer una fila concreta
curl -H "Accept: application/json" \
  "http://10.0.0.30:8085/webhardmon_hourly/licencia-XYZ%7C2024011514"
```

Grafana puede usar el plugin **"JSON API"** o **"Infinity"** apuntando a este endpoint.

### Opción B — Spring Boot webapp (ya desplegada en GCP-B)

La webapp (`roles/web`) corre en el mismo GCP-B y tiene red directa a HBase (network_mode:host). Se puede extender con un endpoint `/api/aggregates?licencia=X&from=2024011500&to=2024011523` que lea de HBase y lo exponga como JSON.  
Grafana usa ese endpoint como datasource SimpleJson — sin cambios en la infraestructura.

### Resumen de puertos útiles

| Servicio | Host | Puerto | Descripción |
|---------|------|--------|-------------|
| HBase Master UI | 10.0.0.30 | 16010 | Estado del clúster, regiones |
| HBase RS UI | 10.0.0.30 / 10.30.2.11 / 10.30.2.12 | 16030 | Estado por RegionServer |
| HBase REST API | 10.0.0.30 | 8085 | API JSON para consultas |
| HDFS NameNode UI | 10.10.1.21 | 9870 | Estado HDFS, DataNodes |

---

## 6. Operativa diaria y troubleshooting

### Ver logs del job más reciente

```bash
ssh -p 2222 ubuntu@10.10.1.24 "sudo ls -lt /var/log/webhardmon-mr-*.log | head -3"
ssh -p 2222 ubuntu@10.10.1.24 "sudo cat /var/log/webhardmon-mr-<yyyyMMddHH>.log"
```

### Ejecutar job sobre una partición concreta

El job acepta cualquier subruta de HDFS vía `MR_INPUT` (URI completa):

```bash
# Solo los Parquet de una hora específica (si el bridge escribe particionado)
ssh -p 2222 ubuntu@10.10.1.24 \
  "sudo docker run --rm --network host \
    -e MR_INPUT='hdfs://10.10.1.21:9000/data/telemetry/2024/01/15/14' \
    -e MR_HBASE_TABLE='webhardmon_hourly' \
    -e MR_ZK_QUORUM='10.0.0.30,10.30.2.11,10.30.2.12' \
    harbor.<zona>/webhardmon/mapreduce:1.0"
```

### Rebalancear regiones HBase (tras añadir RegionServer)

```bash
docker exec hbase-master hbase shell -n <<'EOF'
balance_switch true
balancer
EOF
```

### HBase no conecta al rootdir HDFS

1. Comprobar conectividad desde gcp-b al NameNode:
   ```bash
   docker exec hbase-master hdfs dfs -ls hdfs://10.10.1.21:9000/
   ```
2. Si falla: verificar ruta IP en los nodos gcp-b (`ip route show 10.10.0.0/16`).
3. Verificar que el NameNode escucha en `0.0.0.0` (env var `HDFS_CONF_dfs_namenode_rpc___bind___host=0.0.0.0` ya configurada en `ansible/roles/hdfs/tasks/main.yml` ✓).

### Job MR termina con error de conexión HBase

Verificar que el ZK quorum es alcanzable desde el CT MapReduce:
```bash
ssh -p 2222 ubuntu@10.10.1.24 "echo ruok | nc 10.0.0.30 2181"
# Respuesta esperada: imok
```

---

## 7. Relación con las rúbricas

| Requisito | Implementación |
|-----------|---------------|
| **N2 — DOS sistemas de almacenamiento masivo** | Cassandra (hot) + HBase (served) + HDFS/Parquet (cold) |
| **N2 — Particionado (sharding)** | HBase: 8 regiones pre-spliteadas. Parquet: directorio HDFS particionado. |
| **N2 — Capa batch Y streaming simultáneas** | Batch: HDFS→MR→HBase. Streaming: Kafka→Java→Cassandra. |
| **N3 — TERCER sistema de almacenamiento** | HDFS (cold) + Cassandra (hot) + HBase (served) = 3 sistemas |
| **N3 — Capa service** | HBase REST + webapp Spring Boot = capa service del Lambda stack |
