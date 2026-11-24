-- 07_advisor.sql: asesor de rendimiento (Fase 3)
-- PostgreSQL no trae un equivalente a DBA_ADVISOR_FINDINGS / DBA_ADVISOR_RECOMMENDATIONS.
-- Esta vista lo emula a partir de las estadísticas del servidor:
--   pg_catalog (llaves foráneas e índices), pg_stat_user_tables / pg_stat_user_indexes (uso real),
--   pg_stat_statements (consultas ejecutadas) y pg_settings (parámetros).
-- Cada fila es un hallazgo (FINDING) con su recomendación (RECOMMENDATION) lista para ejecutar.
-- Ejecutar como admin_empleados después de 06_mediciones_base.sql (necesita carga de trabajo medida).

CREATE OR REPLACE VIEW dba.v_advisor AS
WITH
-- Tablas del esquema rrhh agrupando las particiones bajo su tabla padre
tablas AS (
    SELECT COALESCE(i.inhparent, c.oid) AS tabla, c.oid AS relid, c.reltuples
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'rrhh'
    LEFT JOIN pg_inherits i ON i.inhrelid = c.oid
    WHERE c.relkind = 'r'
),
-- Llaves foráneas (en la tabla padre) cuyas columnas no encabezan ningún índice
fk_sin_indice AS (
    SELECT c.conrelid, c.conname, t.relname,
           string_agg(a.attname, ', ' ORDER BY k.ord) AS columnas,
           string_agg(a.attname, '_' ORDER BY k.ord) AS sufijo
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace AND n.nspname = 'rrhh'
    CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.contype = 'f' AND c.conparentid = 0
      AND NOT EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = c.conrelid AND i.indpred IS NULL
            AND (string_to_array(i.indkey::TEXT, ' ')::INT2[])[1:cardinality(c.conkey)] = c.conkey)
    GROUP BY c.conrelid, c.conname, t.relname
),
-- Uso de índices sumando las particiones bajo el índice padre
uso_indices AS (
    SELECT COALESCE(inh.inhparent, ui.indexrelid) AS indice,
           sum(ui.idx_scan) AS lecturas
    FROM pg_stat_user_indexes ui
    JOIN pg_index i ON i.indexrelid = ui.indexrelid
    LEFT JOIN pg_inherits inh ON inh.inhrelid = ui.indexrelid
    WHERE ui.schemaname = 'rrhh' AND NOT i.indisunique AND NOT i.indisprimary
    GROUP BY 1
),
hallazgos AS (
    -- 1. Llave foránea sin índice
    SELECT 1 AS prioridad, 'INDICE_FALTANTE' AS categoria, 'ALTA' AS severidad,
           f.conrelid::regclass::TEXT AS objeto,
           format('La llave foránea %s (%s) no tiene índice: los JOIN por esa columna y los borrados en la tabla referenciada recorren toda la tabla',
                  f.conname, f.columnas) AS hallazgo,
           format('CREATE INDEX idx_%s_%s ON %s (%s) TABLESPACE ts_indices',
                  f.relname, f.sufijo, f.conrelid::regclass, f.columnas) AS recomendacion
    FROM fk_sin_indice f

    UNION ALL
    -- 2. Tablas grandes leídas sobre todo por recorrido secuencial
    SELECT 2, 'ACCESO_SECUENCIAL', 'MEDIA', t.tabla::regclass::TEXT,
           format('%s recorridos secuenciales contra %s lecturas por índice sobre ~%s filas',
                  sum(s.seq_scan), COALESCE(sum(s.idx_scan), 0), round(sum(t.reltuples))),
           'Revisar los planes con dba.plan(n) y crear índices sobre las columnas de los filtros (WHERE) y de los JOIN'
    FROM tablas t
    JOIN pg_stat_user_tables s ON s.relid = t.relid
    GROUP BY t.tabla
    HAVING sum(t.reltuples) > 10000 AND sum(s.seq_scan) > COALESCE(sum(s.idx_scan), 0)

    UNION ALL
    -- 3. Índices que nadie usa (excepto los que sostienen una llave foránea)
    SELECT 3, 'INDICE_SIN_USO', 'MEDIA', u.indice::regclass::TEXT,
           'El índice no se ha usado desde que se reiniciaron las estadísticas: ocupa espacio y vuelve más lentos los INSERT/UPDATE',
           format('DROP INDEX %s', u.indice::regclass)
    FROM uso_indices u
    JOIN pg_index i ON i.indexrelid = u.indice
    WHERE u.lecturas = 0
      AND NOT EXISTS (
          -- un índice parcial (WHERE ...) no sirve a una llave foránea, así que no se protege
          SELECT 1 FROM pg_constraint c
          WHERE c.contype = 'f' AND c.conrelid = i.indrelid AND i.indpred IS NULL
            AND (string_to_array(i.indkey::TEXT, ' ')::INT2[])[1:cardinality(c.conkey)] = c.conkey)

    UNION ALL
    -- 4. Estadísticas del optimizador ausentes u obsoletas
    SELECT 4, 'ESTADISTICAS', 'MEDIA', c.oid::regclass::TEXT,
           CASE WHEN c.reltuples < 0 THEN 'La tabla nunca ha sido analizada: el optimizador estima a ciegas'
                ELSE format('%s filas modificadas desde el último ANALYZE (%s%% de la tabla)',
                            s.n_mod_since_analyze, round(100.0 * s.n_mod_since_analyze / greatest(c.reltuples, 1))) END,
           format('ANALYZE %s', c.oid::regclass)
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'rrhh'
    JOIN pg_stat_user_tables s ON s.relid = c.oid
    WHERE c.relkind = 'r'
      AND (c.reltuples < 0 AND s.n_live_tup > 0
           OR c.reltuples > 1000 AND s.n_mod_since_analyze > 0.1 * c.reltuples)

    UNION ALL
    -- 5. Consultas que desbordan a disco por falta de memoria de trabajo
    SELECT 5, 'PARAMETRO', 'ALTA', 'work_mem = ' || current_setting('work_mem'),
           format('Una consulta escribió %s bloques temporales a disco (%s ejecuciones): %s...',
                  ss.temp_blks_written, ss.calls, left(regexp_replace(ss.query, '\s+', ' ', 'g'), 70)),
           'ALTER SYSTEM SET work_mem = ''32MB''; SELECT pg_reload_conf();'
    FROM pg_stat_statements ss
    WHERE ss.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
      AND ss.temp_blks_written > 0 AND ss.query ILIKE '%rrhh.%'
      AND ss.query ~* '^\s*(SELECT|WITH|INSERT|UPDATE|DELETE)'  -- solo consultas, no EXPLAIN ni mantenimiento

    UNION ALL
    -- 6. Consultas más lentas (promedio > 50 ms)
    SELECT 6, 'CONSULTA_COSTOSA', 'BAJA', format('%s ms promedio, %s ejecuciones', round(ss.mean_exec_time::NUMERIC, 1), ss.calls),
           left(regexp_replace(ss.query, '\s+', ' ', 'g'), 120),
           'Revisar su plan con EXPLAIN (ANALYZE, BUFFERS) y aplicar las recomendaciones de índices'
    FROM pg_stat_statements ss
    WHERE ss.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
      AND ss.mean_exec_time > 50 AND ss.query ILIKE '%rrhh.%'
      AND ss.query ~* '^\s*(SELECT|WITH|INSERT|UPDATE|DELETE)'  -- solo consultas, no EXPLAIN ni mantenimiento

    UNION ALL
    -- 7. Parámetros de memoria y de costo con valores por omisión
    SELECT 7, 'PARAMETRO', 'MEDIA', 'shared_buffers = ' || current_setting('shared_buffers'),
           'La caché de datos tiene el tamaño por omisión (128MB); lo recomendado es ~25% de la RAM del servidor',
           'ALTER SYSTEM SET shared_buffers = ''256MB'';  -- requiere reiniciar el servidor'
    WHERE (SELECT setting::BIGINT FROM pg_settings WHERE name = 'shared_buffers') <= 16384
    UNION ALL
    SELECT 7, 'PARAMETRO', 'BAJA', 'random_page_cost = ' || current_setting('random_page_cost'),
           'El valor 4 supone discos mecánicos; en SSD sobreestima el costo de leer por índice y el optimizador prefiere recorridos secuenciales',
           'ALTER SYSTEM SET random_page_cost = 1.1; SELECT pg_reload_conf();'
    WHERE current_setting('random_page_cost')::NUMERIC >= 4
    UNION ALL
    SELECT 7, 'PARAMETRO', 'BAJA', 'maintenance_work_mem = ' || current_setting('maintenance_work_mem'),
           'Memoria baja para CREATE INDEX, VACUUM y REINDEX sobre tablas grandes',
           'ALTER SYSTEM SET maintenance_work_mem = ''256MB''; SELECT pg_reload_conf();'
    WHERE (SELECT setting::BIGINT FROM pg_settings WHERE name = 'maintenance_work_mem') < 131072
)
SELECT row_number() OVER (ORDER BY prioridad, objeto) AS id_hallazgo,
       categoria, severidad, objeto, hallazgo, recomendacion
FROM hallazgos;

-- Aplica automáticamente las recomendaciones de una categoría que se pueden ejecutar dentro
-- de una transacción (índices y estadísticas). Los parámetros se aplican a mano con ALTER SYSTEM,
-- porque ALTER SYSTEM no puede ejecutarse dentro de una función.
CREATE OR REPLACE FUNCTION dba.aplicar_recomendaciones(p_categoria TEXT)
RETURNS SETOF TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
BEGIN
    IF p_categoria NOT IN ('INDICE_FALTANTE', 'INDICE_SIN_USO', 'ESTADISTICAS') THEN
        RAISE EXCEPTION 'La categoría % no se aplica automáticamente', p_categoria;
    END IF;
    FOR r IN SELECT recomendacion FROM dba.v_advisor WHERE categoria = p_categoria ORDER BY id_hallazgo LOOP
        EXECUTE r.recomendacion;
        RETURN NEXT r.recomendacion;
    END LOOP;
END;
$$;

GRANT SELECT ON dba.v_advisor TO rol_admin;

\echo '=== Hallazgos y recomendaciones del advisor ==='
\x auto
SELECT * FROM dba.v_advisor ORDER BY id_hallazgo;
\x off
