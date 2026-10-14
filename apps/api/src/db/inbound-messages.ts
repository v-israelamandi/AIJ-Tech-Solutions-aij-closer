import type { Pool, PoolClient } from 'pg';
import { z } from 'zod';
import { channelTypeSchema, messageTypeSchema } from '@aij/shared';

/**
 * The inbound-message repository.
 *
 * Everything the webhook ingress needs from the database lives behind
 * `InboundMessageStore`, so the route (and its tests) handle a *normalised*
 * event and never touch SQL. PR 6's agent tools can reuse the same module for
 * reading conversations and appending messages.
 *
 * The connection this runs on is the privileged, RLS-bypassing one described in
 * `pool.ts`. Parameters are always bound, never interpolated.
 */

/** A buyer message, already normalised from a Meta payload. */
export const inboundMessageEventSchema = z.object({
  /** Which Meta product it arrived on. */
  channel: channelTypeSchema,
  /**
   * The channel's routing key as Meta sent it: `metadata.phone_number_id` for
   * WhatsApp, the Instagram account id for Instagram. Resolved to a tenant
   * through `public.channels`.
   */
  routingKey: z.string().min(1),
  /** WhatsApp `wa_id` (phone number) or Instagram IGSID. The contact's identity at Meta. */
  externalId: z.string().min(1),
  /** Profile name from the payload, when Meta sends one. Empty string otherwise. */
  displayName: z.string().default(''),
  /** Meta's message id. The dedupe key: Meta retries webhooks. */
  metaMessageId: z.string().min(1),
  /** `audio` payloads become `voice`; `image` payloads become `image`. */
  type: messageTypeSchema,
  /** Text body, or the image caption. Empty for a voice note until STT lands. */
  content: z.string().default(''),
  /** When Meta says the buyer sent it (WhatsApp: seconds, Instagram: milliseconds). */
  sentAt: z.date(),
});

export type InboundMessageEvent = z.infer<typeof inboundMessageEventSchema>;

/** What actually happened to one event. */
export type InboundMessageOutcome =
  | {
      outcome: 'stored';
      tenantId: string;
      contactId: string;
      conversationId: string;
      messageId: string;
      /** End of Meta's 24-hour customer service window for this thread. */
      windowExpiresAt: Date;
    }
  /** Meta redelivered a message we already have. Nothing was written. */
  | { outcome: 'duplicate'; tenantId: string; contactId: string; conversationId: string }
  /** No active channel matched the routing key, so no tenant owns this payload. */
  | { outcome: 'unroutable'; routingKey: string; channel: InboundMessageEvent['channel'] };

export interface InboundMessageStore {
  store(event: InboundMessageEvent): Promise<InboundMessageOutcome>;
}

/** Meta's 24-hour customer service window, in hours. */
const CUSTOMER_SERVICE_WINDOW_HOURS = 24;

// ---------------------------------------------------------------------------
// SQL. Named so the tests and the next PR can see exactly what runs.
// ---------------------------------------------------------------------------

/**
 * Tenant routing. Both unique partial indexes on `channels` cover this lookup,
 * so it returns at most one row, and an inactive channel deliberately does not
 * route: a disconnected inbox must not keep writing into a vendor's data.
 */
const FIND_CHANNEL_SQL = `
  select id as channel_id, tenant_id
    from public.channels
   where type = $1
     and active
     and ((type = 'whatsapp' and phone_number_id = $2)
       or (type = 'instagram' and instagram_account_id = $2))
`;

/**
 * Contact upsert. Keyed on the constraint rather than a read-then-insert so two
 * concurrent deliveries of the same first message cannot create two contacts.
 * A name is only ever replaced by another non-empty name: WhatsApp omits the
 * profile on some payloads and that must not erase what we already know.
 */
const UPSERT_CONTACT_SQL = `
  insert into public.contacts (tenant_id, channel, external_id, display_name)
  values ($1, $2, $3, $4)
  on conflict on constraint contacts_tenant_id_channel_external_id_key
  do update set display_name = case
        when excluded.display_name <> '' then excluded.display_name
        else public.contacts.display_name
      end
  returning id
`;

