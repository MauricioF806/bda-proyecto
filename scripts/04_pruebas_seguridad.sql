-- Pruebas de acceso, modificación y auditoría (se ejecuta como superusuario y cambia de rol con SET ROLE)

\echo '=== 1. Analista nivel 1: DAC sobre columnas y MAC sobre filas ==='
SET ROLE usr_analista1;
SELECT current_user AS usuario, rrhh.nivel_actual() AS nivel_autorizacion;
\echo '--- SELECT * debe fallar, porque la columna salario no esta autorizada'
SELECT * FROM rrhh.empleados;
\echo '--- Columnas autorizadas: solo se ven filas con nivel menor o igual a 1'
SELECT id_empleado, nombre, apellido_paterno, nivel_clasificacion FROM rrhh.empleados ORDER BY id_empleado;
\echo '--- Modificaciones y acceso a nomina denegados'
UPDATE rrhh.empleados SET activo = FALSE WHERE email = 'ana.lopez@demo.mx';
INSERT INTO rrhh.departamentos (nombre) VALUES ('Intruso');
SELECT * FROM rrhh.nomina;
RESET ROLE;

\echo '=== 2. Analista nivel 2: mismas columnas, mas filas visibles ==='
SET ROLE usr_analista2;
SELECT current_user AS usuario, rrhh.nivel_actual() AS nivel_autorizacion;
SELECT id_empleado, nombre, apellido_paterno, nivel_clasificacion FROM rrhh.empleados ORDER BY id_empleado;
RESET ROLE;

\echo '=== 3. Administrador: acceso total, modificaciones auditadas y bitacora protegida ==='
SET ROLE usr_admin;
SELECT current_user AS usuario;
SELECT count(*) AS empleados_visibles FROM rrhh.empleados;
SELECT nombre, apellido_paterno, salario, nivel_clasificacion FROM rrhh.empleados ORDER BY id_empleado;
INSERT INTO rrhh.empleados (nombre, apellido_paterno, email, fecha_contratacion, salario, id_departamento, id_rol, nivel_clasificacion)
VALUES ('Temporal', 'Prueba', 'temporal@demo.mx', '2026-11-22', 20000, 1, 1, 1);
UPDATE rrhh.empleados SET salario = salario * 1.10 WHERE email = 'ana.lopez@demo.mx';
DELETE FROM rrhh.empleados WHERE email = 'temporal@demo.mx';
\echo '--- Intentos de alterar la bitacora (deben fallar)'
DELETE FROM rrhh.auditoria_empleados;
UPDATE rrhh.auditoria_empleados SET usuario_bd = 'otro';
DELETE FROM rrhh.v_auditoria_empleados;
RESET ROLE;

\echo '=== 4. Auditor: sin acceso a datos, lectura de la bitacora solo por la vista ==='
SET ROLE usr_auditor;
SELECT current_user AS usuario;
SELECT * FROM rrhh.empleados;
SELECT * FROM rrhh.auditoria_empleados;
INSERT INTO rrhh.departamentos (nombre) VALUES ('Intruso');
SELECT id_auditoria, usuario_bd, operacion, id_empleado,
       datos_anteriores->>'salario' AS salario_anterior,
       datos_nuevos->>'salario' AS salario_nuevo
FROM rrhh.v_auditoria_empleados
WHERE usuario_bd = 'usr_admin'
ORDER BY id_auditoria;
RESET ROLE;
