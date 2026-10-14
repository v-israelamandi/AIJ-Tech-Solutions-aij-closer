import { describe, expect, it } from 'vitest';
import { parseMetaWebhook } from './payload.js';
import { loadMetaFixtureJson } from './test-support/index.js';

/** Parses a fixture and fails loudly if anything was ignored unexpectedly. */
function parseFixture(name: Parameters<typeof loadMetaFixtureJson>[0]) {
  const parsed = parseMetaWebhook(loadMetaFixtureJson(name));
  expect(parsed.ignored, `unexpected ignored events in ${name}: ${JSON.stringify(parsed.ignored)}`).toEqual([]);
  return parsed;
}

describe('parseMetaWebhook — WhatsApp', () => {
  it('turns a text message into one inbound event, with the profile name', () => {
    const parsed = parseFixture('whatsapp-text');

    expect(parsed.events).toHaveLength(1);
    expect(parsed.events[0]).toMatchObject({
      channel: 'whatsapp',
      routingKey: '109876543210987',
      externalId: '2348031234567',
      displayName: 'Zainab Adeyemi',
      metaMessageId: 'wamid.HBgNMjM0ODAzMTIzNDU2NxUCABIYFjI5NzY1MjQzMTA3NDY0MTQ2ODk2MzcA',
      type: 'text',
      content: 'Good afternoon. How much is the Zainab Adire two-piece set?',
    });
    // WhatsApp sends Unix seconds; 1792058400 is 2026-10-15T10:00:00Z.
    expect(parsed.events[0]?.sentAt.toISOString()).toBe('2026-10-15T10:00:00.000Z');
  });

  it('calls an audio message a voice note, with no content yet', () => {
    const parsed = parseFixture('whatsapp-voice-note');

    expect(parsed.events).toHaveLength(1);
    expect(parsed.events[0]).toMatchObject({
      type: 'voice',
      content: '',
      externalId: '2347012345678',
      displayName: 'Chidinma Okonkwo',
      metaMessageId: 'wamid.HBgNMjM0NzAxMjM0NTY3OBUCABIYFjI5NzY1MjQ0NTE4ODgyNjA2OTgxMjkA',
    });
  });

  it('stores an image as an image and keeps the caption as content', () => {
    const parsed = parseFixture('whatsapp-image-with-caption');

    expect(parsed.events).toHaveLength(1);
    expect(parsed.events[0]).toMatchObject({
      type: 'image',
      content: 'I saw this on your page. Does it come in a bigger size?',
      externalId: '2348099887766',
    });
  });

  it('keeps the routing key when no tenant owns it — routing is the database\'s job', () => {
    const parsed = parseFixture('whatsapp-unknown-phone-number');
    expect(parsed.events[0]?.routingKey).toBe('999999999999999');
  });
});

