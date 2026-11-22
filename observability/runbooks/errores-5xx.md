# Errores 5xx sostenidos

> Reglas:
>
> - `errores-5xx-core`: `http.server.request.duration`, por `http.response.status_code`;
> - `errores-5xx-facturacion`: `http.server.duration`, por `http.status_code`.
>
> Severidad: **advertencia** con más del 2 % y **crítica** con más del 5 %, en 10 minutos, con al
> menos 20 solicitudes. Dashboards: *Faclab · Ecosistema* y *Faclab · API Core*.

## Síntoma

Más del 2 % de las respuestas del servicio son 5xx durante 10 minutos. Son errores inesperados: un
error de dominio responde 4xx y no cuenta aquí.

## Diagnóstico

1. En *API Core*, el panel «4xx contra 5xx por ruta» dice qué ruta falla. En la facturación se ve el
   mismo dato en *Ecosistema*.
2. En SigNoz, *Traces*: el servicio con `has_error = true` en la última media hora. El span raíz
   lleva `http.route`, y el log de la excepción tiene el mismo `trace_id` (*Logs* → *Related logs*).
3. ¿Falla una dependencia?
   - PostgreSQL: el panel de conexiones y [Conexiones de PostgreSQL](conexiones-postgresql.md);
   - Kafka: [Outbox atascado](outbox-atascado.md);
   - el SRI, en la facturación: [SRI no disponible](sri-no-disponible.md).
4. ¿Coincide con un despliegue? Comparar `service.version` en las trazas con errores contra las de
   antes.

## Acción

- **Un despliegue reciente:** volver a la imagen anterior.
- **Una dependencia caída:** seguir su runbook. Los 5xx bajan cuando vuelve.
- **Un error de código en una ruta:** abrir un issue con el `trace_id`, la ruta y el mensaje del log.
  Mientras se corrige, si la ruta tiene un interruptor de vuelta atrás, usarlo
  (`PUBLIC_API_ENABLED`, `WEBHOOKS_ENABLED`, `IDEMPOTENCY_KEY_REQUIRED` y otros del README del core).

## Escalamiento

Si pasa del 5 % (crítica) o dura más de 30 minutos, escalar al responsable técnico con las trazas.

## Prueba controlada

Ver [pruebas de alertas](../signoz/pruebas-de-alertas.md#errores-5xx).
