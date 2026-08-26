import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const backgroundSource = await readFile(
  new URL("../../SafariExtension/Resources/background.js", import.meta.url),
  "utf8",
);

test("native messages identify the containing app on macOS Safari", async () => {
  let messageListener;
  const nativeMessages = [];
  const browser = {
    action: { setBadgeText() {} },
    runtime: {
      lastError: null,
      onMessage: {
        addListener(listener) {
          messageListener = listener;
        },
      },
      sendNativeMessage(applicationID, message, callback) {
        nativeMessages.push({ applicationID, message });
        callback({
          ok: true,
          data: { chainId: "1", chainIdHex: "0x1", recoveredSwitch: false },
        });
      },
    },
    tabs: {
      query(_query, callback) {
        callback([]);
      },
      sendMessage() {},
    },
  };

  vm.runInNewContext(backgroundSource, { browser, Map, Promise, Set, URL });

  const response = await new Promise((resolve) => {
    assert.equal(messageListener({ type: "wallet.getChain" }, {}, resolve), true);
  });

  assert.equal(response.chainIdHex, "0x1");
  assert.equal(nativeMessages.length, 1);
  assert.equal(nativeMessages[0].applicationID, "co.za.stephancill.stupid-wallet");
  assert.equal(nativeMessages[0].message.action, "chain");
});

test("a popup decision removes its request and clears the zero badge", async () => {
  let messageListener;
  const badgeTexts = [];
  const browser = {
    action: {
      setBadgeText({ text }) {
        badgeTexts.push(text);
      },
    },
    runtime: {
      lastError: null,
      onMessage: {
        addListener(listener) {
          messageListener = listener;
        },
      },
      sendNativeMessage(_applicationID, message, callback) {
        if (message.action === "chain") {
          callback({
            ok: true,
            data: { chainId: "8453", chainIdHex: "0x2105", recoveredSwitch: false },
          });
        } else if (message.action === "prepare") {
          assert.equal(message.requestKey, "provider-session:1");
          callback({ ok: true, data: { requestId: "request-1" } });
        } else {
          callback({ ok: false, error: "unexpected native action" });
        }
      },
    },
    tabs: {
      query(_query, callback) {
        callback([]);
      },
      sendMessage() {},
    },
  };

  vm.runInNewContext(backgroundSource, { browser, Map, Promise, Set, URL });

  const prepared = await new Promise((resolve) => {
    messageListener(
      {
        type: "ethereum.request",
        requestKey: "provider-session:1",
        method: "personal_sign",
        params: ["0x01"],
      },
      { origin: "https://example.com" },
      resolve,
    );
  });
  assert.equal(prepared.pendingId, "request-1");
  assert.equal(badgeTexts.at(-1), "1");

  const decided = await new Promise((resolve) => {
    messageListener({ type: "popup.didDecide", requestId: "request-1" }, {}, resolve);
  });
  assert.equal(decided.ok, true);
  assert.equal(badgeTexts.at(-1), "");
});

test("popup fallback forwards reviewed revisions and connect rebind payloads", async () => {
  let messageListener;
  const nativeMessages = [];
  const browser = {
    action: { setBadgeText() {} },
    runtime: {
      lastError: null,
      onMessage: {
        addListener(listener) {
          messageListener = listener;
        },
      },
      sendNativeMessage(_applicationID, message, callback) {
        nativeMessages.push(message);
        callback({ ok: true, data: {} });
      },
    },
    tabs: {
      query(_query, callback) {
        callback([]);
      },
      sendMessage() {},
    },
  };
  vm.runInNewContext(backgroundSource, { browser, Map, Promise, Set, URL });

  for (const message of [
    { type: "popup.approve", requestId: "request-1", revision: 2 },
    { type: "popup.reject", requestId: "request-1", revision: 2 },
    { type: "popup.connectAccounts", requestId: "request-1", revision: 2 },
    {
      type: "popup.rebindConnect",
      requestId: "request-1",
      revision: 2,
      account: "0x1111111111111111111111111111111111111111",
    },
  ]) {
    await new Promise((resolve) => messageListener(message, {}, resolve));
  }

  assert.deepEqual(
    nativeMessages.map((message) => message.action),
    ["approve", "reject", "connectAccounts", "rebindConnect"],
  );
  assert.equal(nativeMessages[0].payload.revision, 2);
  assert.equal(nativeMessages[1].payload.revision, 2);
  assert.equal(nativeMessages[2].payload.revision, 2);
  assert.equal(nativeMessages[3].payload.account, "0x1111111111111111111111111111111111111111");
});

