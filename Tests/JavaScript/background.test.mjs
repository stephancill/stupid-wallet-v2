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
        if (message.action === "isConnected") callback({ ok: true, data: { connected: true } });
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
      { type: "ethereum.request", method: "wallet_connect", params: [{ version: "1" }] },
      { origin: "https://example.com" },
      resolve,
    );
  });
  assert.deepEqual(Array.from(response.result), ["0x1234"]);
  assert.deepEqual(actions, ["isConnected", "me"]);
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
