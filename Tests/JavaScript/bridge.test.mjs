import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const bridgeSource = await readFile(
  new URL("../../SafariExtension/Resources/bridge.js", import.meta.url),
  "utf8",
);

test("bridge refreshes native account state on Safari page lifecycle returns", async () => {
  const posted = [];
  const requests = [];
  let runtimeListener;
  let account = "0x1111111111111111111111111111111111111111";
  const window = new EventTarget();
  window.postMessage = (message) => posted.push(message);
  const document = new EventTarget();
  document.visibilityState = "visible";
  const browser = {
    runtime: {
      getURL(value) {
        return value;
      },
      onMessage: {
        addListener(listener) {
          runtimeListener = listener;
        },
      },
      sendMessage(message) {
        requests.push(message.type);
        if (message.type === "wallet.getChain") return Promise.resolve({ chainIdHex: "0x1" });
        if (message.type === "wallet.getAccounts") {
          return Promise.resolve({ accounts: account ? [account] : [] });
        }
        return Promise.resolve({});
      },
    },
  };

  vm.runInNewContext(bridgeSource, {
    browser,
    document,
    Promise,
    setTimeout,
    window,
  });
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.deepEqual(requests.slice(0, 2).sort(), ["wallet.getAccounts", "wallet.getChain"]);
  assert.deepEqual(
    Array.from(posted.find((message) => message.event === "accountsChanged").value),
    [account],
  );

  account = undefined;
  window.dispatchEvent(new Event("pageshow"));
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(Array.from(posted.at(-1).value), []);

  account = "0x3333333333333333333333333333333333333333";
  document.dispatchEvent(new Event("visibilitychange"));
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(Array.from(posted.at(-1).value), [account]);

  account = undefined;
  runtimeListener({ type: "wallet.refreshAccounts" });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.deepEqual(Array.from(posted.at(-1).value), []);
});

test("Chrome pending requests poll to completion without injecting the Safari banner", async () => {
  const { execFileSync } = await import("node:child_process");
  execFileSync(process.execPath, [
    new URL("../../ChromeExtension/build.mjs", import.meta.url).pathname,
  ]);
  const source = await readFile(
    new URL("../../.build/chrome-extension/bridge.js", import.meta.url),
    "utf8",
  );
  const window = new EventTarget();
  const document = new EventTarget();
  document.visibilityState = "visible";
  document.createElement = () => {
    throw new Error("Chrome must not inject a pending banner");
  };
  let polls = 0;
  let complete;
  const completed = new Promise((resolve) => {
    complete = resolve;
  });
  window.postMessage = (message) => {
    if (message.__channel === "__stupid-wallet:response") complete(message);
  };
  const chrome = {
    runtime: {
      onMessage: { addListener() {} },
      async sendMessage(message) {
        if (message.type === "wallet.getChain") return { chainIdHex: "0x1" };
        if (message.type === "wallet.getAccounts") return { accounts: [] };
        if (message.type === "ethereum.request")
          return { __envelope: true, ok: true, pendingId: "pending" };
        if (message.type === "ethereum.status")
          return ++polls === 1 ? {} : { __error: "User rejected", code: 4001 };
        throw new Error("Unexpected message");
      },
    },
  };
  vm.runInNewContext(source, { chrome, window, document, setTimeout: (fn) => queueMicrotask(fn) });
  const event = new Event("message");
  Object.defineProperties(event, {
    source: { value: window },
    data: {
      value: {
        __channel: "__stupid-wallet:request",
        id: 7,
        requestKey: "test:7",
        method: "personal_sign",
        params: [],
      },
    },
  });
  window.dispatchEvent(event);
  const result = await completed;
  assert.equal(polls, 2);
  assert.equal(result.code, 4001);
  assert.equal(result.ok, false);
});
