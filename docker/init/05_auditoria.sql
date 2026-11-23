-- 05_auditoria.sql: trigger y vista de auditoría

CREATE OR REPLACE FUNCTION rrhh.fn_auditar_empleados()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO rrhh.auditoria_empleados (tabla_afectada, operacion, usuario_bd, datos_nuevos)
        VALUES ('empleados', 'I', current_user, to_jsonb(NEW));
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO rrhh.auditoria_empleados (tabla_afectada, operacion, usuario_bd, datos_anteriores, datos_nuevos)
        VALUES ('empleados', 'U', current_user, to_jsonb(OLD), to_jsonb(NEW));
    ELSE
        INSERT INTO rrhh.auditoria_empleados (tabla_afectada, operacion, usuario_bd, datos_anteriores)
        VALUES ('empleados', 'D', current_user, to_jsonb(OLD));
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_auditar_empleados
AFTER INSERT OR UPDATE OR DELETE ON rrhh.empleados
FOR EACH ROW EXECUTE FUNCTION rrhh.fn_auditar_empleados();

CREATE VIEW rrhh.v_auditoria_empleados AS
SELECT id_auditoria,
       fecha_evento,
       usuario_bd,
       CASE operacion WHEN 'I' THEN 'INSERT' WHEN 'U' THEN 'UPDATE' WHEN 'D' THEN 'DELETE' END AS operacion,
       COALESCE(datos_nuevos->>'id_empleado', datos_anteriores->>'id_empleado') AS id_empleado,
       datos_anteriores,
       datos_nuevos
FROM rrhh.auditoria_empleados;

GRANT SELECT ON rrhh.v_auditoria_empleados TO rol_auditor;

-- El administrador solo lee la vista; sin esto podría borrar la bitácora a través de ella
REVOKE INSERT, UPDATE, DELETE ON rrhh.v_auditoria_empleados FROM rol_admin;
