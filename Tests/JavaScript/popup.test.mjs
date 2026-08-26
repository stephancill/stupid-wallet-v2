import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";

const popupSource = await readFile(
  new URL("../../SafariExtension/Resources/popup.js", import.meta.url),
  "utf8",
);
const popupStyle = await readFile(
  new URL("../../SafariExtension/Resources/popup.css", import.meta.url),
  "utf8",
);

test("account picker stays scrollable inside the fixed Safari popup viewport", () => {
  const panelRule = popupStyle.match(/\.account-picker-panel\s*\{([^}]*)\}/)?.[1] ?? "";

  assert.match(panelRule, /max-height:\s*calc\(100vh - 24px\)/);
  assert.match(panelRule, /overflow-y:\s*auto/);
  assert.match(panelRule, /overscroll-behavior:\s*contain/);
});

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

test("popup renders addresses, collapses queued requests, and expands raw calldata", async () => {
  const account = "0x1234567890abcdef1234567890abcdef12345678";
  const target = "0x1111111111111111111111111111111111111111";
  const calldata = `0x${"12345678".repeat(30)}`;
  let didRender;
  const tray = new TestElement("div", () => didRender?.());
  const document = {
    getElementById() {
      return tray;
    },
    createElement(tagName) {
      return new TestElement(tagName);
    },
  };
  const browser = {
    runtime: {
      lastError: null,
      sendNativeMessage(_applicationID, _message, callback) {
        callback({
          ok: true,
          data: {
            pending: [
              {
                requestId: "active",
                data: {
                  kind: "batch",
                  title: "Send calls",
                  account,
                  origin: "https://dapp.example",
                  queued: false,
                  rows: [
                    { label: "Account", value: account },
                    { label: "Chain", value: "1" },
                    { label: "Call 1 Target", value: target },
                    { label: "Call 1 Value", value: "0 ETH" },
                    { label: "Call 1 Data", value: calldata },
                    {
                      label: "Call 2 Target",
                      value: "0x2222222222222222222222222222222222222222",
                    },
                    { label: "Call 2 Value", value: "0 ETH" },
                    { label: "Call 2 Data", value: "0x" },
                  ],
                },
              },
              {
                requestId: "queued",
                data: {
                  kind: "message",
                  title: "Sign message",
                  account,
                  origin: "https://dapp.example",
                  queued: true,
                  rows: [
                    { label: "Account", value: account },
                    { label: "Message", value: "hello" },
                  ],
                },
              },
              {
                requestId: "queued-send",
                data: {
                  kind: "send",
                  title: "Send transaction",
                  account,
                  origin: "https://dapp.example",
                  queued: true,
                  rows: [
                    { label: "Account", value: account },
                    { label: "Chain", value: "1" },
                    { label: "To", value: target },
                    { label: "Data", value: "0x1234" },
                  ],
                },
              },
            ],
          },
        });
      },
      sendMessage() {
        return Promise.resolve(null);
      },
    },
  };

  const rendered = new Promise((resolve) => {
    didRender = resolve;
  });
  vm.runInNewContext(popupSource, { browser, document, Math, Promise, URL, window: {} });
  await rendered;

  const addressValues = tray.querySelectorAll(".address-value");
  assert.ok(addressValues.length >= 3);
  assert.equal(addressValues[0].textContent, "0x1111...1111");
  assert.equal(addressValues[0].title, target);
  const blockiePixels = addressValues[0].querySelector(".blockie").children;
  assert.equal(blockiePixels.length, 64);
  const palette = ["hsl(66 69% 49%)", "hsl(157 48% 54%)", "hsl(20 70% 80%)"];
  const leftHalf = [
    0, 0, 1, 2, 1, 1, 0, 0, 2, 2, 0, 2, 1, 0, 0, 1, 0, 0, 2, 1, 1, 1, 2, 1, 0, 0, 0, 1, 1, 0, 1, 0,
  ];
  const expectedColors = [];
  for (let row = 0; row < 8; row += 1) {
    const half = leftHalf.slice(row * 4, row * 4 + 4);
    expectedColors.push(...[...half, ...half.slice().reverse()].map((index) => palette[index]));
  }
  assert.deepEqual(
    blockiePixels.map((pixel) => pixel.style.backgroundColor),
    expectedColors,
  );
  const activeBatch = tray.querySelector(".request-batch");
  const activeActions = activeBatch.querySelector(".actions");
  assert.equal(activeActions.querySelector(".account").textContent, "0x1234...5678");
  const sendAddress = tray.querySelector(".request-send").querySelector(".message-value");
  assert.equal(sendAddress.tagName, "div");
  assert.equal(sendAddress.querySelector(".address-value").textContent, "0x1111...1111");

  const queued = tray.querySelector(".queued");
  const heading = queued.querySelector(".request-heading");
  assert.ok(queued.classList.contains("collapsed"));
  assert.equal(heading.getAttribute("aria-expanded"), "false");
  heading.click();
  assert.ok(!queued.classList.contains("collapsed"));
  assert.equal(heading.getAttribute("aria-expanded"), "true");

  const calldataToggle = activeBatch.querySelector(".calldata-toggle");
  assert.equal(activeBatch.querySelectorAll(".section-list").length, 2);
  assert.equal(activeBatch.querySelectorAll(".section-row").length, 3);
  assert.equal(activeBatch.querySelectorAll(".calldata-toggle").length, 1);
  assert.deepEqual(
    activeBatch.querySelectorAll(".section-label").map((label) => label.textContent),
    ["To", "Data", "To"],
  );
  assert.equal(calldataToggle.textContent, calldata);
  assert.equal(calldataToggle.getAttribute("aria-expanded"), "false");
  calldataToggle.click();
  assert.ok(calldataToggle.classList.contains("expanded"));
  assert.equal(calldataToggle.getAttribute("aria-expanded"), "true");
});

