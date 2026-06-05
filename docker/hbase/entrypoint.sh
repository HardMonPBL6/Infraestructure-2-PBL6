#!/bin/bash
# Arranca el rol correcto según HBASE_ROLE (master | regionserver | rest).
# hbase-site.xml se monta en ${HBASE_HOME}/conf/ por el rol Ansible.
# El rol master también levanta el ZooKeeper embebido antes de arrancar HMaster.
set -euo pipefail

ROLE="${HBASE_ROLE:-master}"

case "${ROLE}" in
  master)
    # Iniciar ZooKeeper embebido como daemon (escribe PID en $HBASE_LOG_DIR).
    # hbase-daemon.sh lo daemoniza; el master lo hereda via hbase-site.xml.
    "${HBASE_HOME}/bin/hbase-daemon.sh" start zookeeper

    # Esperar a que ZK esté listo (4LW "ruok" via /dev/tcp)
    echo "Esperando ZooKeeper en 2181..."
    for i in $(seq 1 30); do
      if 2>/dev/null bash -c "exec 3<>/dev/tcp/127.0.0.1/2181 && printf 'ruok' >&3 && read -t 2 resp <&3 && [[ \$resp == imok ]]"; then
        echo "ZooKeeper listo."
        break
      fi
      sleep 2
    done

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