test("an existing grant does not short-circuit wallet_connect capabilities", async () => {
  let messageListener;
  const actions = [];
  const browser = {
    action: { setBadgeText() {} },
    runtime: {
      lastError: null,
      onMessage: {
        addListener(listener) {
          messageListener = listener;
        },
      },
      sendNativeMessage(_applicationID, message, callback) {
        actions.push(message.action);
        if (message.action === "isConnected") callback({ ok: true, data: { connected: true } });
        else if (message.action === "chain")
          callback({ ok: true, data: { chainId: "1", chainIdHex: "0x1" } });
        else if (message.action === "prepare")
          callback({ ok: true, data: { requestId: "siwe-1" } });
        else callback({ ok: true, data: { account: "0x1234" } });
      },
    },
    tabs: {
      query(_query, callback) {
        callback([]);
      },
      sendMessage() {},
    },
  };
  vm.runInNewContext(backgroundSource, { browser, Map, Promise, Set, URL });

  const response = await new Promise((resolve) => {
    messageListener(
      {
        type: "ethereum.request",
        method: "wallet_connect",
        params: [
          {
            version: "1",
            capabilities: { signInWithEthereum: { nonce: "12345678", chainId: "0x1" } },
          },
        ],
      },
      { origin: "https://example.com" },
      resolve,
    );
  });
  assert.equal(response.pendingId, "siwe-1");
  assert.deepEqual(actions, ["chain", "prepare"]);
});

test("plain wallet_connect still short-circuits an existing grant", async () => {
  let messageListener;
  const actions = [];
  const browser = {
    action: { setBadgeText() {} },
    runtime: {
      lastError: null,
      onMessage: {
        addListener(listener) {
          messageListener = listener;
        },
      },
      sendNativeMessage(_applicationID, message, callback) {
        actions.push(message.action);
        callback({ ok: true, data: { accounts: ["0x1234"] } });
      },
    },
    tabs: {
      query(_query, callback) {
        callback([]);
      },
      sendMessage() {},
    },
  };
  vm.runInNewContext(backgroundSource, { browser, Map, Promise, Set, URL });

  const response = await new Promise((resolve) => {
    messageListener(
      { type: "ethereum.request", method: "wallet_connect", params: [{ version: "1" }] },
      { origin: "https://example.com" },
      resolve,
    );
  });
  assert.deepEqual(Array.from(response.result), ["0x1234"]);
  assert.deepEqual(actions, ["visibleAccounts"]);
});

test("eth_accounts uses one native visible-account snapshot", async () => {
  let messageListener;
  const messages = [];
  const browser = {
    action: { setBadgeText() {} },
    runtime: {
      lastError: null,
      onMessage: {
        addListener(listener) {
          messageListener = listener;
        },
      },
      sendNativeMessage(_applicationID, message, callback) {
        messages.push(message);
        callback({ ok: true, data: { accounts: ["0x1234"] } });
      },
    },
    tabs: {
      query(_query, callback) {
        callback([]);
      },
      sendMessage() {},
    },
  };
  vm.runInNewContext(backgroundSource, { browser, Map, Promise, Set, URL });

  const response = await new Promise((resolve) => {
    messageListener(
      { type: "ethereum.request", method: "eth_accounts" },
      { origin: "https://example.com" },
      resolve,
    );
  });

  assert.deepEqual(Array.from(response.result), ["0x1234"]);
  assert.equal(messages.length, 1);
  assert.equal(messages[0].action, "visibleAccounts");
  assert.equal(messages[0].origin, "https://example.com");
});

test("wallet_disconnect preserves native success and structured errors", async () => {
  let messageListener;
  let nativeResponse = { ok: true, data: { ok: true } };
  const tabMessages = [];
  const browser = {
    action: { setBadgeText() {} },
    runtime: {
      lastError: null,
      onMessage: {
        addListener(listener) {
          messageListener = listener;
        },
      },
      sendNativeMessage(_applicationID, message, callback) {
        assert.equal(message.action, "disconnectSite");
        assert.equal(message.origin, "https://example.com");
        callback(nativeResponse);
      },
    },
    tabs: {
      query(_query, callback) {
        callback([
          { id: 1, url: "https://example.com/one" },
          { id: 2, url: "https://other.example/" },
        ]);
      },
      sendMessage(tabId, message) {
        tabMessages.push({ tabId, message });
      },
    },
  };
  vm.runInNewContext(backgroundSource, { browser, Map, Promise, Set, URL });

  const disconnect = () =>
    new Promise((resolve) => {
      messageListener(
        { type: "ethereum.request", method: "wallet_disconnect" },
        { origin: "https://example.com" },
        resolve,
      );
    });

  const success = await disconnect();
  assert.equal(success.__envelope, true);
  assert.equal(success.ok, true);
  assert.equal(success.result, true);
  assert.equal(tabMessages.length, 1);
  assert.equal(tabMessages[0].tabId, 1);
  assert.equal(tabMessages[0].message.type, "wallet.refreshAccounts");

  nativeResponse = {
    ok: false,
    error: { code: 4900, message: "Connection state is unavailable" },
  };
  const failure = await disconnect();
  assert.equal(failure.__envelope, true);
  assert.equal(failure.ok, false);
  assert.equal(failure.error.code, 4900);
  assert.equal(failure.error.message, "Connection state is unavailable");
  assert.equal(tabMessages.length, 1);
});

