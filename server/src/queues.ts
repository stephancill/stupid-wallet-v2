import type { Database } from './database';
import type { UpstreamClient } from './upstream';
import { setChainActivated, recomputeChainForAll } from './domain/registrations';
import { sendApnsPush, type ApnsPayload, type ApnsCredentials } from './apns';
import { aesGcmDecrypt } from './crypto';
import { eventTitle } from './services/eventKinds';

const MAX_NOTIFICATION_SUBJECT_LENGTH = 120;

export interface ApnsDelivery {
  installationId: string;
  eventId: string;
  addressRegistrationId: string;
  chainId: string;
  eventKind: string;
  subject?: string;
}

export const buildApnsPayload = (delivery: ApnsDelivery, installationId: string): ApnsPayload => {
  const candidate = delivery.subject?.trim();
  const title =
    candidate &&
    candidate.length <= MAX_NOTIFICATION_SUBJECT_LENGTH &&
    !candidate.includes('\n') &&
    !candidate.includes('\r')
      ? candidate
      : eventTitle(delivery.eventKind);
  return {
    aps: {
      'mutable-content': 1,
      // Keep a body in the base alert for the most conservative NSE activation shape.
      // The extension replaces it with locally resolved account and chain context.
      alert: {
        title,
        body: 'Open stupid wallet to view activity.',
      },
      'thread-id': installationId,
    },
    eventId: delivery.eventId,
    addressRegistrationId: delivery.addressRegistrationId,
    chainId: delivery.chainId,
    eventKind: delivery.eventKind,
    subject: title,
    schemaVersion: 1,
  };
};

export async function processUpstreamOperation(
  db: Database,
  upstream: UpstreamClient,
  operation: { id: number; kind: string; chain_id?: string | null; address?: string | null },
): Promise<void> {
  const id = operation.id;
  const kind = operation.kind;
  const chainId = String(operation.chain_id ?? '');
  const address = operation.address ? String(operation.address) : undefined;

  if (kind === 'activate_chain') {
    await db.run(
      "UPDATE upstream_operations SET status = 'processing', updated_at = ? WHERE id = ?",
      [Date.now(), id],
    );
    const chain = await upstream.getChain(chainId);
    if (chain.supported) {
      await setChainActivated(db, chainId, Date.now());
      await recomputeChainForAll(db, chainId, Date.now());
    } else {
      await db.run(
        "UPDATE webhook_chain_stages SET status = 'unsupported', updated_at = ? WHERE chain_id = ?",
        [Date.now(), chainId],
      );
    }
    await db.run("UPDATE upstream_operations SET status = 'done', updated_at = ? WHERE id = ?", [
      Date.now(),
      id,
    ]);
    return;
  }

  if (kind === 'create_subscription' && address) {
    await db.run(
      "UPDATE upstream_operations SET status = 'processing', updated_at = ? WHERE id = ?",
      [Date.now(), id],
    );
    const result = await upstream.createSubscription(address, chainId);
    await db.run(
      "UPDATE upstream_subscriptions SET upstream_subscription_id = ?, status = 'active', updated_at = ? WHERE address = ? AND chain_id = ?",
      [result.subscriptionId, Date.now(), address, chainId],
    );
    await db.run("UPDATE upstream_operations SET status = 'done', updated_at = ? WHERE id = ?", [
      Date.now(),
      id,
    ]);
    return;
  }

  if (kind === 'delete_subscription' && address) {
    const sub = await db.first(
      'SELECT * FROM upstream_subscriptions WHERE address = ? AND chain_id = ?',
      [address, chainId],
    );
    if (sub && String(sub.upstream_subscription_id ?? '')) {
      await upstream.deleteSubscription(String(sub.upstream_subscription_id));
    }
    await db.run('DELETE FROM upstream_subscriptions WHERE address = ? AND chain_id = ?', [
      address,
      chainId,
    ]);
    await db.run("UPDATE upstream_operations SET status = 'done', updated_at = ? WHERE id = ?", [
      Date.now(),
      id,
    ]);
    return;
  }

  throw new Error(`unknown upstream operation kind: ${kind}`);
}

export async function deliverApns(
  db: Database,
  opts: { appDataKey: string; creds: ApnsCredentials },
  delivery: ApnsDelivery,
  now: number,
): Promise<void> {
  const installation = await db.first('SELECT * FROM installations WHERE id = ?', [
    delivery.installationId,
  ]);
  if (!installation) return;
  const environment = String(installation.apns_environment ?? '');
  if (environment !== 'development' && environment !== 'production') return;
  const ciphertext = installation.apns_token_ciphertext;
  if (!ciphertext) return;

  let token: string;
  try {
    token = new TextDecoder().decode(await aesGcmDecrypt(opts.appDataKey, String(ciphertext)));
  } catch {
    return;
  }

  const payload = buildApnsPayload(delivery, delivery.installationId);

  const outcome = await sendApnsPush(opts.creds, token, environment, payload);
  await db.run(
    'INSERT INTO apns_deliveries (installation_id, installation_event_id, status, attempts, created_at, updated_at) VALUES (?, ?, ?, 1, ?, ?)',
    [delivery.installationId, delivery.eventId, outcome.outcome, now, now],
  );
}
