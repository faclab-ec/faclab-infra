# Conciliación

> Regla: `conciliacion` (`faclab.reconciliation.discrepancies`, por `kind`) · Severidad:
> **advertencia** · Dashboard: *Faclab · Calidad de operaciones*, panel «Discrepancias de
> conciliación»

## Síntoma

Hay discrepancias abiertas entre el core y facturación durante 30 minutos seguidos:

- `confirmed_without_result`: una venta confirmada que no tiene resultado de facturación
  `INVOICE_RECONCILIATION_PENDING_MINUTES` (30) después de enviarse.
- `authorized_on_cancelled`: el SRI autorizó la factura de una venta que se anuló en el core. Hay que
  emitirle una nota de crédito.

## Diagnóstico

1. El listado de conciliación del core: `GET /api/admin/invoice-discrepancies`, abiertas por
   defecto, con la venta. En faclab-web está en la administración de ventas.
2. Para `confirmed_without_result`, el estado en facturación (`GET /api/invoices/by-sale/:saleId`):
   - **pendiente con una causa** (SRI caído, emisor no listo): ver
     [Facturas atascadas](facturas-atascadas.md);
   - **no existe:** el mensaje no llegó; revisar [Outbox atascado](outbox-atascado.md) y
     [Mensajes fallidos](mensajes-fallidos.md);
   - **autorizada en facturación:** el resultado no volvió al core; revisar el consumidor
     `faclab-core` en [Consumidor detenido](consumidor-detenido.md).

## Acción

- **El mensaje no llegó:** reenviar la factura desde el core
  (`POST /api/admin/sales/{id}/request-invoice`). La discrepancia se resuelve sola cuando llega el
  resultado.
- **Facturación lo está reintentando:** no hacer nada; marcarla revisada con una nota
  (`POST /api/admin/invoice-discrepancies/{id}/review`).
- **`authorized_on_cancelled`:** emitir la nota de crédito de esa factura
  (`POST /api/admin/invoice-discrepancies/{id}/credit-note`).
- Una discrepancia revisada deja de contar. Si el ruido viene de ventas que facturación ya está
  reintentando, se puede subir `INVOICE_RECONCILIATION_PENDING_MINUTES`.

## Escalamiento

`authorized_on_cancelled` es tributario: resolverlo en el día y, si no se puede emitir la nota,
avisar a la empresa.

## Prueba controlada

Ver [pruebas de alertas](../signoz/pruebas-de-alertas.md#conciliacion).
