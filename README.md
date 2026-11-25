# Faclab Infra

Infraestructura local compartida para el ecosistema Faclab. Provee los servicios base que consumen el sistema principal y los microservicios.

Además, `deploy/production/` tiene el stack de producción en un VPS (S8.1): ver
[Despliegue en producción](#despliegue-en-producción).

## Servicios

| Servicio | Imagen | Puerto local | Descripcion |
|----------|--------|--------------|-------------|
| **Kafka** | `confluentinc/cp-kafka` | `29092` | Broker de mensajeria (modo KRaft, sin Zookeeper) |
| **Kafka UI** | `provectuslabs/kafka-ui` | `9091` | Interfaz web para monitorear topics, consumers y mensajes |
| **kafka-topics** | `confluentinc/cp-kafka` | — | Crea los tópicos con varias particiones al arrancar y termina (`scripts/create-topics.sh`) |
| **invoicing-db** | `postgres:17` | `5434` | Base de datos de faclab-invoicing (`faclab_invoicing` y `faclab_invoicing_test`) |
| **object-storage** | `dxflrs/garage` | `3900` | Almacenamiento de objetos compatible con S3 (Garage) para las facturas autorizadas de faclab-invoicing |
| **mailpit** | `axllent/mailpit` | `1025`, `8025` | Servidor de correo de desarrollo: guarda los correos que faclab-invoicing envía a los compradores y no entrega ninguno |
| **collector** | `otel/opentelemetry-collector-contrib` | `4317`, `4318` | OpenTelemetry Collector: recibe la telemetría de los servicios y del navegador, agrega métricas de infraestructura, borra atributos sensibles y reenvía a SigNoz (ver [Collector](#collector-de-opentelemetry)) |
| **docker-socket-proxy** | `tecnativa/docker-socket-proxy` | — | Acceso de solo lectura a la API de Docker para el Collector; es el único contenedor con el socket |

## Requisitos

- Docker y Docker Compose v2+

## Inicio rapido

```bash
# 1. Crear el archivo de configuracion
cp .env.example .env

# 2. Crear la red compartida (solo la primera vez)
docker network create faclab_network

# 3. Levantar los servicios
docker compose up -d
```

Si venías de la versión con LocalStack, usa `docker compose up -d --remove-orphans` para detener los contenedores `aws-local` y `dynamodb-admin`. Después puedes borrar `.docker/.volumes/aws` y las variables `LOCALSTACK_*` de tu `.env`: ya no se usan.

## Estructura del proyecto

```
faclab-infra/
├── docker-compose.yml          # Definicion de servicios
├── .env.example                # Variables de entorno (plantilla)
├── .env                        # Variables de entorno (no versionado)
├── CHANGELOG.md                # Lo que trae cada versión (S8.2)
├── deploy/
│   └── production/             # Stack de producción en un VPS (S8.1): compose, Caddy, secretos, guía;
│                               # versiones por entorno, matriz de compatibilidad y despliegue (S8.2)
├── garage/
│   └── garage.toml             # Configuracion de Garage (un nodo, sin replicacion); también la de producción
├── observability/
│   ├── otel-collector/
│   │   ├── config.yaml            # Configuración del OTel Collector (receptores, redacción, envío a SigNoz)
│   │   └── redaction-test.yaml    # Capa de la prueba de redacción: OTLP/HTTP y envío a un archivo (S7.6)
│   ├── runbooks/                  # Un runbook por alerta (síntoma, diagnóstico, acción, escalamiento)
│   └── signoz/
│       ├── casting.yaml           # SigNoz local con Foundry: versiones, SMTP, red y puertos
│       ├── dashboards/            # Los seis dashboards de Faclab (SigNoz v6)
│       ├── alerts/                # Las alertas (reglas v2alpha1), con su runbook
│       └── pruebas-de-alertas.md  # Cómo se provocó cada alerta y la evidencia
├── scripts/
│   ├── collector-redaction-test.py # Prueba que el Collector borra las claves sensibles (CI)
│   ├── create-topics.sh        # Crea los tópicos de Kafka con varias particiones
│   ├── init-invoicing-db.sh    # Crea el rol y las bases de faclab-invoicing
│   ├── release.sh              # Prepara una versión (CHANGELOG) y la etiqueta (S8.2)
│   ├── signoz.sh               # SigNoz local (up, down, status, config) y dashboards y alertas (check, sync, verify)
│   └── signoz-sync.py          # Sincroniza canales, dashboards y alertas con la API de SigNoz
```

## Conexion desde microservicios

Este repo crea la red `faclab_network`. Los demas microservicios deben declararla como externa en su `docker-compose.yml`:

```yaml
networks:
  faclab_network:
    external: true
```

### Endpoints internos (desde contenedores)

| Servicio | Host |
|----------|------|
| Kafka | `kafka:9092` |
| PostgreSQL de faclab-invoicing | `invoicing-db:5432` |
| Almacenamiento de objetos (S3) | `http://object-storage:3900` |
| Correo (SMTP) | `mailpit:1025` |
| OpenTelemetry (OTLP gRPC) | `http://collector:4317` |

### Endpoints externos (desde el host)

| Servicio | URL |
|----------|-----|
| Kafka | `localhost:29092` |
| Kafka UI | [http://localhost:9091](http://localhost:9091) |
| PostgreSQL de faclab-invoicing | `localhost:5434` |
| Almacenamiento de objetos (S3) | `http://localhost:3900` |
| Correo (SMTP) | `localhost:1025` |
| Correo (interfaz web de Mailpit) | [http://localhost:8025](http://localhost:8025) |
| OpenTelemetry de los servicios (OTLP gRPC) | `http://localhost:4317` |
| OpenTelemetry del navegador (OTLP/HTTP, solo `faclab-web`) | `http://localhost:4318` |

## Tópicos de Kafka

Kafka no crea tópicos por su cuenta (`KAFKA_AUTO_CREATE_TOPICS_ENABLE=false`): los crea
`scripts/create-topics.sh`, que el servicio `kafka-topics` corre cuando Kafka está sano y luego
termina (ADR-0005).

| Tópico | Productor | Consumidores |
|--------|-----------|--------------|
| `sales.confirmed` | faclab-core (worker, desde el outbox) | faclab-invoicing (worker) |
| `invoices` | faclab-invoicing (worker: solo `InvoiceAuthorized` e `InvoiceRejected`) | faclab-core (worker) |
| `credit_notes.requested` | faclab-core (worker, desde el outbox) | faclab-invoicing (worker) |
| `credit_notes.results` | faclab-invoicing (worker: `CreditNoteAuthorized` y `CreditNoteRejected`) | faclab-core (worker) |

- Desde S4.2 faclab-invoicing ya no usa `invoices` para avanzar sus facturas: lo hace una cola en su
  base de datos, y el tópico solo lleva al core el resultado de cada una.
- Cada tópico tiene `KAFKA_TOPIC_PARTITIONS` particiones (6 por defecto) y replicación 1 (un solo
  nodo). Con `KAFKA_TOPIC_RETENTION_MS`, cada tópico recibe ese `retention.ms` (también los que ya
  existen); sin ella conservan el del broker (`KAFKA_LOG_RETENTION_HOURS`). Producción la fija en 7
  días. Los mensajes llevan como clave la empresa (`tenant_id`): los de una empresa van en orden
  por la misma partición y las empresas se reparten entre las demás.
- Es idempotente: un tópico que ya existe conserva sus mensajes, y si tiene menos particiones crece
  hasta `KAFKA_TOPIC_PARTITIONS` (Kafka no las reduce). Al crecer, los mensajes nuevos de una empresa
  pueden ir a otra partición, así que conviene hacerlo con el tópico quieto.
- Para correrlo de nuevo (por ejemplo, después de cambiar `KAFKA_TOPIC_PARTITIONS`):
  `docker compose run --rm kafka-topics`.
- No hay tópico de mensajes fallidos (`dlq` se quitó en S8.1): cada servicio guarda los que su
  consumidor no pudo procesar en su tabla `dead_letters` y los reprocesa él (`make
  reprocess-dead-letter` en faclab-core, `npm run cli -- dead-letter-reprocess` en faclab-invoicing).
  En un volumen de Kafka que ya lo tiene, `dlq` queda sin uso; se borra con `docker compose exec kafka
  kafka-topics --bootstrap-server localhost:9092 --delete --topic dlq`.

## Base de datos de faclab-invoicing

`invoicing-db` es un PostgreSQL 17 solo para faclab-invoicing; el del core sigue en faclab-core (`make dev`). Al iniciar un volumen vacío, `scripts/init-invoicing-db.sh` crea:

| Objeto | Para qué |
|--------|----------|
| Rol `faclab_invoicing` | Usuario del servicio, dueño de las dos bases (contraseña: `INVOICING_DB_PASSWORD`) |
| Base `faclab_invoicing` | La del servicio: `DATABASE_URL=postgres://faclab_invoicing:faclab_invoicing@localhost:5434/faclab_invoicing` |
| Base `faclab_invoicing_test` | Las pruebas con PostgreSQL de faclab-invoicing (`TEST_DATABASE_URL`) |

Las tablas las crean las migraciones de faclab-invoicing (`npm run migrate up`, ver su README), no este repo.

El script de inicio solo corre la primera vez, con el volumen vacío. Es idempotente; para aplicarlo a un volumen que ya existe (por ejemplo, después de cambiar `INVOICING_DB_PASSWORD`):

```bash
docker compose exec invoicing-db /docker-entrypoint-initdb.d/init-invoicing-db.sh
```

Para empezar de cero: `docker compose down` y `docker volume rm faclab-infra_invoicing_db_data`.

## Almacenamiento de objetos

`object-storage` es [Garage](https://garagehq.deuxfleurs.fr), un servicio compatible con S3, en un
solo nodo. faclab-invoicing guarda ahí el XML autorizado de cada factura
(`tenants/{tenant_id}/invoices/{año}/{clave de acceso}.xml`, S4.1). Al arrancar con
`--single-node --default-bucket`, Garage crea la llave de acceso y el bucket de las variables
`OBJECT_STORAGE_*`; no hace falta ningún script.

| Dato | Valor local |
|------|-------------|
| Endpoint | `http://localhost:3900` (desde un contenedor, `http://object-storage:3900`) |
| Región | `garage` |
| Bucket | `faclab-invoicing` (`OBJECT_STORAGE_BUCKET`) |
| Llave | `OBJECT_STORAGE_ACCESS_KEY_ID` y `OBJECT_STORAGE_SECRET_ACCESS_KEY`; los valores por defecto son de desarrollo y coinciden con los de faclab-invoicing en local |

```bash
docker compose exec object-storage /garage status          # estado del nodo
docker compose exec object-storage /garage bucket info faclab-invoicing   # objetos y tamaño
```

Los datos quedan en el volumen `faclab-infra_object_storage_data`.

- **Por qué Garage.** MinIO dejó de publicar imágenes de su edición comunitaria en 2025 y archivó su
  repositorio en 2026.
- **En el VPS** corre el mismo Garage, con este `garage.toml` (S8.1, `deploy/production`).
- **La copia fuera del servidor** es de S8.3.
- **Cualquier servicio compatible con S3 sirve:** faclab-invoicing solo usa su API.

## Collector de OpenTelemetry

`collector` es el [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/) (distribución
contrib) de Faclab (S7.4, ADR-0010 del core). Los servicios le exportan a él y **nunca directo a
SigNoz**: él agrega las métricas de infraestructura, borra los atributos sensibles y reenvía todo a
SigNoz. Su configuración está en `observability/otel-collector/config.yaml`.

```mermaid
flowchart LR
    C[faclab-core<br/>API y worker] -->|OTLP gRPC :4317| COL
    I[faclab-invoicing<br/>API y worker] -->|OTLP gRPC :4317| COL
    B[faclab-web<br/>navegador, /otlp] -->|OTLP/HTTP :4318| COL
    H[host, contenedores,<br/>PostgreSQL, Kafka, /health] --> COL
    COL[collector] -->|OTLP gRPC| SZ[SigNoz<br/>signoz-otel-collector:4317]
```

| Receptor | Qué agrega | Fuente |
|----------|------------|--------|
| `otlp` (gRPC, `4317`) | Trazas, métricas y logs de los servicios | faclab-core y faclab-invoicing |
| `otlp/browser` (HTTP, `4318`) | Trazas y web vitals del navegador; hasta 1 MiB por envío y solo `service.name=faclab-web` (lo demás se descarta, sin logs: `/v1/logs` responde 404) | La ruta `/otlp` de faclab-web (el proxy de Vite en local) |
| `host_metrics` | `system.*`: CPU, carga, memoria, paginación, discos, sistemas de archivos y red | La raíz del host montada en `/hostfs` |
| `docker_stats` | `container.*`: CPU, memoria, red y disco de cada contenedor | La API de Docker, por `docker-socket-proxy` |
| `postgresql/core`, `postgresql/invoicing` | `postgresql.*`: conexiones y su máximo, tamaño de cada base y tabla, commits, rollbacks, bloqueos, deadlocks, bgwriter; `server.address` dice de qué servidor es | `db:5432` (faclab-core) e `invoicing-db:5432`, como `faclab_monitor` |
| `kafka_metrics` | `kafka.*`: brokers, particiones y offsets, y el lag de cada grupo (`kafka.consumer_group.lag` por partición y `kafka.consumer_group.lag_sum` por tópico) | `kafka:9092` |
| `http_check` | `httpcheck.*`: disponibilidad y duración de `/health/ready` del core y `/health` de la facturación | `CORE_HEALTH_URL`, `INVOICING_HEALTH_URL` |

Procesadores, en este orden:

1. `memory_limiter`: 80 % de los 512 MiB del contenedor.
2. `resource_detection`: `host.name` y `os.type` del host de Docker y `deployment.environment.name` (`COLLECTOR_ENVIRONMENT`). Lo que un servicio ya trae se conserva. No se aplica al navegador.
3. `transform/redact`: borra las claves sensibles en el recurso, los spans, sus eventos, los puntos de las métricas y los logs.
   - Usa la misma lista que el core (`password`, `token`, `secret`, `client_secret`, `authorization`, `cookie`, `api_key`, `p12`, `certificate`, `private_key`, `xml`, `signature` y sus variantes), sin distinguir mayúsculas.
   - También detrás de un prefijo: `http.request.header.authorization`, `x-csrf-token`.
   - Es la segunda capa: cada servicio ya redacta lo suyo.
4. `filter/browser`: solo en las tuberías del navegador.
5. `batch`.

```bash
docker compose up -d collector                  # con docker-socket-proxy
docker compose logs -f collector
docker compose run --rm --no-deps collector validate --config=/etc/otelcol-contrib/config.yaml
python3 scripts/collector-redaction-test.py     # prueba de la redacción (también en CI)
```

**Prueba de la redacción (S7.6).** `scripts/collector-redaction-test.py` levanta el servicio
`collector` con su imagen y `config.yaml`, más `observability/otel-collector/redaction-test.yaml`, que
solo agrega OTLP/HTTP al receptor de los servicios y cambia el envío a SigNoz por un archivo; los
procesadores de cada tubería son los reales.

- Envía un span con un evento, una métrica y un log con claves sensibles en cada nivel (`password`,
  `db.password`, `http.request.header.authorization`, `x-csrf-token`, `Set-Cookie`…), y otras parecidas
  que deben quedar (`auth.passwordless`, `faclab.token_count`).
- También envía por el receptor del navegador un span de `faclab-web` y otro de otro servicio.
- Falla si una clave o un valor sensible llega al archivo, si falta una clave que debe quedar o si
  pasa el span ajeno. Quitar `transform/redact` (o `filter/browser`) de una tubería la hace fallar.
- Usa `.env.example`, nunca `.env`, y solo la biblioteca estándar de Python.

Los receptores que no encuentran su fuente (el core apagado, Kafka sin levantar) registran un error en
cada intento y siguen; no detienen al Collector. Sin SigNoz, el Collector guarda en su cola lo que no
pudo enviar y reintenta.

### Destino y TLS

| Variable | Local | Otro entorno |
|----------|-------|--------------|
| `SIGNOZ_OTLP_ENDPOINT` | `signoz-otel-collector:4317` (el collector de SigNoz en `faclab_network`) | El receptor OTLP de SigNoz (VPS aparte o nube, D-1) |
| `SIGNOZ_OTLP_INSECURE` | `true` (texto plano) | `false`: TLS con los certificados del sistema |
| `TELEMETRY_EXPORTER` | `otlp_grpc/signoz` | `otlp_grpc/signoz`, o `nop` para descartar todo (S8.6) |
| `SIGNOZ_INGESTION_KEY` | vacío | La llave de ingesta de SigNoz Cloud, cabecera `signoz-ingestion-key` |
| `SIGNOZ_OTLP_AUTHORIZATION` | vacío | La cabecera `authorization` (`Bearer <token>`) que revisa el proxy de un receptor autogestionado |
| `COLLECTOR_ENVIRONMENT` | `local` | `staging` o `production` |

`TELEMETRY_EXPORTER` (S8.6) elige el exporter de los cinco pipelines: es una lista de un elemento que
lee la variable, así que no hay un segundo archivo de configuración que mantener. Con `nop` el Collector
sigue recibiendo y procesando, y descarta al final: sin cola que crezca, sin reintentos y sin errores de
exportación. Un nombre que no sea un exporter definido hace que el Collector no arranque (lo prueba
`ci-validate.sh`).

Las dos cabeceras van vacías cuando no hacen falta. Se probó el exporter contra un receptor con TLS y
`bearertokenauth`: entrega con el token correcto, el receptor rechaza uno incorrecto
(`Unauthenticated`), y falla el handshake si el certificado no es de una CA que el sistema conozca.

### Permisos

El Collector solo lee, y cada acceso se da por separado:

- **Docker: proxy de solo lectura.**
  - Montar `/var/run/docker.sock` con `:ro` no limita nada: `:ro` impide cambiar el archivo del socket, no las llamadas a la API. Con el socket se pueden crear, detener o ejecutar contenedores, lo que equivale a root en el host.
  - Por eso solo `docker-socket-proxy` ([tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy), HAProxy) monta el socket. Deja pasar `GET` de `containers`, `events`, `version`, `info` y `_ping`, y rechaza todo lo demás (`POST=0`, el resto de las secciones apagadas).
  - El proxy está en la red interna `docker_api`, que solo comparte con el Collector: ningún otro contenedor llega a él.
  - Aun así, `GET /containers/...` puede leer la configuración, los logs y los archivos de cualquier contenedor. Es menos que el socket, no nada.
  - El Collector avisa al arrancar que la conexión TCP a Docker no lleva TLS (`Unauthenticated TCP connection`); se acepta porque no sale de `docker_api`.
- **PostgreSQL: `faclab_monitor`.**
  - Es un usuario con `pg_monitor`, que lee las vistas de estadísticas (`pg_stat_*`, tamaños, bloqueos) y ninguna fila de las tablas. Además es `NOSUPERUSER`, `NOCREATEDB`, `NOCREATEROLE` y `NOBYPASSRLS`.
  - En `invoicing-db` lo crea `scripts/init-invoicing-db.sh` con `INVOICING_DB_MONITOR_PASSWORD`.
  - En la base del core lo crea `make db-roles` de faclab-core cuando su `.env` tiene `DATABASE_URL_MONITOR`, cuya contraseña es la `CORE_DB_MONITOR_PASSWORD` de aquí.
  - Las muestras de consultas del receptor, que llevarían texto SQL, quedan apagadas.
- **Host: `/` montado en `/hostfs` con `:ro`.** El Collector corre con el usuario sin privilegios de su imagen. Quedan fuera los sistemas de archivos virtuales, los volúmenes de Docker y, en OrbStack, las carpetas de la Mac.

Para un volumen de `invoicing-db` que ya existía, el usuario se crea corriendo otra vez el script de
inicio (es idempotente):

```bash
docker compose up -d invoicing-db   # toma INVOICING_DB_MONITOR_PASSWORD
docker compose exec invoicing-db /docker-entrypoint-initdb.d/init-invoicing-db.sh
```

### Volver atrás

Si el Collector falla, los servicios pueden exportar directo al collector de SigNoz mientras se corrige.
Basta cambiar su variable de endpoint:

- faclab-core: `OTEL_OTLP_ENDPOINT=http://signoz-otel-collector:4317`.
- faclab-invoicing en un contenedor: `OTEL_EXPORTER_OTLP_ENDPOINT=http://signoz-otel-collector:4317`.

Así se pierden las métricas de infraestructura y la segunda capa de redacción.

- `signoz-otel-collector` es un alias del ingester de SigNoz en `faclab_network`. Lo agrega
  `observability/signoz/casting.yaml` para que este camino y `SIGNOZ_OTLP_ENDPOINT` no cambien con Foundry.
- Desde el host no hay camino directo: el ingester no publica puertos.

### En producción

`deploy/production` (S8.1) usa esta misma configuración más `deploy/production/otel-collector.yaml`,
que se le suma como segundo `--config`:

- **Una sola instancia de PostgreSQL.** Deja un solo receptor, `postgresql/core`, hacia la instancia
  compartida: cubre las dos bases.
- **Salud.** Agrega la extensión `health_check` en `:13133`; la consulta `stack.sh status`, porque la
  imagen no tiene shell para un healthcheck de Docker.
- **Sin puertos publicados.** Los servicios llegan por la red interna y el navegador por la ruta `/otlp`
  de Caddy, con 1 MiB y límite por IP.
- **Objetivos de las métricas.** `CORE_HEALTH_URL` e `INVOICING_HEALTH_URL` apuntan a `core-api:8080` e
  `invoicing-api:3173`.
- **Entorno.** `deployment.environment.name` es el `ENVIRONMENT` del despliegue.

- **Telemetría apagada (S8.6).** `TELEMETRY_EXPORTER=nop` en `env/production.env.example`: producción
  arranca sin destino porque aún no hay SigNoz (D-1 sigue abierta). No es un incidente ni una avería:
  las alertas que leen la telemetría callan, y las críticas las cubren los
  [latidos y sondeos](deploy/production/README.md#latidos-y-sondeos). Encenderla es cambiar variables,
  sin tocar imágenes ni código (ver abajo).

**Encenderla** el día que haya un SigNoz al que enviar:

1. En `env/<entorno>.env`:
   ```bash
   TELEMETRY_EXPORTER=otlp_grpc/signoz
   SIGNOZ_OTLP_ENDPOINT=<host:4317>      # el receptor OTLP gRPC, con TLS
   SIGNOZ_OTLP_INSECURE=false
   ```
2. Si el destino pide credencial, en los secretos (`scripts/secrets.sh set <entorno> <nombre>`, el valor
   por la entrada estándar): `SIGNOZ_INGESTION_KEY` para SigNoz Cloud, `SIGNOZ_OTLP_AUTHORIZATION`
   (`Bearer <token>`) para un receptor propio detrás de un proxy.
3. `scripts/secrets.sh push` y `stack.sh install-secrets` en el servidor si cambiaron los secretos, y
   `stack.sh deploy`, que recrea el Collector con las variables nuevas.
4. Aplicar la retención y sincronizar dashboards y alertas (ver «SigNoz en producción»).

Para volver a apagarla, `TELEMETRY_EXPORTER=nop` y el mismo despliegue.

## SigNoz local (observabilidad)

`scripts/signoz.sh` levanta [SigNoz](https://signoz.io) v0.151.0 para ver trazas, métricas y logs de los
servicios (S7.5).

- **Instalación con Foundry.** Desde v0.130, SigNoz ya no trae un Docker Compose: se instala con
  [Foundry](https://github.com/SigNoz/foundry). `foundryctl forge` convierte
  `observability/signoz/casting.yaml` en un compose en `observability/signoz/pours/` (ignorado por git),
  y el script lo levanta.
- **`foundryctl` fijado.** El script baja `foundryctl` v0.5.0 de los releases de GitHub, lo verifica
  contra los sha256 que lleva escritos y lo deja en `.foundry/` (ignorado). El registro anónimo de uso y
  el aviso de actualizaciones de Foundry quedan apagados.
- **Patches del `casting.yaml`:**
  - el ingester (el collector de SigNoz) pierde sus puertos del host y se une a `faclab_network` con el
    alias `signoz-otel-collector`; así `4317` y `4318` del host son del Collector de Faclab, que le
    reenvía;
  - SigNoz se une a `faclab_network` para llegar a Mailpit.

```bash
scripts/signoz.sh up       # forja el casting y levanta SigNoz
docker compose up -d collector
scripts/signoz.sh status   # contenedores y endpoints
scripts/signoz.sh down     # lo detiene; los datos quedan en sus volúmenes
scripts/signoz.sh config   # forja y valida el compose generado (CI)
```

| Componente | Imagen |
|------------|--------|
| SigNoz (API e interfaz) | `signoz/signoz:v0.151.0` |
| Ingester | `signoz/signoz-otel-collector:v0.144.16` |
| ClickHouse y ClickHouse Keeper | `clickhouse/clickhouse-server:25.12.5`, `clickhouse/clickhouse-keeper:25.12.5` |
| Metastore | `postgres:16.16` |

- **Versiones:** son las del chart de Helm 0.151.0 de SigNoz; se actualizan juntas.
- **Interfaz:** queda en [http://localhost:8080](http://localhost:8080).
- **Primer arranque.** Hay que crear la cuenta de administrador en esa interfaz: hasta entonces SigNoz no
  le entrega su configuración al ingester, que no acepta nada, y el Collector de Faclab acumula y
  reintenta. `up` y `status` lo recuerdan mientras falte.
- **Recursos:**
  - Necesita unos 2 GB libres para Docker; ClickHouse es lo más pesado.
  - Desde v0.151 SigNoz guarda los logs dos veces mientras migra a JSON, así que usa más CPU y disco.
  - El `casting.yaml` apaga los logs de sistema de ClickHouse (el perfilador `trace_log`, `text_log`,
    `metric_log` y otros), que Foundry enciende. En una VM de Docker de 4 GB ocupaban varios núcleos
    y dejaban sin aire al resto. Quedan `query_log` y `part_log`.
- **SMTP de las alertas:** el `.env` (`SIGNOZ_SMTP_*`; por defecto Mailpit, sin TLS). Las alertas que
  llegan por correo se ven en [http://localhost:8025](http://localhost:8025).
- **Volver a v0.118** (la instalación anterior, con compose):
  1. `scripts/signoz.sh down`;
  2. `git -C ../Telemetry switch --detach v0.118.0`;
  3. usar el `scripts/signoz.sh` y el `observability/docker-compose.signoz.yml` de la versión anterior de
     este repo.

  Sus volúmenes (`signoz-clickhouse`, `signoz-sqlite`, `signoz-zookeeper-1`) son otros y no se tocan.
  `../Telemetry` ya no hace falta para levantar SigNoz: queda como referencia del código de la versión
  desplegada.

Para que los servicios exporten, ver el detalle en el `.env.example` y el README de cada uno:

| Servicio | Variables |
|----------|-----------|
| faclab-core (contenedor en `faclab_network`) | `OTEL_ENABLED=true`, `OTEL_OTLP_ENDPOINT=http://collector:4317`; para `faclab_monitor`, `DATABASE_URL_MONITOR` y `make db-roles` |
| faclab-invoicing (`npm run dev` en el host) | `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317` (el valor por defecto) |
| faclab-invoicing (contenedor en `faclab_network`) | `OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4317` |
| faclab-web (`npm start`) | `VITE_OTEL_ENABLED=true`; el proxy de Vite lleva `/otlp` a `http://localhost:4318` |

Con todo arriba, una venta del POS se ve en SigNoz como una sola traza: el request en faclab-core, `send sales.confirmed`, `process sales.confirmed` en faclab-invoicing, `send invoices` y `process invoices` de vuelta en faclab-core.

## SigNoz en producción (S8.6)

No hay SigNoz de producción todavía: D-1 (VPS aparte o SigNoz Cloud) sigue abierta y la telemetría está
apagada (ver «En producción»). Esto es lo que se probó contra el SigNoz local y lo que habrá que hacer el
día que exista.

### Dónde correrá

- **SigNoz Cloud:** no hay servidor; se crea la cuenta, se copia la llave de ingesta a
  `SIGNOZ_INGESTION_KEY` y se sigue desde «Retención» abajo (la retención se fija en su consola).
- **Un VPS aparte:** `casting.yaml` con las versiones fijadas (v0.151.0) y 8 GB de RAM como punto de
  partida: ClickHouse, su Keeper, PostgreSQL, el ingester y SigNoz no caben bien en 4 GB (el VPS-1 de
  OVHcloud, de 2 vCores, 4 GB y 40 GB, sirve de laboratorio, no de producción). El receptor OTLP lo
  protege un proxy con TLS y un token (`SIGNOZ_OTLP_AUTHORIZATION`); el puerto 4317 de SigNoz no se
  publica.

### Retención por señal (D-7)

`scripts/signoz.sh retention` fija y relee la retención, y es idempotente. Por defecto, la de D-7:
logs 15 días, trazas 7 y métricas 90 (`--logs-days`, `--traces-days` y `--metrics-days` la cambian;
`--dry-run` solo muestra qué cambiaría).

```bash
SIGNOZ_URL=https://signoz.<dominio> SIGNOZ_API_KEY=... scripts/signoz.sh retention --dry-run
scripts/signoz.sh retention
```

- Trazas y métricas van por la API v1 (en horas) y los logs solo por la v2 (en días): la v1 contesta
  «SetTTLV2 only supported» para ellos.
- Cambiarla es una mutación de ClickHouse: SigNoz la acepta enseguida y la aplica después. Mientras
  tanto el comando informa «aceptada, aplicándose».
- Los valores por defecto de SigNoz son 15 días para logs y trazas y 30 para métricas. Se probó con los
  de D-7 en el SigNoz local y se restauraron los anteriores.
- Medir el disco el primer mes y ajustar: la alerta `disco` y su [runbook](observability/runbooks/disco.md)
  avisan antes de que ClickHouse llene el volumen.

### Cuentas y secretos

- **Sin cuentas por defecto.** SigNoz no trae usuarios: la primera cuenta, que es administradora, la
  crea quien instala, con su correo (no uno compartido). Después, cada persona con su usuario y el rol
  mínimo (Admin, Editor o Viewer) desde la interfaz.
- **`signoz.sh sync` y `retention`** usan la llave de una *service account* con rol Admin (Settings,
  Service Accounts). Esa llave vive en el `.env` de quien opera, no en el servidor.
- **Sin secreto JWT por defecto (G-52).** La instalación vieja traía el secreto `secret` del proyecto.
  SigNoz v0.151 usa tokens opacos (los guarda en su tabla `auth_token`) y se negaría a arrancar con el
  proveedor `jwt` sin un secreto propio. Se verificó en el SigNoz local: sin ninguna variable
  `SIGNOZ_TOKENIZER_*` ni de secreto, arranca, así que el secreto no interviene. Comprobarlo de nuevo al
  desplegar: `docker inspect signoz-signoz-0` no debe mostrar variables de tokenizer ni de secreto.
- **SMTP y avisos:** `SIGNOZ_SMTP_*` (SMTP real), `ALERT_EMAIL_TO`, `TELEGRAM_BOT_TOKEN` y
  `TELEGRAM_CHAT_ID` (el bot de producción) y `SIGNOZ_EXTERNAL_URL` en el `.env` de quien sincroniza,
  y `scripts/signoz.sh sync`. Los valores reales no se escriben en este repositorio.

### Actualizar

1. Leer las notas de la versión y subir juntas las imágenes de `casting.yaml` (SigNoz, su ingester,
   ClickHouse y su Keeper): son las del chart de Helm de esa versión.
2. Respaldar antes el metastore (ver abajo).
3. `scripts/signoz.sh config` valida el compose generado; `up` aplica la actualización (el migrador del
   almacén corre al arrancar).
4. `scripts/signoz.sh verify` ejecuta cada panel y alerta contra la versión nueva.
5. Volver atrás: las imágenes anteriores en `casting.yaml`, `up` y, si la base cambió, restaurar el
   volcado del metastore.

### Respaldo

Lo que se pierde si se pierde el servidor, de menos a más difícil de rehacer:

| Qué | Cómo se recupera |
|---|---|
| Dashboards, alertas y canales | Son código: `scripts/signoz.sh sync` los recrea |
| Cuentas, roles y llaves de API (metastore PostgreSQL) | El volcado de abajo |
| Datos de telemetría (ClickHouse) | No se respaldan: son de 7 a 90 días y se regeneran. Si el histórico llegara a importar, `BACKUP` de ClickHouse a un almacenamiento externo, que no está montado |

El volcado del metastore (probado en el SigNoz local; contiene contraseñas y llaves, así que se cifra
y va fuera del servidor, como los respaldos de [RESPALDOS.md](deploy/production/RESPALDOS.md)):

```bash
docker exec signoz-metastore-postgres-0 sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  | age -r <clave pública> > signoz-metastore-$(date +%F).sql.age
```

Restaurar: levantar solo el metastore, `age -d … | docker exec -i signoz-metastore-postgres-0 psql -U signoz -d signoz`
con la base vacía, y `up`. Un simulacro de la restauración queda pendiente hasta que exista el servidor.

## Dashboards y alertas

Los dashboards, las alertas y los canales de notificación de SigNoz viven como archivos en
`observability/signoz/` (S7.5, OBSERVABILITY.md §7–§8 del core). Cada alerta enlaza a su runbook en
`observability/runbooks/`.

| Dashboard | Pregunta que responde |
|-----------|-----------------------|
| Faclab · Ecosistema | ¿Está sano el sistema ahora? Disponibilidad, 5xx, latencia, colas y el navegador (errores de interfaz y web vitals) |
| Faclab · API Core | ¿Qué ruta o dependencia degrada la experiencia? |
| Faclab · Kafka y mensajería | ¿Fluyen los mensajes? Outbox, envíos, consumo, lag y mensajes fallidos |
| Faclab · Facturación electrónica | ¿Se autorizan los comprobantes a tiempo? Cola, SRI, rechazos, entregas y certificados |
| Faclab · Base de datos e infraestructura | ¿Hay saturación? Host, contenedores, PostgreSQL y Kafka |
| Faclab · Calidad de operaciones | ¿Qué necesita intervención? Ventas fallidas, stock, conciliación, webhooks y logins |

Las 22 alertas y sus umbrales iniciales están en el [índice de runbooks](observability/runbooks/README.md).
Son provisionales hasta tener la línea base del piloto (S9.2).

### Importarlos

1. En SigNoz: *Settings → Service Accounts*. Crea una cuenta, asígnale el rol **Admin** y genera su llave
   de API. Una cuenta sin rol recibe 403 en todo.
2. En el `.env`:
   - `SIGNOZ_API_KEY`: la llave;
   - `ALERT_EMAIL_TO`: los destinatarios de todas las alertas;
   - opcional, `TELEGRAM_BOT_TOKEN` y `TELEGRAM_CHAT_ID`: el canal de las críticas.

   Esos valores no van al repositorio.
3. Corre los comandos:

```bash
scripts/signoz.sh check            # sin red: estructura, descripciones de los paneles, runbooks (CI)
scripts/signoz.sh sync --dry-run   # qué crearía o cambiaría
scripts/signoz.sh sync             # crea o actualiza canales, dashboards y alertas
scripts/signoz.sh verify           # corre cada consulta de paneles y alertas en SigNoz
```

`sync` es idempotente:

- reconoce cada dashboard por su `name` (`faclab-<slug>`) y cada alerta por su etiqueta
  `faclab_rule`;
- crea lo que falta, actualiza lo que difiere y deja igual lo demás;
- con `--prune` borra los dashboards y alertas de Faclab que ya no tienen archivo.

Un dashboard bloqueado en la interfaz no se actualiza: hay que desbloquearlo.

| Canal | Nivel | Variables |
|-------|-------|-----------|
| `faclab-correo` | Advertencias y críticas | `ALERT_EMAIL_TO`; el envío usa el SMTP de SigNoz (`SIGNOZ_SMTP_*`) |
| `faclab-telegram` | Solo críticas | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` |

Las alertas nombran sus canales por el nombre visible, que el script hace igual al `name`. Si un canal no
está configurado, `sync` lo quita de las alertas y lo avisa.

### Cambiarlos

- **Desde los archivos.** Se edita el JSON y se corre `sync`.
- **Desde la interfaz.** Se exporta el dashboard (JSON) y se reemplaza su archivo, conservando
  `name` y el tag `faclab:observabilidad`.
- **Cada panel** dice en su descripción su consulta, su unidad, su umbral y la acción; `check` falla si
  falta alguna.
- **Volver atrás** es reimportar la versión anterior de los archivos con `sync`.

Cómo se provocó cada alerta y la evidencia: [pruebas de alertas](observability/signoz/pruebas-de-alertas.md).

## Correo de desarrollo

`mailpit` es [Mailpit](https://mailpit.axllent.org), un servidor SMTP que guarda los mensajes en
vez de entregarlos (S4.4). faclab-invoicing envía ahí, en local, cada factura autorizada a su
comprador: el RIDE (PDF) y el XML autorizado como adjuntos. Sus valores locales por defecto ya
apuntan a él (`SMTP_HOST=localhost`, `SMTP_PORT=1025`); desde un contenedor de `faclab_network`,
`SMTP_HOST=mailpit`.

| Dato | Valor local |
|------|-------------|
| SMTP | `localhost:1025`, sin TLS; acepta cualquier usuario y contraseña |
| Interfaz web | [http://localhost:8025](http://localhost:8025): los correos recibidos, con sus adjuntos |
| Límite | Guarda los últimos 500 mensajes (`MP_MAX_MESSAGES`), sin volumen: se pierden al recrear el contenedor |

El proveedor de correo real de cada entorno se configura en faclab-invoicing (`SMTP_*`, decisión
D-3: cualquier servicio SMTP). `deploy/production` ya lo recibe por configuración (`env/` y
`secrets.env`); el producto, con SPF, DKIM y DMARC, se elige con el primer VPS.

## Despliegue en producción

`deploy/production/` es el stack de producción en un VPS con Docker Compose (S8.1, ADR-0011 del
core):

- Caddy con TLS y límites por IP;
- faclab-web;
- el API y el worker de faclab-core y de faclab-invoicing;
- PostgreSQL 17 con las dos bases y sus roles;
- Kafka solo en la red interna, con los tópicos de `scripts/create-topics.sh`;
- Garage y el Collector.

Solo Caddy publica puertos (80 y 443). Los secretos viven cifrados con sops y age fuera de este
repositorio.

Desde S8.2 las imágenes salen de GitHub Container Registry, publicadas por el tag de cada
repositorio:

- `deploy/production/versions/<entorno>.env` dice qué versión de cada uno corre en cada entorno, y
  cambiarla es un PR;
- `deploy/production/scripts/deploy.sh`, desde tu máquina o desde el workflow `Deploy`, la despliega:
  respaldo, migraciones, servicios en orden y verificación de salud;
- si algo falla, vuelve sola a la versión anterior;
- la [matriz de compatibilidad](deploy/production/COMPATIBILITY.md) dice qué versiones funcionan
  juntas.

La guía completa, desde un servidor limpio hasta una venta facturada, con el despliegue y la
reversión, está en [deploy/production/README.md](deploy/production/README.md).

## Versiones y publicación

faclab-infra sigue la misma convención que core, invoicing y web (S8.2):

- **Versiones.** Cada una es un tag `vX.Y.Z` con [versionado semántico](https://semver.org/lang/es/),
  0.x hasta el piloto. Lo que trae está en [CHANGELOG.md](CHANGELOG.md).
- **Preparar.** `scripts/release.sh minor` (o `major`, `patch`, `X.Y.Z`), en `master` al día, crea la
  rama `release/vX.Y.Z` con la sección del CHANGELOG escrita desde los commits convencionales. Se
  sube con un PR titulado `chore(release): vX.Y.Z`.
- **Etiquetar.** Después del merge, `scripts/release.sh tag X.Y.Z` crea el tag; `git push origin
  vX.Y.Z` lo publica.
- **Publicar.** El tag corre `.github/workflows/release.yml`, que publica el Caddy de entrada
  (`deploy/production/caddy`) como `ghcr.io/faclab-ec/faclab-caddy:X.Y.Z` para amd64 y arm64. El
  servidor ya no lo compila.
- **Desplegar.** La versión de faclab-infra que corre un entorno es `INFRA_VERSION` de su archivo de
  versiones. El servidor hace checkout de ese tag y usa su `compose.yaml` y sus scripts.

Una **prerelease** (`vX.Y.Z-rc.1`) se publica desde cualquier commit subido y sirve para staging;
producción solo acepta versiones finales.

## Variables de entorno

Consulta `.env.example` para ver todas las variables disponibles y sus valores por defecto.

## Integracion continua

Cada PR y cada push a `master` corren `.github/workflows/ci.yml` en GitHub Actions (job `validate`):

- valida `docker-compose.yml` con las variables de `.env.example`;
- valida la configuración del Collector con su imagen fijada (`otelcol validate`, con los volúmenes y variables del servicio);
- revisa los scripts con ShellCheck;
- forja `observability/signoz/casting.yaml` con el `foundryctl` fijado y valida el compose generado (`scripts/signoz.sh config`);
- valida los dashboards, las alertas y los runbooks sin red (`scripts/signoz-sync.py check`);
- revisa los workflows con `actionlint` (los de release y despliegue solo corren con un tag o a mano);
- valida el stack de producción (`deploy/production/scripts/ci-validate.sh`):
  - el compose con cada archivo de entorno y sus versiones, con las imágenes publicadas de cada una;
  - las dos combinaciones de versiones contra la matriz de compatibilidad (`compat.py`);
  - la imagen de Caddy y su `Caddyfile` en los dos modos de TLS;
  - el Collector con su overlay;
  - que ningún archivo de secretos esté versionado.

Para correr lo mismo en local:

```bash
docker compose --env-file .env.example config -q
docker compose --env-file .env.example run --rm --no-deps collector validate --config=/etc/otelcol-contrib/config.yaml
shellcheck scripts/*.sh deploy/production/scripts/*.sh   # o: docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable ...
scripts/signoz.sh config
python3 scripts/signoz-sync.py check
docker run --rm -v "$PWD:/repo:ro" --workdir /repo rhysd/actionlint:1.7.12
deploy/production/scripts/ci-validate.sh
```

## Comandos utiles

```bash
# Ver logs de un servicio
docker compose logs -f kafka

# Reiniciar un servicio
docker compose restart kafka

# Detener todo
docker compose down

# Detener y eliminar volumenes (reset completo)
docker compose down -v
```
