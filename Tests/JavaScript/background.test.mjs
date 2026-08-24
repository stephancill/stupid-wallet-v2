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
