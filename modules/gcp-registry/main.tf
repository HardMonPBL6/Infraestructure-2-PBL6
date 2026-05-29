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
variable "reader_members" {
  type        = list(string)
  default     = []
  description = "Identidades (formato IAM, p.ej. 'serviceAccount:foo@bar.iam.gserviceaccount.com') con permiso de PULL sobre el repo."
}

resource "google_artifact_registry_repository" "docker" {
  repository_id = "${var.name_prefix}-docker"
  location      = var.location
  format        = "DOCKER"
  description   = "WebHardMon container registry (${var.name_prefix})"
}

# Permiso de lectura (pull) a nivel de repo — las VMs lo usan via su SA + el
# credential helper de gcloud. Mas restrictivo que un binding a nivel proyecto.
resource "google_artifact_registry_repository_iam_member" "readers" {
  for_each = toset(var.reader_members)

  project    = var.project_id
  location   = var.location
  repository = google_artifact_registry_repository.docker.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}

output "repo_url" {
  value = "${var.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.docker.repository_id}"
}

output "repo_id" { value = google_artifact_registry_repository.docker.id }
