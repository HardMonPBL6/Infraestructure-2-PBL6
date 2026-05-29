# Instancia GCE generica para WebHardMon.
# - Imagen Ubuntu 24.04 LTS
# - cloud-init via metadata user-data (plantilla externa)
# - subnet publica/privada elegida por variable; public_ip solo si publica.

terraform {
  required_providers {
    google = {
      source                = "hashicorp/google"
      version               = "~> 6.0"
      configuration_aliases = [google]
    }
  }
}

variable "name" { type = string }
variable "zone" { type = string }
variable "machine_type" { type = string }
variable "subnet_id" { type = string }
variable "public" { type = bool }
variable "network_ip" {
  description = "IP interna estatica. Null = DHCP."
  type        = string
  default     = null
}
variable "external_ip_address" {
  description = "IP externa estatica pre-asignada (google_compute_address). Null = efimera."
  type        = string
  default     = null
}
variable "user_data" { type = string }
variable "service_account" { type = string }
variable "labels" {
  type    = map(string)
  default = {}
}
variable "disk_gb" {
  type    = number
  default = 20
}
variable "spot" {
  type    = bool
  default = false
}
variable "spot_termination_action" {
  description = "Accion al interrumpir la VM spot: DELETE (borra VM + disco) o STOP (conserva disco)."
  type        = string
  default     = "DELETE"
}

resource "google_compute_instance" "this" {
  name         = var.name
  machine_type = var.machine_type
  zone         = var.zone
  labels       = var.labels
  tags         = ["webhardmon", replace(var.name, "/[^a-z0-9-]/", "-")]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.disk_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = var.subnet_id
    network_ip = var.network_ip

    # IP externa solo en subred publica. Los gateways WireGuard usan IP
    # estatica pre-asignada (var.external_ip_address); el resto efimera.
    dynamic "access_config" {
      for_each = var.public ? [1] : []
      content {
        nat_ip = var.external_ip_address
      }
    }
  }

  metadata = {
    user-data              = var.user_data
    block-project-ssh-keys = "TRUE"
  }

  service_account {
    email  = var.service_account
    scopes = ["cloud-platform"]
  }

  dynamic "scheduling" {
    for_each = var.spot ? [1] : []
    content {
      provisioning_model          = "SPOT"
      preemptible                 = true
      automatic_restart           = false
      on_host_maintenance         = "TERMINATE"
      instance_termination_action = var.spot_termination_action
    }
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  lifecycle {
    ignore_changes = [metadata["user-data"]]
  }
}

output "id" { value = google_compute_instance.this.id }
output "name" { value = google_compute_instance.this.name }
output "internal_ip" { value = google_compute_instance.this.network_interface[0].network_ip }
output "external_ip" {
  value = var.public ? google_compute_instance.this.network_interface[0].access_config[0].nat_ip : null
}
