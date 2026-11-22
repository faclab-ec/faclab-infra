# Aumento de rechazos del SRI

> Regla: `rechazos-sri` (`faclab.invoices.rejections`, por `faclab.sri.message.code`) · Severidad:
> **advertencia** · Dashboard: *Faclab · Facturación electrónica*, panel «Rechazos por código»

## Síntoma

El SRI rechazó más de 3 comprobantes en una hora: DEVUELTA en la recepción o NO AUTORIZADO. La
etiqueta `faclab.sri.message.code` es el identificador del primer error del SRI, por ejemplo `35`
(estructura) o `65` (fecha de emisión extemporánea).

El panel del dashboard muestra además el porcentaje sobre los autorizados. El umbral del 5 % de
OBSERVABILITY §8 queda solo en el panel hasta tener una línea base (S9.2).

## Diagnóstico

1. En el panel, ¿un solo código o varios? ¿Una empresa o varias?
   - Las métricas no llevan la empresa.
   - En facturación, `GET /api/invoices?status=rejected` de la empresa (con el `issue` y el mensaje
     del SRI), o en *Traces* los spans `sri.recepcion` y `sri.autorizacion` del worker.
2. Causas frecuentes:
   - **65, fecha extemporánea:** comprobantes que esperaron demasiado (ver
     [Facturas atascadas](facturas-atascadas.md)).
   - **Datos de la empresa** (RUC, establecimiento, ambiente): su perfil fiscal.
   - **Datos de un cliente o de un producto:** el detalle del comprobante.
   - **Un cambio de esquema del SRI:** muchos rechazos del mismo código en todas las empresas a la
     vez.

## Acción

- **De una empresa:** corregir el dato con ella. Un comprobante rechazado no se reintenta: desde el
  core se vuelve a pedir la factura (`POST /api/admin/sales/{id}/request-invoice`), que sale con
  otro número.
- **De todas las empresas:** es un defecto de faclab-invoicing o un cambio del SRI. Abrir un issue
  urgente con el código y el mensaje.

## Escalamiento

Si el mismo código afecta a varias empresas, escalar en el día al responsable técnico.

## Prueba controlada

Ver [pruebas de alertas](../signoz/pruebas-de-alertas.md#disco-y-rechazos-sri) (con una métrica sintética: no hay un SRI simulado que rechace a pedido).
