-- 13_ajustes_dinamicos.sql: ajustes dinámicos de almacenamiento y particiones (Fase 4)
-- Ejecutar como admin_empleados después de 12_monitoreo_almacenamiento.sql.
--
-- Procedimientos (equivalencias con Oracle):
--   dba.sp_crear_particiones_futuras(n)  ->  ALTER TABLE ... ADD PARTITION / SPLIT PARTITION (de DEFAULT)
--   dba.sp_mover_a_historico(n)          ->  ALTER TABLE ... MOVE PARTITION ... TABLESPACE (ciclo de vida, ILM)
--   dba.sp_retencion(n, modo)            ->  ALTER TABLE ... TRUNCATE PARTITION / EXCHANGE PARTITION (archivo)
--   UPDATE dba.cuotas_tablespace         ->  ALTER DATABASE DATAFILE ... AUTOEXTEND ON MAXSIZE n

-- Crea las particiones de nómina desde el año actual hasta n años adelante.
-- Si la partición DEFAULT ya tiene pagos de ese año, los mueve a la partición nueva
-- (PostgreSQL no permite crear una partición cuyas filas ya estén en DEFAULT).
CREATE OR REPLACE PROCEDURE dba.sp_crear_particiones_futuras(p_anios INT DEFAULT 1)
LANGUAGE plpgsql
AS $$
DECLARE
    v_actual INT := extract(YEAR FROM current_date)::INT;
    v_nombre TEXT;
    v_desde  DATE;
    v_hasta  DATE;
    v_filas  BIGINT;
    v_inicio TIMESTAMPTZ;
BEGIN
    FOR v_anio IN v_actual .. v_actual + p_anios LOOP
        v_nombre := 'nomina_' || v_anio;
        CONTINUE WHEN to_regclass('rrhh.' || v_nombre) IS NOT NULL;

        v_inicio := clock_timestamp();
        v_desde  := make_date(v_anio, 1, 1);
        v_hasta  := make_date(v_anio + 1, 1, 1);
        SELECT count(*) INTO v_filas FROM rrhh.nomina_default
        WHERE fecha_pago >= v_desde AND fecha_pago < v_hasta;

        IF v_filas = 0 THEN
            EXECUTE format('CREATE TABLE rrhh.%I PARTITION OF rrhh.nomina FOR VALUES FROM (%L) TO (%L) TABLESPACE ts_datos',
                           v_nombre, v_desde, v_hasta);
        ELSE
            -- "SPLIT" de la partición DEFAULT: se separa, se crea la partición nueva con sus filas y se vuelven a unir.
            -- Mientras están separadas no tienen el trigger de auditoría: mover filas no es un cambio de datos.
            ALTER TABLE rrhh.nomina DETACH PARTITION rrhh.nomina_default;
            EXECUTE format('CREATE TABLE rrhh.%I (LIKE rrhh.nomina INCLUDING DEFAULTS INCLUDING CONSTRAINTS) TABLESPACE ts_datos',
                           v_nombre);
            EXECUTE format('INSERT INTO rrhh.%I SELECT * FROM rrhh.nomina_default WHERE fecha_pago >= %L AND fecha_pago < %L',
                           v_nombre, v_desde, v_hasta);
            DELETE FROM rrhh.nomina_default WHERE fecha_pago >= v_desde AND fecha_pago < v_hasta;
            EXECUTE format('ALTER TABLE rrhh.nomina ATTACH PARTITION rrhh.%I FOR VALUES FROM (%L) TO (%L)',
                           v_nombre, v_desde, v_hasta);
            ALTER TABLE rrhh.nomina ATTACH PARTITION rrhh.nomina_default DEFAULT;
        END IF;

        PERFORM dba.registrar_mantenimiento('CREAR_PARTICION', 'rrhh.' || v_nombre,
            format('FROM %s TO %s; %s filas movidas desde DEFAULT', v_desde, v_hasta, v_filas),
            0, NULL, v_inicio);
        RAISE NOTICE 'Partición rrhh.% creada (% filas movidas desde DEFAULT)', v_nombre, v_filas;
    END LOOP;
END;
$$;

-- Mueve al tablespace histórico las particiones de nómina con al menos n años de antigüedad.
-- La tabla se reescribe en el tablespace nuevo; sus índices se quedan en ts_indices.
CREATE OR REPLACE PROCEDURE dba.sp_mover_a_historico(p_anios_antiguedad INT DEFAULT 1)
LANGUAGE plpgsql
AS $$
DECLARE
    r        RECORD;
    v_inicio TIMESTAMPTZ;
    v_bytes  BIGINT;
