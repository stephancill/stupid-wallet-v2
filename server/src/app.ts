import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { ZodError } from 'zod';
import type { Database } from './database';
import type { UpstreamClient } from './upstream';
import { createChallenge, consumeChallenge } from './domain/challenge';
import {
  createInstallation,
  extendLiveness,
  requireInstallation,
  updateNotificationStatus,
  updatePushToken,
} from './domain/installations';
import {
  activeChainIds,
  enrollAddresses,
  reconcileEnrollments,
  refreshStaging,
  removeEnrollment,
  replaceChainsSnapshot,
  syncUpstream,
} from './domain/registrations';
import { ingestWebhook } from './domain/webhook';
import { listInstallationEvents } from './domain/events';
import { purgeInstallation } from './domain/lifecycle';
import { authenticateRequest, bodyDigestOf } from './auth/request';
import { verifyPopupLiveness } from './auth/popup';
import { schemas } from './schemas';
import { checkRate } from './rate';
import { HttpError } from './errors';
import { constantTimeEqual, hmacSha256Base64Url } from './crypto';
import { verifyP256 } from './p256';
import { CONFIG } from './config';

export interface BackendDeps {
  db: Database;
  appDataKey: string;
  environment: string;
  webhookSecret: string;
  upstream: UpstreamClient;
  now: () => number;
  /** Called with deliveries to enqueue onto the APNs queue. */
  onWebhookFanout?: (deliveries: Array<Record<string, unknown>>) => Promise<void>;
}

type Ctx = import('hono').Context;

const splitSignature = (header: string | undefined): string => {
  if (!header) throw new HttpError(401, 'unauthorized', 'missing signature header');
  const [scheme, signature] = header.split(',');
  if (scheme !== 'v1' || !signature) {
    throw new HttpError(401, 'unauthorized', 'unsupported signature scheme');
  }
  return signature;
};

const requireParam = (value: string | undefined): string => {
  if (!value) throw new HttpError(404, 'not_found', 'missing route parameter');
  return value;
};