/** The thread this message belongs to: the open one, oldest first. */
const FIND_OPEN_CONVERSATION_SQL = `
  select id
    from public.conversations
   where tenant_id = $1
     and contact_id = $2
     and status <> 'closed'
   order by created_at
   limit 1
`;

/**
 * Start a thread. `on conflict do nothing` leans on
 * `conversations_one_open_per_contact_key`, so a redelivery racing with the
 * original creates nothing and the caller re-reads the winner's row.
 */
const CREATE_CONVERSATION_SQL = `
  insert into public.conversations (tenant_id, contact_id, channel, status)
  values ($1, $2, $3, 'bot')
  on conflict do nothing
  returning id
`;

/**
 * The message itself. This is where deduplication happens: the partial unique
 * index `messages_meta_message_id_key` rejects the second copy of a message
 * Meta delivered twice, and `on conflict do nothing` turns that into "zero rows
 * returning" rather than an error. Never a read-then-write race — the database
 * is the arbiter, so two concurrent redeliveries cannot both insert.
 */
const INSERT_INBOUND_MESSAGE_SQL = `
  insert into public.messages
    (tenant_id, conversation_id, direction, type, content, media_url, meta_message_id)
  values ($1, $2, 'inbound', $3, $4, null, $5)
  on conflict do nothing
  returning id
`;

/**
 * Push the customer service window out to 24 hours past the newest inbound
 * message. `greatest` means a message that arrives out of order (Meta does not
 * promise ordering) can only ever extend the window, never shrink it — the
 * window always reflects the most recent thing the buyer sent.
 */
const EXTEND_WINDOW_SQL = `
  update public.conversations
     set window_expires_at = greatest(
           coalesce(window_expires_at, to_timestamp(0)),
           $2::timestamptz + make_interval(hours => ${CUSTOMER_SERVICE_WINDOW_HOURS})
         )
   where tenant_id = $1
     and id = $3
  returning window_expires_at
`;

/**
 * Fast path for the common retry. The unique index above is what actually makes
 * this safe; this read only avoids opening a transaction and touching the
 * contact for a message we provably already have. If it misses (or races), the
 * insert still refuses the duplicate.
 */
const FIND_MESSAGE_BY_META_ID_SQL = `
  select id, tenant_id, conversation_id
    from public.messages
   where meta_message_id = $1
`;

/** Postgres' unique-violation SQLSTATE. */
const UNIQUE_VIOLATION = '23505';

function isUniqueViolation(error: unknown): boolean {
  return typeof error === 'object' && error !== null && 'code' in error
    && (error as { code?: unknown }).code === UNIQUE_VIOLATION;
}

async function rollback(client: PoolClient): Promise<void> {
  try {
    await client.query('rollback');
  } catch {
    // The connection is already broken; releasing it is the pool's problem.
  }
}

/**
 * The `pg` implementation of `InboundMessageStore`.
 *
 * One inbound message is one transaction: channel lookup, contact upsert,
 * find-or-create conversation, message insert, window update. Either the whole
 * delivery is recorded or none of it is, so a crash mid-way cannot leave a
 * conversation with a window that no message justifies.
 */
