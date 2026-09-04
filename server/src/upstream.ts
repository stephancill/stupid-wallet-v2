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
  env: Pick<Env, 'UPSTREAM_API_KEY' | 'UPSTREAM_WEBHOOK_ID'>,
  baseUrl: string,
  fetchImpl: UpstreamHttp = fetch,
): UpstreamClient => ({
  async getChain(chainId) {
    const response = await fetchImpl(`${baseUrl}/v1/chains/${encodeURIComponent(chainId)}`, {
      headers: authHeaders(env.UPSTREAM_API_KEY),
    });
    if (response.status === 404) return { supported: false };
    if (!response.ok) {
      throw new Error(`upstream getChain failed: ${response.status}`);
    }
    const body = (await response.json()) as { cursorBlock?: string | null };
    return { supported: true, activeFromBlock: body.cursorBlock ?? undefined };
  },
  async createSubscription(address, chainId) {
    const response = await fetchImpl(`${baseUrl}/v1/subscriptions`, {
      method: 'POST',
      headers: { ...authHeaders(env.UPSTREAM_API_KEY), 'content-type': 'application/json' },
      body: JSON.stringify({
        address,
        chainIds: [Number(chainId)],
        webhookId: env.UPSTREAM_WEBHOOK_ID,
      }),
    });
    const body = (await response.json()) as {
      subscriptions?: Array<{ id?: string; chainId?: number; status?: string; message?: string }>;
    };
    const subscription = body.subscriptions?.find((item) => String(item.chainId) === chainId);
    if (!response.ok || !subscription?.id) {
      throw new Error(
        `upstream createSubscription failed: ${response.status} ${subscription?.status ?? 'invalid_response'}`,
      );
    }
    return { subscriptionId: subscription.id };
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
