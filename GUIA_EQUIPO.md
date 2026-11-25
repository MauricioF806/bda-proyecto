# Guía para el equipo

Proyecto de Bases de Datos Avanzadas: Diseño, Seguridad y Optimización de un Sistema de Gestión de Empleados, en PostgreSQL 16 con Docker.

## Estado actual

- Actividad 1 (diseño con tablas particionadas y tablespaces): terminada y documentada.
- Actividad 2 (seguridad multinivel, vista y trigger de auditoría): terminada y documentada.
- Actividad 3 (carga masiva, planes de ejecución, índices, parámetros y advisor): scripts 05 a 11, probados de punta a punta.
- Pendientes: actividad 4 (almacenamiento), actividad 5 (reporte final) y la presentación.

## Cómo levantar el entorno

Requisitos: Docker Desktop y Git.

1. Clonar el repositorio y entrar a la carpeta del proyecto.
2. Crear el archivo `.env` en la raíz a partir de `.env.example` y definir `POSTGRES_PASSWORD`. El `.env` no se sube al repositorio.
3. Desde la carpeta `docker`, ejecutar `docker compose up -d`.
4. Esperar a que `docker compose ps -a` muestre `empleados-postgres` como `healthy`.

La primera vez, los scripts de `docker/init` se ejecutan automáticamente en orden: tablespaces (01), esquema (02), roles y privilegios (03), seguridad por fila (04), auditoría (05) y endurecimiento de la auditoría (06). Solo corren cuando el volumen de datos está vacío. `docker compose down -v` borra los volúmenes y todos los datos, y vuelve a ejecutar los scripts desde cero.

El proyecto de compose se llama `bda-proyecto` (definido con `name:` en `docker-compose.yml`), y así aparece en Docker Desktop. Antes tomaba el nombre de la carpeta (`docker`) y se mezclaba con otros proyectos guardados en carpetas `docker`. Quien ya lo había levantado antes del cambio debe hacer, desde `docker`:

    docker rm -f empleados-postgres empleados-tablespaces-init   # contenedores viejos (los volúmenes quedan)
    docker network rm empleados_network                          # estaba etiquetada con el proyecto viejo
    docker compose up -d                                         # crea bda-proyecto con volúmenes nuevos y vacíos

(No usar `docker compose -p docker down`: podría afectar otros proyectos que también se llamen `docker`.)

y luego volver a cargar los datos de prueba con `03_datos_demo_seguridad.sql`. Los volúmenes viejos (`docker_empleados_pgdata` y `docker_empleados_tablespaces`) se pueden borrar con `docker volume rm`.

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

En PowerShell `<` no funciona y además los acentos se dañan al pasar el archivo por una tubería. Ahí conviene copiar la carpeta al contenedor (repetir la copia si se modifica algún script) y ejecutar con `-f`:

    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    docker cp scripts/. empleados-postgres:/tmp/scripts
    docker exec empleados-postgres psql -U admin_empleados -d empleados_db -f /tmp/scripts/NOMBRE.sql

- `01_verificar_ubicaciones.sql`: muestra en qué tablespace quedó cada objeto.
- `02_prueba_particiones.sql`: prueba el enrutamiento de particiones (RANGE en nómina, incluida la partición DEFAULT, y HASH en empleados) y la poda de particiones. Corre dentro de una transacción que termina en `ROLLBACK`: no borra ni deja datos, así que funciona antes o después de la carga masiva.
- `03_datos_demo_seguridad.sql`: carga seis empleados de demostración. Empieza con `TRUNCATE` de todas las tablas.
- `04_pruebas_seguridad.sql`: pruebas de acceso, modificación y auditoría cambiando de rol, incluida la cesión de permisos con `WITH GRANT OPTION` y `REVOKE ... CASCADE` (DAC), intentos de evadir RLS o de alterar la bitácora, y la auditoría de nómina. Los `permission denied` son el resultado esperado.

## Actividad 3: optimización y afinación (scripts 05 a 11)

Todos se ejecutan como `admin_empleados`, en este orden y una sola vez. Antes de empezar conviene partir de una base recién creada (`docker compose down -v` y `up -d`) para que la medición base no tenga índices ni parámetros de pruebas anteriores. De los scripts de las actividades 1 y 2, el 01 y el 02 se pueden ejecutar en cualquier momento. El 03 reemplaza los 50,000 empleados por los 6 de demostración, y el 04 necesita esos 6. Para repetir la demostración de seguridad después de la carga: ejecutar 03 y 04, y luego 05 para recuperar exactamente los mismos datos masivos (~30 s); las mediciones guardadas en `dba` no se pierden.

