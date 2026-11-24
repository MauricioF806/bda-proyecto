-- 05_carga_masiva.sql: carga masiva de datos simulados con PL/pgSQL (Fase 3)
-- Ejecutar como admin_empleados (dueño de las tablas). Reemplaza los datos de demostración.
-- Resultado: 12 departamentos, 15 puestos, 50,000 empleados y ~750,000 pagos de nómina.

CREATE OR REPLACE PROCEDURE rrhh.sp_carga_masiva(p_empleados INT DEFAULT 50000)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Catálogos de nombres para generar personas realistas
    v_nombres   TEXT[] := ARRAY['Ana','Luis','María','José','Carmen','Juan','Laura','Carlos','Sofía','Jorge',
                                'Lucía','Miguel','Elena','Pedro','Isabel','Fernando','Paula','Ricardo','Andrea','Diego',
                                'Valeria','Alejandro','Daniela','Roberto','Fernanda','Héctor','Gabriela','Raúl','Mariana','Óscar'];
    v_apellidos TEXT[] := ARRAY['García','Hernández','Martínez','López','González','Pérez','Rodríguez','Sánchez','Ramírez','Cruz',
                                'Flores','Gómez','Morales','Vázquez','Reyes','Jiménez','Torres','Díaz','Gutiérrez','Ruiz',
                                'Mendoza','Aguilar','Ortiz','Moreno','Castillo','Romero','Álvarez','Méndez','Chávez','Rivera',
                                'Juárez','Ramos','Domínguez','Herrera','Medina','Castro','Vargas','Guzmán','Velázquez','Rojas'];
    v_sal_min   NUMERIC[];
    v_sal_max   NUMERIC[];
    v_num_roles INT;
    v_num_deptos INT;
    v_rol       INT;
    v_nombre    TEXT;
    v_apellido  TEXT;
    v_azar      DOUBLE PRECISION;
    v_inicio    TIMESTAMPTZ := clock_timestamp();
    v_pagos     BIGINT;
