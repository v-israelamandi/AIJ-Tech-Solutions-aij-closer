import { createHash, createHmac, timingSafeEqual } from 'node:crypto';

/**
 * Meta webhook authenticity.
 *
 * Two different checks, both required by the brief's "Meta rules":
 *
 *  - `GET /webhooks/meta` — Meta proves it can read our endpoint by echoing a
 *    shared `hub.verify_token` back. Compared in constant time.
 *  - `POST /webhooks/meta` — every delivery carries `X-Hub-Signature-256`, an
 *    HMAC-SHA256 of the **exact bytes of the request body**, keyed with the Meta
 *    app secret. Computed over the raw bytes and never over a re-serialised
 *    object: `JSON.stringify(JSON.parse(body))` is not the body, and verifying
 *    against it would accept a payload an attacker had altered.
 */

/** Meta's header prefix: `sha256=<64 lowercase hex chars>`. */
const SIGNATURE_PREFIX = 'sha256=';
const HEX_DIGEST = /^[0-9a-f]{64}$/i;

/** `sha256=<hmac>` for a body, as Meta computes it. Used by the tests. */
export function computeMetaSignature(rawBody: Buffer, appSecret: string): string {
  return `${SIGNATURE_PREFIX}${createHmac('sha256', appSecret).update(rawBody).digest('hex')}`;
}

/**
 * True when `header` is Meta's HMAC-SHA256 of exactly `rawBody`.
 *
 * A missing, malformed or mismatched signature is false — never a throw, since
 * the caller's only reasonable response is 401 either way.
 */
export function verifyMetaSignature(
  rawBody: Buffer,
  header: string | undefined,
  appSecret: string,
): boolean {
  if (typeof header !== 'string' || !header.startsWith(SIGNATURE_PREFIX)) return false;

  const provided = header.slice(SIGNATURE_PREFIX.length);
  if (!HEX_DIGEST.test(provided)) return false;

  const expected = createHmac('sha256', appSecret).update(rawBody).digest();
  const actual = Buffer.from(provided, 'hex');
  if (actual.length !== expected.length) return false;

  return timingSafeEqual(expected, actual);
}

/**
 * Constant-time string comparison.
 *
 * Both sides are hashed first so the comparison always runs over 32 bytes: a
 * raw `timingSafeEqual` throws on different lengths, and any length check in
 * front of it leaks the length of the expected value. The digest of a wrong
 * token is still a wrong token.
 */
export function safeEqualStrings(a: string, b: string): boolean {
  const digestA = createHash('sha256').update(a, 'utf8').digest();
  const digestB = createHash('sha256').update(b, 'utf8').digest();
  return timingSafeEqual(digestA, digestB);
}
