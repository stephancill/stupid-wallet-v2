import type { D1Database } from '@cloudflare/workers-types';
import Database from 'better-sqlite3';

export type Row = Record<string, unknown>;
export type List = Array<Record<string, unknown>>;

export interface WriteResult {
  changes: number;
}

export interface Database {
  /** Run a query returning many rows. */
  all(sql: string, params?: Array<unknown>): Promise<List>;
  /** Run a query returning the first row, or null. */
  first(sql: string, params?: Array<unknown>): Promise<Row | null>;
  /** Run a write statement. */
  run(sql: string, params?: Array<unknown>): Promise<WriteResult>;
  /** Apply multiple writes atomically. */
  batch(queries: Array<{ sql: string; params?: Array<unknown> }>): Promise<void>;
}

/** D1-backed adapter used inside the Cloudflare Worker. */
export const createD1Database = (d1: D1Database): Database => ({
  async all(sql, params = []) {
    const result = await d1
      .prepare(sql)
      .bind(...params)
      .all();
    return result.results as List;
  },
  async first(sql, params = []) {
    return (await d1
      .prepare(sql)
      .bind(...params)
      .first()) as Row | null;
  },
  async run(sql, params = []) {
    const result = await d1
      .prepare(sql)
      .bind(...params)
      .run();
    return { changes: result.meta.changes };
  },
  async batch(queries) {
    const prepared = queries.map(({ sql, params = [] }) => d1.prepare(sql).bind(...params));
    await d1.batch(prepared);
  },
});

/** better-sqlite3 in-memory adapter for hermetic tests. */
export const createMemoryDatabase = (existing?: InstanceType<typeof Database>): Database => {
  const raw = existing ?? new Database(':memory:');
  raw.pragma('foreign_keys = ON');
  return {
    async all(sql, params = []) {
      return raw.prepare(sql).all(...params) as List;
    },
    async first(sql, params = []) {
      return (raw.prepare(sql).get(...params) as Row | undefined) ?? null;
    },
    async run(sql, params = []) {
      const result = raw.prepare(sql).run(...params);
      return { changes: Number(result.changes) };
    },
    async batch(queries) {
      raw.transaction(() => {
        for (const q of queries) {
          raw.prepare(q.sql).run(...(q.params ?? []));
        }
      })();
    },
  };
};
