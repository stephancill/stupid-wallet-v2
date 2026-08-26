import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const providerSource = await readFile(
  new URL("../../SafariExtension/Resources/provider.js", import.meta.url),
  "utf8",
);

test("provider re-announces for a late EIP-6963 consumer", () => {
  const window = new EventTarget();
  window.postMessage = () => {};

  vm.runInNewContext(providerSource, {
    crypto,
    CustomEvent,
    Error,
    Map,
    Set,
    window,
  });

  const announcements = [];
  window.addEventListener("eip6963:announceProvider", (event) => {
    announcements.push(event.detail);
  });
  window.dispatchEvent(new Event("eip6963:requestProvider"));

  assert.equal(announcements.length, 1);
  assert.equal(announcements[0].info.name, "stupid wallet");
  assert.equal(announcements[0].info.rdns, "co.za.stephancill.stupid-wallet");
  assert.match(
    announcements[0].info.uuid,
    /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
  );
  assert.equal(Object.isFrozen(announcements[0]), true);
  assert.equal(Object.isFrozen(announcements[0].info), true);
  assert.equal(announcements[0].provider.isStupidWallet, true);
});

test("provider injects on insecure LAN origins without crypto.randomUUID", () => {
  const window = new EventTarget();
  window.postMessage = () => {};

  vm.runInNewContext(providerSource, {
    Array,
    crypto: { getRandomValues: crypto.getRandomValues.bind(crypto) },
    CustomEvent,
    Error,
    Map,
    Set,
    Uint8Array,
    window,
  });

  assert.equal(window.ethereum.isStupidWallet, true);
});

test("provider assigns separate stable keys to separate requests", () => {
  const posted = [];
  const window = new EventTarget();
  window.postMessage = (message) => posted.push(message);

  vm.runInNewContext(providerSource, {
    crypto,
    CustomEvent,
    Error,
    Map,
    Set,
    window,
  });

  void window.ethereum.request({ method: "personal_sign", params: ["0x01"] });
  void window.ethereum.request({ method: "personal_sign", params: ["0x01"] });

  assert.equal(posted.length, 2);
  assert.notEqual(posted[0].requestKey, posted[1].requestKey);
  assert.match(posted[0].requestKey, /^[0-9a-f-]{36}:1$/);
  assert.match(posted[1].requestKey, /^[0-9a-f-]{36}:2$/);
});

test("provider tracks account snapshots and emits only real changes", async () => {
  const posted = [];
  const window = new EventTarget();
  window.postMessage = (message) => posted.push(message);

  vm.runInNewContext(providerSource, {
    Array,
    crypto,
    CustomEvent,
    Error,
    Map,
    Set,
    window,
  });

  const changes = [];
  window.ethereum.on("accountsChanged", (accounts) => changes.push(Array.from(accounts)));
  const dispatch = (data) => {
    const event = new Event("message");
    Object.defineProperties(event, { source: { value: window }, data: { value: data } });
    window.dispatchEvent(event);
  };

  dispatch({
    __channel: "__stupid-wallet:event",
    event: "accountsChanged",
    value: ["0x1111111111111111111111111111111111111111"],
  });
  assert.deepEqual(Array.from(window.ethereum.accounts), [
    "0x1111111111111111111111111111111111111111",
  ]);
  assert.deepEqual(changes, [["0x1111111111111111111111111111111111111111"]]);

  const connect = window.ethereum.request({ method: "eth_requestAccounts" });
  const connectRequest = posted.at(-1);
  dispatch({
    __channel: "__stupid-wallet:response",
    id: connectRequest.id,
    ok: true,
    result: ["0x2222222222222222222222222222222222222222"],
  });
  await connect;
  assert.deepEqual(changes.at(-1), ["0x2222222222222222222222222222222222222222"]);

  dispatch({
    __channel: "__stupid-wallet:event",
    event: "accountsChanged",
    value: ["0x2222222222222222222222222222222222222222"],
  });
  assert.equal(changes.length, 2);

  const disconnect = window.ethereum.request({ method: "wallet_disconnect" });
  const disconnectRequest = posted.at(-1);
  dispatch({
    __channel: "__stupid-wallet:response",
    id: disconnectRequest.id,
    ok: true,
    result: true,
  });
  await disconnect;
  assert.deepEqual(Array.from(window.ethereum.accounts), []);
  assert.deepEqual(changes.at(-1), []);
});
