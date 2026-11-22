# SRI no disponible

> Regla: `sri-no-disponible` (`faclab.sri.request.duration`, por `faclab.sri.environment`) ·
> Severidad: **advertencia** · Dashboard: *Faclab · Facturación electrónica*, panel «Resultado de
> las llamadas al SRI»

## Síntoma

Más de la mitad de las llamadas a los servicios web del SRI fallaron en 10 minutos:
`faclab.sri.outcome` fue `timeout` o `error`, es decir, sin respuesta. Un DEVUELTA es una respuesta
del SRI y no cuenta aquí (ver [Aumento de rechazos](rechazos-sri.md)). `faclab.sri.environment`
dice si es el ambiente de pruebas (`pruebas`, celcer) o el de producción (`produccion`, cel).

## Diagnóstico

1. En *Facturación electrónica*, «Resultado de las llamadas al SRI» por operación:
   - `recepcion` y `autorizacion` caídas a la vez: el SRI o la red;
   - solo `recepcion`: un problema conocido del SRI de pruebas, que puede fallar horas con
     `GenericJDBCException` mientras la autorización responde.
2. Desde el servidor de facturación:

   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' --max-time 10 \
     'https://cel.sri.gob.ec/comprobantes-electronicos-ws/RecepcionComprobantesOffline?wsdl'
   ```

   Usar `celcer` en lugar de `cel` para pruebas. Un timeout o un error de DNS desde el servidor,
   mientras desde otra red responde, apunta a la red o al DNS propios.
3. Los logs del worker de facturación (`sri.recepcion` y `sri.autorizacion` en las trazas) muestran
   el error exacto.

## Acción

- **Caída del SRI:** no hay nada que reintentar a mano. El worker reintenta solo con espera
  creciente, y los comprobantes quedan pendientes. Se puede avisar a las empresas que la
  autorización se demora.
- **Red o DNS propios:** corregirlos. Los reintentos siguen al volver.
- Al recuperarse, comprobar que [Facturas atascadas](facturas-atascadas.md) se resuelve.

## Escalamiento

Si dura más de 2 horas en producción, avisar a las empresas que facturan en ese período. Si el SRI
responde desde fuera y no desde el servidor, escalar a quien administra la red del VPS.

## Prueba controlada

Ver [pruebas de alertas](../signoz/pruebas-de-alertas.md#facturas-atascadas-y-sri-no-disponible).
