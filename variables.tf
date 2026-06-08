# =============================================================================
# Variables globales del proyecto WebHardMon
# =============================================================================

variable "project_name" {
  description = "Etiqueta común para todos los recursos."
  type        = string
  default     = "webhardmon"
}

# -----------------------------------------------------------------------------
# Proxmox (nube local)
# -----------------------------------------------------------------------------

variable "proxmox_endpoint" {
  description = "URL de la API de Proxmox VE (accesible via WireGuard)."
  type        = string
  default     = "https://10.10.1.15:8006/"
}

variable "proxmox_api_token" {
  description = "Token de API Proxmox en formato 'user@realm!tokenid=uuid'."
  type        = string
  sensitive   = true
}

variable "proxmox_tls_insecure" {
  description = "Permite cert TLS auto-firmado del PVE."
  type        = bool
  default     = true
}

variable "proxmox_ssh_user" {
  description = "Usuario SSH para subir snippets al nodo PVE."
  type        = string
  default     = "root"
}

variable "proxmox_ssh_private_key" {
  description = "Clave privada SSH (contenido PEM) para el nodo PVE."
  type        = string
  sensitive   = true
  default     = ""
}

variable "proxmox_nodes" {
  description = "Nodos PVE disponibles. Los CTs genericos se reparten round-robin (RGI320); HDFS se ancla 1-por-nodo (ver var.hdfs_nodes). La plantilla LXC se descarga en TODOS estos nodos."
  type        = list(string)
  default     = ["pve-local", "pve-local2", "pve-local3"]
}

variable "proxmox_node_ssh_hosts" {
  description = "Mapa nombre de nodo PVE -> host SSH. Lo usa el bootstrap de CTs (null_resource.lxc_bootstrap) para entrar por SSH al nodo que aloja cada CT y lanzar `pct exec`. Reutiliza la misma clave que proxmox_ssh_private_key."
  type        = map(string)
  default = {
    "pve-local"  = "10.10.1.15"
    "pve-local2" = "10.10.1.16"
    "pve-local3" = "10.10.1.17"
  }
}

variable "proxmox_datastore_disk" {
  description = "Datastore para discos de los CTs."
  type        = string
  default     = "local-lvm"
}

variable "proxmox_datastore_template" {
  description = "Datastore para plantilla y snippets."
  type        = string
  default     = "local"
}

variable "proxmox_ct_template" {
  description = "Plantilla LXC. La descargara OpenTofu si no existe."
  type        = string
  default     = "ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
}

variable "local_public_bridge" {
  description = "Bridge para la subred publica (ingesta)."
  type        = string
  default     = "vmbr1"
}

variable "local_private_bridge" {
  description = "Bridge para la subred privada (almacenamiento, sin gw)."
  type        = string
  default     = "vmbr2"
}

variable "local_public_cidr" {
  description = "CIDR de la subred publica local. Solo informativo (la red ya existe en PVE)."
  type        = string
  default     = "10.10.2.0/24"
}

variable "local_public_gateway" {
  description = "Gateway de la subred publica local."
  type        = string
  default     = "10.10.2.1"
}

variable "local_private_cidr" {
  description = "CIDR de la subred privada local."
  type        = string
  default     = "10.10.3.0/24"
}

# Supernet que engloba las tres subredes locales (gestion 10.10.1, publica 10.10.2,
# privada 10.10.3). Es lo que el gateway local anuncia a la malla WireGuard y lo que
# los gateways GCP enrutan de vuelta, para que HDFS (10.10.1.x) sea alcanzable desde
# GCP ademas de las subredes de CTs. Tambien amplia el firewall de servicios GCP.
variable "local_supernet_cidr" {
  description = "Supernet de la nube local anunciada a la malla (cubre gestion+publica+privada)."
  type        = string
  default     = "10.10.0.0/16"
}

# Red de gestion (10.10.1.0/24, vmbr0). Es la LAN donde viven los CTs de HDFS:
# el NameNode esta fijado en 10.10.1.21 (lo asume el bridge Java y la capa batch).
# vmbr0 es el bridge por defecto presente en los tres nodos PVE (a diferencia de
# vmbr1/vmbr2, que pueden no autoarrancar).
variable "local_mgmt_bridge" {
  description = "Bridge de la LAN de gestion (10.10.1.x) donde se crean los CTs de HDFS."
  type        = string
  default     = "vmbr0"
}

variable "local_mgmt_gateway" {
  description = "Gateway de la LAN de gestion local (salida a Internet para pulls Docker)."
  type        = string
  default     = "10.10.1.1"
}

