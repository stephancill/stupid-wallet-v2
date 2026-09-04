import type { Database } from '../database';

/** Allocate the next value for a named monotonic counter (used for event cursors). */
export const nextCounter = async (db: Database, name: string): Promise<number> => {
  const rows = await db.all(
    `INSERT INTO counters (name, value) VALUES (?, 1)
     ON CONFLICT (name) DO UPDATE SET value = value + 1
     RETURNING value`,
    [name],
  );
  return Number((rows[0] as { value: number } | undefined)?.value ?? 1);
};