BEGIN
    FOR r IN
        SELECT c.oid::regclass::TEXT AS particion, COALESCE(t.spcname, 'pg_default') AS tablespace
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        LEFT JOIN pg_tablespace t ON t.oid = c.reltablespace
        WHERE i.inhparent = 'rrhh.nomina'::regclass
          AND c.relname ~ '^nomina_\d{4}$'
          AND substring(c.relname FROM 8)::INT <= extract(YEAR FROM current_date)::INT - p_anios_antiguedad
          AND COALESCE(t.spcname, 'pg_default') <> 'ts_historico'
        ORDER BY c.relname
    LOOP
        v_inicio := clock_timestamp();
        v_bytes  := pg_relation_size(r.particion);
        EXECUTE format('ALTER TABLE %s SET TABLESPACE ts_historico', r.particion);
        PERFORM dba.registrar_mantenimiento('MOVER_A_HISTORICO', r.particion,
            format('%s -> ts_historico', r.tablespace), v_bytes, pg_relation_size(r.particion), v_inicio);
        RAISE NOTICE 'Partición % movida de % a ts_historico', r.particion, r.tablespace;
    END LOOP;
END;
$$;

-- Política de retención: conserva los últimos n años de nómina (contando el actual).
--   'TRUNCAR'  vacía las particiones más antiguas (los datos se pierden; la partición queda vacía).
--   'ARCHIVAR' las separa de la tabla y las guarda en el esquema rrhh_archivo (siguen consultables).
-- Deja constancia en la bitácora de mantenimiento y en la bitácora de auditoría.
CREATE OR REPLACE PROCEDURE dba.sp_retencion(p_anios_conservar INT, p_modo TEXT DEFAULT 'ARCHIVAR')
LANGUAGE plpgsql
AS $$
DECLARE
    r        RECORD;
    v_filas  BIGINT;
    v_bytes  BIGINT;
    v_inicio TIMESTAMPTZ;
BEGIN
    IF p_modo NOT IN ('TRUNCAR', 'ARCHIVAR') THEN
        RAISE EXCEPTION 'Modo % no válido: use TRUNCAR o ARCHIVAR', p_modo;
    END IF;
    IF p_anios_conservar < 1 THEN
        RAISE EXCEPTION 'Hay que conservar al menos 1 año';
    END IF;

    FOR r IN
        SELECT c.relname, c.oid::regclass::TEXT AS particion
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = 'rrhh.nomina'::regclass
          AND c.relname ~ '^nomina_\d{4}$'
          AND substring(c.relname FROM 8)::INT <= extract(YEAR FROM current_date)::INT - p_anios_conservar
        ORDER BY c.relname
    LOOP
        EXECUTE format('SELECT count(*) FROM %s', r.particion) INTO v_filas;
        CONTINUE WHEN v_filas = 0;          -- ya se había truncado
        v_inicio := clock_timestamp();
        v_bytes  := pg_total_relation_size(r.particion);

        IF p_modo = 'TRUNCAR' THEN
            EXECUTE format('TRUNCATE %s', r.particion);
            PERFORM dba.registrar_mantenimiento('RETENCION_TRUNCAR', r.particion,
                format('%s filas eliminadas (retención de %s años)', v_filas, p_anios_conservar), v_bytes, NULL, v_inicio);
        ELSE
            CREATE SCHEMA IF NOT EXISTS rrhh_archivo;
            EXECUTE format('ALTER TABLE rrhh.nomina DETACH PARTITION %s', r.particion);
            EXECUTE format('ALTER TABLE %s SET SCHEMA rrhh_archivo', r.particion);
            EXECUTE format('ALTER TABLE rrhh_archivo.%I SET TABLESPACE ts_historico', r.relname);
            PERFORM dba.registrar_mantenimiento('RETENCION_ARCHIVAR', 'rrhh_archivo.' || r.relname,
                format('%s filas archivadas fuera de rrhh.nomina (retención de %s años)', v_filas, p_anios_conservar),
                v_bytes, NULL, v_inicio);
        END IF;

        -- TRUNCATE y DETACH no disparan el trigger por fila: se registra el evento a mano
        INSERT INTO rrhh.auditoria_empleados (tabla_afectada, operacion, usuario_bd, datos_anteriores)
        VALUES (r.relname || ' (retención ' || lower(p_modo) || ')', 'D', session_user,
                jsonb_build_object('filas', v_filas, 'anios_conservados', p_anios_conservar));
        RAISE NOTICE '% %: % filas', p_modo, r.particion, v_filas;
    END LOOP;
END;
$$;

-- ============================ Demostración ============================

\echo '=== 1. Cuota como AUTOEXTEND MAXSIZE: se reduce la cuota de ts_datos para provocar la alerta ==='
UPDATE dba.cuotas_tablespace SET cuota_mb = 30 WHERE tablespace = 'ts_datos';
SELECT tablespace, tamano, cuota_mb, pct_cuota, estado FROM dba.v_tablespaces WHERE tablespace = 'ts_datos';
SELECT severidad, tipo, objeto, detalle, recomendacion FROM dba.v_alertas_almacenamiento WHERE tipo IN ('ESPACIO', 'CICLO_DE_VIDA');

