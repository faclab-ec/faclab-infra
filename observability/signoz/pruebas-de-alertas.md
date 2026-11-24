# Pruebas controladas de las alertas

Cada alerta de `alerts/` se disparó al menos una vez con una falla provocada en local (S7.5,
2026-11-21 y 22, SigNoz v0.151.0). Este documento dice cómo se provocó cada una, cómo se volvió atrás y
qué se vio. La evidencia completa (historia de estados de cada regla y correos de Mailpit) está en el
PR.

Repetir una prueba sirve para comprobar una alerta después de cambiarla, o una versión nueva de SigNoz.

## Entorno

Las fallas se provocaron en un **entorno aislado**, para no tocar los datos ni los procesos de
desarrollo:

- **Core:**
  - una base `faclab_s75` en el `db` del core, creada con `db_roles`, Alembic y `scripts.seed`
    (reescribiendo el nombre de la base en las tres URLs de rol), con un administrador desechable;
  - contenedores `s75-api` (`:3300`) y `s75-worker` en `faclab_network`, con `OTEL_ENABLED=true` hacia
    `collector:4317`;
  - el worker, con `KAFKA_BOOTSTRAP_SERVERS` hacia un broker inexistente, un grupo de consumidores propio y
    `INVOICE_RECONCILIATION_PENDING_MINUTES=1`.
- **Facturación:**
  - una copia de su base (`CREATE DATABASE faclab_invoicing_s75 TEMPLATE faclab_invoicing`, con sus
    migraciones);
  - un broker Kafka propio (`s75-kafka`), para no consumir del grupo `faclab-invoicing` del Kafka
    compartido;
  - el worker en el host (`npm run dev:worker`) con `DATABASE_URL`, `KAFKA_BROKERS` y `HTTP_PORT`
    propios.
- **Alertas:** sincronizadas con `scripts/signoz.sh sync`, con `ALERT_EMAIL_TO` hacia Mailpit y el
  canal de Telegram configurado.

Al final se borran las bases, los contenedores y el broker de prueba, y el tópico y el grupo
desechables del Kafka compartido. El Collector vuelve a sus `*_HEALTH_URL` del `.env`.

## Resultados

Primer aviso de cada regla, de su historia de estados (`/api/v2/rules/{id}/history/timeline`), y cómo
se provocó.

- Cada aviso llegó también a Mailpit: 65 correos en la prueba.
- Las críticas se enviaron además al canal de Telegram. SigNoz no registró errores de envío, y la
  prueba de `/api/v2/notification_channels/test` de los dos canales respondió sin error.

| Regla | Primer aviso (UTC, 2026-11-22) | Niveles | Falla |
|---|---|---|---|
| `servicio-no-disponible` | 02:21:38 | critical; nodata | Real (chequeo sin respuesta; luego `s75-api` detenida) |
| `errores-5xx-core` | 03:04:56 | warning y critical | Real (API sin base) |
| `errores-5xx-facturacion` | 03:13:44 | warning y critical | Real (API sin base) |
| `latencia-pos` | 04:53:06 | warning | Real (bloqueo de `sales`), con las cubetas corregidas |
| `outbox-atascado` | 02:59:19 | warning y critical | Real (venta con el broker caído) |
| `consumidor-detenido` | 03:03:06 | critical | Real (grupo con lag sin consumidor) |
| `outbox-fallidos` | 02:37:46 | warning | Filas inyectadas en la base aislada |
| `dead-letters` | 02:30:09 | warning | Real (dead letter de facturación) e inyectada (core) |
| `facturas-atascadas` | 03:01:25 | warning | Real (SRI bloqueado, 30 min) |
| `sri-no-disponible` | 02:36:42 | warning | Real (SRI bloqueado) |
| `rechazos-sri` | 02:43:16 | warning | Sintética |
| `certificado-30d` | 03:28:49 | warning | Vigencia ajustada en la copia |
| `certificado-7d` | 03:25:39 | critical | Vigencia ajustada en la copia |
| `conciliacion` | 02:22:00 (sin ventana completa); con `requireMinPoints`, tras 30 min | warning | Real (ventas sin resultado) |
| `disco` | 02:37:00 | warning y critical | Sintética |
| `conexiones-postgresql` | 02:38:16 | warning | Real (87 de 100 conexiones) |
| `sin-telemetria-core` | 03:51:28 | nodata | Real (API detenida) |
| `sin-telemetria-core-worker` | 03:44:16 | nodata | Real (worker detenido) |
| `sin-telemetria-invoicing` | 02:21:19 | nodata | Real (facturación sin correr) |
| `sin-telemetria-invoicing-worker` | 02:22:11 | nodata | Real (ver la nota de su sección) |
| `fuerza-bruta` | 03:03:30 | warning | Real (segundo lote de logins fallidos) |
| `entregas-fallidas` | 03:03:38 | warning | Real (SMTP cerrado, segunda entrega) |
| `respaldo-fallido` (S8.3, 2026-11-23) | 22:33:26 | warning | Real (almacenamiento externo detenido, incremental de staging) |
| `wal-sin-archivar` (S8.3, 2026-11-23) | 22:58:30 | critical | Real (ídem, 15 minutos de WAL sin archivar) |

