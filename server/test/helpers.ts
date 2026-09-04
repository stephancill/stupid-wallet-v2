import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import Database from 'better-sqlite3';
import { createMemoryDatabase, type Database as Db } from '../src/database';

const here = dirname(fileURLToPath(import.meta.url));

/** Create a test database with the full migration schema applied. */
export const createTestDb = (): Db => {
  const raw = new Database(':memory:');
  raw.pragma('foreign_keys = ON');
  const migrationsDir = join(here, '..', 'migrations');
  const files = ['0001_initial.sql'];
  for (const file of files) {
    const sql = readFileSync(join(migrationsDir, file), 'utf8');
    raw.exec(sql);
  }
  return createMemoryDatabase(raw);
};

export const testNow = (): number => Date.now();

/** A minimal in-memory P-256 keypair for validations (WebCrypto). */
export const generateTestKeypair = async (): Promise<{
  publicKeySpki: string;
  sign: (message: Uint8Array) => Promise<string>;
}> => {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, [
    'sign',
    'verify',
  ]);
  const spki = await crypto.subtle.exportKey('spki', pair.publicKey);
  const spkiB64 = Buffer.from(spki).toString('base64url');
  return {
    publicKeySpki: spkiB64,
    sign: async (message: Uint8Array) => {
      const sig = await crypto.subtle.sign(
        { name: 'ECDSA', hash: 'SHA-256' },
        pair.privateKey,
        message as unknown as BufferSource,
      );
      return Buffer.from(sig).toString('base64url');
    },
  };
};

/* Re-export for convenience in tests. */
export const enc = (input: Uint8Array | string): string =>
  typeof input === 'string'
    ? Buffer.from(input).toString('base64url')
    : Buffer.from(input).toString('base64url');
