-- WebHardMon — esquema de aplicación
-- Base de datos: empresas, administradores del panel y licencias (API keys por portátil).
--
-- Este fichero se monta en /docker-entrypoint-initdb.d/ del contenedor MySQL
-- y se ejecuta automáticamente al crear la base de datos por primera vez.

CREATE DATABASE IF NOT EXISTS webhardmon
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE webhardmon;

-- ─── empresa ────────────────────────────────────────────────────────────────
-- Tenant raíz. Cada empresa agrupa sus admins y sus licencias.

CREATE TABLE empresa (
    id     BIGINT       NOT NULL AUTO_INCREMENT,
    nombre VARCHAR(255),
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- ─── administrador ──────────────────────────────────────────────────────────
-- Usuarios del panel web. La contraseña se almacena como hash bcrypt
-- (la capa de aplicación nunca guarda el texto en claro).

CREATE TABLE administrador (
    id         BIGINT       NOT NULL AUTO_INCREMENT,
    username   VARCHAR(255) NOT NULL,
    password   VARCHAR(255) NOT NULL,
    empresa_id BIGINT       NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_admin_username (username),
    CONSTRAINT fk_admin_empresa
        FOREIGN KEY (empresa_id) REFERENCES empresa (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- ─── licencia ───────────────────────────────────────────────────────────────
-- API key del collector. Una licencia = un portátil autorizado para una empresa.
-- El collector envía (codigo, portatil); el backend verifica activa = 1.
-- La unicidad (empresa_id, portatil) impide que un mismo portátil tenga
-- dos licencias activas bajo la misma empresa.

CREATE TABLE licencia (
    id             BIGINT       NOT NULL AUTO_INCREMENT,
    codigo         VARCHAR(255) NOT NULL,
    activa         TINYINT(1)   NOT NULL DEFAULT 1,
    empresa_id     BIGINT       NOT NULL,
    portatil       VARCHAR(80)  NOT NULL,
    fecha_creacion DATETIME(6)  NOT NULL,
    PRIMARY KEY (id),
    UNIQUE KEY uk_licencia_codigo (codigo),
    UNIQUE KEY uk_licencia_empresa_portatil (empresa_id, portatil),
    CONSTRAINT fk_licencia_empresa
        FOREIGN KEY (empresa_id) REFERENCES empresa (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
