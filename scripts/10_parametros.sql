-- 10_parametros.sql: ajuste de parámetros críticos del servidor (Fase 3)
-- Ejecutar como admin_empleados después de 09_recrear_indices.sql.
-- Después hay que REINICIAR el contenedor (shared_buffers solo cambia al reiniciar) y ejecutar 11_comparativo.sql.
--
-- Sobre DB_BLOCK_SIZE: en Oracle se fija al crear la base. En PostgreSQL el equivalente es block_size
-- (8 kB), que se fija al COMPILAR el servidor; es de solo lectura y no se puede cambiar con la base creada.

\echo '=== Tamaño de bloque (equivalente a DB_BLOCK_SIZE, solo lectura) ==='
SELECT name, setting, unit, context FROM pg_settings WHERE name IN ('block_size', 'wal_block_size');

\echo '=== Parámetros antes del ajuste ==='
SELECT name, setting, unit, context, source
FROM pg_settings
WHERE name IN ('shared_buffers', 'work_mem', 'maintenance_work_mem', 'effective_cache_size',
               'random_page_cost', 'effective_io_concurrency')
ORDER BY name;

-- ALTER SYSTEM escribe en postgresql.auto.conf (equivalente a ALTER SYSTEM ... SCOPE=SPFILE en Oracle)
ALTER SYSTEM SET shared_buffers = '256MB';            -- caché de datos (context = postmaster: requiere reinicio)
ALTER SYSTEM SET work_mem = '32MB';                   -- memoria por operación de ordenamiento/hash (evita usar disco)
ALTER SYSTEM SET maintenance_work_mem = '256MB';      -- CREATE INDEX, VACUUM, REINDEX
ALTER SYSTEM SET effective_cache_size = '2GB';        -- cuánta caché (PostgreSQL + sistema operativo) supone el optimizador
ALTER SYSTEM SET random_page_cost = 1.1;              -- disco SSD: leer por índice cuesta casi lo mismo que en secuencia
ALTER SYSTEM SET effective_io_concurrency = 200;      -- lecturas concurrentes en SSD (bitmap heap scans)

SELECT pg_reload_conf();
SELECT pg_sleep(1);   -- la recarga es asíncrona: se espera a que el servidor relea la configuración

\echo '=== Parámetros después de recargar (pending_restart = t: falta reiniciar) ==='
SELECT name, setting, unit, pending_restart
FROM pg_settings
WHERE name IN ('shared_buffers', 'work_mem', 'maintenance_work_mem', 'effective_cache_size',
               'random_page_cost', 'effective_io_concurrency')
ORDER BY name;

\echo 'Siguiente paso: reiniciar el contenedor (docker restart empleados-postgres) y ejecutar 11_comparativo.sql'
