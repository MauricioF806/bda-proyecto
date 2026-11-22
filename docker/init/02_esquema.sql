CREATE SCHEMA IF NOT EXISTS rrhh;

-- Catálogos (no particionados)
CREATE TABLE rrhh.departamentos (
    id_departamento   SERIAL PRIMARY KEY USING INDEX TABLESPACE ts_indices,
    nombre            VARCHAR(80) NOT NULL UNIQUE USING INDEX TABLESPACE ts_indices,
    ubicacion         VARCHAR(80),
    presupuesto_anual NUMERIC(14,2) CHECK (presupuesto_anual >= 0)
) TABLESPACE ts_datos;

-- Roles laborales (puestos); no confundir con los roles de seguridad de la BD
CREATE TABLE rrhh.roles_laborales (
    id_rol      SERIAL PRIMARY KEY USING INDEX TABLESPACE ts_indices,
    nombre_rol  VARCHAR(60) NOT NULL UNIQUE USING INDEX TABLESPACE ts_indices,
    descripcion TEXT,
    salario_min NUMERIC(10,2) NOT NULL,
    salario_max NUMERIC(10,2) NOT NULL,
    CHECK (salario_max >= salario_min)
) TABLESPACE ts_datos;

-- Empleados: particionada por HASH para que la PK siga siendo solo id_empleado
-- (en tablas particionadas, una restricción UNIQUE debe incluir la clave de partición,
--  por eso email no lleva UNIQUE)
CREATE TABLE rrhh.empleados (
    id_empleado         BIGSERIAL,
    nombre              VARCHAR(60) NOT NULL,
    apellido_paterno    VARCHAR(60) NOT NULL,
    apellido_materno    VARCHAR(60),
    email               VARCHAR(120) NOT NULL,
    fecha_contratacion  DATE NOT NULL,
    salario             NUMERIC(10,2) NOT NULL CHECK (salario > 0),
    id_departamento     INT NOT NULL REFERENCES rrhh.departamentos (id_departamento),
    id_rol              INT NOT NULL REFERENCES rrhh.roles_laborales (id_rol),
    activo              BOOLEAN NOT NULL DEFAULT TRUE,
    nivel_clasificacion SMALLINT NOT NULL DEFAULT 1 CHECK (nivel_clasificacion BETWEEN 1 AND 3),
    PRIMARY KEY (id_empleado) USING INDEX TABLESPACE ts_indices
) PARTITION BY HASH (id_empleado);

CREATE TABLE rrhh.empleados_p0 PARTITION OF rrhh.empleados FOR VALUES WITH (MODULUS 4, REMAINDER 0) TABLESPACE ts_datos;
CREATE TABLE rrhh.empleados_p1 PARTITION OF rrhh.empleados FOR VALUES WITH (MODULUS 4, REMAINDER 1) TABLESPACE ts_datos;
CREATE TABLE rrhh.empleados_p2 PARTITION OF rrhh.empleados FOR VALUES WITH (MODULUS 4, REMAINDER 2) TABLESPACE ts_datos;
CREATE TABLE rrhh.empleados_p3 PARTITION OF rrhh.empleados FOR VALUES WITH (MODULUS 4, REMAINDER 3) TABLESPACE ts_datos;

-- Nómina: particionada por RANGE (una partición por año)
CREATE TABLE rrhh.nomina (
    id_pago      BIGSERIAL,
    id_empleado  BIGINT NOT NULL REFERENCES rrhh.empleados (id_empleado),
    fecha_pago   DATE NOT NULL,
    salario_base NUMERIC(10,2) NOT NULL,
    bonos        NUMERIC(10,2) NOT NULL DEFAULT 0,
    deducciones  NUMERIC(10,2) NOT NULL DEFAULT 0,
    PRIMARY KEY (id_pago, fecha_pago) USING INDEX TABLESPACE ts_indices
) PARTITION BY RANGE (fecha_pago);

CREATE TABLE rrhh.nomina_2022 PARTITION OF rrhh.nomina FOR VALUES FROM ('2022-01-01') TO ('2023-01-01') TABLESPACE ts_historico;
CREATE TABLE rrhh.nomina_2023 PARTITION OF rrhh.nomina FOR VALUES FROM ('2023-01-01') TO ('2024-01-01') TABLESPACE ts_historico;
CREATE TABLE rrhh.nomina_2024 PARTITION OF rrhh.nomina FOR VALUES FROM ('2024-01-01') TO ('2025-01-01') TABLESPACE ts_historico;
CREATE TABLE rrhh.nomina_2025 PARTITION OF rrhh.nomina FOR VALUES FROM ('2025-01-01') TO ('2026-01-01') TABLESPACE ts_datos;
CREATE TABLE rrhh.nomina_2026 PARTITION OF rrhh.nomina FOR VALUES FROM ('2026-01-01') TO ('2027-01-01') TABLESPACE ts_datos;
CREATE TABLE rrhh.nomina_2027 PARTITION OF rrhh.nomina FOR VALUES FROM ('2027-01-01') TO ('2028-01-01') TABLESPACE ts_datos;
CREATE TABLE rrhh.nomina_default PARTITION OF rrhh.nomina DEFAULT TABLESPACE ts_datos;

-- Bitácora de auditoría (el trigger y la vista vienen después)
CREATE TABLE rrhh.auditoria_empleados (
    id_auditoria     BIGSERIAL PRIMARY KEY USING INDEX TABLESPACE ts_auditoria,
    tabla_afectada   TEXT NOT NULL,
    operacion        CHAR(1) NOT NULL CHECK (operacion IN ('I','U','D')),
    usuario_bd       TEXT NOT NULL DEFAULT current_user,
    fecha_evento     TIMESTAMPTZ NOT NULL DEFAULT now(),
    datos_anteriores JSONB,
    datos_nuevos     JSONB
) TABLESPACE ts_auditoria;
