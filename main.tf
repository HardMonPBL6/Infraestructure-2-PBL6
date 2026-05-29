# =============================================================================
# WebHardMon — composicion de las tres nubes
# =============================================================================
# Orden:
#  1. Tailscale (keys + ACL)
#  2. Nube local: plantilla LXC + hookscripts + CTs por rol
#  3. GCP-A: red + service account + VMs + registry
#  4. GCP-B: red + service account + VMs + registry
# =============================================================================

# ---- 1. Tailscale -----------------------------------------------------------

module "tailscale" {
  source       = "./modules/tailscale"
  project_name = var.project_name
  # local NO se une al tailnet: el portatil actua de subnet router publicando
  # 10.10.2.0/24 y 10.10.3.0/24 al tailnet. Asi evitamos instalar Tailscale en
  # cada CT y conservamos un solo punto de control de rutas LAN.
  clouds = ["gcp-a", "gcp-b"]
}

# =============================================================================
# 2. NUBE LOCAL (Proxmox LXC)
# =============================================================================

# Plantilla Ubuntu 24.04 — descarga si no existe.
resource "proxmox_download_file" "ubuntu_lxc" {
  content_type = "vztmpl"
  datastore_id = var.proxmox_datastore_template
  node_name    = var.proxmox_nodes[0]
  url          = "http://download.proxmox.com/images/system/${var.proxmox_ct_template}"
  file_name    = var.proxmox_ct_template
  overwrite    = false
}

# Reparto de CTs por rol -> lista plana usada para los CTs y para el inventario.
locals {
  local_cloud_tag = "local"

  # Cada entrada: { role, idx, public, cores?, memory?, disk_gb? }
  local_ct_specs = concat(
    [for i in range(var.topology.nifi) : {
      role  = "nifi", idx = i + 1, public = true,
      cores = null, memory = null, disk_gb = null
    }],
    [for i in range(var.topology.hdfs) : {
      role  = "hdfs", idx = i + 1, public = false,
      cores = 2, memory = 4096, disk_gb = 32
    }],
    [for i in range(var.topology.mapreduce) : {
      role  = "mapreduce", idx = i + 1, public = false,
      cores = 2, memory = 4096, disk_gb = 24
    }],
    [for i in range(var.topology.harbor) : {
      role  = "harbor", idx = i + 1, public = true,
      cores = 2, memory = 4096, disk_gb = 24
    }],
  )

  # Bases CIDR para asignar IP estatica determinista a cada CT (ultimo
  # octeto = vmid). Asi el inventario Ansible no depende de DHCP.
  local_public_prefix  = regex("^([0-9]+\\.[0-9]+\\.[0-9]+)\\.", var.local_public_cidr)[0]
  local_private_prefix = regex("^([0-9]+\\.[0-9]+\\.[0-9]+)\\.", var.local_private_cidr)[0]

  local_cts = {
    for i, s in local.local_ct_specs :
    format("%s-%02d", s.role, s.idx) => merge(s, {
      vmid     = var.local_vmid_start + i
      hostname = format("%s-%s-%02d", var.project_name, s.role, s.idx)
      node     = element(var.proxmox_nodes, i) # round-robin RGI320
      cores    = coalesce(s.cores, var.lxc_default_resources.cores)
      memory   = coalesce(s.memory, var.lxc_default_resources.memory)
      disk_gb  = coalesce(s.disk_gb, var.lxc_default_resources.disk_gb)
      ip       = s.public ? format("%s.%d", local.local_public_prefix, var.local_vmid_start + i) : format("%s.%d", local.local_private_prefix, var.local_vmid_start + i)
    })
  }
}

# Hookscript snippet por CT (embebe hostname + tags + auth key).
resource "proxmox_virtual_environment_file" "lxc_hook" {
  for_each = local.local_cts

  content_type = "snippets"
  datastore_id = var.proxmox_datastore_template
  node_name    = var.proxmox_nodes[0]

  source_raw {
    file_name = "wh-${each.value.vmid}.sh"
    data = templatefile("${path.module}/cloud-init/lxc-bootstrap.sh.tftpl", {
      ssh_pubkey = var.local_ct_ssh_pubkey
    })
  }
}

module "local_ct" {
  source   = "./modules/proxmox-lxc"
  for_each = local.local_cts

  vmid             = each.value.vmid
  hostname         = each.value.hostname
  node_name        = each.value.node
  template_file_id = proxmox_download_file.ubuntu_lxc.id
  datastore_disk   = var.proxmox_datastore_disk
  cores            = each.value.cores
  memory           = each.value.memory
  swap             = var.lxc_default_resources.swap
  disk_gb          = each.value.disk_gb

  public_bridge     = var.local_public_bridge
  private_bridge    = var.local_private_bridge
  public_gateway    = var.local_public_gateway
  in_private_subnet = !each.value.public
  primary_ip_cidr   = "${each.value.ip}/24"

  hookscript_file_id = proxmox_virtual_environment_file.lxc_hook[each.key].id

  tags = [var.project_name, local.local_cloud_tag, each.value.role]
}

# =============================================================================
# 3. GCP-A — streaming (Kafka + Java/RMI + Cassandra)
# =============================================================================

