# HBase — PATRÓN: servicio sin imagen oficial mantenida → construir del tarball.
FROM eclipse-temurin:11-jre

ARG HBASE_VERSION=2.5.10
ENV HBASE_HOME=/opt/hbase
ENV PATH="${HBASE_HOME}/bin:${PATH}"

RUN set -eux; \
    apt-get update && apt-get install -y --no-install-recommends curl ca-certificates; \
    curl -fsSL "https://downloads.apache.org/hbase/${HBASE_VERSION}/hbase-${HBASE_VERSION}-bin.tar.gz" \
      | tar -xz -C /opt; \
    mv "/opt/hbase-${HBASE_VERSION}" "${HBASE_HOME}"; \
    apt-get purge -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

# Config del equipo (hbase-site.xml con quorum ZK, regiones, etc.). El deploy
# puede sobreescribirla por env/montaje.
# COPY conf/hbase-site.xml ${HBASE_HOME}/conf/hbase-site.xml

# RegionServer / Master según el rol (lo decide el deploy: hbase_is_master).
EXPOSE 16000 16010 16020 16030
CMD ["hbase", "master", "start"]
