# Cambios

Cada versión de faclab-infra y lo que trae, la más reciente arriba. Sigue
[versionado semántico](https://semver.org/lang/es/): mientras empiece por 0 (hasta el piloto), una
versión menor puede romper la compatibilidad. `scripts/release.sh` escribe cada sección a partir de
los commits convencionales de `master` (README, "Versiones y publicación").

Una versión de faclab-infra es el stack de producción de ese tag (`deploy/production`) y la imagen
del Caddy de entrada, `ghcr.io/faclab-ec/faclab-caddy`. Si su `compose.yaml` necesita una versión
mínima de core, invoicing o web, su sección lo dice en una línea **Requiere**, y la
[matriz de compatibilidad](deploy/production/COMPATIBILITY.md) también.

## [0.1.0] - 2026-11-22

Primera versión etiquetada: el entorno de desarrollo, la observabilidad (Collector, SigNoz) y el
stack de producción de S8.1, con la entrega continua de S8.2 (imágenes de GHCR, `deploy.sh`,
reversión automática y matriz de compatibilidad). La historia anterior está en el historial de Git.

- **Requiere:** faclab-core 0.1.0, faclab-invoicing 0.1.0 y faclab-web 0.1.0.