module "gcp_a_network" {
  source       = "./modules/gcp-network"
  providers    = { google = google.gcp_a }
  name_prefix  = "${var.project_name}-a"
  region       = var.gcp_a_region
  public_cidr  = var.gcp_a_public_cidr
  private_cidr = var.gcp_a_private_cidr
}

resource "google_service_account" "gcp_a" {
  provider     = google.gcp_a
  account_id   = "${var.project_name}-a-vm"
  display_name = "WebHardMon GCP-A VMs"
}

module "gcp_a_registry" {
  source      = "./modules/gcp-registry"
  providers   = { google = google.gcp_a }
  name_prefix = "${var.project_name}-a"
  location    = var.gcp_a_region
  project_id  = var.gcp_a_project_id
}

locals {
  gcp_a_cloud_tag = "gcp_a"
  gcp_a_specs = concat(
    [for i in range(var.topology.kafka) : { role = "kafka", idx = i + 1, public = true }],
    [for i in range(var.topology.zookeeper) : { role = "zookeeper", idx = i + 1, public = false }],
    [for i in range(var.topology.java_rmi) : { role = "java", idx = i + 1, public = false }],
    [for i in range(var.topology.cassandra) : { role = "cassandra", idx = i + 1, public = false }],
  )
  gcp_a_vms = {
    for s in local.gcp_a_specs :
    format("%s-%02d", s.role, s.idx) => merge(s, {
      hostname = format("%s-%s-%02d", var.project_name, s.role, s.idx)
    })
  }
}

module "gcp_a_vm" {
  source    = "./modules/gcp-vm"
  providers = { google = google.gcp_a }
  for_each  = local.gcp_a_vms

  name            = each.value.hostname
  zone            = var.gcp_a_zone
  machine_type    = var.gcp_default_machine_type
  spot            = var.gcp_spot
  subnet_id       = each.value.public ? module.gcp_a_network.public_subnet_id : module.gcp_a_network.private_subnet_id
  public          = each.value.public
  service_account = google_service_account.gcp_a.email
  labels = {
    project = var.project_name
    cloud   = "gcp-a"
    role    = each.value.role
  }
  user_data = templatefile("${path.module}/cloud-init/tailscale.yaml.tftpl", {
    project_name      = var.project_name
    hostname          = each.value.hostname
    cloud_tag         = local.gcp_a_cloud_tag
    role_tag          = each.value.role
    tailscale_authkey = module.tailscale.auth_keys["gcp-a"]
    ssh_pubkey        = var.local_ct_ssh_pubkey
  })
}

# =============================================================================
# 4. GCP-B — analitica + servicio (MySQL + HBase + ES + Grafana)
# =============================================================================

module "gcp_b_network" {
  source       = "./modules/gcp-network"
  providers    = { google = google.gcp_b }
  name_prefix  = "${var.project_name}-b"
  region       = var.gcp_b_region
  public_cidr  = var.gcp_b_public_cidr
  private_cidr = var.gcp_b_private_cidr
}

resource "google_service_account" "gcp_b" {
  provider     = google.gcp_b
  account_id   = "${var.project_name}-b-vm"
  display_name = "WebHardMon GCP-B VMs"
}

module "gcp_b_registry" {
  source      = "./modules/gcp-registry"
  providers   = { google = google.gcp_b }
  name_prefix = "${var.project_name}-b"
  location    = var.gcp_b_region
  project_id  = var.gcp_b_project_id
}

locals {
  gcp_b_cloud_tag = "gcp_b"
  gcp_b_specs = concat(
    [for i in range(var.topology.mysql) : { role = "mysql", idx = i + 1, public = true }],
    [for i in range(var.topology.hbase) : { role = "hbase", idx = i + 1, public = false }],
    [for i in range(var.topology.elasticsearch) : { role = "elasticsearch", idx = i + 1, public = false }],
    [for i in range(var.topology.grafana) : { role = "grafana", idx = i + 1, public = true }],
  )
  gcp_b_vms = {
    for s in local.gcp_b_specs :
    format("%s-%02d", s.role, s.idx) => merge(s, {
      hostname = format("%s-%s-%02d", var.project_name, s.role, s.idx)
    })
  }
}

module "gcp_b_vm" {
  source    = "./modules/gcp-vm"
  providers = { google = google.gcp_b }
  for_each  = local.gcp_b_vms

  name            = each.value.hostname
  zone            = var.gcp_b_zone
  machine_type    = var.gcp_default_machine_type
  spot            = var.gcp_spot
  subnet_id       = each.value.public ? module.gcp_b_network.public_subnet_id : module.gcp_b_network.private_subnet_id
  public          = each.value.public
  service_account = google_service_account.gcp_b.email
  labels = {
    project = var.project_name
    cloud   = "gcp-b"
    role    = each.value.role
  }
  user_data = templatefile("${path.module}/cloud-init/tailscale.yaml.tftpl", {
    project_name      = var.project_name
    hostname          = each.value.hostname
    cloud_tag         = local.gcp_b_cloud_tag
    role_tag          = each.value.role
    tailscale_authkey = module.tailscale.auth_keys["gcp-b"]
    ssh_pubkey        = var.local_ct_ssh_pubkey
  })
}
