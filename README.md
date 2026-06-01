# WebHardMon — Infraestructura (OpenTofu)

Provisiona la infraestructura de WebHardMon repartida en **tres nubes** unidas por una **malla WireGuard**:

| Nube | Plataforma | Subred pública (vmbr1 / public) | Subred privada (vmbr2 / private) |
|---|---|---|---|
| `local` | Proxmox VE (LXC) | `nifi`, `harbor` | `hdfs ×3`, `mapreduce` |
| `gcp-a` | GCE (`europe-southwest1`) | `node-01`: kafka+zookeeper+cassandra+schema_registry | `node-02`/`node-03`: kafka+zookeeper+cassandra+java |
| `gcp-b` | GCE (`europe-west1`)     | `node-01`: hbase+grafana | `node-02`: hbase+mysql · `node-03`: hbase+elasticsearch |

> **Coste GCP — 3 VMs spot compartidas por nube.** En vez de una VM por nodo de cluster (17 VMs on-demand), cada nube GCP usa **3 `e2-standard-4` Spot** (`gcp_spot=true`, `DELETE` al interrumpirse) que co-alojan servicios como contenedores, manteniendo una instancia de cada servicio por VM (clusters de 3 nodos sobre 3 hosts). Reparto en `var.gcp_a_nodes` / `var.gcp_b_nodes`. Spot+DELETE borra el disco al ser interrumpida → los despliegues Ansible deben ser idempotentes y los datos reconstruibles. La nube local no cambia (un LXC por nodo).

## Red entre nubes — WireGuard

Conexión entre nubes: **malla WireGuard**, un gateway por nube. SSH administrativo y todo el tráfico inter-nube viajan cifrados por la VPN.

| Gateway | IP VPN WireGuard | IP interna GCP | IP externa |
|---|---|---|---|
| Gestión (portátil) | `10.0.0.1` | — | dinámica / DDNS |
| Gateway local | `10.0.0.10` | — | configurada a mano |
| GCP-A node-01 | `10.0.0.20` | `10.20.1.10` | estática (`google_compute_address`) |
| GCP-B node-01 | `10.0.0.30` | `10.30.1.10` | estática (`google_compute_address`) |

**Patrón asimétrico — un gateway por nube:**
- **GCP-A / GCP-B**: solo el `node-01` público de cada nube ejecuta WireGuard (gateway). Los nodos privados (`node-02`/`03`) **no** levantan WireGuard — reciben un servicio systemd one-shot que añade rutas estáticas hacia las otras nubes a través de su gateway. Ansible los alcanza por su IP interna GCP (`10.20.2.11`, etc.) enrutada por el gateway.
- **local**: los CTs tampoco ejecutan WireGuard. El gateway local (`10.0.0.10`, gestionado a mano fuera de OpenTofu) anuncia las subredes `10.10.2.0/24` y `10.10.3.0/24` a la malla, así que los CTs son alcanzables por su IP LAN sin instalar nada dentro.

Las **IPs externas estáticas** de los gateways GCP se reservan con `google_compute_address` para que las configs de peers WireGuard sobrevivan a la recreación de las VMs spot. Tras `tofu apply`, ejecuta `tofu output wireguard_gateway_ips` para obtener las IPs que necesitas al configurar a mano el gateway local y el nodo de gestión.

**Claves WireGuard** — se generan a mano y se guardan en `terraform.tfvars` (gitignored). Las privadas de los gateways GCP se inyectan en `wg0.conf` vía `cloud-init/wireguard.yaml.tftpl` en la creación de la VM; el nodo de gestión y el gateway local se configuran a mano con sus propias privadas + las IPs estáticas del output.

```bash
wg genkey | tee gcp-a-private.key | wg pubkey > gcp-a-public.key
wg genkey | tee gcp-b-private.key | wg pubkey > gcp-b-public.key
wg genkey | tee mgmt-private.key  | wg pubkey > mgmt-public.key
wg genkey | tee local-gw-private.key | wg pubkey > local-gw-public.key
```

**Ingesta externa — Cloudflare Tunnel:** el *collector* corre en **PCs de usuario fuera de las tres nubes**, así que no llega por WireGuard (no es peer) ni por la LAN (detrás de NAT doméstico). `cloudflared` corre en el CT de NiFi y marca **saliente** al edge de Cloudflare, publicando `ingest.<zona>` sin abrir puertos ni NAT; **Cloudflare Access** (service token) autentica a los collectors. WireGuard solo lleva la malla inter-nube + SSH admin; Cloudflare Tunnel solo lleva externo→ingesta. Se desactiva con `cloudflare_enabled = false`.

**Frontera**: este repo es solo infra (redes, VMs/CTs, registros, identidades, config WireGuard, plano de control del túnel Cloudflare). La instalación y configuración de Kafka, HDFS, NiFi, `cloudflared`, etc. la hace Ansible — se genera el inventario al final.

## Estructura

