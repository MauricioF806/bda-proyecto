-- 14_simular_fragmentacion.sql: provoca fragmentación para demostrar el mantenimiento (Fase 4)
-- Ejecutar como admin_empleados después de 13_ajustes_dinamicos.sql.
--
-- Actualiza dos veces la mitad de los pagos de la partición del año pasado (+1 y luego -1 al bono):
-- los datos quedan iguales, pero cada UPDATE deja la versión anterior de la fila como "muerta"
-- y agrega entradas nuevas a los índices. Resultado: la partición y sus índices crecen y quedan
-- con huecos, como pasa en producción después de muchas modificaciones.

\echo '=== Antes: tamaño y salud de la partición del año pasado ==='
SELECT particion, tamano_datos, tamano_indices FROM dba.v_particiones
WHERE particion = 'nomina_' || (extract(YEAR FROM current_date)::INT - 1);

BEGIN;
-- Cambio masivo controlado del DBA: no se audita fila por fila (si algo falla, el ROLLBACK reactiva el trigger)
ALTER TABLE rrhh.nomina DISABLE TRIGGER trg_auditar_nomina;

UPDATE rrhh.nomina SET bonos = bonos + 1
WHERE fecha_pago >= make_date(extract(YEAR FROM current_date)::INT - 1, 1, 1)
  AND fecha_pago <  make_date(extract(YEAR FROM current_date)::INT, 1, 1)
  AND id_pago % 2 = 0;

UPDATE rrhh.nomina SET bonos = bonos - 1
WHERE fecha_pago >= make_date(extract(YEAR FROM current_date)::INT - 1, 1, 1)
  AND fecha_pago <  make_date(extract(YEAR FROM current_date)::INT, 1, 1)
  AND id_pago % 2 = 0;

ALTER TABLE rrhh.nomina ENABLE TRIGGER trg_auditar_nomina;
COMMIT;

-- Un VACUUM normal marca el espacio como reutilizable, pero NO devuelve espacio al disco
VACUUM rrhh.nomina;

\echo '=== Después: la partición y sus índices crecieron y quedaron con huecos ==='
SELECT particion, tamano_datos, tamano_indices FROM dba.v_particiones
WHERE particion = 'nomina_' || (extract(YEAR FROM current_date)::INT - 1);

\echo '=== Salud de tablas e índices: lo marcado con requiere_rebuild = t lo reconstruye el mantenimiento ==='
SELECT * FROM dba.v_salud_tablas WHERE requiere_rebuild;
SELECT indice, tamano, densidad_hojas_pct, fragmentacion_pct FROM dba.v_salud_indices WHERE requiere_rebuild;

\echo 'Siguiente paso: 15_mantenimiento_automatico.sql (o esperar a que lo ejecute el contenedor empleados-mantenimiento)'
