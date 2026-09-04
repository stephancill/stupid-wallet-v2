import { base64UrlDecode, asBufferSource } from './crypto';

const ECDSA_PARAMS: EcKeyImportParams = { name: 'ECDSA', namedCurve: 'P-256' };

/** Import a P-256 public key from its base64url SPKI DER representation. */
export const importSpkiPublicKey = async (spkiBase64Url: string): Promise<CryptoKey> => {
  try {
    return await crypto.subtle.importKey(
      'spki',
      asBufferSource(base64UrlDecode(spkiBase64Url))!,
      ECDSA_PARAMS,
      false,
      ['verify'],
    );
  } catch (error) {
    throw new Error(
      `invalid P-256 public key: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
};

/** Verify a P-256 ECDSA-SHA256 signature (R||S raw, base64url) over a message. */
export const verifyP256 = async (
  spkiBase64Url: string,
  signatureBase64Url: string,
  message: Uint8Array,
): Promise<boolean> => {
  const key = await importSpkiPublicKey(spkiBase64Url);
  const signature = base64UrlDecode(signatureBase64Url);
  return crypto.subtle.verify(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    asBufferSource(signature)!,
    asBufferSource(message)!,
  );
};
