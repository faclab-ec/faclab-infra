# Faclab Infra

Infraestructura local compartida para el ecosistema Faclab. Provee los servicios base que consumen el sistema principal y los microservicios.

## Servicios

| Servicio | Imagen | Puerto local | Descripcion |
|----------|--------|--------------|-------------|
| **Kafka** | `confluentinc/cp-kafka` | `29092` | Broker de mensajeria (modo KRaft, sin Zookeeper) |
| **Kafka UI** | `provectuslabs/kafka-ui` | `9091` | Interfaz web para monitorear topics, consumers y mensajes |
| **LocalStack** | `localstack/localstack` | `4566` | Emulador local de servicios AWS (DynamoDB) |

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

## Estructura del proyecto

```
faclab-infra/
├── docker-compose.yml          # Definicion de servicios
├── .env.example                # Variables de entorno (plantilla)
├── .env                        # Variables de entorno (no versionado)
├── scripts/
│   └── init-dynamodb.sh        # Crea tablas DynamoDB en LocalStack al iniciar
└── .docker/
    └── .volumes/aws/           # Datos persistentes de LocalStack
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
| DynamoDB (LocalStack) | `http://aws-local:4566` |

### Endpoints externos (desde el host)

| Servicio | URL |
|----------|-----|
| Kafka | `localhost:29092` |
| Kafka UI | [http://localhost:9091](http://localhost:9091) |
| DynamoDB (LocalStack) | `http://localhost:4566` |

## Tablas DynamoDB

Se crean automaticamente al iniciar LocalStack mediante `scripts/init-dynamodb.sh`:

| Tabla | Servicio | Partition Key | GSI |
|-------|----------|---------------|-----|
| `certificates` | faclab-invoicing | `id` | `SerialNumberIndex` (`serial_number`) |
| `company_config` | faclab-invoicing | `id` | — |
| `invoices` | faclab-invoicing | `id` | `SaleIdIndex` (`saleId`), `StatusIndex` (`status`) |

Si la tabla ya existía, el script agrega los índices que falten (`add_index_if_not_exists`). Para aplicarlo sin reiniciar LocalStack:

```bash
docker compose exec localstack /etc/localstack/init/ready.d/init-dynamodb.sh
```

## Variables de entorno

Consulta `.env.example` para ver todas las variables disponibles y sus valores por defecto.

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
