# Proxmox: se accede a la API via WireGuard (gateway local) al nodo en 10.10.1.15:8006.
# Credenciales por variables sensibles (token recomendado).
provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_tls_insecure

  # Para subir snippets (hookscripts) por SSH al nodo PVE.
  ssh {
    agent       = false
    username    = var.proxmox_ssh_user
    private_key = var.proxmox_ssh_private_key
  }
}

# Dos proyectos GCP = dos proveedores con alias.
# Cada uno con su propia service account / credenciales.
provider "google" {
  alias       = "gcp_a"
  project     = var.gcp_a_project_id
  region      = var.gcp_a_region
  zone        = var.gcp_a_zone
  credentials = var.gcp_a_credentials_file != "" ? file(var.gcp_a_credentials_file) : null
}

provider "google" {
  alias       = "gcp_b"
  project     = var.gcp_b_project_id
  region      = var.gcp_b_region
  zone        = var.gcp_b_zone
  credentials = var.gcp_b_credentials_file != "" ? file(var.gcp_b_credentials_file) : null
}

provider "google-beta" {
  alias       = "gcp_a"
  project     = var.gcp_a_project_id
  region      = var.gcp_a_region
  zone        = var.gcp_a_zone
  credentials = var.gcp_a_credentials_file != "" ? file(var.gcp_a_credentials_file) : null
}

provider "google-beta" {
  alias       = "gcp_b"
  project     = var.gcp_b_project_id
  region      = var.gcp_b_region
  zone        = var.gcp_b_zone
  credentials = var.gcp_b_credentials_file != "" ? file(var.gcp_b_credentials_file) : null
}

# Cloudflare: API token (scopes: Account > Cloudflare Tunnel:Edit + Access:Edit,
# Zone > DNS:Edit). Solo se usa si var.cloudflare_enabled = true.
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
