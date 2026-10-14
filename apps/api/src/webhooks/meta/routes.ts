import type { FastifyPluginAsync, FastifyPluginOptions } from 'fastify';
import { z } from 'zod';
import type { InboundMessageStore } from '../../db/inbound-messages.js';
import { parseMetaWebhook } from './payload.js';
import { safeEqualStrings, verifyMetaSignature } from './signature.js';

/**
 * `GET /webhooks/meta` and `POST /webhooks/meta`.
 *
 * One route family for both channels: the brief has WhatsApp Cloud API and
 * Instagram Messaging behind the same Meta app, so they share a callback URL,
 * a verify token and an app secret, and the body's `object` field says which
 * product a delivery came from.
 */

export interface MetaWebhookConfig extends FastifyPluginOptions {
  /** Meta app secret: the key for `X-Hub-Signature-256`. */
  appSecret: string;
  /** The string we paste into the Meta app and Meta echoes back to prove the endpoint is ours. */
  verifyToken: string;
  /** Where verified messages go. Abstract so the routes can be tested without a database. */
  store: InboundMessageStore;
}

/**
 * `GET` query parameters. The names contain literal dots because that is the
 * shape Meta sends (`?hub.mode=subscribe&…`), so they are read as the flat keys
 * they are rather than drilled into as nested objects.
 */
export const metaVerificationQuerySchema = z.object({
  'hub.mode': z.string().min(1).optional(),
  'hub.verify_token': z.string().min(1).optional(),
  'hub.challenge': z.string().min(1).optional(),
});

export type MetaVerificationQuery = z.infer<typeof metaVerificationQuerySchema>;

/** The `POST` body's response contract. */
export const metaWebhookAckSchema = z.object({
  status: z.literal('ok'),
  /** Messages persisted by this delivery. */
  stored: z.number().int().nonnegative(),
  /** Messages Meta had already delivered: recognised, deliberately not stored twice. */
  duplicates: z.number().int().nonnegative(),
  /** No active channel matched the routing key, so no tenant owns them. */
  unroutable: z.number().int().nonnegative(),
  /** Status callbacks, echoes and event types we do not act on. */
  ignored: z.number().int().nonnegative(),
});

export type MetaWebhookAck = z.infer<typeof metaWebhookAckSchema>;

export const metaWebhookRoutes: FastifyPluginAsync<MetaWebhookConfig> = async (app, config) => {
  /**
   * Keep the request body as the bytes Meta sent.
   *
   * `X-Hub-Signature-256` is an HMAC over those exact bytes, so the signature
   * has to be checked before anything parses the body — and the parse must
   * happen from the same buffer. Registering this inside the plugin scopes it to
   * these two routes: every other route keeps Fastify's ordinary JSON parser.
   * Verifying a re-serialised object instead would be the classic version of
   * this bug, where a body altered in flight still passes.
   */
  app.addContentTypeParser('application/json', { parseAs: 'buffer' }, (_request, body, done) => {
    done(null, body);
  });

  app.get('/webhooks/meta', async (request, reply) => {
    const query = metaVerificationQuerySchema.safeParse(request.query);
    const data: MetaVerificationQuery = query.success ? query.data : {};

    // An absent token is compared as the empty string so the rejection path is
    // the same shape whether the parameter is wrong or missing entirely.
    const providedToken = data['hub.verify_token'] ?? '';

    if (
      data['hub.mode'] !== 'subscribe' ||
      data['hub.challenge'] === undefined ||
      !safeEqualStrings(providedToken, config.verifyToken)
    ) {
      request.log.warn(
        { mode: data['hub.mode'] },
        'meta webhook verification rejected: hub.mode/hub.verify_token did not match',
      );
      return reply.code(403).send({ error: 'verification_failed' });
    }

    request.log.info('meta webhook verified');
    // Meta compares this byte for byte; nothing else may be in the body.
    return reply.type('text/plain; charset=utf-8').send(data['hub.challenge']);
  });

  app.post('/webhooks/meta', async (request, reply) => {
    const rawBody = request.body;

    if (!Buffer.isBuffer(rawBody) || rawBody.length === 0) {
      request.log.warn('meta webhook rejected: request body was not captured as bytes');
      return reply.code(401).send({ error: 'invalid_signature' });
    }

    const header = request.headers['x-hub-signature-256'];
    // A repeated header is not something Meta does; treat it as unverifiable
    // rather than guessing which value to check.
    const signature = typeof header === 'string' ? header : undefined;

    if (!verifyMetaSignature(rawBody, signature, config.appSecret)) {
      // 401 and nothing else: no parse, no write, no side effect of any kind.
      request.log.warn('meta webhook rejected: X-Hub-Signature-256 did not match the body');
      return reply.code(401).send({ error: 'invalid_signature' });
    }

    let body: unknown;
    try {
      body = JSON.parse(rawBody.toString('utf8'));
    } catch {
      // Only reachable from something signed with our app secret, so this is a
      // genuine bad payload rather than an attack.
      request.log.warn('meta webhook rejected: body is not valid JSON');
      return reply.code(400).send({ error: 'invalid_json' });
    }

    const parsed = parseMetaWebhook(body);

    for (const ignored of parsed.ignored) {
      request.log.debug(
        { reason: ignored.reason, ...ignored.ids },
        'meta webhook event ignored, nothing written',
      );
    }

    const ack: MetaWebhookAck = {
      status: 'ok',
      stored: 0,
      duplicates: 0,
      unroutable: 0,
      ignored: parsed.ignored.length,
    };

    for (const event of parsed.events) {
      // Anything thrown here is a genuine failure (the database is unreachable,
      // say), so it propagates and Fastify answers 5xx. Meta retries, and the
      // dedupe below makes those retries safe.
      const outcome = await config.store.store(event);

      switch (outcome.outcome) {
        case 'stored':
          ack.stored += 1;
          request.log.info(
            {
              tenant_id: outcome.tenantId,
              conversation_id: outcome.conversationId,
              meta_message_id: event.metaMessageId,
              type: event.type,
            },
            'inbound message stored',
          );
          break;
        case 'duplicate':
          ack.duplicates += 1;
          request.log.info(
            { conversation_id: outcome.conversationId, meta_message_id: event.metaMessageId },
            'duplicate webhook delivery ignored',
          );
          break;
        case 'unroutable':
          ack.unroutable += 1;
          request.log.warn(
            {
              channel: outcome.channel,
              routing_key: outcome.routingKey,
              meta_message_id: event.metaMessageId,
            },
            'inbound message cannot be routed to a tenant, nothing written',
          );
          request.log.debug(
            { external_id: event.externalId },
            'unroutable inbound message sender',
          );
          break;
      }
    }

    return reply.code(200).send(ack);
  });
};
