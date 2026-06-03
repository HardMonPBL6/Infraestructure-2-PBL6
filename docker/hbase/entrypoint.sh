#!/bin/bash
# Arranca el rol correcto según HBASE_ROLE (master | regionserver | rest).
# hbase-site.xml se monta en ${HBASE_HOME}/conf/ por el rol Ansible.
set -euo pipefail

ROLE="${HBASE_ROLE:-master}"

case "${ROLE}" in
  master)
    exec hbase master start
    ;;
  regionserver)
    exec hbase regionserver start
    ;;
  rest)
    exec hbase rest start -p "${HBASE_REST_PORT:-8085}"
    ;;
  *)
    echo "ERROR: HBASE_ROLE debe ser master, regionserver o rest (valor: '${ROLE}')" >&2
    exit 1
    ;;
esac
