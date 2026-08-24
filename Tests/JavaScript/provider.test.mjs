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
