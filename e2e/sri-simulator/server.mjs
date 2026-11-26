// A stand-in for the SRI's offline web services in the end-to-end tests (S9.1): reception and
// authorization over SOAP, with the test environment's WSDLs (wsdl/, downloaded from celcer, only
// the address changes). It checks what identifies a voucher, not what the SRI validates for tax
// purposes: neither the XSD (faclab-invoicing validates it before signing) nor the signature itself.
// No dependencies. Run: node server.mjs (SRI_SIM_PORT, SRI_SIM_PENDING_CODDOCS)
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { pathToFileURL } from 'node:url';

const SERVICES = {
  '/recepcion': {
    wsdl: 'recepcion.wsdl',
    celcer: 'https://celcer.sri.gob.ec/comprobantes-electronicos-ws/RecepcionComprobantesOffline',
    namespace: 'http://ec.gob.sri.ws.recepcion',
  },
  '/autorizacion': {
    wsdl: 'autorizacion.wsdl',
    celcer:
      'https://celcer.sri.gob.ec/comprobantes-electronicos-ws/AutorizacionComprobantesOffline',
    namespace: 'http://ec.gob.sri.ws.autorizacion',
  },
};

const MAX_BODY_BYTES = 2 * 1024 * 1024;

const escapeXml = (text) =>
  text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/** The text of the first element with that local name, whatever its prefix */
function elementText(xml, name) {
  const match = xml.match(new RegExp(`<(?:[\\w-]+:)?${name}(?:\\s[^>]*)?>([^<]*)</`));
  return match ? match[1].trim() : null;
}

/** Módulo 11 with weights 2 to 7 from the right; 11 is 0 and 10 is 1 (ficha técnica, 5.2) */
export function checkDigit(digits) {
  let sum = 0;
  for (let i = 0; i < digits.length; i++) {
    sum += Number(digits[digits.length - 1 - i]) * (2 + (i % 6));
  }
  const digit = 11 - (sum % 11);
  if (digit === 11) return 0;
  return digit === 10 ? 1 : digit;
}

/** Why the voucher is returned, with the SRI's code; null when it is received */
export function rejectionOf(voucher) {
  const accessKey = elementText(voucher, 'claveAcceso') ?? '';
  const invalid = (code, message, detail) => ({ accessKey, code, message, detail });

  if (!/^\d{49}$/.test(accessKey) || checkDigit(accessKey.slice(0, 48)) !== Number(accessKey[48])) {
    return invalid('35', 'ARCHIVO NO CUMPLE ESTRUCTURA XML', 'Clave de acceso inválida');
  }
  if (elementText(voucher, 'ambiente') !== '1' || accessKey[23] !== '1') {
    return invalid('35', 'ARCHIVO NO CUMPLE ESTRUCTURA XML', 'El simulador solo es de pruebas');
  }
  if (elementText(voucher, 'ruc') !== accessKey.slice(10, 23)) {
    return invalid('35', 'ARCHIVO NO CUMPLE ESTRUCTURA XML', 'El RUC no es el de la clave');
  }
  if (elementText(voucher, 'codDoc') !== accessKey.slice(8, 10)) {
    return invalid('35', 'ARCHIVO NO CUMPLE ESTRUCTURA XML', 'El tipo no es el de la clave');
  }
  if (!/<(?:[\w-]+:)?Signature[\s>]/.test(voucher)) {
    return invalid('39', 'FIRMA INVALIDA', 'El comprobante no está firmado');
  }
  return null;
}

const envelope = (namespace, operation, body) =>
  '<?xml version="1.0" encoding="UTF-8"?>' +
  '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>' +
  `<ns2:${operation}Response xmlns:ns2="${namespace}">${body}</ns2:${operation}Response>` +
  '</soap:Body></soap:Envelope>';

const message = ({ code, message: text, detail }) =>
  `<mensajes><mensaje><identificador>${code}</identificador><mensaje>${escapeXml(text)}</mensaje>` +
  `<informacionAdicional>${escapeXml(detail)}</informacionAdicional><tipo>ERROR</tipo>` +
  '</mensaje></mensajes>';

/**
 * What the simulator remembers. A voucher whose document type is in `pendingCodDocs` answers
 * EN PROCESO to its first authorization query, as the SRI does while it works on it.
 */
