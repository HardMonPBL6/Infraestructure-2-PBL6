# =============================================================================
# WebHardMon — composicion de las tres nubes
# =============================================================================
# Orden:
#  1. WireGuard — IPs estaticas para los gateways GCP
#  2. Nube local: plantilla LXC + hookscripts + CTs por rol
#  3. GCP-A: red + service account + VMs + registry
#  4. GCP-B: red + service account + VMs + registry
# =============================================================================

# ---- 1. WireGuard — IPs estaticas para los gateways GCP --------------------
# Un gateway por nube (node-01 publico). Se reservan IPs estaticas para que la
# configuracion de peers WireGuard no cambie si la VM spot es recreada.

resource "google_compute_address" "gcp_a_gateway" {
  provider = google.gcp_a
  name     = "${var.project_name}-a-gw-wg"
  region   = var.gcp_a_region
}

resource "google_compute_address" "gcp_b_gateway" {
  provider = google.gcp_b
  name     = "${var.project_name}-b-gw-wg"
  region   = var.gcp_b_region
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

  # WireGuard: IPs fijas dentro de wg_vpn_cidr (10.0.0.0/24 por defecto)
  wg_vpn_prefix      = split("/", var.wg_vpn_cidr)[1]
  wg_mgmt_ip         = cidrhost(var.wg_vpn_cidr, 1)   # nodo de gestion
  wg_local_gw_ip     = cidrhost(var.wg_vpn_cidr, 10)  # gateway local
  wg_gcp_a_gw_ip     = cidrhost(var.wg_vpn_cidr, 20)  # gateway GCP-A
  wg_gcp_b_gw_ip     = cidrhost(var.wg_vpn_cidr, 30)  # gateway GCP-B

  # IPs internas estaticas de los gateways (para routing de nodos privados)
  gcp_a_gateway_internal_ip = cidrhost(var.gcp_a_public_cidr, 10)
  gcp_b_gateway_internal_ip = cidrhost(var.gcp_b_public_cidr, 10)

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

# ---- Cloudflare Tunnel: ingesta externa hacia NiFi --------------------------
# El collector (en PCs de usuario, fuera del tailnet y detras de NAT) entra por
# aqui. cloudflared corre en el CT de NiFi con el token que exporta el modulo.

module "cloudflare_tunnel" {
  source    = "./modules/cloudflare-tunnel"
  providers = { cloudflare = cloudflare }
  count     = var.cloudflare_enabled ? 1 : 0

  account_id       = var.cloudflare_account_id
  zone_id          = var.cloudflare_zone_id
  zone_name        = var.cloudflare_zone_name
  subdomain        = var.cloudflare_ingest_subdomain
  nifi_ingest_port = var.nifi_ingest_port
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
  source         = "./modules/gcp-registry"
  providers      = { google = google.gcp_a }
  name_prefix    = "${var.project_name}-a"
  location       = var.gcp_a_region
  project_id     = var.gcp_a_project_id
  reader_members = ["serviceAccount:${google_service_account.gcp_a.email}"]
}

locals {
  gcp_a_cloud_tag = "gcp_a"
  # 3 nodos compartidos: cada VM aloja una instancia de cada servicio de su lista
  # de roles (Kafka+ZK+Cassandra en los 3, Java en 2) -> cluster distribuido de
  # 3 nodos sobre 3 VMs spot en vez de 11 VMs on-demand.
  # network_ip: IP interna estatica (offset +10 en su subred para evitar las
  # reservadas por GCP en .0-.1 y el rango DHCP bajo). i+10 da .10, .11, .12.
  gcp_a_vms = {
    for i, n in var.gcp_a_nodes :
    format("node-%02d", i + 1) => {
      hostname   = format("%s-a-node-%02d", var.project_name, i + 1)
      roles      = n.roles
      public     = n.public
      is_gateway = n.public
      network_ip = n.public ? cidrhost(var.gcp_a_public_cidr, i + 10) : cidrhost(var.gcp_a_private_cidr, i + 10)
      wg_ip      = n.public ? "${local.wg_gcp_a_gw_ip}/${local.wg_vpn_prefix}" : null
    }
  }
}

module "gcp_a_vm" {
  source    = "./modules/gcp-vm"
  providers = { google = google.gcp_a }
  for_each  = local.gcp_a_vms

  name                    = each.value.hostname
  zone                    = var.gcp_a_zone
  machine_type            = var.gcp_default_machine_type
  spot                    = var.gcp_spot
  spot_termination_action = var.gcp_spot_termination_action
  disk_gb                 = var.gcp_node_disk_gb
  subnet_id               = each.value.public ? module.gcp_a_network.public_subnet_id : module.gcp_a_network.private_subnet_id
  public                  = each.value.public
  network_ip              = each.value.network_ip
  external_ip_address     = each.value.is_gateway ? google_compute_address.gcp_a_gateway.address : null
  service_account         = google_service_account.gcp_a.email
  labels = {
    project = var.project_name
    cloud   = "gcp-a"
    roles   = join("-", each.value.roles)
  }
  user_data = templatefile("${path.module}/cloud-init/wireguard.yaml.tftpl", {
    hostname       = each.value.hostname
    ssh_pubkey     = var.local_ct_ssh_pubkey
    is_gateway     = each.value.is_gateway
    wg_ip          = each.value.is_gateway ? each.value.wg_ip : ""
    wg_port        = var.wg_port
    wg_private_key = each.value.is_gateway ? var.wg_gcp_a_private_key : ""
    wg_gateway_ip  = local.gcp_a_gateway_internal_ip
    remote_cidrs = each.value.is_gateway ? [] : [
      var.wg_vpn_cidr,
      var.local_public_cidr, var.local_private_cidr,
      var.gcp_b_public_cidr, var.gcp_b_private_cidr,
    ]
    wg_peers = each.value.is_gateway ? [
      {
        name       = "management"
        public_key = var.wg_mgmt_public_key
        endpoint   = var.wg_mgmt_endpoint
        allowed_ips = ["${local.wg_mgmt_ip}/32"]
      },
      {
        name        = "local-gateway"
        public_key  = var.wg_local_gw_public_key
        endpoint    = var.wg_local_gw_endpoint
        allowed_ips = ["${local.wg_local_gw_ip}/32", var.local_public_cidr, var.local_private_cidr]
      },
      {
        name        = "gcp-b-gateway"
        public_key  = var.wg_gcp_b_public_key
        endpoint    = google_compute_address.gcp_b_gateway.address
        allowed_ips = ["${local.wg_gcp_b_gw_ip}/32", var.gcp_b_public_cidr, var.gcp_b_private_cidr]
      },
    ] : []
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
  source         = "./modules/gcp-registry"
  providers      = { google = google.gcp_b }
  name_prefix    = "${var.project_name}-b"
  location       = var.gcp_b_region
  project_id     = var.gcp_b_project_id
  reader_members = ["serviceAccount:${google_service_account.gcp_b.email}"]
}

locals {
  gcp_b_cloud_tag = "gcp_b"
  gcp_b_vms = {
    for i, n in var.gcp_b_nodes :
    format("node-%02d", i + 1) => {
      hostname   = format("%s-b-node-%02d", var.project_name, i + 1)
      roles      = n.roles
      public     = n.public
      is_gateway = n.public
      network_ip = n.public ? cidrhost(var.gcp_b_public_cidr, i + 10) : cidrhost(var.gcp_b_private_cidr, i + 10)
      wg_ip      = n.public ? "${local.wg_gcp_b_gw_ip}/${local.wg_vpn_prefix}" : null
    }
  }
}

module "gcp_b_vm" {
  source    = "./modules/gcp-vm"
  providers = { google = google.gcp_b }
  for_each  = local.gcp_b_vms

  name                    = each.value.hostname
  zone                    = var.gcp_b_zone
  machine_type            = var.gcp_default_machine_type
  spot                    = var.gcp_spot
  spot_termination_action = var.gcp_spot_termination_action
  disk_gb                 = var.gcp_node_disk_gb
  subnet_id               = each.value.public ? module.gcp_b_network.public_subnet_id : module.gcp_b_network.private_subnet_id
  public                  = each.value.public
  network_ip              = each.value.network_ip
  external_ip_address     = each.value.is_gateway ? google_compute_address.gcp_b_gateway.address : null
  service_account         = google_service_account.gcp_b.email
  labels = {
    project = var.project_name
    cloud   = "gcp-b"
    roles   = join("-", each.value.roles)
  }
  user_data = templatefile("${path.module}/cloud-init/wireguard.yaml.tftpl", {
    hostname       = each.value.hostname
    ssh_pubkey     = var.local_ct_ssh_pubkey
    is_gateway     = each.value.is_gateway
    wg_ip          = each.value.is_gateway ? each.value.wg_ip : ""
    wg_port        = var.wg_port
    wg_private_key = each.value.is_gateway ? var.wg_gcp_b_private_key : ""
    wg_gateway_ip  = local.gcp_b_gateway_internal_ip
    remote_cidrs = each.value.is_gateway ? [] : [
      var.wg_vpn_cidr,
      var.local_public_cidr, var.local_private_cidr,
      var.gcp_a_public_cidr, var.gcp_a_private_cidr,
    ]
    wg_peers = each.value.is_gateway ? [
      {
        name       = "management"
        public_key = var.wg_mgmt_public_key
        endpoint   = var.wg_mgmt_endpoint
        allowed_ips = ["${local.wg_mgmt_ip}/32"]
      },
      {
        name        = "local-gateway"
        public_key  = var.wg_local_gw_public_key
        endpoint    = var.wg_local_gw_endpoint
        allowed_ips = ["${local.wg_local_gw_ip}/32", var.local_public_cidr, var.local_private_cidr]
      },
      {
        name        = "gcp-a-gateway"
        public_key  = var.wg_gcp_a_public_key
        endpoint    = google_compute_address.gcp_a_gateway.address
        allowed_ips = ["${local.wg_gcp_a_gw_ip}/32", var.gcp_a_public_cidr, var.gcp_a_private_cidr]
      },
    ] : []
  })
}
