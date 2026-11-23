-- Datos de demostración para las pruebas de seguridad (se reemplazarán con la carga masiva)
TRUNCATE rrhh.nomina, rrhh.empleados, rrhh.roles_laborales, rrhh.departamentos,
         rrhh.auditoria_empleados RESTART IDENTITY CASCADE;

INSERT INTO rrhh.departamentos (nombre, ubicacion, presupuesto_anual) VALUES
    ('Tecnología', 'CDMX', 5000000), ('Recursos Humanos', 'CDMX', 2000000), ('Finanzas', 'Monterrey', 3500000);

INSERT INTO rrhh.roles_laborales (nombre_rol, salario_min, salario_max) VALUES
    ('Analista de datos', 15000, 40000), ('Gerente', 40000, 90000), ('Auxiliar', 8000, 15000);

INSERT INTO rrhh.empleados (nombre, apellido_paterno, apellido_materno, email, fecha_contratacion,
                            salario, id_departamento, id_rol, nivel_clasificacion) VALUES
    ('Ana',    'López',    'Ruiz', 'ana.lopez@demo.mx',      '2022-03-15', 25000, 1, 1, 1),
    ('Luis',   'Martínez', 'Soto', 'luis.martinez@demo.mx',  '2023-07-01', 32000, 1, 1, 1),
    ('Marta',  'Pérez',    'Gil',  'marta.perez@demo.mx',    '2021-01-10', 48000, 2, 2, 2),
    ('Carlos', 'Díaz',     'Vega', 'carlos.diaz@demo.mx',    '2020-09-20', 52000, 3, 2, 2),
    ('Sofía',  'Ramírez',  'Cruz', 'sofia.ramirez@demo.mx',  '2019-05-05', 85000, 3, 2, 3),
    ('Jorge',  'Herrera',  'Mora', 'jorge.herrera@demo.mx',  '2018-11-30', 90000, 2, 2, 3);

INSERT INTO rrhh.nomina (id_empleado, fecha_pago, salario_base, bonos)
SELECT e.id_empleado, p.fecha, e.salario, p.bono
FROM rrhh.empleados e
JOIN (VALUES ('ana.lopez@demo.mx',     DATE '2023-06-30', 0),
             ('ana.lopez@demo.mx',     DATE '2026-06-30', 1500),
             ('luis.martinez@demo.mx', DATE '2024-12-15', 3000),
             ('marta.perez@demo.mx',   DATE '2025-05-31', 0)) AS p(email, fecha, bono)
  ON p.email = e.email;

SELECT count(*) AS empleados_cargados FROM rrhh.empleados;
