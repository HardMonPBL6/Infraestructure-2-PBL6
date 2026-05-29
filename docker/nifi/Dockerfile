# NiFi — PATRÓN: extender imagen oficial + config del equipo.
# Pinea una versión concreta (no 'latest') para builds reproducibles.
FROM apache/nifi:2.0.0

# Config/flows propios. NiFi expone un ListenHTTP en 8081 para la ingesta del
# collector (el túnel Cloudflare apunta a localhost:8081 en el CT).
# Descomentad lo que uséis:
# COPY conf/    /opt/nifi/nifi-current/conf/
# COPY flows/flow.json.gz /opt/nifi/nifi-current/conf/flow.json.gz

EXPOSE 8080 8081
