# Outbox atascado

> Regla: `outbox-atascado` (`faclab.outbox.oldest_age`, por tópico) · Severidad: **advertencia** con
> más de 5 min, **crítica** con más de 15 min · Dashboard: *Faclab · Kafka y mensajería*

## Síntoma

El mensaje pendiente más antiguo del outbox del core lleva más de 5 minutos sin publicarse en Kafka.
Las ventas confirmadas no llegan a facturación (`sales.confirmed`), ni las notas de crédito
(`credit_notes.requested`). La etiqueta `messaging.destination.name` dice el tópico.

## Diagnóstico

1. ¿El worker del core corre? `docker ps -a | grep worker`. Si no corre, no hay quien publique.
   Además se dispara [Ausencia de telemetría](sin-telemetria.md) de `faclab-core-worker`.
2. Logs del worker: `docker compose logs --tail 200 worker`.
   - `outbox.publish.failed` con un error de conexión: Kafka no responde. El relay no cuenta
     intentos mientras el broker está caído.
   - `outbox_message_failed`: un mensaje agotó sus intentos y quedó `failed` (ver
     [Mensajes fallidos](mensajes-fallidos.md)).
3. Kafka: `docker ps | grep kafka` y
   `docker exec kafka kafka-broker-api-versions --bootstrap-server localhost:9092`.
4. Un tópico que no existe (la creación automática está apagada) falla en cada envío. Listarlos con
   `docker exec kafka kafka-topics --bootstrap-server localhost:9092 --list` y crear los faltantes
   con `scripts/create-topics.sh` (servicio `kafka-topics`).
5. En *Kafka y mensajería*, «Outbox pendiente» dice si crece (nadie publica) o se vacía lento
   (publica, pero no alcanza).

## Acción

- **Worker detenido:** levantarlo (`docker compose up -d worker`) y comprobar su salud
  (`python -m src.shared.infra.worker.health` dentro del contenedor).
- **Kafka caído:** levantarlo (`docker compose up -d kafka` en faclab-infra). El relay reanuda solo y
  publica en orden por empresa.
- **Un mensaje que bloquea a su empresa:** espera su próximo intento y, al agotarlos, queda `failed`
  y deja de bloquear.
- Al recuperarse, la edad vuelve a 0 en pocos minutos.

## Escalamiento

Crítica a los 15 minutos: escalar si Kafka o el worker no vuelven en 30 minutos. Las ventas siguen
guardadas en el outbox: no se pierden, se facturan con retraso.

## Prueba controlada

Ver [pruebas de alertas](../signoz/pruebas-de-alertas.md#outbox-atascado).
