import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { webcrypto } from "node:crypto";
import test from "node:test";
import vm from "node:vm";
const { build } = await import("../../ChromeExtension/node_modules/esbuild/lib/main.js");
const bundle = await build({
  entryPoints: [new URL("../../ChromeExtension/native-transport.js", import.meta.url).pathname],
  bundle: true,
  write: false,
  format: "iife",
  platform: "browser",
});
const source = bundle.outputFiles[0].text;

function harness({ absent = false, version = 3, defer = false } = {}) {
  const storage = {};
  const ports = [];
  let writes = 0;
  const api = {
    runtime: {
      id: "wallet-extension",
      getURL: (path) => `chrome-extension://wallet-extension/${path}`,
      connectNative(name) {
        assert.equal(name, "net.stupidtech.stupid_wallet");
        const listeners = {};
        const port = {
          onMessage: {
            addListener(fn) {
              listeners.message = fn;
            },
          },
          onDisconnect: {
            addListener(fn) {
              listeners.disconnect = fn;
            },
          },
          disconnect() {},
          frames: [],
          challenge(frame) {
            return listeners.message(frame);
          },
          postMessage(frame) {
            port.frames.push(frame);
            if (frame.message.action === "contextResult") return;
            if (absent) queueMicrotask(() => listeners.disconnect());
            else if (frame.message.action === "hello")
              queueMicrotask(() =>
                listeners.message({
                  version,
                  id: frame.id,
                  response: { ok: true, data: { protocolVersion: version } },
                }),
              );
            else if (!defer)
              queueMicrotask(() =>
                listeners.message({
                  version,
                  id: frame.id,
                  response: { ok: true, data: { result: frame.message.params ?? null } },
                }),
              );
          },
          reply(frame, result) {
            listeners.message({ version, id: frame.id, response: { ok: true, data: { result } } });
          },
          crash() {
            listeners.disconnect();
          },
        };
        ports.push(port);
        return port;
      },
    },
    storage: {
      local: {
        async get(key) {
          return key === null ? { ...storage } : { [key]: storage[key] };
        },
        async set(items) {
          writes++;
          Object.assign(storage, items);
        },
        async remove(key) {
          delete storage[key];
        },
      },
    },
    webNavigation: {
      async getFrame() {
        return { documentId: "doc", url: "https://example.com/page" };
      },
      onCommitted: { addListener() {} },
    },
    tabs: {
      onRemoved: { addListener() {} },
      async get(id) {
        return { id, url: "https://example.com/page" };
      },
    },
  };
  const context = {
    chrome: api,
    crypto: webcrypto,
    URL,
    TextEncoder,
    btoa,
    setTimeout,
    clearTimeout,
  };
  vm.runInNewContext(source, context);
  return { context, ports, storage, api, writes: () => writes };
}

test("port handshake, one profile under concurrency, JSON preservation and no chain hints", async () => {
  const h = harness();
  const results = await Promise.all(
    Array.from({ length: 5 }, () =>
      h.context.walletNativeTransport({
        action: "passthrough",
        method: "eth_blockNumber",
        origin: "https://example.com",
        params: [null, false, { x: 1 }],
        chainId: "8453",
      }),
    ),
  );
  assert.equal(h.ports.length, 1);
  assert.equal(h.writes(), 1);
  for (const result of results)
    assert.equal(JSON.stringify(result.data.result), '[null,false,{"x":1}]');
  for (const frame of h.ports[0].frames) {
    assert.equal(frame.profileId, h.storage.nativeProfileId);
    assert.equal(frame.message.chainId, undefined);
  }
  assert.equal(h.ports[0].frames[1].message.method, "eth_blockNumber");
});

test("host absence and version skew fail clearly", async () => {
  for (const config of [{ absent: true }, { version: 1 }]) {
    const h = harness(config);
    const result = await h.context.walletNativeTransport({ action: "list" });
    assert.equal(result.ok, false);
    assert.equal(result.error.code, 4900);
    assert.match(result.error.message, /helper|protocol/);
  }
});

test("host crash settles pending calls without replay; next call reconnects", async () => {
  const h = harness({ defer: true });
  const pending = h.context.walletNativeTransport({
    action: "approve",
    payload: { requestId: "canonical", revision: 1 },
  });
  await new Promise(setImmediate);
  h.ports[0].crash();
  assert.equal((await pending).ok, false);
  assert.equal(h.ports[0].frames.filter((f) => f.message.action === "approve").length, 1);
  const next = h.context.walletNativeTransport({ action: "list" });
  await new Promise(setImmediate);
  assert.equal(h.ports.length, 2);
  const frame = h.ports[1].frames.find((f) => f.message.action === "list");
  h.ports[1].reply(frame, null);
  assert.equal((await next).ok, true);
  assert.equal(
    h.ports[1].frames.some((f) => f.message.action === "approve"),
    false,
  );
});

