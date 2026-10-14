import type { FastifyInstance } from 'fastify';
import { afterEach, describe, expect, it } from 'vitest';
import { buildApp } from '../../app.js';
import { metaWebhookAckSchema, type MetaWebhookConfig } from './routes.js';
import {
  createFailingStore,
  createRecordingStore,
  loadMetaFixture,
  metaSignatureHeader,
  storedOutcome,
  TEST_APP_SECRET,
  TEST_VERIFY_TOKEN,
  type RecordingStore,
} from './test-support/index.js';

const WEBHOOK_URL = '/webhooks/meta';

const apps: FastifyInstance[] = [];

function makeApp(overrides: Partial<MetaWebhookConfig> = {}): {
  app: FastifyInstance;
  store: RecordingStore;
} {
  const store = (overrides.store ?? createRecordingStore()) as RecordingStore;
  const app = buildApp({
    meta: {
      appSecret: TEST_APP_SECRET,
      verifyToken: TEST_VERIFY_TOKEN,
      ...overrides,
      store,
    },
  });
  apps.push(app);
  return { app, store };
}

/** A POST with the signature Meta would send for these exact bytes. */
function postMeta(
  app: FastifyInstance,
  body: Buffer,
  options: { signature?: string | null; contentType?: string } = {},
) {
  const headers: Record<string, string> = {
    'content-type': options.contentType ?? 'application/json',
  };
  if (options.signature !== null) {
    headers['x-hub-signature-256'] = options.signature ?? metaSignatureHeader(body, TEST_APP_SECRET);
  }
  return app.inject({ method: 'POST', url: WEBHOOK_URL, payload: body, headers });
}

afterEach(async () => {
  await Promise.all(apps.splice(0).map((app) => app.close()));
});

describe('GET /webhooks/meta', () => {
  it('echoes the challenge, and nothing else, when the verify token matches', async () => {
    const { app } = makeApp();

    const response = await app.inject({
      method: 'GET',
      url: `${WEBHOOK_URL}?hub.mode=subscribe&hub.verify_token=${TEST_VERIFY_TOKEN}&hub.challenge=1158201444`,
    });

    expect(response.statusCode).toBe(200);
    expect(response.body).toBe('1158201444');
    expect(response.headers['content-type']).toMatch(/text\/plain/);
  });

  it('echoes a challenge with punctuation unchanged', async () => {
    const { app } = makeApp();
    const challenge = 'abc-123_456.789%20';

    const response = await app.inject({
      method: 'GET',
      url: `${WEBHOOK_URL}?hub.mode=subscribe&hub.verify_token=${TEST_VERIFY_TOKEN}&hub.challenge=${encodeURIComponent(challenge)}`,
    });

    expect(response.statusCode).toBe(200);
    expect(response.body).toBe(challenge);
  });

  it.each([
    ['a wrong verify token', `hub.mode=subscribe&hub.verify_token=nope&hub.challenge=1158201444`],
    ['no verify token', `hub.mode=subscribe&hub.challenge=1158201444`],
    ['the right token but the wrong mode', `hub.mode=unsubscribe&hub.verify_token=${TEST_VERIFY_TOKEN}&hub.challenge=1158201444`],
    ['no mode', `hub.verify_token=${TEST_VERIFY_TOKEN}&hub.challenge=1158201444`],
    ['no challenge', `hub.mode=subscribe&hub.verify_token=${TEST_VERIFY_TOKEN}`],
    ['no query at all', ''],
    ['a prefix of the verify token', `hub.mode=subscribe&hub.verify_token=${TEST_VERIFY_TOKEN.slice(0, -1)}&hub.challenge=1158201444`],
  ])('answers 403 and echoes no challenge for %s', async (_case, query) => {
    const { app } = makeApp();

    const response = await app.inject({ method: 'GET', url: `${WEBHOOK_URL}?${query}` });

    expect(response.statusCode).toBe(403);
    expect(response.body).not.toContain('1158201444');
    expect(response.body).not.toContain(TEST_VERIFY_TOKEN);
  });

  it('is not registered when the deployment has no Meta configuration', async () => {
    const app = buildApp();
    apps.push(app);

    const response = await app.inject({
      method: 'GET',
      url: `${WEBHOOK_URL}?hub.mode=subscribe&hub.verify_token=${TEST_VERIFY_TOKEN}&hub.challenge=1158201444`,
    });

    expect(response.statusCode).toBe(404);
  });
});

