# Servicio no disponible

> Regla: `servicio-no-disponible` · Severidad: **crítica** · Dashboard: *Faclab · Ecosistema*, panel
> «Disponibilidad»

## Síntoma

El chequeo de salud del Collector (`http_check`) no recibe una respuesta 2xx de un servicio durante
2 minutos seguidos:

- faclab-core: `/health/ready`, que responde 503 si su base de datos falla;
- faclab-invoicing: `/health`.

La etiqueta `http.url` dice cuál. Las métricas no llegan en 5 minutos: el Collector o el exportador
están caídos (ver [Ausencia de telemetría](sin-telemetria.md)).

Para los usuarios significa que el POS, la administración o la facturación no responden, o responden
con errores.

## Diagnóstico

1. ¿El contenedor está vivo?

   ```bash
   docker ps -a --filter name=api --filter name=invoicing
   ```

   Un `Restarting` o un `Exited` indica que el proceso no arranca.
2. Logs de arranque:
   - faclab-core: `docker compose logs --tail 200 api` en su repositorio. Una configuración inválida
     termina el proceso al importar `config`.
   - faclab-invoicing: `docker logs --tail 200 <contenedor>`. Su `ConfigError` sale por la consola.
3. Si el proceso responde, la causa está en la respuesta:
   - en el core, `/health/ready` da 503 cuando falla `SELECT 1`: hay que revisar PostgreSQL (`db`) y
     [sus conexiones](conexiones-postgresql.md);
   - un 200 con `degraded` (Kafka desconectado) no dispara esta alerta.
4. Desde el Collector: `docker logs collector | grep httpcheck`. Un `connection refused` o un
   `no such host` apunta a la red o a `CORE_HEALTH_URL` y `INVOICING_HEALTH_URL`.

## Acción

- **Proceso caído por configuración:** corregir la variable que el log nombra y volver a levantar el
  contenedor.
- **Base de datos caída:** levantar `db` o `invoicing-db` y revisar espacio en [disco](disco.md).
- **Sin memoria:** `docker stats` y el dashboard *Infraestructura*. Liberar recursos o ampliar el
  servidor.
- Después de recuperarse, comprobar en *Ecosistema* que la disponibilidad vuelve a 1 y que el
  [outbox](outbox-atascado.md) se vacía.

## Escalamiento

Es crítica: si el servicio no vuelve en 30 minutos, escalar al responsable técnico. Si hubo
ventas o facturas que no se pudieron registrar, avisar a las empresas afectadas.

## Prueba controlada

Ver [pruebas de alertas](../signoz/pruebas-de-alertas.md#servicio-no-disponible).