`latencia-pos` también avisó a las 03:21:57, pero ese fue el falso positivo que se describe en su sección.

## Procedimientos

<a id="servicio-no-disponible"></a>
### Servicio no disponible

1. Apuntar el chequeo del Collector a la API aislada y esperar que responda bien:
   `CORE_HEALTH_URL=http://s75-api:3000/health/ready docker compose up -d collector`.
2. Detener `s75-api`. A los 2 minutos sin respuesta 2xx se dispara la alerta, con la `http.url` del
   chequeo.
3. Para volver atrás, levantar `s75-api` y restaurar el Collector con su `.env`.

En el entorno local la alerta ya se había disparado sola: el `.env` apuntaba a `http://api:3000`,
donde no responde nadie (la API de desarrollo corre sin ese alias), y la facturación no corría.

<a id="errores-5xx"></a>
### Errores 5xx

- **Core:** un segundo contenedor de la API (`s75-api-broken`) con las URLs de la base apuntando a una
  base inexistente. Un `POST /api/auth/login` por segundo durante 13 minutos respondió 500 cada vez.
- **Facturación:** su API en el host (`npm run dev`, `HTTP_PORT` propio) con `DATABASE_URL` hacia una
  base inexistente y `JWT_JWKS_URL` hacia `s75-api`. Con un token del administrador de prueba,
  `GET /api/invoices` respondió 500 cada vez.
- Las dos superan el 5 % con más de 20 solicitudes en 10 minutos: se disparan en los dos niveles.

<a id="latencia-pos"></a>
### Latencia del POS

- **Método:** una sesión de `psql` toma `LOCK TABLE sales IN ACCESS EXCLUSIVE MODE` durante 4 s de cada
  4,5 s, mientras un bucle crea ventas en borrador con `POST /api/pos/sales` en `s75-api`, durante
  12 minutos. Cada INSERT espera el bloqueo. Es la causa que el runbook manda a buscar.
- **Falso positivo de la primera prueba:**
  - La alerta se disparó con un p95 de 4,75 s, cuando las peticiones tardaban 0,03 s: eran `GET` a una
    ruta que solo acepta `POST`, y respondían 405.
  - La causa era del core: `http.server.request.duration` (en segundos) usaba las cubetas por defecto
    del SDK, pensadas para milisegundos (0, 5, 10…). Todo caía en la primera cubeta y cualquier
    percentil daba 4,75 s.
  - S7.5 le dio cubetas en segundos (`histogram_views()` en el core). La prueba se repitió con esa
    versión y con peticiones de verdad lentas.
- **Método descartado:** limitar la CPU del contenedor (`docker update --cpus 0.05`) paralizaba toda la
  app, que no respondía ni `/health/live`, en vez de hacerla lenta.

<a id="outbox-atascado"></a>
### Outbox atascado

Con el worker apuntando a un broker inexistente, una venta rápida real en el POS de `s75-api`
(`POST /api/pos/sales/quick`) dejó su `sales.confirmed` pendiente en el outbox. El relay registra
`outbox_broker_unavailable` sin contar intentos.

- A los 5 minutos se disparó la advertencia; a los 15, la crítica.
- La salud del worker (`python -m src.shared.infra.worker.health`) también lo marca: «outbox_relay: no
  successful cycle».

<a id="consumidor-detenido"></a>
### Consumidor detenido

