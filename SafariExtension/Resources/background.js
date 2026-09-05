// Stupid Wallet service worker (background script).
// Owns method classification, prepares native approval requests, and mirrors
// page-side pending requests into Safari's toolbar badge.
(() => {
  const NATIVE_APP_ID = "co.za.stephancill.stupid-wallet";
  const pending = new Set();

  // Method kinds that require the native approval surface. Network switching is handled
  // immediately below after native authorization; adding a chain still requires review.
  const APPROVAL_METHODS = new Set([
    "eth_requestaccounts",
    "wallet_connect",
    "personal_sign",
    "eth_signtypeddata_v4",
    "eth_sendtransaction",
    "wallet_sendcalls",
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

  function native({ action, method, params, origin, chainId, requestKey, payload } = {}) {
    const message = { action };
    if (method !== undefined) message.method = method;
    if (params !== undefined) message.params = params;
    if (origin !== undefined) message.origin = origin;
    if (chainId !== undefined) message.chainId = chainId;
    if (requestKey !== undefined) message.requestKey = requestKey;
    if (payload !== undefined) message.payload = payload;
    if (globalThis.walletNativeTransport) return globalThis.walletNativeTransport(message);
    return new Promise((resolve) => {
      browser.runtime.sendNativeMessage(NATIVE_APP_ID, message, (response) => {
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

  function updateBadge() {
    setBadge(pending.size === 0 ? "" : String(pending.size));
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

  function tabOrigin(tab) {
    if (!tab || typeof tab.url !== "string") return null;
    try {
      return new URL(tab.url).origin;
    } catch {
      return null;
    }
  }

  function publishAccountRefresh(origin) {
    browser.tabs.query({}, (tabs) => {
      for (const tab of tabs || []) {
        if (tab.id === undefined || tabOrigin(tab) !== origin) continue;
        browser.tabs.sendMessage(tab.id, {
          type: "wallet.refreshAccounts",
        });
      }
    });
  }

  async function accountState(origin) {
    const visible = await native({ action: "visibleAccounts", origin });
    if (!visible.ok || !visible.data || !Array.isArray(visible.data.accounts)) return null;
    return visible.data.accounts;
  }

  async function broadcastChainChanged() {
    const chain = await activeChain();
    if (chain) publishChain(chain);
  }

  let popupContext;
  function requirePopup(sender) {
    if (sender?.url !== browser.runtime.getURL("popup.html") || sender.tab || sender.incognito) {
      throw new Error("Connection controls are only available in the wallet popup.");
    }
  }
  async function pageSnapshot() {
    const tabs = await new Promise((resolve) =>
      browser.tabs.query({ active: true, currentWindow: true }, resolve),
    );
    const tab = tabs?.[0];
    const origin = tabOrigin(tab);
    if (!Number.isInteger(tab?.id) || tab.incognito || !origin || !/^https?:\/\//.test(origin)) {
      throw new Error("Open a web page to manage its wallet connection.");
    }
    const document = await browser.tabs.sendMessage(
      tab.id,
      { type: "wallet.documentContext" },
      { frameId: 0 },
    );
    if (!/^[0-9a-f]{32}$/.test(document?.token))
      throw new Error("Reload this page to manage its wallet connection.");
    const chromeSender = globalThis.walletChromeContext
      ? await globalThis.walletChromeContext.pageSender(tab)
      : null;
    return { tabId: tab.id, origin, documentToken: document.token, chromeSender };
  }
  async function reviewedPage(contextId) {
    const expected = popupContext;
    if (!expected || expected.contextId !== contextId)
      throw new Error("Reopen the wallet popup to refresh this page.");
    const current = await pageSnapshot();
    if (
      current.tabId !== expected.tabId ||
      current.origin !== expected.origin ||
      current.documentToken !== expected.documentToken ||
      current.chromeSender?.documentId !== expected.chromeSender?.documentId
    ) {
      throw new Error("The page changed. Reopen the wallet popup.");
    }
    return expected;
  }
  function requireNative(reply) {
    if (!reply?.ok || !reply.data)
      throw new Error(reply?.error?.message || reply?.error || "Wallet request failed");
    return reply.data;
  }
  async function manageConnection(message, sender) {
    requirePopup(sender);
    if (message.type === "popup.siteAccounts") {
      const page = await pageSnapshot();
      const contextId = crypto.randomUUID();
      popupContext = { ...page, contextId };
      const state = requireNative(await native({ action: "siteAccounts", origin: page.origin }));
      await reviewedPage(contextId);
      return { ok: true, data: { ...state, origin: page.origin, contextId } };
    }
    if (typeof message.account !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(message.account)) {
      throw new Error("Choose a valid wallet account.");
    }
    const page = await reviewedPage(message.contextId);
    if (message.type === "popup.disconnectAccount") {
      requireNative(
        await native({
          action: "disconnectReviewed",
          origin: page.origin,
          payload: { account: message.account },
        }),
      );
      publishAccountRefresh(page.origin);
      return { ok: true };
    }
    // The chosen account and displayed page are the popup's connection approval. Native
    // still prepares/rebinds a canonical request and verifies the paired Chrome proof.
    let summary;
    let requestId;
    let completed = false;
    try {
      const prepared = requireNative(
        await native({
          action: "prepare",
          method: "eth_requestAccounts",
          params: [],
          origin: page.origin,
        }),
      );
      requestId = prepared.requestId;
      summary = requireNative(await native({ action: "summary", payload: { requestId } }));
      if (!summary || summary.queued)
        throw new Error("Handle the pending request before switching accounts.");
      const rebound = requireNative(
        await native({
          action: "rebindConnect",
          payload: { requestId, revision: summary.revision, account: message.account },
        }),
      );
      summary = rebound.summary;
      if (
        !summary ||
        summary.kind !== "connect" ||
        summary.origin !== page.origin ||
        summary.account.toLowerCase() !== message.account.toLowerCase()
      )
        throw new Error("Connection review changed.");
      await reviewedPage(message.contextId);
      if (globalThis.walletChromeContext)
        await globalThis.walletChromeContext.remember(requestId, page.chromeSender, {
          open: false,
        });
      requireNative(
        await native({
          action: "approve",
          payload: {
            requestId,
            revision: summary.revision,
            bindingDigest: summary.bindingDigest,
          },
        }),
      );
      completed = true;
      publishAccountRefresh(page.origin);
      return { ok: true };
    } finally {
      if (requestId && !completed) {
        if (!summary) summary = (await native({ action: "summary", payload: { requestId } }))?.data;
        if (summary)
          await native({ action: "reject", payload: { requestId, revision: summary.revision } });
      }
      if (requestId && globalThis.walletChromeContext)
        await globalThis.walletChromeContext.forget(requestId);
    }
  }

  browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    handle(message, sender, sendResponse);
    return true; // keep the channel open; we respond asynchronously
  });

  async function handle(message, sender, sendResponse) {
    try {
      if (globalThis.walletChromeContext)
        await globalThis.walletChromeContext.validate(message, sender);
      if (
        ["popup.siteAccounts", "popup.switchAccount", "popup.disconnectAccount"].includes(
          message?.type,
        )
      ) {
        sendResponse(await manageConnection(message, sender));
        return;
      }
      switch (message.type) {
        case "ethereum.request":
          return await route(message, sender, sendResponse);
        case "ethereum.status":
          return await status(message, sender, sendResponse);
        case "wallet.getChain": {
          const chain = await activeChain();
          sendResponse(chain || { error: "Active chain unavailable" });
          return;
        }
        case "wallet.getAccounts": {
          const accounts = await accountState(originFrom(sender));
          sendResponse(accounts ? { accounts } : { error: "Account state unavailable" });
          return;
        }
        case "popup.list":
          // Read the durable native store (survives worker suspension).
          const nativeList = await native({ action: "list" });
          sendResponse(
            globalThis.walletChromeContext
              ? nativeList
              : nativeList.ok && nativeList.data
                ? nativeList.data.pending
                : [],
          );
          return;
        case "popup.approve":
          const approved = await native({
            action: "approve",
            payload: { requestId: message.requestId, revision: message.revision },
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
            payload: { requestId: message.requestId, revision: message.revision },
          });
          if (rejected.ok) {
            pending.delete(message.requestId);
            updateBadge();
          }
          sendResponse(
            rejected.ok ? { ok: true } : { ok: false, error: rejected.error || "rejection failed" },
          );
          return;
        case "popup.connectAccounts":
          sendResponse(
            await native({
              action: "connectAccounts",
              payload: { requestId: message.requestId, revision: message.revision },
            }),
          );
          return;
        case "popup.rebindConnect":
          sendResponse(
            await native({
              action: "rebindConnect",
              payload: {
                requestId: message.requestId,
                revision: message.revision,
                account: message.account,
              },
            }),
          );
          return;
        case "popup.didDecide":
          pending.delete(message.requestId);
          updateBadge();
          sendResponse({ ok: true });
          return;
        default:
          sendResponse({ error: { code: -32601, message: "Unknown background message" } });
      }
    } catch (error) {
      const detail = { code: -32603, message: String(error) };
      if (globalThis.walletChromeContext && message?.type === "ethereum.request") {
        envelope(sendResponse, { ok: false, error: detail });
      } else if (globalThis.walletChromeContext && message?.type === "ethereum.status") {
        sendResponse({ __error: detail.message, code: detail.code });
      } else {
        sendResponse({ error: detail });
      }
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
      const accounts = await accountState(pageOrigin);
      envelope(sendResponse, {
        ok: true,
        result: accounts || [],
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
      if (dis.ok && dis.data && dis.data.ok === true) {
        publishAccountRefresh(pageOrigin);
        envelope(sendResponse, { ok: true, result: true });
        return;
      }
      const disconnectError = dis && dis.error;
      envelope(sendResponse, {
        ok: false,
        error:
          disconnectError && typeof disconnectError === "object"
            ? disconnectError
            : { code: 4900, message: String(disconnectError || "Disconnect failed") },
      });
      return;
    }

    if (method === "wallet_getcapabilities" || method === "wallet_getcallsstatus") {
      const response = await native({
        action: method === "wallet_getcapabilities" ? "getCapabilities" : "getCallsStatus",
        params: message.params ?? [],
        origin: pageOrigin,
      });
      if (response.ok && response.data) {
        envelope(sendResponse, { ok: true, result: response.data.result });
        return;
      }
      const readError = response && response.error;
      envelope(sendResponse, {
        ok: false,
        error:
          readError && typeof readError === "object"
            ? readError
            : { code: -32603, message: String(readError || "Wallet read failed") },
      });
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
    const capabilities = message.params?.[0]?.capabilities;
    const hasCapabilities =
      capabilities && typeof capabilities === "object" && Object.keys(capabilities).length > 0;
    if (method === "eth_requestaccounts" || (method === "wallet_connect" && !hasCapabilities)) {
      const accounts = await accountState(pageOrigin);
      if (accounts && accounts.length > 0) {
        envelope(sendResponse, {
          ok: true,
          result: accounts,
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
        requestKey:
          typeof message.requestKey === "string" && message.requestKey.length <= 128
            ? message.requestKey
            : undefined,
        method: message.method,
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
      if (globalThis.walletChromeContext)
        await globalThis.walletChromeContext.remember(requestId, sender);
      pending.add(requestId);
      updateBadge();
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

  // Polled by the bridge: mirrors the persisted native status. This is a stateless
  // read on each poll, so a suspending service worker never loses the answer.
  async function status(message, sender, sendResponse) {
    if (
      globalThis.walletChromeContext &&
      !(await globalThis.walletChromeContext.owns(message.id, sender))
    ) {
      sendResponse({ __error: "Request does not belong to this page", code: 4100 });
      return;
    }
    const res = await native({ action: "get", payload: { requestId: message.id } });
    if (!res.ok || !res.data) {
      pending.delete(message.id);
      updateBadge();
      sendResponse({ __missing: true });
      return;
    }
    if (
      ["consumed", "rejected", "failed", "expired"].includes(res.data.status) &&
      globalThis.walletChromeContext
    ) {
      await globalThis.walletChromeContext.forget(message.id);
    }
    if (res.data.status === "consumed" || res.data.status === "rejected") {
      pending.delete(message.id);
      updateBadge();
    }
    if (res.data.status === "consumed") {
      const summary = await native({ action: "summary", payload: { requestId: message.id } });
      if (summary.ok && summary.data) {
        const method = summary.data.method.toLowerCase();
        if (method === "wallet_switchethereumchain") await broadcastChainChanged();
        if (method === "eth_requestaccounts" || method === "wallet_connect") {
          publishAccountRefresh(originFrom(sender));
        }
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
      updateBadge();
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
      updateBadge();
      sendResponse({ __error: "Request expired", code: 4001 });
      return;
    }
    sendResponse({ __pending: true });
  }
})();
