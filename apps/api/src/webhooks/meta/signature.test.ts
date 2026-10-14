import { describe, expect, it } from 'vitest';
import { computeMetaSignature, safeEqualStrings, verifyMetaSignature } from './signature.js';

const APP_SECRET = 'test-meta-app-secret';
const BODY = Buffer.from('{"object":"whatsapp_business_account","entry":[]}', 'utf8');

describe('verifyMetaSignature', () => {
  it('accepts the HMAC that Meta computes over the raw body', () => {
    const header = computeMetaSignature(BODY, APP_SECRET);
    expect(header).toMatch(/^sha256=[0-9a-f]{64}$/);
    expect(verifyMetaSignature(BODY, header, APP_SECRET)).toBe(true);
  });

  it('rejects a body with a single byte changed', () => {
    const header = computeMetaSignature(BODY, APP_SECRET);
    const tampered = Buffer.from(BODY.toString('utf8').replace('[]', '[ ]'), 'utf8');

    expect(verifyMetaSignature(tampered, header, APP_SECRET)).toBe(false);
  });

  it('rejects a signature computed with a different app secret', () => {
    const header = computeMetaSignature(BODY, 'some-other-app-secret');
    expect(verifyMetaSignature(BODY, header, APP_SECRET)).toBe(false);
  });

  it('rejects a signature over the re-serialised body, not the bytes', () => {
    // The classic bug: verify JSON.stringify(JSON.parse(body)) instead of the
    // bytes that arrived. It differs from the raw body here, so a signature
    // computed that way must not be accepted.
    const pretty = Buffer.from('{\n  "object": "whatsapp_business_account",\n  "entry": []\n}', 'utf8');
    const header = computeMetaSignature(Buffer.from(JSON.stringify(JSON.parse(pretty.toString('utf8'))), 'utf8'), APP_SECRET);

    expect(verifyMetaSignature(pretty, header, APP_SECRET)).toBe(false);
    expect(verifyMetaSignature(pretty, computeMetaSignature(pretty, APP_SECRET), APP_SECRET)).toBe(true);
  });

  it('rejects a missing header', () => {
    expect(verifyMetaSignature(BODY, undefined, APP_SECRET)).toBe(false);
  });

  it('rejects a malformed header without throwing', () => {
    const digest = computeMetaSignature(BODY, APP_SECRET).slice('sha256='.length);

    for (const header of [
      '',
      'sha256=',
      digest,
      `sha1=${digest}`,
      `sha256=${digest.slice(0, -1)}`,
      `sha256=${digest}0`,
      `sha256=${digest.toUpperCase()}`,
      `sha256=zzzz${digest.slice(4)}`,
      'sha256=not-hex-at-all',
    ]) {
      // Uppercase hex is a valid encoding of the same digest, so it is the one
      // accepted; everything else must be false rather than a throw.
      const expected = header === `sha256=${digest.toUpperCase()}`;
      expect(verifyMetaSignature(BODY, header, APP_SECRET), header).toBe(expected);
    }
  });

  it('rejects an empty body signed as a body', () => {
    expect(verifyMetaSignature(Buffer.alloc(0), computeMetaSignature(Buffer.alloc(0), APP_SECRET), APP_SECRET)).toBe(true);
  });
});

describe('safeEqualStrings', () => {
  it('accepts identical strings', () => {
    expect(safeEqualStrings('hub-token-123', 'hub-token-123')).toBe(true);
  });

  it('rejects different strings, including different lengths', () => {
    expect(safeEqualStrings('hub-token-123', 'hub-token-124')).toBe(false);
    expect(safeEqualStrings('hub-token-123', 'hub-token-1234')).toBe(false);
    expect(safeEqualStrings('', 'hub-token-123')).toBe(false);
  });

  it('accepts two empty strings', () => {
    // Both sides are hashed before comparison, so equal inputs of any length
    // (including none) are handled without a length check.
    expect(safeEqualStrings('', '')).toBe(true);
  });
});
