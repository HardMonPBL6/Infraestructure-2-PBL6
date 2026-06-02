# ============================================================
#  FASE 2 · Desplegar HDFS dentro de los LXC ya creados
#  Provider: kreuzwerker/docker, un alias por LXC (SSH)
#  Requiere haber aplicado 01-lxc antes (Docker ya instalado).
# ============================================================

terraform {
  required_version = ">= 1.6"
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
  # backend "gcs" {
  #   bucket = "webhardmon-tofu-state"
  #   prefix = "local/hdfs"
  # }
}

locals {
  namenode_ip   = "10.10.1.21"
  datanode0_ip  = "10.10.1.22"
  datanode1_ip  = "10.10.1.23"
  namenode_uri  = "hdfs://${local.namenode_ip}:${var.namenode_rpc_port}"
}

# ── Un provider Docker por LXC (SSH como root) ───────────────
provider "docker" {
  alias = "namenode"
  host  = "ssh://root@${local.namenode_ip}"
  ssh_opts = ["-i", var.ssh_private_key_path, "-o", "StrictHostKeyChecking=no"]
}
provider "docker" {
  alias = "datanode0"
  host  = "ssh://root@${local.datanode0_ip}"
  ssh_opts = ["-i", var.ssh_private_key_path, "-o", "StrictHostKeyChecking=no"]
}
provider "docker" {
  alias = "datanode1"
  host  = "ssh://root@${local.datanode1_ip}"
  ssh_opts = ["-i", var.ssh_private_key_path, "-o", "StrictHostKeyChecking=no"]
}

# ── NameNode (LXC .21) ───────────────────────────────────────
resource "docker_volume" "namenode" {
  provider = docker.namenode
  name     = "${var.name_prefix}-hdfs-namenode"
}

resource "docker_image" "namenode" {
  provider = docker.namenode
  name     = "${var.harbor_registry}/${var.image_namenode}:${var.hadoop_version}"
}

resource "docker_container" "namenode" {
  provider     = docker.namenode
  name         = "${var.name_prefix}-hdfs-namenode"
  image        = docker_image.namenode.image_id
  restart      = "unless-stopped"
  network_mode = "host"

  volumes {
    volume_name    = docker_volume.namenode.name
    container_path = "/hadoop/dfs/name"
  }

  env = [
    "CLUSTER_NAME=${var.name_prefix}",
    "CORE_CONF_fs_defaultFS=${local.namenode_uri}",
    "HDFS_CONF_dfs_namenode_name_dir=file:///hadoop/dfs/name",
    "HDFS_CONF_dfs_namenode_rpc___bind___host=0.0.0.0",
    "HDFS_CONF_dfs_namenode_http___bind___host=0.0.0.0",
    "HDFS_CONF_dfs_namenode_servicerpc___bind___host=0.0.0.0",
    "HDFS_CONF_dfs_replication=${var.dfs_replication}",
    "HDFS_CONF_dfs_blocksize=${var.dfs_blocksize}",
    "HDFS_CONF_dfs_namenode_datanode_registration_ip___hostname___check=false",
    "HDFS_CONF_dfs_client_use_datanode_hostname=true",
    "HDFS_CONF_dfs_permissions_enabled=false",
  ]
}

# ── DataNode-0 (LXC .22) ─────────────────────────────────────
resource "docker_volume" "datanode0" {
  provider = docker.datanode0
  name     = "${var.name_prefix}-hdfs-datanode0"
}
resource "docker_image" "datanode0" {
  provider = docker.datanode0
  name     = "${var.harbor_registry}/${var.image_datanode}:${var.hadoop_version}"
}
resource "docker_container" "datanode0" {
  provider     = docker.datanode0
  name         = "${var.name_prefix}-hdfs-datanode0"
  image        = docker_image.datanode0.image_id
  restart      = "unless-stopped"
  network_mode = "host"

  volumes {
    volume_name    = docker_volume.datanode0.name
    container_path = "/hadoop/dfs/data"
  }

  env = [
    "CORE_CONF_fs_defaultFS=${local.namenode_uri}",
    "HDFS_CONF_dfs_datanode_data_dir=file:///hadoop/dfs/data",
    "HDFS_CONF_dfs_replication=${var.dfs_replication}",
    "HDFS_CONF_dfs_datanode_hostname=${local.datanode0_ip}",
    "HDFS_CONF_dfs_client_use_datanode_hostname=true",
    "HDFS_CONF_dfs_datanode_use_datanode_hostname=true",
  ]
}

# ── DataNode-1 (LXC .23) ─────────────────────────────────────
resource "docker_volume" "datanode1" {
  provider = docker.datanode1
  name     = "${var.name_prefix}-hdfs-datanode1"
}
resource "docker_image" "datanode1" {
  provider = docker.datanode1
  name     = "${var.harbor_registry}/${var.image_datanode}:${var.hadoop_version}"
}
resource "docker_container" "datanode1" {
  provider     = docker.datanode1
  name         = "${var.name_prefix}-hdfs-datanode1"
  image        = docker_image.datanode1.image_id
  restart      = "unless-stopped"
  network_mode = "host"

  volumes {
    volume_name    = docker_volume.datanode1.name
    container_path = "/hadoop/dfs/data"
  }

  env = [
    "CORE_CONF_fs_defaultFS=${local.namenode_uri}",
    "HDFS_CONF_dfs_datanode_data_dir=file:///hadoop/dfs/data",
    "HDFS_CONF_dfs_replication=${var.dfs_replication}",
    "HDFS_CONF_dfs_datanode_hostname=${local.datanode1_ip}",
    "HDFS_CONF_dfs_client_use_datanode_hostname=true",
    "HDFS_CONF_dfs_datanode_use_datanode_hostname=true",
  ]
}

# ── Outputs ──────────────────────────────────────────────────
output "namenode_uri" {
  description = "fs.defaultFS para el cliente Java en GCP-A"
  value       = local.namenode_uri
}
output "namenode_ui" {
  value = "http://${local.namenode_ip}:${var.namenode_ui_port}"
}
