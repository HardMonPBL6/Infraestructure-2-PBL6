# Informe Técnico — HDFS

## Sistema de Ficheros Distribuido Hadoop (HDFS) en WebHardMon

---

## 1. Papel en la arquitectura

HDFS es la **capa de almacenamiento frío** (*cold storage*) dentro del patrón Lambda Architecture que sigue WebHardMon. La plataforma implementa dos vías de procesamiento paralelas:

```
Agente Go → NiFi → Kafka ──► Java Bridge ──► Cassandra   (hot path / streaming)
                                          └──► HDFS        (cold path / batch)
                                                │
                                           MapReduce
                                                │
                                             HBase        (served layer)
```

HDFS no es un sistema de consulta directa ni un sistema de tiempo real. Su función es **acumular todos los registros de telemetría en formato columnar** (Parquet) para que el job MapReduce pueda procesarlos periódicamente y calcular agregados históricos. Sin HDFS, la capa batch del Lambda stack no existiría: no habría datos históricos en HBase ni posibilidad de calcular estadísticas por ventana horaria.

HBase usa `file:///var/hbase-data` (volumen Docker local en cada nodo GCP-B) como rootdir, no HDFS. El acceso directo de GCP-B a `hdfs://10.10.1.21:9000` no está activo (el Windows gateway no reenvía correctamente el tráfico TCP desde GCP-B hacia la LAN local). Por tanto, HDFS es solo la fuente de datos para MapReduce; los HFiles de HBase viven en los nodos GCP-B.

---

## 2. De dónde llegan los datos y cómo

Los datos entran en HDFS exclusivamente desde el **Java Bridge** que corre en GCP-A (nodo node-02, IP interna `10.20.2.11`). El bridge consume mensajes Avro del topic `telemetry` de Kafka, calcula el StressScore vía RMI, y escribe en **dos destinos de forma independiente**:

- **Cassandra** (hot path, síncrono).
- **HDFS** (cold path, best-effort): si el write a HDFS falla, se captura la excepción, se registra en log, y el offset de Kafka se confirma igualmente. Cassandra no se ve afectada.

El componente responsable es `HdfsParquetWriter.java` (en `client/src/main/java/cluster/`). Su comportamiento relevante:

| Parámetro | Valor |
|---|---|
| Variable de entorno de activación | `HDFS_URI` (vacío = HDFS desactivado) |
| URI del NameNode | `hdfs://10.10.1.21:9000` (IP fija en la LAN de gestión Proxmox) |
| Acceso desde GCP-A | Vía malla WireGuard (GCP-A → gateway local 10.0.0.10 → LAN 10.10.x) |
| Modo de autenticación | Simple (sin Kerberos); `dfs.permissions.enabled=false` |
| Thread safety | Lock global; un writer por día, lazy, cerrado en shutdown hook |

La conectividad GCP-A → HDFS depende del túnel WireGuard. El NameNode escucha en `0.0.0.0:9000` para que las conexiones vengan de cualquier interfaz (`HDFS_CONF_dfs_namenode_rpc___bind___host=0.0.0.0` configurado en `roles/hdfs`).

---

## 3. Cómo se almacenan los datos

Los ficheros se escriben en formato **Parquet con esquema Avro** (`TelemetryEnriched`): todos los campos del mensaje Avro original más `stress_score` calculado por RMI.

**Estructura de directorios** (particionado Hive-style):

```
/data/telemetry/
  year=2024/
    month=01/
      day=15/
        part-<uuid>-<timestamp>.parquet
```

**Parámetros de escritura:**

| Parámetro | Valor | Justificación |
|---|---|---|
| Formato | Parquet + Avro schema | Óptimo para lectura columnar en MapReduce |
| Compresión | SNAPPY | Equilibrio velocidad/ratio de compresión |
| Row group | 128 MB | Tamaño alineado con el bloque HDFS |
| Bloque HDFS | 128 MB | Valor estándar Hadoop 3 |
| Factor de replicación | 2 | Con 2 DataNodes, es el máximo posible |

La tabla de campos del esquema `TelemetryEnriched` incluye: `licencia`, `empresa_id`, `nombre_ordenador`, `uso_procesador`, `uso_ram`, `cantidad_ram`, `uso_almacenamiento`, `cantidad_almacenamiento`, `bateria`, `temperatura`, `procesador`, `stress_score`, y el `timestamp` del evento.

---

## 4. Cómo se desplegó