variable "local_vmid_start" {
  description = "VMID inicial para los CTs creados por OpenTofu (evitar colisión con 100-102)."
  type        = number
  default     = 110
}

variable "local_ct_ssh_pubkey" {
  description = "Clave publica SSH inyectada en los CTs (cuenta ubuntu)."
  type        = string
}

# -----------------------------------------------------------------------------
# GCP A
# -----------------------------------------------------------------------------

variable "gcp_a_project_id" {
  description = "Project ID de GCP-A (streaming)."
  type        = string
}

variable "gcp_a_region" {
  description = "Region GCP-A."
  type        = string
  default     = "europe-southwest1"
}

variable "gcp_a_zone" {
  description = "Zona GCP-A."
  type        = string
  default     = "europe-southwest1-a"
}

variable "gcp_a_credentials_file" {
  description = "Ruta al JSON de la service account de GCP-A. Vacio = ADC."
  type        = string
  default     = ""
}

variable "gcp_a_public_cidr" {
  description = "CIDR subred publica gcp-a (borde streaming)."
  type        = string
  default     = "10.20.1.0/24"
}

variable "gcp_a_private_cidr" {
  description = "CIDR subred privada gcp-a (cluster privado)."
  type        = string
  default     = "10.20.2.0/24"
}

# -----------------------------------------------------------------------------
# GCP B
# -----------------------------------------------------------------------------

variable "gcp_b_project_id" {
  description = "Project ID de GCP-B (analitica + servicio)."
  type        = string
}

variable "gcp_b_region" {
  description = "Region GCP-B."
  type        = string
  default     = "europe-west1"
}

variable "gcp_b_zone" {
  description = "Zona GCP-B."
  type        = string
  default     = "europe-west1-b"
}

variable "gcp_b_credentials_file" {
  description = "Ruta al JSON de la service account de GCP-B. Vacio = ADC."
  type        = string
  default     = ""
}

variable "gcp_b_public_cidr" {
  description = "CIDR subred publica gcp-b (borde servicio)."
  type        = string
  default     = "10.30.1.0/24"
}

variable "gcp_b_private_cidr" {
  description = "CIDR subred privada gcp-b (datos)."
  type        = string
  default     = "10.30.2.0/24"
}

# -----------------------------------------------------------------------------
# WireGuard VPN inter-nube
# -----------------------------------------------------------------------------
# Un gateway por nube (el node-01 publico de cada GCP cloud + el gateway local).
# Genera los keypairs con: wg genkey | tee private.key | wg pubkey > public.key
# Las claves privadas van en terraform.tfvars (sensible, gitignoreado).

variable "wg_port" {
  description = "Puerto UDP de WireGuard en todos los gateways."
  type        = number
  default     = 51820
}

variable "wg_vpn_cidr" {
  description = "CIDR de la subred VPN WireGuard. No debe solaparse con 10.10.x, 10.20.x, 10.30.x."
  type        = string
  default     = "10.0.0.0/24"
}

variable "ssh_port" {
  description = "Puerto SSH en régimen permanente tras el endurecimiento (ansible/security.yml). Se emite como ansible_port en el inventario. Los nodos arrancan en el 22 (cloud-init) y security.yml los mueve a este puerto; security.yml autodetecta 22→este puerto, el resto de playbooks asumen este puerto."
  type        = number
  default     = 2222
}

variable "wg_mgmt_public_key" {
  description = "Clave publica WireGuard del nodo de gestion (portatil del operador)."
  type        = string
}

variable "wg_mgmt_endpoint" {
  description = "IP publica o DNS del nodo de gestion. Puede dejarse vacio si el operador siempre inicia la conexion con PersistentKeepalive."
  type        = string
  default     = ""
}

variable "wg_local_gw_public_key" {
  description = "Clave publica WireGuard del gateway de la nube local (gestionado fuera de OpenTofu)."
  type        = string
}

variable "wg_local_gw_endpoint" {
  description = "IP publica o DNS del gateway de la nube local."
  type        = string
  default     = ""
}

variable "wg_gcp_a_private_key" {
  description = "Clave privada WireGuard del gateway de GCP-A (node-01). Sensible."
  type        = string
  sensitive   = true
}

variable "wg_gcp_a_public_key" {
  description = "Clave publica WireGuard del gateway de GCP-A (derivada de la privada con wg pubkey)."
  type        = string
}

variable "wg_gcp_b_private_key" {
  description = "Clave privada WireGuard del gateway de GCP-B (node-01). Sensible."
  type        = string
  sensitive   = true
}

