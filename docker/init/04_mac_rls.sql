-- 04_mac_rls.sql: emulación de MAC con Row Level Security

CREATE TABLE rrhh.autorizacion_usuario (
    usuario            NAME PRIMARY KEY USING INDEX TABLESPACE ts_indices,
    nivel_autorizacion SMALLINT NOT NULL CHECK (nivel_autorizacion BETWEEN 1 AND 3)
) TABLESPACE ts_datos;

INSERT INTO rrhh.autorizacion_usuario (usuario, nivel_autorizacion) VALUES
    ('usr_admin', 3), ('usr_analista1', 1), ('usr_analista2', 2), ('usr_auditor', 3);

-- Nivel de autorización del usuario que ejecuta la consulta (0 si no tiene)
CREATE FUNCTION rrhh.nivel_actual() RETURNS SMALLINT
LANGUAGE sql STABLE AS $$
    SELECT COALESCE((SELECT nivel_autorizacion FROM rrhh.autorizacion_usuario
                     WHERE usuario = current_user), 0)::smallint
$$;

-- Cada usuario solo puede leer su propia fila de autorización
ALTER TABLE rrhh.autorizacion_usuario ENABLE ROW LEVEL SECURITY;
CREATE POLICY pol_aut_admin  ON rrhh.autorizacion_usuario FOR ALL TO rol_admin
    USING (true) WITH CHECK (true);
CREATE POLICY pol_aut_propio ON rrhh.autorizacion_usuario FOR SELECT TO rol_analista, rol_auditor
    USING (usuario = current_user);
GRANT SELECT ON rrhh.autorizacion_usuario TO rol_analista, rol_auditor;

-- Empleados: el administrador ve todo; el analista solo filas con nivel <= su autorización
ALTER TABLE rrhh.empleados ENABLE ROW LEVEL SECURITY;
CREATE POLICY pol_empleados_admin ON rrhh.empleados FOR ALL TO rol_admin
    USING (true) WITH CHECK (true);
CREATE POLICY pol_empleados_mac ON rrhh.empleados FOR SELECT TO rol_analista
    USING (nivel_clasificacion <= rrhh.nivel_actual());