describe('POST /webhooks/meta — authenticity', () => {
  it('accepts a signed WhatsApp text message and stores exactly one event', async () => {
    const { app, store } = makeApp();
    const body = loadMetaFixture('whatsapp-text');

    const response = await postMeta(app, body);

    expect(response.statusCode).toBe(200);
    expect(metaWebhookAckSchema.parse(response.json())).toEqual({
      status: 'ok',
      stored: 1,
      duplicates: 0,
      unroutable: 0,
      ignored: 0,
    });
    expect(store.events).toHaveLength(1);
    expect(store.events[0]).toMatchObject({
      channel: 'whatsapp',
      routingKey: '109876543210987',
      externalId: '2348031234567',
      displayName: 'Zainab Adeyemi',
      type: 'text',
    });
  });

  it.each([
    ['no signature header', null, 401],
    ['an empty signature', '', 401],
    ['a signature with no prefix', 'deadbeef', 401],
    ['a truncated signature', 'sha256=abc', 401],
    ['a signature computed with another secret', 'other-secret', 401],
  ] as const)('rejects %s with 401 and writes nothing', async (_case, signature, expectedStatus) => {
    const { app, store } = makeApp();
    const body = loadMetaFixture('whatsapp-text');
    const header =
      signature === 'other-secret'
        ? metaSignatureHeader(body, 'some-other-app-secret')
        : signature;

    const response = await postMeta(app, body, { signature: header });

    expect(response.statusCode).toBe(expectedStatus);
    expect(store.events).toEqual([]);
  });

  it('rejects a body that was altered after it was signed, and writes nothing', async () => {
    const { app, store } = makeApp();
    const original = loadMetaFixture('whatsapp-text');
    const signature = metaSignatureHeader(original, TEST_APP_SECRET);
    // Same payload, one number changed: the classic man-in-the-middle edit.
    const tampered = Buffer.from(
      original.toString('utf8').replace('2348031234567', '2348099999999'),
      'utf8',
    );
    expect(tampered.equals(original)).toBe(false);

    const response = await postMeta(app, tampered, { signature });

    expect(response.statusCode).toBe(401);
    expect(response.json()).toEqual({ error: 'invalid_signature' });
    expect(store.events).toEqual([]);
  });

  it('rejects a signature over the re-serialised body, proving the HMAC covers the raw bytes', async () => {
    const { app, store } = makeApp();
    const raw = loadMetaFixture('whatsapp-text');
    const reserialised = Buffer.from(JSON.stringify(JSON.parse(raw.toString('utf8'))), 'utf8');
    // The two differ only in whitespace, which is exactly what a JSON parser
    // throws away. Signing the re-serialised form must not be accepted.
    expect(reserialised.equals(raw)).toBe(false);

    const response = await postMeta(app, raw, {
      signature: metaSignatureHeader(reserialised, TEST_APP_SECRET),
    });

    expect(response.statusCode).toBe(401);
    expect(store.events).toEqual([]);
  });

  it('accepts the raw bytes even when the JSON is odd-looking', async () => {
    const { app, store } = makeApp();
    // No newline, spaces everywhere, a key order no serializer here would pick.
    const odd = Buffer.from(
      '{ "entry" : [ ] ,   "object":"whatsapp_business_account" }',
      'utf8',
    );

    const response = await postMeta(app, odd);

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({ status: 'ok', stored: 0, ignored: 0 });
    expect(store.events).toEqual([]);
  });

  it('rejects an unsigned request that has no body at all', async () => {
    const { app, store } = makeApp();

    const response = await app.inject({
      method: 'POST',
      url: WEBHOOK_URL,
      headers: { 'content-type': 'application/json' },
      payload: '',
    });

    expect(response.statusCode).toBe(401);
    expect(store.events).toEqual([]);
  });

  it('ignores a repeated signature header rather than guessing which one to check', async () => {
    const { app, store } = makeApp();
    const body = loadMetaFixture('whatsapp-text');

    const response = await app.inject({
      method: 'POST',
      url: WEBHOOK_URL,
      payload: body,
      headers: {
        'content-type': 'application/json',
        'x-hub-signature-256': [
          metaSignatureHeader(body, TEST_APP_SECRET),
          metaSignatureHeader(body, TEST_APP_SECRET),
        ],
      },
    });

    expect(response.statusCode).toBe(401);
    expect(store.events).toEqual([]);
  });

  it('rejects a correctly signed body that is not JSON', async () => {
    const { app, store } = makeApp();
    const body = Buffer.from('not json at all', 'utf8');

    const response = await postMeta(app, body);

    expect(response.statusCode).toBe(400);
    expect(store.events).toEqual([]);
  });
});

