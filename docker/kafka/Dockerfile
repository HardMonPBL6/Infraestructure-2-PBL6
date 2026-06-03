# Kafka — imagen Confluent Platform 7.6.1 (Kafka 3.6.x + ZooKeeper mode).
# Misma línea de versión que cp-zookeeper y cp-schema-registry para garantizar
# compatibilidad de protocolo entre los tres servicios.
# La configuración del broker (id, listeners, ZK connect, heap) la inyecta el
# rol Ansible a través de variables de entorno en tiempo de despliegue.
FROM confluentinc/cp-kafka:7.6.1

# Puerto del broker (clientes y inter-broker con listener único PLAINTEXT).
EXPOSE 9092
