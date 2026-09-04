import { describe, expect, it } from 'vitest';
import { createUpstreamClient, type UpstreamHttp } from '../src/upstream';

const env = { UPSTREAM_API_KEY: 'test-key', UPSTREAM_WEBHOOK_ID: 'wh_test' };

describe('Stupid Wallet Webhooks client contract', () => {
  it('treats a resolved chain response as supported and 404 as unsupported', async () => {
    const responses = [
      new Response(JSON.stringify({ chainId: 8453, status: null }), { status: 200 }),
      new Response(JSON.stringify({ error: 'unknown chain' }), { status: 404 }),
    ];
    const client = createUpstreamClient(env, 'https://example.test', async () =>
      responses.shift()!,
    );
    await expect(client.getChain('8453')).resolves.toEqual({ supported: true });
    await expect(client.getChain('999999')).resolves.toEqual({ supported: false });
  });

  it('creates the live multi-chain request shape and returns its per-chain id', async () => {
    let request: RequestInit | undefined;
    const fetch: UpstreamHttp = async (_url, init) => {
      request = init;
      return new Response(
        JSON.stringify({ subscriptions: [{ id: 'sub_1', chainId: 8453, status: 'pending' }] }),
        { status: 201 },
      );
    };
    const client = createUpstreamClient(env, 'https://example.test', fetch);
    await expect(
      client.createSubscription('0x1111111111111111111111111111111111111111', '8453'),
    ).resolves.toEqual({ subscriptionId: 'sub_1' });
    expect(JSON.parse(String(request?.body))).toEqual({
      address: '0x1111111111111111111111111111111111111111',
      chainIds: [8453],
      webhookId: 'wh_test',
    });
  });
});
