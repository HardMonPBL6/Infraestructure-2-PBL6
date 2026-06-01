# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

OpenTofu (Terraform-compatible) infrastructure-as-code for **WebHardMon** — a distributed big data platform spanning three cloud environments connected via a WireGuard VPN mesh:

| Cloud | Platform | Services |
|-------|----------|----------|
| `local` | Proxmox VE (LXC containers) | NiFi, HDFS ×3, MapReduce, Harbor |
| `gcp-a` | GCP europe-southwest1 | Kafka ×3, ZooKeeper ×3, Schema Registry, Java/RMI ×2, Cassandra ×3 |
| `gcp-b` | GCP europe-west1 | MySQL, HBase ×3, Elasticsearch, Grafana |

**GCP cost model — 3 shared spot VMs per cloud.** Each GCP cloud runs **3 `e2-standard-4` Spot VMs** (`gcp_spot = true`, `instance_termination_action = DELETE`) that co-locate services as containers, keeping one instance of each clustered service per node (real 3-node distributed cluster across 3 hosts). The per-node layout lives in `var.gcp_a_nodes` / `var.gcp_b_nodes`; machine type, disk, spot and termination action are `var.gcp_default_machine_type`, `var.gcp_node_disk_gb`, `var.gcp_spot`, `var.gcp_spot_termination_action`. Because Spot+DELETE drops the boot disk on preemption, Ansible deploys must be idempotent and stateful data is rebuildable. The local Proxmox cloud is unchanged (one LXC per node).

**WireGuard VPN — inter-cloud mesh.** One gateway per cloud handles all inter-cloud traffic:

| Gateway | WireGuard VPN IP | GCP internal IP | External IP |
|---------|-----------------|-----------------|-------------|
| Management (laptop) | `10.0.0.1` | — | dynamic / DDNS |
| Local gateway | `10.0.0.10` | — | configured manually |
| GCP-A node-01 | `10.0.0.20` | `10.20.1.10` | static (`google_compute_address`) |
| GCP-B node-01 | `10.0.0.30` | `10.30.1.10` | static (`google_compute_address`) |

Private nodes (node-02/03) do **not** run WireGuard — they get a systemd route service that sends inter-cloud traffic through their cloud's gateway. Ansible reaches them via their static GCP internal IPs (`10.20.2.11`, `10.20.2.12`, etc.) routed through the gateway. Static external IPs are reserved via `google_compute_address` so WireGuard peer configs survive Spot VM recreation. Gateways are configured at `cloud-init/wireguard.yaml.tftpl`.

Keys are generated manually (`wg genkey | tee private.key | wg pubkey > public.key`) and stored in `terraform.tfvars` (gitignored). After `tofu apply`, run `tofu output wireguard_gateway_ips` to get the GCP static IPs needed to configure the local gateway and management node peers.

**MySQL — application database.** MySQL in GCP-B (`node-02`) is the application database for the WebHardMon business layer. Schema (`docker/mysql/init.sql`):
- `empresa` — tenant root
- `administrador` — web panel users (bcrypt-hashed passwords)
- `licencia` — API keys bound to a specific laptop hostname (`portatil`); the collector sends `(codigo, portatil)` and NiFi validates `activa = 1` via JDBC LookupService before routing to Kafka

This is separate from Grafana's own internal auth and NiFi's own internal auth.

**Avro — Confluent Schema Registry.** Avro is the on-the-wire format for Kafka. A Confluent Schema Registry singleton runs on GCP-A `node-01` (co-located with Kafka, on the node that has no Java so RAM is free). NiFi serializes records against it (`ConfluentSchemaRegistry` controller service → `nifi_schema_registry_url`) and the Java consumer deserializes via `KafkaAvroDeserializer` (`javaapp_schema_registry_url`). Schemas are versioned and stored in Kafka's internal `_schemas` topic; compatibility is `BACKWARD` so the collector's schema can evolve without breaking deployed consumers. NiFi (local cloud) reaches the registry over WireGuard via node-01's gateway IP.

