# Guía para el equipo

Proyecto de Bases de Datos Avanzadas: Diseño, Seguridad y Optimización de un Sistema de Gestión de Empleados, en PostgreSQL 16 con Docker.

## Estado actual

- Actividad 1 (diseño con tablas particionadas y tablespaces): terminada y documentada.
- Actividad 2 (seguridad multinivel, vista y trigger de auditoría): terminada y documentada.
- Pendientes: actividad 3 (carga masiva y optimización), actividad 4 (almacenamiento), actividad 5 (reporte final) y la presentación.

## Cómo levantar el entorno

Requisitos: Docker Desktop y Git.

1. Clonar el repositorio y entrar a la carpeta del proyecto.
2. Crear el archivo `.env` en la raíz a partir de `.env.example` y definir `POSTGRES_PASSWORD`. El `.env` no se sube al repositorio.
3. Desde la carpeta `docker`, ejecutar `docker compose up -d`.
4. Esperar a que `docker compose ps -a` muestre `empleados-postgres` como `healthy`.

La primera vez, los scripts de `docker/init` se ejecutan automáticamente en orden: tablespaces (01), esquema (02), roles y privilegios (03), seguridad por fila (04), auditoría (05) y endurecimiento de la auditoría (06). Solo corren cuando el volumen de datos está vacío. `docker compose down -v` borra los volúmenes y todos los datos, y vuelve a ejecutar los scripts desde cero.

## Conectarse

En Git Bash (Windows):

    winpty docker exec -it empleados-postgres psql -U admin_empleados -d empleados_db

Para entrar con otro usuario, cambiar `-U`. Usuarios de demostración (contraseñas solo para este entorno académico):

| Usuario | Rol | Nivel MAC | Contraseña |
|---|---|---|---|
| usr_admin | rol_admin | 3 | Admin_2026 |
| usr_analista1 | rol_analista | 1 | Analista1_2026 |
| usr_analista2 | rol_analista | 2 | Analista2_2026 |
| usr_auditor | rol_auditor | 3 | Auditor_2026 |

`admin_empleados` es el superusuario del clúster y se salta las políticas de seguridad. Dentro del contenedor la conexión local no pide contraseña. Para demostrar un inicio de sesión real con contraseña, conectarse desde Windows por el puerto publicado (requiere `psql` instalado en Windows):

    psql -h localhost -p 5433 -U usr_analista1 -d empleados_db

## Endurecimiento de la auditoría (`06_endurecimiento.sql`)

- `rol_admin` ya no tiene `TRUNCATE` sobre `empleados` y `nomina` (TRUNCATE no dispara el trigger y borraría sin dejar rastro), ni `INSERT` ni `TRIGGER` sobre la bitácora (no puede fabricar registros ni crear un trigger que los descarte).
- La función del trigger es `SECURITY DEFINER`: escribe en la bitácora con permisos de su dueño. El usuario registrado sale del `SET ROLE` vigente o, si no hay, de `session_user`. Se agregaron las columnas `usuario_sesion` e `ip_cliente`.
- `nomina` también se audita (`trg_auditar_nomina`). La vista muestra `tabla_afectada`, `usuario_sesion` e `ip_cliente`.
- Los intentos rechazados no llegan a la bitácora (no se ejecutan). Quedan en el log del servidor con usuario y base:

      docker logs empleados-postgres 2>&1 | grep -A1 "permission denied"

  El log muestra el usuario con el que se inició sesión, no el rol activado con `SET ROLE`. Con `04_pruebas_seguridad.sql` (que entra como `admin_empleados`) todos los rechazos aparecen como `admin_empleados`; para que el log muestre `usr_analista1`, etc., la demostración debe iniciar sesión con ese usuario (`psql -h localhost -p 5433 -U usr_analista1 ...`).

## Scripts de la carpeta `scripts`

Se ejecutan desde la raíz del repo con:

    docker exec -i empleados-postgres psql -U admin_empleados -d empleados_db < scripts/NOMBRE.sql

- `01_verificar_ubicaciones.sql`: muestra en qué tablespace quedó cada objeto.
- `02_prueba_particiones.sql`: prueba el enrutamiento de particiones. Termina con `TRUNCATE`.
- `03_datos_demo_seguridad.sql`: carga seis empleados de demostración. Empieza con `TRUNCATE` de todas las tablas.
- `04_pruebas_seguridad.sql`: pruebas de acceso, modificación y auditoría cambiando de rol, incluida la cesión de permisos con `WITH GRANT OPTION` y `REVOKE ... CASCADE` (DAC), intentos de evadir RLS o de alterar la bitácora, y la auditoría de nómina. Los `permission denied` son el resultado esperado.

## Advertencias para la actividad 3

- Los scripts 02 y 03 vacían las tablas. No ejecutarlos después de la carga masiva. Antes de cargar, hay que vaciar los datos de demostración.
- Los triggers `trg_auditar_empleados` y `trg_auditar_nomina` registran cada fila insertada en `empleados` y `nomina`. Una carga de 50,000 registros generará 50,000 entradas en la bitácora (más las de nómina) y será más lenta. Hay que decidir si se desactiva durante la carga y comprobar si `ALTER TABLE ... DISABLE TRIGGER` alcanza a las particiones.
- RLS está activo en `empleados`: cargar y consultar como `admin_empleados` o `usr_admin`, porque un analista solo verá las filas de su nivel. Los empleados nuevos deben repartirse entre los niveles de clasificación 1, 2 y 3.
- No hay índices secundarios a propósito. Para la comparación antes/después, medir primero con `EXPLAIN (ANALYZE, BUFFERS)` y solo después crear o recrear índices.
- `pg_stat_statements` ya está precargado en el servidor, pero falta ejecutar `CREATE EXTENSION pg_stat_statements;` en la base.
- `DB_BLOCK_SIZE` no existe en PostgreSQL (el tamaño de bloque se fija al compilar). Los parámetros ajustables son, por ejemplo, `shared_buffers`, `work_mem`, `effective_cache_size`, `maintenance_work_mem` y `random_page_cost`.
- Convención de documentación: el código va como texto y los resultados como capturas, con figuras numeradas.
