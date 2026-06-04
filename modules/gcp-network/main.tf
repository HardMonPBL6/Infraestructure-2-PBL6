# VPC con 2 subredes (publica/privada), Cloud Router + Cloud NAT para que la
# subred privada tenga egress (actualizaciones, pull de imagenes, etc.), y
# reglas de firewall minimas (sin SSH desde Internet — SSH va por WireGuard).

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
variable "region" { type = string }

variable "public_cidr" {
  type        = string
  description = "Subred publica — borde, ingesta/servicio externo."
}
variable "private_cidr" {
  type        = string
  description = "Subred privada — cluster interno, sin IP publica."
}

resource "google_compute_network" "vpc" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
  description             = "WebHardMon VPC para ${var.name_prefix}"
}

resource "google_compute_subnetwork" "public" {
  name          = "${var.name_prefix}-public"
  ip_cidr_range = var.public_cidr
  region        = var.region
  network       = google_compute_network.vpc.id
  description   = "Subred publica: instancias de borde (Kafka brokers / Grafana / MySQL frontend). IP externa estatica para el gateway WireGuard."
}

resource "google_compute_subnetwork" "private" {
  name                     = "${var.name_prefix}-private"
  ip_cidr_range            = var.private_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
  description              = "Subred privada: nodos de cluster (Cassandra/HBase/ES). Sin IP externa; egress por Cloud NAT."
}

resource "google_compute_router" "router" {
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.name_prefix}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.private.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# ---- Firewall --------------------------------------------------------------
# NOTA: NO se abre SSH (22) desde 0.0.0.0/0. El acceso administrativo va por
# WireGuard. Solo permitimos UDP 51820 (WireGuard) e ICMP.

resource "google_compute_firewall" "allow_wireguard" {
  name          = "${var.name_prefix}-allow-wireguard"
  network       = google_compute_network.vpc.id
  description   = "UDP 51820: WireGuard VPN inter-nube."
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "udp"
    ports    = ["51820"]
  }
}

resource "google_compute_firewall" "allow_icmp" {
  name          = "${var.name_prefix}-allow-icmp"
  network       = google_compute_network.vpc.id
  description   = "ICMP para diagnostico."
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]

  allow { protocol = "icmp" }
}

resource "google_compute_firewall" "allow_internal" {
  name          = "${var.name_prefix}-allow-internal"
  network       = google_compute_network.vpc.id
  description   = "Tráfico intra-VPC (entre subredes publica/privada)."
  direction     = "INGRESS"
  source_ranges = [var.public_cidr, var.private_cidr]

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

variable "wg_vpn_cidr" {
  description = "CIDR de la VPN WireGuard. Solo se permite trafico de servicio desde esta red."
  type        = string
  default     = "10.0.0.0/24"
}

variable "wg_service_source_ranges" {
  description = "Origenes permitidos para trafico de servicio entrante via la malla. Por defecto solo la VPN; el repo raiz lo amplia con las subredes locales/inter-nube (malla enrutada sin NAT)."
  type        = list(string)
  default     = null
}

resource "google_compute_firewall" "allow_wg_vpn" {
  name          = "${var.name_prefix}-allow-wg-vpn"
  network       = google_compute_network.vpc.id
  description   = "Trafico de servicios desde la malla WireGuard (VPN + subredes locales/inter-nube enrutadas)."
  direction     = "INGRESS"
  source_ranges = coalesce(var.wg_service_source_ranges, [var.wg_vpn_cidr])

  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

output "vpc_id" { value = google_compute_network.vpc.id }
output "public_subnet_id" { value = google_compute_subnetwork.public.id }
output "private_subnet_id" { value = google_compute_subnetwork.private.id }
output "public_subnet_name" { value = google_compute_subnetwork.public.name }
output "private_subnet_name" { value = google_compute_subnetwork.private.name }
