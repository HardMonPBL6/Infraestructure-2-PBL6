# ============================================================
#  FASE 1 · Crear los 3 LXC en Proxmox e instalar Docker dentro
#  Un provider alias por nodo para evitar el problema de SSL
#  al conectar a pve-local2 y pve-local3 desde el cluster.
# ============================================================

terraform {
  required_version = ">= 1.6"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
  # backend "gcs" {
  #   bucket = "webhardmon-tofu-state"
  #   prefix = "local/lxc"
  # }
}

# ── Provider por defecto (requerido aunque no lo use ningún recurso) ──
provider "proxmox" {
  endpoint  = "https://${var.proxmox_node_0_ip}:8006"
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = true
  ssh {
    agent       = false
    username    = var.proxmox_ssh_user
    private_key = file(var.ssh_private_key_path)
  }
}

# ── Un provider por nodo Proxmox (cada uno apunta directamente) ──
provider "proxmox" {
  alias     = "node0"
  endpoint  = "https://${var.proxmox_node_0_ip}:8006"
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = true
  ssh {
    agent       = false
    username    = var.proxmox_ssh_user
    private_key = file(var.ssh_private_key_path)
  }
}

provider "proxmox" {
  alias     = "node1"
  endpoint  = "https://${var.proxmox_node_1_ip}:8006"
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = true
  ssh {
    agent       = false
    username    = var.proxmox_ssh_user
    private_key = file(var.ssh_private_key_path)
  }
}

provider "proxmox" {
  alias     = "node2"
  endpoint  = "https://${var.proxmox_node_2_ip}:8006"
  api_token = "${var.proxmox_api_token_id}=${var.proxmox_api_token_secret}"
  insecure  = true
  ssh {
    agent       = false
    username    = var.proxmox_ssh_user
    private_key = file(var.ssh_private_key_path)
  }
}

# ── NameNode (pve-local · 10.10.1.21) ────────────────────────
resource "proxmox_virtual_environment_container" "namenode" {
  provider      = proxmox.node0
  node_name     = var.proxmox_node_0
  description   = "WebHardMon HDFS · namenode"
  unprivileged  = true
  start_on_boot = true
  started       = true

  features {
    nesting = true
  }

  cpu {
    cores = var.lxc_cores
  }

  memory {
    dedicated = var.lxc_memory_mb
  }

  disk {
    datastore_id = var.lxc_storage
    size         = var.lxc_disk_gb
  }

  operating_system {
    template_file_id = var.lxc_ostemplate
    type             = "debian"
  }

  network_interface {
    name   = "eth0"
    bridge = var.lxc_bridge
  }

  initialization {
    hostname = "hdfs-namenode"
    dns {
      servers = ["172.17.18.2", "8.8.8.8"]
    }
    ip_config {
      ipv4 {
        address = "10.10.1.21/24"
        gateway = var.lxc_gateway
      }
    }
    user_account {
      keys = [trimspace(var.ssh_public_key)]
    }
  }
}

# ── DataNode-0 (pve-local2 · 10.10.1.22) ─────────────────────
resource "proxmox_virtual_environment_container" "datanode0" {
  provider      = proxmox.node1
  node_name     = var.proxmox_node_1
  description   = "WebHardMon HDFS · datanode0"
  unprivileged  = true
  start_on_boot = true
  started       = true

  features {
    nesting = true
  }

  cpu {
    cores = var.lxc_cores
  }

  memory {
    dedicated = var.lxc_memory_mb
  }

  disk {
    datastore_id = var.lxc_storage
    size         = var.lxc_disk_gb
  }

  operating_system {
    template_file_id = var.lxc_ostemplate
    type             = "debian"
  }

  network_interface {
    name   = "eth0"
    bridge = var.lxc_bridge
  }

  initialization {
    hostname = "hdfs-datanode0"
    dns {
      servers = ["172.17.18.2", "8.8.8.8"]
    }
    ip_config {
      ipv4 {
        address = "10.10.1.22/24"
        gateway = var.lxc_gateway
      }
    }
    user_account {
      keys = [trimspace(var.ssh_public_key)]
    }
  }
}

