#!/usr/bin/env bash
# Construye y sube las imágenes de servicio de WebHardMon al registro de su nube.
#
# Cada subdirectorio con un Dockerfile = un servicio. El mapa CLOUD decide a qué
# registro va. Las URLs coinciden con `container_registry` de los group_vars.
#
# Uso:
#   export GCP_A_PROJECT=... GCP_B_PROJECT=... HARBOR_HOST=... IMAGE_TAG=1.0
#   ./build-and-push.sh                 # todos los servicios con Dockerfile
#   ./build-and-push.sh cassandra nifi  # solo algunos
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-webhardmon}"
IMAGE_TAG="${IMAGE_TAG:-1.0}"

GCP_A_PROJECT="${GCP_A_PROJECT:?define GCP_A_PROJECT}"
GCP_A_LOCATION="${GCP_A_LOCATION:-europe-southwest1}"
GCP_B_PROJECT="${GCP_B_PROJECT:?define GCP_B_PROJECT}"
GCP_B_LOCATION="${GCP_B_LOCATION:-europe-west1}"
HARBOR_HOST="${HARBOR_HOST:-harbor.local}"

# servicio -> nube
declare -A CLOUD=(
  [nifi]=local [hdfs]=local [mapreduce]=local
  [kafka]=gcp-a [zookeeper]=gcp-a [cassandra]=gcp-a [java-stressscore]=gcp-a [stressscore-bridge]=gcp-a [schema-registry]=gcp-a
  [hbase]=gcp-b [mysql]=gcp-b [elasticsearch]=gcp-b [grafana]=gcp-b [matomo]=gcp-b
)

registry_for() {
  case "$1" in
    gcp-a) echo "${GCP_A_LOCATION}-docker.pkg.dev/${GCP_A_PROJECT}/${PROJECT_NAME}-a-docker" ;;
    gcp-b) echo "${GCP_B_LOCATION}-docker.pkg.dev/${GCP_B_PROJECT}/${PROJECT_NAME}-b-docker" ;;
    local) echo "${HARBOR_HOST}/${PROJECT_NAME}" ;;
    *)     return 1 ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Servicios a construir: argumentos, o todo subdir con Dockerfile.
services=("$@")
if [ ${#services[@]} -eq 0 ]; then
  for d in "$SCRIPT_DIR"/*/; do
    [ -f "${d}Dockerfile" ] && services+=("$(basename "$d")")
  done
fi
[ ${#services[@]} -eq 0 ] && { echo "No hay Dockerfiles que construir."; exit 0; }

# Autenticación de Docker a los Artifact Registry vía el helper de gcloud.
# (Harbor: hacer `docker login $HARBOR_HOST` antes de ejecutar este script.)
gcloud auth configure-docker "${GCP_A_LOCATION}-docker.pkg.dev,${GCP_B_LOCATION}-docker.pkg.dev" --quiet

failed=()
for svc in "${services[@]}"; do
  cloud="${CLOUD[$svc]:-}"
  ctx="$SCRIPT_DIR/$svc"
  if [ -z "$cloud" ]; then echo "!! $svc: sin mapeo de nube, omitido"; continue; fi
  if [ ! -f "$ctx/Dockerfile" ]; then echo "!! $svc: sin Dockerfile, omitido"; continue; fi
  img="$(registry_for "$cloud")/$svc:$IMAGE_TAG"
  echo "==> [$cloud] $svc -> $img"
  if docker build -t "$img" "$ctx" && docker push "$img"; then
    echo "    OK"
  else
    echo "    FALLO"; failed+=("$svc")
  fi
done

if [ ${#failed[@]} -gt 0 ]; then
  echo "Fallaron: ${failed[*]}"; exit 1
fi
echo "Listo. Tag: $IMAGE_TAG"
