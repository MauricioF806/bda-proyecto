-- 15_mantenimiento_automatico.sql: rutina de mantenimiento automático (Fase 4)
-- La ejecuta el contenedor empleados-mantenimiento cada MANTENIMIENTO_INTERVALO_SEG segundos
-- (equivalente a un job de DBMS_SCHEDULER). También se puede ejecutar a mano como admin_empleados.
--
-- Pasos:
--   1. Crea las particiones del año actual y del siguiente (y vacía DEFAULT si hace falta).
--   2. Mueve al tablespace histórico las particiones de años cerrados.
--   3. Retención (truncado): solo si se define MANTENIMIENTO_RETENCION_ANIOS en el contenedor.
--   4. Reconstruye las tablas fragmentadas (VACUUM FULL: reescribe la partición y sus índices).
--   5. Reconstruye en línea los índices poco densos (REINDEX CONCURRENTLY: no bloquea las consultas).
--   6. Muestra lo que hizo esta corrida.
-- Los pasos 4 y 5 se generan con \gexec porque VACUUM y REINDEX CONCURRENTLY no pueden
-- ejecutarse dentro de una función o procedimiento.

\set QUIET on
SELECT COALESCE(to_regprocedure('dba.sp_crear_particiones_futuras(integer)') IS NOT NULL
                AND to_regclass('dba.v_salud_tablas') IS NOT NULL, false) AS listo \gset
\set QUIET off

\if :listo
SELECT clock_timestamp() AS inicio_corrida \gset
\echo '--- Mantenimiento iniciado' :inicio_corrida

\echo '--- 1. Particiones futuras'
CALL dba.sp_crear_particiones_futuras(1);

\echo '--- 2. Ciclo de vida: años cerrados a ts_historico'
CALL dba.sp_mover_a_historico(1);

\echo '--- 3. Retención'
\getenv retencion MANTENIMIENTO_RETENCION_ANIOS
\if :{?retencion}
CALL dba.sp_retencion(:retencion, 'TRUNCAR');
\else
\echo '    (desactivada: no se definió MANTENIMIENTO_RETENCION_ANIOS)'
\endif

\echo '--- 4. Reconstrucción de tablas fragmentadas'
SELECT 'SELECT dba.marcar_inicio()',
       format('VACUUM (FULL, ANALYZE) %s', tabla),
       format('SELECT dba.registrar_mantenimiento(%L, %L, %L, %s)',
              'REBUILD_TABLA', tabla,
              format('%s%% libre + %s%% muertas', pct_libre, pct_muertas), bytes_total)
FROM dba.v_salud_tablas
WHERE requiere_rebuild
ORDER BY tabla \gexec

\echo '--- 5. Reconstrucción de índices poco densos'
SELECT 'SELECT dba.marcar_inicio()',
       format('REINDEX INDEX CONCURRENTLY %s', indice),
       format('SELECT dba.registrar_mantenimiento(%L, %L, %L, %s)',
              'REBUILD_INDICE', indice,
              format('densidad %s%%, fragmentación %s%%', densidad_hojas_pct, fragmentacion_pct), bytes)
FROM dba.v_salud_indices
WHERE requiere_rebuild
ORDER BY indice \gexec

\echo '--- 6. Operaciones de esta corrida'
SELECT operacion, objeto, detalle,
       pg_size_pretty(bytes_antes) AS antes, pg_size_pretty(bytes_despues) AS despues,
       round(100.0 * (bytes_despues - bytes_antes) / NULLIF(bytes_antes, 0), 1) AS cambio_pct,
       date_trunc('millisecond', duracion) AS duracion
FROM dba.bitacora_mantenimiento
WHERE fecha >= :'inicio_corrida'
ORDER BY id_operacion;

\echo '--- Alertas pendientes después del mantenimiento'
SELECT severidad, tipo, objeto, detalle FROM dba.v_alertas_almacenamiento;
\else
\echo 'Mantenimiento omitido: todavía no existen los objetos de la Fase 4 (ejecutar 12 y 13).'
\endif
