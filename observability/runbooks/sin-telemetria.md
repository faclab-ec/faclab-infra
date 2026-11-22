# Ausencia de telemetría

> Reglas: `sin-telemetria-core`, `sin-telemetria-core-worker`, `sin-telemetria-invoicing` y
> `sin-telemetria-invoicing-worker` · Severidad: **advertencia** · Dashboard: *Faclab · Ecosistema*

## Síntoma

SigNoz no recibe en 10 minutos ninguna muestra de `db.client.connection.count` de un servicio. Todos
la exportan siempre, cada 15 a 60 s, haya tráfico o no: cada pool de conexiones la reporta. Por eso
sirve de latido. Su ausencia significa una de dos cosas:

- el proceso no corre;
- su telemetría no llega: un exportador roto, el Collector caído o SigNoz sin recibir.

OBSERVABILITY §8 pedía «sin spans en horario comercial». El latido de métricas no depende del
tráfico, así que avisa también de noche sin falsas alarmas.

## Diagnóstico

1. ¿Falla un servicio o todos?
   - **Todos a la vez:** el Collector o SigNoz. `docker ps | grep -E 'collector|signoz'` y
     `docker logs collector`. Un `connection refused` hacia `signoz-otel-collector:4317` indica que
     SigNoz no recibe.
   - **Uno solo:** ese proceso.
2. ¿El proceso corre?
   - `docker ps -a`;
   - el worker del core: `python -m src.shared.infra.worker.health`;
   - el de facturación: su `/health`.
3. ¿Exporta? Revisar en sus logs errores del exportador OTLP. En el core, `OTEL_ENABLED` y
   `OTEL_OTLP_ENDPOINT`; en facturación, `OTEL_EXPORTER_OTLP_ENDPOINT`. Un exportador de Node que
   arrancó con el Collector caído puede no recuperarse: reiniciarlo.

## Acción

- **Proceso detenido:** levantarlo. Si es un worker, revisar en cuanto vuelva el
  [outbox](outbox-atascado.md) y el [lag](consumidor-detenido.md).
- **Collector caído:** `docker compose up -d collector` en faclab-infra. Mientras tanto, los servicios
  pueden exportar directo a SigNoz (README de faclab-infra, «Volver atrás»).
- **SigNoz caído:** `scripts/signoz.sh status` y `up`.

## Escalamiento

Sin telemetría, las demás alertas no ven nada. Si no vuelve en una hora, escalar.

## Prueba controlada

Ver [pruebas de alertas](../signoz/pruebas-de-alertas.md#sin-telemetria).
