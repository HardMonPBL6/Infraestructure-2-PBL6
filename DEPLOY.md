# WebHardMon · Guía de despliegue completo

Orden y comandos exactos para levantar toda la plataforma desde cero.  
El despliegue tiene **tres fases**: infraestructura (OpenTofu), imágenes Docker y configuración de servicios (Ansible).

---

## Arquitectura final desplegada

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  NUBE LOCAL · Proxmox LXC                                                   │
│  ┌──────────────┐  ┌─────────────────────────────────────────┐              │
│  │   Harbor     │  │  NiFi + cloudflared                     │              │
│  │ 10.10.2.111  │  │  UI :8080  │  Ingest :8081 (CF Tunnel)  │              │
│  │ (TLS :443)   │  │                                         │              │
│  └──────────────┘  └─────────────────────────────────────────┘              │
│  ┌──────────────────────────────────────────────────────────┐               │
│  │  HDFS  NameNode :10.10.1.21  DataNode-0 :21  DN-1 :23   │               │
│  └──────────────────────────────────────────────────────────┘               │
└─────────────────────────────────────────────────────────────────────────────┘
              │ WireGuard mesh 10.0.0.0/24
┌─────────────────────────────────────────────────────────────────────────────┐
│  GCP-A · europe-southwest1  (3 VMs spot e2-standard-4)                      │
│  node-01  10.20.1.10  WG:10.0.0.20  │ ZooKeeper · Kafka · Cassandra        │
│                                      │ Schema Registry (singleton)          │
│  node-02  10.20.2.11                 │ ZooKeeper · Kafka · Cassandra        │
│                                      │ Java RMI · Java Bridge               │
│  node-03  10.20.2.12                 │ ZooKeeper · Kafka · Cassandra        │
│                                      │ Java RMI                             │
└─────────────────────────────────────────────────────────────────────────────┘
              │ WireGuard routing
┌─────────────────────────────────────────────────────────────────────────────┐
│  GCP-B · europe-west1  (3 VMs spot e2-standard-4)                          │
│  node-01  10.30.1.10  WG:10.0.0.30  │ HBase Master · REST :8085            │
│                                      │ Grafana :3000 · Matomo :8282        │
│                                      │ Web Panel :8080                      │
│  node-02  10.30.2.11                 │ HBase RegionServer · MySQL :3307     │
│  node-03  10.30.2.12                 │ HBase RegionServer                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Fase 0 — Prerequisitos en el nodo de gestión

```bash
# Herramientas necesarias
tofu --version        # >= 1.6
ansible --version     # >= 2.14
docker --version      # para construir imágenes
wg --version          # para generar claves WireGuard

# Colección Docker de Ansible
ansible-galaxy collection install community.docker
```

---

## Fase 1 — Infraestructura con OpenTofu

### 1.1 Preparar credenciales

```bash
# Copiar plantilla de variables
cp terraform.tfvars.example terraform.tfvars
# Editar terraform.tfvars con los valores reales:
#   - proxmox_endpoint, proxmox_api_token, proxmox_ssh_private_key
#   - gcp_a_project_id, gcp_a_credentials_file
#   - gcp_b_project_id, gcp_b_credentials_file
#   - local_ct_ssh_pubkey
#   - wg_* (claves WireGuard, ver paso 1.2)
#   - cloudflare_* (API token, account_id, zone_id, zone_name)
```

### 1.2 Generar claves WireGuard

```bash
# Un par de claves por gateway (ejecutar UNA VEZ y guardar en terraform.tfvars)
wg genkey | tee gcp-a-private.key | wg pubkey > gcp-a-public.key
wg genkey | tee gcp-b-private.key | wg pubkey > gcp-b-public.key
wg genkey | tee mgmt-private.key  | wg pubkey > mgmt-public.key
wg genkey | tee local-gw-private.key | wg pubkey > local-gw-public.key

cat gcp-a-private.key   # → wg_gcp_a_private_key en terraform.tfvars
cat gcp-a-public.key    # → wg_gcp_a_public_key
# Repetir para b, mgmt y local-gw
```

