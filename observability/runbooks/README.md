# Runbooks de las alertas

Cada alerta de SigNoz (`observability/signoz/alerts/`) enlaza, en su anotación `runbook_url` y en
su descripción, al runbook de esta carpeta que le corresponde. Cada runbook dice qué se ve, cómo
confirmar la causa, qué hacer y a quién escalar.

Los umbrales son **iniciales y provisionales** (OBSERVABILITY.md §8 del core): se ajustan con la
línea base del piloto (S9.2). Si una alerta suena sin un problema real, se anota en el runbook y se
ajusta su archivo; no se silencia en la interfaz sin dejar rastro.

| Runbook | Reglas | Severidad |
|---|---|---|
| [Servicio no disponible](servicio-no-disponible.md) | `servicio-no-disponible` | Crítica |
| [Errores 5xx sostenidos](errores-5xx.md) | `errores-5xx-core`, `errores-5xx-facturacion` | Advertencia (> 2 %), crítica (> 5 %) |
| [Latencia del POS](latencia-pos.md) | `latencia-pos` | Advertencia |
| [Outbox atascado](outbox-atascado.md) | `outbox-atascado` | Advertencia (> 5 min), crítica (> 15 min) |
| [Consumidor detenido](consumidor-detenido.md) | `consumidor-detenido` | Crítica |
| [Mensajes fallidos](mensajes-fallidos.md) | `outbox-fallidos`, `dead-letters` | Advertencia |
| [Facturas atascadas](facturas-atascadas.md) | `facturas-atascadas` | Advertencia |
| [SRI no disponible](sri-no-disponible.md) | `sri-no-disponible` | Advertencia |
| [Aumento de rechazos del SRI](rechazos-sri.md) | `rechazos-sri` | Advertencia |
| [Certificado por vencer](certificado-por-vencer.md) | `certificado-30d`, `certificado-7d` | Advertencia (30 días), crítica (7 días o vencido) |
| [Conciliación](conciliacion.md) | `conciliacion` | Advertencia |
| [Disco](disco.md) | `disco` | Advertencia (> 80 %), crítica (> 90 %) |
| [Conexiones de PostgreSQL](conexiones-postgresql.md) | `conexiones-postgresql` | Advertencia |
| [Ausencia de telemetría](sin-telemetria.md) | `sin-telemetria-core`, `sin-telemetria-core-worker`, `sin-telemetria-invoicing`, `sin-telemetria-invoicing-worker` | Advertencia |
| [Fuerza bruta en el login](fuerza-bruta.md) | `fuerza-bruta` | Advertencia |
| [Entregas de facturas fallidas](entregas-fallidas.md) | `entregas-fallidas` | Advertencia |
| [Respaldos](respaldos.md) | `respaldo-fallido`, `respaldo-atrasado`, `wal-sin-archivar` | Advertencia (fallido, atrasado), crítica (WAL sin archivar) |

## Severidades y canales

- **Crítica:** va al correo y a Telegram. Alguien la atiende en cuanto llega, a cualquier hora.
- **Advertencia:** va al correo. Se revisa en horario laboral, el mismo día.

Los canales los crea `scripts/signoz.sh sync` con las variables del `.env` (README de faclab-infra,
«Dashboards y alertas»). Una alerta vuelve a avisar mientras siga activa: cada 4 h, o cada 24 h las
de certificados.

## Escalamiento

1. Quien está de turno sigue el runbook.
2. Si en 30 minutos (crítica) o en el día (advertencia) no hay causa o solución, escala al
   responsable técnico de Faclab con lo que ya revisó: la alerta, los paneles, los logs y las trazas.
3. Si afecta a la facturación de una empresa (comprobantes sin autorizar, certificado vencido), se
   avisa además a la empresa por su canal de soporte.

Los nombres y contactos de turno se definen con el despliegue (S8.6) y no van en este repositorio.

## Comandos de referencia

- **faclab-core**, en su repositorio:
  - `make outbox-failed` y `make outbox-retry ids="..." by=<quién>`;
  - `make dead-letters` y `make reprocess-dead-letter id=<id> by=<quién>`;
  - `docker compose logs -f api worker`.
- **faclab-invoicing**:
  - `npm run cli -- dead-letters` y `npm run cli -- dead-letter-reprocess --id <id> --by <quién>`;
  - `GET /api/invoicing/status` (estado del emisor de una empresa);
  - `POST /api/invoices/retry`.
- **Kafka**:
  - `docker exec kafka kafka-consumer-groups --bootstrap-server localhost:9092 --describe --group <grupo>`;
  - los grupos son `faclab-core` y `faclab-invoicing`.
- **SigNoz**: los dashboards *Faclab · …*. Cada panel dice en su descripción qué consulta, en qué
  unidad, su umbral y qué hacer.