# ── DataNode-1 (pve-local3 · 10.10.1.23) ─────────────────────
resource "proxmox_virtual_environment_container" "datanode1" {
  provider      = proxmox.node2
  node_name     = var.proxmox_node_2
  description   = "WebHardMon HDFS · datanode1"
  unprivileged  = true
  start_on_boot = true
  started       = true

  features {
    nesting = true
  }

  cpu {
    cores = var.lxc_cores
  }

  memory {
    dedicated = var.lxc_memory_mb
  }

  disk {
    datastore_id = var.lxc_storage
    size         = var.lxc_disk_gb
  }

  operating_system {
    template_file_id = var.lxc_ostemplate
    type             = "debian"
  }

  network_interface {
    name   = "eth0"
    bridge = var.lxc_bridge
  }

  initialization {
    hostname = "hdfs-datanode1"
    dns {
      servers = ["172.17.18.2", "8.8.8.8"]
    }
    ip_config {
      ipv4 {
        address = "10.10.1.23/24"
        gateway = var.lxc_gateway
      }
    }
    user_account {
      keys = [trimspace(var.ssh_public_key)]
    }
  }
}

# ── Esperar a que los LXC completen su boot inicial ──────────
resource "time_sleep" "wait_for_lxc_boot" {
  depends_on = [
    proxmox_virtual_environment_container.namenode,
    proxmox_virtual_environment_container.datanode0,
    proxmox_virtual_environment_container.datanode1,
  ]
  create_duration = "90s"   # subido de 60s a 90s: Debian 13 tarda un poco más en el primer boot
}

# ── Instalar Docker en los 3 LXC ─────────────────────────────
locals {
  lxc_nodes = {
    namenode  = { ip = "10.10.1.21", id = proxmox_virtual_environment_container.namenode.id }
    datanode0 = { ip = "10.10.1.22", id = proxmox_virtual_environment_container.datanode0.id }
    datanode1 = { ip = "10.10.1.23", id = proxmox_virtual_environment_container.datanode1.id }
  }
}

resource "null_resource" "install_docker" {
  for_each = local.lxc_nodes

  depends_on = [time_sleep.wait_for_lxc_boot]

  triggers = {
    container_id = each.value.id
    script_hash  = filemd5("${path.module}/install-docker.sh")
  }

  connection {
    type        = "ssh"
    host        = each.value.ip
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    timeout     = "5m"
  }

  # ── Paso 1: activar SSH keepalive en el servidor ──────────────────────────
  # Sin esto, Go's SSH library pierde la sesión si el script tarda más de
  # lo que el kernel deja sin actividad TCP. Hacemos reload (no restart)
  # para no cerrar la conexión actual.
  provisioner "remote-exec" {
    inline = [
      "grep -q '^ClientAliveInterval' /etc/ssh/sshd_config || echo 'ClientAliveInterval 30' >> /etc/ssh/sshd_config",
      "grep -q '^ClientAliveCountMax'  /etc/ssh/sshd_config || echo 'ClientAliveCountMax 20'  >> /etc/ssh/sshd_config",
      "systemctl reload ssh 2>/dev/null || service ssh reload 2>/dev/null || true",
    ]
  }

  # ── Paso 2: subir script ──────────────────────────────────────────────────
  provisioner "file" {
    source      = "${path.module}/install-docker.sh"
    destination = "/root/install-docker.sh"
  }

  # ── Paso 3: ejecutar instalación (~3 min con docker.io de Debian) ────────
  provisioner "remote-exec" {
    inline = [
      "chmod +x /root/install-docker.sh",
      "HARBOR_REGISTRY='${var.harbor_registry}' bash /root/install-docker.sh",
    ]
  }
}

# ── Outputs para la Fase 2 ───────────────────────────────────
output "lxc_ips" {
  value = {
    namenode  = "10.10.1.21"
    datanode0 = "10.10.1.22"
    datanode1 = "10.10.1.23"
  }
}