**External ingest — Cloudflare Tunnel.** The collector runs on **end-user PCs outside all three clouds**, so it can't reach NiFi via WireGuard (not peers) or the LAN (behind home NAT). `modules/cloudflare-tunnel` publishes NiFi's ingest listener at `ingest.<zone>` via a named Cloudflare Tunnel: `cloudflared` runs on the NiFi CT and dials **out** to Cloudflare (no port-forward, no inbound firewall). **Cloudflare Access** with a service token authenticates collectors at the edge. WireGuard carries only the inter-cloud mesh + admin SSH; Cloudflare Tunnel handles external→ingest only. Gated by `var.cloudflare_enabled`; outputs `cloudflared_tunnel_token` (for Ansible) + `collector_access_client_id/secret` (for the collector installer).

## Common Commands

```bash
tofu init                  # initialize providers and modules
tofu fmt -recursive        # format all .tf files
tofu validate              # validate configuration
tofu plan                  # preview changes
tofu apply                 # provision all three clouds + generate ansible/inventory.ini
tofu output                # show outputs after apply
tofu output wireguard_gateway_ips  # get GCP static IPs to configure external WireGuard peers
tofu destroy               # tear down all resources
```

To target a single resource or module:
```bash
tofu plan -target=module.gcp_a_vm
tofu apply -target=module.proxmox_lxc["nifi"]
tofu apply -target=google_compute_address.gcp_a_gateway
```

## Required Setup Before `tofu init`

Copy and fill in the example vars file:
```bash
cp terraform.tfvars.example terraform.tfvars
```

Mandatory variables (no defaults — `tofu plan` will fail without them):
- `proxmox_api_token`, `proxmox_ssh_private_key`
- `gcp_a_project_id`, `gcp_b_project_id` + corresponding credential JSON paths
- `wg_gcp_a_private_key`, `wg_gcp_a_public_key`, `wg_gcp_b_private_key`, `wg_gcp_b_public_key`
- `wg_mgmt_public_key`, `wg_local_gw_public_key`
- `local_ct_ssh_pubkey` — injected into every VM/CT for Ansible access

Generate WireGuard keypairs before filling `terraform.tfvars`:
```bash
wg genkey | tee gcp-a-private.key | wg pubkey > gcp-a-public.key
wg genkey | tee gcp-b-private.key | wg pubkey > gcp-b-public.key
wg genkey | tee mgmt-private.key  | wg pubkey > mgmt-public.key
wg genkey | tee local-gw-private.key | wg pubkey > local-gw-public.key
```

See `bootstrap/README.md` for how to create the Proxmox API token and GCP service accounts.

## Architecture

### Module Layout

```
modules/
  proxmox-lxc/       # LXC container with dual-NIC support and post-start hookscript
  gcp-network/       # VPC + 2 subnets + Cloud Router + Cloud NAT + firewall rules
  gcp-vm/            # GCE Ubuntu 24.04, shielded VM, static internal IP, cloud-init
  gcp-registry/      # Artifact Registry (Docker) per GCP project
  cloudflare-tunnel/ # Named tunnel + DNS + Access (service token) for external ingest
```

`main.tf` is the orchestration layer. It also creates `google_compute_address` resources for the GCP gateway static IPs before the VMs.

### WireGuard Key Management

Private keys for GCP gateways are passed as sensitive variables → embedded in `wg0.conf` via `cloud-init/wireguard.yaml.tftpl` at VM creation time. The management node and local gateway are configured manually using their own private keys and the GCP static IPs from `tofu output wireguard_gateway_ips`.

`lifecycle { ignore_changes = [metadata["user-data"]] }` in `gcp-vm` means WireGuard config changes do **not** trigger VM replacement — update it by re-running cloud-init or SSHing in.

### IP Addressing

Cloud subnets follow `10.<cloud>.<tier>.0/24`:
- `10.10.x` = local (Proxmox), `10.20.x` = gcp-a, `10.30.x` = gcp-b
- `.1` = public subnet, `.2` = private subnet