HDFS se despliega en **dos pasos** independientes: OpenTofu crea los LXC y Ansible despliega los contenedores Docker.

### Paso 1 — Crear LXC (root `tofu apply`)

Los 3 nodos HDFS están definidos en `var.hdfs_nodes` del proyecto principal y se aprovisionan como parte del **root `tofu apply`**, igual que el resto de CTs de la nube local. OpenTofu crea un LXC Debian por nodo Proxmox con IP estática en la LAN de gestión:

| CT | Proxmox node | IP LAN | vmid |
|---|---|---|---|
| `hdfs-namenode` | `pve-local` | `10.10.1.21` | 121 |
| `hdfs-datanode0` | `pve-local2` | `10.10.1.22` | 122 |
| `hdfs-datanode1` | `pve-local3` | `10.10.1.23` | 123 |

El hookscript `cloud-init/lxc-bootstrap.sh.tftpl` instala openssh y Python3 dentro del LXC al arrancar.

### Paso 2 — Desplegar NameNode y DataNodes (Ansible)

El playbook `ansible/hdfs.yml` ejecuta `roles/docker` + `roles/hdfs` sobre el grupo `[hdfs]`. Las imágenes se descargan directamente de **Docker Hub** (los LXC tienen salida a Internet vía el gateway `10.10.1.1`):

| Contenedor | Host LXC | IP | Imagen |
|---|---|---|---|
| `webhardmon-hdfs-namenode` | 10.10.1.21 | — | `bde2020/hadoop-namenode:2.0.0-hadoop3.2.1-java8` |
| `webhardmon-hdfs-datanode` (×2) | 10.10.1.22, 10.10.1.23 | — | `bde2020/hadoop-datanode:2.0.0-hadoop3.2.1-java8` |

Para servir las imágenes desde Harbor en lugar de Docker Hub, basta con poner `hdfs_registry_prefix: "harbor.hardmon.eus/"` en `group_vars/hdfs.yml` y hacer `docker tag + push` de las imágenes allí.

**Topología resultante:**

```
pve-local  → LXC 10.10.1.21 → Docker → webhardmon-hdfs-namenode  (9000/9870)
pve-local2 → LXC 10.10.1.22 → Docker → webhardmon-hdfs-datanode  (DataNode-0)
pve-local3 → LXC 10.10.1.23 → Docker → webhardmon-hdfs-datanode  (DataNode-1)
```

**Verificación post-despliegue:**

```bash
# NameNode UI — debe listar 2 DataNodes vivos
# http://10.10.1.21:9870 (pestaña Datanodes)

ssh -p 2222 ubuntu@10.10.1.21 \
  "docker exec webhardmon-hdfs-namenode hdfs dfsadmin -report"

# Crear directorio de telemetría si no existe
ssh -p 2222 ubuntu@10.10.1.21 \
  "docker exec webhardmon-hdfs-namenode hdfs dfs -mkdir -p /data/telemetry"
```

---

## 5. Por qué se eligió HDFS

- **Lambda Architecture requiere cold storage**: los datos de streaming (Cassandra) son costosos de consultar en rango horario/diario a gran escala. HDFS + Parquet proporciona un almacén barato, columnar y comprimido para procesar por lotes.
- **Parquet sobre HDFS = entrada nativa de MapReduce**: la integración `AvroParquetInputFormat` permite que el job MapReduce lea los ficheros sin transformación adicional.
- **Entrada de MapReduce**: HDFS es la única fuente de datos para el job de agregación. Sin HDFS no habría capa batch ni histórico en HBase.
- **Coste**: la nube local (Proxmox) tiene almacenamiento persistente y sin coste de GCP. Mantener los datos fríos aquí evita facturación de egress y almacenamiento en GCP.
- **Separación de preocupaciones**: HDFS/MapReduce/HBase forman una pila batch autónoma. Un fallo en el streaming (Kafka/Cassandra) no afecta a los datos históricos.

---

## 6. Puertos de referencia

| Servicio | Host | Puerto | Descripción |
|---|---|---|---|
| HDFS NameNode RPC | 10.10.1.21 | 9000 | Acceso de clientes (Java Bridge, MapReduce, HBase) |
| HDFS NameNode UI | 10.10.1.21 | 9870 | Dashboard web del clúster |
| DataNode-0 | 10.10.1.22 | 9864 | DataNode UI |
| DataNode-1 | 10.10.1.23 | 9864 | DataNode UI |
