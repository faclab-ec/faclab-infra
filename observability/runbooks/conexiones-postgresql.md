# Conexiones de PostgreSQL

> Regla: `conexiones-postgresql` (`postgresql.backends` sobre `postgresql.connection.max`, por
> `server.address`) · Severidad: **advertencia** · Dashboard: *Faclab · Infraestructura*, panel
> «Conexiones de PostgreSQL»

## Síntoma

Un servidor PostgreSQL usa más del 80 % de su `max_connections`. `server.address` dice cuál:

- `db`: el core;
- `invoicing-db`: la facturación.

Al llegar al máximo, las conexiones nuevas fallan con `too many clients already` y los requests
responden 5xx.

## Diagnóstico

1. ¿Quién tiene las conexiones? Como superusuario en ese servidor:

   ```sql
   SELECT usename, application_name, state, count(*)
   FROM pg_stat_activity GROUP BY 1, 2, 3 ORDER BY 4 DESC;
   ```

   - En el core:
     - `faclab_app` es el API: sus pools por cada worker de uvicorn (`WEB_CONCURRENCY`);
     - `faclab_worker` es el worker;
     - `faclab_monitor`, el Collector.
   - En la facturación, `faclab_invoicing`: su pool es de 10 por proceso.
2. Muchas `idle in transaction`: una transacción abierta que no termina, una fuga. La traza del
   request que la abrió la muestra.
3. En *API Core*, «Conexiones del pool» por pool y estado.

## Acción

- **Fuga, `idle in transaction`:** terminar esas sesiones con
  `SELECT pg_terminate_backend(pid) ...`, después de anotar el `pid`, `query` y `xact_start`, y abrir
  un issue.
- **Más procesos que conexiones:** bajar `WEB_CONCURRENCY` o los workers, o subir `max_connections`
  del servidor, con su memoria en cuenta.
- **Un proceso externo** (una consola, un script): cerrarlo.

## Escalamiento

Si sube al 95 %, escalar: falta poco para que fallen los requests.

## Prueba controlada

Ver [pruebas de alertas](../signoz/pruebas-de-alertas.md#conexiones-postgresql).
