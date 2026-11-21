# Faclab Infra

Infraestructura local compartida para el ecosistema Faclab. Provee los servicios base que consumen el sistema principal y los microservicios.

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
├── garage/
│   └── garage.toml             # Configuracion de Garage (un nodo, sin replicacion)
├── observability/
│   ├── docker-compose.signoz.yml  # Une el collector de SigNoz a faclab_network y le quita los puertos del host
│   └── otel-collector/
│       └── config.yaml            # Configuración del OTel Collector (receptores, redacción, envío a SigNoz)
├── scripts/
│   ├── create-topics.sh        # Crea los tópicos de Kafka con varias particiones
│   ├── init-invoicing-db.sh    # Crea el rol y las bases de faclab-invoicing
│   └── signoz.sh               # Levanta SigNoz local (up, down, status, config)
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
| `dlq` | faclab-invoicing (mensajes que no pudo procesar) | — |

- Desde S4.2 faclab-invoicing ya no usa `invoices` para avanzar sus facturas: lo hace una cola en su
  base de datos, y el tópico solo lleva al core el resultado de cada una.
- Cada tópico tiene `KAFKA_TOPIC_PARTITIONS` particiones (6 por defecto) y replicación 1 (un solo
  nodo). Los mensajes llevan como clave la empresa (`tenant_id`): los de una empresa van en orden
  por la misma partición y las empresas se reparten entre las demás.
- Es idempotente: un tópico que ya existe conserva sus mensajes, y si tiene menos particiones crece
  hasta `KAFKA_TOPIC_PARTITIONS` (Kafka no las reduce). Al crecer, los mensajes nuevos de una empresa
  pueden ir a otra partición, así que conviene hacerlo con el tópico quieto.
- Para correrlo de nuevo (por ejemplo, después de cambiar `KAFKA_TOPIC_PARTITIONS`):
  `docker compose run --rm kafka-topics`.
- Los mensajes que faclab-core no pudo procesar no van a `dlq` sino a su tabla `dead_letters`, que se
  reprocesa con `make reprocess-dead-letter` en faclab-core.

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

Los datos quedan en el volumen `faclab-infra_object_storage_data`. Se eligió Garage porque MinIO
dejó de publicar imágenes de su edición comunitaria en 2025 y archivó su repositorio en 2026; qué
servicio corre en el VPS se decide en S8.1 y la copia fuera del servidor, en S8.3. Cualquier
servicio compatible con S3 sirve: faclab-invoicing solo usa su API.

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
```

Los receptores que no encuentran su fuente (el core apagado, Kafka sin levantar) registran un error en
cada intento y siguen; no detienen al Collector. Sin SigNoz, el Collector guarda en su cola lo que no
pudo enviar y reintenta.

### Destino y TLS

| Variable | Local | Otro entorno |
|----------|-------|--------------|
| `SIGNOZ_OTLP_ENDPOINT` | `signoz-otel-collector:4317` (el collector de SigNoz en `faclab_network`) | El receptor OTLP de SigNoz (VPS aparte o nube, D-1) |
| `SIGNOZ_OTLP_INSECURE` | `true` (texto plano) | `false`: TLS con los certificados del sistema |
| `COLLECTOR_ENVIRONMENT` | `local` | `staging` o `production` |

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

Así se pierden las métricas de infraestructura y la segunda capa de redacción. Desde el host no hay
camino directo, porque el overlay le quita a SigNoz sus puertos.

### En producción

Queda para S8.1 (VPS) y S8.6 (SigNoz):

- los puertos del Collector no se publican: los servicios llegan por la red interna y el navegador por la ruta `/otlp` de Caddy, con límite de tamaño y de frecuencia;
- el destino con TLS y, si D-1 elige SigNoz Cloud, su llave de ingesta;
- `CORE_HEALTH_URL` hacia el API de producción (`:8080`);
- `COLLECTOR_ENVIRONMENT=production`.

## SigNoz local (observabilidad)

`scripts/signoz.sh` levanta [SigNoz](https://signoz.io) para ver trazas, métricas y logs de los servicios.
Usa el Docker Compose del propio SigNoz más `observability/docker-compose.signoz.yml`, que une su
collector de OpenTelemetry a `faclab_network` y le quita los puertos del host (`ports: !reset []`,
Compose 2.24 o más nuevo). Así `4317` y `4318` del host son del Collector de Faclab, que reenvía a
`signoz-otel-collector:4317`.

```bash
scripts/signoz.sh up       # levanta SigNoz (la primera vez lo clona)
docker compose up -d collector
scripts/signoz.sh status   # contenedores y endpoints
scripts/signoz.sh down     # lo detiene; los datos quedan en sus volúmenes
```

- Busca SigNoz en `../Telemetry`, junto a este repo; `SIGNOZ_DIR` cambia la ruta. Si no existe, clona solo `deploy/` de la etiqueta `SIGNOZ_VERSION` (por defecto `v0.118.0`).
- Necesita varios GB de memoria libres para Docker (ClickHouse y ZooKeeper).
- La interfaz queda en [http://localhost:8080](http://localhost:8080).
- **La primera vez hay que crear la cuenta de administrador en esa interfaz.** Hasta entonces SigNoz no le entrega su configuración a su collector, que no acepta nada; el Collector de Faclab acumula y reintenta. `up` y `status` lo recuerdan mientras falte.

Para que los servicios exporten, ver el detalle en el `.env.example` y el README de cada uno:

| Servicio | Variables |
|----------|-----------|
| faclab-core (contenedor en `faclab_network`) | `OTEL_ENABLED=true`, `OTEL_OTLP_ENDPOINT=http://collector:4317`; para `faclab_monitor`, `DATABASE_URL_MONITOR` y `make db-roles` |
| faclab-invoicing (`npm run dev` en el host) | `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317` (el valor por defecto) |
| faclab-invoicing (contenedor en `faclab_network`) | `OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4317` |
| faclab-web (`npm start`) | `VITE_OTEL_ENABLED=true`; el proxy de Vite lleva `/otlp` a `http://localhost:4318` |

Con todo arriba, una venta del POS se ve en SigNoz como una sola traza: el request en faclab-core, `send sales.confirmed`, `process sales.confirmed` en faclab-invoicing, `send invoices` y `process invoices` de vuelta en faclab-core.

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
D-3: cualquier servicio SMTP); se elige al desplegar (S8.1).

## Variables de entorno

Consulta `.env.example` para ver todas las variables disponibles y sus valores por defecto.

## Integracion continua

Cada PR y cada push a `master` corren `.github/workflows/ci.yml` en GitHub Actions (job `validate`):

- valida `docker-compose.yml` con las variables de `.env.example`;
- valida la configuración del Collector con su imagen fijada (`otelcol validate`, con los volúmenes y variables del servicio);
- revisa los scripts con ShellCheck;
- valida el compose de SigNoz con `observability/docker-compose.signoz.yml` (`scripts/signoz.sh config`).

Para correr lo mismo en local:

```bash
docker compose --env-file .env.example config -q
docker compose --env-file .env.example run --rm --no-deps collector validate --config=/etc/otelcol-contrib/config.yaml
shellcheck scripts/*.sh   # o: docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable scripts/*.sh
scripts/signoz.sh config
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
