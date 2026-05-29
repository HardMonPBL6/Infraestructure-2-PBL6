# docker/ — imágenes de servicio de WebHardMon

Los servicios se despliegan como **contenedores**. Este directorio contiene los
Dockerfiles del equipo y un script para construirlos y subirlos al registro de
cada nube. La **infra** (OpenTofu) solo garantiza que el registro existe y da
permiso de pull a las VMs; las **imágenes** las hacéis vosotros aquí.

> Puede vivir en este repo o moverse a vuestro repo de aplicación — es código de
> build, no de infra. Si lo movéis, llevaos `build-and-push.sh` con él.

## Dónde va cada imagen

`build-and-push.sh` mapea cada servicio a la nube/registro correcto:

| Nube | Registro | Servicios |
|------|----------|-----------|
| local | Harbor (`$HARBOR_HOST/webhardmon`) | nifi, hdfs, mapreduce |
| gcp-a | Artifact Registry A | kafka, zookeeper, cassandra, java-stressscore |
| gcp-b | Artifact Registry B | hbase, mysql, elasticsearch, grafana |

Las URLs coinciden con `container_registry` de los `group_vars` de Ansible, así
que lo que subáis aquí es lo que se despliega allí.

## Tres patrones (elegid por servicio)

1. **Vuestro código** → Dockerfile completo. Ej.: `java-stressscore/` (compila
   el JAR y lo ejecuta). Obligatorio para la app Java/RMI.
2. **Extender una imagen oficial** + vuestra config. Ej.: `nifi/`, `cassandra/`.
3. **Servicio sin imagen oficial** → construir desde el tarball. Ej.: `hbase/`.

Para un servicio que uséis tal cual (p.ej. Grafana, MySQL, Elasticsearch), **no
hace falta Dockerfile**: apuntad el `*_image` del group_vars a la imagen upstream
(`grafana/grafana:11.2.0`, etc.) y omitidlo del build.

## Uso

```bash
# Autenticación previa para Harbor (AR se autentica solo con gcloud):
docker login "$HARBOR_HOST"

export GCP_A_PROJECT=webhardmon-a-XXXXX
export GCP_B_PROJECT=webhardmon-b-XXXXX
export HARBOR_HOST=harbor.local        # o la IP/host del CT harbor
export IMAGE_TAG=1.0                    # fijad una versión, NO 'latest'

# Todos los servicios con Dockerfile:
./build-and-push.sh

# O solo algunos:
./build-and-push.sh cassandra java-stressscore
```

Luego poned `image_tag: "1.0"` en los group_vars y desplegad con Ansible.

## Requisitos
- `docker` y `gcloud` (autenticado: `gcloud auth login`) en la máquina de build.
- Permisos de push en los Artifact Registry (rol `roles/artifactregistry.writer`
  para vuestro usuario; las VMs solo tienen *reader*, concedido por OpenTofu).
- Bash 4+ (Linux/macOS/WSL/Git-Bash).
