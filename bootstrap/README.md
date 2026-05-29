# Bootstrap

Pasos previos al primer `tofu init` — ver el README de la raíz para los comandos. Resumen:

1. **Proxmox** — crear usuario `tofu@pve`, API token, copiar clave SSH al nodo.
2. **GCP × 2** — crear proyectos, habilitar APIs (`compute`, `artifactregistry`, `iam`), crear service accounts con `roles/editor`, descargar JSON.
3. **Tailscale** — crear OAuth client con scopes `auth_keys` + `acl`.
4. **(opcional) GCS** — `gsutil mb gs://webhardmon-tofu-state` + `versioning set on` y conmutar `backend.tf` a `gcs`.

Este directorio existe como ancla para futuros scripts de bootstrap automatizado (p. ej. crear el bucket GCS, registrar la service account, etc.). De momento solo documentación.
