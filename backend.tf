# Backend del state.
#
# Por defecto: backend local. Es suficiente porque todo se opera desde el
# mismo nodo de gestion y no hay colaboracion concurrente sobre el state.
#
# Para conmutar a GCS (recomendado si varios operadores) descomenta el
# bloque "backend gcs" y comenta el "backend local". El bucket debe crearse
# antes del primer `tofu init` -> ver bootstrap/README.md.

terraform {
  backend "local" {
    path = "terraform.tfstate"
  }

  # backend "gcs" {
  #   bucket = "webhardmon-tofu-state"   # crear con: gsutil mb -p <gcp_a> -l EU gs://webhardmon-tofu-state && gsutil versioning set on gs://webhardmon-tofu-state
  #   prefix = "webhardmon/tofu"
  # }
}
