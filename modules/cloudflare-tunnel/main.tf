# Cloudflare Tunnel para la ingesta externa.
#
# El collector corre en PCs de usuario FUERA de las tres nubes. No puede entrar
# por WireGuard (no son peers de la malla) ni por la LAN local (detras de NAT
# domestico, sin ingress publico). Este modulo publica el endpoint de ingesta de
# NiFi en `ingest.<zona>` via un tunel Cloudflare: `cloudflared` corre en el CT
# de NiFi y marca SALIENTE hacia el edge de Cloudflare (sin abrir puertos ni
# port-forward). El endpoint queda PUBLICO: la autenticacion la hace NiFi a nivel
# de aplicacion validando la licencia (codigo, portatil) antes de enrutar a Kafka
# (no hay Cloudflare Access en el edge).
#
# Lo que crea OpenTofu aqui es solo el plano de control (tunel + DNS + token).
# El demonio `cloudflared` lo instala Ansible en el CT de NiFi con el
# `tunnel_token` que este modulo exporta.

terraform {
  required_providers {
    cloudflare = {
      source                = "cloudflare/cloudflare"
      version               = "~> 4.52"
      configuration_aliases = [cloudflare]
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

variable "account_id" { type = string }
variable "zone_id" { type = string }
variable "zone_name" {
  type        = string
  description = "Dominio gestionado en Cloudflare (p.ej. example.com)."
}
variable "subdomain" {
  type        = string
  default     = "ingest"
  description = "Subdominio para el endpoint de ingesta -> <subdomain>.<zone_name>."
}
variable "nifi_ingest_port" {
  type        = number
  default     = 8081
  description = "Puerto del listener HTTP de ingesta de NiFi (ListenHTTP/HandleHttpRequest) dentro del CT."
}
variable "tunnel_name" {
  type    = string
  default = "webhardmon-ingest"
}

locals {
  ingest_hostname = "${var.subdomain}.${var.zone_name}"
}

# Secreto del conector (32+ bytes en base64). Lo usa el propio tunel.
resource "random_id" "tunnel_secret" {
  byte_length = 35
}

# --- Tunel -------------------------------------------------------------------
resource "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  account_id = var.account_id
  name       = var.tunnel_name
  secret     = random_id.tunnel_secret.b64_std
  config_src = "cloudflare"
}

# Reglas de ingress: el hostname publico -> NiFi en localhost del CT.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this.id

  config {
    ingress_rule {
      hostname = local.ingest_hostname
      service  = "http://localhost:${var.nifi_ingest_port}"
    }
    # Catch-all obligatorio.
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# CNAME ingest.<zona> -> <tunnel-id>.cfargotunnel.com (proxied).
resource "cloudflare_record" "ingest" {
  zone_id = var.zone_id
  name    = var.subdomain
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  comment = "WebHardMon ingest tunnel"
}

# --- Outputs -----------------------------------------------------------------
output "ingest_hostname" {
  value = local.ingest_hostname
}

output "tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.this.id
}

# Token que consume `cloudflared` en el CT de NiFi (lo usa Ansible).
output "tunnel_token" {
  value     = cloudflare_zero_trust_tunnel_cloudflared.this.tunnel_token
  sensitive = true
}