test("trusted sender rejects incognito, frames, opaque and spoofed origins, and page popup actions", async () => {
  const h = harness();
  const sender = {
    id: h.api.runtime.id,
    origin: "https://example.com",
    url: "https://example.com/page",
    frameId: 0,
    documentId: "doc",
    tab: { id: 7, url: "https://example.com/page" },
  };
  await h.context.walletChromeContext.validate({ type: "ethereum.request" }, sender);
  for (const bad of [
    { ...sender, incognito: true },
    { ...sender, frameId: 1 },
    { ...sender, origin: "null" },
    { ...sender, origin: "https://evil.example" },
    { ...sender, documentId: undefined },
  ]) {
    await assert.rejects(h.context.walletChromeContext.validate({ type: "ethereum.request" }, bad));
  }
  await assert.rejects(h.context.walletChromeContext.validate({ type: "popup.approve" }, sender));
  await h.context.walletChromeContext.validate(
    { type: "popup.list" },
    { id: h.api.runtime.id, url: h.api.runtime.getURL("popup.html") },
  );
  await h.context.walletChromeContext.remember("request", sender);
  assert.equal(await h.context.walletChromeContext.owns("request", sender), true);
  assert.equal(
    await h.context.walletChromeContext.owns("request", { ...sender, documentId: "navigated" }),
    false,
  );
  assert.equal(
    await h.context.walletChromeContext.owns("request", {
      ...sender,
      tab: { ...sender.tab, id: 8 },
    }),
    false,
  );
  await h.context.walletChromeContext.forget("request");
  assert.equal(await h.context.walletChromeContext.owns("request", sender), false);
});

test("profile corruption fails instead of silently creating a new grant identity", async () => {
  const h = harness();
  h.storage.nativeProfileId = "corrupt";
  const result = await h.context.walletNativeTransport({ action: "list" });
  assert.equal(result.ok, false);
  assert.equal(h.ports.length, 0);
  assert.equal(h.writes(), 0);
});

test("worker ignores page authority metadata and preserves structured sender rejection", async () => {
  const background = await readFile(
    new URL("../../SafariExtension/Resources/background.js", import.meta.url),
    "utf8",
  );
  const h = harness();
  let listener;
  h.api.runtime.onMessage = {
    addListener(fn) {
      listener = fn;
    },
  };
  h.api.action = { setBadgeText() {} };
  h.context.browser = h.api;
  vm.runInNewContext(background, h.context);
  const sender = {
    id: h.api.runtime.id,
    origin: "https://example.com",
    url: "https://example.com/page",
    frameId: 0,
    documentId: "doc",
    tab: { id: 7, url: "https://example.com/page" },
  };
  await new Promise((resolve) =>
    listener(
      { type: "wallet.getAccounts", origin: "https://evil.example", profileId: "spoofed" },
      sender,
      resolve,
    ),
  );
  const request = h.ports[0].frames.find((frame) => frame.message.action === "visibleAccounts");
  assert.equal(request.message.origin, sender.origin);
  assert.equal(request.profileId, h.storage.nativeProfileId);
  assert.equal(request.message.profileId, undefined);
  const response = await new Promise((resolve) =>
    listener(
      { type: "ethereum.request", method: "eth_sign" },
      { ...sender, incognito: true },
      resolve,
    ),
  );
  assert.equal(response.__envelope, true);
  assert.equal(response.ok, false);
  assert.match(response.error.message, /Incognito/);
});

test("toolbar decisions reject extra authority and same-origin document replacement", async () => {
  const h = harness();
  const id = webcrypto.randomUUID();
  const sender = { id: h.api.runtime.id, url: h.api.runtime.getURL("popup.html") };
  await h.context.walletChromeContext.remember(id, {
    tab: { id: 7 },
    documentId: "doc",
    origin: "https://example.com",
  });
  const message = { type: "popup.approve", requestId: id, revision: 0, bindingDigest: "digest" };
  await h.context.walletChromeContext.validate(message, sender);
  await assert.rejects(h.context.walletChromeContext.validate({ ...message, params: [] }, sender));
  h.api.webNavigation.getFrame = async () => ({
    documentId: "new-document",
    url: "https://example.com/page",
  });
  await assert.rejects(h.context.walletChromeContext.validate(message, sender));
});

