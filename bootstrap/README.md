# Bootstrap

Pasos previos al primer `tofu init` — ver el README de la raíz para los comandos. Resumen:

1. **Proxmox** — crear usuario `tofu@pve`, API token, copiar clave SSH al nodo.
2. **GCP × 2** — crear proyectos, habilitar APIs (`compute`, `artifactregistry`, `iam`), crear service accounts con `roles/editor`, descargar JSON.
3. **Tailscale** — crear OAuth client con scopes `auth_keys` + `acl`.
4. **Cloudflare** (ingesta externa) — dominio gestionado en Cloudflare + API token con permisos `Account > Cloudflare Tunnel:Edit` y `Account > Access: Apps and Policies:Edit` + `Zone > DNS:Edit`. Anota `account_id` y `zone_id` (panel de la zona). Pon `cloudflare_enabled = false` para omitirlo.
5. **(opcional) GCS** — `gsutil mb gs://webhardmon-tofu-state` + `versioning set on` y conmutar `backend.tf` a `gcs`.

Este directorio existe como ancla para futuros scripts de bootstrap automatizado (p. ej. crear el bucket GCS, registrar la service account, etc.). De momento solo documentación.