describe('parseMetaWebhook — WhatsApp events we do not act on', () => {
  it('ignores delivery and read status callbacks', () => {
    const parsed = parseMetaWebhook(loadMetaFixtureJson('whatsapp-status-callback'));

    expect(parsed.events).toEqual([]);
    expect(parsed.ignored).toHaveLength(1);
    expect(parsed.ignored[0]).toMatchObject({ reason: 'status_callback' });
    expect(parsed.ignored[0]?.ids.phone_number_id).toBe('109876543210987');
  });

  it('ignores a message type we do not handle, naming the type and nothing else', () => {
    const parsed = parseMetaWebhook(loadMetaFixtureJson('whatsapp-other-message-type'));

    expect(parsed.events).toEqual([]);
    expect(parsed.ignored).toHaveLength(1);
    expect(parsed.ignored[0]).toMatchObject({ reason: 'unsupported_message_type' });
    expect(parsed.ignored[0]?.ids).toMatchObject({
      phone_number_id: '109876543210987',
      type: 'location',
      meta_message_id: 'wamid.HBgNMjM0ODA1NTUxMjM0NRUCABIYFjI5NzY1MjQ2NTA1OTI4Mzc0MTA2NTEA',
    });
  });

  it('ignores a change that is not a message at all', () => {
    const parsed = parseMetaWebhook(loadMetaFixtureJson('whatsapp-unknown-event'));

    expect(parsed.events).toEqual([]);
    expect(parsed.ignored).toHaveLength(1);
    expect(parsed.ignored[0]?.reason).toBe('unsupported_event');
  });

  it('ignores a message whose change carries no phone_number_id', () => {
    const parsed = parseMetaWebhook({
      object: 'whatsapp_business_account',
      entry: [
        {
          id: '102290129340398',
          changes: [
            {
              field: 'messages',
              value: {
                messaging_product: 'whatsapp',
                contacts: [{ wa_id: '2348031234567', profile: { name: 'Zainab Adeyemi' } }],
                messages: [{ from: '2348031234567', id: 'wamid.NO-METADATA', timestamp: '1792058400', type: 'text', text: { body: 'hi' } }],
              },
            },
          ],
        },
      ],
    });

    expect(parsed.events).toEqual([]);
    expect(parsed.ignored[0]?.reason).toBe('malformed_entry');
  });

  it('handles several messages in one change', () => {
    const parsed = parseMetaWebhook({
      object: 'whatsapp_business_account',
      entry: [
        {
          id: '102290129340398',
          changes: [
            {
              field: 'messages',
              value: {
                messaging_product: 'whatsapp',
                metadata: { phone_number_id: '109876543210987' },
                contacts: [{ wa_id: '2348031234567', profile: { name: 'Zainab Adeyemi' } }],
                messages: [
                  { from: '2348031234567', id: 'wamid.ONE', timestamp: '1792058400', type: 'text', text: { body: 'first' } },
                  { from: '2348031234567', id: 'wamid.TWO', timestamp: '1792058401', type: 'text', text: { body: 'second' } },
                ],
              },
            },
          ],
        },
      ],
    });

    expect(parsed.events.map((event) => event.content)).toEqual(['first', 'second']);
  });
});

describe('parseMetaWebhook — Instagram', () => {
  it('turns a DM into one inbound event, routed by the account that received it', () => {
    const parsed = parseFixture('instagram-text');

    expect(parsed.events).toHaveLength(1);
    expect(parsed.events[0]).toMatchObject({
      channel: 'instagram',
      routingKey: '17841400000000001',
      externalId: '7012384591267503',
      displayName: '',
      metaMessageId: 'aWdfZAG06MTpJR01lc3NhZ2VJRDoxMjM0NTY3ODkwMTIzNDU2Nzg5MA==',
      type: 'text',
      content: 'Hi! Do you deliver to Lekki Phase 1?',
    });
    // Instagram sends milliseconds.
    expect(parsed.events[0]?.sentAt.toISOString()).toBe('2026-10-15T10:05:00.123Z');
  });

  it('stores an image attachment as an image', () => {
    const parsed = parseFixture('instagram-image-attachment');

    expect(parsed.events[0]).toMatchObject({ type: 'image', content: '' });
  });

  it('reads a seconds-scale timestamp as seconds, not milliseconds', () => {
    const parsed = parseMetaWebhook({
      object: 'instagram',
      entry: [
        {
          id: '17841400000000001',
          time: 1792058700,
          messaging: [
            {
              sender: { id: '7012384591267503' },
              recipient: { id: '17841400000000001' },
              timestamp: 1792058700,
              message: { mid: 'mid.SECONDS', text: 'no timestamp units, please' },
            },
          ],
        },
      ],
    });

    expect(parsed.events[0]?.sentAt.toISOString()).toBe('2026-10-15T10:05:00.000Z');
  });

  it('falls back to the entry time when an event carries no timestamp', () => {
    const parsed = parseMetaWebhook({
      object: 'instagram',
      entry: [
        {
          id: '17841400000000001',
          time: 1792058700,
          messaging: [
            {
              sender: { id: '7012384591267503' },
              recipient: { id: '17841400000000001' },
              message: { mid: 'mid.NO-TIMESTAMP', text: 'hello' },
            },
          ],
        },
      ],
    });

    expect(parsed.events[0]?.sentAt.toISOString()).toBe('2026-10-15T10:05:00.000Z');
  });

  it('ignores read receipts', () => {
    const parsed = parseMetaWebhook(loadMetaFixtureJson('instagram-read-callback'));

    expect(parsed.events).toEqual([]);
    expect(parsed.ignored).toHaveLength(1);
    expect(parsed.ignored[0]).toMatchObject({ reason: 'read_receipt' });
    expect(parsed.ignored[0]?.ids.instagram_account_id).toBe('17841400000000001');
  });

  it('ignores our own message echoed back to us', () => {
    const parsed = parseMetaWebhook(loadMetaFixtureJson('instagram-echo'));

    expect(parsed.events).toEqual([]);
    expect(parsed.ignored).toHaveLength(1);
    expect(parsed.ignored[0]).toMatchObject({ reason: 'unsupported_event' });
    expect(parsed.ignored[0]?.ids.echo).toBe('true');
  });

  it('ignores an attachment type we do not handle', () => {
    const parsed = parseMetaWebhook({
      object: 'instagram',
      entry: [
        {
          id: '17841400000000001',
          messaging: [
            {
              sender: { id: '7012384591267503' },
              recipient: { id: '17841400000000001' },
              message: { mid: 'mid.VIDEO', attachments: [{ type: 'video', payload: { url: 'https://example.invalid/v.mp4' } }] },
            },
          ],
        },
      ],
    });

    expect(parsed.events).toEqual([]);
    expect(parsed.ignored[0]?.reason).toBe('unsupported_message_type');
    expect(parsed.ignored[0]?.ids.attachment_type).toBe('video');
  });
});

