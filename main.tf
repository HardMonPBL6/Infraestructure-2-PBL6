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

# Plantilla Ubuntu 24.04 — descarga si no existe. El storage `local` es por-nodo,
# y los CTs se reparten round-robin entre var.proxmox_nodes, así que la plantilla
# debe existir en CADA nodo, no solo en el primero.
resource "proxmox_download_file" "ubuntu_lxc" {
  for_each = toset(var.proxmox_nodes)

  content_type = "vztmpl"
  datastore_id = var.proxmox_datastore_template
  node_name    = each.value
  url          = "http://download.proxmox.com/images/system/${var.proxmox_ct_template}"
  file_name    = var.proxmox_ct_template
  overwrite    = false
}

# Reparto de CTs por rol -> lista plana usada para los CTs y para el inventario.
locals {
  local_cloud_tag = "local"

  # WireGuard: IPs fijas dentro de wg_vpn_cidr (10.0.0.0/24 por defecto)
  wg_vpn_prefix  = split("/", var.wg_vpn_cidr)[1]
  wg_mgmt_ip     = cidrhost(var.wg_vpn_cidr, 1)  # nodo de gestion
  wg_local_gw_ip = cidrhost(var.wg_vpn_cidr, 10) # gateway local
  wg_gcp_a_gw_ip = cidrhost(var.wg_vpn_cidr, 20) # gateway GCP-A
  wg_gcp_b_gw_ip = cidrhost(var.wg_vpn_cidr, 30) # gateway GCP-B

  # IPs internas estaticas de los gateways (para routing de nodos privados)
  gcp_a_gateway_internal_ip = cidrhost(var.gcp_a_public_cidr, 10)
  gcp_b_gateway_internal_ip = cidrhost(var.gcp_b_public_cidr, 10)

  # Origenes permitidos en el firewall de servicios GCP (allow_wg_vpn): la malla
  # WireGuard mas las IPs reales de la nube local y de la otra nube GCP, ya que el
  # trafico inter-nube cruza el tunel SIN NAT (malla enrutada plana).
  wg_service_source_ranges = [
    var.wg_vpn_cidr,
    var.local_supernet_cidr,
    var.gcp_a_public_cidr, var.gcp_a_private_cidr,
    var.gcp_b_public_cidr, var.gcp_b_private_cidr,
  ]

  # CTs genericos round-robin (HDFS y MapReduce se gestionan aparte, ver mas abajo).
  # Cada entrada: { role, idx, public, cores?, memory?, disk_gb? }
  local_ct_specs = concat(
    [for i in range(var.topology.nifi) : {
      role  = "nifi", idx = i + 1, public = true,
      cores = null, memory = null, disk_gb = null
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

  # HDFS: 1 CT por host PVE en la LAN de gestion (IP/nodo fijos, ver var.hdfs_nodes).
  # El NameNode lleva el rol hdfs_namenode; los DataNodes, hdfs_datanode. Estos
  # grupos los consume Ansible (roles/hdfs ramifica por grupo).
  hdfs_cts = {
    for n in var.hdfs_nodes :
    n.name => merge(n, {
      hostname = "${var.project_name}-${n.name}"
      roles    = n.kind == "namenode" ? ["hdfs", "hdfs_namenode"] : ["hdfs", "hdfs_datanode"]
      cores    = 2
      memory   = 4096
      disk_gb  = 32
    })
  }

  # MapReduce: CT dedicado a la capa batch en la LAN de gestion (ver
  # var.mapreduce_node). Solo lleva el rol [mapreduce]; Ansible (roles/mapreduce)
  # despliega ahi el contenedor efimero del job. Mismo formato que hdfs_cts para
  # reutilizar el modulo proxmox-lxc y el bootstrap por SSH+pct.
  mapreduce_cts = {
    (var.mapreduce_node.name) = merge(var.mapreduce_node, {
      hostname = "${var.project_name}-${var.mapreduce_node.name}"
      roles    = ["mapreduce"]
      cores    = 2
      memory   = 4096
      disk_gb  = 24
    })
  }
}

module "local_ct" {
  source   = "./modules/proxmox-lxc"
  for_each = local.local_cts

  vmid             = each.value.vmid
  hostname         = each.value.hostname
  node_name        = each.value.node
  template_file_id = proxmox_download_file.ubuntu_lxc[each.value.node].id
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

  tags = [var.project_name, local.local_cloud_tag, each.value.role]
}

# Bootstrap de cada CT (sustituye al antiguo hookscript de Proxmox, que exigia
# root@pam). Terraform entra por SSH al nodo PVE que aloja el CT —con la misma
# clave que el provider— y ejecuta el script DENTRO del CT via `pct exec`. Esto
# no requiere root@pam (el API sigue usando el token): `pct exec` es local al
# nodo. Idempotente; se re-ejecuta si cambia el CT o el script.
resource "null_resource" "lxc_bootstrap" {
  for_each = local.local_cts

  triggers = {
    container = module.local_ct[each.key].id
    script = sha1(templatefile("${path.module}/cloud-init/lxc-bootstrap.sh.tftpl", {
      ssh_pubkey = var.local_ct_ssh_pubkey
    }))
  }

  connection {
    type        = "ssh"
    host        = var.proxmox_node_ssh_hosts[each.value.node]
    user        = var.proxmox_ssh_user
    private_key = var.proxmox_ssh_private_key
  }

  # Sube el script al nodo y lo inyecta en el CT por stdin de `pct exec`.
  provisioner "file" {
    content = templatefile("${path.module}/cloud-init/lxc-bootstrap.sh.tftpl", {
      ssh_pubkey = var.local_ct_ssh_pubkey
    })
    destination = "/tmp/wh-bootstrap-${each.value.vmid}.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "pct start ${each.value.vmid} >/dev/null 2>&1 || true",
      "for i in $(seq 1 60); do pct status ${each.value.vmid} | grep -q running && break; sleep 1; done",
      "pct exec ${each.value.vmid} -- bash -se < /tmp/wh-bootstrap-${each.value.vmid}.sh",
      "rm -f /tmp/wh-bootstrap-${each.value.vmid}.sh",
    ]
  }
}

# ---- HDFS: 3 CTs (host Docker) en la LAN de gestion, 1 por nodo PVE ---------
# Reutiliza el mismo modulo proxmox-lxc en su modo "publico" (1 NIC + gateway),
# pero apuntando al bridge de gestion (vmbr0 / 10.10.1.1). HDFS en si lo despliega
# Ansible como contenedores Docker (roles/hdfs). El NameNode queda en 10.10.1.21.
module "hdfs_ct" {
  source   = "./modules/proxmox-lxc"
  for_each = local.hdfs_cts

  vmid             = each.value.vmid
  hostname         = each.value.hostname
  node_name        = each.value.proxmox_node
  template_file_id = proxmox_download_file.ubuntu_lxc[each.value.proxmox_node].id
  datastore_disk   = var.proxmox_datastore_disk
  cores            = each.value.cores
  memory           = each.value.memory
  swap             = var.lxc_default_resources.swap
  disk_gb          = each.value.disk_gb

  public_bridge     = var.local_mgmt_bridge
  private_bridge    = var.local_private_bridge
  public_gateway    = var.local_mgmt_gateway
  in_private_subnet = false
  primary_ip_cidr   = "${each.value.ip}/24"

  tags = [var.project_name, local.local_cloud_tag, "hdfs"]
}

# Mismo bootstrap por SSH+pct que los CTs genericos (crea ubuntu, instala python3
# para Ansible, endurece SSH). Docker lo instala despues Ansible (roles/docker).
resource "null_resource" "hdfs_bootstrap" {
  for_each = local.hdfs_cts

  triggers = {
    container = module.hdfs_ct[each.key].id
    script = sha1(templatefile("${path.module}/cloud-init/lxc-bootstrap.sh.tftpl", {
      ssh_pubkey = var.local_ct_ssh_pubkey
    }))
  }

  connection {
    type        = "ssh"
    host        = var.proxmox_node_ssh_hosts[each.value.proxmox_node]
    user        = var.proxmox_ssh_user
    private_key = var.proxmox_ssh_private_key
  }

  provisioner "file" {
    content = templatefile("${path.module}/cloud-init/lxc-bootstrap.sh.tftpl", {
      ssh_pubkey = var.local_ct_ssh_pubkey
    })
    destination = "/tmp/wh-bootstrap-${each.value.vmid}.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "pct start ${each.value.vmid} >/dev/null 2>&1 || true",
      "for i in $(seq 1 60); do pct status ${each.value.vmid} | grep -q running && break; sleep 1; done",
      "pct exec ${each.value.vmid} -- bash -se < /tmp/wh-bootstrap-${each.value.vmid}.sh",
      "rm -f /tmp/wh-bootstrap-${each.value.vmid}.sh",
    ]
  }
}

# ---- MapReduce: CT dedicado (host Docker) en la LAN de gestion --------------
# Mismo patron que hdfs_ct (modulo proxmox-lxc en modo "publico" sobre vmbr0 /
# 10.10.1.x). El job batch lo despliega Ansible (roles/mapreduce) como contenedor
# efimero. Vive junto a HDFS para minimizar latencia de lectura de los Parquet.
module "mapreduce_ct" {
  source   = "./modules/proxmox-lxc"
  for_each = local.mapreduce_cts

  vmid             = each.value.vmid
  hostname         = each.value.hostname
  node_name        = each.value.proxmox_node
  template_file_id = proxmox_download_file.ubuntu_lxc[each.value.proxmox_node].id
  datastore_disk   = var.proxmox_datastore_disk
  cores            = each.value.cores
  memory           = each.value.memory
  swap             = var.lxc_default_resources.swap
  disk_gb          = each.value.disk_gb

  public_bridge     = var.local_mgmt_bridge
  private_bridge    = var.local_private_bridge
  public_gateway    = var.local_mgmt_gateway
  in_private_subnet = false
  primary_ip_cidr   = "${each.value.ip}/24"

  tags = [var.project_name, local.local_cloud_tag, "mapreduce"]
}

# Mismo bootstrap por SSH+pct que el resto de CTs (crea ubuntu, instala python3
# para Ansible, endurece SSH). Docker lo instala despues Ansible (roles/docker).
resource "null_resource" "mapreduce_bootstrap" {
  for_each = local.mapreduce_cts

  triggers = {
    container = module.mapreduce_ct[each.key].id
    script = sha1(templatefile("${path.module}/cloud-init/lxc-bootstrap.sh.tftpl", {
      ssh_pubkey = var.local_ct_ssh_pubkey
    }))
  }

  connection {
    type        = "ssh"
    host        = var.proxmox_node_ssh_hosts[each.value.proxmox_node]
    user        = var.proxmox_ssh_user
    private_key = var.proxmox_ssh_private_key
  }

  provisioner "file" {
    content = templatefile("${path.module}/cloud-init/lxc-bootstrap.sh.tftpl", {
      ssh_pubkey = var.local_ct_ssh_pubkey
    })
    destination = "/tmp/wh-bootstrap-${each.value.vmid}.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "pct start ${each.value.vmid} >/dev/null 2>&1 || true",
      "for i in $(seq 1 60); do pct status ${each.value.vmid} | grep -q running && break; sleep 1; done",
      "pct exec ${each.value.vmid} -- bash -se < /tmp/wh-bootstrap-${each.value.vmid}.sh",
      "rm -f /tmp/wh-bootstrap-${each.value.vmid}.sh",
    ]
  }
}

