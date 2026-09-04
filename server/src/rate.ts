import { rateLimited } from './errors';
import type { Database } from './database';

/**
 * D1-backed sliding window counter. Returns without throwing when a new request
 * is within the bound; throws {@link rateLimited} when the limit is exceeded.
 */
export async function checkRate(
  db: Database,
  key: string,
  windowSeconds: number,
  max: number,
  now = Date.now(),
): Promise<void> {
  const windowStart = Math.floor(now / (windowSeconds * 1000)) * (windowSeconds * 1000);
  const row = await db
    .all(
      `INSERT INTO rate_limits (limit_key, window_start, count) VALUES (?, ?, 1)
       ON CONFLICT (limit_key, window_start) DO UPDATE SET count = count + 1
       RETURNING count`,
      [key, windowStart],
    )
    .then((rows) => rows[0] as { count: number } | undefined);

  if ((row?.count ?? 0) > max) {
    throw rateLimited('rate limit exceeded');
  }
}
