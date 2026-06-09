# WebHardMon — Material Visual para Memoria del Proyecto

> Prompts de generación para cada diagrama o visual. Todos siguen la estética del panel web:
> fondo `#0f172a`, paneles `#1e293b`, acento azul-índigo, texto gris claro.
> Herramientas recomendadas: **Excalidraw** (bocetos), **draw.io** / **Lucidchart** (diagramas formales), **dbdiagram.io** (ERDs), **Figma** (mockups UI).

---

## 1. Arquitectura Multi-Cloud (Vista General)

**Tipo:** Diagrama de arquitectura de infraestructura  
**Herramienta recomendada:** draw.io / Excalidraw / Figma

### Prompt

```
Crea un diagrama de arquitectura de infraestructura distribuida para WebHardMon con la siguiente estética:
- Fondo: #0f172a (azul oscuro casi negro)
- Cajas de nube/zona: #1e293b con borde #334155
- Acento primario: gradiente de blue-400 (#60a5fa) a indigo-500 (#6366f1)
- Texto: #e2e8f0 (gris claro) sobre fondos oscuros
- Líneas de conexión: #3b82f6 (azul) para datos, #818cf8 (índigo) para control, #22d3ee (cyan) para VPN
- Bordes redondeados (corner radius 12px), sombra sutil

Estructura del diagrama (3 nubes separadas con WireGuard en el centro):

── NUBE LOCAL (Proxmox VE) ─────────────────────────────
  Icono: servidor físico/rack  
  Color borde: #7c3aed (violeta, "on-premise")
  Contenedores LXC:
  • NiFi + cloudflared    [10.10.2.x]  — ingest + túnel Cloudflare
  • HDFS NameNode          [10.10.1.21] — almacenamiento batch
  • HDFS DataNode ×2       [10.10.1.22, 10.10.1.23]
  • MapReduce CT           [10.10.1.24] — job batch (cron horario)
  • Harbor Registry        [10.10.2.x]  — registro Docker privado

── NUBE GCP-A (europe-southwest1) ──────────────────────
  Icono: nube GCP (azul Google)
  Color borde: #2563eb (azul)
  VMs Spot e2-standard-4 ×3:
  • node-01 [10.0.0.20 / 10.20.1.10]: WireGuard GW + Kafka + ZooKeeper + Schema Registry
  • node-02 [10.20.2.11]: Kafka + ZooKeeper + Cassandra + Java/RMI
  • node-03 [10.20.2.12]: Kafka + ZooKeeper + Cassandra + Java/RMI + Java Bridge

── NUBE GCP-B (europe-west1) ───────────────────────────
  Icono: nube GCP (verde Google)
  Color borde: #059669 (verde)
  VMs Spot e2-standard-4 ×3:
  • node-01 [10.0.0.30 / 10.30.1.10]: WireGuard GW + HBase Master + Grafana + Matomo + Web Panel
  • node-02 [10.30.2.11]: HBase RegionServer + MySQL
  • node-03 [10.30.2.12]: HBase RegionServer

── WireGuard VPN Mesh (10.0.0.0/24) ───────────────────
  Nodo central hexagonal con icono candado, color #6366f1
  Peers:
  • Management/Laptop  → 10.0.0.1
  • Local Gateway      → 10.0.0.10 (Windows host)
  • GCP-A node-01      → 10.0.0.20
  • GCP-B node-01      → 10.0.0.30
  Líneas discontinuas cyan entre todos los peers

── EXTERNO ─────────────────────────────────────────────
  • Agente Go (PC usuario) → Cloudflare Tunnel → NiFi
    Icono portátil con flecha hacia nube Cloudflare (naranja)
  • Cloudflare DNS A records (harbmon.eus, grafana, matomo, ingest)

Leyenda en esquina inferior derecha:
  🔵 Tráfico de datos  🟣 VPN/Control  🟦 Ingest externo
  Spot VM = icono rayo rojo pequeño en esquina
```

---

## 2. Flujo de Datos Lambda Architecture (End-to-End)

