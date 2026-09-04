import type { Database, Row } from '../database';
import { notFound } from '../errors';

export interface FeedItem {
  eventId: string;
  cursor: string;
  chainId: string;
  eventKind: string;
  address: string;
  addressRegistrationId: string;
  createdAt: number;
}

export interface FeedPage {
  items: FeedItem[];
  nextCursor: string | null;
}

/**
 * Read an authenticated installation's event feed from a durable cursor. The
 * cursor is the last-returned cursor string; repeating it after a timeout returns
 * the same window and never skips events.
 */
export async function listInstallationEvents(
  db: Database,
  installationId: string,
  cursor: string | null,
  limit: number,
): Promise<FeedPage> {
  const installation = await db.first('SELECT id FROM installations WHERE id = ?', [
    installationId,
  ]);
  if (!installation) throw notFound('installation not found');

  const bounded = Math.min(Math.max(limit, 1), 100);
  const after = cursor !== null ? Number(cursor) : 0;
  if (!Number.isFinite(after)) throw notFound('invalid cursor');

  const rows = await db.all(
    `SELECT * FROM installation_events
      WHERE installation_id = ? AND cursor_seq > ?
      ORDER BY cursor_seq ASC
      LIMIT ?`,
    [installationId, after, bounded],
  );

  const items: FeedItem[] = rows.map((row) => ({
    eventId: String(row.event_id),
    cursor: String(row.cursor_seq),
    address: String(row.address),
    addressRegistrationId: String(row.address_registration_id),
    eventKind: String(row.event_kind),
    chainId: String(row.chain_id),
    createdAt: Number(row.created_at),
  }));

  const nextCursor = items.length === bounded ? (items.at(-1)?.cursor ?? null) : null;
  return { items, nextCursor };
}

export type { Row as EventRow };
