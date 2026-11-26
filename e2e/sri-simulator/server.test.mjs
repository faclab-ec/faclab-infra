// node --test e2e/sri-simulator/
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { checkDigit, createSriServer } from './server.mjs';

process.env.SRI_SIM_QUIET = 'true';

const RUC = '1799999990001';

/** An access key of a test environment voucher: date, type, RUC, environment, series, number… */
function accessKey(codDoc, sequence) {
  const base = `26112026${codDoc}${RUC}1001001${String(sequence).padStart(9, '0')}123456781`;
  return base + checkDigit(base);
}

const voucher = (key, { ruc = RUC, ambiente = '1', signature = '<ds:Signature Id="S"/>' } = {}) =>
  `<?xml version="1.0"?><factura><infoTributaria><ambiente>${ambiente}</ambiente><ruc>${ruc}</ruc>` +
  `<claveAcceso>${key}</claveAcceso><codDoc>${key.slice(8, 10)}</codDoc></infoTributaria>` +
  `${signature}</factura>`;

async function withServer(run, options) {
  const server = createSriServer(options);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}`;
  const post = async (path, body) =>
    (await fetch(url + path, { method: 'POST', body })).text();
  try {
    await run({
      url,
      send: (xml) =>
        post('/recepcion', `<e><tns:xml>${Buffer.from(xml).toString('base64')}</tns:xml></e>`),
      ask: (key) => post('/autorizacion', `<e><claveAccesoComprobante>${key}</claveAccesoComprobante></e>`),
    });
  } finally {
    server.close();
  }
}

test('serves the WSDLs pointing at itself', () =>
  withServer(async ({ url }) => {
    for (const path of ['/recepcion', '/autorizacion']) {
      const wsdl = await (await fetch(`${url}${path}?wsdl`)).text();
      assert.match(wsdl, new RegExp(`location="${url}${path}"`));
      assert.doesNotMatch(wsdl, /celcer/);
    }
  }));

test('receives an invoice, keeps it processing once and then authorizes it', () =>
  withServer(async ({ send, ask }) => {
    const key = accessKey('01', 1);

    assert.match(await send(voucher(key)), /<estado>RECIBIDA<\/estado>/);
    assert.match(await ask(key), /<estado>EN PROCESO<\/estado>/);
    const authorized = await ask(key);
    assert.match(authorized, /<estado>AUTORIZADO<\/estado>/);
    assert.match(authorized, new RegExp(`<numeroAutorizacion>${key}</numeroAutorizacion>`));
    assert.match(authorized, /<comprobante>&lt;\?xml/);
  }));

test('authorizes a credit note at the first query', () =>
  withServer(async ({ send, ask }) => {
    const key = accessKey('04', 1);
    await send(voucher(key));

    assert.match(await ask(key), /<estado>AUTORIZADO<\/estado>/);
  }));

test('returns an access key it already has with code 43', () =>
  withServer(async ({ send }) => {
    const key = accessKey('01', 2);
    await send(voucher(key));

    const repeated = await send(voucher(key));
    assert.match(repeated, /<estado>DEVUELTA<\/estado>/);
    assert.match(repeated, /<identificador>43<\/identificador>/);
  }));

test('returns what does not identify a signed test voucher', () =>
  withServer(async ({ send, ask }) => {
    const key = accessKey('01', 3);
    const wrongDigit = key.slice(0, 48) + ((Number(key[48]) + 1) % 10);
    const cases = [
      voucher(wrongDigit),
      voucher(key, { ambiente: '2' }),
      voucher(key, { ruc: '1790016919001' }),
      voucher(key, { signature: '' }),
    ];

    for (const xml of cases) {
      assert.match(await send(xml), /<estado>DEVUELTA<\/estado>/);
    }
    assert.match(await ask(key), /<numeroComprobantes>0<\/numeroComprobantes>/);
  }));

test('takes the configured time to answer, as the real service would', () =>
  withServer(
    async ({ send }) => {
      const started = Date.now();
      await send(voucher(accessKey('01', 4)));

      assert.ok(Date.now() - started >= 200);
    },
    { delayMs: 200 },
  ));
