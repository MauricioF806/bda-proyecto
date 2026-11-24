-- 09_recrear_indices.sql: modificar y recrear índices, y evaluar su costo/beneficio (Fase 3)
-- Ejecutar como admin_empleados después de 08_indices.sql.

-- Vista de apoyo: tamaño de cada índice (sumando sus particiones) y cuántas veces se ha usado
CREATE OR REPLACE VIEW dba.v_indices AS
SELECT i.relname AS indice,
       t.relname AS tabla,
       pg_get_indexdef(i.oid) AS definicion,
       pg_size_pretty(sum(pg_relation_size(p.relid))) AS tamano,
       sum(pg_relation_size(p.relid)) AS bytes,
       COALESCE(sum(s.idx_scan), 0) AS lecturas
FROM pg_class i
JOIN pg_index x ON x.indexrelid = i.oid
JOIN pg_class t ON t.oid = x.indrelid
JOIN pg_namespace n ON n.oid = i.relnamespace AND n.nspname = 'rrhh'
CROSS JOIN LATERAL pg_partition_tree(i.oid) p
LEFT JOIN pg_stat_user_indexes s ON s.indexrelid = p.relid
WHERE i.relkind IN ('i', 'I') AND NOT EXISTS (SELECT 1 FROM pg_inherits h WHERE h.inhrelid = i.oid)
GROUP BY i.oid, i.relname, t.relname;
GRANT SELECT ON dba.v_indices TO rol_admin;

\echo '=== Índices antes de modificarlos ==='
SELECT indice, tabla, tamano, lecturas FROM dba.v_indices WHERE indice LIKE 'idx_%' ORDER BY tabla, indice;

-- 1. Apellido -> (apellido, nombre): la consulta 3 filtra por las dos columnas;
--    con el índice compuesto ya no hay que revisar a todos los "García" para encontrar a las "Ana".
DROP INDEX rrhh.idx_empleados_apellido;
CREATE INDEX idx_empleados_apellido_nombre ON rrhh.empleados (apellido_paterno, nombre) TABLESPACE ts_indices;

-- 2. Nómina por empleado -> (empleado, fecha DESC) + columnas incluidas (covering index):
--    devuelve los pagos ya ordenados y con los importes dentro del índice (index-only scan),
--    sin visitar la tabla. Sigue sirviendo a la llave foránea porque empieza por id_empleado.
DROP INDEX rrhh.idx_nomina_id_empleado;
CREATE INDEX idx_nomina_empleado_fecha ON rrhh.nomina (id_empleado, fecha_pago DESC)
    INCLUDE (salario_base, bonos, deducciones) TABLESPACE ts_indices;

-- 3. Departamento -> índice parcial y compuesto solo con empleados activos (la consulta 2 filtra activo):
--    más pequeño y ya agrupado por puesto. Se conserva idx_empleados_id_departamento para la llave foránea.
CREATE INDEX idx_empleados_depto_activos ON rrhh.empleados (id_departamento, id_rol)
    INCLUDE (salario) TABLESPACE ts_indices WHERE activo;

-- Mapa de visibilidad al día para permitir index-only scans
VACUUM (ANALYZE) rrhh.empleados, rrhh.nomina;

\echo '=== Medición con índices recreados ==='
SELECT * FROM dba.medir('3_indices_recreados');

\echo '=== Índices después de modificarlos (lecturas acumuladas) ==='
SELECT indice, tabla, tamano, lecturas FROM dba.v_indices WHERE indice LIKE 'idx_%' ORDER BY tabla, indice;

\echo '=== Comparativo ==='
SELECT q, etapa, costo, costo_vs_base_pct, tiempo_ms, tiempo_vs_base_pct, operaciones FROM dba.v_comparativo;

\echo '=== Plan de la consulta 3 con el índice compuesto y el covering index ==='
SELECT * FROM dba.plan(3);

\echo '=== Advisor después de los cambios ==='
\x auto
SELECT * FROM dba.v_advisor ORDER BY id_hallazgo;
\x off
