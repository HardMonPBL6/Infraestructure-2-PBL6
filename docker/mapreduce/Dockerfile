# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 — Compilar el fat JAR con Maven (Java 8 = mismo JDK que el clúster)
# ─────────────────────────────────────────────────────────────────────────────
FROM maven:3.9.6-eclipse-temurin-8 AS build

WORKDIR /build

# Descargar dependencias primero (caché de capas Docker)
COPY pom.xml .
RUN mvn dependency:go-offline -q

# Compilar + shade
COPY src/ src/
RUN mvn package -DskipTests -q \
 && cp target/webhardmon-mr-*.jar /webhardmon-mr.jar

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 — Imagen runnable: runtime Hadoop 3.2.1 + el fat JAR.
# La base bde2020/hadoop-base aporta el CLI `hadoop` y las libs (las deps Hadoop
# del JAR son `provided`); debe coincidir con la version del clúster HDFS
# (group_vars/hdfs.yml: hadoop_version = 2.0.0-hadoop3.2.1-java8).
# El job corre en modo local (LocalJobRunner, sin YARN): lee Parquet de HDFS y
# escribe en HBase via TableOutputFormat. Contenedor efimero (docker run --rm).
# ─────────────────────────────────────────────────────────────────────────────
FROM bde2020/hadoop-base:2.0.0-hadoop3.2.1-java8

COPY --from=build /webhardmon-mr.jar /opt/webhardmon-mr.jar
COPY run-job.sh /opt/run-job.sh
RUN sed -i 's/\r//' /opt/run-job.sh && chmod +x /opt/run-job.sh

# El wrapper lee la configuración del job de variables de entorno (MR_*) y lanza
# `hadoop jar`. Sobreescribimos el ENTRYPOINT de la base: no necesitamos generar
# site XMLs (el input es una URI hdfs:// completa y el quorum ZK va por argumento).
ENTRYPOINT ["/opt/run-job.sh"]
