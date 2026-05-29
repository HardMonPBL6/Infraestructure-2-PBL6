# Modulo reutilizable: un CT LXC en Proxmox WebHardMon.
#
# Decisiones:
#  - Unprivileged + nesting=1 (mismo patron que los CTs ya existentes).
#  - IP estatica determinista por CT (asi el inventario Ansible es estable y
#    el subnet router del portatil ya enruta esos rangos por Tailscale).
#  - Si in_private_subnet=true, el CT recibe 2 NICs: la privada (vmbr2, sin gw)
#    y una segunda en vmbr1 con DHCP solo para egress (apt).
#  - Sin Tailscale dentro del CT: el alta en el tailnet la hace el subnet router
#    del portatil del operador.

terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}

variable "vmid" { type = number }
variable "hostname" { type = string }
variable "node_name" { type = string }
variable "template_file_id" { type = string }
variable "datastore_disk" { type = string }
variable "disk_gb" { type = number }
variable "cores" { type = number }
variable "memory" { type = number }
variable "swap" { type = number }

variable "public_bridge" { type = string }
variable "private_bridge" { type = string }
variable "public_gateway" { type = string }
variable "primary_ip_cidr" {
  description = "Direccion estatica del NIC principal en formato CIDR (p.ej. 10.10.3.110/24)."
  type        = string
}
variable "in_private_subnet" {
  description = "true => NIC privada principal + NIC publica de egress; false => solo NIC publica."
  type        = bool
  default     = false
}

variable "hookscript_file_id" {
  description = "ID volid del snippet hookscript (ej. local:snippets/wh-110.sh)."
  type        = string
}

variable "tags" {
  type    = list(string)
  default = []
}

resource "proxmox_virtual_environment_container" "this" {
  vm_id     = var.vmid
  node_name = var.node_name
  tags      = var.tags

  unprivileged  = true
  start_on_boot = true

  features {
    nesting = true
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = "ubuntu"
  }

  cpu {
    cores = var.cores
  }

  memory {
    dedicated = var.memory
    swap      = var.swap
  }

  disk {
    datastore_id = var.datastore_disk
    size         = var.disk_gb
  }

  initialization {
    hostname = var.hostname

    # NIC principal: IP estatica. Si es privada, sin gateway (el cluster no
    # necesita salir por aqui). Si es publica, gateway del bridge.
    ip_config {
      ipv4 {
        address = var.primary_ip_cidr
        gateway = var.in_private_subnet ? null : var.public_gateway
      }
    }

    # NIC secundaria solo para CTs privados: DHCP en vmbr1 para egress (apt).
    dynamic "ip_config" {
      for_each = var.in_private_subnet ? [1] : []
      content {
        ipv4 {
          address = "dhcp"
        }
      }
    }
  }

  network_interface {
    name   = "eth0"
    bridge = var.in_private_subnet ? var.private_bridge : var.public_bridge
  }

  dynamic "network_interface" {
    for_each = var.in_private_subnet ? [1] : []
    content {
      name   = "eth1"
      bridge = var.public_bridge
    }
  }

  hook_script_file_id = var.hookscript_file_id

  lifecycle {
    ignore_changes = [
      initialization,
    ]
  }
}

output "id" { value = proxmox_virtual_environment_container.this.id }
output "vmid" { value = proxmox_virtual_environment_container.this.vm_id }
output "hostname" { value = var.hostname }