**Tipo:** Diagrama de flujo de datos (swimlane)  
**Herramienta recomendada:** draw.io (swimlanes) / Figma

### Prompt

```
Diagrama de flujo de datos Lambda Architecture para WebHardMon.
Estética: fondo #0f172a, swimlanes en #1e293b, flechas animables.
Orientación: horizontal, izquierda (origen) → derecha (visualización).

SWIMLANES (5 filas, colores de cabecera):
1. "Colector / PC Usuario"     — cabecera #7c3aed
2. "Ingest (NiFi + Local)"     — cabecera #2563eb  
3. "Streaming / Hot Path"      — cabecera #dc2626 (rojo, caliente)
4. "Batch / Cold Path"         — cabecera #0891b2 (cyan, frío)
5. "Visualización"             — cabecera #059669

NODOS Y CONEXIONES:

[Agente Go]
  └─Cloudflare Tunnel──▶ [NiFi]
                              ├─ Validar licencia MySQL (JDBC lookup)
                              ├─ Serializar Avro (Schema Registry)
                              │
                              ├──▶ [Kafka 3 brokers] ─────────────────────────────────────────────────┐
                              │        (hot path)                                                       │
                              │                                                                         ▼
                              │                                                              [Java Bridge (stressscore-bridge)]
                              │                                                                ├─ RMI → [Java StressScore ×2]
                              │                                                                ├──▶ [Cassandra 3 nodos]
                              │                                                                │         └──▶ [Grafana — paneles live]
                              │                                                                └──▶ [HDFS (Parquet)] ────────────┐
                              │                                                                                                  │
                              └──▶ [HDFS raw Parquet]                                                                           │
                                        (cold path)                                                                              │
                                            └──▶ [MapReduce CT] ──▶ [HBase webhardmon_hourly] ──▶ [Grafana — paneles históricos]
                                                  (cron :10/hora)          (batch served layer)          [Web Panel Spring Boot]

Iconos por servicio:
  - Kafka: logo oficial kafka (negro/blanco invertido para dark)
  - Cassandra: logo oficial
  - HDFS: elefante Hadoop simplificado
  - HBase: logo HBase
  - NiFi: logo NiFi
  - Grafana: logo Grafana

Etiquetas en flechas:
  Cloudflare→NiFi: "HTTPS / REST"
  NiFi→Kafka: "Avro serializado"
  Bridge→Cassandra: "hot write"
  Bridge→HDFS: "Parquet flush"
  MapReduce→HBase: "hourly aggregate"

Caja de tiempo encima del diagrama:
  ← "Latencia < 5s" (hot path, rojo)    "Latencia ~1h" (cold path, cyan) →
```

---

## 3. Mapa de Red y VPN WireGuard

**Tipo:** Diagrama de red con IPs  
**Herramienta recomendada:** draw.io / Network Diagram tool

### Prompt

