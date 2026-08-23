// Stupid Wallet service worker (background script).
// Owns method classification, prepares native approval requests, and routes
// completion back to the requesting tab once the popup resolves the request.
(() => {
  const pending = new Map(); // requestId -> { sendResponse }

  // Method kinds that require the native approval surface. Network switching is handled
  // immediately below after native authorization; adding a chain still requires review.
  const APPROVAL_METHODS = new Set([
    "eth_requestaccounts",
    "wallet_connect",
    "personal_sign",
    "eth_signtypeddata_v4",
    "eth_sendtransaction",
    "eth_addethereumchain",
    "wallet_addethereumchain",
    // Explicitly unsafe and intentionally unsupported:
    "eth_sign",
    "eth_signtransaction",
    "eth_signtypeddata",
    "eth_signtypeddata_v1",
    "eth_signtypeddata_v3",
  ]);
  // These never reach an approval surface; they are unsupported on purpose.
  const DENIED_METHODS = new Set([
    "eth_sign",
    "eth_signtransaction",
    "eth_signtypeddata",
    "eth_signtypeddata_v1",
    "eth_signtypeddata_v3",
  ]);
  function originFrom(sender) {
    if (sender && sender.origin) return sender.origin;
    if (sender && sender.tab && sender.tab.url) {
      try {
        return new URL(sender.tab.url).origin;
      } catch {
        /* ignore */
      }
    }
    return "unknown";
  }

  function native({ action, method, params, origin, chainId, payload } = {}) {
    const message = { action };
    if (method !== undefined) message.method = method;
    if (params !== undefined) message.params = params;
    if (origin !== undefined) message.origin = origin;
    if (chainId !== undefined) message.chainId = chainId;
    if (payload !== undefined) message.payload = payload;
    return new Promise((resolve) => {
      browser.runtime.sendNativeMessage(undefined, message, (response) => {
        if (browser.runtime.lastError) {
          resolve({ ok: false, error: String(browser.runtime.lastError.message) });
        } else {
          resolve(response || { ok: false, error: "no native response" });
        }
      });
    });
  }

  function setBadge(text) {
    try {
      browser.action.setBadgeText({ text });
    } catch {
      /* ignore */
    }
  }

  async function activeChain() {
    const response = await native({ action: "chain" });
    if (!response.ok || !response.data) return null;
    if (response.data.recoveredSwitch) publishChain(response.data);
    return response.data;
  }

  function publishChain(chain) {
    browser.tabs.query({}, (tabs) => {
      for (const tab of tabs || []) {
        if (tab.id === undefined) continue;
        browser.tabs.sendMessage(tab.id, {
          type: "wallet.chainChanged",
          chainIdHex: chain.chainIdHex,
        });
      }
    });
  }

  async function broadcastChainChanged() {
    const chain = await activeChain();
    if (chain) publishChain(chain);
  }

  browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    handle(message, sender, sendResponse);
    return true; // keep the channel open; we respond asynchronously
  });

  async function handle(message, sender, sendResponse) {
    try {
      switch (message.type) {
        case "ethereum.request":
          return await route(message, sender, sendResponse);
        case "ethereum.status":
          return await status(message, sendResponse);
        case "wallet.getChain": {
          const chain = await activeChain();
          sendResponse(chain || { error: "Active chain unavailable" });
          return;
        }
        case "popup.getPending":
          return getPending(sendResponse);
        case "popup.list":
          // Read the durable native store (survives worker suspension).
          const nativeList = await native({ action: "list" });
          sendResponse(nativeList.ok && nativeList.data ? nativeList.data.pending : []);
          return;
        case "popup.approve":
          const approved = await native({
            action: "approve",
            payload: { requestId: message.requestId },
          });
          if (approved.ok && approved.data) {
            sendResponse({ ok: true, result: approved.data.result });
          } else {
            sendResponse({
              ok: false,
              error: approved.error || "approval failed",
              code: (approved.error && approved.error.code) || undefined,
            });
          }
          return;
        case "popup.reject":
          const rejected = await native({
            action: "reject",
            payload: { requestId: message.requestId },
          });
          sendResponse({ ok: !!rejected.ok });
          return;
        case "popup.resolve": {
          const entry = pending.get(message.requestId);
          if (!entry) {
            sendResponse({ ok: false, error: "no matching pending request" });
            return;
          }
          entry.sendResponse(message.result);
          pending.delete(message.requestId);
          setBadge(String(pending.size));
          sendResponse({ ok: true });
          return;
        }
        case "popup.reject-all":
          for (const entry of pending.values()) {
            entry.sendResponse({ error: { code: 4001, message: "User dismissed" } });
          }
          pending.clear();
          setBadge("");
          sendResponse({ ok: true });
          return;
        default:
          sendResponse({ error: { code: -32601, message: "Unknown background message" } });
      }
    } catch (error) {
      sendResponse({ error: { code: -32603, message: String(error) } });
    }
  }

  // The worker always replies to the bridge with a stable envelope so the bridge never
  // guesses success vs failure. `result` preserves any JSON value, `error` carries only
  // a structured EIP-1193 error (`{ code, message, data? }`).
  function envelope(sendResponse, value) {
    sendResponse({ __envelope: true, ...value });
  }

  async function route(message, sender, sendResponse) {
    const method = (message.method || "").toLowerCase();
    const pageOrigin = originFrom(sender);

    // Wallet-owned read that reflects the connection grant. eth_chainId / net_version
    // resolve locally with the injected account/active chain.
    if (method === "eth_accounts") {
      const me = await native({ action: "me" });
      const connected = await native({ action: "isConnected", origin: pageOrigin });
      envelope(sendResponse, {
        ok: true,
        result:
          me.ok && connected.ok && connected.data && connected.data.connected
            ? [me.data.account]
            : [],
      });
      return;
    }
    if (method === "eth_chainid") {
      const chain = await activeChain();
      envelope(
        sendResponse,
        chain
          ? { ok: true, result: chain.chainIdHex }
          : { ok: false, error: { code: -32603, message: "Active chain unavailable" } },
      );
      return;
    }
    if (method === "net_version") {
      const chain = await activeChain();
      envelope(
        sendResponse,
        chain
          ? { ok: true, result: chain.chainId }
          : { ok: false, error: { code: -32603, message: "Active chain unavailable" } },
      );
      return;
    }

    // Explicitly unsafe signing methods are always denied with EIP-1193 4200 and
    // never reach authentication or signing.
    if (DENIED_METHODS.has(method)) {
      envelope(sendResponse, {
        ok: false,
        error: { code: 4200, message: "Method not supported by stupid wallet" },
      });
      return;
    }

    // wallet_disconnect revokes the origin's durable connection grant.
    if (method === "wallet_disconnect") {
      const dis = await native({ action: "disconnectSite", origin: pageOrigin });
      envelope(sendResponse, { ok: true, result: dis.ok === true });
      return;
    }

    // An authorized origin may switch the wallet's active chain immediately. Native code
    // validates the standard params and serializes the persistent state change; no popup
    // approval or keychain authentication is involved.
    if (method === "wallet_switchethereumchain") {
      const switched = await native({
        action: "switchChain",
        params: message.params,
        origin: pageOrigin,
      });
      if (switched.ok && switched.data) {
        await broadcastChainChanged();
        envelope(sendResponse, { ok: true, result: switched.data.result });
        return;
      }
      const switchError = switched && switched.error;
      envelope(sendResponse, {
        ok: false,
        error:
          switchError && typeof switchError === "object"
            ? switchError
            : { code: -32603, message: String(switchError || "Network switch failed") },
      });
      return;
    }

    // eth_requestAccounts / wallet_connect: if this origin already holds a grant for the
    // active account, resolve immediately without a new approval card / queue entry.
    if (method === "eth_requestaccounts" || method === "wallet_connect") {
      const connected = await native({ action: "isConnected", origin: pageOrigin });
      if (connected.ok && connected.data && connected.data.connected) {
        const me = await native({ action: "me" });
        envelope(sendResponse, {
          ok: true,
          result: me.ok && me.data ? [me.data.account] : [],
        });
        return;
      }
    }

    // Connect / signing / sending / add-chain methods are canonical approvals.
    if (APPROVAL_METHODS.has(method)) {
      const chain = await activeChain();
      if (!chain) {
        envelope(sendResponse, {
          ok: false,
          error: { code: -32603, message: "Active chain unavailable" },
        });
        return;
      }
      const prepared = await native({
        action: "prepare",
        method,
        params: message.params,
        origin: pageOrigin,
        chainId: chain.chainId,
      });
      if (!prepared.ok) {
        const code = (prepared.error && prepared.error.code) || 4001;
        const msg =
          (prepared.error && prepared.error.message) || String(prepared.error || "approval failed");
        envelope(sendResponse, {
          ok: false,
          error: { code, message: msg, data: prepared.error && prepared.error.data },
        });
        return;
      }
      const requestId = prepared.data.requestId;
      pending.set(requestId, { sendResponse });
      setBadge(String(pending.size));
      // Hand the requestId to the bridge immediately; the bridge then polls the
      // native store for the result, so completion survives worker suspension.
      envelope(sendResponse, { ok: true, pendingId: requestId });
      return;
    }

    // Generic passthrough: forward every other method unchanged to the active RPC
    // through the single native resolver. Node results and structured errors return
    // untouched.
    const chain = await activeChain();
    if (!chain) {
      envelope(sendResponse, {
        ok: false,
        error: { code: -32603, message: "Active chain unavailable" },
      });
      return;
    }
    const passthrough = await native({
      action: "passthrough",
      method: message.method,
      params: message.params ?? [],
      origin: originFrom(sender),
      chainId: chain.chainId,
    });
    if (passthrough.ok && passthrough.data && passthrough.data.result !== undefined) {
      envelope(sendResponse, { ok: true, result: passthrough.data.result });
      return;
    }
    const nodeError = passthrough ? passthrough.error : { code: -32603, message: "no response" };
    let e;
    if (nodeError && typeof nodeError === "object" && nodeError.code !== undefined) {
      e = nodeError;
    } else {
      e = { code: -32603, message: String(nodeError) };
    }
    envelope(sendResponse, { ok: false, error: e });
  }

  function getPending(sendResponse) {
    const ids = Array.from(pending.keys());
    Promise.all(
      ids.map((requestId) =>
        native({ action: "summary", payload: { requestId } }).then((summary) => ({
          requestId,
          ok: summary.ok,
          data: summary.data || null,
          error: summary.error || null,
        })),
      ),
    ).then((list) => sendResponse({ pending: list }));
  }

  // Polled by the bridge: mirrors the persisted native status. This is a stateless
  // read on each poll, so a suspending service worker never loses the answer.
  async function status(message, sendResponse) {
    const res = await native({ action: "get", payload: { requestId: message.id } });
    if (!res.ok || !res.data) {
      pending.delete(message.id);
      setBadge(String(pending.size));
      sendResponse({ __missing: true });
      return;
    }
    if (res.data.status === "consumed" || res.data.status === "rejected") {
      pending.delete(message.id);
      setBadge(String(pending.size));
    }
    if (res.data.status === "consumed") {
      const summary = await native({ action: "summary", payload: { requestId: message.id } });
      if (
        summary.ok &&
        summary.data &&
        summary.data.method.toLowerCase() === "wallet_switchethereumchain"
      ) {
        await broadcastChainChanged();
      }
      sendResponse({ __resolved: true, result: res.data.result });
      return;
    }
    if (res.data.status === "rejected") {
      sendResponse({ __error: "User rejected", code: 4001 });
      return;
    }
    if (res.data.status === "failed") {
      pending.delete(message.id);
      setBadge(String(pending.size));
      const error = res.data.error || {};
      sendResponse({
        __error: error.message || "Transaction submission failed",
        code: error.code || -32603,
        data: error.data,
      });
      return;
    }
    if (res.data.status === "expired") {
      pending.delete(message.id);
      setBadge(String(pending.size));
      sendResponse({ __error: "Request expired", code: 4001 });
      return;
    }
    sendResponse({ __pending: true });
  }
})();
