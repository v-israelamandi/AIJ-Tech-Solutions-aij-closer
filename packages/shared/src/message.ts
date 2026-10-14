import { z } from 'zod';

/** Who sent the message: the buyer, or the tenant's side (agent or human). */
export const messageDirectionSchema = z.enum(['inbound', 'outbound']);

export type MessageDirection = z.infer<typeof messageDirectionSchema>;

/** What the message is: typed text, a voice note, or an image/screenshot. */
export const messageTypeSchema = z.enum(['text', 'voice', 'image']);

export type MessageType = z.infer<typeof messageTypeSchema>;