test("active connect account opens an existing-account-only revisioned picker", async () => {
  const first = "0x1234567890abcdef1234567890abcdef12345678";
  const second = "0x1111111111111111111111111111111111111111";
  const nativeMessages = [];
  let didRender;
  const tray = new TestElement("div", () => didRender?.());
  const document = {
    getElementById() {
      return tray;
    },
    createElement(tagName) {
      return new TestElement(tagName);
    },
  };
  const summary = {
    id: "connect-1",
    kind: "connect",
    title: "Connect site",
    account: first,
    origin: "https://dapp.example",
    queued: false,
    revision: 3,
    rows: [
      { label: "Account", value: first },
      { label: "Origin", value: "https://dapp.example" },
    ],
  };
  const browser = {
    runtime: {
      lastError: null,
      sendNativeMessage(_applicationID, message, callback) {
        nativeMessages.push(message);
        if (message.action === "list") callback({ ok: true, data: { pending: [summary] } });
        else if (message.action === "connectAccounts") {
          callback({
            ok: true,
            data: {
              groups: [
                { id: "seed", kind: "seed", accounts: [{ address: first }, { address: second }] },
                { id: "key", kind: "privateKey", accounts: [{ address: first }] },
              ],
            },
          });
        } else if (message.action === "rebindConnect") {
          callback({ ok: true, data: { summary: { ...summary, account: second, revision: 4 } } });
        }
      },
      sendMessage() {
        return Promise.resolve(null);
      },
    },
  };

  const rendered = new Promise((resolve) => {
    didRender = resolve;
  });
  vm.runInNewContext(popupSource, { browser, document, Math, Promise, URL, window: {} });
  await rendered;

  const connect = tray.querySelector(".request-connect");
  assert.equal(connect.querySelector(".summary").textContent.includes("Wallet"), false);
  const accountButton = connect.querySelector(".account-select");
  assert.ok(accountButton);
  accountButton.click();
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(nativeMessages[1].action, "connectAccounts");
  assert.equal(nativeMessages[1].payload.requestId, "connect-1");
  assert.equal(nativeMessages[1].payload.revision, 3);
  const picker = tray.querySelector(".account-picker");
  assert.ok(picker);
  assert.equal(picker.textContent.includes("Create"), false);
  assert.equal(picker.textContent.includes("Import"), false);
  assert.equal(picker.querySelectorAll(".account-group").length, 2);
  picker.querySelectorAll(".account-option")[1].click();
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(nativeMessages[2].action, "rebindConnect");
  assert.equal(nativeMessages[2].payload.requestId, "connect-1");
  assert.equal(nativeMessages[2].payload.revision, 3);
  assert.equal(nativeMessages[2].payload.account, second);
});

class TestElement {
  constructor(tagName, onAppend) {
    this.tagName = tagName;
    this.children = [];
    this.attributes = new Map();
    this.listeners = new Map();
    this.style = {};
    this.className = "";
    this._textContent = "";
    this.onAppend = onAppend;
  }

  get textContent() {
    return this._textContent || this.children.map((child) => child.textContent || "").join("");
  }

  set textContent(value) {
    this._textContent = String(value);
    this.children = [];
  }

  get classList() {
    const classes = () => new Set(this.className.split(/\s+/).filter(Boolean));
    const save = (values) => {
      this.className = [...values].join(" ");
    };
    return {
      add: (...names) => {
        const values = classes();
        for (const name of names) values.add(name);
        save(values);
      },
      contains: (name) => classes().has(name),
      toggle: (name) => {
        const values = classes();
        const added = !values.has(name);
        if (added) values.add(name);
        else values.delete(name);
        save(values);
        return added;
      },
    };
  }

  append(...children) {
    for (const child of children) this.appendChild(child);
  }

  appendChild(child) {
    this.children.push(child);
    child.parentNode = this;
    this.onAppend?.();
    return child;
  }

  insertBefore(child, reference) {
    const index = this.children.indexOf(reference);
    if (index < 0) return this.appendChild(child);
    this.children.splice(index, 0, child);
    child.parentNode = this;
    return child;
  }

  remove() {
    if (!this.parentNode) return;
    this.parentNode.children = this.parentNode.children.filter((child) => child !== this);
    this.parentNode = null;
  }

  setAttribute(name, value) {
    this.attributes.set(name, String(value));
  }

  getAttribute(name) {
    return this.attributes.get(name) ?? null;
  }

  addEventListener(type, listener) {
    const listeners = this.listeners.get(type) || [];
    listeners.push(listener);
    this.listeners.set(type, listeners);
  }

  click() {
    for (const listener of this.listeners.get("click") || []) listener({});
  }

  querySelector(selector) {
    return this.querySelectorAll(selector)[0] || null;
  }

  querySelectorAll(selector) {
    const className = selector.startsWith(".") ? selector.slice(1) : null;
    const tagName = className ? null : selector.toLowerCase();
    const matches = [];
    for (const child of this.children) {
      if (className && child.classList.contains(className)) matches.push(child);
      if (tagName && child.tagName.toLowerCase() === tagName) matches.push(child);
      matches.push(...child.querySelectorAll(selector));
    }
    return matches;
  }
}
