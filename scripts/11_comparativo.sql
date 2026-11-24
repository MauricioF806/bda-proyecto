-- 11_comparativo.sql: medición final y comparativo antes/después de la afinación (Fase 3)
-- Ejecutar como admin_empleados después de reiniciar el contenedor (10_parametros.sql).

\echo '=== Parámetros vigentes ==='
SELECT name, setting, unit, source
FROM pg_settings
WHERE name IN ('shared_buffers', 'work_mem', 'maintenance_work_mem', 'effective_cache_size',
               'random_page_cost', 'effective_io_concurrency')
ORDER BY name;

-- Estadísticas en cero: el advisor final evalúa solo la carga ejecutada con la configuración final
SELECT pg_stat_statements_reset();
SELECT pg_stat_reset();

\echo '=== Medición con parámetros ajustados ==='
SELECT * FROM dba.medir('4_parametros');

\echo '=== Comparativo de las cuatro etapas (porcentajes contra la línea base) ==='
SELECT q, etapa, costo, costo_vs_base_pct, tiempo_ms, tiempo_vs_base_pct, bloques_temp, operaciones
FROM dba.v_comparativo;

\echo '=== Plan final de la consulta 4 (la agregación ya no usa disco) ==='
SELECT * FROM dba.plan(4);

\echo '=== Advisor final ==='
\x auto
SELECT * FROM dba.v_advisor ORDER BY id_hallazgo;
\x off

\echo '=== Aplicando la recomendación de borrar índices sin uso ==='
SELECT * FROM dba.aplicar_recomendaciones('INDICE_SIN_USO');

\echo '=== Índices finales ==='
SELECT indice, tabla, tamano, lecturas FROM dba.v_indices WHERE indice LIKE 'idx_%' ORDER BY tabla, indice;
