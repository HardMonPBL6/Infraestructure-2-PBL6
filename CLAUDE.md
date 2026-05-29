# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

OpenTofu (Terraform-compatible) infrastructure-as-code for **WebHardMon** — a distributed big data platform spanning three cloud environments connected via a Tailscale WireGuard mesh:

| Cloud | Platform | Services |
|-------|----------|----------|
| `local` | Proxmox VE (LXC containers) | NiFi, HDFS ×3, MapReduce, Harbor |
| `gcp-a` | GCP europe-southwest1 | Kafka ×3, ZooKeeper ×3, Java/RMI ×2, Cassandra ×3 |
| `gcp-b` | GCP europe-west1 | MySQL, HBase ×3, Elasticsearch, Grafana |

**GCP cost model — 3 shared spot VMs per cloud.** To save money the GCP services are *not* one VM per cluster node. Each GCP cloud runs **3 `e2-standard-4` Spot VMs** (`gcp_spot = true`, `instance_termination_action = DELETE`) that co-locate the services as containers, keeping one instance of each clustered service per node (so a real 3-node distributed cluster survives across 3 hosts). The per-node service layout lives in `var.gcp_a_nodes` / `var.gcp_b_nodes`; machine type, disk, spot and termination action are `var.gcp_default_machine_type`, `var.gcp_node_disk_gb`, `var.gcp_spot`, `var.gcp_spot_termination_action`. Because Spot+DELETE drops the boot disk on preemption, Ansible deploys must be idempotent and stateful data is rebuildable. The local Proxmox cloud is unchanged (one LXC per node).

GCP VMs join Tailscale directly via cloud-init. Proxmox LXC containers do **not** run Tailscale; the operator's laptop acts as a subnet router advertising `10.10.2.0/24` and `10.10.3.0/24`.

**External ingest — Cloudflare Tunnel.** The collector runs on **end-user PCs outside all three clouds**, so it can't reach NiFi via the tailnet (not members) or the LAN (behind home NAT). A `modules/cloudflare-tunnel` publishes NiFi's ingest listener at `ingest.<zone>` via a named Cloudflare Tunnel: `cloudflared` runs on the NiFi CT and dials **out** to Cloudflare (no port-forward, no inbound firewall). **Cloudflare Access** with a service token authenticates collectors at the edge. Tailscale is unchanged — it still carries the inter-cloud mesh + admin SSH; Cloudflare Tunnel only handles external→ingest. Gated by `var.cloudflare_enabled`; OpenTofu creates the tunnel/DNS/Access/token and outputs `cloudflared_tunnel_token` (for Ansible to run the daemon) + `collector_access_client_id/secret` (for the collector installer).

## Common Commands

```bash
tofu init                  # initialize providers and modules
tofu fmt -recursive        # format all .tf files
tofu validate              # validate configuration
tofu plan                  # preview changes
tofu apply                 # provision all three clouds + generate ansible/inventory.ini
tofu output                # show outputs after apply
tofu destroy               # tear down all resources
```

To target a single resource or module:
```bash
tofu plan -target=module.gcp_a_vms
tofu apply -target=module.proxmox_lxc["nifi"]
```

## Required Setup Before `tofu init`

Copy and fill in the example vars file:
```bash
cp terraform.tfvars.example terraform.tfvars
```

Mandatory variables (no defaults — `tofu plan` will fail without them):
- `proxmox_api_token_id`, `proxmox_api_token_secret`, `proxmox_node_ssh_private_key`
- `gcp_project_id_a`, `gcp_project_id_b` + corresponding credential JSON paths
- `tailscale_oauth_client_id`, `tailscale_oauth_client_secret`
- `ssh_public_key` — injected into every VM/CT for Ansible access

See `bootstrap/README.md` for how to create the Proxmox API token, GCP service accounts, and Tailscale OAuth client.

## Architecture

### Module Layout

```
modules/
  tailscale/        # ACL policy + one preauthorized auth key per cloud (gcp-a, gcp-b)
  proxmox-lxc/      # LXC container with dual-NIC support and post-start hookscript
  gcp-network/      # VPC + 2 subnets + Cloud Router + Cloud NAT + firewall rules
  gcp-vm/           # GCE Ubuntu 24.04, shielded VM, cloud-init user-data
  gcp-registry/     # Artifact Registry (Docker) per GCP project
  cloudflare-tunnel/ # Named tunnel + DNS + Access (service token) for external ingest
```

`main.tf` is the orchestration layer; it calls all modules in order and passes outputs between them.

### Container images

This repo provisions the **registries** (Artifact Registry per GCP cloud + grants each VM service account `roles/artifactregistry.reader` on its repo via `gcp-registry`'s `reader_members`; Harbor CT for local) but **not the images**. The team's Dockerfiles + `build-and-push.sh` live in `docker/` (could move to the app repo). Image names there match the `*_image` refs in the Ansible `group_vars`, and `build-and-push.sh` maps each service to its cloud's registry. VMs pull using their SA + the gcloud credential helper (no key files); push is a developer/CI action. Pin a real `IMAGE_TAG` (not `latest`) so a spot-rebuilt node gets the same image.

### IP Addressing

Subnets follow the pattern `10.<cloud>.<tier>.0/24`:
- `10.10.x` = local (Proxmox), `10.20.x` = gcp-a, `10.30.x` = gcp-b
- `.1` = public subnet, `.2` = private subnet

LXC containers get **static IPs** derived from the Proxmox VMID (`<cidr>.<vmid>`). This makes Ansible inventory deterministic without DHCP.

Private-subnet LXC containers get a second NIC on DHCP for egress (apt updates etc.) without a public IP.

### Provisioning Scripts

- `cloud-init/tailscale.yaml.tftpl` — GCP VM user-data: hostname, `ubuntu` user, SSH hardening, Tailscale install + join with preauthorized key and role/cloud tags.
- `cloud-init/lxc-bootstrap.sh.tftpl` — Proxmox hookscript (runs post-start, idempotent via marker file): installs openssh + python3, creates `ubuntu` user, injects SSH pubkey, hardens SSH.

### Outputs

`tofu apply` generates `ansible/inventory.ini` (from `ansible/inventory.tmpl`) with hosts grouped by role and by cloud. This file is gitignored.

### Tailscale ACL Tags

`tag:mgmt` can SSH to everything. Per-service tags (`tag:kafka`, `tag:mysql`, etc.) allow only the ports needed for that service. Tags are defined in `modules/tailscale/main.tf`.

## State Backend

`backend.tf` defaults to local state. A commented-out GCS backend block is present for switching to remote state when needed.
