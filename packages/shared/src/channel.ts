import { z } from 'zod';

/** Where a tenant's conversations arrive from. One Meta app serves both. */
export const channelTypeSchema = z.enum(['whatsapp', 'instagram']);

export type ChannelType = z.infer<typeof channelTypeSchema>;
