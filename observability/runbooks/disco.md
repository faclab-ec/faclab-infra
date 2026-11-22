# Disco

> Regla: `disco` (`system.filesystem.utilization`, por `host.name` y `mountpoint`) · Severidad:
> **advertencia** con más del 80 %, **crítica** con más del 90 % · Dashboard: *Faclab ·
> Infraestructura*, panel «Disco del host»

## Síntoma

Un sistema de archivos del servidor pasó del 80 % de uso. Con el disco lleno, PostgreSQL deja de
escribir y los servicios fallan (ver [Servicio no disponible](servicio-no-disponible.md)).

## Diagnóstico

1. En el servidor:

   ```bash
   df -h
   docker system df
   ```

2. Lo que suele crecer:
   - **Volúmenes de bases:** `db`, `invoicing-db` y el ClickHouse de SigNoz. El tamaño de cada base
     está en el panel «Tamaño de las bases».
   - **Kafka:** retención de `KAFKA_LOG_RETENTION_HOURS` (168 h).
   - **Logs de contenedores**, si no tienen rotación configurada.
   - **Imágenes viejas** de despliegues anteriores.
3. En las bases del core:
   - el outbox se purga a los `OUTBOX_RETENTION_DAYS` y las filas de importación a los
     `IMPORT_RETENTION_DAYS`;
   - la purga corre en el worker: si está detenido, esas tablas crecen.

## Acción

- **Imágenes y capas sin uso:** `docker image prune -a` (solo las que no usa ningún contenedor) y
  `docker builder prune`.
- **Retención de telemetría:** ajustar la retención de SigNoz (S8.6) o liberar datos viejos.
- **Worker detenido:** levantarlo; las purgas siguen solas.
- **Disco chico para la carga:** ampliar el volumen del VPS.

## Escalamiento

Al 90 % (crítica), actuar en la hora: al llenarse, PostgreSQL se detiene. Escalar a quien
administra el VPS si hay que ampliar el disco.

## Prueba controlada

Ver [pruebas de alertas](../signoz/pruebas-de-alertas.md#disco-y-rechazos-sri) (con una métrica
sintética: el disco real no se llena en la prueba).