export const createBackend = (deps: BackendDeps): Hono => {
  const app = new Hono();
  app.use('/v1/*', cors());
  app.onError((error) => {
    if (error instanceof HttpError) {
      return new Response(JSON.stringify({ error: { code: error.code, message: error.message } }), {
        status: error.status,
        headers: { 'content-type': 'application/json' },
      });
    }
    if (error instanceof ZodError) {
      return new Response(
        JSON.stringify({
          error: { code: 'bad_request', message: error.issues[0]?.message ?? 'invalid request' },
        }),
        { status: 400, headers: { 'content-type': 'application/json' } },
      );
    }
    return new Response(
      JSON.stringify({ error: { code: 'internal_error', message: 'internal error' } }),
      {
        status: 500,
        headers: { 'content-type': 'application/json' },
      },
    );
  });

  const db = deps.db;
  const at = () => deps.now();

  // signed: authenticates the installation key over the exact request bytes.
  const signed =
    (handler: (c: Ctx) => Promise<Response>) =>
    async (c: Ctx): Promise<Response> => {
      const installationId = requireParam(c.req.param('id'));
      const url = new URL(c.req.url);
      const pathAndQuery = url.pathname + url.search;
      const requestId = c.req.header('x-wallet-request-id') ?? '';
      const timestamp = c.req.header('x-wallet-timestamp') ?? '';
      const signature = splitSignature(c.req.header('x-wallet-signature'));
      const bodyBytes = new Uint8Array(await c.req.arrayBuffer());
      await authenticateRequest(
        db,
        c.req.method,
        pathAndQuery,
        installationId,
        timestamp,
        requestId,
        signature,
        bodyBytes,
        at(),
      );
      return handler(c);
    };

  // ---- Public bootstrap: challenge ----
  app.post('/v1/installations/challenges', async (c) => {
    await checkRate(
      db,
      'challenge:global',
      CONFIG.rateLimits.challenge.windowSeconds,
      CONFIG.rateLimits.challenge.max,
      at(),
    );
    const body = schemas.challengeCreate.parse(await c.req.json());
    const result = await createChallenge(
      db,
      deps.appDataKey,
      body.publicKey,
      body.packageName,
      deps.environment,
      at(),
    );
    return c.json(
      {
        challengeId: result.challengeId,
        installationPublicKeyHash: result.installationPublicKeyHash,
        nonce: result.nonce,
        serverTime: result.serverTime,
        expiresAt: result.expiresAt,
        provisionalInstallationId: result.provisionalInstallationId,
      },
      201,
    );
  });

  // ---- Public bootstrap: install ----
  app.post('/v1/installations', async (c) => {
    await checkRate(
      db,
      'install:create',
      CONFIG.rateLimits.installationCreate.windowSeconds,
      CONFIG.rateLimits.installationCreate.max,
      at(),
    );
    const bodyBytes = new Uint8Array(await c.req.arrayBuffer());
    const textBuffer = new TextDecoder().decode(bodyBytes);
    const body = schemas.installationCreate.parse(textBuffer ? JSON.parse(textBuffer) : {});

    const url = new URL(c.req.url);
    const pathAndQuery = url.pathname + url.search;
    const requestId = c.req.header('x-wallet-request-id') ?? '';
    const timestamp = c.req.header('x-wallet-timestamp') ?? '';
    const signature = splitSignature(c.req.header('x-wallet-signature'));
    if (!/^[A-Za-z0-9_-]{8,128}$/.test(requestId))
      throw new HttpError(400, 'bad_request', 'malformed request id');
    if (Math.abs(at() - Number(timestamp)) > CONFIG.clockSkewSeconds * 1000) {
      throw new HttpError(401, 'unauthorized', 'timestamp outside window');
    }

    const digest = await bodyDigestOf(bodyBytes);
    const canonical = ['v1', 'POST', pathAndQuery, timestamp, requestId, digest].join('\n');
    const valid = await verifyP256(body.publicKey, signature, new TextEncoder().encode(canonical));
    if (!valid) throw new HttpError(400, 'bad_request', 'installation public-key signature failed');

    await consumeChallenge(db, body.challengeId, body.publicKey, deps.appDataKey, at());

    const id = await createInstallation(
      db,
      { appDataKey: deps.appDataKey },
      {
        publicKey: body.publicKey,
        appVersion: body.appVersion,
        appBuild: body.appBuild,
        apnsEnvironment: body.apnsEnvironment,
        apnsToken: body.apnsToken,
        notificationAuthorization: body.notificationAuthorization,
        notificationAlertSetting: body.notificationAlertSetting,
      },
    );

    await db.run(
      'INSERT OR IGNORE INTO installation_request_ids (installation_id, request_id, consumed_at, expires_at) VALUES (?, ?, ?, ?)',
      [id, requestId, at(), at() + CONFIG.replayWindowSeconds * 1000],
    );

    return c.json({ installationId: id, trustMode: 'installation_key_only' }, 201);
  });

  // ---- Authenticated routes ----
  app.get(
    '/v1/installations/:id',
    signed(async (c) => {
      const installation = await requireInstallation(db, requireParam(c.req.param('id')));
      return c.json({
        installationId: String(installation.id),
        trustMode: String(installation.trust_mode),
        notificationAuthorization: installation.notification_authorization ?? null,
        notificationAlertSetting: installation.notification_alert_setting ?? null,
        hasApnsToken: Boolean(installation.apns_token_hash),
        livenessExpiresAt: Number(installation.liveness_expires_at),
      });
    }),
  );

  app.put(
    '/v1/installations/:id/push-token',
    signed(async (c) => {
      const body = schemas.pushToken.parse(await c.req.json());
      await updatePushToken(
        db,
        { appDataKey: deps.appDataKey },
        requireParam(c.req.param('id')),
        body.environment,
        body.token,
      );
      await refreshStaging(db, at());
      await syncUpstream(db, at());
      return c.json({ ok: true });
    }),
  );

  app.put(
    '/v1/installations/:id/notification-status',
    signed(async (c) => {
      const body = schemas.notificationStatus.parse(await c.req.json());
      await updateNotificationStatus(db, requireParam(c.req.param('id')), {
        authorization: body.authorization,
        alertSetting: body.alertSetting,
        observedAt: body.observeUnixMilliseconds,
      });
      return c.json({ ok: true });
    }),
  );

  app.put(
    '/v1/installations/:id/chains',
    signed(async (c) => {
      const body = schemas.chains.parse(await c.req.json());
      await replaceChainsSnapshot(
        db,
        requireParam(c.req.param('id')),
        body.revision,
        body.chainIds,
        at(),
      );
      const active = await activeChainIds(db);
      const stageRows = await db.all('SELECT chain_id, status FROM webhook_chain_stages');
      const statusByChain = new Map(stageRows.map((r) => [String(r.chain_id), String(r.status)]));
      return c.json({
        accepted: body.chainIds.map((chainId) => ({
          chainId,
          stage: statusByChain.get(chainId) ?? 'staged',
        })),
        activeChains: active,
      });
    }),
  );

  app.post(
    '/v1/installations/:id/addresses',
    signed(async (c) => {
      const body = schemas.addresses.parse(await c.req.json());
      await enrollAddresses(db, requireParam(c.req.param('id')), body.addresses, at());
      const active = await activeChainIds(db);
      return c.json({ registeredAddresses: body.addresses.length, activeChains: active });
    }),
  );

  app.delete(
    '/v1/installations/:id/addresses/:address',
    signed(async (c) => {
      const address = requireParam(c.req.param('address'));
      await removeEnrollment(db, requireParam(c.req.param('id')), address, at());
      return c.json({ ok: true });
    }),
  );

  app.post(
    '/v1/installations/:id/renew',
    signed(async (c) => {
      const body = schemas.renew.parse(await c.req.json());
      await reconcileEnrollments(db, requireParam(c.req.param('id')), body.addresses, at());
      await replaceChainsSnapshot(
        db,
        requireParam(c.req.param('id')),
        body.chains.revision,
        body.chains.chainIds,
        at(),
      );
      return c.json({ ok: true });
    }),
  );

  app.get(
    '/v1/installations/:id/events',
    signed(async (c) => {
      const cursor = c.req.query('cursor');
      const limit = Number(c.req.query('limit') ?? 50);
      const page = await listInstallationEvents(
        db,
        requireParam(c.req.param('id')),
        cursor ?? null,
        limit,
      );
      return c.json(page);
    }),
  );

  app.delete(
    '/v1/installations/:id',
    signed(async (c) => {
      await purgeInstallation(db, requireParam(c.req.param('id')));
      await refreshStaging(db, at());
      await syncUpstream(db, at());
      return c.json({ ok: true });
    }),
  );

  // ---- Popup liveness ----
  app.post('/v1/installations/:id/liveness', async (c) => {
    const id = requireParam(c.req.param('id'));
    await checkRate(
      db,
      `popup:${id}`,
      CONFIG.rateLimits.popupLiveness.windowSeconds,
      CONFIG.rateLimits.popupLiveness.max,
      at(),
    );
    await checkRate(
      db,
      'popup:global',
      CONFIG.rateLimits.popupLiveness.windowSeconds,
      CONFIG.rateLimits.popupLiveness.max,
      at(),
    );
    const url = new URL(c.req.url);
    const pathAndQuery = url.pathname + url.search;
    const requestId = c.req.header('x-wallet-request-id') ?? '';
    const timestamp = c.req.header('x-wallet-timestamp') ?? '';
    const signature = splitSignature(c.req.header('x-wallet-signature'));
    const installation = await verifyPopupLiveness(
      db,
      id,
      timestamp,
      requestId,
      signature,
      pathAndQuery,
      at(),
    );
    await extendLiveness(db, installation, at());
    return c.json({ ok: true });
  });

  // ---- Internal webhook ----
  app.post('/internal/v1/wallet-activity', async (c) => {
    await checkRate(
      db,
      'webhook:global',
      CONFIG.rateLimits.webhook.windowSeconds,
      CONFIG.rateLimits.webhook.max,
      at(),
    );
    const exactBody = new Uint8Array(await c.req.arrayBuffer());
    const webhookId = c.req.header('x-wallet-hook-id') ?? '';
    const hookTimestamp = c.req.header('x-wallet-hook-timestamp') ?? '';
    const signatureHeader = c.req.header('x-wallet-hook-signature') ?? '';
    if (!webhookId || !hookTimestamp || !signatureHeader) {
      throw new HttpError(401, 'unauthorized', 'missing webhook headers');
    }
    if (Math.abs(at() - Number(hookTimestamp)) > CONFIG.clockSkewSeconds * 1000) {
      throw new HttpError(401, 'unauthorized', 'webhook timestamp outside window');
    }

    const secret = new TextEncoder().encode(deps.webhookSecret);
    const mac = await webhookHmac(secret, webhookId, hookTimestamp, exactBody);
    const expected = signatureHeader.replace(/^v1,?/, '');
    if (!constantTimeEqual(new TextEncoder().encode(mac), new TextEncoder().encode(expected))) {
      throw new HttpError(401, 'unauthorized', 'webhook signature invalid');
    }

    const payloadText = new TextDecoder().decode(exactBody);
    const payload = schemas.webhookEvent.parse(payloadText ? JSON.parse(payloadText) : {});
    const result = await ingestWebhook(db, payload, webhookId, at());

    if (!result.duplicate && deps.onWebhookFanout && result.fanout.length > 0) {
      const deliveries = result.fanout.map((target) => ({
        installationId: target.installationId,
        eventId: result.eventId,
        addressRegistrationId: target.opaqueRegistrationId,
        chainId: payload.chainId,
        eventKind: result.eventKind,
        createdAt: at(),
      }));
      await deps.onWebhookFanout(deliveries);
    }

    return c.json({ ok: true, duplicate: result.duplicate }, 202);
  });

  return app;
};

const webhookHmac = async (
  secret: Uint8Array,
  webhookId: string,
  hookTimestamp: string,
  exactBody: Uint8Array,
): Promise<string> => {
  const encoder = new TextEncoder();
  const prefixBytes = encoder.encode(`${webhookId}.${hookTimestamp}.`);
  const combined = new Uint8Array(prefixBytes.length + exactBody.length);
  combined.set(prefixBytes, 0);
  combined.set(exactBody, prefixBytes.length);
  return hmacSha256Base64Url(secret, combined);
};
