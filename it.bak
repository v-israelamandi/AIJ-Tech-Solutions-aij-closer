import { Pool } from 'pg';
import { afterAll, describe, expect, it } from 'vitest';
import { parseMetaWebhook } from '../webhooks/meta/payload.js';
import { loadMetaFixtureJson, type MetaFixture } from '../webhooks/meta/test-support/index.js';
import {
  createPgInboundMessageStore,
  type InboundMessageEvent,
  type InboundMessageOutcome,
} from './inbound-messages.js';

/**
 * The repository against a real, migrated and seeded Postgres.
 *
 * This is the test that proves the ingress actually writes: routing through
 * `channels`, the contact upsert, find-or-create for the conversation, the
 * message insert, the 24-hour window, and above all that **the database** — not
 * a read-then-write check in JavaScript — refuses the second copy of a message
 * Meta delivered twice.
 *
 * Run it with the migrations and the demo seed applied:
 *
 *   createdb aij_test
 *   export DATABASE_URL=postgresql://localhost/aij_test
 *   npm run test:db && npm run seed && npm run test:integration
 *
 * It skips — visibly, in its own name — when there is no `DATABASE_URL`, or
 * when the database it points at has no `sisi-lagos-fashion` tenant to resolve
 * against, which is how the ordinary unit-test run in CI stays database-free.
 * Rows it creates are namespaced by a per-run id and deleted afterwards.
 */

const DEMO_TENANT_SLUG = 'sisi-lagos-fashion';
const WHATSAPP_PHONE_NUMBER_ID = '109876543210987';
const INSTAGRAM_ACCOUNT_ID = '17841400000000001';

const databaseUrl = process.env.DATABASE_URL;
const runId = `itest-${Date.now().toString(36)}-${Math.floor(Math.random() * 1e6).toString(36)}`;

/** Every fixture this test delivers, namespaced so a re-run cannot collide. */
function eventFromFixture(fixture: MetaFixture, suffix: string): InboundMessageEvent[] {
  const parsed = parseMetaWebhook(loadMetaFixtureJson(fixture));
  expect(parsed.ignored).toEqual([]);
  expect(parsed.events).toHaveLength(1);
  return parsed.events.map((event) => ({
    ...event,
    // Both keys get this run's id: the contact, so repeated runs start from
    // nothing, and the message id, so dedupe is exercised within a run only.
    externalId: `${event.externalId}.${runId}.${suffix}`,
    metaMessageId: `${event.metaMessageId}.${runId}.${suffix}`,
  }));
}

function eventFromPayload(payload: unknown): InboundMessageEvent[] {
  const parsed = parseMetaWebhook(payload);
  expect(parsed.ignored).toEqual([]);
  expect(parsed.events).toHaveLength(1);
  return parsed.events;
}

/** A WhatsApp text payload for a buyer we choose, at a time we choose. */
function whatsappTextPayload(options: {
  waId: string;
  metaMessageId: string;
  body: string;
  seconds: number;
  name?: string;
  phoneNumberId?: string;
}): unknown {
  return {
    object: 'whatsapp_business_account',
    entry: [
      {
        id: '102290129340398',
        changes: [
          {
            field: 'messages',
            value: {
              messaging_product: 'whatsapp',
              metadata: {
                display_phone_number: '2348023456789',
                phone_number_id: options.phoneNumberId ?? WHATSAPP_PHONE_NUMBER_ID,
              },
              contacts: [
                { wa_id: options.waId, ...(options.name === undefined ? {} : { profile: { name: options.name } }) },
              ],
              messages: [
                {
                  from: options.waId,
                  id: options.metaMessageId,
                  timestamp: String(options.seconds),
                  type: 'text',
                  text: { body: options.body },
                },
              ],
            },
          },
        ],
      },
    ],
  };
}

/** The 2026-10-15T10:00:00Z the fixtures use, in Unix seconds. */
const FIXTURE_SECONDS = 1792058400;

const pool = databaseUrl ? new Pool({ connectionString: databaseUrl, max: 4 }) : null;
const store = pool ? createPgInboundMessageStore(pool) : null;

let skipReason: string | null = null;
if (!databaseUrl) skipReason = 'DATABASE_URL is not set';

