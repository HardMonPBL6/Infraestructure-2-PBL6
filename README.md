# WebHardMon — Infraestructura (OpenTofu)

Provisiona la infraestructura de WebHardMon repartida en **tres nubes** unidas por **Tailscale**:

| Nube | Plataforma | Subred pública (vmbr1 / public) | Subred privada (vmbr2 / private) |
|---|---|---|---|
| `local` | Proxmox VE (LXC) | `nifi`, `harbor` | `hdfs ×3`, `mapreduce` |
| `gcp-a` | GCE (`europe-southwest1`) | `node-01`: kafka+zookeeper+cassandra | `node-02`/`node-03`: kafka+zookeeper+cassandra+java |
| `gcp-b` | GCE (`europe-west1`)     | `node-01`: hbase+grafana | `node-02`: hbase+mysql · `node-03`: hbase+elasticsearch |

> **Coste GCP — 3 VMs spot compartidas por nube.** En vez de una VM por nodo de cluster (17 VMs on-demand), cada nube GCP usa **3 `e2-standard-4` Spot** (`gcp_spot=true`, `DELETE` al interrumpirse) que co-alojan servicios como contenedores, manteniendo una instancia de cada servicio por VM (clusters de 3 nodos sobre 3 hosts). Reparto en `var.gcp_a_nodes` / `var.gcp_b_nodes`. Spot+DELETE borra el disco al ser interrumpida → los despliegues Ansible deben ser idempotentes. La nube local no cambia.

Conexión entre nubes: tailnet WireGuard gestionado (`tailscale/tailscale` provider). SSH **solo** por tailnet, ACLs por tag.

**Patrón de unión al tailnet — asimétrico a propósito:**
- **GCP-A / GCP-B**: cada VM se une **directamente** al tailnet via cloud-init. Mesh entre VMs → conexiones UDP directas, sin SPOF, ACL granular por tag.
- **local**: los CTs **no** ejecutan Tailscale. El portátil del operador actúa como **subnet router** anunciando `10.10.2.0/24` y `10.10.3.0/24` al tailnet, así que los CTs son alcanzables desde cualquier nodo del tailnet con su IP LAN sin instalar nada dentro. Tiene sentido aquí porque el portátil ya está apagado cuando no se trabaja con la nube local; aplicar el mismo patrón en GCP sería SPOF + cuello de botella crypto + ACL pobre.

**Ingesta externa — Cloudflare Tunnel:** el *collector* corre en **PCs de usuario fuera de las tres nubes**, así que no llega por el tailnet (no es miembro) ni por la LAN (detrás de NAT doméstico). `cloudflared` corre en el CT de NiFi y marca **saliente** al edge de Cloudflare, publicando `ingest.<zona>` sin abrir puertos; **Cloudflare Access** (service token) autentica a los collectors. Tailscale no cambia: sigue siendo la malla entre nubes + SSH admin. Se desactiva con `cloudflare_enabled = false`.

**Frontera**: este repo es solo infra (redes, VMs/CTs, registros, identidades, alta en Tailscale, plano de control del túnel Cloudflare). La instalación y configuración de Kafka, HDFS, NiFi, `cloudflared`, etc. la hace Ansible — se genera el inventario al final.

## Estructura

```
.
├── versions.tf · providers.tf · backend.tf · variables.tf · main.tf · outputs.tf
├── terraform.tfvars.example
├── cloud-init/
│   ├── tailscale.yaml.tftpl          # user-data para VMs GCP
│   └── lxc-tailscale-hook.sh.tftpl   # hookscript post-start para CTs LXC
├── modules/
│   ├── tailscale/         # auth keys por nube + ACL del tailnet
│   ├── proxmox-lxc/       # CT unprivileged + nesting + tun passthrough
│   ├── gcp-network/       # VPC + 2 subnets + Cloud NAT + firewall
│   ├── gcp-vm/            # GCE Ubuntu 24.04 + cloud-init
│   ├── gcp-registry/      # Artifact Registry (Docker)
│   └── cloudflare-tunnel/ # Tunnel + DNS + Access para ingesta externa
├── ansible/
│   ├── inventory.tmpl     # plantilla del inventario
│   └── inventory.ini      # GENERADO por TF (gitignored)
└── bootstrap/             # ver más abajo
```

## Decisiones de diseño

- **Tres nubes** = `local` + `gcp-a` + `gcp-b`. Los dos GCP cuentan como nubes separadas porque se comunican por **IP pública** (criterio del profesor); el cifrado lo aporta Tailscale.
- **LXC en lugar de VMs en Proxmox** (decisión del operador). Los CTs son *unprivileged* con `nesting=1`. No instalan Tailscale — se accede vía el subnet router del portátil.
- **Hookscript en vez de cloud-init para LXC**: la API de Proxmox para contenedores no acepta `user-data` arbitrario, así que el provisioning inicial (usuario `ubuntu`, claves SSH, hardening básico) va en un snippet `post-start` (`cloud-init/lxc-bootstrap.sh.tftpl`).
- **IP estática determinista por CT** (`<cidr_base>.<vmid>`): así el inventario Ansible no depende de DHCP y los hostnames pueden añadirse a `/etc/hosts` si se quiere.
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

### 3) Tailscale — OAuth client + subnet router en el portátil
En <https://login.tailscale.com/admin/settings/oauth> crea un OAuth client con scopes:
- `auth_keys` (write)
- `acl` (write) — sin esto no podemos publicar la ACL

Guarda `client_id` y `client_secret`.

**Subnet router en el portátil** (una sola vez, fuera de OpenTofu):
```bash
sudo tailscale up --advertise-routes=10.10.2.0/24,10.10.3.0/24 --accept-routes
```
Y en el admin de Tailscale aprueba las rutas anunciadas. A partir de ahí cualquier nodo del tailnet alcanza los CTs por su IP LAN.

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

# 4. Planificacion (NO aplicar todavia segun el enunciado)
tofu plan
```

Cuando estés listo para aplicar:
```powershell
tofu apply
```

Tras el apply:
- `ansible/inventory.ini` queda generado con los hostnames de Tailscale agrupados por rol y nube.
- Los CTs/VMs se han registrado en el tailnet con tags `tag:webhardmon`, `tag:<nube>`, `tag:<rol>`.
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
| `tailscale_oauth_client_id` | OAuth client del paso 3 |
| `tailscale_oauth_client_secret` | OAuth secret del paso 3 |

Requeridas **si** `cloudflare_enabled = true` (default): `cloudflare_api_token`, `cloudflare_account_id`, `cloudflare_zone_id`, `cloudflare_zone_name` (paso 4).

Opcionales con default razonable: regiones/zonas GCP, CIDRs, plantilla LXC, `proxmox_nodes`, tamaños por defecto de CT/VM, topología local (`var.topology`), reparto y coste de los nodos GCP (`var.gcp_a_nodes`, `var.gcp_b_nodes`, `var.gcp_spot`, `var.gcp_spot_termination_action`, `var.gcp_default_machine_type`, `var.gcp_node_disk_gb`).

## Lo que NO hace este repo

- No instala/configura Kafka, HDFS, NiFi, Cassandra, HBase, MySQL, Java/RMI, Elasticsearch, Grafana, Harbor — eso es Ansible.
- No abre SSH a Internet. Cualquier acceso administrativo va por tailnet con tag `mgmt`.
- No ejecuta `tofu apply` automáticamente — el enunciado pide solo generar código + `fmt` + `validate`.
