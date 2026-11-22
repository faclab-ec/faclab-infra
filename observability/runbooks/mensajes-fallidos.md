# Mensajes fallidos

> Reglas:
>
> - `outbox-fallidos`: `faclab.outbox.failed`, por tópico;
> - `dead-letters`: `faclab.dead_letters.pending`, por servicio y tópico.
>
> Severidad: **advertencia** · Dashboard: *Faclab · Kafka y mensajería*

## Síntoma

En los últimos 15 minutos hubo mensajes que no se pudieron procesar y esperan a una persona:

- **Outbox `failed`** (core): un mensaje que el relay no pudo publicar después de
  `OUTBOX_MAX_ATTEMPTS` intentos. Ya no bloquea a los de su empresa, pero no llegó a Kafka.
- **Dead letters**: un mensaje que el consumidor no pudo procesar después de sus reintentos.
  - `service.name=faclab-core-worker`: el core no pudo aplicar un resultado de facturación.
  - `faclab-invoicing-worker`: facturación no pudo recibir una venta o una nota de crédito.

La alerta sigue activa mientras queden pendientes.

## Diagnóstico

1. Listar los mensajes:
   - outbox del core: `make outbox-failed`, que muestra el último error de cada uno;
   - dead letters del core: `make dead-letters`;
   - dead letters de facturación: `npm run cli -- dead-letters`.
2. Leer el error de cada uno:
   - **De datos:** un mensaje mal formado, una versión de contrato desconocida o una empresa que
     no existe. No se arregla reintentando.
   - **Transitorio:** una base caída o un timeout. Reintentar sirve cuando la dependencia volvió.
3. En *Traces*, el `trace_id` del mensaje (el header `traceparent`) muestra el flujo que lo produjo.

## Acción

- **Error transitorio**, ya resuelto:
  - outbox: `make outbox-retry ids="<ids>" by=<quién>`, o `ids=--all`;
  - dead letters del core: `make reprocess-dead-letter id=<id> by=<quién>`;
  - de facturación: `npm run cli -- dead-letter-reprocess --id <id> --by <quién>`, o `--all`.
- **Error de datos:** no reprocesar a ciegas. Abrir un issue con el mensaje y el error, corregir el
  productor y decidir caso por caso. Una venta sin factura se puede volver a pedir desde el core
  (`POST /api/admin/sales/{id}/request-invoice`, el reenvío).
- `--by` queda registrado en la fila y en el log: siempre con el nombre de quien lo hace.

## Escalamiento

Si hay más de 10 pendientes o el mismo error se repite en varias empresas, escalar al responsable
técnico: es un defecto, no un incidente aislado.

## Prueba controlada

Ver [pruebas de alertas](../signoz/pruebas-de-alertas.md#mensajes-fallidos).
