# Respaldos y recuperación

Esta guía cubre los respaldos del stack de producción (S8.3, G-59 del core): qué se respalda, dónde
y cada cuánto; los objetivos de pérdida de datos y de tiempo de recuperación; cómo se prepara el
almacenamiento externo; cómo se restaura; y el registro del simulacro.

Complementa el respaldo previo a cada despliegue ([README](README.md#restaurar-el-respaldo-previo)),
que sirve solo para volver atrás de ese despliegue y no sale del servidor.

## Qué se respalda

| Qué | Cómo | Dónde | Cuándo | Cuánto tiempo |
|---|---|---|---|---|
| **PostgreSQL** (las bases `faclab` y `faclab_invoicing`) | pgBackRest, cifrado con AES-256 en el servidor antes de salir | Bucket `BACKUP_PG_BUCKET` del almacenamiento externo | WAL continuo, a lo sumo 60 s después de cada escritura; completo los domingos a las 02:00 (Ecuador); incremental de lunes a sábado a las 02:00 | 4 completos: de 4 a 5 semanas de recuperación a cualquier punto |
| **Comprobantes** (XML autorizados, RIDE, logos del almacenamiento de objetos) | rclone crypt: contenido y nombres cifrados en el servidor | Bucket `BACKUP_OBJECTS_BUCKET`, con versionado y Object Lock en modo compliance | Lo escrito en las últimas 24 h, cada 5 minutos; una copia completa diaria a las 03:00 | El plazo legal: **7 años** (por confirmar con el contador) |
| **Secretos** (contraseñas, llaves, frases de cifrado) | sops y age | `FACLAB_SECRETS_DIR`, fuera del servidor ([README](README.md#3-secretos)) | Con cada cambio | Mientras existan los respaldos |

### Por qué así

- **Garage no tiene versionado ni Object Lock.** Por eso el versionado y la retención legal de los
  comprobantes viven en la copia externa, no en el almacenamiento del servidor.
- **La copia externa es lo único que protege los XML autorizados.** faclab-invoicing guarda el XML
  autorizado y el RIDE solo en el almacenamiento de objetos; su base guarda la clave del objeto. El
  respaldo de PostgreSQL no los incluye.
- **Dos buckets, cada uno con su propia llave:**
  - La de pgBackRest puede borrar, porque vence los respaldos viejos.
  - La de los comprobantes escribe y lee, pero nunca borra. Además, Object Lock en modo compliance
    impide borrar o reescribir una versión antes de su plazo, ni siquiera con la cuenta raíz.
  - Un servidor comprometido puede dañar los respaldos de la base dentro de su ventana de retención,
    pero no los comprobantes.
- **pgBackRest y no WAL-G:**
  - tiene los tipos completo e incremental;
  - cifra el repositorio;
  - archiva el WAL de forma asíncrona, con un tope de cola para no llenar el disco;
  - su `info --output=json` alimenta las alertas;
  - anota cada respaldo con las versiones desplegadas.
- **Los respaldos son físicos.** pgBackRest copia los archivos de la base. A diferencia de `pg_dump`,
  no lee las tablas, así que la seguridad por filas (RLS) forzada del core no lo afecta.
- **Kafka no se respalda.** Sus mensajes son transitorios: el outbox del core vuelve a publicar lo
  pendiente, y la conciliación detecta lo que se perdió (ver
  [Después de restaurar](#después-de-restaurar)).

## Objetivos: RPO y RTO

| | Objetivo | Medido en el simulacro |
|---|---|---|
| **RPO de PostgreSQL** (cuántos datos se pueden perder) | 5 minutos: `archive_timeout=60` y envío asíncrono | Menos de 77 s: una venta confirmada 77 s antes de restaurar se recuperó; la confirmada en el mismo segundo, no ([registro](#registro-del-simulacro-de-s83)) |
| **RPO de los comprobantes** | 10 minutos: la copia corre cada 5. El SRI también conserva los autorizados | Cada corrida copió los XML y RIDE nuevos en menos de 30 s |
| **RTO** (cuánto tarda volver a dar servicio en un servidor nuevo) | 2 horas, con los datos verificados | 10 minutos de máquina, con una base de 44 MB: servidor, restauración, comprobantes y verificaciones |

Ajusta `POSTGRES_ARCHIVE_TIMEOUT` si el RPO cambia: menos segundos es menos pérdida y más segmentos
de WAL en el bucket.

## En el servidor

- **`postgres` corre la imagen `faclab-postgres`.** Es la oficial más pgBackRest
  ([postgres/Dockerfile](postgres/Dockerfile)), con su
  [configuración](postgres/pgbackrest.conf). Archiva cada segmento de WAL con
  `archive_command`. Está en la red `backup`, la única con salida a Internet además de `egress`, y
  nadie más la comparte salvo la tarea de copia de objetos.
- **docker-init es el PID 1 del contenedor** (`init: true`). Recoge los procesos que pgBackRest deja
  en segundo plano al archivar. Sin él, PostgreSQL los adopta y, cuando uno termina con error (el
  repositorio no responde), lo toma por un proceso propio caído y reinicia todas las conexiones. Lo
  encontró el simulacro de S8.3. Para pasarle a PostgreSQL la señal de parada, docker-init necesita
  la capacidad `KILL`; sin ella, PostgreSQL muere sin apagarse limpio.
- **El archivo de WAL no está en la línea de comandos.** Va en `postgresql.auto.conf`
  (`ALTER SYSTEM`), y lo pone `stack.sh migrate` después de crear el stanza; cambiar `archive_mode`
  reinicia PostgreSQL una vez. Así, una base nueva se inicializa sin archivar (el stanza aún no
  existe y el servidor temporal de la imagen no podría apagarse), y una base restaurada trae lo suyo.
- **El interruptor `BACKUPS`** del entorno (`env/<entorno>.env`):
  - con `on`, `stack.sh deploy` crea el stanza, enciende el archivo de WAL, instala los timers y lanza
    el primer completo si no hay ninguno;
  - con `off` (un servidor que solo restaura), PostgreSQL no archiva y no hay timers.
    `stack.sh restore` lo restaura con `--archive-mode=off`, para que no escriba en el repositorio
    del que viene.
- **Los timers de systemd** ([systemd/](systemd/)) corren
  [`scripts/backups.sh`](scripts/backups.sh):

  | Timer | Qué hace | Cuándo |
  |---|---|---|
  | `faclab-backup@full` | Respaldo completo | Domingos a las 02:00 (Ecuador) |
  | `faclab-backup@incr` | Respaldo incremental | De lunes a sábado a las 02:00 |
  | `faclab-backup@objects` | Copia completa de los comprobantes | Diaria a las 03:00 |
  | `faclab-backup@objects-recent` | Copia de las últimas 24 h | Cada 5 minutos |
  | `faclab-backup@report` | Métricas al Collector | Cada 5 minutos |

  Los completos e incrementales que se perdieron con el servidor apagado corren al encenderlo.
- **El resultado de cada corrida** queda en `/var/lib/faclab/backups/` y en journald.
- **Las métricas `faclab.backup.*`** van al receptor interno del Collector (`:4319`) y alimentan:
  - las alertas `respaldo-fallido`, `respaldo-atrasado` y `wal-sin-archivar`
    ([runbook](../../observability/runbooks/respaldos.md));
  - la sección «Respaldos» del dashboard de infraestructura.

```bash
sudo deploy/production/scripts/backups.sh status     # respaldos, archivo de WAL, últimas corridas, timers
sudo deploy/production/scripts/backups.sh check      # archiva un segmento de punta a punta
sudo systemctl start faclab-backup@incr              # un respaldo ahora (o full, objects)
journalctl -u 'faclab-backup@*' --since today        # los logs
```

Un despliegue que recrea `postgres` a mitad de un respaldo lo interrumpe. Ese trabajo falla y su
alerta avisa: repítelo con `systemctl start`.

Volver a una versión de faclab-infra anterior a 0.2.0 (sin respaldos) deja los timers apuntando a un
script que ya no existe. Antes, quítalos con `sudo deploy/production/scripts/backups.sh remove-timers`.

## Preparar el almacenamiento externo

Se prepara una vez por entorno. Sirve cualquier servicio compatible con S3 que tenga versionado y
Object Lock, en otra empresa y otra región que el servidor: Backblaze B2, AWS S3, Wasabi u otro.

1. **El bucket de pgBackRest** (`BACKUP_PG_BUCKET`):
   - privado y sin Object Lock, porque pgBackRest borra lo que vence;
   - si el proveedor versiona por defecto (B2), una regla de ciclo de vida que borre las versiones
     ocultas a los 30 días. Si no, el bucket crece sin límite.
2. **El bucket de los comprobantes** (`BACKUP_OBJECTS_BUCKET`):
   - privado, creado **con Object Lock** (casi siempre solo se puede activar al crearlo);
   - retención por defecto **COMPLIANCE de 2557 días** (7 años, por confirmar con el contador), que
     activa el versionado.

   En AWS:
   ```bash
   aws s3api create-bucket --bucket <bucket> --object-lock-enabled-for-bucket
   aws s3api put-object-lock-configuration --bucket <bucket> --object-lock-configuration \
     '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"COMPLIANCE","Days":2557}}}'
   ```

   El modo compliance no se puede quitar ni acortar: cada versión cuesta almacenamiento durante 7
   años.
3. **Dos llaves de acceso**, cada una limitada a su bucket:
   - la de pgBackRest lista, lee, escribe y borra;
   - la de los comprobantes lista, lee y escribe (también por partes: `AbortMultipartUpload`), **sin
     permiso de borrar** ni de cambiar la retención.

   Un bucket con Object Lock rechaza un objeto sin `Content-MD5`. Como rclone cifra al vuelo y no
   conoce ese hash de antemano, sube todo por partes (`upload_cutoff=0` en `compose.yaml`) y envía el
   MD5 de cada una. Lo encontró el simulacro de S8.3.
4. **La configuración del entorno** (`env/<entorno>.env`), que no es secreta:
   - `BACKUPS=on`;
   - `BACKUP_S3_ENDPOINT` (el host, sin `https://`) y `BACKUP_S3_REGION`;
   - `BACKUP_PG_BUCKET` y `BACKUP_OBJECTS_BUCKET`;
   - si hace falta, `BACKUP_S3_PORT` y `BACKUP_S3_URI_STYLE`.
5. **Los secretos**, en tu máquina:

   ```bash
   # Las llaves del proveedor, desde stdin (nunca en la línea de comandos)
   pbpaste | deploy/production/scripts/secrets.sh set production BACKUP_PG_ACCESS_KEY_ID
   # ... BACKUP_PG_SECRET_ACCESS_KEY, BACKUP_OBJECTS_ACCESS_KEY_ID, BACKUP_OBJECTS_SECRET_ACCESS_KEY
   ```

   `secrets.sh init` ya genera las frases de cifrado. Un entorno creado antes de S8.3 las agrega con:
   ```bash
   deploy/production/scripts/secrets.sh set production BACKUP_PG_CIPHER_PASS base64
   deploy/production/scripts/secrets.sh set production BACKUP_OBJECTS_CRYPT_PASSWORD hex
   deploy/production/scripts/secrets.sh set production BACKUP_OBJECTS_CRYPT_SALT hex
   ```

   Después, `secrets.sh push` y `stack.sh install-secrets`, como cualquier secreto.

> **Las frases de cifrado son irremplazables.** Sin `BACKUP_PG_CIPHER_PASS`, los respaldos de la base
> no se pueden leer; sin `BACKUP_OBJECTS_CRYPT_PASSWORD` y su sal, tampoco la copia de comprobantes.
> Viven en los archivos de sops, que solo se descifran con la llave de age: respáldala fuera de tu
> máquina (README, «Secretos»). Nunca las rotes sin un completo nuevo y una copia nueva.

### El sustituto de staging

Hasta el primer VPS, staging guarda sus respaldos en un sustituto: [drill/](drill/), versitygw en el
Docker de la Mac que corre las VM. Tiene versionado, Object Lock en modo compliance de 1 día, una
llave por bucket y la de comprobantes sin permiso de borrar.

```bash
deploy/production/drill/standin.sh up      # llaves, certificado, buckets y políticas (idempotente)
deploy/production/drill/standin.sh secret BACKUP_PG_ACCESS_KEY_ID |
  deploy/production/scripts/secrets.sh set staging BACKUP_PG_ACCESS_KEY_ID   # y las otras tres
```

Su certificado es autofirmado: `env/staging.env` es el único lugar con `BACKUP_S3_VERIFY_TLS=n`, y el
CI rechaza esa línea en el ejemplo de producción.

Después del simulacro, staging quedó con `BACKUPS=off`: el sustituto corre en la Mac y no siempre
está arriba, y sin él staging acumularía WAL y avisaría `wal-sin-archivar`. Para volver a probar,
`BACKUPS=on` y `standin.sh up`. Cuando llegue el proveedor real, staging cambia su endpoint, sus
buckets y sus llaves, enciende `BACKUPS` y hace un completo nuevo.

## Restaurar

`stack.sh restore` recupera PostgreSQL desde el repositorio externo al punto que se le pida y después
despliega encima las versiones que corrían entonces:

- por defecto, las anotadas en el respaldo del que parte;
- si no, las que se le den.

Lo escrito después de ese punto se pierde.

### En un servidor nuevo (el servidor se perdió)

1. **El servidor:** aprovisiónalo y clona faclab-infra ([README](README.md#1-aprovisionar-el-servidor),
   pasos 1 y 2). Apunta el DNS a la IP nueva.
2. **Los secretos y la configuración** del mismo entorno, desde tu máquina:
   ```bash
   deploy/production/scripts/secrets.sh push production deploy@<servidor nuevo>
   ```

   En el servidor:
   ```bash
   sudo deploy/production/scripts/stack.sh install-secrets production
   cp deploy/production/env/production.env.example deploy/production/env/production.env   # completa como el anterior
   ```

   Hacen falta los mismos secretos: sin `CERTIFICATE_PASSWORD_KEY`, los certificados de firma
   restaurados no se pueden leer; sin las llaves Fernet, tampoco los secretos de los webhooks.
3. **PostgreSQL**, hasta el último WAL archivado:
   ```bash
   sudo deploy/production/scripts/stack.sh restore latest --yes
   ```

   O hasta una hora: `restore '2026-11-24 10:15:00-05:00' --yes`. El comando:
   1. lee el repositorio y toma las versiones anotadas en el respaldo de partida;
   2. hace el checkout de su faclab-infra;
   3. restaura con `pgbackrest restore`;
   4. espera a que PostgreSQL termine de aplicar el WAL;
   5. comprueba que las imágenes conocen el esquema restaurado;
   6. despliega como cualquier despliegue, en orden y con comprobaciones;
   7. con `BACKUPS=on`, lanza un completo nuevo de la línea de tiempo nueva.
4. **Los comprobantes:**
   ```bash
   sudo deploy/production/scripts/stack.sh restore-objects --yes
   ```
5. **Las comprobaciones:**
   - [Después de restaurar](#después-de-restaurar);
   - la prueba de humo (`smoke.sh`);
   - una venta de prueba en un punto de emisión que no se use, o en el ambiente de pruebas del SRI.

### En el mismo servidor (un error borró o dañó datos)

```bash
sudo deploy/production/scripts/stack.sh restore '2026-11-24 10:15:00-05:00' --yes
```

pgBackRest reescribe solo lo que difiere (`--delta`). **Todo lo escrito después de esa hora se
pierde, en todas las empresas.**

Para recuperar los datos de una sola empresa, restaura en un servidor aparte con `BACKUPS=off` y
copia lo necesario a mano. Ver [Simulacro](#simulacro).

### Después de restaurar

Con pérdida de datos (cualquier hora distinta de `latest`, o un RPO mayor que cero):

- **Ventas y movimientos posteriores a ese punto:** no existen. Hay que registrarlos de nuevo desde
  los comprobantes impresos o la copia de comprobantes.
- **Kafka:**
  - en un servidor nuevo, los tópicos empiezan vacíos;
  - el outbox del core vuelve a publicar lo que estaba pendiente;
  - la conciliación (S4.3) marca como `confirmed_without_result` las ventas cuyo resultado se perdió;
  - el reenvío de facturación las resuelve.
- **Secuenciales del SRI, antes de volver a facturar:** las facturas que el SRI autorizó después de
  ese punto siguen allá, pero la base restaurada no las conoce. faclab-invoicing reutilizaría sus
  secuenciales y el SRI los rechazaría (secuencial registrado). Para cada punto de emisión:
  1. busca el último secuencial autorizado en la copia de comprobantes, que puede ser más reciente que
     la base, y en el portal del SRI;
  2. avanza la secuencia de faclab-invoicing por encima de él.

  Hoy es un paso manual (pendiente en el ROADMAP del core).
- **El primer completo** de la base restaurada corre solo (`journalctl -u faclab-backup@full`). Hasta
  que termine, la recuperación a un punto en el tiempo solo llega a lo anterior a la restauración.

## Simulacro

ADR-0011 pide un simulacro de restauración **mensual**. Se hace en un servidor aparte para no tocar
producción:

1. **Una VM limpia.** Aprovisiónala, clona faclab-infra e instala los secretos del entorno con otro
   nombre:
   - `stack.sh install-secrets drill`, con `env/drill.env`, copia del entorno con `BACKUPS=off` (Git
     lo ignora);
   - así PostgreSQL no archiva ni escribe en el repositorio de origen.
2. **El resumen del origen** a una hora T, con sus conteos (abajo).
3. **La restauración**, cronometrada de punta a punta: `stack.sh restore T --yes` y `restore-objects
   --yes`.
4. **Las comprobaciones:**
   - el resumen de la VM es igual al del origen en T;
   - lo escrito después de T no está;
   - cada XML autorizado de la base existe en el almacenamiento;
   - `pg_amcheck --all` no encuentra daños.
5. **El cierre:** anota los tiempos aquí y borra la VM.

El resumen, en el servidor (no imprime datos de clientes, solo conteos y números de documento):

```bash
S="sudo deploy/production/scripts/stack.sh compose exec -T postgres psql -U postgres -X -qtA"
$S -d faclab -c "select 'sales', count(*), max(number), sum(total) from sales union all
  select 'movements', count(*), null, null from movements union all
  select 'audit_log', count(*), null, null from audit_log"
$S -d faclab_invoicing -c "select status, count(*), max(sequence) from invoices group by status order by status"
$S -d faclab_invoicing -c "select md5(string_agg(authorized_xml_key, ',' order by authorized_xml_key)) from invoices where authorized_xml_key is not null"
```

### Registro del simulacro de S8.3

2026-11-24, en OrbStack. El origen fue staging (`faclab-staging`), con una empresa real de pruebas
cuyo emisor estaba configurado en el ambiente de pruebas del SRI, y facturas autorizadas por celcer.
El destino fue una VM limpia (`faclab-restore`, Ubuntu 24.04). El almacenamiento externo fue el
sustituto de `drill/`.

**Datos.** El resumen S1 de staging se tomó en T = 2026-11-24 12:06:37 -05:00. Para entonces había 4
ventas (hasta V-001-000004) y 4 facturas autorizadas, sin facturas en vuelo. Después de T hubo 2
ventas más, también autorizadas.

**Restauración a T en el servidor limpio**, con faclab-infra 0.2.0-rc.5 (horas UTC):

| Paso | Inicio | Duración |
|---|---|---|
| Crear y aprovisionar la VM (`provision-vps.sh`) | 2026-11-23 20:37:52 | 2 min 59 s |
| Clonar faclab-infra en el tag y crear `env/drill.env` (`BACKUPS=off`) | 19:13:41 | 2 s |
| `secrets.sh push` e `install-secrets drill` | 19:13:50 | 1 s |
| `stack.sh restore '2026-11-24 12:06:37-05:00' --yes …` | 19:16:47 | 3 min 39 s |
| `stack.sh restore-objects --yes` | 19:20:41 | 22 s |
| Verificaciones (resumen, XML, `pg_amcheck`, API) | 19:21:10 | unos 2 min 30 s |
| **Total de máquina** | | **unos 10 minutos** |

Dentro de `restore`:
- las imágenes, 1 min 21 s;
- pgBackRest restauró el incremental de las 15:43 en 10 s;
- PostgreSQL aplicó el WAL hasta T y se promovió en 5 s;
- el despliegue completo, con sus comprobaciones, tardó el resto.

**Verificaciones:**
- **El resumen del servidor restaurado es idéntico a S1:**
  - las ventas, sus líneas y pagos, con las mismas sumas;
  - los movimientos y el stock;
  - las facturas por estado y su último secuencial;
  - el hash de las claves de los XML autorizados.

  Las dos ventas posteriores a T no están.
- **Los XML:** cada uno de los 4 autorizados de la base existe en el almacenamiento restaurado.
  `restore-objects` trajo los 12 objetos de la copia, incluidos los de después de T.
- **`pg_amcheck --all --heapallindexed`:** 1634 relaciones y 4055 páginas, sin daños.
- **Por la API del servidor restaurado:**
  - el login con la cuenta de staging funciona;
  - el XML autorizado se descarga (`<estado>AUTORIZADO</estado>`), igual que el RIDE en PDF.

**RPO, con `restore latest` en el mismo servidor** (faclab-infra 0.2.0-rc.8, en 4 min 18 s):

1. un incremental en staging;
2. la venta A a las 19:38:09;
3. la venta B 77 s después;
4. de inmediato, la restauración.

A está y B no: su segmento de WAL salía en el minuto siguiente. Por defecto, `restore` tomó las
versiones anotadas en el respaldo (rc.8), cambió el checkout del servidor y restauró con `--delta`.

**Lo que el simulacro encontró y se corrigió antes de cerrarlo:**

- **Reinicios de PostgreSQL.** El proceso asíncrono de pgBackRest lo reiniciaba al fallar. Se agregó
  `init: true` y `CAP_KILL`; sin esta última, docker-init no podía detener PostgreSQL limpio.
- **La inicialización de una base nueva no se podía apagar.** El archivo de WAL estaba en la línea
  de comandos; ahora lo enciende `stack.sh migrate` después del stanza.
- **`pgbackrest info` responde 0 aunque el repositorio no responda.** Ahora se lee el estado de su
  JSON.
- **La copia a un bucket con Object Lock fallaba.** Exige `Content-MD5`; ahora se sube por partes.
- **Conexiones rotas después de reiniciar PostgreSQL.** Un despliegue que lo recreaba dejaba a las
  aplicaciones con conexiones a un servidor detenido. Ahora se recrean también.
- **Un `postmaster.pid` viejo impedía la restauración en el mismo servidor.** `restore` lo quita con
  el contenedor detenido.

Ajenos a los respaldos, anotados como pendientes en el core:

- **ERROR 45 «secuencial registrado».** La primera factura de staging lo recibió: el SRI ya tenía
  ese secuencial del mismo RUC, de otro entorno. Es el mismo caso de una restauración con pérdida:
  se avanzó la secuencia con `PUT /api/sequences/001/001` y se reenvió.
- **El consumidor de Kafka de faclab-invoicing no se recupera solo.** Después de una suspensión de la
  VM (superó `max.poll.interval.ms`), salió del grupo y no volvió a entrar hasta reiniciar el worker.

**Escala.** La base era de 44 MB. El tiempo de pgBackRest crece con el tamaño (restaura en paralelo
y comprimido) y con el WAL desde el último respaldo (a lo sumo un día). El margen frente a las 2 horas
del RTO es amplio, pero el simulacro mensual con datos reales del piloto lo confirmará.
