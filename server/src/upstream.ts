import type { Env } from './config';

export interface UpstreamClient {
  getChain(chainId: string): Promise<{ supported: boolean; activeFromBlock?: string }>;
  createSubscription(address: string, chainId: string): Promise<{ subscriptionId: string }>;
  deleteSubscription(subscriptionId: string): Promise<void>;
}

export interface UpstreamHttp {
  (url: string, init: RequestInit): Promise<Response>;
}

/**
 * Stupid Wallet Webhooks HTTP client. Keeps the customer API key on the backend
 * and never exposes it to the app. Designed to be injectable for tests.
 */
export const createUpstreamClient = (
  env: Pick<Env, 'UPSTREAM_API_KEY'>,
  baseUrl: string,
  fetchImpl: UpstreamHttp = fetch,
): UpstreamClient => ({
  async getChain(chainId) {
    const response = await fetchImpl(`${baseUrl}/v1/chains/${encodeURIComponent(chainId)}`, {
      headers: authHeaders(env.UPSTREAM_API_KEY),
    });
    if (!response.ok) {
      throw new Error(`upstream getChain failed: ${response.status}`);
    }
    const body = (await response.json()) as { supported?: boolean; activeFromBlock?: string };
    return { supported: Boolean(body.supported), activeFromBlock: body.activeFromBlock };
  },
  async createSubscription(address, chainId) {
    const response = await fetchImpl(`${baseUrl}/v1/subscriptions`, {
      method: 'POST',
      headers: { ...authHeaders(env.UPSTREAM_API_KEY), 'content-type': 'application/json' },
      body: JSON.stringify({ address, chainId }),
    });
    if (!response.ok) {
      throw new Error(`upstream createSubscription failed: ${response.status}`);
    }
    const body = (await response.json()) as { subscriptionId: string; id?: string };
    return { subscriptionId: body.subscriptionId ?? body.id ?? '' };
  },
  async deleteSubscription(subscriptionId) {
    const response = await fetchImpl(
      `${baseUrl}/v1/subscriptions/${encodeURIComponent(subscriptionId)}`,
      { method: 'DELETE', headers: authHeaders(env.UPSTREAM_API_KEY) },
    );
    if (!response.ok) {
      throw new Error(`upstream deleteSubscription failed: ${response.status}`);
    }
  },
});

const authHeaders = (apiKey: string): Record<string, string> => ({
  authorization: `Bearer ${apiKey}`,
});
