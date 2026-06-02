FROM mysql:8.0

# El script de init se copia en /docker-entrypoint-initdb.d/:
# MySQL lo ejecuta automáticamente al crear el volumen por primera vez.
COPY init.sql /docker-entrypoint-initdb.d/01-telemetriadb.sql

EXPOSE 3306
