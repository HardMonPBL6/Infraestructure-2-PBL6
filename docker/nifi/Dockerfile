# NiFi — PATRÓN: extender imagen oficial + config del equipo.
# Pinea una versión concreta (no 'latest') para builds reproducibles.
# 1.27.0 = misma línea que el docker-compose local y que los nombres de processor
# que usa el flujo automatizado (configure_flow.py: PublishKafkaRecord_2_6,
# ExecuteScript). NiFi 2.x renombró/eliminó esos processors → rompería el script.
FROM apache/nifi:1.27.0

# Config/flows propios. NiFi expone un ListenHTTP en 8081 para la ingesta del
# collector (el túnel Cloudflare apunta a localhost:8081 en el CT).
# Descomentad lo que uséis:
# COPY conf/    /opt/nifi/nifi-current/conf/
# COPY flows/flow.json.gz /opt/nifi/nifi-current/conf/flow.json.gz

EXPOSE 8080 8081