const tenantRows = databaseUrl
  ? await query<{ id: string }>('select id from public.tenants where slug = $1', [DEMO_TENANT_SLUG])
  : [];

if (databaseUrl && tenantRows.length === 0) {
  skipReason = `no ${DEMO_TENANT_SLUG} tenant: run npm run test:db && npm run seed first`;
}

const tenantId = tenantRows[0]?.id ?? '';

async function query<T extends Record<string, unknown>>(
  sql: string,
  params: unknown[] = [],
): Promise<T[]> {
  if (!pool) throw new Error('the integration test has no database pool');
  const { rows } = await pool.query<T>(sql, params);
  return rows;
}

/** What this test has written so far, for one buyer. */
async function countsFor(externalId: string): Promise<{
  contacts: number;
  conversations: number;
  messages: number;
}> {
  const [row] = await query<{ contacts: string; conversations: string; messages: string }>(
    `select
       (select count(*) from public.contacts where tenant_id = $1 and external_id = $2) as contacts,
       (select count(*) from public.conversations c
          join public.contacts k on k.tenant_id = c.tenant_id and k.id = c.contact_id
         where c.tenant_id = $1 and k.external_id = $2) as conversations,
       (select count(*) from public.messages m
          join public.contacts k on k.tenant_id = m.tenant_id
          join public.conversations c on c.tenant_id = m.tenant_id and c.id = m.conversation_id and c.contact_id = k.id
         where m.tenant_id = $1 and k.external_id = $2) as messages`,
    [tenantId, externalId],
  );

  return {
    contacts: Number(row?.contacts ?? 0),
    conversations: Number(row?.conversations ?? 0),
    messages: Number(row?.messages ?? 0),
  };
}

/** The stored message rows for one buyer, newest first. */
async function messagesFor(externalId: string): Promise<
  Array<{ direction: string; type: string; content: string; meta_message_id: string | null }>
> {
  return query(
    `select m.direction, m.type, m.content, m.meta_message_id
       from public.messages m
       join public.conversations c on c.tenant_id = m.tenant_id and c.id = m.conversation_id
       join public.contacts k on k.tenant_id = c.tenant_id and k.id = c.contact_id
      where k.tenant_id = $1 and k.external_id = $2
      order by m.created_at`,
    [tenantId, externalId],
  );
}

async function windowFor(externalId: string): Promise<Date | null> {
  const [row] = await query<{ window_expires_at: Date | null }>(
    `select c.window_expires_at
       from public.conversations c
       join public.contacts k on k.tenant_id = c.tenant_id and k.id = c.contact_id
      where k.tenant_id = $1 and k.external_id = $2`,
    [tenantId, externalId],
  );
  return row?.window_expires_at ?? null;
}

/** Fails loudly rather than silently asserting against a missing database. */
function requireStore(): NonNullable<typeof store> {
  if (!store) throw new Error('the integration test has no database connection');
  return store;
}

const describeDb = skipReason ? describe.skip : describe;

