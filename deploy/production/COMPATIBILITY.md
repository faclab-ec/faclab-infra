# Matriz de compatibilidad

Qué versiones de faclab-core, faclab-invoicing, faclab-web y faclab-infra funcionan juntas (S8.2).
Cada repositorio tiene su propia versión (un tag `vX.Y.Z`, CHANGELOG en cada uno), y un entorno corre
una combinación: la de `versions/<entorno>.env`.

`scripts/compat.py` lee la tabla de abajo y comprueba una combinación:

- **En el CI de faclab-infra**, para `versions/staging.env` y `versions/production.env`: un PR que
  cambia una versión no pasa si la combinación no es compatible.
- **En `scripts/deploy.sh`**, antes de tocar el servidor.

```bash
deploy/production/scripts/compat.py deploy/production/versions/staging.env
deploy/production/scripts/compat.py infra=0.1.0 core=0.2.0 invoicing=0.1.0 web=0.1.0
```

## Cómo se lee

Cada fila es una versión publicada de un servicio. Una prerelease (`0.2.0-rc.1`) usa la fila de su
versión base (`0.2.0`).

- **Publica:** los mensajes de Kafka que produce, con la versión de su esquema (`schema_version`,
  [ADR-0006](https://github.com/faclab-ec/faclab-api/blob/master/docs/architecture/ADR/0006-contratos-de-eventos-versionados.md);
  los esquemas están en `contracts/events` del core).
- **Acepta:** los mensajes que consume y el rango de versiones que entiende.
- **Requiere:** la versión mínima de otro servicio, por lo que no es un mensaje de Kafka:
  - faclab-web llama a las API de administración y POS del core y a la de facturación;
  - faclab-invoicing verifica los tokens del core con su JWKS;
  - el stack de faclab-infra pasa a cada imagen las variables que esa versión lee.

Una combinación es compatible cuando:

1. cada versión tiene su fila;
2. cada mensaje que publica un servicio está en el rango que acepta el servicio que lo consume, y
   alguno lo consume;
3. cada requisito se cumple.

## Al publicar una versión

En el mismo PR que la lleva a un entorno (el que cambia `versions/<entorno>.env`), agrega su fila:

- **core o invoicing:** copia la fila anterior y cambia lo que cambió su CHANGELOG (líneas
  **Contratos**).
  - Core: los `*_SCHEMA_VERSION` de `src/invoicing/infra/event_handlers.py` (publica) y los
    `SUPPORTED_SCHEMA_VERSIONS` de `invoice_messages.py` y `credit_note_messages.py` (acepta).
  - Invoicing: los `schema_version` de `src/modules/invoice/infra/messaging/schemas.ts` (acepta) y lo
    que escriben sus productores (publica).
- **web:** la versión mínima del core y de invoicing con la que se probó (línea **Requiere** de su
  CHANGELOG).
- **infra:** lo mismo, si su `compose.yaml` pasa una variable nueva a una imagen.

Las reglas para cambiar un contrato y el orden de despliegue de cada cambio están en
`contracts/README.md` y `contracts/CHANGELOG.md` del core. Una versión incompatible del productor va
después de que el consumidor acepte la nueva. Con la matriz, el CI lo impide.

Lo que la matriz no cubre:

- **La API pública** (`/api/v1`) tiene su propio contrato versionado: core 1.1.0, invoicing 1.0.0.
  `public-api-compat` del CI de cada uno rechaza un cambio incompatible.
- **Las API internas entre la web y el core:** `check:contract` de faclab-web compara la web con el
  OpenAPI del core.

## Matriz

<!-- matrix:start -->
| Servicio | Versión | Publica | Acepta | Requiere |
|---|---|---|---|---|
| core | 0.1.0 | sales.confirmed v3, credit_notes.requested v2 | invoices v1, credit_notes.results v1 | — |
| invoicing | 0.1.0 | invoices v1, credit_notes.results v1 | sales.confirmed v1–v3, credit_notes.requested v1–v2 | core ≥ 0.1.0 |
| web | 0.1.0 | — | — | core ≥ 0.1.0, invoicing ≥ 0.1.0 |
| infra | 0.1.0 | — | — | core ≥ 0.1.0, invoicing ≥ 0.1.0, web ≥ 0.1.0 |
<!-- matrix:end -->
