-- WebHardMon — esquema de aplicación
-- Base de datos: empresas (tenant), usuarios del panel y ordenadores registrados.
--
-- Este fichero se monta en /docker-entrypoint-initdb.d/ del contenedor MySQL
-- y se ejecuta automáticamente al crear el volumen por primera vez.

CREATE DATABASE IF NOT EXISTS telemetriadb
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE telemetriadb;

-- ─── empresa ────────────────────────────────────────────────────────────────
-- Tenant raíz. Cada empresa agrupa sus usuarios y sus ordenadores.

CREATE TABLE empresa (
    id     BIGINT       NOT NULL AUTO_INCREMENT,
    nombre VARCHAR(255) NOT NULL,
    codigo VARCHAR(40)  NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_empresa_codigo (codigo)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- ─── usuario ────────────────────────────────────────────────────────────────
-- Usuarios del panel web. Contraseña almacenada como hash bcrypt.

CREATE TABLE usuario (
    id         BIGINT       NOT NULL AUTO_INCREMENT,
    username   VARCHAR(255) NOT NULL,
    password   VARCHAR(255) NOT NULL,
    empresa_id BIGINT       NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_usuario_username (username),
    CONSTRAINT fk_usuario_empresa
        FOREIGN KEY (empresa_id) REFERENCES empresa (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- ─── ordenador ──────────────────────────────────────────────────────────────
-- Portátil registrado en una empresa. El uuid_ordenador es el identificador
-- único que el collector envía junto con las métricas a Cassandra/Kafka.

CREATE TABLE ordenador (
    id             BIGINT       NOT NULL AUTO_INCREMENT,
    nombre         VARCHAR(255),
    uuid_ordenador VARCHAR(36)  NOT NULL,
    empresa_id     BIGINT       NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_ordenador_uuid (uuid_ordenador),
    CONSTRAINT fk_ordenador_empresa
        FOREIGN KEY (empresa_id) REFERENCES empresa (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- ─── datos iniciales ────────────────────────────────────────────────────────

INSERT INTO empresa (nombre, codigo) VALUES ('Demo Corp', 'DEMO-0000-0000-0000');
