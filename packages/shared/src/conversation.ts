import { z } from 'zod';

/**
 * Conversation lifecycle. `bot` = the agent is replying, `human` = an owner has
 * taken over (the agent stops replying), `closed` = done.
 */
export const conversationStatusSchema = z.enum(['bot', 'human', 'closed']);

export type ConversationStatus = z.infer<typeof conversationStatusSchema>;
