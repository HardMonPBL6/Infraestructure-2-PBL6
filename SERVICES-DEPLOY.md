# WebHardMon · Despliegue de servicios base

Guía completa para construir las imágenes Docker, entender la arquitectura de red y desplegar todos los servicios base de WebHardMon en orden.

---

## 1. Arquitectura de red — dos subredes por nube

Cada nube tiene dos redes con propósitos distintos:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  NUBE LOCAL (Proxmox)                                                    │
│  Red gestión (pública):  10.10.1.x  ← NiFi, Harbor, HDFS NameNode      │
│  Red datos  (privada):   10.10.2.x  ← HDFS DataNodes                   │
└──────────────────────────────────────────────────────────────────────────┘
            │ WireGuard mesh (10.0.0.x)
┌──────────────────────────────────────────────────────────────────────────┐
│  GCP-A  (europe-southwest1)                                              │
│  Red gestión (subred pública):   10.20.1.x  ← node-01 (gateway WG)     │
│    node-01  10.20.1.10  WG: 10.0.0.20  →  ZK, Kafka, Schema Registry   │
│  Red datos  (subred privada):    10.20.2.x  ← node-02/03               │
│    node-02  10.20.2.11           →  ZK, Kafka, Cassandra, Java RMI      │
│    node-03  10.20.2.12           →  ZK, Kafka, Cassandra, Java RMI      │
└──────────────────────────────────────────────────────────────────────────┘
            │ WireGuard routing
┌──────────────────────────────────────────────────────────────────────────┐
│  GCP-B  (europe-west1)                                                   │
│  Red gestión (subred pública):   10.30.1.x  ← node-01 (gateway WG)     │
│    node-01  10.30.1.10  WG: 10.0.0.30  →  Grafana, Matomo, HBase M.    │
│  Red datos  (subred privada):    10.30.2.x  ← node-02/03               │
│    node-02  10.30.2.11           →  MySQL, HBase RS                     │
│    node-03  10.30.2.12           →  Elasticsearch, HBase RS             │
└──────────────────────────────────────────────────────────────────────────┘
```

### Principios de binding por tipo de servicio

| Tipo | bind address | Puerto accesible desde |
|------|-------------|------------------------|
| **Datos cluster** (ZK, Kafka, Cassandra) | `inventory_hostname` (IP interna GCP) | VPC interna + WireGuard routing desde otras nubes |
| **UI/gestión** (Grafana, Matomo, NiFi) | `0.0.0.0` | Red gestión: WireGuard 10.0.0.x → nodo de gestión |
| **BD privada** (MySQL) | `0.0.0.0` (firewall GCP restringe) | Red datos: solo VPC gcp-b + WireGuard routing |
| **Singleton de API** (Schema Registry) | `0.0.0.0` | Red datos: VPC gcp-a + WireGuard desde local/gcp-b |

---

## 2. Paso previo — construir y subir imágenes

Antes de desplegar cualquier servicio, sus imágenes deben estar en el registro correspondiente.

### Variables de entorno necesarias

```bash
export GCP_A_PROJECT="webhardmon-a-XXXXX"   # tu project_id real de GCP-A
export GCP_B_PROJECT="webhardmon-b-XXXXX"   # tu project_id real de GCP-B
export HARBOR_HOST="10.10.1.50:5000"        # Harbor en la nube local
export IMAGE_TAG="1.0"
```

### Autenticación previa

```bash
# GCP Artifact Registry
gcloud auth configure-docker europe-southwest1-docker.pkg.dev,europe-west1-docker.pkg.dev

