# Pruebas de punta a punta (S9.1)

Levantan el sistema completo (web, core y su worker, invoicing y su worker, PostgreSQL, Kafka, el
almacenamiento de objetos y el SRI), siembran datos, recorren el flujo en un navegador y lo destruyen
todo. Es lo único que comprueba que los cuatro repositorios funcionan juntos: la suite de Playwright
de faclab-web (`tests/e2e`) simula el backend.

## Correrlas en local

Necesita Docker, Node 22, `openssl` y los cuatro repositorios como carpetas hermanas
(`faclab-core`, `faclab-web`, `faclab-invoicing`, `faclab-infra`). Una vez, en faclab-web:
`npm ci && npx playwright install chromium`. Después:

```bash
e2e/run.sh                              # de principio a fin; destruye todo al terminar
e2e/run.sh --keep                       # deja el entorno en marcha para inspeccionarlo
e2e/run.sh -- --headed                  # lo que va después de -- llega a Playwright
e2e/run.sh --inject-contract-regression # comprueba que la suite detecta un contrato roto
```

Usa su propio proyecto de Compose (`faclab-e2e`), red, volúmenes y puertos (web 18080, API 18000,
invoicing 18173, solo en `127.0.0.1`): puede correr junto al entorno de desarrollo, aunque con una VM
de Docker de 6 GB conviene detener lo que no se use. Las imágenes son las de producción, construidas
desde lo que haya en cada carpeta (también cambios sin commit). Las contraseñas, claves y el
certificado de firma se generan en cada corrida y no se guardan.

Si falla, los logs de los servicios quedan en `e2e/artifacts/compose.log` y el informe de Playwright
en `faclab-web/playwright-report-full-stack`.

Con `--keep`, las variables de la corrida quedan en `e2e/.env.run` (ignorado por git). La suite abre
y cierra un turno: para repetirla sobre el mismo entorno, ese turno tiene que haber quedado cerrado.

```bash
set -a; . e2e/.env.run; set +a; (cd ../faclab-web && npm run test:e2e:full)
docker compose -p faclab-e2e down -v    # al terminar
```

## Qué se comprueba

| Paso | Qué demuestra |
|---|---|
| Login eligiendo empresa | El administrador de la semilla pertenece a dos empresas |
| Apertura de turno | La caja `CAJA-01` de la matriz |
| Venta de 1 "Caja x25" a "Ferretería El Maestro" | Presentación y lista de precios del cliente: 95,00 + IVA, no 100,00 |
| Factura autorizada y RIDE | core → outbox → Kafka → invoicing → SRI → Kafka → core |
| Devolución total | Nota de crédito autorizada, venta `CREDITED`, su RIDE |
| Cierre de caja | Diferencia 0 y cierre Z numerado |
| Conciliación | Sin discrepancias en las ventas enviadas a facturar; la factura y la nota por el total de la venta |

La semilla trae ventas históricas `CONFIRMED` que nunca se enviaron a facturar: la conciliación las
lista (`confirmed_without_result`), como haría con ventas reales así, y la suite no las cuenta.

Además, `run.sh` falla si al final queda algún mensaje `failed` en el outbox de core o en las
`dead_letters` de cualquiera de los dos servicios.

## Simulador o `celcer`

| | Simulador (por defecto) | `celcer` (`--sri celcer`) |
|---|---|---|
| Para qué | CI y desarrollo: que el sistema funcione unido | Comprobar a mano que el SRI de pruebas acepta lo que se emite |
| Red y estabilidad | Sin internet, determinista | Depende de la disponibilidad del SRI |
| Certificado | Autofirmado, generado en cada corrida | El tuyo, de un RUC habilitado en pruebas |
| Valida | Clave de acceso, ambiente, RUC, tipo, presencia de firma, clave repetida (43) | Todo: XSD, firma, RUC, reglas tributarias |

El simulador (`sri-simulator/`) sirve los WSDL de `celcer` (descargados tal cual; solo cambia la
dirección) y deja la factura `EN PROCESO` en la primera consulta, para recorrer el reintento de
invoicing (un minuto). **No verifica la firma XAdES ni el XSD**: un XML mal firmado pasa aquí y no en
el SRI. invoicing valida el XSD antes de firmar; la firma real solo la comprueba `celcer`. Sus
pruebas: `node --test e2e/sri-simulator/server.test.mjs`.

invoicing apunta al simulador con `SRI_TEST_RECEPTION_WSDL` y `SRI_TEST_AUTHORIZATION_WSDL`, que se
rechazan con `NODE_ENV=production`; el entorno corre además con `NODE_ENV=local`, así que nunca
alcanza el SRI de producción.

Con `celcer`:

```bash
E2E_RUC=<RUC del certificado> E2E_P12_PATH=/ruta/certificado.p12 E2E_P12_PASSWORD=... \
  e2e/run.sh --sri celcer
```

La numeración arranca en un valor tomado de la hora, para no repetir comprobantes que el SRI ya
tiene. No se guardan trazas, capturas ni informes.

## En CI (`.github/workflows/e2e.yml`)

- **Cada noche** (06:00 UTC, 01:00 en Ecuador): compara el `master` de los cuatro repositorios con
  los de la última noche en verde; si no cambió ninguno, termina sin levantar nada. GitHub puede
  atrasar la hora y desactiva las programaciones tras 60 días sin actividad en el repositorio; la
  marca de la última noche en verde vive en la caché de Actions, que caduca tras 7 días sin uso, así
  que entonces vuelve a correr.
- **A mano** (*Actions → E2E → Run workflow*): refs de core, web e invoicing, `celcer` o simulador e
  inyección de la regresión. Útil antes de publicar una versión.
- **En los PR de faclab-infra** que cambian `e2e/` o lo que usa: toma en cada repositorio la rama con
  el mismo nombre, si existe, para probar juntos un cambio que cruza repositorios.

No corre en los PR de core, web ni invoicing: levantar todo es lento. El informe y los logs se
guardan 7 días solo si falla y solo con el simulador.

Para `celcer` en CI hacen falta los secretos `SRI_E2E_P12_BASE64`, `SRI_E2E_P12_PASSWORD` y
`SRI_E2E_RUC` del repositorio. Usa un certificado que solo sirva para pruebas.

## La regresión inyectada

`regressions/contract-sales-confirmed.patch` renombra `issuer_ruc` en el mensaje `sales.confirmed`.
Con `--inject-contract-regression`, `run.sh` lo aplica a una copia temporal de faclab-core y **solo
termina bien** si la suite falla y el mensaje está en las `dead_letters` de invoicing. Si el parche
deja de aplicar porque cambió ese código, el script lo dice: hay que regenerarlo.
