import { readFileSync } from 'node:fs';
import type { InboundMessageEvent, InboundMessageOutcome, InboundMessageStore } from '../../../db/inbound-messages.js';
import { computeMetaSignature } from '../signature.js';

/**
 * Test support for the webhook layer: the recorded payloads as bytes, request
 * signing, and an in-memory `InboundMessageStore`.
 *
 * Excluded from the build (`tsconfig.build.json`) — this is test-only code and
 * the fixture paths only resolve from `src/`.
 */

/** The payloads under `../fixtures/`, by name. */
export type MetaFixture =
  | 'whatsapp-text'
  | 'whatsapp-voice-note'
  | 'whatsapp-image-with-caption'
  | 'whatsapp-status-callback'
  | 'whatsapp-other-message-type'
  | 'whatsapp-unknown-event'
  | 'whatsapp-unknown-phone-number'
  | 'instagram-text'
  | 'instagram-image-attachment'
  | 'instagram-read-callback'
  | 'instagram-echo';

const FIXTURES_URL = new URL('../fixtures/', import.meta.url);

/** One recorded payload, exactly as it is on disk. */
export function loadMetaFixture(name: MetaFixture): Buffer {
  return readFileSync(new URL(`${name}.json`, FIXTURES_URL));
}

/** The same payload, parsed. */
export function loadMetaFixtureJson(name: MetaFixture): unknown {
  return JSON.parse(loadMetaFixture(name).toString('utf8'));
}

/** A signature header over these exact bytes: what Meta would send. */
export function metaSignatureHeader(rawBody: Buffer, appSecret: string): string {
  return computeMetaSignature(rawBody, appSecret);
}

// ---------------------------------------------------------------------------
// A store that records instead of writing
// ---------------------------------------------------------------------------

/** A plausible stored outcome. */
export function storedOutcome(overrides: Partial<{
  tenantId: string;
  contactId: string;
  conversationId: string;
  messageId: string;
  windowExpiresAt: Date;
}> = {}): InboundMessageOutcome {
  return {
    outcome: 'stored',
    tenantId: '5eed0000-0000-4000-8000-000000000001',
    contactId: '5eed0000-0000-4000-8000-000000000301',
    conversationId: '5eed0000-0000-4000-8000-000000000401',
    messageId: '5eed0000-0000-4000-8000-000000000501',
    windowExpiresAt: new Date('2026-10-15T10:00:00.000Z'),
    ...overrides,
  };
}

export interface RecordingStore extends InboundMessageStore {
  /** Every event handed to the store, in order. Empty means no side effect. */
  readonly events: InboundMessageEvent[];
}

/**
 * An `InboundMessageStore` that writes nothing and remembers everything, so a
 * test can assert both what the route did with a payload and — by inspecting
 * `events` — that a rejected request never even reached the store.
 */
export function createRecordingStore(
  respond: (event: InboundMessageEvent, index: number) => InboundMessageOutcome = () =>
    storedOutcome(),
): RecordingStore {
  const events: InboundMessageEvent[] = [];

  return {
    events,
    async store(event: InboundMessageEvent): Promise<InboundMessageOutcome> {
      events.push(event);
      return respond(event, events.length - 1);
    },
  };
}

/** A store whose database is down: every call throws. */
export function createFailingStore(error: Error = new Error('database is unreachable')): InboundMessageStore {
  return {
    async store(): Promise<InboundMessageOutcome> {
      throw error;
    },
  };
}

// Placeholders. Never a real Meta secret — see `.env.example`.
export const TEST_APP_SECRET = 'test-meta-app-secret';
export const TEST_VERIFY_TOKEN = 'test-meta-verify-token';
