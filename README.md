# Faclab Infra

Infraestructura local compartida para el ecosistema Faclab. Provee los servicios base que consumen el sistema principal y los microservicios.

## Servicios

| Servicio | Imagen | Puerto local | Descripcion |
|----------|--------|--------------|-------------|
| **Kafka** | `confluentinc/cp-kafka` | `29092` | Broker de mensajeria (modo KRaft, sin Zookeeper) |
| **Kafka UI** | `provectuslabs/kafka-ui` | `9091` | Interfaz web para monitorear topics, consumers y mensajes |
| **invoicing-db** | `postgres:17` | `5434` | Base de datos de faclab-invoicing (`faclab_invoicing` y `faclab_invoicing_test`) |

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
├── observability/
│   └── docker-compose.signoz.yml  # Une el collector de SigNoz a faclab_network
├── scripts/
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

### Endpoints externos (desde el host)

| Servicio | URL |
|----------|-----|
| Kafka | `localhost:29092` |
| Kafka UI | [http://localhost:9091](http://localhost:9091) |
| PostgreSQL de faclab-invoicing | `localhost:5434` |

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

## SigNoz local (observabilidad)

`scripts/signoz.sh` levanta [SigNoz](https://signoz.io) para ver trazas, métricas y logs de los servicios. Usa el Docker Compose del propio SigNoz más `observability/docker-compose.signoz.yml`, que une su collector de OpenTelemetry a `faclab_network`.

```bash
scripts/signoz.sh up       # levanta SigNoz (la primera vez lo clona)
scripts/signoz.sh status   # contenedores y endpoints
scripts/signoz.sh down     # lo detiene; los datos quedan en sus volúmenes
```

- Busca SigNoz en `../Telemetry`, junto a este repo; `SIGNOZ_DIR` cambia la ruta. Si no existe, clona solo `deploy/` de la etiqueta `SIGNOZ_VERSION` (por defecto `v0.118.0`).
- Necesita varios GB de memoria libres para Docker (ClickHouse y ZooKeeper).
- La interfaz queda en [http://localhost:8080](http://localhost:8080).
- **La primera vez hay que crear la cuenta de administrador en esa interfaz.** Hasta entonces SigNoz no le entrega su configuración al collector y nada escucha en 4317/4318: los servicios ven `UNAVAILABLE` al exportar. `up` y `status` lo recuerdan mientras falte.

Para que los servicios exporten a SigNoz, ver el detalle en el `.env.example` y el README de cada uno:

| Servicio | Variables |
|----------|-----------|
| faclab-core (contenedor en `faclab_network`) | `OTEL_ENABLED=true`, `OTEL_OTLP_ENDPOINT=http://signoz-otel-collector:4317` |
| faclab-invoicing (`npm run dev` en el host) | `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317` (el valor por defecto) |
| faclab-invoicing (contenedor en `faclab_network`) | `OTEL_EXPORTER_OTLP_ENDPOINT=http://signoz-otel-collector:4317` |

Con todo arriba, una venta del POS se ve en SigNoz como una sola traza: el request en faclab-core, `send sales.confirmed`, `process sales.confirmed` en faclab-invoicing, `send invoices` y `process invoices` de vuelta en faclab-core.

## Variables de entorno

Consulta `.env.example` para ver todas las variables disponibles y sus valores por defecto.

## Integracion continua

Cada PR y cada push a `master` corren `.github/workflows/ci.yml` en GitHub Actions (job `validate`): valida `docker-compose.yml` con las variables de `.env.example`, revisa los scripts con ShellCheck y valida el compose de SigNoz con `observability/docker-compose.signoz.yml` (`scripts/signoz.sh config`).

Para correr lo mismo en local:

```bash
docker compose --env-file .env.example config -q
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
