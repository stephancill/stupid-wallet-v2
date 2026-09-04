import { describe, expect, it, beforeAll } from 'vitest';
import { createBackend, type BackendDeps } from '../src/app';
import { createTestDb, generateTestKeypair } from './helpers';
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
  fetch: async (input) => {
    const key = input.split('/').at(-1);
    if (key === 'ethereum:0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee') {
      return Response.json({
        coins: { [key]: { symbol: 'ETH', decimals: 18, price: 2_500 } },
      });
    }
    return new Response('', { status: 404 });
  },
  onWebhookFanout: async (d) => {
    deliveries.push(...d);
  },
});

const hmac = async (secret: string, timestamp: string, exactBody: Uint8Array) => {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const prefix = new TextEncoder().encode(`${timestamp}.`);
  const combined = new Uint8Array(prefix.length + exactBody.length);
  combined.set(prefix, 0);
  combined.set(exactBody, prefix.length);
  const sig = await crypto.subtle.sign('HMAC', key, combined);
  return Buffer.from(sig).toString('hex');
};

describe('installation HTTP route', () => {
  it('persists the constrained popup liveness key', async () => {
    const db = createTestDb();
    const deliveries: Array<Record<string, unknown>> = [];
    const app = createBackend(makeDeps(db, deliveries));
    const installationKey = await generateTestKeypair();
    const popupKey = await generateTestKeypair();
    const challengeResponse = await app.request('/v1/installations/challenges', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        publicKey: installationKey.publicKeySpki,
        packageName: 'co.za.stephancill.stupid-wallet',
      }),
    });
    expect(challengeResponse.status).toBe(201);
    const challenge = (await challengeResponse.json()) as { challengeId: string };
    const body = JSON.stringify({
      challengeId: challenge.challengeId,
      publicKey: installationKey.publicKeySpki,
      popupLivenessPublicKey: popupKey.publicKeySpki,
      apnsEnvironment: 'development',
      apnsToken: 'a'.repeat(64),
      notificationAuthorization: 'authorized',
      notificationAlertSetting: 'enabled',
    });
    const timestamp = String(NOW());
    const requestId = 'request_popup_key';
    const digest = Buffer.from(
      await crypto.subtle.digest('SHA-256', new TextEncoder().encode(body)),
    ).toString('base64url');
    const signature = await installationKey.sign(
      new TextEncoder().encode(
        ['v1', 'POST', '/v1/installations', timestamp, requestId, digest].join('\n'),
      ),
    );
    const createResponse = await app.request('/v1/installations', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-wallet-request-id': requestId,
        'x-wallet-timestamp': timestamp,
        'x-wallet-signature': `v1,${signature}`,
      },
      body,
    });
    expect(createResponse.status).toBe(201);
    const created = (await createResponse.json()) as { installationId: string };
    const row = await db.first('SELECT popup_liveness_public_key FROM installations WHERE id = ?', [
      created.installationId,
    ]);
    expect(row?.popup_liveness_public_key).toBe(popupKey.publicKeySpki);

    await replaceChainsSnapshot(db, created.installationId, 1, ['1'], NOW());
    await setChainActivated(db, '1', NOW());
    await enrollAddresses(
      db,
      created.installationId,
      ['0x1111111111111111111111111111111111111111'],
      NOW(),
    );
    await syncUpstream(db, NOW());

    const testPath = `/v1/installations/${created.installationId}/test-notification`;
    const testTimestamp = String(NOW());
    const testRequestId = 'request_test_notification';
    const emptyDigest = Buffer.from(
      await crypto.subtle.digest('SHA-256', new Uint8Array()),
    ).toString('base64url');
    const testSignature = await installationKey.sign(
      new TextEncoder().encode(
        ['v1', 'POST', testPath, testTimestamp, testRequestId, emptyDigest].join('\n'),
      ),
    );
    const testResponse = await app.request(testPath, {
      method: 'POST',
      headers: {
        'x-wallet-request-id': testRequestId,
        'x-wallet-timestamp': testTimestamp,
        'x-wallet-signature': `v1,${testSignature}`,
      },
    });
    expect(testResponse.status).toBe(202);
    expect(deliveries).toHaveLength(1);
    expect(deliveries[0]?.eventKind).toBe('activityDetected');
  });
});

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

  const post = async (
    body: Record<string, unknown>,
    webhookId: string,
    timestamp = String(Math.floor(NOW() / 1_000)),
  ) => {
    deliveries = [];
    const app = createBackend(makeDeps(db, deliveries));
    const bodyText = new TextEncoder().encode(JSON.stringify(body));
    const sig = await hmac('test-secret', timestamp, bodyText);
    return app.request('/internal/v1/wallet-activity', {
      method: 'POST',
      headers: {
        'webhook-id': webhookId,
        'webhook-timestamp': timestamp,
        'webhook-signature': sig,
        'content-type': 'application/json',
      },
      body: bodyText,
    });
  };

  it('accepts a signed delivery and enqueues fanout', async () => {
    const res = await post(
      {
        id: 'obs-1',
        type: 'activity.observed',
        createdAt: new Date(NOW()).toISOString(),
        data: {
          chainId: 1,
          trackedAddress: '0x1111111111111111111111111111111111111111',
          initiatedByTrackedAddress: false,
          blockNumber: '123',
          blockHash: `0x${'cd'.repeat(32)}`,
          blockTimestamp: String(Math.floor(NOW() / 1_000)),
          transaction: {
            hash: `0x${'ab'.repeat(32)}`,
            index: 0,
            from: '0x2222222222222222222222222222222222222222',
            to: '0x1111111111111111111111111111111111111111',
            status: 'success',
            nonce: '1',
            value: '1000000000000000000',
          },
          effects: [],
        },
      },
      'obs-1',
    );
    expect(res.status).toBe(202);
    const json = (await res.json()) as { duplicate: boolean };
    expect(json.duplicate).toBe(false);
    expect(deliveries.length).toBe(1);
    expect(deliveries[0]?.eventKind).toBe('nativeReceived');
    expect(deliveries[0]?.subject).toBe('Received $2,500 of ETH');
  });

  it('accepts and classifies a real-shape zero-native-value ERC-20 swap', async () => {
    const res = await post(
      {
        id: 'obs-swap-1',
        type: 'activity.observed',
        createdAt: new Date(NOW()).toISOString(),
        data: {
          chainId: 1,
          trackedAddress: '0x1111111111111111111111111111111111111111',
          initiatedByTrackedAddress: true,
          blockNumber: '124',
          blockHash: `0x${'ef'.repeat(32)}`,
          blockTimestamp: String(Math.floor(NOW() / 1_000)),
          transaction: {
            hash: `0x${'bc'.repeat(32)}`,
            index: 1,
            from: '0x1111111111111111111111111111111111111111',
            to: '0x3333333333333333333333333333333333333333',
            status: 'success',
            nonce: '2',
            value: '0',
          },
          effects: [
            {
              id: 'effect-1',
              kind: 'erc20',
              direction: 'outgoing',
              logIndex: 3,
              from: '0x1111111111111111111111111111111111111111',
              to: '0x3333333333333333333333333333333333333333',
              assetAddress: '0x4444444444444444444444444444444444444444',
              amount: '1000',
            },
          ],
        },
      },
      'obs-swap-1',
    );
    expect(res.status).toBe(202);
    expect(deliveries).toHaveLength(1);
    expect(deliveries[0]?.eventKind).toBe('tokenSent');
  });

  it('rejects a bad HMAC', async () => {
    const app = createBackend(makeDeps(db, deliveries));
    const bodyText = new TextEncoder().encode(JSON.stringify({}));
    const res = await app.request('/internal/v1/wallet-activity', {
      method: 'POST',
      headers: {
        'webhook-id': 'hook-2',
        'webhook-timestamp': String(Math.floor(NOW() / 1_000)),
        'webhook-signature': 'bogus',
        'content-type': 'application/json',
      },
      body: bodyText,
    });
    expect(res.status).toBe(401);
  });

  it('rejects millisecond and malformed webhook timestamps', async () => {
    const body = {
      id: 'test-delivery-timestamp',
      type: 'webhook.test',
      createdAt: new Date(NOW()).toISOString(),
      data: { webhookId: 'configured-webhook-1' },
    };
    const milliseconds = await post(body, 'test-delivery-timestamp', String(NOW()));
    expect(milliseconds.status).toBe(401);
    const malformed = await post(body, 'test-delivery-timestamp', 'not-a-timestamp');
    expect(malformed.status).toBe(401);
  });

  it('accepts a signed upstream test ping without fanout', async () => {
    const res = await post(
      {
        id: 'test-delivery-1',
        type: 'webhook.test',
        createdAt: new Date(NOW()).toISOString(),
        data: { webhookId: 'configured-webhook-1' },
      },
      'test-delivery-1',
    );
    expect(res.status).toBe(202);
    expect(deliveries).toHaveLength(0);
  });
});
