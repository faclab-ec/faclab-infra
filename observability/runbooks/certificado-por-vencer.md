# Certificado por vencer

> Reglas:
>
> - `certificado-30d`: ventana `30d`, de 8 a 30 días;
> - `certificado-7d`: ventanas `7d` (hasta 7 días) y `expired`.
>
> Métrica: `faclab.certificates.expiring`. Severidad: **advertencia** a 30 días, **crítica** a 7 días
> o vencido. Se evalúa cada hora y vuelve a avisar cada 24 h. Dashboard: *Faclab · Facturación
> electrónica*, panel «Certificados por vencer».

## Síntoma

El certificado de firma seleccionado por alguna empresa vence pronto o ya venció. Con el certificado
vencido, sus comprobantes quedan pendientes con `CERTIFICATE_EXPIRED` y no se emiten.

## Diagnóstico

1. La métrica no dice qué empresa: por diseño no lleva ids. El detalle sale en los logs del worker de
   facturación, una vez al día y al arrancar:
   - `certificate.expiring`, en WARN;
   - `certificate.expired`, en ERROR;
   - los dos con la empresa y la fecha.

   En SigNoz: *Logs*, `service.name = faclab-invoicing-worker AND body CONTAINS 'certificate.'`.
2. `GET /api/invoicing/status` de esa empresa avisa también del certificado que vence en 30 días.

## Acción

- Avisar a la empresa con tiempo. Tiene que:
  1. renovar su firma electrónica con su entidad certificadora;
  2. subir el nuevo `.p12` (`POST /api/certificates`, o la pantalla de configuración de
     facturación);
  3. seleccionarlo en su perfil fiscal.
- Al seleccionar uno vigente, la recuperación vuelve a encolar los comprobantes que esperaban por el
  certificado. En la siguiente muestra (60 s) el panel baja.

## Escalamiento

- Crítica a 7 días: contactar a la empresa por teléfono además del correo.
- Vencido: sus ventas siguen, pero sin facturar. Seguir con ella hasta que suba el nuevo.

## Prueba controlada

Ver [pruebas de alertas](../signoz/pruebas-de-alertas.md#certificado-por-vencer).