# ---- Cloudflare Tunnel: ingesta externa hacia NiFi --------------------------
# El collector (en PCs de usuario, fuera de la malla WireGuard y detras de NAT) entra por
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

# ---- Harbor TLS: registro DNS para el registro de contenedores local --------
# Registro A *DNS-only* (grey cloud) harbor.<zona> -> IP LAN del CT Harbor. No
# se proxea (Cloudflare no alcanza un origen privado) ni se expone a Internet:
# solo resuelve el nombre para clientes de la LAN/malla. El cert TLS lo emite
# Let's Encrypt por DNS-01 (Ansible roles/harbor), de modo que Docker confia en
# Harbor sin CA extra ni insecure-registries. La IP se deriva del CT real para
# que no diverja de la topologia (harbor-01 en la subred publica local).
resource "cloudflare_record" "harbor" {
  count = var.cloudflare_enabled && contains(keys(local.local_cts), "harbor-01") ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = var.cloudflare_harbor_subdomain
  content = local.local_cts["harbor-01"].ip
  type    = "A"
  proxied = false
  comment = "WebHardMon Harbor registry (DNS-only, LAN IP; TLS via LE DNS-01)"
}

# =============================================================================
# 3. GCP-A — streaming (Kafka + Java/RMI + Cassandra)
# =============================================================================

