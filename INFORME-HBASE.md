# Informe Técnico — HBase

## Clúster HBase en WebHardMon (Capa Served)

---

## 1. Papel en la arquitectura

HBase es la **capa served** del Lambda Architecture: almacena los agregados horarios pre-calculados por MapReduce y los sirve con latencia baja a las aplicaciones de visualización (Grafana, webapp Spring Boot). Es el punto de encuentro entre el resultado del batch y el consumidor final de los datos históricos.

```
MapReduce ──► HBase webhardmon_hourly ──► REST API :8085 ──► Grafana
                                                           └──► Webapp Spring Boot
```

La distinción con Cassandra es fundamental:

| Dimensión | Cassandra (hot) | HBase (served) |
|---|---|---|
| Datos | Registros individuales en tiempo real | Agregados horarios (avg/min/max/count) |
| Latencia de ingestión | Milisegundos (Kafka → Java Bridge) | ~1 hora (cron MapReduce) |
| Consulta típica | Últimas N mediciones de un dispositivo | Estadísticas horarias en rango [t1, t2] |
| Escrito por | Java Bridge (streaming) | MapReduce job (batch) |
| TTL | No definido explícitamente | 90 días (automático) |

---

## 2. De dónde llegan los datos y cómo

Los datos llegan exclusivamente del **job MapReduce**, que corre en el HDFS NameNode (`10.10.1.21`, nube local). El Reducer escribe `Put` de HBase directamente a través del cliente HBase usando `TableOutputFormat`. El camino de red es:

```
CT MapReduce (10.10.1.24, nube local)
    │  ruta 10.30.0.0/16 via 10.10.1.1 (gateway LAN)
    ▼
ZK HBase GCP-B: 10.30.1.10:2181  (node-01, IP interna GCP-B)
    │  (ZK devuelve la dirección del RegionServer responsable)
    ▼
RegionServer correspondiente en GCP-B (10.30.1.10 / 10.30.2.11 / 10.30.2.12)
    │  (Put almacenado en MemStore → flush a HFile en volumen Docker)
    ▼
Rootdir local: file:///var/hbase-data  (volumen Docker hbase-data en cada nodo GCP-B)
```

HBase escribe sus HFiles en el **sistema de ficheros local del contenedor** (volumen Docker `hbase-data` montado en `/var/hbase-data`). No usa HDFS como rootdir; los RegionServers de GCP-B escriben localmente sin necesitar acceso de red al NameNode.

---

## 3. Cómo se almacenan los datos

### 3.1 Tabla `webhardmon_hourly`

**Row key**: `{empresaId}|{ramGb}|{stoGb}|{yyyyMMddHH}`

- `empresaId`: ID numérico de la empresa propietaria del dispositivo (campo `empresa_id` del Parquet).
- `ramGb`: capacidad de RAM del dispositivo redondeada a GB entero (tier de hardware).
- `stoGb`: capacidad de almacenamiento del dispositivo redondeada a GB entero (tier de hardware).
- `yyyyMMddHH`: ventana horaria en UTC (p.ej. `2024011514` = 15 de enero de 2024, hora 14:00 UTC).

La inclusión de `ramGb` y `stoGb` en la clave es una decisión de diseño deliberada: agrupa solo dispositivos con la misma capacidad de hardware, de forma que los percentiles de uso sean comparables entre sí. Un equipo con 8 GB de RAM al 80% de uso tiene un perfil de stress diferente al de uno con 32 GB al 80%.

Esta estructura permite scans eficientes por rango de horas de una empresa y tier de hardware concreto:
- `STARTROW = 42|16|512|2024011500`
- `STOPROW   = 42|16|512|2024011523`

**Column family**: `m` (una sola letra para minimizar el overhead de metadatos por HFile).

**Columnas**:

| Columna HBase | Campo Parquet origen | Descripción |
|---|---|---|
| `m:cpu_avg`, `m:cpu_min`, `m:cpu_max` | `cpu_percent` | % de uso de CPU |
| `m:ram_avg`, `m:ram_min`, `m:ram_max` | `ram_percent` | % de uso de RAM |
| `m:ram_gb` | `ram` (capacidad) | Capacidad total de RAM (GB, promedio del grupo) |
| `m:sto_avg`, `m:sto_min`, `m:sto_max` | `disco_percent` | % de uso de almacenamiento |
| `m:sto_gb` | `almacenamiento` (capacidad) | Capacidad total de disco (GB, promedio del grupo) |
| `m:bat_avg`, `m:bat_min`, `m:bat_max` | `bateria_percent` | % de batería |
| `m:tmp_avg`, `m:tmp_min`, `m:tmp_max` | `temperatura` | Temperatura (°C) |
| `m:str_avg`, `m:str_min`, `m:str_max` | `stress_score` | StressScore calculado por RMI (0–100) |
| `m:count` | — | Número de muestras en esa ventana horaria |

