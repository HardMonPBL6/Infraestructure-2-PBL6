# ============================================================
#  FASE 2 · variables
# ============================================================

variable "name_prefix" {
  type    = string
  default = "webhardmon"
}

variable "ssh_private_key_path" {
  description = "Clave privada para entrar por SSH a los LXC (la misma de la Fase 1)"
  type        = string
}

# ── Harbor / imágenes ────────────────────────────────────────
variable "harbor_registry" {
  type    = string
  default = "10.10.1.50:5000"
}
variable "image_namenode" {
  type    = string
  default = "hadoop-namenode"
}
variable "image_datanode" {
  type    = string
  default = "hadoop-datanode"
}
variable "hadoop_version" {
  type    = string
  default = "2.0.0-hadoop3.2.1-java8"
}

# ── HDFS ─────────────────────────────────────────────────────
variable "dfs_replication" {
  type    = number
  default = 2
}
variable "dfs_blocksize" {
  type    = number
  default = 134217728 # 128 MiB
}
variable "namenode_rpc_port" {
  type    = number
  default = 9000
}
variable "namenode_ui_port" {
  type    = number
  default = 9870
}