```
.
├── versions.tf · providers.tf · backend.tf · variables.tf · main.tf · outputs.tf
├── terraform.tfvars.example
├── cloud-init/
│   ├── wireguard.yaml.tftpl          # user-data para VMs GCP (gateway o rutas)
│   └── lxc-bootstrap.sh.tftpl        # hookscript post-start para CTs LXC
├── modules/
│   ├── proxmox-lxc/       # CT unprivileged + nesting + dual-NIC + hookscript
│   ├── gcp-network/       # VPC + 2 subnets + Cloud Router + Cloud NAT + firewall
│   ├── gcp-vm/            # GCE Ubuntu 24.04 shielded + IP interna estática + cloud-init
│   ├── gcp-registry/      # Artifact Registry (Docker)
│   └── cloudflare-tunnel/ # Tunnel + DNS + Access para ingesta externa
├── ansible/
│   ├── inventory.tmpl     # plantilla del inventario
│   ├── inventory.ini      # GENERADO por TF (gitignored)
│   └── group_vars/        # config por servicio, fusionada por nodo compartido
├── docker/                # Dockerfiles + build-and-push.sh (imágenes, no infra)
└── bootstrap/             # ver más abajo
```

## Decisiones de diseño

- **Tres nubes** = `local` + `gcp-a` + `gcp-b`. Los dos GCP cuentan como nubes separadas porque se comunican por **IP pública** (criterio del profesor); el cifrado lo aporta WireGuard.
- **Un gateway WireGuard por nube** en vez de unir cada VM a la malla: menos superficie, peers estables (IP estática), y los nodos privados salen por Cloud NAT sin IP pública. Los `node-02/03` solo necesitan rutas systemd hacia el gateway.
- **LXC en lugar de VMs en Proxmox** (decisión del operador). Los CTs son *unprivileged* con `nesting=1`. No instalan WireGuard — se alcanzan vía el gateway local que anuncia sus subredes.
- **Hookscript en vez de cloud-init para LXC**: la API de Proxmox para contenedores no acepta `user-data` arbitrario, así que el provisioning inicial (usuario `ubuntu`, claves SSH, hardening básico) va en un snippet `post-start` (`cloud-init/lxc-bootstrap.sh.tftpl`).
- **IP estática determinista por nodo**: CTs en `<cidr_base>.<vmid>`; VMs GCP con IP interna estática en offset +10 de la base de subred (`10.20.1.10`, `10.20.2.11`, …). Así el inventario Ansible no depende de DHCP y los ids de cluster son estables tras una preempción spot.
- **`ignore_changes` en el user-data de las VMs GCP**: cambiar la config WireGuard **no** recrea la VM — se actualiza re-ejecutando cloud-init o por SSH.
- **Subred privada local**: `vmbr2` no tiene gateway → los CTs privados llevan **2 NICs**: la principal en `vmbr2` (cluster, sin gw) y una secundaria DHCP en `vmbr1` solo para egress (apt).
- **Reparto RGI320**: los CTs se distribuyen *round-robin* entre `pve-local` y `pve-local2` (variable `proxmox_nodes`).
- **State**: backend local por defecto (un único nodo de gestión). En `backend.tf` se deja preparado un bloque GCS comentado para conmutar cuando interese.
- **Sin secretos en el código**: todos por `variable` con `sensitive = true`, leídos de `terraform.tfvars` (en `.gitignore`) o de variables de entorno.

## Bootstrap — qué necesitas antes del primer `tofu init`

### 1) Proxmox — token de API
```bash
ssh root@10.10.1.15
pveum user add tofu@pve
pveum aclmod / -user tofu@pve -role Administrator     # ajusta a tu gusto
pveum user token add tofu@pve webhardmon --privsep=0
# Copia el UUID que imprime. El token completo es: tofu@pve!webhardmon=<uuid>
```
Y una clave SSH para que el provider pueda subir snippets:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/proxmox_tofu -N ""
ssh-copy-id -i ~/.ssh/proxmox_tofu.pub root@10.10.1.15
```

### 2) GCP — dos proyectos + service accounts
Por cada proyecto (A y B):
```bash
gcloud projects create webhardmon-a-XXXXX
gcloud config set project webhardmon-a-XXXXX
gcloud services enable compute.googleapis.com artifactregistry.googleapis.com iam.googleapis.com
gcloud iam service-accounts create tofu --display-name "OpenTofu"
gcloud projects add-iam-policy-binding webhardmon-a-XXXXX \
   --member="serviceAccount:tofu@webhardmon-a-XXXXX.iam.gserviceaccount.com" \
   --role="roles/editor"
gcloud iam service-accounts keys create ~/.gcp/webhardmon-a.json \
   --iam-account=tofu@webhardmon-a-XXXXX.iam.gserviceaccount.com
