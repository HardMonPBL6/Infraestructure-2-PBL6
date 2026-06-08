-- WebHardMon — esquema MySQL (CANÓNICO, alineado con el repo de la app WebHardMon).
-- BD de la aplicación: empresas, administradores del panel, usuarios (ordenadores)
-- y licencias del agente. La app usa Hibernate ddl-auto:update; este fichero crea
-- la BD a mano y siembra datos de prueba. Se monta en /docker-entrypoint-initdb.d/.
 
CREATE DATABASE IF NOT EXISTS telemetriadb
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;
 
USE telemetriadb;
 
-- ─── empresa ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS empresa (
    id     BIGINT       NOT NULL AUTO_INCREMENT,
    nombre VARCHAR(255) NOT NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB;
 
-- ─── administrador ──────────────────────────────────────────────────────────
-- Usuarios con acceso al panel web (rol ADMIN).
CREATE TABLE IF NOT EXISTS administrador (
    id         BIGINT       NOT NULL AUTO_INCREMENT,
    username   VARCHAR(255) NOT NULL,
    password   VARCHAR(255) NOT NULL,
    empresa_id BIGINT       NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uk_administrador_username UNIQUE (username),
    CONSTRAINT fk_administrador_empresa
        FOREIGN KEY (empresa_id) REFERENCES empresa(id)
) ENGINE=InnoDB;
 
-- ─── usuario ──────────────────────────────────────────────────────────────
-- Empleado con un ordenador (sin acceso web). nombre_ordenador == `nombre` en
-- las tablas Cassandra ordenadores y mediciones.
CREATE TABLE IF NOT EXISTS usuario (
    id               BIGINT       NOT NULL AUTO_INCREMENT,
    nombre           VARCHAR(100) NOT NULL,
    nombre_ordenador VARCHAR(80)  NOT NULL,
    empresa_id       BIGINT       NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uk_usuario_empresa_ordenador UNIQUE (empresa_id, nombre_ordenador),
    CONSTRAINT fk_usuario_empresa
        FOREIGN KEY (empresa_id) REFERENCES empresa(id)
) ENGINE=InnoDB;
 
-- ─── licencia ──────────────────────────────────────────────────────────────
-- API key del agente Go (1-1 con usuario). El agente envía `codigo` a
-- POST /api/agente/validar; el panel verifica activa=1 y devuelve empresaId+nombreOrdenador.
CREATE TABLE IF NOT EXISTS licencia (
    id             BIGINT       NOT NULL AUTO_INCREMENT,
    codigo         VARCHAR(255) NOT NULL,
    activa         TINYINT(1)   NOT NULL DEFAULT 1,
    fecha_creacion DATETIME     NOT NULL,
    usuario_id     BIGINT       NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT uk_licencia_codigo  UNIQUE (codigo),
    CONSTRAINT uk_licencia_usuario UNIQUE (usuario_id),
    CONSTRAINT fk_licencia_usuario
        FOREIGN KEY (usuario_id) REFERENCES usuario(id)
) ENGINE=InnoDB;
 
-- ─── vista de lookup para NiFi ────────────────────────────────────────────────
-- NiFi consulta esta vista con el `codigo`: valida (activa=1) y obtiene empresa_id
-- + nombre en la misma consulta para enriquecer el Avro (sin tocar la API de Java).
CREATE OR REPLACE VIEW licencia_lookup AS
SELECT l.codigo           AS codigo,
       l.activa           AS activa,
       u.empresa_id       AS empresa_id,
       u.nombre_ordenador AS nombre
FROM licencia l
JOIN usuario  u ON u.id = l.usuario_id;
 
-- ─── datos de prueba ────────────────────────────────────────────────────────
-- No se siembra ningún administrador: el superadmin se crea en el arranque de
-- la app (SUPERADMIN_USERNAME/SUPERADMIN_PASSWORD, del vault) y desde el panel
-- se dan de alta los administradores. Así no hay hash de contraseña en el repo.
INSERT IGNORE INTO empresa (id, nombre) VALUES (1, 'Acme Corp');
INSERT IGNORE INTO usuario (id, nombre, nombre_ordenador, empresa_id)
VALUES (1, 'Usuario Prueba', 'PC-TEST', 1);
INSERT IGNORE INTO licencia (id, codigo, activa, fecha_creacion, usuario_id)
VALUES (1, 'WHM-TEST-TEST-TEST-AABB', 1, NOW(), 1);