# Respaldos

> Reglas:
>
> - `respaldo-fallido` (`faclab.backup.failed`, por `faclab.backup.job`): **advertencia**;
> - `respaldo-atrasado` (`faclab.backup.overdue`, por `faclab.backup.job`; o el reporte ausente 30
>   minutos): **advertencia**;
> - `wal-sin-archivar` (`faclab.backup.wal.failing`, 15 minutos seguidos): **crítica**.
>
> Dashboard: *Faclab · Base de datos e infraestructura*, sección «Respaldos».

## Síntoma

Los respaldos de PostgreSQL (pgBackRest) o la copia de los comprobantes fuera del servidor no se
están haciendo. Las métricas las envía `deploy/production/scripts/backups.sh report` cada 5 minutos;
la guía completa está en [RESPALDOS.md](../../deploy/production/RESPALDOS.md).

- **`respaldo-fallido`:** la última corrida de un trabajo falló. Los trabajos son:
  - `full`: el completo de los domingos;
  - `incr`: el incremental de lunes a sábado;
  - `objects`: la copia completa diaria de los comprobantes;
  - `objects-recent`: la copia de los comprobantes de las últimas 24 horas, cada 5 minutos.
- **`respaldo-atrasado`:** según el trabajo:
  - `incr`: no hay ningún respaldo de PostgreSQL de las últimas 26 horas;
  - `full`: no hay un completo de los últimos 8 días;
  - `objects`: la copia de comprobantes no terminó bien en la última hora.

  Sin datos durante 30 minutos significa que el reporte mismo no corre: el timer, PostgreSQL o el
  Collector están caídos.
- **`wal-sin-archivar`:** PostgreSQL no logra enviar el WAL al repositorio. Es crítica:
  - la recuperación a un punto en el tiempo pierde lo escrito desde la falla;
  - el WAL se acumula en `pg_wal` hasta `archive-push-queue-max` (4 GiB). Después, pgBackRest lo
    descarta y la cadena tiene un hueco hasta el próximo respaldo completo.

## Diagnóstico

En el servidor, desde el checkout de faclab-infra:

```bash
sudo deploy/production/scripts/backups.sh status        # respaldos, archivo de WAL, últimas corridas, timers
journalctl -u 'faclab-backup@*' --since today           # el log de cada corrida
sudo deploy/production/scripts/backups.sh check         # archiva un segmento de punta a punta
```

Causas frecuentes:

1. **El almacenamiento externo no responde o rechaza la llave.**
   - pgBackRest dice `unable to connect`, `HTTP 403` o `InvalidAccessKeyId`.
   - rclone dice `AccessDenied` o `connection refused`.
   - Revisa el estado del proveedor y si la llave sigue vigente.
2. **El servidor no sale a Internet.** Lo comprueba `stack.sh compose exec postgres curl -sI
   https://<BACKUP_S3_ENDPOINT>`.
3. **Un despliegue recreó PostgreSQL a mitad de un respaldo.** El log del trabajo termina en un error
   de conexión a la hora del despliegue (`stack.sh deployments`).
4. **Disco lleno** en el servidor ([Disco](disco.md)): la cola de WAL y el spool viven en él.
5. **El reporte no llega** (sin datos):
   - `systemctl list-timers 'faclab-backup@*'`: los timers deben aparecer;
   - `journalctl -u faclab-backup@report`;
   - `stack.sh status`: PostgreSQL y el Collector deben estar sanos.

## Acción

- **Credenciales vencidas o rotadas:**
  1. carga la llave nueva con `secrets.sh set <entorno> BACKUP_PG_ACCESS_KEY_ID` (y las que
     cambiaron), y luego `push` e `install-secrets`;
  2. `stack.sh up` recrea `postgres` con las nuevas.
- **Cuando la causa se corrigió:**
  - repite el trabajo, sin esperar al timer: `sudo systemctl start faclab-backup@incr` (o `full`,
    `objects`);
  - comprueba con `backups.sh status`.
- **Después de un hueco en el WAL** (`wal-sin-archivar` sostenida, o pgBackRest avisó que descartó
  segmentos): corre un completo apenas se pueda (`systemctl start faclab-backup@full`). La
  recuperación a un punto en el tiempo vuelve a ser continua desde ese completo.
- **Timers ausentes:** `sudo deploy/production/scripts/backups.sh install-timers`.

## Escalamiento

- **`wal-sin-archivar`:** atiéndela en la hora. Si el almacenamiento externo sigue caído más de dos
  horas, escala a quien administra la cuenta del proveedor.
- **`respaldo-fallido` y `respaldo-atrasado`:** el mismo día hábil. Un completo fallido deja la
  semana sin respaldo base nuevo: repítelo antes del lunes.

## Prueba controlada

Ver [pruebas de alertas](../signoz/pruebas-de-alertas.md#respaldos): se detuvo el almacenamiento
externo de staging y se corrió un incremental.
