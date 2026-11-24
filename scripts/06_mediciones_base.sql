-- 06_mediciones_base.sql: consultas complejas, medición automática y línea base sin índices (Fase 3)
-- Ejecutar como admin_empleados después de 05_carga_masiva.sql.
--
-- Equivalencias con Oracle:
--   EXPLAIN PLAN + DBMS_XPLAN.DISPLAY_CURSOR  ->  EXPLAIN (ANALYZE, BUFFERS)   (ver dba.plan(n))
--   costo del plan (COST)                     ->  "cost=..": costo total estimado del nodo raíz
--   tiempo real (A-Time)                      ->  "actual time" / "Execution Time"

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE SCHEMA IF NOT EXISTS dba;

-- Catálogo de las consultas que se miden en cada etapa
CREATE TABLE IF NOT EXISTS dba.consultas (
    id_consulta INT PRIMARY KEY,
    nombre      TEXT NOT NULL,
    objetivo    TEXT NOT NULL,
    sql         TEXT NOT NULL
) TABLESPACE ts_datos;

-- Resultado de cada medición: costo estimado, tiempo real, bloques leídos y plan completo
CREATE TABLE IF NOT EXISTS dba.mediciones (
    id_medicion    BIGSERIAL PRIMARY KEY,
    etapa          TEXT NOT NULL,
    id_consulta    INT NOT NULL REFERENCES dba.consultas,
    fecha          TIMESTAMPTZ NOT NULL DEFAULT now(),
    costo_estimado NUMERIC NOT NULL,
    tiempo_ms      NUMERIC NOT NULL,
    bloques_cache  BIGINT,
    bloques_disco  BIGINT,
    bloques_temp   BIGINT,
    operaciones    TEXT,
    plan           JSONB
) TABLESPACE ts_datos;

INSERT INTO dba.consultas (id_consulta, nombre, objetivo, sql) VALUES
(1, 'Nómina por departamento y trimestre 2025',
    'Agregación sobre ~190k pagos con JOIN de 3 tablas; muestra la poda de particiones (solo lee nomina_2025)',
 $q$SELECT d.nombre AS departamento,
       date_trunc('quarter', n.fecha_pago)::date AS trimestre,
       count(*) AS pagos,
       sum(n.salario_base + n.bonos - n.deducciones) AS neto_pagado
FROM rrhh.nomina n
JOIN rrhh.empleados e     ON e.id_empleado = n.id_empleado
JOIN rrhh.departamentos d ON d.id_departamento = e.id_departamento
WHERE n.fecha_pago >= DATE '2025-01-01' AND n.fecha_pago < DATE '2026-01-01'
GROUP BY d.nombre, date_trunc('quarter', n.fecha_pago)
ORDER BY d.nombre, trimestre$q$),
(2, 'Empleados por encima del promedio de su puesto en un departamento',
    'Filtro por departamento + función de ventana (AVG OVER PARTITION BY); se beneficia de un índice por departamento',
 $q$SELECT e.id_empleado, e.nombre, e.apellido_paterno, r.nombre_rol, e.salario,
       round(e.promedio_puesto, 2) AS promedio_puesto
FROM (SELECT x.*, avg(x.salario) OVER (PARTITION BY x.id_rol) AS promedio_puesto
      FROM rrhh.empleados x
      WHERE x.id_departamento = 7 AND x.activo) e
JOIN rrhh.roles_laborales r ON r.id_rol = e.id_rol
WHERE e.salario > e.promedio_puesto * 1.15
ORDER BY e.salario DESC$q$),
(3, 'Historial de pagos de una persona buscada por nombre',
    'Búsqueda selectiva por apellido y nombre + JOIN con nómina; sin índices recorre las ~750k filas de nómina',
 $q$SELECT e.id_empleado, e.nombre, e.apellido_paterno, e.email,
       n.fecha_pago, n.salario_base + n.bonos - n.deducciones AS neto
FROM rrhh.empleados e
JOIN rrhh.nomina n ON n.id_empleado = e.id_empleado
WHERE e.apellido_paterno = 'García' AND e.nombre = 'Ana'
ORDER BY e.id_empleado, n.fecha_pago DESC$q$),
(4, 'Top 20 de bonos acumulados desde 2024',
    'Agrupa ~50k empleados sobre ~400k pagos; sensible a work_mem (la agregación puede desbordarse a disco)',
 $q$SELECT e.id_empleado, e.nombre, e.apellido_paterno,
       sum(n.bonos) AS bonos_acumulados, count(*) AS pagos
FROM rrhh.nomina n
JOIN rrhh.empleados e ON e.id_empleado = n.id_empleado
WHERE n.fecha_pago >= DATE '2024-01-01'
GROUP BY e.id_empleado, e.nombre, e.apellido_paterno
ORDER BY bonos_acumulados DESC
LIMIT 20$q$)
ON CONFLICT (id_consulta) DO UPDATE
SET nombre = EXCLUDED.nombre, objetivo = EXCLUDED.objetivo, sql = EXCLUDED.sql;