export function createPgInboundMessageStore(pool: Pool): InboundMessageStore {
  async function findExistingMessage(
    client: PoolClient,
    metaMessageId: string,
  ): Promise<InboundMessageOutcome | null> {
    const { rows } = await client.query<{
      id: string;
      tenant_id: string;
      conversation_id: string;
    }>(FIND_MESSAGE_BY_META_ID_SQL, [metaMessageId]);

    const existing = rows[0];
    if (!existing) return null;

    const contact = await client.query<{ contact_id: string }>(
      'select contact_id from public.conversations where tenant_id = $1 and id = $2',
      [existing.tenant_id, existing.conversation_id],
    );

    return {
      outcome: 'duplicate',
      tenantId: existing.tenant_id,
      conversationId: existing.conversation_id,
      contactId: contact.rows[0]?.contact_id ?? '',
    };
  }

  async function routeToTenant(
    client: PoolClient,
    event: InboundMessageEvent,
  ): Promise<string | null> {
    const { rows } = await client.query<{ channel_id: string; tenant_id: string }>(
      FIND_CHANNEL_SQL,
      [event.channel, event.routingKey],
    );
    return rows[0]?.tenant_id ?? null;
  }

  async function findOrCreateConversation(
    client: PoolClient,
    tenantId: string,
    contactId: string,
    channel: InboundMessageEvent['channel'],
  ): Promise<string> {
    const found = await client.query<{ id: string }>(FIND_OPEN_CONVERSATION_SQL, [
      tenantId,
      contactId,
    ]);
    if (found.rows[0]) return found.rows[0].id;

    const created = await client.query<{ id: string }>(CREATE_CONVERSATION_SQL, [
      tenantId,
      contactId,
      channel,
    ]);
    if (created.rows[0]) return created.rows[0].id;

    // `on conflict do nothing` fired: another delivery of the same message
    // created this contact's open conversation a moment ago. Use theirs.
    const raced = await client.query<{ id: string }>(FIND_OPEN_CONVERSATION_SQL, [
      tenantId,
      contactId,
    ]);
    const racedId = raced.rows[0]?.id;
    if (!racedId) {
      throw new Error(
        'could not find or create an open conversation for the inbound message',
      );
    }
    return racedId;
  }

  return {
    async store(event: InboundMessageEvent): Promise<InboundMessageOutcome> {
      const client = await pool.connect();
      try {
        await client.query('begin');

        const already = await findExistingMessage(client, event.metaMessageId);
        if (already) {
          await client.query('commit');
          return already;
        }

        const tenantId = await routeToTenant(client, event);
        if (!tenantId) {
          await client.query('commit');
          return {
            outcome: 'unroutable',
            routingKey: event.routingKey,
            channel: event.channel,
          };
        }

        const contact = await client.query<{ id: string }>(UPSERT_CONTACT_SQL, [
          tenantId,
          event.channel,
          event.externalId,
          event.displayName,
        ]);
        const contactId = contact.rows[0]?.id;
        if (!contactId) throw new Error('contact upsert returned no row');

        const conversationId = await findOrCreateConversation(
          client,
          tenantId,
          contactId,
          event.channel,
        );

        const inserted = await client.query<{ id: string }>(INSERT_INBOUND_MESSAGE_SQL, [
          tenantId,
          conversationId,
          event.type,
          event.content,
          event.metaMessageId,
        ]);

        const messageId = inserted.rows[0]?.id;
        if (!messageId) {
          // Lost the race to a concurrent delivery of the same message. The
          // other delivery owns the row (and the window update), so this one
          // writes nothing at all.
          await client.query('rollback');
          const existing = await findExistingMessage(client, event.metaMessageId);
          if (existing) return existing;
          throw new Error('inbound message insert conflicted but no row exists');
        }

        const window = await client.query<{ window_expires_at: Date }>(EXTEND_WINDOW_SQL, [
          tenantId,
          event.sentAt,
          conversationId,
        ]);

        await client.query('commit');

        return {
          outcome: 'stored',
          tenantId,
          contactId,
          conversationId,
          messageId,
          windowExpiresAt: window.rows[0]?.window_expires_at ?? event.sentAt,
        };
      } catch (error) {
        // A concurrent insert of the same message id is the one conflict that
        // is not a failure: the other transaction stored it. Anything else is
        // rethrown so the route can answer 500 and let Meta retry.
        await rollback(client);
        if (isUniqueViolation(error)) {
          const existing = await findExistingMessage(client, event.metaMessageId);
          if (existing) return existing;
        }
        throw error;
      } finally {
        client.release();
      }
    },
  };
}
