INSERT INTO rrhh.departamentos (nombre, ubicacion, presupuesto_anual) VALUES ('Tecnología', 'CDMX', 5000000);
INSERT INTO rrhh.roles_laborales (nombre_rol, salario_min, salario_max) VALUES ('Analista de datos', 15000, 40000);
INSERT INTO rrhh.empleados (nombre, apellido_paterno, email, fecha_contratacion, salario, id_departamento, id_rol)
VALUES ('Ana', 'López', 'ana@ejemplo.com', '2022-03-15', 25000, 1, 1);
INSERT INTO rrhh.nomina (id_empleado, fecha_pago, salario_base) VALUES (1, '2023-06-30', 25000), (1, '2026-06-30', 25000);

SELECT tableoid::regclass AS particion, id_pago, id_empleado, fecha_pago FROM rrhh.nomina ORDER BY fecha_pago;

TRUNCATE rrhh.nomina, rrhh.empleados, rrhh.roles_laborales, rrhh.departamentos RESTART IDENTITY CASCADE;
