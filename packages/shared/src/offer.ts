import { z } from 'zod';

/**
 * Lifecycle of a price the agent put on the table.
 *
 *  - `proposed` — the agent has quoted it and the buyer has not answered.
 *  - `accepted` — the buyer took it.
 *  - `rejected` — the buyer refused it, or the owner withdrew it.
 *
 * Mirrors the `CHECK` on `public.offers.status`. PR 2 flagged that the database
 * accepted these three values with no shared counterpart; this closes that gap,
 * so a tool or a handler that writes an offer validates against the same three
 * strings the database will accept.
 */
export const offerStatusSchema = z.enum(['proposed', 'accepted', 'rejected']);
export type OfferStatus = z.infer<typeof offerStatusSchema>;