-- Plan de ejecución real de una consulta (equivalente a DBMS_XPLAN.DISPLAY_CURSOR)
CREATE OR REPLACE FUNCTION dba.plan(p_id_consulta INT)
RETURNS SETOF TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_sql TEXT;
BEGIN
    SELECT sql INTO STRICT v_sql FROM dba.consultas WHERE id_consulta = p_id_consulta;
    RETURN QUERY EXECUTE 'EXPLAIN (ANALYZE, BUFFERS) ' || v_sql;
END;
$$;

-- Mide todas las consultas: una ejecución de calentamiento y p_repeticiones medidas (se promedia el tiempo).
-- Volver a medir una etapa reemplaza sus resultados anteriores.
CREATE OR REPLACE FUNCTION dba.medir(p_etapa TEXT, p_repeticiones INT DEFAULT 3)
RETURNS TABLE (consulta INT, costo_estimado NUMERIC, tiempo_ms NUMERIC, operaciones TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    c        RECORD;
    v_plan   JSONB;
    v_tiempo NUMERIC;
BEGIN
    -- Registrar también en pg_stat_statements las sentencias ejecutadas dentro de esta función
    PERFORM set_config('pg_stat_statements.track', 'all', true);
    DELETE FROM dba.mediciones m WHERE m.etapa = p_etapa;

    FOR c IN SELECT * FROM dba.consultas ORDER BY id_consulta LOOP
        EXECUTE c.sql;                               -- calentamiento (carga la caché)
        v_tiempo := 0;
        FOR i IN 1 .. p_repeticiones LOOP
            EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || c.sql INTO v_plan;
            v_tiempo := v_tiempo + (v_plan->0->>'Execution Time')::NUMERIC;
        END LOOP;

        INSERT INTO dba.mediciones (etapa, id_consulta, costo_estimado, tiempo_ms,
                                    bloques_cache, bloques_disco, bloques_temp, operaciones, plan)
        SELECT p_etapa, c.id_consulta,
               (v_plan->0->'Plan'->>'Total Cost')::NUMERIC,
               round(v_tiempo / p_repeticiones, 3),
               (v_plan->0->'Plan'->>'Shared Hit Blocks')::BIGINT,
               (v_plan->0->'Plan'->>'Shared Read Blocks')::BIGINT,
               (v_plan->0->'Plan'->>'Temp Written Blocks')::BIGINT,
               -- operaciones del plan: tipo de nodo y, si aplica, el índice usado
               (SELECT string_agg(DISTINCT nodo, ', ')
                FROM (SELECT n->>'Node Type' || COALESCE(' (' || (n->>'Index Name') || ')', '') AS nodo
                      FROM jsonb_path_query(v_plan, 'strict $.**') AS n
                      WHERE jsonb_typeof(n) = 'object' AND n ? 'Node Type'
                        AND n->>'Node Type' NOT IN ('Result', 'Append', 'Gather', 'Gather Merge')) AS t),
               v_plan;
    END LOOP;

    RETURN QUERY
    SELECT m.id_consulta, m.costo_estimado, m.tiempo_ms, m.operaciones
    FROM dba.mediciones m WHERE m.etapa = p_etapa ORDER BY m.id_consulta;
END;
$$;

-- Comparativo antes/después: cada etapa contra la primera etapa medida
CREATE OR REPLACE VIEW dba.v_comparativo AS
WITH base AS (
    SELECT DISTINCT ON (id_consulta) id_consulta, costo_estimado, tiempo_ms
    FROM dba.mediciones ORDER BY id_consulta, fecha
)
SELECT m.id_consulta AS q,
       m.etapa,
       round(m.costo_estimado, 1) AS costo,
       round(100.0 * (m.costo_estimado - b.costo_estimado) / NULLIF(b.costo_estimado, 0), 1) AS costo_vs_base_pct,
       round(m.tiempo_ms, 2) AS tiempo_ms,
       round(100.0 * (m.tiempo_ms - b.tiempo_ms) / NULLIF(b.tiempo_ms, 0), 1) AS tiempo_vs_base_pct,
       m.bloques_temp,
       m.operaciones
FROM dba.mediciones m
JOIN base b ON b.id_consulta = m.id_consulta
ORDER BY m.id_consulta, m.fecha;

-- Solo el administrador consulta estas herramientas
REVOKE ALL ON SCHEMA dba FROM PUBLIC;
GRANT USAGE ON SCHEMA dba TO rol_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA dba TO rol_admin;

-- Estadísticas de uso en cero: el advisor (07) analizará solo la carga de trabajo de estas mediciones
SELECT pg_stat_statements_reset();
SELECT pg_stat_reset();

\echo '=== Línea base: sin índices secundarios, parámetros por omisión ==='
SELECT * FROM dba.medir('1_sin_indices');

\echo '=== Planes de ejecución (equivalente a DBMS_XPLAN) ==='
\echo '--- Consulta 1'
SELECT * FROM dba.plan(1);
\echo '--- Consulta 2'
SELECT * FROM dba.plan(2);
\echo '--- Consulta 3'
SELECT * FROM dba.plan(3);
\echo '--- Consulta 4'
SELECT * FROM dba.plan(4);
