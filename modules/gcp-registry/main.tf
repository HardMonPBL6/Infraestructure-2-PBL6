# Artifact Registry (Docker) — un repo por proyecto GCP.

terraform {
  required_providers {
    google = {
      source                = "hashicorp/google"
      version               = "~> 6.0"
      configuration_aliases = [google]
    }
  }
}

variable "name_prefix" { type = string }
variable "location" { type = string }
variable "project_id" { type = string }

resource "google_artifact_registry_repository" "docker" {
  repository_id = "${var.name_prefix}-docker"
  location      = var.location
  format        = "DOCKER"
  description   = "WebHardMon container registry (${var.name_prefix})"
}

output "repo_url" {
  value = "${var.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.docker.repository_id}"
}

output "repo_id" { value = google_artifact_registry_repository.docker.id }
