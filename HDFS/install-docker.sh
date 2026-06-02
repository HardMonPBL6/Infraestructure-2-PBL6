#!/usr/bin/env bash
# install-docker.sh
# Target : Debian 13 "Trixie" en LXC Proxmox (unprivileged, nesting=true)
# Método : repositorio oficial docker.com — incluye CLI + daemon.
# Idempotente: si docker-ce-cli ya está instalado, salta la instalación.
set -euo pipefail

HARBOR_REGISTRY="${HARBOR_REGISTRY:-10.10.1.50:5000}"
export DEBIAN_FRONTEND=noninteractive

log() { echo "[$(date +%T)] $*"; }

# ── 0. Idempotencia: salir si docker CLI ya está operativo ───────────────────
if command -v docker &>/dev/null && docker --version &>/dev/null; then
  log "=== Docker ya instalado: $(docker --version) — nada que hacer ==="
  touch /root/.docker_done
  exit 0
fi

# ── 1. Dependencias base ──────────────────────────────────────────────────────
log "=== apt update ==="
apt-get -qq update \
  -o Acquire::Retries=3 \
  -o Acquire::http::Timeout=30 \
  -o Acquire::https::Timeout=30

apt-get -qq install -y --no-install-recommends \
  ca-certificates \
  curl \
  gnupg

# ── 2. Eliminar docker.io nativo si está presente (no incluye CLI en Trixie) ─
if dpkg -l docker.io &>/dev/null 2>&1; then
  log "=== eliminando docker.io nativo (sin CLI en Trixie) ==="
  apt-get -qq remove -y docker.io
  rm -f /etc/apt/sources.list.d/docker.list
fi

# ── 3. Repositorio oficial de Docker ─────────────────────────────────────────
log "=== añadiendo repo oficial docker.com ==="
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
echo \
  "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian ${CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get -qq update \
  -o Acquire::Retries=3 \
  -o Acquire::http::Timeout=30 \
  -o Acquire::https::Timeout=30

# ── 4. Instalar Docker Engine + CLI ──────────────────────────────────────────
log "=== instalando docker-ce + docker-ce-cli ==="
apt-get -qq install -y --no-install-recommends \
  docker-ce \
  docker-ce-cli \
  containerd.io

# ── 5. Activar demonio ───────────────────────────────────────────────────────
log "=== habilitando servicio Docker ==="
systemctl enable --now docker

# ── 6. Configurar daemon: registro inseguro Harbor + límite de logs ──────────
log "=== configurando /etc/docker/daemon.json ==="
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<EOF
{
  "insecure-registries": ["${HARBOR_REGISTRY}"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

systemctl restart docker
sleep 5

# ── 7. Verificar ─────────────────────────────────────────────────────────────
if ! systemctl is-active --quiet docker; then
  log "ERROR: Docker no arranca. Últimas líneas del journal:"
  journalctl -u docker --no-pager -n 30
  exit 1
fi

log "=== Docker listo: $(docker --version) ==="
touch /root/.docker_done