module "gcp_a_network" {
  source                   = "./modules/gcp-network"
  providers                = { google = google.gcp_a }
  name_prefix              = "${var.project_name}-a"
  region                   = var.gcp_a_region
  public_cidr              = var.gcp_a_public_cidr
  private_cidr             = var.gcp_a_private_cidr
  wg_service_source_ranges = local.wg_service_source_ranges
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
      var.local_supernet_cidr,
      var.gcp_b_public_cidr, var.gcp_b_private_cidr,
    ]
    wg_peers = each.value.is_gateway ? [
      {
        name        = "management"
        public_key  = var.wg_mgmt_public_key
        endpoint    = var.wg_mgmt_endpoint
        allowed_ips = ["${local.wg_mgmt_ip}/32"]
      },
      {
        name        = "local-gateway"
        public_key  = var.wg_local_gw_public_key
        endpoint    = var.wg_local_gw_endpoint
        allowed_ips = ["${local.wg_local_gw_ip}/32", var.local_supernet_cidr]
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
  source                   = "./modules/gcp-network"
  providers                = { google = google.gcp_b }
  name_prefix              = "${var.project_name}-b"
  region                   = var.gcp_b_region
  public_cidr              = var.gcp_b_public_cidr
  private_cidr             = var.gcp_b_private_cidr
  wg_service_source_ranges = local.wg_service_source_ranges
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
      var.local_supernet_cidr,
      var.gcp_a_public_cidr, var.gcp_a_private_cidr,
    ]
    wg_peers = each.value.is_gateway ? [
      {
        name        = "management"
        public_key  = var.wg_mgmt_public_key
        endpoint    = var.wg_mgmt_endpoint
        allowed_ips = ["${local.wg_mgmt_ip}/32"]
      },
      {
        name        = "local-gateway"
        public_key  = var.wg_local_gw_public_key
        endpoint    = var.wg_local_gw_endpoint
        allowed_ips = ["${local.wg_local_gw_ip}/32", var.local_supernet_cidr]
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
