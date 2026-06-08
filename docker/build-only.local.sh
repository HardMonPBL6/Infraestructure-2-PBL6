#!/usr/bin/env bash
# TEMP: build-only pass (no push). Mirrors build-and-push.sh's service map and
# tags images with push-ready registry names so `docker push <img>` works later
# once Harbor is deployed and the registries are authenticated.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TFVARS="$REPO_DIR/terraform.tfvars"

tfval() { grep -E "^[[:space:]]*$1[[:space:]]*=" "$TFVARS" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'; }

PROJECT_NAME="${PROJECT_NAME:-webhardmon}"
IMAGE_TAG="${IMAGE_TAG:-1.0}"
GCP_A_PROJECT="$(tfval gcp_a_project_id)"
GCP_A_LOCATION="${GCP_A_LOCATION:-europe-southwest1}"
GCP_B_PROJECT="$(tfval gcp_b_project_id)"
GCP_B_LOCATION="${GCP_B_LOCATION:-europe-west1}"
HARBOR_HOST="${HARBOR_HOST:-harbor.hardmon.eus}"

declare -A CLOUD=(
  [nifi]=local [hdfs]=local [mapreduce]=local
  [kafka]=gcp-a [zookeeper]=gcp-a [cassandra]=gcp-a [java-stressscore]=gcp-a [stressscore-bridge]=gcp-a [schema-registry]=gcp-a
  [hbase]=gcp-b [mysql]=gcp-b [grafana]=gcp-b [matomo]=gcp-b [web]=gcp-b
)
APP_SRC="$REPO_DIR/services/stressscore"
WEB_SRC="$REPO_DIR/services/web"
declare -A BUILD_CTX=( [java-stressscore]="$APP_SRC" [stressscore-bridge]="$APP_SRC" [web]="$WEB_SRC" )
declare -A BUILD_FILE=( [java-stressscore]="$APP_SRC/server/Dockerfile" [stressscore-bridge]="$APP_SRC/client/Dockerfile" [web]="$WEB_SRC/Dockerfile" )

registry_for() {
  case "$1" in
    gcp-a) echo "${GCP_A_LOCATION}-docker.pkg.dev/${GCP_A_PROJECT}/${PROJECT_NAME}-a-docker" ;;
    gcp-b) echo "${GCP_B_LOCATION}-docker.pkg.dev/${GCP_B_PROJECT}/${PROJECT_NAME}-b-docker" ;;
    local) echo "${HARBOR_HOST}/${PROJECT_NAME}" ;;
    *)     return 1 ;;
  esac
}

services=("$@")
if [[ ${#services[@]} -eq 0 ]]; then
  for d in "$SCRIPT_DIR"/*/; do [[ -f "${d}Dockerfile" ]] && services+=("$(basename "$d")"); done
  for svc in "${!BUILD_CTX[@]}"; do [[ " ${services[*]} " == *" $svc "* ]] || services+=("$svc"); done
fi

echo "Tag: $IMAGE_TAG | services: ${services[*]}"
ok=(); failed=()
for svc in "${services[@]}"; do
  cloud="${CLOUD[$svc]:-}"
  ctx="${BUILD_CTX[$svc]:-$SCRIPT_DIR/$svc}"
  dockerfile="${BUILD_FILE[$svc]:-$ctx/Dockerfile}"
  [[ -z "$cloud" ]] && { echo "!! $svc: sin mapeo de nube, omitido"; continue; }
  [[ -f "$dockerfile" ]] || { echo "!! $svc: sin Dockerfile ($dockerfile), omitido"; continue; }
  img="$(registry_for "$cloud")/$svc:$IMAGE_TAG"
  echo "==> BUILD [$cloud] $svc -> $img"
  if docker build -t "$img" -f "$dockerfile" "$ctx"; then echo "    OK $svc"; ok+=("$svc"); else echo "    FALLO $svc"; failed+=("$svc"); fi
done

echo "================ RESUMEN BUILD ================"
echo "OK (${#ok[@]}): ${ok[*]:-none}"
echo "FALLO (${#failed[@]}): ${failed[*]:-none}"
[[ ${#failed[@]} -eq 0 ]] && echo "BUILD_RESULT=SUCCESS" || echo "BUILD_RESULT=PARTIAL"