# Harbor (nube local) — hacer login una vez
docker login 10.10.1.50:5000
```

### Construir todas las imágenes de una vez

```bash
cd docker/
./build-and-push.sh
```

O por servicio (si solo quieres reconstruir uno):

```bash
./build-and-push.sh zookeeper kafka schema-registry cassandra
./build-and-push.sh nifi
./build-and-push.sh mysql grafana matomo hbase
```

### Mapa de imágenes por nube

| Servicio | Imagen base | Registro destino |
|---------|-------------|-----------------|
| `zookeeper` | `confluentinc/cp-zookeeper:7.6.1` | Artifact Registry GCP-A |
| `kafka` | `confluentinc/cp-kafka:7.6.1` | Artifact Registry GCP-A |
| `schema-registry` | `confluentinc/cp-schema-registry:7.6.1` | Artifact Registry GCP-A |
| `cassandra` | `cassandra:4.1` + custom entrypoint | Artifact Registry GCP-A |
| `nifi` | `apache/nifi:2.0.0` | Harbor local |
| `mysql` | `mysql:8.0` + init.sql | Artifact Registry GCP-B |
| `hbase` | `eclipse-temurin:11-jre` + tarball | Artifact Registry GCP-B |
| `grafana` | `grafana/grafana:10.4.0` + plugin Cassandra | Artifact Registry GCP-B |
| `matomo` | `matomo:5.1` | Artifact Registry GCP-B |

---

## 3. Credenciales y secretos

Antes de desplegar servicios que usan contraseñas, crear un fichero de vault de Ansible:

```bash
ansible-vault create ansible/vault.yml
```

Contenido mínimo:

```yaml
vault_mysql_root_password:       "cambia-esto"
vault_mysql_app_password:        "cambia-esto"
vault_cassandra_password:        "cassandra"        # default de la imagen oficial
vault_grafana_admin_password:    "cambia-esto"
vault_matomo_mysql_password:     "cambia-esto"
vault_matomo_mysql_root_password: "cambia-esto"
vault_cloudflared_tunnel_token:  "token-de-tofu-output"
```

Para obtener el token de cloudflared:
```bash
tofu output -raw cloudflared_tunnel_token
```

Pasar el vault en los playbooks:
```bash
ansible-playbook -i ansible/inventory.ini ansible/site.yml --ask-vault-pass
# o con fichero de password:
ansible-playbook -i ansible/inventory.ini ansible/site.yml --vault-password-file ~/.vault_pass
```

---

## 4. Orden de despliegue

### 4.1 Prerequisitos globales (una sola vez)

```bash
# 1. Provisionar infraestructura con OpenTofu
tofu apply                        # genera ansible/inventory.ini

# 2. Seguridad en todos los hosts (SSH, Fail2ban) — SIEMPRE PRIMERO
ansible-playbook -i ansible/inventory.ini ansible/security.yml

# 3. Verificar WireGuard (desde el nodo de gestión)
ping -c 2 10.0.0.20   # gcp-a gateway
ping -c 2 10.0.0.30   # gcp-b gateway
```

### 4.2 GCP-A — servicios de streaming

Los servicios de GCP-A tienen dependencias en cadena:

```
ZooKeeper  →  Kafka  →  Schema Registry
Cassandra  (independiente, se puede desplegar en paralelo con ZK)
```

```bash
# 1. ZooKeeper (ensemble de 3, serial: node-01 primero)
ansible-playbook -i ansible/inventory.ini ansible/zookeeper.yml

# Verificar ensemble:
# En cualquier nodo gcp-a:
echo ruok | nc 10.20.1.10 2181   # debe responder: imok
echo ruok | nc 10.20.2.11 2181
echo ruok | nc 10.20.2.12 2181

# 2. Kafka (3 brokers, espera ZK activo)
ansible-playbook -i ansible/inventory.ini ansible/kafka.yml

# Verificar brokers registrados:
# docker exec zookeeper zookeeper-shell localhost:2181 ls /brokers/ids
# debe listar [0, 1, 2]

# 3. Schema Registry (singleton en node-01, espera Kafka activo)
ansible-playbook -i ansible/inventory.ini ansible/schema_registry.yml

# Verificar:
curl http://10.0.0.20:8081/subjects   # debe devolver []

# 4. Cassandra (serial: seed node-01 primero)
ansible-playbook -i ansible/inventory.ini ansible/cassandra.yml

# Verificar anillo (en cualquier nodo gcp-a):
# docker exec cassandra nodetool status
# Todos los nodos deben aparecer como UN (Up/Normal)
```

### 4.3 GCP-B — analítica y servicio

```bash
# 5. MySQL (singleton en node-02, subred privada)
ansible-playbook -i ansible/inventory.ini ansible/mysql.yml \
  --ask-vault-pass

# Verificar:
# ssh ubuntu@10.0.0.30 "docker exec mysql mysql -uwebhardmon -p -e 'SHOW DATABASES;'"

# 6. HBase (3 nodos, serial: Master primero — requiere HDFS local activo)
ansible-playbook -i ansible/inventory.ini ansible/hbase.yml

# Verificar Master UI:
curl http://10.0.0.30:16010/master-status | grep -i regionserver

# 7. Grafana (node-01, tras Cassandra + MySQL + HBase)
ansible-playbook -i ansible/inventory.ini ansible/grafana.yml \
  --ask-vault-pass

# Acceso: http://10.0.0.30:3000 (admin/admin por defecto, cambiar en primer acceso)