variable "wg_gcp_b_public_key" {
  description = "Clave publica WireGuard del gateway de GCP-B (derivada de la privada con wg pubkey)."
  type        = string
}

# -----------------------------------------------------------------------------
# Cloudflare Tunnel (ingesta externa)
# -----------------------------------------------------------------------------
# El collector corre en PCs de usuario fuera de las tres nubes. Cloudflare Tunnel
# publica el endpoint de ingesta de NiFi (en el CT local) sin abrir NAT ni VPN en
# el cliente; Cloudflare Access lo protege con un service token.

variable "cloudflare_enabled" {
  description = "Crear el tunel Cloudflare para la ingesta externa hacia NiFi."
  type        = bool
  default     = true
}

variable "cloudflare_api_token" {
  description = "API token Cloudflare (Account: Cloudflare Tunnel:Edit; Zone: DNS:Edit). Requerido si cloudflare_enabled."
  type        = string
  sensitive   = true
  default     = ""
}

variable "cloudflare_account_id" {
  description = "Account ID de Cloudflare."
  type        = string
  default     = ""
}

variable "cloudflare_zone_id" {
  description = "Zone ID del dominio donde se crea el registro de ingesta."
  type        = string
  default     = ""
}

variable "cloudflare_zone_name" {
  description = "Dominio gestionado en Cloudflare (p.ej. example.com)."
  type        = string
  default     = ""
}

variable "cloudflare_ingest_subdomain" {
  description = "Subdominio del endpoint de ingesta -> <subdominio>.<zona>."
  type        = string
  default     = "ingest"
}

variable "cloudflare_harbor_subdomain" {
  description = "Subdominio del registro Harbor -> <subdominio>.<zona>. Registro DNS-only (grey cloud) apuntando a la IP LAN del CT Harbor; el cert TLS lo emite Let's Encrypt via DNS-01 (Ansible). No expone Harbor a Internet."
  type        = string
  default     = "harbor"
}

variable "cloudflare_web_subdomain" {
  description = "Subdominio del panel web -> <subdominio>.<zona>. Expuesto vía Cloudflare Tunnel (cloudflared en GCP-B node-02)."
  type        = string
  default     = "app"
}

variable "nifi_ingest_port" {
  description = "Puerto del listener HTTP de ingesta de NiFi dentro del CT (destino del tunel)."
  type        = number
  default     = 8081
}

# -----------------------------------------------------------------------------
# Topologia (numero de nodos por rol; parametrizable por rubrica)
# -----------------------------------------------------------------------------

variable "topology" {
  description = "Numero de CTs genericos round-robin de la nube LOCAL (Proxmox). HDFS NO se cuenta aqui: se ancla 1-por-nodo en la LAN de gestion (ver var.hdfs_nodes). MapReduce tampoco: tiene su propio CT dedicado (ver var.mapreduce_node). Los servicios GCP se co-localizan en nodos compartidos spot (ver var.gcp_a_nodes / var.gcp_b_nodes)."
  type = object({
    nifi   = number
    harbor = number
  })
  default = {
    nifi   = 1
    harbor = 1
  }
}

# -----------------------------------------------------------------------------
# HDFS — clúster de 3 nodos sobre la LAN de gestion (10.10.1.x), 1 CT por host PVE
# -----------------------------------------------------------------------------
# Cada CT es solo el HOST Docker; HDFS se despliega como contenedores de
# aplicacion (bde2020/hadoop-*) via Ansible (roles/hdfs). El NameNode esta fijo
# en 10.10.1.21 (lo asume stressscore-bridge y la capa batch hbase/mapreduce).
# El job MapReduce vive en su propio CT dedicado (ver var.mapreduce_node).
variable "hdfs_nodes" {
  description = "Nodos del clúster HDFS. kind = namenode|datanode. Uno por host PVE (round-robin manual sobre var.proxmox_nodes)."
  type = list(object({
    name         = string
    kind         = string
    proxmox_node = string
    ip           = string
    vmid         = number
  }))
  default = [
    { name = "hdfs-namenode", kind = "namenode", proxmox_node = "pve-local", ip = "10.10.1.21", vmid = 121 },
    { name = "hdfs-datanode0", kind = "datanode", proxmox_node = "pve-local2", ip = "10.10.1.22", vmid = 122 },
    { name = "hdfs-datanode1", kind = "datanode", proxmox_node = "pve-local3", ip = "10.10.1.23", vmid = 123 },
  ]
}

