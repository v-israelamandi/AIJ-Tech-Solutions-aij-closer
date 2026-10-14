import { z } from 'zod';
import { inboundMessageEventSchema, type InboundMessageEvent } from '../../db/inbound-messages.js';

/**
 * Meta webhook payloads → normalised inbound messages.
 *
 * One Meta app serves both channels, so one endpoint receives both shapes and
 * this module is the only place that knows how they differ:
 *
 *  - `object: "whatsapp_business_account"` — `entry[].changes[].value` carries
 *    `metadata.phone_number_id`, `contacts[]` and `messages[]` (or `statuses[]`,
 *    which describes *our* delivery to the buyer and is not a buyer message).
 *  - `object: "instagram"` — `entry[].messaging[]` carries `sender`,
 *    `recipient` and `message`, alongside `read`/`delivery`/`reaction` events.
 *
 * Everything is validated: nothing downstream sees an `any`. A payload the
 * schema rejects, or an event type we do not act on (a delivery receipt, a
 * reaction, a location pin), becomes an `IgnoredMetaEvent` — acknowledged, never
 * persisted, and never a crash. Meta retries a 5xx, so the only events allowed
 * to throw are the ones we genuinely want retried.
 */

// ---------------------------------------------------------------------------
// Envelope
// ---------------------------------------------------------------------------

export const META_OBJECT_WHATSAPP = 'whatsapp_business_account';
export const META_OBJECT_INSTAGRAM = 'instagram';

export const metaWebhookBodySchema = z.object({
  object: z.string().min(1),
  entry: z.array(z.unknown()).default([]),
});

export type MetaWebhookBody = z.infer<typeof metaWebhookBodySchema>;

/** Why a webhook we understood was not turned into a message. */
export type IgnoredMetaEventReason =
  /** WhatsApp `statuses[]`: sent/delivered/read/failed receipts for our sends. */
  | 'status_callback'
  /** Instagram `read` / `delivery` events for our sends. */
  | 'read_receipt'
  /** A real event we do not act on yet: postback, reaction, message echo, ... */
  | 'unsupported_event'
  /** A buyer message of a type that is not text, a voice note or an image. */
  | 'unsupported_message_type'
  /** Did not validate against the channel's payload shape. */
  | 'malformed_entry';

/**
 * An event that deliberately produced nothing. `ids` carries Meta-side
 * identifiers only — a channel key, a message id, an event type. Never a
 * message body, which is the buyer's, not ours, to put in a log.
 */
export interface IgnoredMetaEvent {
  reason: IgnoredMetaEventReason;
  ids: Record<string, string>;
}

export interface ParsedMetaWebhook {
  events: InboundMessageEvent[];
  ignored: IgnoredMetaEvent[];
}

/** Keeps `ids` free of undefined and empty values. */
function ids(...pairs: Array<[string, string | undefined]>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of pairs) {
    if (value) out[key] = value;
  }
  return out;
}

// ---------------------------------------------------------------------------
// WhatsApp Cloud API
// ---------------------------------------------------------------------------

/** WhatsApp sends Unix seconds, as a string. */
const waTimestampSchema = z.coerce
  .number()
  .int()
  .nonnegative()
  .transform((seconds) => new Date(seconds * 1000));

const waContactSchema = z.object({
  wa_id: z.string().min(1),
  profile: z.object({ name: z.string().min(1).optional() }).optional(),
});

const waMetadataSchema = z.object({
  /** The routing key: `public.channels.phone_number_id`. */
  phone_number_id: z.string().min(1),
  display_phone_number: z.string().optional(),
});

/**
 * Fields every inbound WhatsApp message carries. Kept separate so the three
 * supported types share one shape and the union only adds what differs.
 */
const waMessageEnvelope = {
  id: z.string().min(1),
  from: z.string().min(1),
  timestamp: waTimestampSchema,
};

const waTextMessageSchema = z.object({
  ...waMessageEnvelope,
  type: z.literal('text'),
  text: z.object({ body: z.string() }),
});

const waAudioMessageSchema = z.object({
  ...waMessageEnvelope,
  type: z.literal('audio'),
  audio: z.object({
    /** Needed to fetch the media for transcription; not persisted yet (see README). */
    id: z.string().min(1),
    mime_type: z.string().optional(),
    sha256: z.string().optional(),
    /** True when the buyer used the microphone rather than uploading a file. */
    voice: z.boolean().optional(),
  }),
});

