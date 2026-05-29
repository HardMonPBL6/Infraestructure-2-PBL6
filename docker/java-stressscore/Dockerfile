# StressScore — app Java/RMI del equipo (data enrichment).
# PATRÓN: vuestro código → build completo. Espera un proyecto Maven en el
# contexto (pom.xml + src/). Si usáis Gradle, adaptad la etapa de build.

# --- build ---
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B package -DskipTests

# --- runtime ---
FROM eclipse-temurin:21-jre
WORKDIR /app
# Ajustad al nombre real del artefacto (jar sombreado/uber-jar):
COPY --from=build /src/target/*-shaded.jar /app/stressscore.jar

# RMI debe anunciar un hostname alcanzable por el resto del tailnet; lo fija el
# deploy (javaapp_rmi_server_hostname en group_vars/java.yml).
ENV JAVA_RMI_HOSTNAME=""
ENV JAVA_OPTS="-Xmx1536m"
EXPOSE 1099 1100
ENTRYPOINT ["sh","-c","java $JAVA_OPTS -Djava.rmi.server.hostname=$JAVA_RMI_HOSTNAME -jar /app/stressscore.jar"]