Un tópico (`s75.drill`) y un grupo (`faclab-drill-s75`) desechables en el Kafka compartido:

1. el grupo consume un mensaje para confirmar su offset;
2. se publican 5 mensajes más sin nadie que los lea, así que el lag queda en 5;
3. pasados 10 minutos con el lag en 5, se dispara la alerta.

Para volver atrás: `kafka-consumer-groups --delete --group faclab-drill-s75` y
`kafka-topics --delete --topic s75.drill`.

<a id="mensajes-fallidos"></a>
### Mensajes fallidos

- **Core:** una fila `failed` en `outbox_messages` y una `pending` en `dead_letters` de `faclab_s75`.
  `queue_metrics` las informa al minuto, y se disparan `outbox-fallidos` y `dead-letters`.
- **Facturación:** una dead letter real. El primer `sales.confirmed` llegó cuando a la copia le faltaban
  migraciones (`column "branch_id" does not exist`). El consumidor lo reintentó y lo guardó como dead
  letter: la alerta muestra `service.name` y el tópico.

<a id="facturas-atascadas-y-sri-no-disponible"></a>
### Facturas atascadas y SRI no disponible

1. Bloquear el SRI. No existe un SRI simulado, así que se usa un *preload* de Node
   (`NODE_OPTIONS=--require block-sri.cjs`) que resuelve `*.sri.gob.ec` a `127.0.0.1`: cada llamada
   falla al instante con `ECONNREFUSED`, sin tocar el código ni `/etc/hosts`.
2. Enviar un `sales.confirmed` v3 (el ejemplo `full-customer` del contrato, con la empresa y el RUC del
   emisor de la copia) al broker de prueba. La factura se firmó y quedó en `signed` con `SRI_UNAVAILABLE`.
3. Resultados:
   - `sri-no-disponible` se disparó con los primeros reintentos (100 % de llamadas sin respuesta);
   - `facturas-atascadas`, cuando la factura pasó los 30 minutos.

<a id="certificado-por-vencer"></a>
### Certificado por vencer

En la copia de la base de facturación:

1. el certificado seleccionado del emisor pasa a vencer en 5 días (ventana `7d`);
2. un segundo emisor de prueba, con una copia del certificado, vence en 20 días (ventana `30d`).

El worker muestrea los certificados cada minuto. Las dos reglas se evalúan cada hora, así que se
disparan en su siguiente evaluación.

<a id="conciliacion"></a>
### Conciliación

El worker aislado corre la conciliación cada minuto con `INVOICE_RECONCILIATION_PENDING_MINUTES=1`. Las
ventas confirmadas del seed, que nunca tuvieron resultado de facturación, abrieron discrepancias
`confirmed_without_result`, y la alerta se disparó tras 30 minutos abiertas.

La primera versión de la regla se disparó a los 2 minutos: con «todo el tiempo», SigNoz evalúa solo
los puntos que hay en la ventana. Por eso las reglas de ese tipo exigen el 75 % de los puntos.

<a id="conexiones-postgresql"></a>
### Conexiones de PostgreSQL

Se abrieron 75 conexiones en espera (`select pg_sleep(1200)`) contra `invoicing-db`
(`max_connections` 100). Con las del worker y el Collector llegaron a 87 de 100, y la alerta se disparó.
Para volver atrás: `pg_terminate_backend` de esas sesiones.

<a id="sin-telemetria"></a>
### Ausencia de telemetría

- **Core:** se detienen `s75-worker` y `s75-api`. A los 10 minutos sin `db.client.connection.count` de
  `faclab-core-worker` y de `faclab-core`, sus reglas pasan a `nodata` y avisan.
- **Facturación:** la regla de `faclab-invoicing` avisó al inicio, cuando la facturación no corría, y se
  resolvió al arrancar su worker. Ese worker, lanzado con `npm run dev:worker`, se reporta como
  `faclab-invoicing` y no como `faclab-invoicing-worker`, así que la regla del worker siguió en
  `nodata`. Está anotado como pendiente de faclab-invoicing.

<a id="fuerza-bruta"></a>
### Fuerza bruta

Se enviaron 60 logins con contraseña equivocada contra `s75-api` en menos de un minuto: 20 respondieron
`invalid` y, con la IP ya bloqueada, 40 respondieron `locked`.