test("post-native-review challenge checks the live document and never replays approval", async () => {
  const h = harness({ defer: true });
  const id = webcrypto.randomUUID();
  await h.context.walletChromeContext.remember(id, {
    tab: { id: 7 },
    documentId: "doc",
    origin: "https://example.com",
  });
  const pending = h.context.walletNativeTransport({
    action: "approve",
    payload: { requestId: id, revision: 0, bindingDigest: "digest" },
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  const port = h.ports[0];
  const approval = port.frames.find((f) => f.message.action === "approve");
  h.api.webNavigation.getFrame = async () => ({
    documentId: "navigated",
    url: "https://example.com/next",
  });
  await port.challenge({
    version: 3,
    id: approval.id,
    contextCheck: true,
    requestId: id,
    nonce: webcrypto.randomUUID(),
    revision: 0,
    bindingDigest: "digest",
  });
  assert.equal(port.frames.at(-1).message.payload.valid, false);
  assert.equal(port.frames.filter((f) => f.message.action === "approve").length, 1);
  port.crash();
  assert.equal((await pending).ok, false);
});

test("auto review opens once for a current foreground document and preserves routes on failure", async () => {
  const h = harness();
  const opens = [];
  let active = true;
  let focused = true;
  h.api.tabs.get = async (id) => ({ id, active, windowId: 7, url: "https://example.com/page" });
  h.api.windows = { get: async () => ({ focused }) };
  h.api.action = {
    openPopup: async ({ windowId }) => {
      opens.push(windowId);
    },
  };
  const sender = { tab: { id: 1 }, documentId: "doc", origin: "https://example.com" };
  const review = h.context.walletChromeContext;
  await review.remember("first", sender);
  await review.remember("first", sender);
  assert.deepEqual(opens, [7]);
  active = false;
  await review.remember("background", sender);
  active = true;
  focused = false;
  await review.remember("unfocused", sender);
  focused = true;
  await review.remember("stale", { ...sender, documentId: "old-doc" });
  assert.deepEqual(opens, [7]);
  h.api.action.openPopup = async () => {
    throw new Error("Browser refused");
  };
  await review.remember("refused", sender);
  assert.ok(h.storage["route:refused"]);
});

test("paired approval signs only the reviewed request binding and native nonce", async () => {
  const h = harness({ defer: true });
  const keys = await webcrypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, [
    "sign",
    "verify",
  ]);
  h.context.CryptoKey = CryptoKey;
  h.context.indexedDB = {
    open() {
      const open = {};
      queueMicrotask(() => {
        open.result = {
          close() {},
          transaction() {
            return {
              objectStore() {
                return {
                  get() {
                    const read = {};
                    queueMicrotask(() => {
                      read.result = keys;
                      read.onsuccess();
                    });
                    return read;
                  },
                };
              },
            };
          },
        };
        open.onsuccess();
      });
      return open;
    },
  };
  const id = webcrypto.randomUUID();
  await h.context.walletChromeContext.remember(id, {
    tab: { id: 7 },
    documentId: "doc",
    origin: "https://example.com",
  });
  const pending = h.context.walletNativeTransport({
    action: "approve",
    payload: { requestId: id, revision: 7, bindingDigest: "digest" },
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  const port = h.ports[0];
  const approval = port.frames.find((f) => f.message.action === "approve");
  const nonce = webcrypto.randomUUID();
  await port.challenge({
    version: 3,
    id: approval.id,
    contextCheck: true,
    requestId: id,
    nonce,
    revision: 7,
    bindingDigest: "digest",
  });
  const proof = port.frames.at(-1).message.payload;
  assert.equal(proof.valid, true);
  const transcript = new TextEncoder().encode(
    `stupid-wallet-approve-v1\n${approval.profileId}\n${nonce}\n${id}\n7\ndigest`,
  );
  assert.equal(
    await webcrypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      keys.publicKey,
      Buffer.from(proof.signature, "base64"),
      transcript,
    ),
    true,
  );
  await port.challenge({
    version: 3,
    id: approval.id,
    contextCheck: true,
    requestId: id,
    nonce,
    revision: 7,
    bindingDigest: "mutated",
  });
  assert.equal((await pending).ok, false);
});