```
Diagrama de red detallado con todas las subredes y rutas WireGuard de WebHardMon.
Estética: fondo #0f172a, subredes como rectángulos redondeados, color distinto por nube.

SUBREDES (rectángulos con borde de color):
┌─ VPN Mesh 10.0.0.0/24 ─────────────────────┐  borde #818cf8 (índigo)
│  10.0.0.1   Management (laptop)             │
│  10.0.0.10  Local Gateway (Windows host)    │
│  10.0.0.20  GCP-A node-01                   │
│  10.0.0.30  GCP-B node-01                   │
└─────────────────────────────────────────────┘

┌─ LOCAL — Proxmox 10.10.x.0/24 ─────────────┐  borde #7c3aed
│ Mgmt bridge vmbr0:                          │
│  10.10.1.21  HDFS NameNode                  │
│  10.10.1.22  HDFS DataNode 1                │
│  10.10.1.23  HDFS DataNode 2                │
│  10.10.1.24  MapReduce CT                   │
│ Data bridge vmbr1 (10.10.2.0/24):           │
│  10.10.2.x   NiFi, Harbor                   │
└─────────────────────────────────────────────┘

┌─ GCP-A 10.20.x.0/24 ───────────────────────┐  borde #2563eb
│ Public subnet 10.20.1.0/24:                 │
│  10.20.1.10  node-01 (WG gw + Kafka + ZK + SR) │
│ Private subnet 10.20.2.0/24:                │
│  10.20.2.11  node-02 (Kafka + ZK + Cass + Java) │
│  10.20.2.12  node-03 (Kafka + ZK + Cass + Java + Bridge) │
└─────────────────────────────────────────────┘

┌─ GCP-B 10.30.x.0/24 ───────────────────────┐  borde #059669
│ Public subnet 10.30.1.0/24:                 │
│  10.30.1.10  node-01 (WG gw + HBase Master + Grafana + Web) │
│ Private subnet 10.30.2.0/24:                │
│  10.30.2.11  node-02 (HBase RS + MySQL)     │
│  10.30.2.12  node-03 (HBase RS)             │
└─────────────────────────────────────────────┘

RUTAS (flechas entre subredes):
  node-02/03 GCP-A → route 10.0.0.0/24 + 10.30.0.0/16 via 10.20.1.10
  node-02/03 GCP-B → route 10.0.0.0/24 + 10.20.0.0/16 via 10.30.1.10
  Local → supernet 10.10.0.0/16 advertised to mesh
  MapReduce CT → 10.30.0.0/16 via 10.10.1.1 (local gw)

ICONOS en cada nodo:
  Candado = WireGuard peer
  Cortafuegos = firewall GCP
  Nube = NAT Cloud Router
  Flecha UDP bidireccional entre todos los WG peers (línea discontinua azul)

LEYENDA inferior:
  🔵 WireGuard UDP  ──── Ruta estática  ···· Ruta anunciada
```

---

## 4. ERD MySQL — Base de Datos de Aplicación

