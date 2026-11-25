-- 02_prueba_particiones.sql: demuestra a qué partición va cada fila (Fase 1)
-- Todo corre dentro de una transacción que al final se deshace (ROLLBACK):
-- no borra ni deja datos, así que se puede ejecutar antes o después de la carga masiva.
-- Las filas de prueba usan nombres propios para no chocar con los datos existentes.
-- (Las secuencias sí avanzan: los id que se consumen aquí no se reutilizan, lo cual es normal.)

BEGIN;

INSERT INTO rrhh.departamentos (nombre, ubicacion, presupuesto_anual)
VALUES ('Prueba de particiones', 'CDMX', 1000000);
INSERT INTO rrhh.roles_laborales (nombre_rol, salario_min, salario_max)
VALUES ('Puesto de prueba de particiones', 15000, 40000);

-- 20 empleados de prueba: se reparten entre las 4 particiones HASH según su id_empleado
INSERT INTO rrhh.empleados (nombre, apellido_paterno, email, fecha_contratacion, salario, id_departamento, id_rol)
SELECT 'Prueba' || g, 'Particiones', 'prueba' || g || '@particiones.test', DATE '2022-03-15', 25000,
       (SELECT id_departamento FROM rrhh.departamentos WHERE nombre = 'Prueba de particiones'),
       (SELECT id_rol FROM rrhh.roles_laborales WHERE nombre_rol = 'Puesto de prueba de particiones')
FROM generate_series(1, 20) AS g;

-- Un pago por año para el primer empleado de prueba: cada uno cae en la partición RANGE de su año
INSERT INTO rrhh.nomina (id_empleado, fecha_pago, salario_base)
SELECT e.id_empleado, f.fecha, 25000
FROM rrhh.empleados e
CROSS JOIN (VALUES (DATE '2022-06-30'), (DATE '2023-06-30'), (DATE '2024-06-30'),
                   (DATE '2025-06-30'), (DATE '2026-06-30'), (DATE '2027-06-30'),
                   (DATE '2030-06-30')) AS f(fecha)          -- 2030 no tiene partición: va a DEFAULT
WHERE e.email = 'prueba1@particiones.test';

\echo '--- Nómina (RANGE por fecha_pago): cada pago en la partición de su año'
SELECT n.tableoid::regclass AS particion, n.fecha_pago, COALESCE(t.spcname, 'pg_default') AS tablespace
FROM rrhh.nomina n
JOIN rrhh.empleados e ON e.id_empleado = n.id_empleado
JOIN pg_class c ON c.oid = n.tableoid
LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
WHERE e.email = 'prueba1@particiones.test'
ORDER BY n.fecha_pago;

\echo '--- Empleados (HASH por id_empleado): reparto de los 20 empleados de prueba'
SELECT tableoid::regclass AS particion, count(*) AS empleados, string_agg(id_empleado::TEXT, ', ' ORDER BY id_empleado) AS ids
FROM rrhh.empleados
WHERE email LIKE '%@particiones.test'
GROUP BY 1
ORDER BY 1;

\echo '--- Poda de particiones: una consulta por fecha solo lee la partición de ese año'
EXPLAIN (COSTS OFF)
SELECT count(*) FROM rrhh.nomina WHERE fecha_pago BETWEEN DATE '2024-01-01' AND DATE '2024-12-31';

ROLLBACK;

\echo '--- Después del ROLLBACK no queda ningún dato de prueba'
SELECT count(*) AS empleados_de_prueba FROM rrhh.empleados WHERE email LIKE '%@particiones.test';
