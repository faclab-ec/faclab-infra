# Entregas de facturas fallidas

> Regla: `entregas-fallidas` (`faclab.invoices.deliveries` con `result` en `failed` o `bounced`) ·
> Severidad: **advertencia** · Dashboard: *Faclab · Facturación electrónica*, panel «Entregas por
> resultado»

## Síntoma

En la última hora, alguna factura autorizada no llegó al correo de su comprador:

- `failed`: se agotaron los reintentos de envío;
- `bounced`: el servidor de correo la rechazó con un 5xx síncrono.

La factura sigue autorizada y su RIDE y XML existen; solo falta entregarla.

## Diagnóstico

1. El registro de envíos de esa factura: `GET /api/invoices/:id/emails`, con el error de cada
   intento.
2. **Muchas a la vez:** el SMTP de facturación. Revisar:
   - las variables: `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE` y las credenciales en el `.env` del
     servicio;
   - la cuenta del proveedor: cuota, bloqueo o credenciales vencidas;
   - los logs del worker de entregas.
3. **Una sola:** un correo mal escrito del comprador (`bounced`) o un buzón lleno.

## Acción

- **SMTP caído o mal configurado:** corregirlo. Las entregas pendientes siguen solas; las `failed` se
  reenvían con `POST /api/invoices/:id/email`.
- **Correo inválido del comprador:** la empresa lo corrige. El reenvío va siempre al correo de la
  venta; corregir el destino después de la venta está pendiente en el ROADMAP.

## Escalamiento

Si todas las entregas fallan durante más de una hora, escalar al responsable técnico y revisar el
proveedor de correo (S8.1).

## Prueba controlada

Ver [pruebas de alertas](../signoz/pruebas-de-alertas.md#entregas-fallidas).