- **Primer lote:** no disparó. El contador `faclab.auth.login.attempts{result=invalid}` apareció por
  primera vez en ese proceso, y el primer punto de una serie no da `increase`.
- **Segundo lote,** igual que el primero: disparó.
- La corrección (inicializar los contadores en 0 al arrancar) está pendiente para S7.6.
- Al terminar se vacía `login_failures` de `faclab_s75`: el bloqueo por IP también afectaba al
  administrador de prueba.

<a id="entregas-fallidas"></a>
### Entregas fallidas

Con el worker de facturación apuntando su SMTP a un puerto cerrado (`SMTP_HOST=127.0.0.1`,
`SMTP_PORT=1`), una entrega existente de la copia vuelve a `pending` con `attempts=9`. El siguiente
intento falla con `ECONNREFUSED 127.0.0.1:1` y la entrega queda `failed`.

- Hace falta que corra el almacenamiento de objetos (`object-storage`): sin él, el trabajo falla antes
  de llegar al SMTP y no cuenta como entrega.
- Como en fuerza bruta, la primera falla de un proceso no da `increase`. La segunda disparó la
  alerta.

<a id="disco-y-rechazos-sri"></a>
### Disco y rechazos del SRI (métricas sintéticas)

Estas dos no se pueden provocar de verdad en local: el disco del host no se llena en una prueba, y
ningún SRI simulado responde DEVUELTA a pedido.

Se emitieron sus métricas con el mismo nombre y los mismos atributos, por el Collector, con el SDK de
OpenTelemetry que ya trae el `.venv` del core:

- `system.filesystem.utilization` = 0,93 en `host.name=drill-s75`, `mountpoint=/drill-s75`: se
  dispararon los dos niveles;
- `faclab.invoices.rejections` de `faclab-invoicing-worker`, primero en 0 y luego +5, con código `35` y
  operación `recepcion`: más de 3 en una hora.

Al dejar de emitirlas, las dos alertas se resuelven.

<a id="respaldos"></a>
### Respaldos (S8.3)

Se probaron en staging, con faclab-infra 0.2.0-rc.2, cuyo Collector envía al de la Mac y de ahí al
SigNoz local, a las 22:26 UTC del 2026-11-23:

1. Se detuvo el sustituto de S3 de `deploy/production/drill` (`standin.sh down`): una caída real del
   almacenamiento externo.
2. Se corrió el incremental con `systemctl start faclab-backup@incr`. pgBackRest falló a los 121 s
   (exit 49) y `backups.sh` dejó `incr` como fallido. Con su reporte, `respaldo-fallido` avisó a los 7
   minutos.
3. Una carga mínima en la base `postgres` (una fila y `pg_switch_wal()` cada 30 s, durante 25
   minutos) dio WAL que archivar. `wal-sin-archivar` avisó a las 22:58, después de sus 15 minutos de
   falla sostenida, por correo y por Telegram.
4. Al levantar el sustituto (`standin.sh up`), el archivo de WAL se puso al día solo: 15 segmentos
   en un minuto, ninguno pendiente.

La prueba encontró tres problemas, corregidos antes del simulacro de restauración:

- **PostgreSQL se reiniciaba cada vez que pgBackRest fallaba en segundo plano:** 9 veces en 20
  minutos. Como PID 1 del contenedor, el postmaster adoptaba el proceso asíncrono de pgBackRest y
  tomaba su salida con error por la caída de un proceso propio. Ahora `init: true` pone docker-init
  como PID 1. Reproducido en local: sin init, 1 reinicio en 4 minutos; con init, ninguno.
- **`respaldo-atrasado` también avisaba, y no debía:** `pgbackrest info` termina con 0 aunque el
  repositorio no responda, y dice el error en su JSON (`status.code` 99). El reporte lo leía como «no
  hay respaldos». Ahora solo confía en los códigos 0 y 2, y si no, usa las corridas registradas.
- **El archivo de WAL ya no va en la línea de comandos** (`stack.sh migrate` lo enciende tras crear el
  stanza). Lo mostró la prueba local: el servidor temporal con que la imagen inicializa una base nueva
  no se podía apagar sin un stanza al que archivar.

`respaldo-atrasado` sin datos (`alertOnAbsent`) avisó al crearse la regla, a las 20:46, antes del
primer reporte del timer, y se resolvió a las 20:54.

