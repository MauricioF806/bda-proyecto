-- 12_monitoreo_almacenamiento.sql: monitoreo de tablespaces, archivos y particiones (Fase 4)
-- Ejecutar como admin_empleados (superusuario: lee el disco del servidor y usa pgstattuple).
-- Se puede ejecutar antes o después de la Fase 3; lo ideal es después de la carga masiva (05).
--
-- Equivalencias con Oracle:
--   DBA_TABLESPACES / DBA_DATA_FILES / DBA_FREE_SPACE  ->  dba.v_tablespaces
--   AUTOEXTEND ON MAXSIZE n                             ->  dba.cuotas_tablespace (límite lógico con alerta)
--   DBA_TAB_PARTITIONS                                  ->  dba.v_particiones
--   DBMS_SPACE / ANALYZE ... VALIDATE STRUCTURE         ->  dba.v_salud_tablas y dba.v_salud_indices (pgstattuple)
--   Alertas de espacio de Enterprise Manager            ->  dba.v_alertas_almacenamiento
--
-- En PostgreSQL los archivos de datos crecen solos (en segmentos de 1 GB) hasta llenar el disco:
-- no existe AUTOEXTEND ni MAXSIZE. Por eso el control se hace con cuotas lógicas por tablespace
-- y con el espacio libre real del disco, y los ajustes son mover particiones o ampliar la cuota.

CREATE EXTENSION IF NOT EXISTS pgstattuple;
CREATE SCHEMA IF NOT EXISTS dba;

-- Parámetros del monitoreo y del mantenimiento (se pueden ajustar sin tocar el código)
CREATE TABLE IF NOT EXISTS dba.config_almacenamiento (
    clave       TEXT PRIMARY KEY,
    valor       NUMERIC NOT NULL,
    descripcion TEXT NOT NULL
) TABLESPACE ts_datos;

INSERT INTO dba.config_almacenamiento (clave, valor, descripcion) VALUES
    ('umbral_disco_alerta_pct',     80, 'Porcentaje de disco usado a partir del cual hay alerta'),
    ('umbral_disco_critico_pct',    90, 'Porcentaje de disco usado a partir del cual es crítico'),
    ('umbral_rebuild_tabla_pct',    30, 'Espacio libre + filas muertas (%) a partir del cual una tabla se reconstruye'),
    ('umbral_densidad_indice_pct',  70, 'Densidad de hojas (%) por debajo de la cual un índice se reconstruye'),
    ('tamano_minimo_mb',             1, 'Tablas e índices más pequeños no se evalúan')
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION dba.config(p_clave TEXT) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT valor FROM dba.config_almacenamiento WHERE clave = p_clave
$$;

-- Cuota lógica por tablespace (equivalente a MAXSIZE de un datafile con AUTOEXTEND)
CREATE TABLE IF NOT EXISTS dba.cuotas_tablespace (
    tablespace          NAME PRIMARY KEY,
    cuota_mb            INT NOT NULL CHECK (cuota_mb > 0),
    umbral_alerta_pct   INT NOT NULL DEFAULT 80 CHECK (umbral_alerta_pct BETWEEN 1 AND 100)
) TABLESPACE ts_datos;

INSERT INTO dba.cuotas_tablespace (tablespace, cuota_mb) VALUES
    ('ts_datos', 512), ('ts_historico', 512), ('ts_indices', 512), ('ts_auditoria', 128)
ON CONFLICT (tablespace) DO NOTHING;

-- Bitácora de todas las operaciones de almacenamiento y mantenimiento
CREATE TABLE IF NOT EXISTS dba.bitacora_mantenimiento (
    id_operacion  BIGSERIAL PRIMARY KEY,
    fecha         TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    operacion     TEXT NOT NULL,
    objeto        TEXT NOT NULL,
    detalle       TEXT,
    bytes_antes   BIGINT,
    bytes_despues BIGINT,
    duracion      INTERVAL,
    usuario       TEXT NOT NULL DEFAULT session_user
) TABLESPACE ts_auditoria;

-- Marca el inicio de una operación que se ejecuta fuera de una función (VACUUM, REINDEX CONCURRENTLY)
CREATE OR REPLACE FUNCTION dba.marcar_inicio() RETURNS VOID
LANGUAGE sql AS $$
    SELECT set_config('dba.inicio_operacion', clock_timestamp()::TEXT, false)
$$;

