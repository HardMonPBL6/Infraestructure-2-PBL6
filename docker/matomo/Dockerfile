FROM matomo:5.1

# La configuración inicial (host DB, credenciales, admin) se realiza mediante
# el asistente web en http://<host>:8080 en el primer arranque.
# Variables de entorno necesarias en docker-compose / despliegue Ansible:
#   MATOMO_DATABASE_HOST     host del MySQL de Matomo
#   MATOMO_DATABASE_DBNAME   matomo
#   MATOMO_DATABASE_USERNAME matomo
#   MATOMO_DATABASE_PASSWORD <vault>
#
# Referencia: ansible/group_vars/matomo.yml

EXPOSE 80