### 1.3 Provisionar infraestructura principal (3 nubes)

```bash
cd /ruta/al/repo/Infraestructure-2-PBL6

tofu init
tofu plan    # verificar el plan antes de aplicar
tofu apply   # ~5-8 min; crea VMs, redes, WireGuard, Artifact Registry, inventory.ini
```

**Qué crea este `tofu apply`:**
- **Proxmox**: LXC containers (host Docker) para NiFi, Harbor, los 3 nodos HDFS (10.10.1.21/22/23, ver 1.4) y el CT dedicado de MapReduce (10.10.1.24, ver 3.6)
- **GCP-A**: VPC + subredes pública/privada + Cloud NAT + 3 VMs spot + Artifact Registry
- **GCP-B**: VPC + subredes pública/privada + Cloud NAT + 3 VMs spot + Artifact Registry
- **WireGuard**: IPs estáticas reservadas, `wg0.conf` inyectado vía cloud-init en node-01 de cada nube
- **Cloudflare Tunnel**: túnel + registro DNS `ingest.<zona>` + service token para colectores
- **`ansible/inventory.ini`**: generado automáticamente con todos los hosts y grupos

```bash
# Verificar outputs importantes
tofu output wireguard_gateway_ips   # → IPs para configurar gateway local y nodo de gestión
tofu output -raw cloudflared_tunnel_token   # → guardar para el despliegue de NiFi
tofu output container_registries            # → URLs de Artifact Registry por nube
```

### 1.4 HDFS — incluido en el `tofu apply` (nube local)

Los 3 nodos HDFS ya **no** son un proyecto aparte: el `tofu apply` de §1.1 crea un CT
host-Docker por nodo PVE en la LAN de gestión (`var.hdfs_nodes`):

| CT | Nodo PVE | IP | Rol |
|----|----------|----|-----|
| `hdfs-namenode`  | pve-local  | 10.10.1.21 | NameNode |
| `hdfs-datanode0` | pve-local2 | 10.10.1.22 | DataNode |
| `hdfs-datanode1` | pve-local3 | 10.10.1.23 | DataNode |

> El mismo `tofu apply` crea además el CT **`mapreduce`** (`10.10.1.24`, pve-local, `var.mapreduce_node`), host del job batch — ver §3.6. No es un nodo HDFS.

El clúster HDFS en sí (contenedores `bde2020/hadoop-*`) lo despliega **Ansible** en la
fase de servicios, igual que el resto: `ansible-playbook -i ansible/inventory.ini ansible/hdfs.yml`
(ya incluido en `site.yml`, tras NiFi). Verificación tras ese play:

```bash
# Debe mostrar 2 DataNodes en estado Live (ubuntu@2222 tras security.yml)
ssh -p 2222 ubuntu@10.10.1.21 \
  "docker exec webhardmon-hdfs-namenode hdfs dfsadmin -report"

# Crear directorio de telemetría para el camino cold (Parquet del Java bridge)
ssh -p 2222 ubuntu@10.10.1.21 \
  "docker exec webhardmon-hdfs-namenode hdfs dfs -mkdir -p /data/telemetry"

# UI del NameNode: http://10.10.1.21:9870
```

---

## Fase 2 — Construir y subir imágenes Docker

```bash
cd /ruta/al/repo/Infraestructure-2-PBL6/docker/

# Configurar variables de entorno
export GCP_A_PROJECT="webhardmon-a-XXXXX"
export GCP_B_PROJECT="webhardmon-b-XXXXX"
export HARBOR_HOST="harbor.example.com"   # = tofu output harbor_hostname (TLS, Let's Encrypt)
export IMAGE_TAG="1.0"

# Autenticación
gcloud auth configure-docker \
  europe-southwest1-docker.pkg.dev,europe-west1-docker.pkg.dev

# Harbor sirve con TLS (cert público de Let's Encrypt), así que NO hace falta
# insecure-registries ni CA extra. OJO con el orden: para SUBIR imágenes locales
# (nifi, mapreduce) Harbor ya debe estar desplegado (ver 3.1b) y resoluble.
docker login "$HARBOR_HOST"

# Construir y subir TODO (orden no importa, son independientes)
./build-and-push.sh

# O por nube si prefieres:
./build-and-push.sh zookeeper kafka schema-registry cassandra  # → GCP-A
./build-and-push.sh nifi                                        # → Harbor local
./build-and-push.sh hbase mysql grafana matomo                  # → GCP-B

# Los servicios Java (stressscore + web) requieren el submódulo inicializado:
git submodule update --init --recursive
./build-and-push.sh java-stressscore stressscore-bridge web     # → GCP-A / GCP-B
```