**Pre-split**: la tabla se crea con **8 regiones** distribuidas entre los 3 RegionServers. Los splits se basan en el primer byte del row key para garantizar distribución uniforme desde el inicio, evitando el "hot-spotting" inicial habitual cuando todas las escrituras van a una sola región.

**TTL**: 90 días (7.776.000 segundos). HBase expira automáticamente las celdas pasado ese tiempo durante los compaction cycles. No requiere tareas de limpieza adicionales.

**Rootdir local**: `file:///var/hbase-data`. Los HFiles se almacenan en el volumen Docker `hbase-data` de cada nodo GCP-B. El acceso directo de GCP-B a HDFS (`hdfs://10.10.1.21:9000`) no está activo porque el Windows gateway no enruta correctamente TCP forwarded desde GCP-B hacia la LAN local (SYN-ACK no llega de vuelta). El job MapReduce escribe en HBase exclusivamente vía la API cliente (ZK → Master → RS) sin que HBase necesite HDFS como rootdir.

---

## 4. Cómo se desplegó

### 4.1 Imagen Docker

Se construye una **única imagen** (`docker/hbase/`) con un entrypoint parametrizable por rol:

```bash
HBASE_ROLE=master       → hbase master start
HBASE_ROLE=regionserver → hbase regionserver start
HBASE_ROLE=rest         → hbase rest start -p 8085
```

Esto evita mantener tres imágenes distintas. La imagen se construye y sube al **Artifact Registry de GCP-B** (`europe-west1-docker.pkg.dev/<gcp_b_project_id>/webhardmon/hbase:<tag>`). Las VMs de GCP-B se autentican al registro usando su service account (sin ficheros de clave en el host), configurado por OpenTofu.

### 4.2 Topología de nodos (GCP-B, europe-west1)

| Nodo GCP-B | Roles HBase | IP interna GCP-B | IP WireGuard |
|---|---|---|---|
| node-01 | HMaster + RegionServer + REST | 10.30.1.10 | 10.0.0.30 |
| node-02 | RegionServer | 10.30.2.11 | — |
| node-03 | RegionServer | 10.30.2.12 | — |

- **HMaster**: coordinador del clúster, monitoriza RegionServers, gestiona el balanceo y failover de regiones.
- **RegionServer**: almacena y sirve regiones concretas. Cada nodo aloja ~2-3 de las 8 regiones pre-split.
- **REST server**: puerto 8085 en node-01, expone la API JSON para Grafana y webapp sin necesidad de Apache Phoenix.
- **ZooKeeper embebido**: los 3 nodos HBase forman su propio quorum ZK (`10.30.1.10,10.30.2.11,10.30.2.12`), independiente del ZK de Kafka en GCP-A. Esto aísla los dos clústeres y evita que un fallo en GCP-A afecte la disponibilidad de HBase.

**Presupuesto de RAM por nodo** (e2-standard-4, 16 GB):

| Servicio | Heap |
|---|---|
| HMaster | 1.024 MB (solo node-01) |
| RegionServer | 3.072 MB (los 3 nodos) |
| MySQL (`telemetriadb`) | Buffer pool 2.048 MB (solo node-02) |
| SO + Docker + WireGuard | ~1.536 MB reservados |

### 4.3 Playbook Ansible (`ansible/hbase.yml`)

El playbook usa `serial: 1` para garantizar que el HMaster esté operativo antes de que los RegionServers intenten registrarse:

1. **Genera `hbase-site.xml`** en cada nodo (plantilla Jinja2): ZK quorum con IPs internas de GCP-B, `hbase.rootdir = file:///var/hbase-data`, REST port 8085.
2. **Arranca HMaster** en node-01 (primer nodo del grupo `[hbase]`).
3. **Espera** a que el puerto 16000 (HMaster RPC) esté escuchando.
4. **Arranca RegionServer** en los 3 nodos.
5. **Arranca REST server** en node-01 (puerto 8085).
6. **Crea la tabla** `webhardmon_hourly` con 8 pre-splits y TTL 90 días (idempotente: comprueba `exists` antes de crear).

**Ejecutar el despliegue:**

```bash
# Prerrequisito: imagen construida y subida al Artifact Registry de GCP-B
GCP_B_REGISTRY="europe-west1-docker.pkg.dev/<gcp_b_project_id>/webhardmon"
docker build -t "${GCP_B_REGISTRY}/hbase:1.0" docker/hbase/
docker push "${GCP_B_REGISTRY}/hbase:1.0"

# Desplegar el clúster
ansible-playbook -i ansible/inventory.ini ansible/hbase.yml
```

