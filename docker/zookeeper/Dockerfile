# ZooKeeper — imagen Confluent Platform (misma versión que Kafka y Schema Registry).
# La configuración del ensemble (myid, servidores, heap) la inyecta el rol Ansible
# a través de variables de entorno en tiempo de despliegue.
FROM confluentinc/cp-zookeeper:7.6.1

# Puertos del ensemble ZooKeeper:
#   2181 — cliente (Kafka, HBase, herramientas de admin)
#   2888 — comunicación peer-to-peer (follower → leader)
#   3888 — elección de líder entre peers
EXPOSE 2181 2888 3888
