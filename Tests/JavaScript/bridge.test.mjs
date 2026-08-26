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