**Verificar el clúster:**

```bash
# HMaster UI — debe listar 3 RegionServers
curl http://10.0.0.30:16010/master-status

# Desde dentro del contenedor
docker exec hbase-master hbase shell -n <<'EOF'
status 'detailed'
list_tables
EOF
```

### 4.4 Variables de configuración (`ansible/group_vars/hbase.yml`)

| Variable | Valor | Descripción |
|---|---|---|
| `hbase_regionserver_heap_mb` | 3072 | Heap del RegionServer |
| `hbase_master_heap_mb` | 1024 | Heap del HMaster |
| `hbase_zk_internal_quorum` | `10.30.1.10,10.30.2.11,10.30.2.12` | ZK con IPs internas GCP-B (para contenedores) |
| `hbase_hdfs_rootdir` | `file:///var/hbase-data` | Rootdir local en volumen Docker |
| `hbase_table_name` | `webhardmon_hourly` | Tabla de agregados |
| `hbase_column_family` | `m` | Family única de columnas |
| `hbase_table_ttl_seconds` | 7776000 | TTL de 90 días |
| `hbase_presplit_regions` | 8 | Regiones pre-split al crear la tabla |
| `hbase_rest_port` | 8085 | Puerto del servidor REST |

---

## 5. Por qué se eligió HBase

- **Modelo de datos columnar variable**: cada dispositivo puede tener métricas distintas (p.ej. sin batería si es un PC de escritorio). HBase almacena solo las columnas que existen; no hay NULLs costosos.
- **Row key compuesto `empresaId|ramGb|stoGb|hora`**: permite scans eficientes por rangos temporales de una empresa y tier de hardware sin índices secundarios. La segmentación por tier garantiza que los percentiles son comparables dentro de cada grupo, que es exactamente el patrón de consulta de Grafana.
- **Pre-split desde el inicio**: evitar el hotspot inicial es crítico en sistemas donde los row keys siguen un patrón ordenado (como timestamps). Los 8 splits distribuyen la carga entre los 3 RegionServers desde el primer registro.
- **REST API nativa**: HBase incluye un servidor REST que expone las tablas como JSON. Grafana puede usar los plugins "JSON API" o "Infinity" apuntando directamente a `http://10.0.0.30:8085/webhardmon_hourly/<rowkey>` sin intermediarios.
- **Rootdir local en volumen Docker**: los HFiles residen en el volumen `hbase-data` de cada nodo GCP-B. Los datos no sobreviven a una preemption con `DELETE` sin una copia de seguridad previa; se asume que HBase se puede repoblar con MapReduce si se pierde una VM.
- **ZooKeeper embebido independiente**: no añade dependencia de infraestructura extra y aísla HBase del ZK de Kafka.
- **TTL automático**: los 90 días de retención se gestionan solos por HBase durante los compaction cycles, sin tareas de limpieza adicionales.
- **Complementariedad con Cassandra**: Cassandra cubre el hot path (consultas de los últimos N registros con alta frecuencia), HBase cubre el served path (consultas históricas por ventana horaria). Cada uno está optimizado para su patrón de acceso.

---

## 6. Consumo de los datos

### Opción A — HBase REST API (puerto 8085)

```bash
# Listar tablas
curl http://10.0.0.30:8085/

# Leer una fila concreta (empresa 42, 16 GB RAM, 512 GB disco, hora 2024011514)
# El separador | se codifica como %7C en la URL
curl -H "Accept: application/json" \
  "http://10.0.0.30:8085/webhardmon_hourly/42%7C16%7C512%7C2024011514"
```

Grafana puede usar el plugin **"JSON API"** o **"Infinity"** apuntando a este endpoint.

### Opción B — Webapp Spring Boot (GCP-B)

La webapp corre en el mismo GCP-B con red directa a HBase (`network_mode: host`). Se puede extender con un endpoint `/api/aggregates?empresaId=42&ramGb=16&stoGb=512&from=2024011500&to=2024011523` que lea de HBase y lo exponga como JSON para Grafana.

---

## 7. Puertos de referencia

| Servicio | Host | Puerto | Descripción |
|---|---|---|---|
| HBase Master UI | 10.0.0.30 | 16010 | Estado del clúster, regiones activas |
| HBase RS UI (node-01) | 10.0.0.30 | 16030 | Estado del RegionServer |
| HBase RS UI (node-02) | 10.30.2.11 | 16030 | Estado del RegionServer |
| HBase RS UI (node-03) | 10.30.2.12 | 16030 | Estado del RegionServer |
| HBase REST API | 10.0.0.30 | 8085 | API JSON para consultas externas |
| ZooKeeper (embebido) | 10.30.1.10, 10.30.2.11, 10.30.2.12 | 2181 | Coordinación del clúster HBase |
