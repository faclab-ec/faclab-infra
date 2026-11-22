# Facturas atascadas

> Regla: `facturas-atascadas` (`faclab.invoices.oldest_age`, por `status`) · Severidad: **advertencia**
> · Dashboard: *Faclab · Facturación electrónica*

## Síntoma

Hay un comprobante sin estado final (ni autorizado ni rechazado) que llegó a facturación hace más de
30 minutos. El comprador no recibe su factura, y la venta sigue con la factura `PENDING` en el core.

## Diagnóstico

1. En *Facturación electrónica*, «Pendientes por estado y causa» dice en qué estado se quedaron y con
   qué `faclab.issue.type`:
   - **Causas del emisor** (`CONFIG_MISSING`, `CONFIG_INVALID`, `CERTIFICATE_*`): la empresa no puede
     facturar todavía. `GET /api/invoicing/status` de esa empresa lista sus problemas.
   - **Transitorias** (el SRI no responde, timeouts): ver [SRI no disponible](sri-no-disponible.md).
     Se reintentan solas, con espera creciente.
   - `XML_SCHEMA_INVALID` y otras de datos: el comprobante no pasa el esquema del SRI. No se arregla
     solo.
2. «Vencidas sin tomar» (`faclab.invoices.due`) y «Leases vencidos» (`expired_leases`):
   - si `due` crece, faltan workers o están detenidos;
   - si hay leases vencidos, un worker murió con comprobantes tomados. Se liberan solos al vencer el
     lease.
3. ¿Corre el worker de facturación? Su `/health` y sus logs.

## Acción

- **Emisor no listo:** avisar a la empresa. Tiene que completar su perfil fiscal o subir y
  seleccionar un certificado vigente. Al corregirlo, la recuperación vuelve a encolar sus
  comprobantes.
- **SRI caído:** esperar. Al volver el SRI, los reintentos los autorizan.
- **Un worker detenido:** levantarlo.
- **Error de datos:** revisar el comprobante (`GET /api/invoices/:id`, con su `issue`), corregir la
  causa y reintentar con `POST /api/invoices/:id/retry`, o todos los de la empresa con
  `POST /api/invoices/retry`.

## Escalamiento

- Si un comprobante pasa de 4 horas sin estado final, escalar: el SRI pide transmitirlo cuando se
  emite (error 65, «fecha de emisión extemporánea»).
- Si la causa es del emisor, la empresa es quien lo resuelve.

## Prueba controlada

Ver [pruebas de alertas](../signoz/pruebas-de-alertas.md#facturas-atascadas-y-sri-no-disponible).