**Imágenes y sus registros:**

| Imagen | Registro | Nodo destino |
|--------|----------|--------------|
| `zookeeper` | Artifact Registry GCP-A | node-01/02/03 |
| `kafka` | Artifact Registry GCP-A | node-01/02/03 |
| `schema-registry` | Artifact Registry GCP-A | node-01 |
| `cassandra` | Artifact Registry GCP-A | node-01/02/03 |
| `java-stressscore` | Artifact Registry GCP-A | node-02/03 |
| `stressscore-bridge` | Artifact Registry GCP-A | node-02 |
| `nifi` | Harbor local | LXC NiFi |
| `hbase` | Artifact Registry GCP-B | node-01/02/03 |
| `mysql` | Artifact Registry GCP-B | node-02 |
| `grafana` | Artifact Registry GCP-B | node-01 |
| `matomo` | Artifact Registry GCP-B | node-01 |
| `web` | Artifact Registry GCP-B | node-01 |

---

## Fase 3 — Configurar servicios con Ansible

### 3.0 Preparar secretos (vault)

```bash
# Crear fichero de vault con todas las contraseñas
ansible-vault create ansible/vault.yml
```

Contenido mínimo:
```yaml
vault_mysql_root_password:        "elige-una-password"
vault_mysql_app_password:         "elige-una-password"
vault_cassandra_password:         "cassandra"
vault_grafana_admin_password:     "elige-una-password"
vault_matomo_mysql_password:      "elige-una-password"
vault_matomo_mysql_root_password: "elige-una-password"
vault_cloudflared_tunnel_token:   "<salida de: tofu output -raw cloudflared_tunnel_token>"
vault_harbor_admin_password:      "elige-una-password"
vault_harbor_db_password:         "elige-una-password"
vault_cloudflare_api_token:       "<token Cloudflare con Zone:DNS:Edit — para el cert TLS de Harbor (DNS-01)>"
```

```bash
# Verificar inventario generado por OpenTofu
cat ansible/inventory.ini

# Test de conectividad antes de empezar
ansible -i ansible/inventory.ini all -m ping --ask-vault-pass
```

### 3.1 Seguridad — SIEMPRE PRIMERO

```bash
ansible-playbook -i ansible/inventory.ini ansible/security.yml \
  --vault-password-file ~/.vault_pass
```

Cambia el puerto SSH de 22 → 2222 en todos los hosts. Los playbooks siguientes se conectan en 2222.

### 3.1b Harbor — registro de contenedores local (TLS)

