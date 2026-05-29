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

    # IP externa efímera solo en la subred publica — ayuda a la travesia NAT
    # de Tailscale en el primer arranque. Privadas: sin IP externa, egress
    # por Cloud NAT.
    dynamic "access_config" {
      for_each = var.public ? [1] : []
      content {}
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
      instance_termination_action = "STOP"
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