-- Registra una operación. Si no se da el tamaño final, se mide el objeto; si no se da el inicio,
-- se usa el que dejó dba.marcar_inicio().
CREATE OR REPLACE FUNCTION dba.registrar_mantenimiento(
    p_operacion TEXT, p_objeto TEXT, p_detalle TEXT, p_bytes_antes BIGINT,
    p_bytes_despues BIGINT DEFAULT NULL, p_inicio TIMESTAMPTZ DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO dba.bitacora_mantenimiento (operacion, objeto, detalle, bytes_antes, bytes_despues, duracion)
    VALUES (p_operacion, p_objeto, p_detalle, p_bytes_antes,
            COALESCE(p_bytes_despues, pg_total_relation_size(to_regclass(p_objeto))),
            clock_timestamp() - COALESCE(p_inicio,
                                         NULLIF(current_setting('dba.inicio_operacion', true), '')::TIMESTAMPTZ,
                                         clock_timestamp()));
END;
$$;

-- Espacio total y libre del disco donde vive una ruta (lee "df" del servidor; solo superusuario).
-- Si quien consulta no tiene permiso, devuelve vacío en lugar de fallar.
CREATE OR REPLACE FUNCTION dba.espacio_disco(p_ruta TEXT)
RETURNS TABLE (total_bytes BIGINT, libre_bytes BIGINT)
LANGUAGE plpgsql AS $$
DECLARE
    v_campos TEXT[];
BEGIN
    -- Solo rutas absolutas simples: evita inyectar comandos en el "df"
    IF p_ruta IS NULL OR p_ruta !~ '^/[A-Za-z0-9_./-]*$' THEN
        RETURN;
    END IF;
    IF to_regclass('pg_temp.tmp_df') IS NULL THEN
        CREATE TEMP TABLE tmp_df (linea TEXT);
    END IF;
    TRUNCATE tmp_df;
    EXECUTE format('COPY tmp_df FROM PROGRAM %L', 'df -kP ' || p_ruta || ' | tail -n 1');
    SELECT regexp_split_to_array(linea, '\s+') INTO v_campos FROM tmp_df;
    total_bytes := v_campos[2]::BIGINT * 1024;
    libre_bytes := v_campos[4]::BIGINT * 1024;
    RETURN NEXT;
EXCEPTION WHEN OTHERS THEN
    RETURN;
END;
$$;
REVOKE EXECUTE ON FUNCTION dba.espacio_disco(TEXT) FROM PUBLIC;

-- Tablespaces: tamaño, cuota, disco y estado (equivalente a DBA_TABLESPACES + DBA_DATA_FILES + DBA_FREE_SPACE)
CREATE OR REPLACE VIEW dba.v_tablespaces AS
WITH ts AS (
    SELECT t.oid, t.spcname,
           CASE WHEN t.spcname = 'pg_default' THEN current_setting('data_directory')
                ELSE pg_tablespace_location(t.oid) END AS ruta,
           pg_tablespace_size(t.oid) AS bytes
    FROM pg_tablespace t
    WHERE t.spcname <> 'pg_global'
),
calc AS (
    SELECT ts.*,
           (SELECT count(*) FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname IN ('rrhh', 'dba', 'rrhh_archivo')
            WHERE c.relkind IN ('r', 'i')
              AND c.reltablespace = CASE WHEN ts.spcname = 'pg_default' THEN 0 ELSE ts.oid END) AS objetos,
           q.cuota_mb, q.umbral_alerta_pct,
           round(100.0 * ts.bytes / NULLIF(q.cuota_mb * 1048576.0, 0), 1) AS pct_cuota,
           d.total_bytes, d.libre_bytes,
           round(100.0 * (d.total_bytes - d.libre_bytes) / NULLIF(d.total_bytes, 0), 1) AS pct_disco
    FROM ts
    LEFT JOIN dba.cuotas_tablespace q ON q.tablespace = ts.spcname
    LEFT JOIN LATERAL dba.espacio_disco(ts.ruta) d ON true
)
SELECT spcname AS tablespace,
       ruta,
       objetos,
       pg_size_pretty(bytes) AS tamano,
       bytes,
       cuota_mb,
       pct_cuota,
       pg_size_pretty(libre_bytes) AS disco_libre,
       pct_disco AS pct_disco_usado,
       CASE WHEN pct_disco >= dba.config('umbral_disco_critico_pct') OR pct_cuota >= 100 THEN 'CRITICO'
            WHEN pct_disco >= dba.config('umbral_disco_alerta_pct') OR pct_cuota >= umbral_alerta_pct THEN 'ALERTA'
            ELSE 'OK' END AS estado
FROM calc
ORDER BY spcname;

-- Particiones de las tablas particionadas (equivalente a DBA_TAB_PARTITIONS)
CREATE OR REPLACE VIEW dba.v_particiones AS
SELECT p.parentrelid::regclass::TEXT AS tabla,
       c.relname AS particion,
       pg_get_expr(c.relpartbound, c.oid) AS limites,
       COALESCE(t.spcname, 'pg_default') AS tablespace,
       greatest(c.reltuples, 0)::BIGINT AS filas_estimadas,
       pg_size_pretty(pg_relation_size(c.oid)) AS tamano_datos,
       pg_size_pretty(pg_indexes_size(c.oid)) AS tamano_indices,
       pg_total_relation_size(c.oid) AS bytes_total,
       s.n_dead_tup AS filas_muertas,
       s.last_autovacuum
FROM pg_partition_tree('rrhh.nomina') p
JOIN pg_class c ON c.oid = p.relid
LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE p.isleaf
UNION ALL
SELECT p.parentrelid::regclass::TEXT, c.relname, pg_get_expr(c.relpartbound, c.oid),
       COALESCE(t.spcname, 'pg_default'), greatest(c.reltuples, 0)::BIGINT,
       pg_size_pretty(pg_relation_size(c.oid)), pg_size_pretty(pg_indexes_size(c.oid)),
       pg_total_relation_size(c.oid), s.n_dead_tup, s.last_autovacuum
FROM pg_partition_tree('rrhh.empleados') p
JOIN pg_class c ON c.oid = p.relid
LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE p.isleaf;

-- Salud física de las tablas: espacio libre y filas muertas dentro de los archivos (pgstattuple)
CREATE OR REPLACE VIEW dba.v_salud_tablas AS
SELECT c.oid::regclass::TEXT AS tabla,
       COALESCE(t.spcname, 'pg_default') AS tablespace,
       pg_size_pretty(pg_relation_size(c.oid)) AS tamano,
       pg_total_relation_size(c.oid) AS bytes_total,
       round(a.approx_free_percent::NUMERIC, 1) AS pct_libre,
       round(a.dead_tuple_percent::NUMERIC, 1) AS pct_muertas,
       (a.approx_free_percent + a.dead_tuple_percent) >= dba.config('umbral_rebuild_tabla_pct') AS requiere_rebuild
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'rrhh'
LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
CROSS JOIN LATERAL pgstattuple_approx(c.oid) a
WHERE c.relkind = 'r'
  AND pg_relation_size(c.oid) >= dba.config('tamano_minimo_mb') * 1048576;

-- Salud física de los índices B-tree: densidad de las hojas y fragmentación (pgstatindex)
CREATE OR REPLACE VIEW dba.v_salud_indices AS
SELECT ci.oid::regclass::TEXT AS indice,
       ct.oid::regclass::TEXT AS tabla,
       pg_size_pretty(pg_relation_size(ci.oid)) AS tamano,
       pg_relation_size(ci.oid) AS bytes,
       round(s.avg_leaf_density::NUMERIC, 1) AS densidad_hojas_pct,
       round(s.leaf_fragmentation::NUMERIC, 1) AS fragmentacion_pct,
       s.avg_leaf_density < dba.config('umbral_densidad_indice_pct') AS requiere_rebuild
FROM pg_index x
JOIN pg_class ci ON ci.oid = x.indexrelid
JOIN pg_class ct ON ct.oid = x.indrelid
JOIN pg_namespace n ON n.oid = ci.relnamespace AND n.nspname = 'rrhh'
JOIN pg_am am ON am.oid = ci.relam AND am.amname = 'btree'
CROSS JOIN LATERAL pgstatindex(ci.oid) s
WHERE ci.relkind = 'i'
  AND pg_relation_size(ci.oid) >= dba.config('tamano_minimo_mb') * 1048576;

-- Alertas de almacenamiento con la acción recomendada
CREATE OR REPLACE VIEW dba.v_alertas_almacenamiento AS
WITH anio AS (SELECT extract(YEAR FROM current_date)::INT AS actual),
default_nomina AS (
    SELECT count(*) AS filas, max(extract(YEAR FROM fecha_pago))::INT AS ultimo_anio
    FROM rrhh.nomina_default
)
-- 1. Tablespaces por encima de su cuota o con el disco casi lleno
SELECT CASE v.estado WHEN 'CRITICO' THEN 'ALTA' ELSE 'MEDIA' END AS severidad,
       'ESPACIO' AS tipo,
       v.tablespace AS objeto,
       format('Usa %s de una cuota de %s MB (%s%%); disco usado: %s%%',
              v.tamano, v.cuota_mb, v.pct_cuota, COALESCE(v.pct_disco_usado::TEXT, 'sin dato')) AS detalle,
       CASE WHEN v.tablespace = 'ts_datos'
            THEN 'CALL dba.sp_mover_a_historico(1);  -- o ampliar la cuota: UPDATE dba.cuotas_tablespace SET cuota_mb = '
                 || ceil(v.bytes / 1048576.0 * 1.5) || ' WHERE tablespace = ''ts_datos'';'
            ELSE format('UPDATE dba.cuotas_tablespace SET cuota_mb = %s WHERE tablespace = %L;  -- equivalente a AUTOEXTEND MAXSIZE',
                        ceil(v.bytes / 1048576.0 * 1.5), v.tablespace) END AS recomendacion
FROM dba.v_tablespaces v
WHERE v.estado <> 'OK'
UNION ALL
-- 2. Falta la partición del año siguiente: los pagos de ese año caerían en DEFAULT
SELECT 'ALTA', 'PARTICION', 'rrhh.nomina',
       format('No existe la partición nomina_%s', a.actual + 1),
       'CALL dba.sp_crear_particiones_futuras(1);'
FROM anio a
WHERE to_regclass('rrhh.nomina_' || (a.actual + 1)) IS NULL
UNION ALL
-- 3. Filas en la partición DEFAULT: hay que crear su partición y moverlas (equivalente a SPLIT PARTITION)
SELECT 'MEDIA', 'PARTICION', 'rrhh.nomina_default',
       format('%s filas en la partición DEFAULT (hasta el año %s)', d.filas, d.ultimo_anio),
       format('CALL dba.sp_crear_particiones_futuras(%s);', greatest(d.ultimo_anio - a.actual, 1))
FROM default_nomina d, anio a
WHERE d.filas > 0
UNION ALL
-- 4. Particiones de años cerrados que siguen en el tablespace de datos activos
SELECT 'BAJA', 'CICLO_DE_VIDA', p.particion,
       format('Partición de un año cerrado en %s (%s)', p.tablespace, pg_size_pretty(p.bytes_total)),
       'CALL dba.sp_mover_a_historico(1);'
FROM dba.v_particiones p, anio a
WHERE p.tabla = 'rrhh.nomina' AND p.tablespace <> 'ts_historico'
  AND p.particion ~ '^nomina_\d{4}$'
  AND substring(p.particion FROM 8)::INT <= a.actual - 1
UNION ALL
-- 5. Tablas fragmentadas: reconstruir (equivalente a ALTER TABLE ... MOVE)
SELECT 'MEDIA', 'FRAGMENTACION', s.tabla,
       format('%s%% de espacio libre y %s%% de filas muertas en %s', s.pct_libre, s.pct_muertas, s.tamano),
       format('VACUUM (FULL, ANALYZE) %s;', s.tabla)
FROM dba.v_salud_tablas s
WHERE s.requiere_rebuild
UNION ALL
-- 6. Índices con hojas poco densas: reconstruir (equivalente a ALTER INDEX ... REBUILD ONLINE)
SELECT 'MEDIA', 'FRAGMENTACION', i.indice,
       format('Densidad de hojas %s%% (fragmentación %s%%) en %s', i.densidad_hojas_pct, i.fragmentacion_pct, i.tamano),
       format('REINDEX INDEX CONCURRENTLY %s;', i.indice)
FROM dba.v_salud_indices i
WHERE i.requiere_rebuild;

\echo '=== Tablespaces (tamaño, cuota y disco) ==='
SELECT tablespace, ruta, objetos, tamano, cuota_mb, pct_cuota, disco_libre, pct_disco_usado, estado
FROM dba.v_tablespaces;

\echo '=== Particiones ==='
SELECT tabla, particion, limites, tablespace, filas_estimadas, tamano_datos, tamano_indices
FROM dba.v_particiones ORDER BY tabla, particion;

\echo '=== Salud de tablas (pgstattuple) ==='
SELECT * FROM dba.v_salud_tablas ORDER BY tabla;

\echo '=== Salud de índices (pgstatindex) ==='
SELECT indice, tabla, tamano, densidad_hojas_pct, fragmentacion_pct, requiere_rebuild
FROM dba.v_salud_indices ORDER BY tabla, indice;

\echo '=== Alertas de almacenamiento ==='
\x auto
SELECT * FROM dba.v_alertas_almacenamiento;
\x off