Despliega el registro **antes** de subir/usar imágenes locales (nifi, mapreduce).
Sirve con TLS bajo `harbor.<zona>` (cert de Let's Encrypt por DNS-01). El registro
DNS lo crea OpenTofu; pon el FQDN en `group_vars/cloud_local.yml` (`harbor_hostname`).

```bash
ansible-playbook -i ansible/inventory.ini ansible/harbor.yml \
  --vault-password-file ~/.vault_pass

# Acceso: https://harbor.<zona>  (admin / vault_harbor_admin_password)
```

> Después de esto, vuelve a la Fase 2 para `docker login harbor.<zona>` y
> `./build-and-push.sh nifi mapreduce` (las imágenes locales van a este Harbor).

### 3.2 GCP-A — servicios de streaming

```bash
# ZooKeeper (ensemble de 3, serial: node-01 primero como líder)
ansible-playbook -i ansible/inventory.ini ansible/zookeeper.yml \
  --vault-password-file ~/.vault_pass

# Verificar ensemble ZK
echo ruok | nc 10.0.0.20 2181   # imok
echo ruok | nc 10.20.2.11 2181  # imok
echo ruok | nc 10.20.2.12 2181  # imok

# Kafka (3 brokers)
ansible-playbook -i ansible/inventory.ini ansible/kafka.yml \
  --vault-password-file ~/.vault_pass

# Verificar brokers
# ssh ubuntu@10.0.0.20 -p 2222 "docker exec zookeeper \
#   zookeeper-shell localhost:2181 ls /brokers/ids"
# → [0, 1, 2]

# Schema Registry (singleton node-01)
ansible-playbook -i ansible/inventory.ini ansible/schema_registry.yml \
  --vault-password-file ~/.vault_pass

# Verificar
curl http://10.0.0.20:8081/subjects   # → []

# Cassandra (serial: seed node-01 primero)
ansible-playbook -i ansible/inventory.ini ansible/cassandra.yml \
  --vault-password-file ~/.vault_pass

# Verificar anillo (todos en UN = Up/Normal)
# ssh ubuntu@10.0.0.20 -p 2222 "docker exec cassandra nodetool status"
```

### 3.3 GCP-B — analítica y servicio

```bash
# MySQL (node-02, subred privada)
ansible-playbook -i ansible/inventory.ini ansible/mysql.yml \
  --vault-password-file ~/.vault_pass

# HBase (3 nodos, serial: Master en node-01 primero)
# Prerequisito: HDFS local debe estar corriendo (rootdir en hdfs://10.10.1.21:9000)
ansible-playbook -i ansible/inventory.ini ansible/hbase.yml \
  --vault-password-file ~/.vault_pass

# Verificar HBase Master UI: http://10.0.0.30:16010
# Verificar tabla creada:
# ssh ubuntu@10.0.0.30 -p 2222 "docker exec hbase-master \
#   hbase shell -n <<<'list_tables'"
# → webhardmon_hourly

# Grafana (node-01)
ansible-playbook -i ansible/inventory.ini ansible/grafana.yml \
  --vault-password-file ~/.vault_pass

# Acceso: http://10.0.0.30:3000  (admin / contraseña del vault)

# Matomo (node-01)
ansible-playbook -i ansible/inventory.ini ansible/matomo.yml \
  --vault-password-file ~/.vault_pass

# Acceso: http://10.0.0.30:8282  (completar wizard en primer acceso)
```

### 3.4 Nube local — ingesta

```bash
# NiFi + cloudflared (LXC nube local)
ansible-playbook -i ansible/inventory.ini ansible/nifi.yml \
  --vault-password-file ~/.vault_pass

# Acceso NiFi UI: http://<ip-lxc-nifi>:8080/nifi
```

⚠️ **Post-despliegue de NiFi** — la lógica del flujo se configura en la UI:
- Controller Service: `ConfluentSchemaRegistry` → URL: `http://10.0.0.20:8081`
- Controller Service: JDBC LookupService → `jdbc:mysql://10.30.2.11:3307/telemetriadb`
- Processor: `ListenHTTP` en puerto 8081 (destino del túnel Cloudflare)
- Processor: `PublishKafkaRecord_2_6` → bootstrap: `10.20.1.10:9092,10.20.2.11:9092,10.20.2.12:9092`

### 3.5 Aplicaciones Java y panel web

```bash
# StressScore: nodos RMI (node-02/03) + puente Kafka→RMI→Cassandra (node-02)
ansible-playbook -i ansible/inventory.ini ansible/stressscore.yml \
  --vault-password-file ~/.vault_pass

# Panel web Spring Boot (node-01 gcp-b)
ansible-playbook -i ansible/inventory.ini ansible/web.yml \
  --vault-password-file ~/.vault_pass

# Acceso webapp: http://10.0.0.30:8080
```

### 3.6 MapReduce batch (cuando haya datos en HDFS)

El job corre como contenedor Docker **efímero** en su CT dedicado (`10.10.1.24`), no
dentro del NameNode. Requiere la imagen `mapreduce` en Harbor (Fase 2,
`./build-and-push.sh mapreduce`).

```bash
# Desplegar el job MapReduce en su CT dedicado (instala Docker + pull imagen + cron)
ansible-playbook -i ansible/inventory.ini ansible/mapreduce.yml \
  --vault-password-file ~/.vault_pass

# El cron corre cada hora a :10 → docker run --rm → agrega HDFS Parquet → HBase webhardmon_hourly
# Ejecución manual:
ssh -p 2222 ubuntu@10.10.1.24 "sudo /usr/local/bin/run-webhardmon-aggregation.sh"
```

---

## Resumen de servicios desplegados

### GCP-A — Streaming (3 nodos spot, europe-southwest1)

| Servicio | Nodo | IP interna | Puerto | Rol en la arquitectura |
|---------|------|-----------|--------|----------------------|
| **ZooKeeper** | node-01/02/03 | 10.20.1.10, 10.20.2.11/12 | 2181 | Coordinación de Kafka y HBase |
| **Kafka** | node-01/02/03 | 10.20.1.10, 10.20.2.11/12 | 9092 | Bus asíncrono de métricas (Avro) |
| **Schema Registry** | node-01 | 10.20.1.10 | 8081 | Registro centralizado de esquemas Avro (BACKWARD compat.) |
| **Cassandra** | node-01/02/03 | 10.20.1.10, 10.20.2.11/12 | 9042 | TSDB caliente — datos recientes (RF=3, 16 vnodes) |
| **Java RMI** | node-02/03 | 10.20.2.11/12 | 1099/1100 | Cálculo de StressScore (servicio concurrente RMI) |
| **Java Bridge** | node-02 | 10.20.2.11 | — | Consume Kafka → llama RMI → escribe Cassandra |

### GCP-B — Analítica y servicio (3 nodos spot, europe-west1)

| Servicio | Nodo | IP interna | Puerto | Rol en la arquitectura |
|---------|------|-----------|--------|----------------------|
| **HBase Master** | node-01 | 10.30.1.10 | 16000/16010 | Capa served batch (Lambda Architecture) |
| **HBase REST** | node-01 | 10.30.1.10 | 8085 | API para Grafana y webapp |
| **HBase RegionServer** | node-01/02/03 | 10.30.1.10, 10.30.2.11/12 | 16020/16030 | 8 regiones pre-split — sharding (requisito N2) |
| **MySQL** | node-02 | 10.30.2.11 | 3307 | BD aplicación: empresa, administrador, usuario, licencia |
| **Grafana** | node-01 | 10.30.1.10 | 3000 | Capa service / EOD — dashboards en tiempo real e histórico |
| **Matomo** | node-01 | 10.30.1.10 | 8282 | Analítica web del panel (EOD HMI — comportamiento usuario) |
| **Web Panel** | node-01 | 10.30.1.10 | 8080 | Spring Boot — interfaz de gestión y visualización |

### Nube local — Ingesta y almacenamiento

| Servicio | IP | Puerto | Rol en la arquitectura |
|---------|-----|--------|----------------------|
| **NiFi** | LXC ~10.10.x.x | 8080 (UI), 8081 (ingest) | Valida licencias, serializa Avro, produce a Kafka |
| **cloudflared** | mismo LXC | — | Túnel saliente → `https://ingest.<zona>` → NiFi:8081 |
| **HDFS NameNode** | 10.10.1.21 | 9000 (RPC), 9870 (UI) | Data lake Parquet — capa cold del Lambda Architecture |
| **HDFS DataNode-0** | 10.10.1.22 | — | Almacenamiento distribuido (replicación ×2) |
| **HDFS DataNode-1** | 10.10.1.23 | — | Almacenamiento distribuido |
| **Harbor** | 10.10.2.111 (`harbor.<zona>`) | 443 (TLS) | Registro Docker para imágenes de la nube local (cert Let's Encrypt DNS-01) |
| **MapReduce job** | 10.10.1.24 (CT dedicado, cron) | — | Contenedor efímero: lee Parquet HDFS → agrega → escribe HBase (cada hora :10) |

---

## Flujo de datos extremo a extremo

```
Agente PC (usuario real)
   │ HTTPS + CF-Access token
   ▼
Cloudflare Edge → Tunnel → NiFi:8081
   │ valida licencia (JDBC → MySQL 10.30.2.11:3307)
   │ serializa Avro (Schema Registry 10.0.0.20:8081)
   ▼
Kafka 9092 (3 brokers GCP-A, Avro, RF=3)
   │
   ├──► Java Bridge (consume Avro)
   │        │ calcula StressScore via RMI (10.20.2.11/12:1099)
   │        ├──► Cassandra:9042 (hot, datos recientes) ──► Grafana:3000
   │        └──► HDFS /data/telemetry (Parquet, cold)
   │                    │
   │            [cron :10 cada hora]
   │                    ▼
   │             MapReduce job
   │             (contenedor dedicado 10.10.1.24)
   │                    │ agrega avg/min/max/count por licencia+hora
   │                    ▼
   │             HBase webhardmon_hourly ──────────────► Grafana:3000
   │             (REST :8085, Lambda served)
   │
   └──────────────────────────────────────────────────► Web Panel:8080
                                                         (Spring Boot, lee
                                                          MySQL + Cassandra)
```

---

## Verificación final

```bash
# WireGuard — todos los gateways alcanzan los demás
ping -c 2 10.0.0.20   # GCP-A gateway
ping -c 2 10.0.0.30   # GCP-B gateway

# GCP-A
echo ruok | nc 10.0.0.20 2181          # ZooKeeper: imok
curl http://10.0.0.20:8081/subjects    # Schema Registry: []

# GCP-B
curl http://10.0.0.30:3000/api/health  # Grafana: {"database":"ok"...}
curl -I http://10.0.0.30:8080          # Web Panel: HTTP 200
curl http://10.0.0.30:8085/            # HBase REST: lista de tablas

# HDFS
ssh -p 2222 ubuntu@10.10.1.21 \
  "docker exec webhardmon-hdfs-namenode hdfs dfsadmin -report" | grep "Live datanodes"
# → Live datanodes (2):

# NiFi UI
curl -I http://<ip-nifi>:8080/nifi    # HTTP 200
```

---

## Configuración WireGuard en el gateway local y nodo de gestión

Después del `tofu apply`, obtener las IPs estáticas de GCP:

```bash
tofu output wireguard_gateway_ips
# gcp_a_gateway_ip = "34.x.x.x"
# gcp_b_gateway_ip = "34.x.x.x"
```

Añadir estos peers en el gateway local (`/etc/wireguard/wg0.conf`):

```ini
[Peer]  # GCP-A
PublicKey = <wg_gcp_a_public_key>
Endpoint = 34.x.x.x:51820
AllowedIPs = 10.0.0.20/32, 10.20.0.0/16

[Peer]  # GCP-B
PublicKey = <wg_gcp_b_public_key>
Endpoint = 34.x.x.x:51820
AllowedIPs = 10.0.0.30/32, 10.30.0.0/16
```

Y en el nodo de gestión (laptop):

```ini
[Peer]  # GCP-A
PublicKey = <wg_gcp_a_public_key>
Endpoint = 34.x.x.x:51820
AllowedIPs = 10.0.0.20/32, 10.20.0.0/16

[Peer]  # GCP-B
PublicKey = <wg_gcp_b_public_key>
Endpoint = 34.x.x.x:51820
AllowedIPs = 10.0.0.30/32, 10.30.0.0/16

[Peer]  # Gateway local
PublicKey = <wg_local_gw_public_key>
Endpoint = <IP-pública-gateway-local>:51820
AllowedIPs = 10.0.0.10/32, 10.10.0.0/16
```
