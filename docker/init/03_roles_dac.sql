-- 03_roles_dac.sql: roles (RBAC), usuarios y privilegios (DAC)

-- Roles de grupo (sin inicio de sesión)
CREATE ROLE rol_admin    NOLOGIN;
CREATE ROLE rol_analista NOLOGIN;
CREATE ROLE rol_auditor  NOLOGIN;

-- Usuarios ficticios (contraseñas de demostración, solo para este entorno académico)
CREATE ROLE usr_admin     LOGIN PASSWORD 'Admin_2026'     IN ROLE rol_admin;
CREATE ROLE usr_analista1 LOGIN PASSWORD 'Analista1_2026' IN ROLE rol_analista;
CREATE ROLE usr_analista2 LOGIN PASSWORD 'Analista2_2026' IN ROLE rol_analista;
CREATE ROLE usr_auditor   LOGIN PASSWORD 'Auditor_2026'   IN ROLE rol_auditor;

-- Acceso a la base de datos y al esquema
REVOKE ALL ON DATABASE empleados_db FROM PUBLIC;
GRANT CONNECT ON DATABASE empleados_db TO rol_admin, rol_analista, rol_auditor;
REVOKE ALL ON SCHEMA rrhh FROM PUBLIC;
GRANT USAGE ON SCHEMA rrhh TO rol_admin, rol_analista, rol_auditor;
GRANT CREATE ON SCHEMA rrhh TO rol_admin;
GRANT CREATE ON TABLESPACE ts_datos, ts_historico, ts_indices, ts_auditoria TO rol_admin;

-- Administrador: todo, excepto modificar o borrar la bitácora
GRANT ALL ON ALL TABLES IN SCHEMA rrhh TO rol_admin;
GRANT ALL ON ALL SEQUENCES IN SCHEMA rrhh TO rol_admin;
REVOKE UPDATE, DELETE, TRUNCATE ON rrhh.auditoria_empleados FROM rol_admin;
ALTER DEFAULT PRIVILEGES FOR ROLE admin_empleados IN SCHEMA rrhh GRANT ALL ON TABLES TO rol_admin;
ALTER DEFAULT PRIVILEGES FOR ROLE admin_empleados IN SCHEMA rrhh GRANT ALL ON SEQUENCES TO rol_admin;

-- Analista: lectura de catálogos y de empleados SIN la columna salario
GRANT SELECT ON rrhh.departamentos, rrhh.roles_laborales TO rol_analista;
GRANT SELECT (id_empleado, nombre, apellido_paterno, apellido_materno, email,
              fecha_contratacion, id_departamento, id_rol, activo, nivel_clasificacion)
      ON rrhh.empleados TO rol_analista;
