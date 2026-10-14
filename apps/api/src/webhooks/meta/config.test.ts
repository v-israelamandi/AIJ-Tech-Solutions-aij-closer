import { describe, expect, it } from 'vitest';
import { loadEnv } from '../../config/env.js';
import { resolveMetaWebhookConfig } from './config.js';
import { createRecordingStore, TEST_APP_SECRET, TEST_VERIFY_TOKEN } from './test-support/index.js';

const store = createRecordingStore();

describe('resolveMetaWebhookConfig', () => {
  it('builds the wiring when the credentials and a store are present', () => {
    const env = loadEnv({ META_APP_SECRET: TEST_APP_SECRET, META_VERIFY_TOKEN: TEST_VERIFY_TOKEN });

    expect(resolveMetaWebhookConfig(env, store)).toEqual({
      appSecret: TEST_APP_SECRET,
      verifyToken: TEST_VERIFY_TOKEN,
      store,
    });
  });

  it('is undefined without the app secret, the verify token or a store', () => {
    const both = loadEnv({ META_APP_SECRET: TEST_APP_SECRET, META_VERIFY_TOKEN: TEST_VERIFY_TOKEN });
    const secretOnly = loadEnv({ META_APP_SECRET: TEST_APP_SECRET });
    const tokenOnly = loadEnv({ META_VERIFY_TOKEN: TEST_VERIFY_TOKEN });

    expect(resolveMetaWebhookConfig(both, null)).toBeUndefined();
    expect(resolveMetaWebhookConfig(secretOnly, store)).toBeUndefined();
    expect(resolveMetaWebhookConfig(tokenOnly, store)).toBeUndefined();
    expect(resolveMetaWebhookConfig(loadEnv({}), store)).toBeUndefined();
  });
});