describe('POST /webhooks/meta — parsing, routing and acknowledgement', () => {
  it('stores a signed Instagram DM', async () => {
    const { app, store } = makeApp();
    const body = loadMetaFixture('instagram-text');

    const response = await postMeta(app, body);

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({ status: 'ok', stored: 1 });
    expect(store.events[0]).toMatchObject({
      channel: 'instagram',
      routingKey: '17841400000000001',
      externalId: '7012384591267503',
      type: 'text',
    });
  });

  it.each([
    ['whatsapp-voice-note', 'voice'],
    ['whatsapp-image-with-caption', 'image'],
    ['instagram-image-attachment', 'image'],
  ] as const)('stores %s as type %s', async (fixture, type) => {
    const { app, store } = makeApp();

    const response = await postMeta(app, loadMetaFixture(fixture));

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({ stored: 1 });
    expect(store.events.map((event) => event.type)).toEqual([type]);
  });

  it.each([
    ['whatsapp-status-callback', 'status_callback'],
    ['whatsapp-other-message-type', 'unsupported_message_type'],
    ['whatsapp-unknown-event', 'malformed_entry'],
    ['instagram-read-callback', 'read_receipt'],
    ['instagram-echo', 'unsupported_event'],
  ] as const)('acknowledges %s with 200 and writes no rows', async (fixture, _reason) => {
    const { app, store } = makeApp();

    const response = await postMeta(app, loadMetaFixture(fixture));

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({ status: 'ok', stored: 0, duplicates: 0, unroutable: 0, ignored: 1 });
    expect(store.events).toEqual([]);
  });

  it('acknowledges a duplicate delivery with 200 and reports it as a duplicate', async () => {
    const { app, store } = makeApp({
      store: createRecordingStore(() => ({
        outcome: 'duplicate',
        tenantId: '5eed0000-0000-4000-8000-000000000001',
        contactId: '5eed0000-0000-4000-8000-000000000301',
        conversationId: '5eed0000-0000-4000-8000-000000000401',
      })),
    });
    const body = loadMetaFixture('whatsapp-text');

    const first = await postMeta(app, body);
    const second = await postMeta(app, body);

    expect(first.statusCode).toBe(200);
    expect(second.statusCode).toBe(200);
    expect(second.json()).toMatchObject({ status: 'ok', stored: 0, duplicates: 1 });
    // The store is asked to dedupe (that is its job); the route must report the
    // outcome truthfully rather than counting it as stored.
    expect(store.events).toHaveLength(2);
    expect(store.events[0]?.metaMessageId).toBe(store.events[1]?.metaMessageId);
  });

  it('acknowledges an unroutable payload with 200 and reports it as unroutable', async () => {
    const { app, store } = makeApp({
      store: createRecordingStore((event) => ({
        outcome: 'unroutable',
        routingKey: event.routingKey,
        channel: event.channel,
      })),
    });

    const response = await postMeta(app, loadMetaFixture('whatsapp-unknown-phone-number'));

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({ status: 'ok', unroutable: 1, stored: 0 });
    expect(store.events).toHaveLength(1);
  });

  it('answers 500 when the store fails, so Meta retries', async () => {
    const { app } = makeApp({ store: createFailingStore(new Error('database is unreachable')) });

    const response = await postMeta(app, loadMetaFixture('whatsapp-text'));

    expect(response.statusCode).toBe(500);
  });

  it('counts every outcome in one delivery', async () => {
    // One body carrying three messages: stored, duplicate, unroutable.
    const body = Buffer.from(
      JSON.stringify({
        object: 'whatsapp_business_account',
        entry: [
          {
            id: 'waba',
            changes: [
              {
                field: 'messages',
                value: {
                  messaging_product: 'whatsapp',
                  metadata: { phone_number_id: '109876543210987' },
                  contacts: [{ wa_id: '2348031234567', profile: { name: 'Zainab Adeyemi' } }],
                  messages: [
                    { from: '2348031234567', id: 'wamid.A', timestamp: '1792058400', type: 'text', text: { body: 'one' } },
                    { from: '2348031234567', id: 'wamid.B', timestamp: '1792058401', type: 'text', text: { body: 'two' } },
                    { from: '2348031234567', id: 'wamid.C', timestamp: '1792058402', type: 'text', text: { body: 'three' } },
                  ],
                },
              },
            ],
          },
        ],
      }),
      'utf8',
    );

    const { app } = makeApp({
      store: createRecordingStore((_event, index) => {
        if (index === 1) {
          return { outcome: 'duplicate', tenantId: 't', contactId: 'c', conversationId: 'v' };
        }
        if (index === 2) return { outcome: 'unroutable', routingKey: 'k', channel: 'whatsapp' };
        return storedOutcome();
      }),
    });

    const response = await postMeta(app, body);

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({ stored: 1, duplicates: 1, unroutable: 1, ignored: 0 });
  });
});
