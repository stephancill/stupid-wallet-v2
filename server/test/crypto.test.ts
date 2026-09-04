import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { verifyP256 } from '../src/p256';
import { buildCanonicalSequence, bodyDigestOf } from '../src/auth/request';
import { hmacSha256Base64Url, sha256Base64Url } from '../src/crypto';

const here = dirname(fileURLToPath(import.meta.url));
const vector = JSON.parse(readFileSync(join(here, 'fixtures', 'p256-vector.json'), 'utf8'));

describe('P-256 installation-key vectors', () => {
  it('verifies the independent fixture signature', async () => {
    const ok = await verifyP256(
      (vector as { spkiBase64Url: string }).spkiBase64Url,
      (vector as { signatureBase64Url: string }).signatureBase64Url,
      new TextEncoder().encode((vector as { message: string }).message),
    );
    expect(ok).toBe(true);
  });

  it('rejects a tampered message', async () => {
    const ok = await verifyP256(
      (vector as { spkiBase64Url: string }).spkiBase64Url,
      (vector as { signatureBase64Url: string }).signatureBase64Url,
      new TextEncoder().encode('tampered'),
    );
    expect(ok).toBe(false);
  });
});

describe('canonical request hashing', () => {
  it('computes a stable body digest and canonical sequence', async () => {
    const body = new TextEncoder().encode('{"installationId":"inst_1"}');
    const digest = await bodyDigestOf(body);
    expect(digest).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const canonical = buildCanonicalSequence(
      'PUT',
      '/v1/installations/inst_1/push-token',
      '1720000000000',
      'req-1',
      digest,
    );
    expect(canonical.startsWith('v1\nPUT\n/v1/installations/inst_1/push-token\n')).toBe(true);
  });
});

describe('HMAC helpers', () => {
  it('hashes deterministically', async () => {
    const secret = new TextEncoder().encode('secret');
    const first = await hmacSha256Base64Url(secret, 'payload');
    const second = await hmacSha256Base64Url(secret, 'payload');
    expect(first).toBe(second);
    expect(await sha256Base64Url('payload')).not.toBe(first);
  });
});