| Script | Qué hace | Requisito del PDF |
|---|---|---|
| `05_carga_masiva.sql` | Procedimiento PL/pgSQL `rrhh.sp_carga_masiva`: 12 departamentos, 15 puestos, 50,000 empleados (ciclo fila por fila) y ~818,000 pagos de nómina (una sentencia orientada a conjuntos). Semilla fija: siempre genera los mismos datos. Tarda ~30 s. | Carga masiva con PL/SQL |
| `06_mediciones_base.sql` | Crea el esquema `dba` con 4 consultas complejas, la función `dba.medir(etapa)` y la función `dba.plan(n)`. Mide la línea base sin índices. | EXPLAIN PLAN / DBMS_XPLAN |
| `07_advisor.sql` | Vista `dba.v_advisor` (hallazgos + recomendaciones) y función `dba.aplicar_recomendaciones(categoria)`. | DBA_ADVISOR_FINDINGS / RECOMMENDATIONS |
| `08_indices.sql` | Aplica automáticamente los índices que recomendó el advisor y un índice por apellido. Mide. | Crear índices, aplicar el advisor |
| `09_recrear_indices.sql` | Borra y recrea índices mejorados (compuesto, covering con `INCLUDE`, parcial con `WHERE activo`). Mide y compara tamaños. | Modificar y recrear índices |
| `10_parametros.sql` | `block_size` (equivalente a DB_BLOCK_SIZE, solo lectura) y `ALTER SYSTEM` de `shared_buffers`, `work_mem`, `maintenance_work_mem`, `effective_cache_size`, `random_page_cost`, `effective_io_concurrency`. | Parámetros críticos |
| (reiniciar) | `docker restart empleados-postgres`: `shared_buffers` solo cambia al reiniciar. | |
| `11_comparativo.sql` | Medición final, comparativo de las 4 etapas, advisor final y borrado de índices sin uso. | Análisis antes/después |

Consultas útiles durante la presentación:

    SELECT * FROM dba.v_comparativo;          -- costo y tiempo de cada consulta en cada etapa, con % contra la base
    SELECT * FROM dba.plan(3);                -- plan real de la consulta 3 (equivalente a DBMS_XPLAN.DISPLAY_CURSOR)
    SELECT * FROM dba.v_advisor;              -- hallazgos y recomendaciones vigentes
    SELECT * FROM dba.v_indices;              -- tamaño y uso de cada índice
    SELECT * FROM dba.consultas;              -- texto y objetivo de las 4 consultas

Resultados de referencia (una corrida de prueba; los tiempos varían según el equipo, los costos no):

| Consulta | Línea base | Índices simples | Índices recreados | Parámetros |
|---|---|---|---|---|
| 1. Nómina por departamento y trimestre | 8,588 / 104 ms | 8,588 / 130 ms | 8,588 / 112 ms | 8,588 / 104 ms |
| 2. Sobre el promedio de su puesto | 1,808 / 7.1 ms | 1,300 / 5.6 ms | 1,300 / 4.8 ms | 1,151 / 4.7 ms |
| 3. Historial de pagos por nombre | 16,852 / 60 ms | 3,341 / 7.5 ms | 1,045 / 1.3 ms | 397 / 1.3 ms |
| 4. Top 20 de bonos | 53,128 / 255 ms | 52,620 / 317 ms | 45,580 / 265 ms | 22,512 / 319 ms |

(costo estimado / tiempo real promedio)

Cómo leerlos (útil para la conclusión del reporte):

- **Consulta 3**: es la que más gana (−98 % de tiempo). Pasa de recorrer las ~818,000 filas de nómina a un `Nested Loop` con *index-only scan* sobre el covering index.
- **Consulta 1**: ningún índice la mejora, y es correcto. Lee una partición completa (`nomina_2025`) gracias a la poda de particiones; un índice no ayuda cuando se lee toda la partición.
- **Consulta 2**: con `random_page_cost = 4` el optimizador ignora el índice parcial. Con 1.1 (valor para SSD) lo usa. Así un parámetro cambia el plan.
- **Consulta 4**: con `work_mem = 4MB` la agregación escribe ~2,300 bloques temporales a disco; con 32MB se resuelve en memoria (`bloques_temp = 0`). Su costo estimado baja 58 %, pero el tiempo no mejora: el costo es una estimación del optimizador, no una medida de tiempo.
- Las diferencias de unos pocos milisegundos entre corridas son ruido (caché, otros procesos del equipo).
- Al final siguen dos hallazgos `CONSULTA_COSTOSA` (consultas 1 y 4) y uno de `ACCESO_SECUENCIAL` en empleados: son consultas que agregan una partición completa o casi toda la nómina, por lo que su recorrido secuencial es el plan correcto.

Notas técnicas:

- La carga desactiva los triggers de auditoría (sí alcanza a las particiones) dentro de la misma transacción; si algo falla, el `ROLLBACK` los deja activos. La bitácora registra la carga como un único evento con el total de filas.
- RLS sigue activo: tras la carga, `usr_analista1` ve 29,915 empleados, `usr_analista2` 44,917 y `usr_admin` los 50,000. El esquema `dba` solo es accesible para `rol_admin`.
- `dba.medir` ejecuta cada consulta una vez para calentar la caché y luego 3 veces con `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`; guarda el promedio de tiempo, el costo y el plan completo en `dba.mediciones`. Volver a medir una etapa reemplaza sus resultados.
- `DB_BLOCK_SIZE` no existe en PostgreSQL: el tamaño de bloque (`block_size = 8192`) se fija al compilar el servidor.
- Convención de documentación: el código va como texto y los resultados como capturas, con figuras numeradas.