const waImageMessageSchema = z.object({
  ...waMessageEnvelope,
  type: z.literal('image'),
  image: z.object({
    id: z.string().min(1),
    mime_type: z.string().optional(),
    sha256: z.string().optional(),
    caption: z.string().optional(),
  }),
});

const waInboundMessageSchema = z.discriminatedUnion('type', [
  waTextMessageSchema,
  waAudioMessageSchema,
  waImageMessageSchema,
]);

/** Enough of a message to name what we are ignoring, without trusting it. */
const waMessageShapeSchema = z.object({
  id: z.string().min(1).optional(),
  from: z.string().min(1).optional(),
  type: z.string().min(1).optional(),
});

const waValueSchema = z.object({
  messaging_product: z.literal('whatsapp').optional(),
  metadata: waMetadataSchema.optional(),
  contacts: z.array(waContactSchema).default([]),
  messages: z.array(z.unknown()).default([]),
  statuses: z.array(z.unknown()).default([]),
});

const waEntrySchema = z.object({
  id: z.string().optional(),
  changes: z
    .array(z.object({ field: z.string().optional(), value: waValueSchema }))
    .default([]),
});

function collectWhatsAppEntry(entry: unknown, out: ParsedMetaWebhook): void {
  const parsedEntry = waEntrySchema.safeParse(entry);

  if (!parsedEntry.success) {
    out.ignored.push({ reason: 'malformed_entry', ids: ids(['object', META_OBJECT_WHATSAPP]) });
    return;
  }

  for (const change of parsedEntry.data.changes) {
    const { value } = change;
    const routingKey = value.metadata?.phone_number_id;

    if (value.messages.length === 0) {
      out.ignored.push({
        reason: value.statuses.length > 0 ? 'status_callback' : 'unsupported_event',
        ids: ids(
          ['phone_number_id', routingKey],
          ['field', change.field],
          ['entry_id', parsedEntry.data.id],
          ['status_count', value.statuses.length > 0 ? String(value.statuses.length) : undefined],
        ),
      });
      continue;
    }

    if (!routingKey) {
      // No phone_number_id means we cannot tell which tenant this belongs to.
      out.ignored.push({
        reason: 'malformed_entry',
        ids: ids(['field', change.field], ['entry_id', parsedEntry.data.id]),
      });
      continue;
    }

    for (const rawMessage of value.messages) {
      const parsedMessage = waInboundMessageSchema.safeParse(rawMessage);

      if (!parsedMessage.success) {
        const shape = waMessageShapeSchema.safeParse(rawMessage);
        out.ignored.push({
          reason: 'unsupported_message_type',
          ids: ids(
            ['phone_number_id', routingKey],
            ['meta_message_id', shape.success ? shape.data.id : undefined],
            ['type', shape.success ? shape.data.type : undefined],
          ),
        });
        continue;
      }

      const message = parsedMessage.data;
      const displayName =
        value.contacts.find((contact) => contact.wa_id === message.from)?.profile?.name ?? '';

      out.events.push(
        inboundMessageEventSchema.parse({
          channel: 'whatsapp',
          routingKey,
          externalId: message.from,
          displayName,
          metaMessageId: message.id,
          // Meta calls a voice note `audio`; the domain calls it `voice`.
          type: message.type === 'audio' ? 'voice' : message.type,
          content:
            message.type === 'text'
              ? message.text.body
              : message.type === 'image'
                ? (message.image.caption ?? '')
                : '',
          sentAt: message.timestamp,
        }),
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Instagram Messaging
// ---------------------------------------------------------------------------

/**
 * Instagram sends milliseconds. 100 000 000 000 ms is 1973, so anything above
 * it is a millisecond timestamp and anything below is the seconds form that
 * shows up in some payloads; reading it the wrong way would put a message
 * decades out and break the customer-service window.
 */
function instagramTimestampToDate(value: number): Date {
  return new Date(value > 1e11 ? value : value * 1000);
}

const igTimestampSchema = z.coerce.number().int().nonnegative().transform(instagramTimestampToDate);

const igAttachmentSchema = z.object({
  type: z.string().min(1),
  payload: z.object({ url: z.string().optional() }).optional(),
});

const igMessageSchema = z.object({
  /** Routing/dedupe key, equivalent to WhatsApp's `wamid.…` id. */
  mid: z.string().min(1),
  text: z.string().optional(),
  /** True when this is *our own* send mirrored back to us. */
  is_echo: z.boolean().optional(),
  attachments: z.array(igAttachmentSchema).optional(),
});

const igMessagingSchema = z.object({
  sender: z.object({ id: z.string().min(1) }),
  recipient: z.object({ id: z.string().min(1) }),
  timestamp: igTimestampSchema.optional(),
  message: igMessageSchema.optional(),
  read: z.unknown().optional(),
  delivery: z.unknown().optional(),
  reaction: z.unknown().optional(),
  postback: z.unknown().optional(),
  referral: z.unknown().optional(),
});

const igEntrySchema = z.object({
  /** The Instagram professional account id: the routing key. */
  id: z.string().min(1),
  time: z.coerce.number().int().nonnegative().optional(),
  messaging: z.array(igMessagingSchema).default([]),
});

/** Instagram puts the kind of message in the attachments, not a `type` field. */
function instagramMessageKind(
  message: z.infer<typeof igMessageSchema>,
): { type: InboundMessageEvent['type']; content: string } | null {
  if (typeof message.text === 'string' && message.text.length > 0) {
    return { type: 'text', content: message.text };
  }

  const attachment = message.attachments?.[0];
  if (!attachment) return null;
  if (attachment.type === 'image') return { type: 'image', content: '' };
  if (attachment.type === 'audio') return { type: 'voice', content: '' };
  return null;
}

function collectInstagramEntry(entry: unknown, out: ParsedMetaWebhook): void {
  const parsedEntry = igEntrySchema.safeParse(entry);

  if (!parsedEntry.success) {
    out.ignored.push({ reason: 'malformed_entry', ids: ids(['object', META_OBJECT_INSTAGRAM]) });
    return;
  }

  const { id: accountId, time } = parsedEntry.data;

  for (const messaging of parsedEntry.data.messaging) {
    // The account that received the message owns the thread. `entry.id` is that
    // account; `recipient.id` says the same thing and is the fallback.
    const routingKey = accountId || messaging.recipient.id;
    const senderId = messaging.sender.id;

    if (messaging.read !== undefined || messaging.delivery !== undefined) {
      out.ignored.push({
        reason: 'read_receipt',
        ids: ids(['instagram_account_id', routingKey], ['sender_id', senderId]),
      });
      continue;
    }

    if (!messaging.message) {
      out.ignored.push({
        reason: 'unsupported_event',
        ids: ids(['instagram_account_id', routingKey], ['sender_id', senderId]),
      });
      continue;
    }

    if (messaging.message.is_echo) {
      out.ignored.push({
        reason: 'unsupported_event',
        ids: ids(
          ['instagram_account_id', routingKey],
          ['meta_message_id', messaging.message.mid],
          ['echo', 'true'],
        ),
      });
      continue;
    }

    const kind = instagramMessageKind(messaging.message);
    if (!kind) {
      out.ignored.push({
        reason: 'unsupported_message_type',
        ids: ids(
          ['instagram_account_id', routingKey],
          ['meta_message_id', messaging.message.mid],
          ['attachment_type', messaging.message.attachments?.[0]?.type],
        ),
      });
      continue;
    }

    const sentAt =
      messaging.timestamp ?? (time !== undefined ? new Date(time * 1000) : new Date());

    out.events.push(
      inboundMessageEventSchema.parse({
        channel: 'instagram',
        routingKey,
        externalId: senderId,
        // Instagram webhooks carry no profile name for the sender.
        displayName: '',
        metaMessageId: messaging.message.mid,
        type: kind.type,
        content: kind.content,
        sentAt,
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/**
 * Normalises a whole webhook body. Never throws: a body that is not a Meta
 * envelope at all comes back as one `malformed_entry` and the caller
 * acknowledges it, because the signature already proved it came from Meta and
 * nothing here is worth a retry.
 */
export function parseMetaWebhook(input: unknown): ParsedMetaWebhook {
  const out: ParsedMetaWebhook = { events: [], ignored: [] };

  const envelope = metaWebhookBodySchema.safeParse(input);
  if (!envelope.success) {
    out.ignored.push({ reason: 'malformed_entry', ids: ids(['object', undefined]) });
    return out;
  }

  for (const entry of envelope.data.entry) {
    switch (envelope.data.object) {
      case META_OBJECT_WHATSAPP:
        collectWhatsAppEntry(entry, out);
        break;
      case META_OBJECT_INSTAGRAM:
        collectInstagramEntry(entry, out);
        break;
      default:
        out.ignored.push({
          reason: 'unsupported_event',
          ids: ids(['object', envelope.data.object]),
        });
    }
  }

  return out;
}
