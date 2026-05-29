# =============================================================================
# Outputs e inventario Ansible
# =============================================================================
#
# Hosts locales -> IP LAN (subnet router en el portatil enruta esos rangos
# via Tailscale). Hosts GCP -> hostname Tailscale (MagicDNS).

locals {
  all_hosts = concat(
    [for k, v in local.local_cts : {
      name         = v.hostname
      ansible_host = v.ip
      role         = v.role
      cloud        = "local"
    }],
    [for k, v in local.gcp_a_vms : {
      name         = v.hostname
      ansible_host = "" # MagicDNS resuelve el hostname
      role         = v.role
      cloud        = "gcp-a"
    }],
    [for k, v in local.gcp_b_vms : {
      name         = v.hostname
      ansible_host = ""
      role         = v.role
      cloud        = "gcp-b"
    }],
  )

  groups_by_role = {
    for role in distinct([for h in local.all_hosts : h.role]) :
    role => [for h in local.all_hosts : { name = h.name, ansible_host = h.ansible_host } if h.role == role]
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
  })
}

# ---- Outputs visibles ------------------------------------------------------

output "hosts_by_role" {
  description = "Hosts agrupados por rol con su ansible_host (LAN IP para locales, '' para GCP via MagicDNS)."
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

output "tailscale_acl_id" {
  value = module.tailscale.acl_applied
}
