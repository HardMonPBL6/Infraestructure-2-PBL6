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
  description = "URL de la API de Proxmox VE (accesible via Tailscale)."
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
  description = "Nodos PVE disponibles. Los componentes del mismo clúster se reparten round-robin (RGI320)."
  type        = list(string)
  default     = ["pve-local", "pve-local2"]
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
# Tailscale
# -----------------------------------------------------------------------------

variable "tailscale_tailnet" {
  description = "Nombre del tailnet (p.ej. 'example.com' o '-' para el por defecto del OAuth)."
  type        = string
  default     = "-"
}

variable "tailscale_oauth_client_id" {
  description = "OAuth client id del tailnet (scope: devices:write, acl)."
  type        = string
  sensitive   = true
}

variable "tailscale_oauth_client_secret" {
  description = "OAuth client secret del tailnet."
  type        = string
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Topologia (numero de nodos por rol; parametrizable por rubrica)
# -----------------------------------------------------------------------------

variable "topology" {
  description = "Numero de nodos por componente. Editable sin tocar codigo."
  type = object({
    # local
    nifi      = number
    hdfs      = number # NameNode + DataNodes contados juntos
    mapreduce = number
    harbor    = number
    # gcp-a
    kafka     = number
    zookeeper = number
    java_rmi  = number
    cassandra = number
    # gcp-b
    mysql         = number
    hbase         = number
    elasticsearch = number
    grafana       = number
  })
  default = {
    nifi          = 1
    hdfs          = 3
    mapreduce     = 1
    harbor        = 1
    kafka         = 3
    zookeeper     = 3
    java_rmi      = 2
    cassandra     = 3
    mysql         = 1
    hbase         = 3
    elasticsearch = 1
    grafana       = 1
  }
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
  description = "Tipo de máquina por defecto para instancias GCP."
  type        = string
  default     = "e2-standard-2"
}

variable "gcp_spot" {
  description = "Usar Spot VMs en GCP (~70 % mas barato; pueden ser interrumpidas con 30 s de aviso)."
  type        = bool
  default     = false
}
