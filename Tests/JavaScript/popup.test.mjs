import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const popupSource = await readFile(
  new URL("../../SafariExtension/Resources/popup.js", import.meta.url),
  "utf8",
);

test("popup lists pending requests directly through native messaging", async () => {
  const nativeMessages = [];
  let nativeReply;
  const tray = {
    textContent: "",
    appendChild() {
      nativeReply();
    },
  };
  const document = {
    getElementById() {
      return tray;
    },
    createElement() {
      return {
        append() {},
        appendChild() {},
        className: "",
        textContent: "",
      };
    },
  };
  const browser = {
    runtime: {
      lastError: null,
      sendMessage() {
        throw new Error("popup list must not pass through the background worker");
      },
      sendNativeMessage(applicationID, message, callback) {
        nativeMessages.push({ applicationID, message });
        callback({ ok: true, data: { pending: [] } });
      },
    },
  };

  const rendered = new Promise((resolve) => {
    nativeReply = resolve;
  });
  vm.runInNewContext(popupSource, { browser, document, Promise, URL, window: {} });
  await rendered;

  assert.equal(nativeMessages.length, 1);
  assert.equal(nativeMessages[0].applicationID, "co.za.stephancill.stupid-wallet");
  assert.equal(nativeMessages[0].message.action, "list");
  assert.equal(nativeMessages[0].message.payload, undefined);
});

test("popup falls back to background messaging when direct native transport is unavailable", async () => {
  const backgroundMessages = [];
  let renderedReply;
  const tray = {
    textContent: "",
    appendChild() {
      renderedReply();
    },
  };
  const browser = {
    runtime: {
      lastError: { message: "native transport unavailable" },
      sendNativeMessage(_applicationID, _message, callback) {
        callback(undefined);
      },
      sendMessage(message) {
        backgroundMessages.push(message);
        return Promise.resolve([]);
      },
    },
  };
  const document = {
    getElementById() {
      return tray;
    },
    createElement() {
      return { append() {}, appendChild() {}, className: "", textContent: "" };
    },
  };

  const rendered = new Promise((resolve) => {
    renderedReply = resolve;
  });
  vm.runInNewContext(popupSource, { browser, document, Promise, URL, window: {} });
  await rendered;

  assert.equal(backgroundMessages.length, 1);
  assert.equal(backgroundMessages[0].type, "popup.list");
});
