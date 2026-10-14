import { z } from 'zod';

/**
 * Payment state of an order, as tracked against its Paystack reference.
 * Money always settles in the vendor's own Paystack subaccount.
 */
export const orderPaymentStatusSchema = z.enum(['pending', 'paid', 'failed', 'refunded']);

export type OrderPaymentStatus = z.infer<typeof orderPaymentStatusSchema>;