# 8. Matomo (node-01, independiente)
ansible-playbook -i ansible/inventory.ini ansible/matomo.yml \
  --ask-vault-pass

# Acceso: http://10.0.0.30:8282 (completar wizard de instalación la primera vez)
```

### 4.4 Nube local — ingesta

```bash
# 9. NiFi + cloudflared (CT nube local — requiere Kafka + Schema Registry + MySQL activos)
ansible-playbook -i ansible/inventory.ini ansible/nifi.yml \
  -e "vault_cloudflared_tunnel_token=$(tofu output -raw cloudflared_tunnel_token)"

# Acceso NiFi UI: http://<ip-ct-nifi>:8080/nifi
```

### 4.5 Aplicaciones Java y panel web

```bash
# 10. StressScore (Java RMI cluster + bridge)
ansible-playbook -i ansible/inventory.ini ansible/stressscore.yml

# 11. Web panel (Spring Boot)
ansible-playbook -i ansible/inventory.ini ansible/web.yml

# 12. Job MapReduce (batch, tras HBase + HDFS con datos)
ansible-playbook -i ansible/inventory.ini ansible/mapreduce.yml
```

### Despliegue completo de una vez

Una vez verificados los prerequisitos, el `site.yml` orquesta todo en orden:

```bash
ansible-playbook -i ansible/inventory.ini ansible/site.yml --ask-vault-pass
```

---

## 5. Descripción de cada servicio

### ZooKeeper (GCP-A, 3 nodos)

- **Rol**: coordinación distribuida para Kafka (almacena metadatos de brokers y topics).
- **Red**: tráfico de peers 2888/3888 en VPC interna gcp-a. Puerto cliente 2181 accesible desde cualquier nodo del VPC y vía WireGuard routing.
- **Imagen**: `confluentinc/cp-zookeeper:7.6.1` (misma CP que Kafka → protocolo garantizado).
- **Config clave**: `ZOOKEEPER_SERVER_ID` = posición en el grupo (1,2,3) — determinista tras preempción spot.
- **Ficheros**: `docker/zookeeper/Dockerfile`, `ansible/roles/zookeeper/`, `ansible/zookeeper.yml`, `ansible/group_vars/zookeeper.yml`.

### Kafka (GCP-A, 3 brokers)

- **Rol**: bus de mensajes asíncrono. NiFi produce mensajes Avro; Java bridge los consume.
- **Red**: listener único `PLAINTEXT://inventory_hostname:9092`. La IP interna GCP es alcanzable desde otras nubes vía WireGuard routing. No se expone a Internet.
- **Imagen**: `confluentinc/cp-kafka:7.6.1` — misma línea CP que ZooKeeper.
- **Config clave**: `KAFKA_BROKER_ID` determinista (0,1,2). RF=3, min ISR=2, particiones=3 (requisito N2 sharding).
- **Ficheros**: `docker/kafka/Dockerfile`, `ansible/roles/kafka/`, `ansible/kafka.yml`, `ansible/group_vars/kafka.yml`.

### Schema Registry (GCP-A, node-01)

- **Rol**: registro central de esquemas Avro. NiFi serializa contra él; el bridge Java deserializa. Compatibilidad BACKWARD permite evolucionar el collector sin romper consumidores.
- **Red**: escucha en `0.0.0.0:8081`. Accesible desde NiFi (local) vía WireGuard (10.0.0.20:8081) y desde el bridge (gcp-a VPC, 10.20.1.10:8081). Node-01 está en la **subred pública** (red gestión), lo que facilita el acceso inter-nube.
- **Imagen**: `confluentinc/cp-schema-registry:7.6.1` (ya existía en `docker/schema-registry/`).
- **Ficheros**: `ansible/roles/schema_registry/`, `ansible/schema_registry.yml`, `ansible/group_vars/schema_registry.yml`.

### Cassandra (GCP-A, 3 nodos)

- **Rol**: TSDB caliente para datos de streaming (capa hot del Lambda Architecture). El bridge Java escribe aquí tras calcular StressScore; Grafana lee datos recientes.
- **Red**: `listen_address` = IP interna GCP del nodo (red datos). `rpc_address` = `0.0.0.0`. Puerto CQL 9042 alcanzable desde gcp-b y nube local vía WireGuard routing.
- **Imagen**: `cassandra:4.1` con entrypoint custom que aplica `webhardmon.cql` (ya existía en `docker/cassandra/`).
- **Config clave**: `CASSANDRA_SEEDS` = primeros 2 nodos. Vnodes=16, RF=3 (sharding + replicación, requisito N2).
- **Init**: `webhardmon.cql` crea el keyspace `webhardmon` con RF=3. El entrypoint es idempotente (marker de fichero).
- **Ficheros**: `ansible/roles/cassandra/`, `ansible/cassandra.yml`, `ansible/group_vars/cassandra.yml`.

