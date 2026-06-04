# =============================================================================
# Outputs e inventario Ansible
# =============================================================================
#
# Hosts locales -> IP LAN. Hosts GCP gateway -> IP WireGuard (10.0.0.x).
# Hosts GCP privados -> IP interna GCP, alcanzable via el gateway WireGuard.

locals {
  # Cada host lleva una LISTA de roles. Los CTs locales tienen un unico rol;
  # los nodos GCP compartidos alojan varios servicios -> aparecen en varios
  # grupos [rol] del inventario para que Ansible despliegue cada contenedor.
  all_hosts = concat(
    [for k, v in local.local_cts : {
      name         = v.hostname
      ansible_host = v.ip
      roles        = [v.role]
      cloud        = "local"
    }],
    [for k, v in local.gcp_a_vms : {
      name         = v.hostname
      ansible_host = v.is_gateway ? local.wg_gcp_a_gw_ip : v.network_ip
      roles        = v.roles
      cloud        = "gcp-a"
    }],
    [for k, v in local.gcp_b_vms : {
      name         = v.hostname
      ansible_host = v.is_gateway ? local.wg_gcp_b_gw_ip : v.network_ip
      roles        = v.roles
      cloud        = "gcp-b"
    }],
  )

  groups_by_role = {
    for role in distinct(flatten([for h in local.all_hosts : h.roles])) :
    role => [for h in local.all_hosts : { name = h.name, ansible_host = h.ansible_host } if contains(h.roles, role)]
  }

  groups_by_cloud = {
    for c in distinct([for h in local.all_hosts : h.cloud]) :
    c => [for h in local.all_hosts : { name = h.name, ansible_host = h.ansible_host } if h.cloud == c]
  }
}

resource "local_file" "ansible_inventory" {
  filename        = "${path.module}/ansible/inventory.ini"
  file_permission = "0644"
  content = templatefile("${path.module}/ansible/inventory.tmpl", {
    groups_by_role  = local.groups_by_role
    groups_by_cloud = local.groups_by_cloud
    ssh_port        = var.ssh_port
  })
}

# ---- Outputs visibles ------------------------------------------------------

output "hosts_by_role" {
  description = "Hosts agrupados por rol con su ansible_host (LAN IP para locales, WireGuard IP para gateways GCP, IP interna GCP para nodos privados)."
  value       = local.groups_by_role
}

output "hosts_by_cloud" {
  description = "Hosts agrupados por nube."
  value       = local.groups_by_cloud
}

output "container_registries" {
  description = "URLs de los registros de contenedores por nube."
  value = {
    "gcp-a" = module.gcp_a_registry.repo_url
    "gcp-b" = module.gcp_b_registry.repo_url
    "local" = "Harbor (desplegado por Ansible sobre CT harbor-01)"
  }
}

output "ansible_inventory_path" {
  description = "Ruta al inventario generado."
  value       = local_file.ansible_inventory.filename
}

output "wireguard_gateway_ips" {
  description = "IPs publicas estaticas de los gateways WireGuard (necesarias para configurar peers externos: nodo de gestion y gateway local)."
  value = {
    "gcp-a" = google_compute_address.gcp_a_gateway.address
    "gcp-b" = google_compute_address.gcp_b_gateway.address
  }
}

# ---- Cloudflare Tunnel (ingesta externa) -----------------------------------

output "ingest_hostname" {
  description = "Hostname publico de ingesta para los collectors."
  value       = var.cloudflare_enabled ? module.cloudflare_tunnel[0].ingest_hostname : null
}

output "cloudflared_tunnel_token" {
  description = "Token para `cloudflared` en el CT de NiFi (lo consume Ansible)."
  value       = var.cloudflare_enabled ? module.cloudflare_tunnel[0].tunnel_token : null
  sensitive   = true
}
