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

La primera vez, los scripts de `docker/init` se ejecutan automáticamente en orden: tablespaces (01), esquema (02), roles y privilegios (03), seguridad por fila (04) y auditoría (05). Solo corren cuando el volumen de datos está vacío. `docker compose down -v` borra los volúmenes y todos los datos, y vuelve a ejecutar los scripts desde cero.

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

`admin_empleados` es el superusuario del clúster y se salta las políticas de seguridad. Dentro del contenedor la conexión local no pide contraseña.

## Scripts de la carpeta `scripts`

Se ejecutan desde la raíz del repo con:

    docker exec -i empleados-postgres psql -U admin_empleados -d empleados_db < scripts/NOMBRE.sql

- `01_verificar_ubicaciones.sql`: muestra en qué tablespace quedó cada objeto.
- `02_prueba_particiones.sql`: prueba el enrutamiento de particiones. Termina con `TRUNCATE`.
- `03_datos_demo_seguridad.sql`: carga seis empleados de demostración. Empieza con `TRUNCATE` de todas las tablas.
- `04_pruebas_seguridad.sql`: pruebas de acceso, modificación y auditoría cambiando de rol. Los `permission denied` son el resultado esperado.

## Advertencias para la actividad 3

- Los scripts 02 y 03 vacían las tablas. No ejecutarlos después de la carga masiva. Antes de cargar, hay que vaciar los datos de demostración.
- El trigger `trg_auditar_empleados` registra cada fila insertada en `empleados`. Una carga de 50,000 registros generará 50,000 entradas en la bitácora y será más lenta. Hay que decidir si se desactiva durante la carga y comprobar si `ALTER TABLE ... DISABLE TRIGGER` alcanza a las particiones.
- RLS está activo en `empleados`: cargar y consultar como `admin_empleados` o `usr_admin`, porque un analista solo verá las filas de su nivel. Los empleados nuevos deben repartirse entre los niveles de clasificación 1, 2 y 3.
- No hay índices secundarios a propósito. Para la comparación antes/después, medir primero con `EXPLAIN (ANALYZE, BUFFERS)` y solo después crear o recrear índices.
- `pg_stat_statements` ya está precargado en el servidor, pero falta ejecutar `CREATE EXTENSION pg_stat_statements;` en la base.
- `DB_BLOCK_SIZE` no existe en PostgreSQL (el tamaño de bloque se fija al compilar). Los parámetros ajustables son, por ejemplo, `shared_buffers`, `work_mem`, `effective_cache_size`, `maintenance_work_mem` y `random_page_cost`.
- Convención de documentación: el código va como texto y los resultados como capturas, con figuras numeradas.