# -----------------------------------------------------------------------------
# MapReduce — CT dedicado para la capa batch (LAN de gestion, junto a HDFS)
# -----------------------------------------------------------------------------
# El job batch ya NO corre dentro del contenedor NameNode: tiene su propio CT
# host-Docker. El rol roles/mapreduce despliega ahi un contenedor dedicado
# (imagen runnable bde2020/hadoop-base + fat JAR) que se ejecuta efimero (docker
# run --rm) cada hora via cron. Alcanza HDFS (10.10.1.21:9000) por la LAN y el
# quorum ZK de HBase (10.30.0.0/16) por la ruta WireGuard del gateway local.
variable "mapreduce_node" {
  description = "CT dedicado al job MapReduce batch (nube local, LAN de gestion). Host Docker; el contenedor del job lo despliega Ansible (roles/mapreduce)."
  type = object({
    name         = string
    proxmox_node = string
    ip           = string
    vmid         = number
  })
  default = { name = "mapreduce", proxmox_node = "pve-local", ip = "10.10.1.24", vmid = 124 }
}

# -----------------------------------------------------------------------------
# Nodos compartidos GCP (consolidacion de coste)
# -----------------------------------------------------------------------------
# En vez de una VM por nodo de cluster (17 VMs on-demand), cada nube GCP usa
# 3 VMs spot e2-standard-4 que co-alojan varios servicios como contenedores.
# Se mantienen los clusters distribuidos de 3 nodos repartiendo UNA instancia de
# cada servicio por VM (defendible frente a RGI320: siguen siendo 3 hosts).

variable "gcp_a_nodes" {
  description = "Nodos compartidos de GCP-A (streaming). 'public' = NIC en subred publica con IP externa estatica (gateway WireGuard); false = subred privada, egress por Cloud NAT."
  type = list(object({
    roles  = list(string)
    public = bool
  }))
  default = [
    # node-01 público: gateway WireGuard + Schema Registry (singleton)
    { roles = ["kafka", "zookeeper", "cassandra", "schema_registry"], public = true },
    # node-02: java_bridge (puente Kafka→RMI→Cassandra, 1 instancia)
    { roles = ["kafka", "zookeeper", "cassandra", "java", "java_bridge"], public = false },
    { roles = ["kafka", "zookeeper", "cassandra", "java"], public = false },
  ]
}

variable "gcp_b_nodes" {
  description = "Nodos compartidos de GCP-B (analitica + servicio). Mismo criterio publico/privado que gcp_a_nodes."
  type = list(object({
    roles  = list(string)
    public = bool
  }))
  default = [
    # node-01 público: UI/servicio (Grafana, Matomo, Web panel, HBase Master)
    { roles = ["hbase", "grafana", "matomo", "web"], public = true },
    { roles = ["hbase", "mysql"], public = false },
    # node-03: solo HBase RS (Elasticsearch eliminado de la arquitectura final)
    { roles = ["hbase"], public = false },
  ]
}

variable "lxc_default_resources" {
  description = "Recursos por defecto para los CTs locales."
  type = object({
    cores   = number
    memory  = number
    disk_gb = number
    swap    = number
  })
  default = {
    cores   = 2
    memory  = 2048
    disk_gb = 16
    swap    = 512
  }
}

variable "gcp_default_machine_type" {
  description = "Tipo de máquina de los nodos compartidos GCP. e2-standard-4 (4 vCPU / 16 GB) da holgura para co-alojar varios JVM por nodo."
  type        = string
  default     = "e2-standard-4"
}

variable "gcp_node_disk_gb" {
  description = "Disco de arranque (GB) de cada nodo compartido GCP. Mayor que una VM single-role porque co-aloja varios servicios y sus datos."
  type        = number
  default     = 30
}

variable "gcp_spot" {
  description = "Usar Spot VMs en GCP (~70 % mas barato; pueden ser interrumpidas con 30 s de aviso). Por defecto activado para abaratar el proyecto de clase."
  type        = bool
  default     = true
}

variable "gcp_spot_termination_action" {
  description = "Que hacer al interrumpir una VM spot: DELETE (borra VM + disco, mas barato, sin estado persistente) o STOP (conserva el disco para reinicio rapido). Solo aplica si gcp_spot = true; las VMs on-demand no se interrumpen."
  type        = string
  default     = "STOP"
  validation {
    condition     = contains(["DELETE", "STOP"], var.gcp_spot_termination_action)
    error_message = "gcp_spot_termination_action debe ser DELETE o STOP."
  }
}
