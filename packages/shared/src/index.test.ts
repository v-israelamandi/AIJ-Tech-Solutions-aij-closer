import { describe, expect, it } from 'vitest';
import {
  channelTypeSchema,
  conversationStatusSchema,
  messageDirectionSchema,
  messageTypeSchema,
  orderPaymentStatusSchema,
  type ChannelType,
  type ConversationStatus,
  type MessageDirection,
  type MessageType,
  type OrderPaymentStatus,
} from './index.js';

describe('@aij/shared domain enums', () => {
  describe('conversationStatusSchema', () => {
    it('accepts bot, human and closed', () => {
      for (const status of ['bot', 'human', 'closed'] as const) {
        expect(conversationStatusSchema.parse(status)).toBe(status);
      }
    });

    it('rejects anything else', () => {
      expect(conversationStatusSchema.safeParse('paused').success).toBe(false);
      expect(conversationStatusSchema.safeParse(undefined).success).toBe(false);
      expect(conversationStatusSchema.safeParse('BOT').success).toBe(false);
    });
  });

  describe('messageDirectionSchema', () => {
    it('accepts inbound and outbound', () => {
      expect(messageDirectionSchema.parse('inbound')).toBe('inbound');
      expect(messageDirectionSchema.parse('outbound')).toBe('outbound');
    });

    it('rejects anything else', () => {
      expect(messageDirectionSchema.safeParse('incoming').success).toBe(false);
      expect(messageDirectionSchema.safeParse(null).success).toBe(false);
    });
  });

  describe('messageTypeSchema', () => {
    it('accepts text, voice and image', () => {
      for (const kind of ['text', 'voice', 'image'] as const) {
        expect(messageTypeSchema.parse(kind)).toBe(kind);
      }
    });

    it('rejects anything else', () => {
      expect(messageTypeSchema.safeParse('video').success).toBe(false);
      expect(messageTypeSchema.safeParse('').success).toBe(false);
    });
  });

  describe('channelTypeSchema', () => {
    it('accepts whatsapp and instagram', () => {
      expect(channelTypeSchema.parse('whatsapp')).toBe('whatsapp');
      expect(channelTypeSchema.parse('instagram')).toBe('instagram');
    });

    it('rejects anything else', () => {
      expect(channelTypeSchema.safeParse('telegram').success).toBe(false);
      expect(channelTypeSchema.safeParse(42).success).toBe(false);
    });
  });

  describe('orderPaymentStatusSchema', () => {
    it('accepts pending, paid, failed and refunded', () => {
      for (const status of ['pending', 'paid', 'failed', 'refunded'] as const) {
        expect(orderPaymentStatusSchema.parse(status)).toBe(status);
      }
    });

    it('rejects anything else, including Paystack-internal states', () => {
      expect(orderPaymentStatusSchema.safeParse('abandoned').success).toBe(false);
      expect(orderPaymentStatusSchema.safeParse('processing').success).toBe(false);
    });
  });

  it('exports the inferred types from the barrel', () => {
    const status: ConversationStatus = 'human';
    const direction: MessageDirection = 'inbound';
    const messageKind: MessageType = 'voice';
    const channel: ChannelType = 'whatsapp';
    const payment: OrderPaymentStatus = 'paid';

    expect([status, direction, messageKind, channel, payment]).toEqual([
      'human',
      'inbound',
      'voice',
      'whatsapp',
      'paid',
    ]);
  });
});
