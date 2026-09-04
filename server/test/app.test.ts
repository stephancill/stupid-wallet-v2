import { describe, expect, it, beforeAll } from 'vitest';
import { createBackend, type BackendDeps } from '../src/app';
import { createTestDb } from './helpers';
import { createInstallation } from '../src/domain/installations';
import {
  enrollAddresses,
  setChainActivated,
  replaceChainsSnapshot,
  syncUpstream,
} from '../src/domain/registrations';
import type { Database } from '../src/database';

const NOW = () => Date.now();
const APP_KEY = Buffer.from(Array(32).fill(0x55)).toString('base64url');

const makeDeps = (db: Database, deliveries: Array<Record<string, unknown>>): BackendDeps => ({
  db,
  appDataKey: APP_KEY,
  environment: 'test',
  webhookSecret: 'test-secret',
  upstream: {
    getChain: async () => ({ supported: true }),
    createSubscription: async () => ({ subscriptionId: 'sub_1' }),
    deleteSubscription: async () => undefined,
  },
  now: NOW,
  onWebhookFanout: async (d) => {
    deliveries.push(...d);
  },
});

const hmac = async (secret: string, id: string, timestamp: string, exactBody: Uint8Array) => {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const prefix = new TextEncoder().encode(`${id}.${timestamp}.`);
  const combined = new Uint8Array(prefix.length + exactBody.length);
  combined.set(prefix, 0);
  combined.set(exactBody, prefix.length);
  const sig = await crypto.subtle.sign('HMAC', key, combined);
  return Buffer.from(sig).toString('base64url');
};

describe('webhook HTTP route', () => {
  let db: Database;
  let deliveries: Array<Record<string, unknown>>;

  beforeAll(async () => {
    db = createTestDb();
    const installationId = await createInstallation(
      db,
      { appDataKey: APP_KEY },
      {
        publicKey: 'pk',
        apnsToken: 'aaaaaaaaaaaaaaaa',
        apnsEnvironment: 'production',
        notificationAuthorization: 'authorized',
        notificationAlertSetting: 'enabled',
      },
    );
    await replaceChainsSnapshot(db, installationId, 1, ['1'], NOW());
    await setChainActivated(db, '1', NOW());
    await enrollAddresses(
      db,
      installationId,
      ['0x1111111111111111111111111111111111111111'],
      NOW(),
    );
    await syncUpstream(db, NOW());
  });

  const post = async (body: Record<string, unknown>, webhookId: string) => {
    deliveries = [];
    const app = createBackend(makeDeps(db, deliveries));
    const bodyText = new TextEncoder().encode(JSON.stringify(body));
    const timestamp = String(NOW());
    const sig = await hmac('test-secret', webhookId, timestamp, bodyText);
    return app.request('/internal/v1/wallet-activity', {
      method: 'POST',
      headers: {
        'x-wallet-hook-id': webhookId,
        'x-wallet-hook-timestamp': timestamp,
        'x-wallet-hook-signature': `v1,${sig}`,
        'content-type': 'application/json',
      },
      body: bodyText,
    });
  };

  it('accepts a signed delivery and enqueues fanout', async () => {
    const res = await post(
      {
        eventId: 'obs-1',
        eventType: 'activity.observed',
        chainId: '1',
        address: '0x1111111111111111111111111111111111111111',
        observationId: 'obs-1',
      },
      'hook-1',
    );
    expect(res.status).toBe(202);
    const json = (await res.json()) as { duplicate: boolean };
    expect(json.duplicate).toBe(false);
    expect(deliveries.length).toBe(1);
  });

  it('rejects a bad HMAC', async () => {
    const app = createBackend(makeDeps(db, deliveries));
    const bodyText = new TextEncoder().encode(JSON.stringify({}));
    const res = await app.request('/internal/v1/wallet-activity', {
      method: 'POST',
      headers: {
        'x-wallet-hook-id': 'hook-2',
        'x-wallet-hook-timestamp': String(NOW()),
        'x-wallet-hook-signature': 'v1,bogus',
        'content-type': 'application/json',
      },
      body: bodyText,
    });
    // eslint-disable-next-line no-console
    console.log('BAD HMAC BODY:', await res.text());
    expect(res.status).toBe(401);
  });
});