GCP VMs get **static internal IPs** at offset +10 from the subnet base (`cidrhost(cidr, i+10)`):
- GCP-A: `10.20.1.10` (node-01/gateway), `10.20.2.11` (node-02), `10.20.2.12` (node-03)
- GCP-B: `10.30.1.10` (node-01/gateway), `10.30.2.11` (node-02), `10.30.2.12` (node-03)

WireGuard VPN subnet: `10.0.0.0/24` (var `wg_vpn_cidr`). Gateway IPs are at offsets 1 (mgmt), 10 (local), 20 (gcp-a), 30 (gcp-b).

LXC containers get static IPs derived from the Proxmox VMID (`<cidr>.<vmid>`).

### Ansible Inventory

`tofu apply` generates `ansible/inventory.ini` (from `ansible/inventory.tmpl`) with hosts grouped by role and by cloud. `ansible_host` values:
- Local CTs: LAN IP
- GCP gateway nodes (node-01): WireGuard VPN IP (`10.0.0.20` / `10.0.0.30`)
- GCP private nodes (node-02/03): GCP internal IP, reachable via the gateway's WireGuard route

Because GCP nodes are shared, the generated inventory places one node in **multiple** `[role]` groups at once (e.g. gcp-a node-02 is in `[kafka]`, `[zookeeper]`, `[cassandra]`, `[java]`). The template also emits `[cloud_*]` groups and a `[webhardmon:children]` group spanning all roles.

### Ansible group_vars (config layer)

`ansible/group_vars/` holds the service config Ansible merges per host. Because a shared node belongs to several role groups, Ansible **merges** the group_vars of every group it's in. Key conventions (see `ansible/group_vars/README.md`):

- **Everything is namespaced per service** (`kafka_*`, `cassandra_*`, `zookeeper_*`, …) so co-located services never collide on a variable name during the merge.
- **Fixed RAM budget.** Heaps are capped so the densest node fits in 16 GB (`e2-standard-4`) with headroom for page cache — gcp-a node-02/03 runs Kafka 2 GB + ZooKeeper 512 MB + Cassandra 4 GB + Java/RMI 1.5 GB (~8 GB), gcp-b caps HBase RS 3 GB, Elasticsearch 3 GB, MySQL buffer pool 2 GB. Schema Registry (768 MB) sits on node-01 where there's no Java. Don't raise a heap without re-checking the node's total.
- **Deterministic identity.** `broker.id`, `myid`, etc. derive from the host's index within its group (`groups['kafka'].index(...)`). The inventory is stable (`node-01/02/03`), so a node deleted by spot preemption rebuilds with the **same** id and rejoins the cluster.
- Local single-service roles (nifi, hdfs, mapreduce, harbor) carry their own group_vars without these co-location constraints.

### Provisioning Scripts

- `cloud-init/wireguard.yaml.tftpl` — GCP VM user-data: hostname, `ubuntu` user, SSH hardening, WireGuard install. Gateway nodes get a full `wg0.conf`; private nodes get a systemd one-shot service that adds static routes via their gateway.
- `cloud-init/lxc-bootstrap.sh.tftpl` — Proxmox hookscript (runs post-start, idempotent): installs openssh + python3, creates `ubuntu` user, injects SSH pubkey, hardens SSH.

### Container Images

This repo provisions **registries** (Artifact Registry per GCP cloud + Harbor CT for local) but not the images. Dockerfiles + `build-and-push.sh` live in `docker/`. VMs pull using their service account + the gcloud credential helper. Pin a real `IMAGE_TAG` (not `latest`) so spot-rebuilt nodes get the same image.

### MySQL Init Schema

`docker/mysql/init.sql` is mounted at `/docker-entrypoint-initdb.d/` and runs once at container creation. Tables: `empresa`, `administrador` (bcrypt passwords), `licencia` (API keys per laptop). The Ansible MySQL role copies this file to the host before starting the container.

## State Backend

`backend.tf` defaults to local state. A commented-out GCS backend block is present for switching to remote state when needed.