describeDb(
  `inbound-message repository against Postgres${skipReason ? ` — skipped: ${skipReason}` : ''}`,
  () => {
    afterAll(async () => {
      if (!pool) return;
      // Everything this test created hangs off its own contacts, and deleting
      // the contact cascades to conversations and messages.
      await query('delete from public.contacts where tenant_id = $1 and external_id like $2', [
        tenantId,
        `%${runId}%`,
      ]);
      await query('update public.channels set active = true where tenant_id = $1', [tenantId]);
      await pool.end();
    });

    it('stores a WhatsApp delivery: contact, bot conversation, inbound message and a 24-hour window', async () => {
      const waId = `23480300${runId.slice(-6)}`;
      const [event] = eventFromPayload(
        whatsappTextPayload({
          waId,
          name: 'Zainab Adeyemi',
          metaMessageId: `wamid.ITEST-1-${runId}`,
          body: 'Good afternoon. How much is the Zainab Adire two-piece set?',
          seconds: FIXTURE_SECONDS,
        }),
      ) as [InboundMessageEvent];

      const outcome = await requireStore().store(event);

      expect(outcome.outcome).toBe('stored');
      if (outcome.outcome !== 'stored') return;
      expect(outcome.tenantId).toBe(tenantId);

      expect(await countsFor(waId)).toEqual({ contacts: 1, conversations: 1, messages: 1 });
      expect(await messagesFor(waId)).toEqual([
        {
          direction: 'inbound',
          type: 'text',
          content: 'Good afternoon. How much is the Zainab Adire two-piece set?',
          meta_message_id: `wamid.ITEST-1-${runId}`,
        },
      ]);

      const [contact] = await query<{ display_name: string; channel: string }>(
        'select display_name, channel from public.contacts where tenant_id = $1 and external_id = $2',
        [tenantId, waId],
      );
      expect(contact).toMatchObject({ display_name: 'Zainab Adeyemi', channel: 'whatsapp' });

      const [conversation] = await query<{ status: string; channel: string }>(
        'select status, channel from public.conversations where tenant_id = $1 and id = $2',
        [tenantId, outcome.conversationId],
      );
      expect(conversation).toEqual({ status: 'bot', channel: 'whatsapp' });

      // Last inbound message time + 24 hours, exactly as the brief specifies.
      expect(outcome.windowExpiresAt.toISOString()).toBe('2026-10-16T10:00:00.000Z');
      expect((await windowFor(waId))?.toISOString()).toBe('2026-10-16T10:00:00.000Z');
    });

    it('stores the audio fixture as a voice note and the image fixture as an image', async () => {
      const [voice] = eventFromFixture('whatsapp-voice-note', 'voice') as [InboundMessageEvent];
      const [image] = eventFromFixture('whatsapp-image-with-caption', 'image') as [InboundMessageEvent];

      expect((await requireStore().store(voice)).outcome).toBe('stored');
      expect((await requireStore().store(image)).outcome).toBe('stored');

      expect(await messagesFor(voice.externalId)).toMatchObject([
        { direction: 'inbound', type: 'voice', content: '' },
      ]);
      expect(await messagesFor(image.externalId)).toMatchObject([
        {
          direction: 'inbound',
          type: 'image',
          content: 'I saw this on your page. Does it come in a bigger size?',
        },
      ]);
    });

    it('routes an Instagram delivery through the account id, as its own contact and thread', async () => {
      const [event] = eventFromFixture('instagram-text', 'ig') as [InboundMessageEvent];
      expect(event.routingKey).toBe(INSTAGRAM_ACCOUNT_ID);

      const outcome = await requireStore().store(event);

      expect(outcome.outcome).toBe('stored');
      expect(await countsFor(event.externalId)).toEqual({ contacts: 1, conversations: 1, messages: 1 });

      const [contact] = await query<{ channel: string }>(
        'select channel from public.contacts where tenant_id = $1 and external_id = $2',
        [tenantId, event.externalId],
      );
      expect(contact?.channel).toBe('instagram');
    });

    it('treats the same buyer id on two channels as two contacts', async () => {
      const externalId = `shared-id-${runId}`;
      const [whatsapp] = eventFromPayload(
        whatsappTextPayload({
          waId: externalId,
          metaMessageId: `wamid.ITEST-2-${runId}`,
          body: 'whatsapp thread',
          seconds: FIXTURE_SECONDS,
        }),
      ) as [InboundMessageEvent];
      const [instagram] = eventFromFixture('instagram-text', 'shared') as [InboundMessageEvent];

      await requireStore().store(whatsapp);
      await requireStore().store({ ...instagram, externalId });

      const rows = await query<{ channel: string }>(
        'select channel from public.contacts where tenant_id = $1 and external_id = $2 order by channel',
        [tenantId, externalId],
      );
      expect(rows.map((row) => row.channel)).toEqual(['instagram', 'whatsapp']);
    });

    it('records a redelivered message once and does not move the window again', async () => {
      const waId = `23480310${runId.slice(-6)}`;
      const payload = whatsappTextPayload({
        waId,
        name: 'Chidinma Okonkwo',
        metaMessageId: `wamid.ITEST-3-${runId}`,
        body: 'Abeg, how much for the bubu gown?',
        seconds: FIXTURE_SECONDS,
      });
      const [event] = eventFromPayload(payload) as [InboundMessageEvent];

      const first = await requireStore().store(event);
      const windowAfterFirst = await windowFor(waId);
      const second = await requireStore().store(event);
      const third = await requireStore().store({ ...event });

      expect(first.outcome).toBe('stored');
      // A redelivery is recognised, not stored, and never an error.
      expect(second.outcome).toBe('duplicate');
      expect(third.outcome).toBe('duplicate');

      expect(await countsFor(waId)).toEqual({ contacts: 1, conversations: 1, messages: 1 });
      expect(await windowFor(waId)).toEqual(windowAfterFirst);
      expect((await windowFor(waId))?.toISOString()).toBe('2026-10-16T10:00:00.000Z');
    });

    it('lets a later message extend the window but never lets a late one shrink it', async () => {
      const waId = `23480320${runId.slice(-6)}`;
      const message = (index: number, seconds: number): InboundMessageEvent =>
        (
          eventFromPayload(
            whatsappTextPayload({
              waId,
              metaMessageId: `wamid.ITEST-4-${index}-${runId}`,
              body: `message ${index}`,
              seconds,
            }),
          ) as [InboundMessageEvent]
        )[0];

      await requireStore().store(message(1, FIXTURE_SECONDS));
      // 25 hours later: the window should follow the newer message.
      await requireStore().store(message(2, FIXTURE_SECONDS + 25 * 3600));
      expect((await windowFor(waId))?.toISOString()).toBe('2026-10-17T11:00:00.000Z');

      // Then a message Meta delivers late, from before either: it must be
      // stored, but the window stays where the newest message put it.
      await requireStore().store(message(3, FIXTURE_SECONDS - 3600));
      expect((await windowFor(waId))?.toISOString()).toBe('2026-10-17T11:00:00.000Z');
      expect(await countsFor(waId)).toEqual({ contacts: 1, conversations: 1, messages: 3 });
    });

    it('keeps the name it knows when a later payload carries no profile', async () => {
      const waId = `23480330${runId.slice(-6)}`;

      await requireStore().store(
        (eventFromPayload(
          whatsappTextPayload({
            waId,
            name: 'Blessing Eze',
            metaMessageId: `wamid.ITEST-5-a-${runId}`,
            body: 'first',
            seconds: FIXTURE_SECONDS,
          }),
        ) as [InboundMessageEvent])[0],
      );
      // No `contacts[]` at all, which happens on real deliveries.
      await requireStore().store(
        (eventFromPayload(
          whatsappTextPayload({
            waId,
            metaMessageId: `wamid.ITEST-5-b-${runId}`,
            body: 'second',
            seconds: FIXTURE_SECONDS + 60,
          }),
        ) as [InboundMessageEvent])[0],
      );

      const [contact] = await query<{ display_name: string }>(
        'select display_name from public.contacts where tenant_id = $1 and external_id = $2',
        [tenantId, waId],
      );
      expect(contact?.display_name).toBe('Blessing Eze');
      // And both messages landed on the same thread.
      expect(await countsFor(waId)).toEqual({ contacts: 1, conversations: 1, messages: 2 });
    });

    it('acknowledges a payload no tenant owns without writing anything at all', async () => {
      const waId = `23480340${runId.slice(-6)}`;
      const [event] = eventFromPayload(
        whatsappTextPayload({
          waId,
          metaMessageId: `wamid.ITEST-6-${runId}`,
          body: 'Hello, is this Sneakers Hub?',
          seconds: FIXTURE_SECONDS,
          phoneNumberId: `999999${runId.slice(-4)}`,
        }),
      ) as [InboundMessageEvent];

      const outcome = await requireStore().store(event);

      expect(outcome).toEqual({
        outcome: 'unroutable',
        routingKey: `999999${runId.slice(-4)}`,
        channel: 'whatsapp',
      });
      // No contact, no conversation, no message — no orphan row of any kind.
      expect(await countsFor(waId)).toEqual({ contacts: 0, conversations: 0, messages: 0 });
      const [orphans] = await query<{ meta_message_id: string | null }>(
        'select meta_message_id from public.messages where meta_message_id = $1',
        [`wamid.ITEST-6-${runId}`],
      );
      expect(orphans).toBeUndefined();
    });

    it('does not route a payload for a channel the tenant has switched off', async () => {
      const [event] = eventFromFixture('instagram-text', 'inactive') as [InboundMessageEvent];

      try {
        await query('update public.channels set active = false where tenant_id = $1 and type = $2', [
          tenantId,
          'instagram',
        ]);

        const outcome = await requireStore().store(event);

        expect(outcome.outcome).toBe('unroutable');
        expect(await countsFor(event.externalId)).toEqual({ contacts: 0, conversations: 0, messages: 0 });
      } finally {
        await query('update public.channels set active = true where tenant_id = $1 and type = $2', [
          tenantId,
          'instagram',
        ]);
      }
    });

    it('rolls the whole delivery back when the write fails', async () => {
      const waId = `23480350${runId.slice(-6)}`;
      // A message that cannot be stored: the channel routes, but the type is
      // outside messages.type's CHECK, so the insert raises after the contact
      // and conversation were created in the same transaction.
      const broken: InboundMessageEvent = {
        channel: 'whatsapp',
        routingKey: WHATSAPP_PHONE_NUMBER_ID,
        externalId: waId,
        displayName: 'Should Not Persist',
        metaMessageId: `wamid.ITEST-7-${runId}`,
        type: 'video' as InboundMessageEvent['type'],
        content: 'nope',
        sentAt: new Date(FIXTURE_SECONDS * 1000),
      };

      await expect(requireStore().store(broken)).rejects.toThrow();

      const rows = await countsFor(waId);
      expect(rows).toEqual({ contacts: 0, conversations: 0, messages: 0 });

      // And the same message stores cleanly once it is valid, proving the
      // failure was the transaction and not a poisoned meta_message_id.
      const outcome: InboundMessageOutcome = await requireStore().store({ ...broken, type: 'text' });
      expect(outcome.outcome).toBe('stored');
      expect(await countsFor(waId)).toEqual({ contacts: 1, conversations: 1, messages: 1 });
    });

    it('lets only one of several concurrent deliveries of the same message store it', async () => {
      // The test that actually exercises the unique index. A sequential
      // redelivery is caught by the fast-path read, so it would pass even with
      // no index at all. Here every delivery passes that read before any of
      // them inserts, so the database is the only thing that can stop the
      // second, third and fourth copies.
      const waId = `23480370${runId.slice(-6)}`;
      const [event] = eventFromPayload(
        whatsappTextPayload({
          waId,
          name: 'Yetunde Balogun',
          metaMessageId: `wamid.ITEST-9-${runId}`,
          body: 'four at once, please',
          seconds: FIXTURE_SECONDS,
        }),
      ) as [InboundMessageEvent];

      const outcomes = await Promise.all([
        requireStore().store({ ...event }),
        requireStore().store({ ...event }),
        requireStore().store({ ...event }),
        requireStore().store({ ...event }),
      ]);

      expect(outcomes.filter((outcome) => outcome.outcome === 'stored')).toHaveLength(1);
      expect(outcomes.filter((outcome) => outcome.outcome === 'duplicate')).toHaveLength(3);
      // One contact, one thread, one message — no orphan conversation from the
      // deliveries that lost the race.
      expect(await countsFor(waId)).toEqual({ contacts: 1, conversations: 1, messages: 1 });
      expect((await windowFor(waId))?.toISOString()).toBe('2026-10-16T10:00:00.000Z');
    });

    it('does not store a duplicate of a message it already has, whatever the window', async () => {
      const waId = `23480360${runId.slice(-6)}`;
      const [first] = eventFromPayload(
        whatsappTextPayload({
          waId,
          metaMessageId: `wamid.ITEST-8-${runId}`,
          body: 'only once, please',
          seconds: FIXTURE_SECONDS,
        }),
      ) as [InboundMessageEvent];

      expect((await requireStore().store(first)).outcome).toBe('stored');

      // A redelivery carrying a *wrong* timestamp must still change nothing.
      const redelivery = { ...first, sentAt: new Date((FIXTURE_SECONDS + 5 * 86400) * 1000) };
      expect((await requireStore().store(redelivery)).outcome).toBe('duplicate');

      expect(await countsFor(waId)).toEqual({ contacts: 1, conversations: 1, messages: 1 });
      expect((await windowFor(waId))?.toISOString()).toBe('2026-10-16T10:00:00.000Z');
    });
  },
);