### NiFi (Nube local)

- **Rol**: ingesta, validación, enriquecimiento y serialización. Recibe JSON de los colectores (vía Cloudflare Tunnel), valida licencias contra MySQL (JDBC), serializa a Avro (Schema Registry) y publica en Kafka.
- **Red**:
  - **Gestión**: UI en puerto 8080, accesible desde el nodo de gestión.
  - **Datos** (salida): conexiones salientes a Kafka (9092), Schema Registry (8081) y MySQL (3307) vía WireGuard routing.
  - **Ingest externo**: cloudflared abre conexión SALIENTE a Cloudflare (sin ports inbound). Enruta `https://ingest.<zona>` → `localhost:8081`.
- **Imagen**: `apache/nifi:2.0.0` (ya existía en `docker/nifi/`). Modo HTTP (sin TLS) para uso interno.
- **cloudflared**: contenedor separado con `network_mode: host`. Requiere `vault_cloudflared_tunnel_token` (de `tofu output`).
- **Post-despliegue**: la lógica de NiFi (processors, controller services) se configura en la UI. Ver documentación de flujos del equipo.
- **Ficheros**: `ansible/roles/nifi/`, `ansible/nifi.yml`, `ansible/group_vars/nifi.yml`.

### MySQL (GCP-B, node-02)

- **Rol**: base de datos de la aplicación (empresas, administradores, licencias). No es un almacén analítico.
- **Red**: node-02 está en la **subred privada** (red datos, 10.30.2.11). MySQL escucha en `0.0.0.0` pero el firewall GCP restringe el acceso. Accesible desde:
  - gcp-b node-01 (web, Grafana): VPC interna → `10.30.2.11:3307`
  - NiFi (local): WireGuard routing → `10.30.2.11:3307`
- **Imagen**: `mysql:8.0` + `init.sql` (ya existía en `docker/mysql/`). El init.sql crea el esquema `telemetriadb` con las tablas `empresa`, `administrador`, `usuario`, `licencia` y la vista `licencia_lookup`.
- **Puerto host**: 3307 (container: 3306) para poder co-alojar otro MySQL si fuera necesario.
- **Ficheros**: `ansible/roles/mysql/`, `ansible/mysql.yml`, `ansible/group_vars/mysql.yml`.

### Grafana (GCP-B, node-01)

- **Rol**: capa service / visualización. Lee de Cassandra (hot), MySQL (telemetría) y HBase REST (batch). La webapp Spring Boot embebe sus dashboards.
- **Red**: node-01 está en la **subred pública** (red gestión, 10.30.1.10). Puerto 3000 accesible vía WireGuard (10.0.0.30:3000).
- **Datasources** provisioned automáticamente por Ansible:
  - `cassandra-hot`: gcp-a → `10.20.1.10:9042` (inter-nube, WireGuard)
  - `mysql-telemetria`: gcp-b node-02 → `10.30.2.11:3307` (VPC interna, red datos)
  - `hbase-rest`: localhost → `127.0.0.1:8085` (mismo host, loopback)
- **Plugin**: `hadesarchitect-cassandra-datasource` (instalado via `GF_INSTALL_PLUGINS` en el contenedor).
- **Imagen**: `grafana/grafana:10.4.0` (ya existía en `docker/grafana/`).
- **Ficheros**: `ansible/roles/grafana/` (con template `datasources.yml.j2`), `ansible/grafana.yml`, `ansible/group_vars/grafana.yml`.

### Matomo (GCP-B, node-01)

- **Rol**: analítica web del panel de WebHardMon (comportamiento de usuarios en la app). Parte del requisito EOD de HMI.
- **Red**: node-01, **subred pública**. Puerto 8282 (no 8080 para evitar conflicto con la webapp).
- **matomo-mysql**: instancia MySQL dedicada en el mismo nodo, puerto 3308, acceso solo desde localhost. Matomo se conecta vía `127.0.0.1:3308`.
- **Primer arranque**: completar el wizard de instalación web en `http://10.0.0.30:8282`. Usar `DB host: 127.0.0.1`, `DB port: 3308`.
- **Imagen**: `matomo:5.1` (ya existía en `docker/matomo/`).
- **Ficheros**: `ansible/roles/matomo/`, `ansible/matomo.yml`, `ansible/group_vars/matomo.yml`.

---