export function createSri({ pendingCodDocs = ['01'], now = () => new Date() } = {}) {
  const vouchers = new Map();

  function receive(request) {
    const encoded = elementText(request, 'xml');
    const voucher = encoded ? Buffer.from(encoded, 'base64').toString('utf-8') : '';
    let rejection = rejectionOf(voucher);
    const accessKey = elementText(voucher, 'claveAcceso') ?? '';
    if (!rejection && vouchers.has(accessKey)) {
      rejection = { accessKey, code: '43', message: 'CLAVE ACCESO REGISTRADA', detail: accessKey };
    }

    let body = '<estado>RECIBIDA</estado><comprobantes/>';
    if (rejection) {
      body =
        '<estado>DEVUELTA</estado><comprobantes><comprobante>' +
        `<claveAcceso>${escapeXml(rejection.accessKey)}</claveAcceso>${message(rejection)}` +
        '</comprobante></comprobantes>';
    } else {
      const codDoc = accessKey.slice(8, 10);
      vouchers.set(accessKey, { voucher, codDoc, pending: pendingCodDocs.includes(codDoc) });
    }
    log('recepcion', accessKey, rejection ? `DEVUELTA ${rejection.code}` : 'RECIBIDA');
    return `<RespuestaRecepcionComprobante>${body}</RespuestaRecepcionComprobante>`;
  }

  function authorize(request) {
    const accessKey = elementText(request, 'claveAccesoComprobante') ?? '';
    const found = vouchers.get(accessKey);
    let authorization = '';
    let state = 'UNKNOWN';
    if (found?.pending) {
      found.pending = false;
      state = 'EN PROCESO';
      authorization = '<autorizacion><estado>EN PROCESO</estado></autorizacion>';
    } else if (found) {
      found.authorizedAt ??= now().toISOString();
      state = 'AUTORIZADO';
      authorization =
        '<autorizacion><estado>AUTORIZADO</estado>' +
        `<numeroAutorizacion>${accessKey}</numeroAutorizacion>` +
        `<fechaAutorizacion>${found.authorizedAt}</fechaAutorizacion>` +
        '<ambiente>PRUEBAS</ambiente>' +
        `<comprobante>${escapeXml(found.voucher)}</comprobante><mensajes/></autorizacion>`;
    }
    log('autorizacion', accessKey, state);
    return (
      '<RespuestaAutorizacionComprobante>' +
      `<claveAccesoConsultada>${escapeXml(accessKey)}</claveAccesoConsultada>` +
      `<numeroComprobantes>${authorization ? 1 : 0}</numeroComprobantes>` +
      `<autorizaciones>${authorization}</autorizaciones>` +
      '</RespuestaAutorizacionComprobante>'
    );
  }

  return { receive, authorize };
}

function log(operation, accessKey, result) {
  if (process.env.SRI_SIM_QUIET !== 'true') {
    console.log(JSON.stringify({ operation, accessKey, result }));
  }
}

const readBody = (request) =>
  new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) reject(new Error('body too large'));
      else chunks.push(chunk);
    });
    request.on('end', () => resolve(Buffer.concat(chunks).toString('utf-8')));
    request.on('error', reject);
  });

export function createSriServer(options) {
  const sri = createSri(options);
  return createServer(async (request, response) => {
    const send = (status, body, type = 'text/xml; charset=utf-8') => {
      response.writeHead(status, { 'Content-Type': type });
      response.end(body);
    };
    try {
      const path = new URL(request.url, 'http://sri').pathname;
      if (path === '/health') return send(200, 'ok', 'text/plain');
      const service = SERVICES[path];
      if (!service) return send(404, 'not found', 'text/plain');

      if (request.method === 'GET') {
        const wsdl = readFileSync(new URL(`./wsdl/${service.wsdl}`, import.meta.url), 'utf-8');
        return send(200, wsdl.replace(service.celcer, `http://${request.headers.host}${path}`));
      }
      const body = await readBody(request);
      if (path === '/recepcion') {
        return send(200, envelope(service.namespace, 'validarComprobante', sri.receive(body)));
      }
      return send(200, envelope(service.namespace, 'autorizacionComprobante', sri.authorize(body)));
    } catch (error) {
      console.error(error);
      return send(500, 'error', 'text/plain');
    }
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(process.env.SRI_SIM_PORT ?? 8081);
  const pendingCodDocs = (process.env.SRI_SIM_PENDING_CODDOCS ?? '01').split(',').filter(Boolean);
  const server = createSriServer({ pendingCodDocs });
  server.listen(port, () => console.log(`SRI simulator on :${port}`));
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => process.exit(0));
}
