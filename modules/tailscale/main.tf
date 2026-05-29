# Modulo Tailscale:
#  - Define la ACL del tailnet (tags por nube y rol, reglas restrictivas).
#  - Emite auth keys preautorizadas + reutilizables + etiquetadas, una por nube.

terraform {
  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.17"
    }
  }
}

variable "project_name" {
  type = string
}

variable "clouds" {
  description = "Nombres de las nubes (para tags y keys)."
  type        = list(string)
  default     = ["local", "gcp-a", "gcp-b"]
}

variable "roles" {
  description = "Roles funcionales que existen en el sistema."
  type        = list(string)
  default = [
    "nifi", "hdfs", "mapreduce", "harbor",
    "kafka", "zookeeper", "java", "cassandra",
    "mysql", "hbase", "elasticsearch", "grafana",
    "mgmt",
  ]
}

variable "ssh_admin_tag" {
  description = "Tag autorizado a abrir SSH contra el resto del tailnet."
  type        = string
  default     = "mgmt"
}

# ----------------------------------------------------------------------------
# ACL del tailnet
# ----------------------------------------------------------------------------
# Reglas:
#  - SSH (22) sólo entre nodos del tailnet — nunca desde Internet.
#  - El tag mgmt llega a todo por 22.
#  - Cada tag de nube llega libremente a sí mismo (intra-nube).
#  - Las tags de webhardmon pueden hablarse entre nubes pero solo en los
#    puertos relevantes (Kafka, HDFS, RMI, Cassandra, MySQL, HBase, ES).
locals {
  cloud_tags = [for c in var.clouds : "tag:${replace(c, "-", "_")}"]
  role_tags  = [for r in var.roles : "tag:${r}"]
  all_tags = concat(
    ["tag:${var.project_name}"],
    local.cloud_tags,
    local.role_tags,
  )

  acl = {
    tagOwners = merge(
      { "tag:${var.project_name}" = ["autogroup:admin"] },
      { for t in local.cloud_tags : t => ["autogroup:admin"] },
      { for t in local.role_tags : t => ["autogroup:admin"] },
    )

    acls = [
      # mgmt -> todos: SSH y administración
      {
        action = "accept"
        src    = ["tag:${var.ssh_admin_tag}"]
        dst    = ["tag:${var.project_name}:*"]
      },
      # Cualquier nodo webhardmon habla con cualquier otro nodo webhardmon
      # solo en los puertos de servicio. Sin SSH abierto entre tags de servicio.
      {
        action = "accept"
        src    = ["tag:${var.project_name}"]
        dst = [
          "tag:kafka:9092,9093",
          "tag:zookeeper:2181,2888,3888",
          "tag:hdfs:8020,9000,9866,9870",
          "tag:java:1099,1100",
          "tag:cassandra:7000,7001,9042",
          "tag:mysql:3306",
          "tag:hbase:2181,16000,16010,16020,16030",
          "tag:elasticsearch:9200,9300",
          "tag:nifi:8080,8443,10000",
          "tag:grafana:3000",
          "tag:harbor:80,443",
        ]
      },
    ]

    ssh = [
      # Tailscale SSH: sólo mgmt y como usuario no-root
      {
        action = "accept"
        src    = ["tag:${var.ssh_admin_tag}"]
        dst    = ["tag:${var.project_name}"]
        users  = ["autogroup:nonroot", "ubuntu"]
      },
    ]
  }
}

resource "tailscale_acl" "webhardmon" {
  acl = jsonencode(local.acl)
}

# Una auth key por nube — reutilizable + preautorizada + etiquetada con la nube
# y el proyecto. Asi cada nodo se une con el tag correcto.
resource "tailscale_tailnet_key" "per_cloud" {
  for_each = toset(var.clouds)

  reusable      = true
  ephemeral     = false
  preauthorized = true
  expiry        = 7776000 # 90 dias
  description   = "${var.project_name} - ${each.key}"
  tags          = ["tag:${var.project_name}", "tag:${replace(each.key, "-", "_")}"]
}

output "auth_keys" {
  description = "Auth keys por nube (sensibles)."
  value       = { for k, v in tailscale_tailnet_key.per_cloud : k => v.key }
  sensitive   = true
}

output "acl_applied" {
  value = tailscale_acl.webhardmon.id
}
