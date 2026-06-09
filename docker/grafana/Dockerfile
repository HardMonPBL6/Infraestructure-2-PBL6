FROM grafana/grafana:10.4.0

# Cassandra datasource plugin (comunica con el anillo GCP-A via WireGuard).
RUN grafana-cli plugins install hadesarchitect-cassandra-datasource && \
    grafana-cli plugins install yesoreyeram-infinity-datasource

# Los datasources (IPs reales del cluster) los provisiona Ansible en tiempo de
# despliegue, montando /etc/grafana/provisioning/datasources/ desde el host.
# Fuente canónica: ansible/roles/grafana/templates/datasources.yml.j2
# (provisioning/datasources/datasources.yml de este repo es solo referencia).

EXPOSE 3000
