#!/usr/bin/env bash
# TEMP: push already-built :1.0 images. All destinations are derived from
# terraform.tfvars (same registry_for() mapping as build-only.local.sh) — no
# hardcoded project IDs. gcp-a under the active account; gcp-b under its own SA
# (key path also from tfvars), then restore; Harbor skipped (not deployed).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TFVARS="$REPO_DIR/terraform.tfvars"
tfval() { grep -E "^[[:space:]]*$1[[:space:]]*=" "$TFVARS" | head -1 | sed -E 's/^[^=]*=[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/'; }

PROJECT_NAME="${PROJECT_NAME:-webhardmon}"
TAG="${IMAGE_TAG:-1.0}"
GCP_A_PROJECT="$(tfval gcp_a_project_id)"
GCP_A_LOCATION="${GCP_A_LOCATION:-europe-southwest1}"
GCP_B_PROJECT="$(tfval gcp_b_project_id)"
GCP_B_LOCATION="${GCP_B_LOCATION:-europe-west1}"
GCPB_KEY="$(tfval gcp_b_credentials_file)"

registry_for() {
  case "$1" in
    gcp-a) echo "${GCP_A_LOCATION}-docker.pkg.dev/${GCP_A_PROJECT}/${PROJECT_NAME}-a-docker" ;;
    gcp-b) echo "${GCP_B_LOCATION}-docker.pkg.dev/${GCP_B_PROJECT}/${PROJECT_NAME}-b-docker" ;;
  esac
}
ORIG_ACCT="$(gcloud config get-value account 2>/dev/null)"
A_SVCS="kafka zookeeper cassandra schema-registry java-stressscore stressscore-bridge"
B_SVCS="hbase mysql grafana matomo web"

echo "Derived from tfvars: gcp-a=$(registry_for gcp-a) | gcp-b=$(registry_for gcp-b)"
ok=(); fail=()
push_one(){ echo "==> push $1"; if docker push "$1"; then echo "   OK $1"; ok+=("$1"); else echo "   FAIL $1"; fail+=("$1"); fi; }

echo "### GCP-A (account: $ORIG_ACCT)"
for s in $A_SVCS; do push_one "$(registry_for gcp-a)/$s:$TAG"; done

echo "### GCP-B (activating its SA from tfvars key)"
if gcloud auth activate-service-account --key-file="$GCPB_KEY" >/dev/null 2>&1; then echo "activated gcp-b SA"; else echo "FAILED to activate gcp-b SA"; fi
for s in $B_SVCS; do push_one "$(registry_for gcp-b)/$s:$TAG"; done

echo "### restoring original account: $ORIG_ACCT"
gcloud config set account "$ORIG_ACCT" >/dev/null 2>&1 && echo "restored" || echo "FAILED restore"

echo "### Harbor images skipped (not deployed): nifi mapreduce"
echo "================ RESUMEN PUSH ================"
echo "OK (${#ok[@]}): ${ok[*]:-none}"
echo "FAIL (${#fail[@]}): ${fail[*]:-none}"
[ ${#fail[@]} -eq 0 ] && echo "PUSH_RESULT=SUCCESS" || echo "PUSH_RESULT=PARTIAL"