**Tipo:** Entity Relationship Diagram (crow's foot notation)  
**Herramienta recomendada:** dbdiagram.io / draw.io

### Prompt

```
ERD estilo "crow's foot" para la base de datos telemetriadb de WebHardMon.
Estética dark: fondo #0f172a, tablas con cabecera #1e293b y borde #334155,
tipo de letra monoespaciada, PK en amarillo-dorado (#fbbf24), FK en azul (#60a5fa),
columnas normales en #e2e8f0.

TABLAS Y COLUMNAS:

┌────────────────────────────────────┐
│  empresa                           │  (cabecera fondo #1e3a8a)
├────────────────────────────────────┤
│ 🔑 id          BIGINT  PK AUTO_INC │
│    nombre      VARCHAR(255) NOT NULL│
└────────────────────────────────────┘
         │ 1
         │
         │ M                         
┌────────────────────────────────────┐
│  administrador                     │  (cabecera fondo #1e3a8a)
├────────────────────────────────────┤
│ 🔑 id          BIGINT  PK AUTO_INC │
│    username    VARCHAR(255) UNIQUE  │
│    password    VARCHAR(255) bcrypt  │
│ 🔗 empresa_id  BIGINT  FK          │
└────────────────────────────────────┘

         │ 1
         │
         │ M
┌────────────────────────────────────┐
│  usuario                           │  (cabecera fondo #1e3a8a)
├────────────────────────────────────┤
│ 🔑 id               BIGINT  PK     │
│    nombre           VARCHAR(100)   │
│    nombre_ordenador VARCHAR(80)    │
│ 🔗 empresa_id       BIGINT  FK     │
│    UNIQUE(empresa_id, nombre_ord.) │
└────────────────────────────────────┘
         │ 1
         │
         │ 1
┌────────────────────────────────────┐
│  licencia                          │  (cabecera fondo #1e3a8a)
├────────────────────────────────────┤
│ 🔑 id             BIGINT  PK       │
│    codigo         VARCHAR(255) UQ  │
│    activa         TINYINT(1) DEF 1 │
│    fecha_creacion DATETIME         │
│ 🔗 usuario_id     BIGINT  FK UQ    │
└────────────────────────────────────┘

┌────────────────────────────────────┐
│  VIEW: licencia_lookup             │  (cabecera fondo #1e293b, borde #818cf8)
├────────────────────────────────────┤
│ codigo     ← licencia.codigo       │
│ activa     ← licencia.activa       │
│ empresa_id ← usuario.empresa_id    │
│ nombre     ← usuario.nombre_ord.   │
│                                    │
│ Consumida por: NiFi (JDBC lookup)  │
└────────────────────────────────────┘

Nota al pie:
  "Flujo: NiFi consulta licencia_lookup con codigo del Avro.
   Si activa=1, enrichece empresa_id + nombre antes de enviar a Kafka."
```

---

## 5. Esquema Cassandra — Hot Path

**Tipo:** Tabla de esquema NoSQL estilo card  
**Herramienta recomendada:** Figma / draw.io / Notion embed

### Prompt

```
Ficha visual de esquema Cassandra para WebHardMon. Estética: tarjeta dark theme.
Fondo tarjeta: #1e293b, borde: #334155, acento cabecera: gradiente #3b82f6→#6366f1.
Fuente monoespaciada para CQL.

Título de la tarjeta: "Cassandra — Keyspace: webhardmon"
Subtítulo: "Hot Path · Replication Factor 3 · Cluster: WebHardMonCluster"

TABLA ordenadores:
┌─────────────────────────────────────────────────────────┐
│ TABLE ordenadores                                        │
│ Partition key: empresa_id (int)  Clustering: nombre (asc)│
├──────────────────┬──────────┬──────────────────────────┤
│ empresa_id       │ INT      │ 🔑 PARTITION KEY          │
│ nombre           │ TEXT     │ 🔑 CLUSTERING KEY         │
│ cpu_percent      │ DOUBLE   │ Latest CPU %              │
│ ram_percent      │ DOUBLE   │ Latest RAM %              │
│ sto_percent      │ DOUBLE   │ Latest storage %          │
│ temperatura      │ DOUBLE   │ °C                        │
│ bateria          │ DOUBLE   │ Battery %                 │
│ stress_score     │ DOUBLE   │ Computed via RMI          │
│ ts               │ TIMESTAMP│ Last seen                 │
└──────────────────┴──────────┴──────────────────────────┘

TABLA mediciones (serie temporal):
┌─────────────────────────────────────────────────────────┐
│ TABLE mediciones                                         │
│ Partition: empresa_id + nombre   Clustering: ts DESC     │
├──────────────────┬──────────┬──────────────────────────┤
│ empresa_id       │ INT      │ 🔑 PARTITION KEY          │
│ nombre           │ TEXT     │ 🔑 PARTITION KEY          │
│ ts               │ TIMESTAMP│ 🔑 CLUSTERING KEY (DESC)  │
│ cpu_percent      │ DOUBLE   │                            │
│ ram_percent      │ DOUBLE   │                            │
│ sto_percent      │ DOUBLE   │                            │
│ temperatura      │ DOUBLE   │                            │
│ bateria          │ DOUBLE   │                            │
│ stress_score     │ DOUBLE   │                            │
└──────────────────┴──────────┴──────────────────────────┘

Nota lateral derecha (badge):
  "Grafana consulta mediciones con ALLOW FILTERING + $__timeFrom/$__timeTo"
  "TTL implícito: compaction settings. Auto-refresh: 5s"
```

---

## 6. Esquema HBase — Batch / Served Layer

**Tipo:** Ficha visual de tabla HBase con anatomía de row key  
**Herramienta recomendada:** Figma / draw.io

### Prompt

```
Ficha visual de esquema HBase para WebHardMon — Batch Layer.
Estética dark: fondo #0f172a, card #1e293b, acento cyan (#06b6d4) para HBase.

SECCIÓN 1 — Anatomía del Row Key (diagrama de bloques horizontales):

  ┌──────────────────────────────────────────────────────────────────┐
  │                    ROW KEY ANATOMY                                │
  │  ┌───────────┬───────────┬───────────┬───────────────────────┐  │
  │  │ empresa_id│   ramGb   │   stoGb   │     yyyyMMddHH        │  │
  │  │  (int)    │  (int)    │  (int)    │   (timestamp hora)    │  │
  │  │  2 chars  │  3 chars  │  3 chars  │      10 chars         │  │
  │  └───────────┴───────────┴───────────┴───────────────────────┘  │
  │   Separador: |            Ejemplo: "1|8|256|2025060914"          │
  │   Pre-split: 8 regiones · TTL: 90 días                          │
  └──────────────────────────────────────────────────────────────────┘

  Nota explicativa (tooltip/badge azul):
  "Segmentado por tier de hardware (RAM+storage) para distribuir regiones
   entre los 3 RegionServers sin hot-spotting."

SECCIÓN 2 — Column Family y Columnas:

  TABLE: webhardmon_hourly
  Column Family: "m"  (1 letra = menor overhead)

  ┌─────────────────┬─────────┬─────────────────────────────┐
  │ Columna         │ Tipo    │ Descripción                 │
  ├─────────────────┼─────────┼─────────────────────────────┤
  │ m:cpu_avg       │ DOUBLE  │ CPU media horaria (%)       │
  │ m:cpu_min       │ DOUBLE  │ CPU mínima horaria          │
  │ m:cpu_max       │ DOUBLE  │ CPU máxima horaria          │
  │ m:ram_avg       │ DOUBLE  │ RAM media (%)               │
  │ m:ram_min/max   │ DOUBLE  │ RAM min/max                 │
  │ m:sto_avg       │ DOUBLE  │ Storage media (%)           │
  │ m:sto_min/max   │ DOUBLE  │ Storage min/max             │
  │ m:tmp_avg       │ DOUBLE  │ Temperatura media (°C)      │
  │ m:tmp_min/max   │ DOUBLE  │ Temp min/max                │
  │ m:bat_avg       │ DOUBLE  │ Batería media (%)           │
  │ m:bat_min/max   │ DOUBLE  │ Batería min/max             │
  │ m:str_avg       │ DOUBLE  │ StressScore medio           │
  │ m:str_min/max   │ DOUBLE  │ StressScore min/max         │
  │ m:count         │ LONG    │ Mediciones en el periodo    │
  └─────────────────┴─────────┴─────────────────────────────┘

SECCIÓN 3 — Topología HBase (mini diagrama):
  3 nodos GCP-B en círculo:
  • node-01: HMaster (puerto 16000) + REST API (8085)
  • node-02: RegionServer (puerto 16020) + MySQL
  • node-03: RegionServer (puerto 16020)
  ZooKeeper embedded (puerto 2181), NOT compartido con Kafka ZK
  HDFS rootdir: file:///var/hbase-data (local en los nodos)
```

---

## 7. Co-location de Servicios por Nodo

**Tipo:** Tabla visual de asignación de servicios  
**Herramienta recomendada:** Figma / tabla HTML dark / Notion

### Prompt

```
Tabla visual de co-location de servicios por nodo para WebHardMon.
Estética: dark theme, fondo #0f172a, filas alternas #1e293b/#0f172a,
cabecera con gradiente blue→indigo. Badge de color por categoría de servicio.

CABECERAS COLUMNA: Nodo | IP | Servicios | RAM usada | Tipo

GCP-A (europe-southwest1) — 3 VMs Spot e2-standard-4 (16 GB RAM):
┌──────────────┬─────────────┬──────────────────────────────────────┬──────────┬────────────────┐
│ node-01      │ 10.20.1.10  │ [WireGuard GW] [Kafka] [ZooKeeper]   │ ~3.3 GB  │ 🌩 Spot+DELETE │
│              │ WG:10.0.0.20│ [Schema Registry]                    │          │                │
│ node-02      │ 10.20.2.11  │ [Kafka] [ZooKeeper] [Cassandra]      │ ~8.0 GB  │ 🌩 Spot+DELETE │
│              │             │ [Java/RMI]                           │          │                │
│ node-03      │ 10.20.2.12  │ [Kafka] [ZooKeeper] [Cassandra]      │ ~8.0 GB  │ 🌩 Spot+DELETE │
│              │             │ [Java/RMI] [Java Bridge]             │          │                │
└──────────────┴─────────────┴──────────────────────────────────────┴──────────┴────────────────┘

GCP-B (europe-west1) — 3 VMs Spot e2-standard-4 (16 GB RAM):
┌──────────────┬─────────────┬──────────────────────────────────────┬──────────┬────────────────┐
│ node-01      │ 10.30.1.10  │ [WireGuard GW] [HBase Master]        │ ~5.5 GB  │ 🌩 Spot+DELETE │
│              │ WG:10.0.0.30│ [Grafana] [Matomo] [Web Panel]       │          │                │
│ node-02      │ 10.30.2.11  │ [HBase RegionServer] [MySQL]         │ ~5.0 GB  │ 🌩 Spot+DELETE │
│ node-03      │ 10.30.2.12  │ [HBase RegionServer]                 │ ~3.0 GB  │ 🌩 Spot+DELETE │
└──────────────┴─────────────┴──────────────────────────────────────┴──────────┴────────────────┘

Nube Local (Proxmox LXC) — persistente:
┌──────────────┬─────────────┬──────────────────────────────────────┬──────────┬────────────────┐
│ HDFS-01      │ 10.10.1.21  │ [HDFS NameNode]                      │          │ 💾 Persistente │
│ HDFS-02      │ 10.10.1.22  │ [HDFS DataNode]                      │          │ 💾 Persistente │
│ HDFS-03      │ 10.10.1.23  │ [HDFS DataNode]                      │          │ 💾 Persistente │
│ MapReduce    │ 10.10.1.24  │ [MapReduce CT] (cron horario)         │          │ 💾 Persistente │
│ NiFi         │ 10.10.2.x   │ [NiFi] [cloudflared]                 │          │ 💾 Persistente │
│ Harbor       │ 10.10.2.x   │ [Harbor Registry] (TLS Let's Encrypt) │         │ 💾 Persistente │
└──────────────┴─────────────┴──────────────────────────────────────┴──────────┴────────────────┘

LEYENDA DE BADGES (color por categoría):
  🟦 Streaming   [Kafka] [ZooKeeper] [Schema Registry]
  🟧 Storage     [Cassandra] [HBase RS/Master] [MySQL] [HDFS]
  🟩 Processing  [Java/RMI] [Java Bridge] [MapReduce]
  🟪 Ingest      [NiFi] [cloudflared]
  ⬜ UI/Ops      [Grafana] [Matomo] [Web Panel] [Harbor]
  🟥 Network     [WireGuard GW]

Nota al pie:
  "⚡ Spot+DELETE: el disco de arranque se elimina en preempción.
   Los datos de estado se reconstruyen con Ansible (idempotente).
   La nube local mantiene HDFS (datos cold) persistente."
```

---

## 8. Flujo de Deploy (Orden de Dependencias)

**Tipo:** Diagrama de dependencias / DAG de deployment  
**Herramienta recomendada:** draw.io (dagre layout) / Mermaid

### Prompt

```
Diagrama DAG de orden de deployment para WebHardMon con Ansible.
Estética dark, nodos como rectángulos redondeados con borde de color por nube,
flechas grises con etiqueta "depende de".

NODOS Y DEPENDENCIAS:

Nivel 0 (prerequisito):
  [tofu apply] → genera inventory.ini + keys WireGuard + IPs estáticas

Nivel 1 (seguridad — todos los hosts):
  [security.yml] ← depende de: tofu apply
    • SSH 22→2222, fail2ban, auditd, AIDE

Nivel 2 (base networking + registros):
  [harbor.yml]    ← depende de: security.yml   (GCP-B node-01 → local)
  [zookeeper.yml] ← depende de: security.yml   (GCP-A)

Nivel 3 (cluster streaming + storage):
  [kafka.yml]           ← depende de: zookeeper.yml
  [schema_registry.yml] ← depende de: kafka.yml
  [cassandra.yml]       ← depende de: security.yml

Nivel 4 (ingest + bridge):
  [nifi.yml]        ← depende de: harbor.yml, schema_registry.yml, kafka.yml, mysql.yml
  [java.yml]        ← depende de: harbor.yml
  [java_bridge.yml] ← depende de: java.yml, kafka.yml, cassandra.yml

Nivel 5 (batch layer):
  [hdfs.yml]       ← depende de: security.yml (local)
  [hbase.yml]      ← depende de: security.yml (GCP-B) — ejecutar manualmente
  [mapreduce.yml]  ← depende de: hdfs.yml, hbase.yml, harbor.yml — ejecutar manualmente

Nivel 6 (analytics + web):
  [mysql.yml]   ← depende de: security.yml (GCP-B)
  [grafana.yml] ← depende de: cassandra.yml, hbase.yml, mysql.yml
  [matomo.yml]  ← depende de: security.yml
  [web.yml]     ← depende de: mysql.yml, cassandra.yml, grafana.yml

ESTILOS de nodo por cloud:
  Local     → borde #7c3aed
  GCP-A     → borde #2563eb
  GCP-B     → borde #059669
  Todos     → borde #374151 (gris)

Nodos con fondo especial:
  [hbase.yml] y [mapreduce.yml] → fondo #78350f (ámbar oscuro) + badge "⚠ manual"
  [security.yml] → fondo #1e1b4b (índigo muy oscuro) + badge "🔒 primero"
```

---

## 9. Dashboard Mockup — Panel de Ordenador (Web Panel)

**Tipo:** UI Mockup de alta fidelidad  
**Herramienta recomendada:** Figma

### Prompt

```
Mockup dark-theme del panel de monitorización de ordenador de WebHardMon.
Resolución: 1440×900. Fuente: Inter / sistema. Sin emojis en UI.

LAYOUT:
  Sidebar izquierdo (w-64, bg #1e293b):
  ─ Logo: "WebHardMon" gradiente text blue-400→indigo-500, negrita
  ─ Nav items (h-10, icon+label):
    • Empresa (activo: bg blue-600/10, text blue-400, borde-l-2 blue-500)
    • Ordenagailuak
    • Lizentziak
    • Administratzaileak
    • Etika

  Header (h-16, bg #1e293b, border-b gray-800):
  ─ Empresa: "Acme Corp"  |  Selector ordenador: [PC-1-1 ▼]
  ─ Rango tiempo: [Azken 24h ▼]
  ─ Botón logout (icon + texto, hover text-red-400)

  Contenido principal (bg #0f172a):
  FILA 1 — Grid 6 columnas de KPI cards (h-36, bg #1e293b, rounded-xl, border gray-800):
    Card CPU:    valor "34%" grande, barra progress verde, subtítulo "CPU"
    Card RAM:    valor "71%" naranja-warning
    Card Storage: valor "45%" verde
    Card Temp:   valor "52°C" verde
    Card Batería: valor "88%" verde
    Card Stress: valor "2.4" color según threshold (verde<3, naranja 3-6, rojo>6)
    Cada card tiene un iframe Grafana panel embebido como fuente de datos
    
  FILA 2 — Gráfico líneas tiempo (últimas 24h, bg #1e293b, rounded-xl):
    Multi-line chart con leyenda: CPU (azul), RAM (índigo), Temp (naranja)
    Eje X: horas, Eje Y: porcentaje
    Fondo inner: #0f172a, grid lines: #1e293b, líneas colored

  FILA 3 — Tabla histórica HBase (bg #1e293b, rounded-xl):
    Cabecera: "Historial horario (HBase)"
    Columnas: Hora | CPU avg | RAM avg | Temp avg | Stress avg | Mediciones
    Filas con color condicional en valores:
      < 70%: text-green-400
      70-90%: text-yellow-400
      >= 90%: text-red-400
    Paginación en footer

COLORES Y TOKENS:
  --bg-base: #0f172a
  --bg-panel: #1e293b
  --border: #334155
  --accent: #3b82f6
  --accent-light: #60a5fa
  --text-primary: #e2e8f0
  --text-muted: #94a3b8
  --ok: #4ade80      (< 70%)
  --warn: #fb923c    (70-90%)
  --crit: #f87171    (>= 90%)
```

---

## 10. Diagrama Cloudflare Tunnel + Autenticación NiFi

**Tipo:** Diagrama de secuencia de autenticación  
**Herramienta recomendada:** Mermaid sequence / draw.io

### Prompt

```
Diagrama de secuencia de autenticación del agente Go en WebHardMon.
Estética dark theme, actores como cajas redondeadas con colores por zona:
  Agente PC: #7c3aed (violeta, "exterior")
  Cloudflare: #f97316 (naranja, "CDN")
  NiFi: #2563eb (azul, "local cloud")
  MySQL: #059669 (verde, "GCP-B")
  Kafka: #0891b2 (cyan, "GCP-A")

SECUENCIA:

Agente Go → HTTPS POST /api/agente/validar → Web Panel (GCP-B)
  Web Panel → MySQL: SELECT activa, empresa_id, nombre FROM licencia_lookup WHERE codigo=?
  MySQL → Web Panel: {activa:1, empresa_id:1, nombre:"PC-1-1"}
  Web Panel → Agente: {token JWT / api_key válida}

Agente Go → HTTPS POST (Avro payload) → Cloudflare (ingest.<zone>)
  Cloudflare Tunnel → NiFi ListenHTTP (10.10.2.x:8081)
  NiFi → MySQL (JDBC LookupService): SELECT FROM licencia_lookup WHERE codigo=?
  alt [activa = 1]
    NiFi → Schema Registry (10.0.0.20:8081): serializar Avro
    NiFi → Kafka (9092): publish topic webhardmon-raw
    NiFi → Agente: 200 OK
  else [activa = 0 o no existe]
    NiFi → Agente: 401 Unauthorized
  end

NOTA al margen:
  "No hay Cloudflare Access en el edge.
   La autenticación es 100% aplicación (NiFi + MySQL).
   El túnel solo provee HTTPS público sin port-forward."

Estilo de flechas:
  → sólida: llamada
  --> discontinua: respuesta
  Etiquetas en cajas color-coded
```

---

## Paleta de Colores de Referencia (para todos los diagramas)

| Token | Hex | Uso |
|---|---|---|
| `bg-base` | `#0f172a` | Fondo principal |
| `bg-panel` | `#1e293b` | Tarjetas, sidebar, header |
| `border` | `#334155` | Bordes de cards |
| `border-muted` | `#1e293b` | Bordes sutiles |
| `accent-blue` | `#3b82f6` | Acciones primarias, links |
| `accent-light` | `#60a5fa` | Texto de acento, iconos activos |
| `accent-indigo` | `#6366f1` | Gradiente secundario |
| `text-primary` | `#e2e8f0` | Texto principal |
| `text-muted` | `#94a3b8` | Texto secundario |
| `ok-green` | `#4ade80` | < 70%, estado OK |
| `warn-orange` | `#fb923c` | 70–90%, advertencia |
| `crit-red` | `#f87171` | ≥ 90%, crítico |
| `cloud-local` | `#7c3aed` | Proxmox / on-premise |
| `cloud-gcp-a` | `#2563eb` | GCP europe-southwest1 |
| `cloud-gcp-b` | `#059669` | GCP europe-west1 |
| `vpn-mesh` | `#06b6d4` | WireGuard / red VPN |

---

## Checklist de Materiales

- [ ] **01** Arquitectura Multi-Cloud (vista general)
- [ ] **02** Flujo Lambda Architecture (swimlane end-to-end)
- [ ] **03** Mapa de Red y WireGuard VPN
- [ ] **04** ERD MySQL (telemetriadb)
- [ ] **05** Esquema Cassandra (hot path)
- [ ] **06** Esquema HBase (batch layer)
- [ ] **07** Co-location de servicios por nodo
- [ ] **08** DAG de deployment (orden Ansible)
- [ ] **09** Dashboard Mockup (Web Panel dark)
- [ ] **10** Secuencia Cloudflare Tunnel + Auth NiFi
