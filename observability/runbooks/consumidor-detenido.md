# Consumidor detenido

> Regla: `consumidor-detenido` (`kafka.consumer_group.lag_sum`, por `group` y `topic`) · Severidad:
> **crítica** · Dashboard: *Faclab · Kafka y mensajería*, panel «Lag por grupo»

## Síntoma

Un grupo de consumidores tiene mensajes sin leer durante 10 minutos seguidos: su lag nunca bajó a
0. Los grupos de Faclab son:

- `faclab-invoicing`: lee `sales.confirmed` y `credit_notes.requested` y emite los comprobantes.
- `faclab-core`: lee `invoices` y `credit_notes.results` y actualiza las ventas.

## Diagnóstico

1. Estado del grupo:

   ```bash
   docker exec kafka kafka-consumer-groups --bootstrap-server localhost:9092 \
     --describe --group faclab-invoicing --members
   ```

   Sin miembros: el proceso consumidor no corre. Con miembros y el lag que sube: consume, pero
   lento, o está atascado en un mensaje.
2. ¿Corre el worker de ese servicio?
   - faclab-invoicing: su worker (`npm run worker` o el contenedor).
   - faclab-core: `docker ps -a | grep worker`.
3. Logs del consumidor. Un mensaje que falla se reintenta con espera creciente y, al agotar los
   intentos, queda como dead letter y el consumidor sigue (ver
   [Mensajes fallidos](mensajes-fallidos.md)). Si los logs repiten el mismo mensaje, está en esos
   reintentos.
4. Un grupo que ya no se usa (de una prueba, por ejemplo) mantiene su lag para siempre. Si no es de
   Faclab, se borra:
   `kafka-consumer-groups --delete --group <grupo>`.

## Acción

- **Worker detenido:** levantarlo. El consumidor retoma desde el último offset confirmado: no se
  pierden mensajes, y los handlers son idempotentes.
- **Consumo lento:** revisar en *Kafka y mensajería* la duración de `messaging.process.duration` y
  sus dependencias (la base de facturación, el SRI).
- **Grupo huérfano:** borrarlo, como en el paso 4.

## Escalamiento

Es crítica: sin consumidor no se emiten facturas (`faclab-invoicing`) o las ventas no se enteran de
su resultado (`faclab-core`). Escalar si no se recupera en 30 minutos.

## Prueba controlada

Ver [pruebas de alertas](../signoz/pruebas-de-alertas.md#consumidor-detenido).
