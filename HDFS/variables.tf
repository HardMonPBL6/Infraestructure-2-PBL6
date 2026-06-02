# ============================================================
#  FASE 1 · variables
# ============================================================

# ── Proxmox API ──────────────────────────────────────────────
variable "proxmox_api_url" {
  type = string
}
variable "proxmox_api_token_id" {
  type = string
}
variable "proxmox_api_token_secret" {
  type      = string
  sensitive = true
}
variable "proxmox_ssh_user" {
  description = "Usuario SSH en los NODOS Proxmox (no en los LXC). Normalmente root."
  type        = string
  default     = "root"
}

# ── Nodos Proxmox donde crear cada LXC ───────────────────────
variable "proxmox_node_0" {
  description = "Nombre del nodo Proxmox para el NameNode (como aparece en la UI)"
  type        = string
  default     = "pve-local"
}
variable "proxmox_node_0_ip" {
  description = "IP del nodo Proxmox para el NameNode"
  type        = string
  default     = "10.10.1.15"
}
variable "proxmox_node_1" {
  description = "Nombre del nodo Proxmox para el DataNode-0"
  type        = string
  default     = "pve-local2"
}
variable "proxmox_node_1_ip" {
  description = "IP del nodo Proxmox para el DataNode-0"
  type        = string
  default     = "10.10.1.16"
}
variable "proxmox_node_2" {
  description = "Nombre del nodo Proxmox para el DataNode-1"
  type        = string
  default     = "pve-local3"
}
variable "proxmox_node_2_ip" {
  description = "IP del nodo Proxmox para el DataNode-1"
  type        = string
  default     = "10.10.1.17"
}

# ── Plantilla y recursos de los LXC ──────────────────────────
variable "lxc_ostemplate" {
  type    = string
  default = "local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
}
variable "lxc_storage" {
  description = "Storage de Proxmox para el rootfs (p.ej. local-lvm, local-zfs)"
  type        = string
  default     = "local-lvm" # ← CONFIRMAR nombre real del storage
}
variable "lxc_cores" {
  type    = number
  default = 2
}
variable "lxc_memory_mb" {
  type    = number
  default = 2048
}
variable "lxc_disk_gb" {
  type    = number
  default = 20
}

# ── Red de los LXC ───────────────────────────────────────────
variable "lxc_bridge" {
  type    = string
  default = "vmbr0"
}
variable "lxc_gateway" {
  description = "Gateway de la subred 10.10.1.0/24"
  type        = string
  default     = "10.10.1.1" # ← CONFIRMAR la IP real del gateway
}

# ── SSH para entrar a los LXC ────────────────────────────────
variable "ssh_public_key" {
  description = "Clave pública que se inyecta en los LXC (root)"
  type        = string
}
variable "ssh_private_key_path" {
  description = "Ruta a la clave privada correspondiente, en el nodo de gestión"
  type        = string
}

# ── Harbor ───────────────────────────────────────────────────
variable "harbor_registry" {
  description = "Registry Harbor (host:puerto). Se marca como inseguro en Docker."
  type        = string
  default     = "10.10.1.50:5000"
}
