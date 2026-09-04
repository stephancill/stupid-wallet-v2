/** Base64URL helpers avoiding Node Buffer for worker portability. */
export const base64UrlEncode = (input: Uint8Array): string => {
  const bin = Array.from(input, (byte) => String.fromCharCode(byte)).join('');
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

export const base64UrlDecode = (input: string): Uint8Array => {
  const normalized = input.replace(/-/g, '+').replace(/_/g, '/');
  const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=');
  const bin = atob(padded);
  const bytes = new Uint8Array(bin.length);
  for (let index = 0; index < bin.length; index += 1) {
    bytes[index] = bin.charCodeAt(index);
  }
  return bytes;
};

/**
 * Bridges the generic typed-array variance between lib/webworker and the
 * @cloudflare/workers-types DOM `BufferSource` when passing bytes to Web Crypto.
 */
export const asBufferSource = (input: Uint8Array | undefined): BufferSource | undefined =>
  input === undefined ? undefined : (input as unknown as BufferSource);

/** SHA-256 as raw bytes. */
export const sha256 = async (input: Uint8Array | string): Promise<Uint8Array> => {
  const bytes = typeof input === 'string' ? new TextEncoder().encode(input) : input;
  return new Uint8Array(await crypto.subtle.digest('SHA-256', asBufferSource(bytes)!));
};

export const sha256Base64Url = async (input: Uint8Array | string): Promise<string> =>
  base64UrlEncode(await sha256(input));

/** Constant-time byte comparison. */
export const constantTimeEqual = (a: Uint8Array, b: Uint8Array): boolean => {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let index = 0; index < a.length; index += 1) {
    diff |= (a[index] ?? 0) ^ (b[index] ?? 0);
  }
  return diff === 0;
};

export const hmacSha256Base64Url = async (
  key: Uint8Array,
  input: Uint8Array | string,
): Promise<string> => {
  const keyHandle = await crypto.subtle.importKey(
    'raw',
    asBufferSource(key)!,
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const bytes = typeof input === 'string' ? new TextEncoder().encode(input) : input;
  const signature = await crypto.subtle.sign('HMAC', keyHandle, asBufferSource(bytes)!);
  return base64UrlEncode(new Uint8Array(signature));
};

/** Keyed HMAC-SHA256 hash used for APNs token lookup (never stores the raw token). */
export const keyedHash = (keyBase64: string, input: string): Promise<string> => {
  const keyBytes = base64UrlDecode(keyBase64);
  return hmacSha256Base64Url(keyBytes, input);
};

/** AES-256-GCM authenticated encryption for sensitive delivery values. */
export async function aesGcmEncrypt(
  keyBase64: string,
  plaintext: Uint8Array,
  associatedData?: Uint8Array,
): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    asBufferSource(base64UrlDecode(keyBase64))!,
    { name: 'AES-GCM' },
    false,
    ['encrypt'],
  );
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      {
        name: 'AES-GCM',
        iv: asBufferSource(iv)!,
        additionalData: asBufferSource(associatedData),
        tagLength: 128,
      },
      key,
      asBufferSource(plaintext)!,
    ),
  );
  const combined = new Uint8Array(iv.length + ciphertext.length);
  combined.set(iv, 0);
  combined.set(ciphertext, iv.length);
  return base64UrlEncode(combined);
}

/** Decrypts an AES-GCM envelope produced by {@link aesGcmEncrypt}. */
export async function aesGcmDecrypt(
  keyBase64: string,
  envelopeBase64Url: string,
  associatedData?: Uint8Array,
): Promise<Uint8Array> {
  const combined = base64UrlDecode(envelopeBase64Url);
  const iv = combined.subarray(0, 12);
  if (combined.length < 12 + 16) {
    throw new Error('invalid ciphertext envelope');
  }
  const ciphertext = combined.subarray(12);
  const key = await crypto.subtle.importKey(
    'raw',
    asBufferSource(base64UrlDecode(keyBase64))!,
    { name: 'AES-GCM' },
    false,
    ['decrypt'],
  );
  const plaintext = await crypto.subtle.decrypt(
    {
      name: 'AES-GCM',
      iv: asBufferSource(iv),
      additionalData: asBufferSource(associatedData),
      tagLength: 128,
    },
    key,
    asBufferSource(ciphertext)!,
  );
  return new Uint8Array(plaintext);
}
