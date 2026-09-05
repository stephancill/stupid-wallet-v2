import { z } from "zod";
import {
  pairingMessage,
  pairingKeys,
  publicPairingKey,
  pairTranscript,
  approvalTranscript,
  pairingCode,
  signPairing,
} from "./pairing.js";
// Loaded only by the Chrome artifact. The service worker owns the port, never the popup.
(() => {
  const api = globalThis.browser ?? globalThis.chrome;
  const HOST = "net.stupidtech.stupid_wallet";
  const VERSION = 3;
  const PROFILE_KEY = "nativeProfileId";
  let profilePromise;
  let connection;
  const decision = {
    requestId: z.uuid(),
    revision: z.number().int().min(0).max(Number.MAX_SAFE_INTEGER),
  };
  const popupSchema = z.discriminatedUnion("type", [
    z.strictObject({ type: z.literal("popup.list") }),
    z.strictObject({
      type: z.literal("popup.approve"),
      ...decision,
      bindingDigest: z.string().min(1).max(256),
    }),
    ...["popup.reject", "popup.connectAccounts"].map((type) =>
      z.strictObject({ type: z.literal(type), ...decision }),
    ),
    z.strictObject({
      type: z.literal("popup.rebindConnect"),
      ...decision,
      account: z.string().regex(/^0x[0-9a-fA-F]{40}$/),
    }),
    z.strictObject({ type: z.literal("popup.didDecide"), requestId: z.uuid() }),
  ]);
  const contextCheckSchema = z.strictObject({
    version: z.literal(3),
    id: z.uuid(),
    contextCheck: z.literal(true),
    requestId: z.uuid(),
    nonce: z.uuid(),
    revision: decision.revision,
    bindingDigest: z.string().min(1).max(256),
  });
  async function currentRoute(requestId) {
    const route = (await api.storage.local.get(`route:${requestId}`))[`route:${requestId}`];
    if (!route || route.profileId !== (await profileID())) return false;
    try {
      const [tab, frame] = await Promise.all([
        api.tabs.get(route.tabId),
        api.webNavigation.getFrame({ tabId: route.tabId, frameId: 0 }),
      ]);
      return (
        !tab.incognito &&
        frame?.documentId === route.documentId &&
        new URL(frame.url).origin === route.origin &&
        new URL(tab.url).origin === route.origin
      );
    } catch {
      return false;
    }
  }
  const failure = (message) => ({ ok: false, error: { code: 4900, message } });

  function profileID() {
    profilePromise ??= (async () => {
      const stored = (await api.storage.local.get(PROFILE_KEY))[PROFILE_KEY];
      if (stored !== undefined) {
        if (
          !/^chrome:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(
            stored,
          )
        ) {
          throw new Error(
            "Browser profile identity is invalid. Reinstall the extension to reconnect sites.",
          );
        }
        return stored;
      }
      const created = `chrome:${crypto.randomUUID()}`;
      await api.storage.local.set({ [PROFILE_KEY]: created });
      return created;
    })();
    return profilePromise;
  }

  async function connect() {
    const profileId = await profileID();
    const port = api.runtime.connectNative(HOST);
    const waiting = new Map();
    let closed = false;
    function close(message) {
      if (closed) return;
      closed = true;
      connection = undefined;
      for (const { resolve, timer } of waiting.values()) {
        clearTimeout(timer);
        resolve(failure(message));
      }
      waiting.clear();
      port.disconnect();
    }
    port.onDisconnect.addListener(() => {
      // Reading lastError prevents an unchecked runtime error; never include payloads in diagnostics.
      void api.runtime.lastError;
      close(
        "Stupid Wallet helper is unavailable. Install or repair the macOS helper package, then retry.",
      );
    });
    port.onMessage.addListener(async (frame) => {
      if (frame?.contextCheck === true) {
        const parsed = contextCheckSchema.safeParse(frame);
        const owner = waiting.get(frame.id);
        if (
          !parsed.success ||
          owner?.message?.action !== "approve" ||
          owner.message.payload?.requestId !== frame.requestId ||
          owner.message.payload?.revision !== frame.revision ||
          owner.message.payload?.bindingDigest !== frame.bindingDigest
        ) {
          close("Invalid native review context check.");
          return;
        }
        let valid = await currentRoute(frame.requestId);
        let signature = "";
        if (valid) {
          try {
            const keys = await pairingKeys();
            if (!keys) throw new Error("Pairing required");
            signature = await signPairing({
              key: keys.privateKey,
              message: approvalTranscript({ profile: profileId, ...parsed.data }),
            });
            valid = await currentRoute(frame.requestId);
          } catch {
            valid = false;
          }
        }
        if (!closed)
          port.postMessage({
            version: VERSION,
            id: crypto.randomUUID(),
            profileId,
            message: {
              action: "contextResult",
              payload: {
                requestId: frame.requestId,
                nonce: frame.nonce,
                valid,
                signature: valid ? signature : "",
              },
            },
          });
        return;
      }
      if (
        !frame ||
        frame.version !== VERSION ||
        typeof frame.id !== "string" ||
        !frame.response ||
        typeof frame.response.ok !== "boolean"
      ) {
        close(
          "Stupid Wallet helper protocol is incompatible. Update the extension and helper together.",
        );
        return;
      }
      const request = waiting.get(frame.id);
      if (!request) {
        close("Stupid Wallet helper returned an unexpected response.");
        return;
      }
      waiting.delete(frame.id);
      clearTimeout(request.timer);
      request.resolve(frame.response);
    });
    function request(message) {
      if (closed)
        return Promise.resolve(failure("Stupid Wallet helper disconnected. Retry the request."));
      return new Promise((resolve) => {
        const id = crypto.randomUUID();
        const timer = setTimeout(
          () =>
            close("Stupid Wallet helper timed out. Reopen the review to check its durable status."),
          180000,
        );
        waiting.set(id, { resolve, timer, message });
        try {
          port.postMessage({ version: VERSION, id, profileId, message });
        } catch {
          close("Stupid Wallet helper could not receive the request.");
        }
      });
    }
    const hello = await request({ action: "hello" });
    if (!hello.ok || hello.data?.protocolVersion !== VERSION) {
      close(
        "Stupid Wallet helper protocol is incompatible. Update the extension and helper together.",
      );
      throw new Error(hello.error?.message || "Stupid Wallet helper protocol is incompatible.");
    }
    return request;
  }

  globalThis.walletNativeTransport = async (message) => {
    try {
      connection ??= connect();
      const request = await connection;
      // The native chain is authoritative; a browser hint is never part of the Chrome schema.
      const { chainId: _chainHint, ...canonical } = message;
      return await request(canonical);
    } catch (error) {
      connection = undefined;
      return failure(error.message || "Stupid Wallet helper is unavailable.");
    }
  };

  let pairingAttempt;
  api.runtime.onMessage?.addListener((message, sender, respond) => {
    if (!message?.type?.startsWith("pairing.")) return;
    (async () => {
      if (
        sender.id !== api.runtime.id ||
        sender.incognito ||
        sender.tab?.incognito ||
        ![api.runtime.getURL("pairing.html"), api.runtime.getURL("popup.html")].includes(sender.url)
      ) {
        throw new Error("Pairing is only available in wallet setup.");
      }
      pairingMessage.parse(message);
      if (message.type !== "pairing.status" && sender.url !== api.runtime.getURL("pairing.html")) {
        throw new Error("Open wallet setup to manage pairing.");
      }
      const native = globalThis.walletNativeTransport;
      const profile = await profileID();
      if (message.type === "pairing.status") {
        const response = await native({ action: "pairStatus" });
        if (!response.ok) return response;
        const keys = await pairingKeys();
        return {
          ok: true,
          paired: !!keys && response.data.publicKey === (await publicPairingKey({ keys })),
        };
      }
      if (message.type === "pairing.begin") {
        const keys = await pairingKeys({ create: true });
        const publicKey = await publicPairingKey({ keys });
        const response = await native({ action: "pairBegin", publicKey });
        if (!response.ok) return response;
        const nonce = z.uuid().parse(response.data.nonce);
        const transcript = pairTranscript({ profile, nonce, publicKey });
        pairingAttempt = { nonce, transcript, keys };
        return { ok: true, code: await pairingCode({ transcript }) };
      }
      if (message.type === "pairing.confirm") {
        const attempt = pairingAttempt;
        pairingAttempt = undefined;
        if (!attempt) throw new Error("Start pairing again.");
        return await native({
          action: "pairConfirm",
          nonce: attempt.nonce,
          signature: await signPairing({
            key: attempt.keys.privateKey,
            message: attempt.transcript,
          }),
        });
      }
      pairingAttempt = undefined;
      return await native({ action: "pairRevoke" });
    })().then(respond, () =>
      respond({ ok: false, error: { message: "Pairing failed. Reopen setup and try again." } }),
    );
    return true;
  });

  globalThis.walletChromeContext = {
    async validate(message, sender) {
      if (sender?.id !== api.runtime.id || sender.incognito || sender.tab?.incognito) {
        throw new Error("This browser context is not supported. Incognito is disabled.");
      }
      if (message?.type?.startsWith("popup.")) {
        if (sender.tab || sender.url !== api.runtime.getURL("popup.html")) {
          throw new Error("Only the extension toolbar can review requests.");
        }
        popupSchema.parse(message);
        if (
          ["popup.approve", "popup.rebindConnect", "popup.connectAccounts"].includes(
            message.type,
          ) &&
          !(await currentRoute(message.requestId))
        ) {
          throw new Error(
            "The requesting tab navigated or closed. Request again from the current page.",
          );
        }
        return;
      }
      if (
        !Number.isInteger(sender.tab?.id) ||
        sender.frameId !== 0 ||
        typeof sender.documentId !== "string" ||
        typeof sender.origin !== "string"
      ) {
        throw new Error("A trusted top-level browser sender is required.");
      }
      const url = new URL(sender.url);
      if (
        !["http:", "https:"].includes(url.protocol) ||
        url.origin !== sender.origin ||
        new URL(sender.tab.url).origin !== sender.origin
      ) {
        throw new Error("The requesting tab origin changed.");
      }
    },
    async remember(requestId, sender) {
      const existing = (await api.storage.local.get(`route:${requestId}`))[`route:${requestId}`];
      await api.storage.local.set({
        [`route:${requestId}`]: {
          tabId: sender.tab.id,
          documentId: sender.documentId,
          origin: sender.origin,
          profileId: await profileID(),
        },
      });
      if (!existing) await this.openReview({ requestId, tabId: sender.tab.id });
    },
    async openReview({ requestId, tabId }) {
      if (!api.action?.openPopup) return;
      try {
        const tab = await api.tabs.get(tabId);
        if (!tab.active || !(await currentRoute(requestId))) return;
        const window = await api.windows.get(tab.windowId);
        if (!window.focused) return;
        await api.action.openPopup({ windowId: tab.windowId });
      } catch {
        // Presentation failure must not discard an already-persisted approval request.
        console.warn("Automatic wallet review could not open. Use the wallet toolbar button.");
      }
    },
    async owns(requestId, sender) {
      const route = (await api.storage.local.get(`route:${requestId}`))[`route:${requestId}`];
      if (
        !route ||
        route.profileId !== (await profileID()) ||
        route.tabId !== sender.tab.id ||
        route.documentId !== sender.documentId ||
        route.origin !== sender.origin
      )
        return false;
      const tab = await api.tabs.get(route.tabId);
      return (
        !tab.incognito &&
        new URL(tab.url).origin === route.origin &&
        (await currentRoute(requestId))
      );
    },
    async forget(requestId) {
      await api.storage.local.remove(`route:${requestId}`);
    },
  };
  async function invalidateTab(tabId, documentId) {
    const entries = await api.storage.local.get(null);
    for (const [key, route] of Object.entries(entries)) {
      if (
        !key.startsWith("route:") ||
        route.tabId !== tabId ||
        (documentId && route.documentId === documentId)
      )
        continue;
      await api.storage.local.remove(key);
      await globalThis.walletNativeTransport({
        action: "invalidate",
        payload: { requestId: key.slice(6) },
      });
    }
  }
  api.webNavigation.onCommitted.addListener((event) => {
    if (event.frameId === 0) void invalidateTab(event.tabId, event.documentId);
  });
  api.tabs.onRemoved.addListener((tabId) => {
    void invalidateTab(tabId);
  });
})();
