-- 06_endurecimiento.sql: cierra huecos de la auditoría

-- 1. El administrador no puede saltarse el trigger ni manipular la bitácora
--    TRUNCATE no dispara triggers por fila: vaciaría las tablas sin dejar rastro.
REVOKE TRUNCATE ON rrhh.empleados, rrhh.nomina FROM rol_admin;
--    Sin INSERT no puede fabricar registros falsos (el trigger escribe como dueño de la función).
REVOKE INSERT, REFERENCES ON rrhh.auditoria_empleados FROM rol_admin;
--    Sin TRIGGER no puede crear un trigger que descarte los registros de la bitácora.
REVOKE TRIGGER ON ALL TABLES IN SCHEMA rrhh FROM rol_admin;
ALTER DEFAULT PRIVILEGES FOR ROLE admin_empleados IN SCHEMA rrhh REVOKE TRIGGER ON TABLES FROM rol_admin;

-- 2. Más contexto en cada registro: usuario de la sesión e IP de origen
ALTER TABLE rrhh.auditoria_empleados
    ADD COLUMN usuario_sesion TEXT NOT NULL DEFAULT session_user,
    ADD COLUMN ip_cliente     INET DEFAULT inet_client_addr();

-- 3. Trigger SECURITY DEFINER: escribe en la bitácora con los permisos del dueño,
--    así ningún usuario necesita INSERT sobre ella.
--    Dentro de SECURITY DEFINER, current_user es el dueño de la función, por eso el
--    usuario real se toma del SET ROLE vigente o, si no hay, de session_user.
--    TG_ARGV[0] da el nombre lógico de la tabla (TG_TABLE_NAME devolvería la partición).
CREATE OR REPLACE FUNCTION rrhh.fn_auditar_empleados()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, rrhh
AS $$
DECLARE
    v_usuario TEXT := CASE WHEN current_setting('role') = 'none'
                           THEN session_user::text
                           ELSE current_setting('role') END;
BEGIN
    INSERT INTO rrhh.auditoria_empleados
           (tabla_afectada, operacion, usuario_bd, datos_anteriores, datos_nuevos)
    VALUES (COALESCE(TG_ARGV[0], 'empleados'), left(TG_OP, 1), v_usuario,
            CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) END);
    RETURN NULL;
END;
$$;

-- 4. Auditar también la nómina (cambios de salario, bonos y deducciones)
CREATE TRIGGER trg_auditar_nomina
AFTER INSERT OR UPDATE OR DELETE ON rrhh.nomina
FOR EACH ROW EXECUTE FUNCTION rrhh.fn_auditar_empleados('nomina');

-- 5. La vista expone las columnas nuevas (se agregan al final; los permisos se conservan)
CREATE OR REPLACE VIEW rrhh.v_auditoria_empleados AS
SELECT id_auditoria,
       fecha_evento,
       usuario_bd,
       CASE operacion WHEN 'I' THEN 'INSERT' WHEN 'U' THEN 'UPDATE' WHEN 'D' THEN 'DELETE' END AS operacion,
       COALESCE(datos_nuevos->>'id_empleado', datos_anteriores->>'id_empleado') AS id_empleado,
       datos_anteriores,
       datos_nuevos,
       tabla_afectada,
       usuario_sesion,
       ip_cliente
FROM rrhh.auditoria_empleados;
