FROM grafana/grafana:10.4.0

# Cassandra datasource plugin (comunica con el anillo GCP-A via WireGuard).
RUN grafana-cli plugins install hadesarchitect-cassandra-datasource

# Los datasources (IPs reales del cluster) los provisiona Ansible en tiempo de
# despliegue, montando /etc/grafana/provisioning/datasources/ desde el host.
# Referencia: ansible/group_vars/grafana.yml

EXPOSE 3000