describe('parseMetaWebhook — malformed and unknown envelopes', () => {
  it('turns anything that is not a Meta envelope into one ignored event', () => {
    for (const input of [null, undefined, [], 'a string', 42, {}, { entry: [] }]) {
      const parsed = parseMetaWebhook(input);
      expect(parsed.events, JSON.stringify(input) ?? 'undefined').toEqual([]);
      expect(parsed.ignored, JSON.stringify(input) ?? 'undefined').toHaveLength(1);
    }
  });

  it('accepts an envelope with no entries as nothing to do', () => {
    const parsed = parseMetaWebhook({ object: 'whatsapp_business_account', entry: [] });
    const parsedNoEntryKey = parseMetaWebhook({ object: 'whatsapp_business_account' });

    expect(parsed).toEqual({ events: [], ignored: [] });
    expect(parsedNoEntryKey).toEqual({ events: [], ignored: [] });
  });

  it('ignores an object for a product we do not receive (e.g. a Facebook Page)', () => {
    const parsed = parseMetaWebhook({ object: 'page', entry: [{ id: '1', messaging: [] }] });

    expect(parsed.events).toEqual([]);
    expect(parsed.ignored[0]).toMatchObject({ reason: 'unsupported_event' });
    expect(parsed.ignored[0]?.ids.object).toBe('page');
  });

  it('ignores a malformed entry without losing the well-formed ones', () => {
    const parsed = parseMetaWebhook({
      object: 'whatsapp_business_account',
      entry: [
        null,
        { id: '102290129340398', changes: 'not-an-array' },
        ...((loadMetaFixtureJson('whatsapp-text') as { entry: unknown[] }).entry),
      ],
    });

    expect(parsed.events).toHaveLength(1);
    expect(parsed.ignored.map((ignored) => ignored.reason)).toEqual([
      'malformed_entry',
      'malformed_entry',
    ]);
  });

  it('never puts message content in an ignored event', () => {
    const parsed = parseMetaWebhook(loadMetaFixtureJson('whatsapp-other-message-type'));
    const serialised = JSON.stringify(parsed.ignored);

    expect(serialised).not.toContain('Yaba');
    expect(serialised).not.toContain('6.5001345');
  });
});
