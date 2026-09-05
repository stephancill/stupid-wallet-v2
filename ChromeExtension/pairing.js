import { z } from "zod";

export const pairingMessage = z.strictObject({
  type: z.enum(["pairing.status", "pairing.begin", "pairing.confirm", "pairing.revoke"]),
});
export function bytesToBase64(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)));
}
export function pairTranscript({ profile, nonce, publicKey }) {
  return new TextEncoder().encode(`stupid-wallet-pair-v1\n${profile}\n${nonce}\n${publicKey}`);
}
export function approvalTranscript({ profile, nonce, requestId, revision, bindingDigest }) {
  return new TextEncoder().encode(
    `stupid-wallet-approve-v1\n${profile}\n${nonce}\n${requestId}\n${revision}\n${bindingDigest}`,
  );
}
export async function pairingCode({ transcript }) {
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", transcript));
  return Array.from(hash.slice(0, 6))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("")
    .toUpperCase();
}
export async function signPairing({ key, message }) {
  return bytesToBase64(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, message));
}
let keyOperation;
export function pairingKeys({ create = false } = {}) {
  const operation = (keyOperation ?? Promise.resolve()).then(() => loadKeys({ create }));
  keyOperation = operation.catch(() => {});
  return operation;
}
async function loadKeys({ create }) {
  const db = await new Promise((resolve, reject) => {
    const request = indexedDB.open("stupid-wallet-pairing-v1", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("credentials");
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(new Error("Cannot open browser pairing storage."));
  });
  try {
    const stored = await new Promise((resolve, reject) => {
      const request = db.transaction("credentials").objectStore("credentials").get("keypair");
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(new Error("Cannot read browser pairing."));
    });
    if (stored !== undefined) {
      if (
        !(stored.privateKey instanceof CryptoKey) ||
        stored.privateKey.extractable ||
        stored.privateKey.type !== "private" ||
        stored.privateKey.algorithm.name !== "ECDSA" ||
        stored.privateKey.algorithm.namedCurve !== "P-256" ||
        !(stored.publicKey instanceof CryptoKey)
      ) {
        throw new Error("Browser pairing is corrupt. Clear extension data and pair again.");
      }
      return stored;
    }
    if (!create) return null;
    const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, [
      "sign",
      "verify",
    ]);
    await new Promise((resolve, reject) => {
      const transaction = db.transaction("credentials", "readwrite");
      transaction.objectStore("credentials").add(keys, "keypair");
      transaction.oncomplete = resolve;
      transaction.onabort = transaction.onerror = () =>
        reject(new Error("Cannot persist browser pairing."));
    });
    return keys;
  } finally {
    db.close();
  }
}
export async function publicPairingKey({ keys }) {
  return bytesToBase64(await crypto.subtle.exportKey("raw", keys.publicKey));
}
