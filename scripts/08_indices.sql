-- 08_indices.sql: aplicar las recomendaciones del advisor y medir el impacto (Fase 3)
-- Ejecutar como admin_empleados después de 07_advisor.sql.

\echo '=== Aplicando automáticamente los índices que recomendó el advisor (llaves foráneas) ==='
SELECT * FROM dba.aplicar_recomendaciones('INDICE_FALTANTE');

\echo '=== Índice adicional para el hallazgo de acceso secuencial en empleados (consulta 3 filtra por apellido) ==='
CREATE INDEX idx_empleados_apellido ON rrhh.empleados (apellido_paterno) TABLESPACE ts_indices;

ANALYZE rrhh.empleados;
ANALYZE rrhh.nomina;

\echo '=== Medición con índices simples ==='
SELECT * FROM dba.medir('2_indices_simples');

\echo '=== Comparativo contra la línea base ==='
SELECT q, etapa, costo, costo_vs_base_pct, tiempo_ms, tiempo_vs_base_pct, operaciones FROM dba.v_comparativo;

\echo '=== Plan de la consulta 3 con índices ==='
SELECT * FROM dba.plan(3);
