# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 — Compilar el fat JAR con Maven (Java 8 = mismo JDK que el NameNode)
# ─────────────────────────────────────────────────────────────────────────────
FROM maven:3.9.6-eclipse-temurin-8 AS build

WORKDIR /build

# Descargar dependencias primero (caché de capas Docker)
COPY pom.xml .
RUN mvn dependency:go-offline -q

# Compilar + shade
COPY src/ src/
RUN mvn package -DskipTests -q

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 — Imagen mínima que solo contiene el JAR listo para extraer.
# El rol Ansible hace: docker build → docker create → docker cp → docker rm
# ─────────────────────────────────────────────────────────────────────────────
FROM debian:bookworm-slim

COPY --from=build /build/target/webhardmon-mr-*.jar /app/webhardmon-mr.jar

CMD ["echo", "Extrae el JAR: docker cp <container>:/app/webhardmon-mr.jar ."]