BEGIN
    -- Semilla fija: cada ejecución genera exactamente los mismos datos (mediciones comparables)
    PERFORM setseed(0.42);

    -- La carga es una operación controlada del DBA: se apaga la auditoría por fila
    -- (si algo falla, el ROLLBACK la vuelve a dejar encendida porque ALTER TABLE es transaccional)
    ALTER TABLE rrhh.empleados DISABLE TRIGGER trg_auditar_empleados;
    ALTER TABLE rrhh.nomina    DISABLE TRIGGER trg_auditar_nomina;

    TRUNCATE rrhh.nomina, rrhh.empleados, rrhh.roles_laborales, rrhh.departamentos RESTART IDENTITY CASCADE;

    -- 1. Catálogos
    INSERT INTO rrhh.departamentos (nombre, ubicacion, presupuesto_anual) VALUES
        ('Tecnología','CDMX',12000000), ('Recursos Humanos','CDMX',4000000), ('Finanzas','Monterrey',8000000),
        ('Ventas','Guadalajara',9500000), ('Marketing','CDMX',6000000), ('Operaciones','Querétaro',11000000),
        ('Logística','Monterrey',7000000), ('Jurídico','CDMX',3500000), ('Compras','Puebla',3000000),
        ('Atención a Clientes','Mérida',5000000), ('Investigación y Desarrollo','CDMX',10000000), ('Calidad','León',2500000);

    INSERT INTO rrhh.roles_laborales (nombre_rol, descripcion, salario_min, salario_max) VALUES
        ('Auxiliar administrativo','Soporte administrativo',9000,15000),
        ('Asistente','Apoyo operativo',10000,17000),
        ('Analista junior','Análisis básico',15000,25000),
        ('Analista senior','Análisis avanzado',25000,40000),
        ('Desarrollador','Desarrollo de software',22000,45000),
        ('Ingeniero de datos','Plataformas de datos',30000,55000),
        ('Contador','Contabilidad',18000,32000),
        ('Abogado','Asesoría legal',25000,50000),
        ('Ejecutivo de ventas','Venta directa',12000,30000),
        ('Supervisor','Supervisión de equipos',25000,38000),
        ('Coordinador','Coordinación de proyectos',30000,48000),
        ('Gerente','Gerencia de área',45000,80000),
        ('Subdirector','Subdirección',70000,110000),
        ('Director','Dirección de área',100000,160000),
        ('Becario','Programa de becarios',6000,9000);

    SELECT array_agg(salario_min ORDER BY id_rol), array_agg(salario_max ORDER BY id_rol), count(*)
      INTO v_sal_min, v_sal_max, v_num_roles
      FROM rrhh.roles_laborales;
    SELECT count(*) INTO v_num_deptos FROM rrhh.departamentos;

    -- 2. Empleados: un INSERT por fila dentro de un ciclo PL/pgSQL
    FOR i IN 1 .. p_empleados LOOP
        v_rol      := 1 + floor(random() * v_num_roles)::INT;
        v_nombre   := v_nombres[1 + floor(random() * array_length(v_nombres, 1))::INT];
        v_apellido := v_apellidos[1 + floor(random() * array_length(v_apellidos, 1))::INT];
        v_azar     := random();

        INSERT INTO rrhh.empleados (nombre, apellido_paterno, apellido_materno, email, fecha_contratacion,
                                    salario, id_departamento, id_rol, activo, nivel_clasificacion)
        VALUES (v_nombre,
                v_apellido,
                v_apellidos[1 + floor(random() * array_length(v_apellidos, 1))::INT],
                translate(lower(v_nombre || '.' || v_apellido || '.' || i), 'áéíóúñ', 'aeioun') || '@empresa.mx',
                DATE '2010-01-01' + floor(random() * (DATE '2026-10-31' - DATE '2010-01-01'))::INT,
                round(v_sal_min[v_rol] + random()::NUMERIC * (v_sal_max[v_rol] - v_sal_min[v_rol]), 2),
                1 + floor(random() * v_num_deptos)::INT,
                v_rol,
                random() < 0.9,
                CASE WHEN v_azar < 0.6 THEN 1 WHEN v_azar < 0.9 THEN 2 ELSE 3 END);

        IF i % 10000 = 0 THEN
            RAISE NOTICE '% empleados insertados (% s)', i,
                round(extract(epoch FROM clock_timestamp() - v_inicio)::NUMERIC, 1);
        END IF;
    END LOOP;

    -- 3. Nómina: un pago por cierre de trimestre desde 2022 (o desde la contratación) hasta sep-2026.
    --    Se genera en una sola sentencia (orientada a conjuntos), mucho más rápida que fila por fila.
    INSERT INTO rrhh.nomina (id_empleado, fecha_pago, salario_base, bonos, deducciones)
    SELECT p.id_empleado,
           p.fecha_pago,
           p.salario_base,
           CASE WHEN random() < 0.3 THEN round(p.salario_base * random()::NUMERIC * 0.15, 2) ELSE 0 END,
           round(p.salario_base * (0.10 + random()::NUMERIC * 0.15), 2)
    FROM (SELECT e.id_empleado,
                 (g + INTERVAL '3 months - 1 day')::DATE AS fecha_pago,
                 -- salario de años anteriores: 5% menos por cada año hacia atrás
                 round(e.salario * power(0.95, 2026 - extract(YEAR FROM g)::INT), 2) AS salario_base
          FROM rrhh.empleados e
          CROSS JOIN LATERAL generate_series(
                 greatest(date_trunc('quarter', e.fecha_contratacion), DATE '2022-01-01'),
                 DATE '2026-07-01',
                 INTERVAL '3 months') AS g) AS p;
    GET DIAGNOSTICS v_pagos = ROW_COUNT;

    ALTER TABLE rrhh.empleados ENABLE TRIGGER trg_auditar_empleados;
    ALTER TABLE rrhh.nomina    ENABLE TRIGGER trg_auditar_nomina;

    -- Un solo registro en la bitácora que deja constancia de la carga
    INSERT INTO rrhh.auditoria_empleados (tabla_afectada, operacion, usuario_bd, datos_nuevos)
    VALUES ('empleados (carga masiva)', 'I', session_user,
            jsonb_build_object('empleados', p_empleados, 'pagos_nomina', v_pagos,
                               'segundos', round(extract(epoch FROM clock_timestamp() - v_inicio)::NUMERIC, 1)));

    RAISE NOTICE 'Carga terminada: % empleados, % pagos en % s', p_empleados, v_pagos,
        round(extract(epoch FROM clock_timestamp() - v_inicio)::NUMERIC, 1);
END;
$$;

\timing on
CALL rrhh.sp_carga_masiva(50000);

-- Estadísticas y mapa de visibilidad al día (necesarios para planes correctos y para index-only scans)
VACUUM (ANALYZE) rrhh.departamentos, rrhh.roles_laborales, rrhh.empleados, rrhh.nomina;
\timing off

\echo '--- Registros por tabla'
SELECT 'departamentos' AS tabla, count(*) FROM rrhh.departamentos
UNION ALL SELECT 'roles_laborales', count(*) FROM rrhh.roles_laborales
UNION ALL SELECT 'empleados', count(*) FROM rrhh.empleados
UNION ALL SELECT 'nomina', count(*) FROM rrhh.nomina;

\echo '--- Reparto por partición'
SELECT tableoid::regclass AS particion, count(*) AS filas FROM rrhh.empleados GROUP BY 1
UNION ALL
SELECT tableoid::regclass, count(*) FROM rrhh.nomina GROUP BY 1
ORDER BY 1;

\echo '--- Empleados por nivel de clasificación (MAC)'
SELECT nivel_clasificacion, count(*) FROM rrhh.empleados GROUP BY 1 ORDER BY 1;

\echo '--- La bitácora solo registra la carga como un evento'
SELECT id_auditoria, tabla_afectada, usuario_bd, datos_nuevos FROM rrhh.auditoria_empleados
ORDER BY id_auditoria DESC LIMIT 1;
