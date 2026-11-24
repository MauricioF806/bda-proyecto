INSERT INTO rrhh.departamentos (nombre, ubicacion, presupuesto_anual) VALUES ('Tecnología', 'CDMX', 5000000);
INSERT INTO rrhh.roles_laborales (nombre_rol, salario_min, salario_max) VALUES ('Analista de datos', 15000, 40000);
INSERT INTO rrhh.empleados (nombre, apellido_paterno, email, fecha_contratacion, salario, id_departamento, id_rol)
VALUES ('Ana', 'López', 'ana@ejemplo.com', '2022-03-15', 25000, 1, 1);
INSERT INTO rrhh.nomina (id_empleado, fecha_pago, salario_base) VALUES (1, '2023-06-30', 25000), (1, '2026-06-30', 25000);

SELECT tableoid::regclass AS particion, id_pago, id_empleado, fecha_pago FROM rrhh.nomina ORDER BY fecha_pago;

-- Reparto por HASH de empleados: se agregan 19 empleados más y se cuentan por partición
INSERT INTO rrhh.empleados (nombre, apellido_paterno, email, fecha_contratacion, salario, id_departamento, id_rol)
SELECT 'Prueba' || g, 'Hash', 'prueba' || g || '@ejemplo.com', DATE '2024-01-01', 20000, 1, 1
FROM generate_series(1, 19) AS g;
SELECT tableoid::regclass AS particion, count(*) AS empleados FROM rrhh.empleados GROUP BY 1 ORDER BY 1;

TRUNCATE rrhh.nomina, rrhh.empleados, rrhh.roles_laborales, rrhh.departamentos RESTART IDENTITY CASCADE;
