import type { Env } from './config';
import { createBackend, type BackendDeps } from './app';
import { createD1Database } from './database';
import { createUpstreamClient } from './upstream';
import { processUpstreamOperation, deliverApns, type ApnsDelivery } from './queues';
import {
  expireLapsedInstallations,
  pruneInstallationEvents,
  pruneScratchState,
} from './domain/lifecycle';
import { refreshStaging, syncUpstream } from './domain/registrations';
import type { ApnsCredentials } from './apns';

const nowMs = () => Date.now();
const UPSTREAM_BASE_URL = 'https://wallet-webhooks.stupidtech.net';

const apnsCreds = (env: Env): ApnsCredentials => ({
  privateKeyPkcs8Base64Url: env.APNS_KEY,
  keyId: env.APNS_KEY_ID,
  teamId: env.APNS_TEAM_ID,
  topic: env.APNS_TOPIC,
});

const upstreamClient = (env: Env) => createUpstreamClient(env, UPSTREAM_BASE_URL);

const buildDeps = (env: Env): BackendDeps => {
  const db = createD1Database(env.DB);
  return {
    db,
    appDataKey: env.APP_DATA_KEY,
    environment: env.ENVIRONMENT,
    webhookSecret: env.UPSTREAM_WEBHOOK_SECRET,
    upstream: upstreamClient(env),
    now: nowMs,
    onWebhookFanout: async (deliveries) => {
      await env.APNS_QUEUE.sendBatch(
        deliveries.map((delivery) => ({ body: { type: 'apns', ...delivery } })),
      );
    },
  };
};

const runScheduledReconciliation = async (env: Env): Promise<void> => {
  const db = createD1Database(env.DB);
  const at = nowMs();
  await pruneScratchState(db, at);
  await pruneInstallationEvents(db, at);
  await expireLapsedInstallations(db, at);
  await refreshStaging(db, at);
  await syncUpstream(db, at);
  const pending = await db.all("SELECT * FROM upstream_operations WHERE status = 'pending'");
  if (pending.length > 0) {
    await env.UPSTREAM_QUEUE.sendBatch(
      pending.map((row) => ({ body: { type: 'upstream', id: Number(row.id) } })),
    );
  }
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const app = createBackend(buildDeps(env));
    return app.fetch(request, env, {} as Parameters<typeof app.fetch>[2]);
  },

  async scheduled(_event: unknown, env: Env): Promise<void> {
    await runScheduledReconciliation(env);
  },

  async queue(batch: unknown, env: Env): Promise<void> {
    const messages = (batch as { messages: Array<{ body: Record<string, unknown> }> }).messages;
    const db = createD1Database(env.DB);
    for (const message of messages) {
      const body = message.body;
      if (body.type === 'upstream' && typeof body.id === 'number') {
        const row = await db.first('SELECT * FROM upstream_operations WHERE id = ?', [body.id]);
        if (!row) continue;
        await processUpstreamOperation(db, upstreamClient(env), {
          id: Number(row.id),
          kind: String(row.kind),
          chain_id: row.chain_id != null ? String(row.chain_id) : null,
          address: row.address != null ? String(row.address) : null,
        });
        continue;
      }
      await deliverApns(
        db,
        { appDataKey: env.APP_DATA_KEY, creds: apnsCreds(env) },
        body as unknown as ApnsDelivery,
        nowMs(),
      );
    }
  },
};