```

### 3) WireGuard — keypairs + gateways externos
Genera los cuatro keypairs (ver comandos arriba) y rellena en `terraform.tfvars`:
- `wg_gcp_a_private_key` / `wg_gcp_a_public_key`, `wg_gcp_b_private_key` / `wg_gcp_b_public_key` (gateways GCP),
- `wg_mgmt_public_key` (portátil de gestión), `wg_local_gw_public_key` (gateway local).

Los gateways GCP los configura OpenTofu vía cloud-init. El **nodo de gestión** y el **gateway local** se configuran a mano: tras `tofu apply` obtén sus endpoints con
```powershell
tofu output wireguard_gateway_ips
```
y crea sus `wg0.conf` apuntando a esas IPs estáticas (puerto `var.wg_port`, por defecto `51820`). El gateway local debe además anunciar/enrutar `10.10.2.0/24` y `10.10.3.0/24` para que los CTs sean alcanzables.

### 4) Cloudflare — túnel de ingesta externa
1. Ten un dominio cuyas NS apunten a Cloudflare (zona activa).
2. Crea un **API token** (My Profile → API Tokens → Create Token, custom):
   - `Account` → `Cloudflare Tunnel`: Edit
   - `Account` → `Access: Apps and Policies`: Edit
   - `Zone` → `DNS`: Edit (sobre la zona del dominio)
3. Anota `Account ID` y `Zone ID` (panel de la zona, columna derecha).

Rellena `cloudflare_*` en `terraform.tfvars`. Tras `tofu apply`:
```powershell
tofu output -raw cloudflared_tunnel_token        # -> Ansible lo pasa a cloudflared
tofu output -raw collector_access_client_id       # -> instalador del collector
tofu output -raw collector_access_client_secret
```
Para omitirlo por completo: `cloudflare_enabled = false`.

### 5) Backend GCS (opcional)
Solo si quieres state remoto:
```bash
gsutil mb -p webhardmon-a-XXXXX -l EU gs://webhardmon-tofu-state
gsutil versioning set on gs://webhardmon-tofu-state
# Luego descomenta el bloque "backend gcs" en backend.tf y comenta el local.
```

## Uso

```powershell
# 1. Copia el ejemplo y rellena variables
Copy-Item terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars

# 2. Init (sin GCS: backend local)
tofu init

# 3. Validacion
tofu fmt -recursive
tofu validate

# 4. Planificacion
tofu plan
```

Cuando estés listo para aplicar:
```powershell
tofu apply
tofu output wireguard_gateway_ips   # IPs estáticas para configurar los peers externos
```

Tras el apply:
- `ansible/inventory.ini` queda generado, agrupado por rol y por nube. Cada nodo GCP compartido aparece en **varios** grupos `[rol]` a la vez; Ansible fusiona sus `group_vars` (ver `ansible/group_vars/README.md`).
- Los gateways GCP están en la malla WireGuard con IP estática; configura a mano el nodo de gestión y el gateway local con las IPs del output.
- Cada nube tiene su registro de contenedores listo: Harbor (sobre el CT `harbor-01`, lo instala Ansible) + 2× Artifact Registry.

## Variables que tienes que rellenar antes de `tofu plan`

Obligatorias (sin default):
| Variable | Qué es |
|---|---|
| `proxmox_api_token` | `tofu@pve!webhardmon=<uuid>` del paso 1 |
| `proxmox_ssh_private_key` | contenido PEM de `~/.ssh/proxmox_tofu` |
| `local_ct_ssh_pubkey` | clave pública que entra en los CTs/VMs |
| `gcp_a_project_id` | ID del proyecto GCP-A |
| `gcp_b_project_id` | ID del proyecto GCP-B |
| `wg_gcp_a_private_key` / `wg_gcp_a_public_key` | keypair del gateway WireGuard de GCP-A |
| `wg_gcp_b_private_key` / `wg_gcp_b_public_key` | keypair del gateway WireGuard de GCP-B |
| `wg_mgmt_public_key` | clave pública del nodo de gestión (portátil) |
| `wg_local_gw_public_key` | clave pública del gateway local |

Requeridas **si** `cloudflare_enabled = true` (default): `cloudflare_api_token`, `cloudflare_account_id`, `cloudflare_zone_id`, `cloudflare_zone_name` (paso 4).

Opcionales con default razonable: regiones/zonas GCP, CIDRs, `wg_port` / `wg_vpn_cidr` / endpoints WireGuard, plantilla LXC, `proxmox_nodes`, tamaños por defecto de CT/VM, topología local (`var.topology`), reparto y coste de los nodos GCP (`var.gcp_a_nodes`, `var.gcp_b_nodes`, `var.gcp_spot`, `var.gcp_spot_termination_action`, `var.gcp_default_machine_type`, `var.gcp_node_disk_gb`).

## Lo que NO hace este repo

- No instala/configura Kafka, HDFS, NiFi, Cassandra, HBase, MySQL, Java/RMI, Elasticsearch, Grafana, Harbor, Schema Registry, `cloudflared` — eso es Ansible.
- No abre SSH a Internet. Cualquier acceso administrativo va por la malla WireGuard.
- No configura el nodo de gestión ni el gateway local — esos peers WireGuard se montan a mano con las IPs de `tofu output wireguard_gateway_ips`.
