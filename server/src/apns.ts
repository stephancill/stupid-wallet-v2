import { base64UrlDecode, base64UrlEncode, asBufferSource } from './crypto';

export type ApnsOutcome =
  | { outcome: 'accepted' }
  | { outcome: 'retry'; retryAfterSeconds?: number }
  | { outcome: 'unregistered' } // 410, token no longer valid for the current version
  | { outcome: 'token_failure' } // BadDeviceToken / DeviceTokenNotForTopic: unusable token
  | { outcome: 'provider_credential' }; // APNs provider auth failure: never delete device

export interface ApnsPayload {
  aps: {
    'mutable-content': 1;
    alert: { title: string };
    'thread-id': string;
  };
  eventId: string;
  addressRegistrationId: string;
  chainId: string;
  eventKind: string;
  schemaVersion: 1;
}

export const apnsEndpoint = (environment: 'development' | 'production'): string =>
  environment === 'development'
    ? 'https://api.sandbox.push.apple.com/3/device/'
    : 'https://api.push.apple.com/3/device/';

const encode = (object: object): string =>
  base64UrlEncode(new TextEncoder().encode(JSON.stringify(object)));

/** Sign a short-lived ES256 provider JWT from the .p8 private key (PKCS8 DER base64). */
export const providerJwt = async (
  privateKeyPkcs8Base64Url: string,
  keyId: string,
  teamId: string,
): Promise<string> => {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const header = { alg: 'ES256', kid: keyId, typ: 'JWT' };
  const claims = { iss: teamId, iat: nowSeconds, aud: 'api.push.apple.com' };
  const signingInput = `${encode(header)}.${encode(claims)}`;

  const privateKey = await crypto.subtle.importKey(
    'pkcs8',
    asBufferSource(base64UrlDecode(privateKeyPkcs8Base64Url))!,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' },
      privateKey,
      asBufferSource(new TextEncoder().encode(signingInput))!,
    ),
  );
  return `${signingInput}.${base64UrlEncode(signature)}`;
};

export interface ApnsCredentials {
  privateKeyPkcs8Base64Url: string;
  keyId: string;
  teamId: string;
  topic: string;
}

/** Send one alert/mutable push. Returns an outcome; never throws for APNs responses. */
export async function sendApnsPush(
  creds: ApnsCredentials,
  token: string,
  environment: 'development' | 'production',
  payload: ApnsPayload,
  fetchImpl: (url: string, init: RequestInit) => Promise<Response> = fetch,
): Promise<ApnsOutcome> {
  const jwt = await providerJwt(creds.privateKeyPkcs8Base64Url, creds.keyId, creds.teamId);

  let response: Response;
  try {
    response = await fetchImpl(`${apnsEndpoint(environment)}${encodeURIComponent(token)}`, {
      method: 'POST',
      headers: {
        authorization: `bearer ${jwt}`,
        'apns-topic': creds.topic,
        'apns-push-type': 'alert',
        'content-type': 'application/json',
      },
      body: JSON.stringify(payload),
    });
  } catch {
    // Transport failure: bounded retry.
    return { outcome: 'retry' };
  }

  if (response.status === 200) return { outcome: 'accepted' };
  if (response.status === 410) return { outcome: 'unregistered' };

  if (response.status === 429 || response.status >= 500) {
    const retryAfter = response.headers.get('retry-after');
    const parsed = retryAfter ? Number(retryAfter) : NaN;
    return {
      outcome: 'retry',
      retryAfterSeconds: Number.isFinite(parsed) ? parsed : undefined,
    };
  }

  const bodyText = await response.text();
  try {
    const body = JSON.parse(bodyText) as { reason?: string };
    if (body.reason === 'BadDeviceToken' || body.reason === 'DeviceTokenNotForTopic') {
      return { outcome: 'token_failure' };
    }
  } catch {
    // Non-JSON error body: transient misconfiguration, not device deletion.
  }
  return { outcome: 'provider_credential' };
}