\echo '=== 2. Ajuste: mover las particiones de años cerrados al tablespace histórico ==='
CALL dba.sp_mover_a_historico(1);
SELECT tablespace, tamano, cuota_mb, pct_cuota, estado FROM dba.v_tablespaces WHERE tablespace IN ('ts_datos', 'ts_historico');
SELECT particion, tablespace, tamano_datos FROM dba.v_particiones WHERE tabla = 'rrhh.nomina' ORDER BY particion;

\echo '=== 3. Ajuste: ampliar la cuota (equivalente a subir MAXSIZE) y volver al valor normal ==='
UPDATE dba.cuotas_tablespace SET cuota_mb = 512 WHERE tablespace = 'ts_datos';
SELECT tablespace, tamano, cuota_mb, pct_cuota, estado FROM dba.v_tablespaces WHERE tablespace = 'ts_datos';

\echo '=== 4. Un pago de un año sin partición cae en DEFAULT y genera alerta ==='
INSERT INTO rrhh.nomina (id_empleado, fecha_pago, salario_base)
SELECT min(id_empleado), make_date(extract(YEAR FROM current_date)::INT + 2, 1, 15), 25000 FROM rrhh.empleados;
SELECT severidad, tipo, objeto, detalle, recomendacion FROM dba.v_alertas_almacenamiento WHERE tipo = 'PARTICION';

\echo '=== 5. Ajuste: crear las particiones futuras; el pago sale de DEFAULT a su partición nueva ==='
CALL dba.sp_crear_particiones_futuras(2);
SELECT n.tableoid::regclass AS particion, n.fecha_pago FROM rrhh.nomina n
WHERE n.fecha_pago >= make_date(extract(YEAR FROM current_date)::INT + 2, 1, 1);
SELECT particion, limites, tablespace FROM dba.v_particiones WHERE tabla = 'rrhh.nomina' ORDER BY particion;
SELECT count(*) AS alertas_de_particion FROM dba.v_alertas_almacenamiento WHERE tipo = 'PARTICION';
-- Se borra el pago de prueba (queda registrado en la bitácora de auditoría)
DELETE FROM rrhh.nomina WHERE fecha_pago >= make_date(extract(YEAR FROM current_date)::INT + 2, 1, 1);

\echo '=== 6. Retención con truncado (dentro de una transacción que se deshace: en PostgreSQL TRUNCATE es transaccional) ==='
BEGIN;
SELECT particion, filas_estimadas, tamano_datos FROM dba.v_particiones
WHERE tabla = 'rrhh.nomina' AND particion ~ '^nomina_\d{4}$' ORDER BY particion LIMIT 2;
CALL dba.sp_retencion(4, 'TRUNCAR');       -- conserva 4 años: vacía los anteriores
SELECT operacion, objeto, detalle, pg_size_pretty(bytes_antes) AS antes, pg_size_pretty(bytes_despues) AS despues
FROM dba.bitacora_mantenimiento WHERE operacion = 'RETENCION_TRUNCAR';
SELECT tabla_afectada, operacion, usuario_bd, datos_anteriores FROM rrhh.auditoria_empleados
WHERE tabla_afectada LIKE '%retención%';
ROLLBACK;
SELECT particion, filas_estimadas, tamano_datos FROM dba.v_particiones
WHERE tabla = 'rrhh.nomina' AND particion ~ '^nomina_\d{4}$' ORDER BY particion LIMIT 2;

\echo '=== 7. Retención con archivado: la partición sale de la tabla activa pero se conserva, y se reintegra ==='
CALL dba.sp_retencion(4, 'ARCHIVAR');
SELECT schemaname, tablename, tablespace FROM pg_tables WHERE schemaname = 'rrhh_archivo';
SELECT count(*) AS pagos_activos FROM rrhh.nomina;
-- Reintegrar lo archivado (equivalente a EXCHANGE PARTITION de vuelta)
DO $$
DECLARE
    r      RECORD;
    v_anio INT;
BEGIN
    FOR r IN SELECT tablename FROM pg_tables WHERE schemaname = 'rrhh_archivo' AND tablename ~ '^nomina_\d{4}$' LOOP
        v_anio := substring(r.tablename FROM 8)::INT;
        EXECUTE format('ALTER TABLE rrhh_archivo.%I SET SCHEMA rrhh', r.tablename);
        EXECUTE format('ALTER TABLE rrhh.nomina ATTACH PARTITION rrhh.%I FOR VALUES FROM (%L) TO (%L)',
                       r.tablename, make_date(v_anio, 1, 1), make_date(v_anio + 1, 1, 1));
        RAISE NOTICE 'Partición rrhh.% reintegrada', r.tablename;
    END LOOP;
END;
$$;
SELECT count(*) AS pagos_activos_tras_reintegrar FROM rrhh.nomina;

\echo '=== Bitácora de mantenimiento ==='
SELECT id_operacion, operacion, objeto, detalle, pg_size_pretty(bytes_antes) AS antes,
       pg_size_pretty(bytes_despues) AS despues, duracion
FROM dba.bitacora_mantenimiento ORDER BY id_operacion;