## 6. Verificación del sistema completo

### Checklist post-despliegue

```bash
# GCP-A
echo ruok | nc 10.0.0.20 2181               # ZooKeeper node-01: imok
curl http://10.0.0.20:8081/subjects          # Schema Registry: []
# ssh gcp-a node-01: docker exec cassandra nodetool status → 3 nodos UN

# GCP-B
# ssh ubuntu@10.0.0.30 "docker exec mysql mysql -uwebhardmon -p -e 'SHOW TABLES;'"
curl http://10.0.0.30:3000/api/health        # Grafana: {"commit":...,"database":"ok"...}
curl http://10.0.0.30:8282                   # Matomo: HTTP 200

# Nube local
curl http://<ip-nifi>:8080/nifi/             # NiFi UI: HTTP 200
```

### Puertos de acceso por nodo (resumen)

| Nodo | IP WireGuard | Puerto | Servicio | Red |
|------|-------------|--------|---------|-----|
| gcp-a node-01 | 10.0.0.20 | 2181 | ZooKeeper client | Datos |
| gcp-a node-01 | 10.0.0.20 | 9092 | Kafka broker | Datos |
| gcp-a node-01 | 10.0.0.20 | 8081 | Schema Registry | Gestión/Datos |
| gcp-a node-02 | — | 9042 | Cassandra CQL | Datos |
| gcp-b node-01 | 10.0.0.30 | 3000 | Grafana UI | Gestión |
| gcp-b node-01 | 10.0.0.30 | 8085 | HBase REST | Datos |
| gcp-b node-01 | 10.0.0.30 | 16010 | HBase Master UI | Gestión |
| gcp-b node-01 | 10.0.0.30 | 8282 | Matomo UI | Gestión |
| gcp-b node-02 | — | 3307 | MySQL telemetriadb | Datos |
| local (NiFi CT) | — | 8080 | NiFi UI | Gestión |

---

## 7. Ficheros creados / modificados

### Nuevos Dockerfiles

| Fichero | Descripción |
|---------|-------------|
| `docker/zookeeper/Dockerfile` | `cp-zookeeper:7.6.1` (Confluent CP) |
| `docker/kafka/Dockerfile` | `cp-kafka:7.6.1` (Confluent CP) |

### Nuevos roles Ansible

| Rol | Servicio | Nube | Nodo |
|-----|---------|------|------|
| `ansible/roles/zookeeper/` | ZooKeeper | GCP-A | node-01/02/03 |
| `ansible/roles/kafka/` | Kafka | GCP-A | node-01/02/03 |
| `ansible/roles/schema_registry/` | Schema Registry | GCP-A | node-01 |
| `ansible/roles/cassandra/` | Cassandra | GCP-A | node-01/02/03 |
| `ansible/roles/nifi/` | NiFi + cloudflared | Local | CT NiFi |
| `ansible/roles/mysql/` | MySQL | GCP-B | node-02 |
| `ansible/roles/grafana/` | Grafana | GCP-B | node-01 |
| `ansible/roles/matomo/` | Matomo + matomo-mysql | GCP-B | node-01 |

### Nuevos playbooks

`ansible/zookeeper.yml`, `ansible/kafka.yml`, `ansible/schema_registry.yml`, `ansible/cassandra.yml`, `ansible/nifi.yml`, `ansible/mysql.yml`, `ansible/grafana.yml`, `ansible/matomo.yml`

### Nuevos templates

| Fichero | Descripción |
|---------|-------------|
| `ansible/roles/grafana/templates/datasources.yml.j2` | Datasources provisioning (IPs dinámicas) |

### Ficheros modificados

| Fichero | Cambio |
|---------|--------|
| `ansible/site.yml` | Activados todos los `import_playbook` en orden de dependencias |

---

## 8. Pendiente — Elasticsearch

Elasticsearch (`ansible/group_vars/elasticsearch.yml` existe) no tiene rol ni Dockerfile aún. Cuando se cree:

- **Nodo**: gcp-b node-03 (subred privada, co-alojado con HBase RS).
- **Imagen**: `docker.elastic.co/elasticsearch/elasticsearch:8.x` (no requiere Dockerfile custom en principio).
- **Config**: single-node (`discovery.type: single-node`), heap 3072 MB, bind a `inventory_hostname`.
- **Red**: puerto 9200 accesible desde gcp-b VPC y WireGuard routing. Puerto 9300 (inter-nodo) no necesario en single-node.
- **Datasource Grafana**: ya está configurado en `datasources.yml.j2` pero comentado hasta que se despliegue.
