# Latencia del POS

> Regla: `latencia-pos` · Severidad: **advertencia** · Dashboard: *Faclab · API Core*, panel «p95 por
> ruta»

## Síntoma

El p95 de las rutas `/api/pos/sales*` (crear, cobrar, venta rápida, confirmar) pasa de 1 s en
promedio durante 10 minutos. En caja, cada venta tarda y se forman filas.

Línea base (S9.2, `docs/architecture/CARGA.md` del core): 0,1 s en el pico de la ferretería piloto y
0,65 s a 150 veces ese pico. Por encima de 1 s el servidor está cerca de saturarse o algo está mal.

## Diagnóstico

1. En *API Core*, «p95 por ruta» muestra qué ruta del POS se puso lenta, y «Duración de comandos»
   (`handler.duration`) muestra qué comando.
2. En *Traces*, abrir las trazas más lentas de esa ruta:
   - spans largos de SQL: una consulta lenta o un bloqueo;
   - un hueco antes del primer span: CPU o espera por una conexión del pool.
3. Bloqueos: en *Infraestructura*, «Bloqueos de PostgreSQL». Una venta bloquea las filas de stock y
   el contador del documento. Un ajuste o una importación grande en paralelo puede hacerlas esperar.
4. Recursos: CPU y memoria del contenedor `api` en *Infraestructura*. La CPU es lo primero que se
   agota (S9.2): con 4 vCPU, unas 600 ventas por minuto.
5. Pool: «Conexiones del pool» en *API Core*. Muchas conexiones `used` y pocas `idle` indican que
   el pool se agotó.

## Acción

- **Bloqueo por una operación masiva:** esperar que termine o pausarla. Una importación se sigue en
  `/api/admin/imports`.
- **CPU saturada:** ampliar el servidor. Subir `WEB_CONCURRENCY` de 2 a 4 en 4 vCPU empeoró la
  latencia en la prueba de S9.2 y casi agotó las conexiones de PostgreSQL: no subirlo sin núcleos
  libres y sin medir.
- **Una consulta lenta:** anotar la ruta y el SQL del span en un issue. Revisar si le falta un índice.

## Escalamiento

Si dura más de una hora en horario de atención, escalar al responsable técnico: el POS lento detiene
la venta de las empresas.

## Prueba controlada

Ver [pruebas de alertas](../signoz/pruebas-de-alertas.md#latencia-pos).