test("account updates reach only tabs for the authoritative origin", async () => {
  let messageListener;
  const tabMessages = [];
  const browser = {
    action: { setBadgeText() {} },
    runtime: {
      lastError: null,
      onMessage: {
        addListener(listener) {
          messageListener = listener;
        },
      },
      sendNativeMessage(_applicationID, message, callback) {
        if (message.action === "get") {
          callback({ ok: true, data: { status: "consumed", result: ["0x1234"] } });
        } else if (message.action === "summary") {
          callback({ ok: true, data: { method: "eth_requestAccounts" } });
        } else {
          callback({ ok: false, error: "unexpected native action" });
        }
      },
    },
    tabs: {
      query(_query, callback) {
        callback([
          { id: 1, url: "https://example.com/one" },
          { id: 2, url: "https://example.com:443/two" },
          { id: 3, url: "https://other.example/" },
        ]);
      },
      sendMessage(tabId, message) {
        tabMessages.push({ tabId, message });
      },
    },
  };
  vm.runInNewContext(backgroundSource, { browser, Map, Promise, Set, URL });

  const response = await new Promise((resolve) => {
    messageListener(
      { type: "ethereum.status", id: "request-1" },
      { origin: "https://example.com" },
      resolve,
    );
  });

  assert.equal(response.__resolved, true);
  assert.deepEqual(
    tabMessages.map(({ tabId }) => tabId),
    [1, 2],
  );
  assert.equal(tabMessages[0].message.type, "wallet.refreshAccounts");
});

test("account bootstrap resolves one native sender-scoped snapshot", async () => {
  let messageListener;
  const nativeMessages = [];
  const browser = {
    action: { setBadgeText() {} },
    runtime: {
      lastError: null,
      onMessage: {
        addListener(listener) {
          messageListener = listener;
        },
      },
      sendNativeMessage(_applicationID, message, callback) {
        nativeMessages.push(message);
        callback({ ok: true, data: { accounts: ["0x1234"] } });
      },
    },
    tabs: {
      query(_query, callback) {
        callback([]);
      },
      sendMessage() {},
    },
  };
  vm.runInNewContext(backgroundSource, { browser, Map, Promise, Set, URL });

  const response = await new Promise((resolve) => {
    messageListener({ type: "wallet.getAccounts" }, { origin: "https://example.com" }, resolve);
  });

  assert.deepEqual(Array.from(response.accounts), ["0x1234"]);
  assert.equal(nativeMessages.length, 1);
  assert.equal(nativeMessages[0].action, "visibleAccounts");
  assert.equal(nativeMessages[0].origin, "https://example.com");
});

test("EIP-5792 methods use native-authoritative routes and preserve method spelling", async () => {
  let messageListener;
  const messages = [];
  const browser = {
    action: { setBadgeText() {} },
    runtime: {
      lastError: null,
      onMessage: {
        addListener(listener) {
          messageListener = listener;
        },
      },
      sendNativeMessage(_applicationID, message, callback) {
        messages.push(message);
        if (message.action === "chain")
          callback({ ok: true, data: { chainId: "1", chainIdHex: "0x1" } });
        else if (message.action === "prepare")
          callback({ ok: true, data: { requestId: "batch-1" } });
        else if (message.action === "getCapabilities")
          callback({ ok: true, data: { result: { "0x1": { atomic: { status: "supported" } } } } });
        else if (message.action === "getCallsStatus")
          callback({ ok: true, data: { result: { status: 100 } } });
        else callback({ ok: false, error: { code: -32603, message: "unexpected" } });
      },
    },
    tabs: {
      query(_query, callback) {
        callback([]);
      },
      sendMessage() {},
    },
  };
  vm.runInNewContext(backgroundSource, { browser, Map, Promise, Set, URL });

  const send = await new Promise((resolve) => {
    messageListener(
      { type: "ethereum.request", method: "wallet_sendCalls", params: [{}] },
      { origin: "https://example.com" },
      resolve,
    );
  });
  assert.equal(send.pendingId, "batch-1");
  assert.equal(messages.find((message) => message.action === "prepare").method, "wallet_sendCalls");

  const capabilities = await new Promise((resolve) => {
    messageListener(
      { type: "ethereum.request", method: "wallet_getCapabilities", params: ["0x1234"] },
      { origin: "https://example.com" },
      resolve,
    );
  });
  assert.equal(capabilities.result["0x1"].atomic.status, "supported");

  const status = await new Promise((resolve) => {
    messageListener(
      { type: "ethereum.request", method: "wallet_getCallsStatus", params: ["0x01"] },
      { origin: "https://example.com" },
      resolve,
    );
  });
  assert.equal(status.result.status, 100);
  assert.deepEqual(
    messages.filter((message) => message.action === "passthrough"),
    [],
  );
});
