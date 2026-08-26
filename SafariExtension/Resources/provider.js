// Stupid Wallet EIP-1193 provider.
// Runs in the MAIN world of the page. It cannot touch WebExtension APIs, so it
// relays JSON-RPC requests to the isolated-world bridge via window.postMessage.
// It never sees private keys or signs anything.
(() => {
  if (window.__StupidWallet) return;
  window.__StupidWallet = true;

  const SRC_CHANNEL = "__stupid-wallet:request";
  const DST_CHANNEL = "__stupid-wallet:response";
  const EVENT_CHANNEL = "__stupid-wallet:event";
  const providerSessionID = randomUUID();
  const WALLET_ICON =
    "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAIAAADYYG7QAAAAIGNIUk0AAHomAACAhAAA+gAAAIDoAAB1MAAA6mAAADqYAAAXcJy6UTwAAAAGYktHRAD/AP8A/6C9p5MAAAAJcEhZcwAACxMAAAsTAQCanBgAAAAHdElNRQfqCBgJBSZ+fezCAAAB/klEQVRYw+2XoevqUBzFz3VDjIrJNDCJyWbxXxDLEKyC2W7QbhbMRv8EDQaDRVCLYhO0KWxgUee288KF8fjBg7frfMpjJ959uftwvud+7yZI4puU+DRADBQDxUAx0KcBYqAPAJGM8EJ8Fcj3fSGEEMLzvM8DeZ6XSCQsy7JtW9O0SJjUgVzX1TRttVrl8/lCobBer6NhopJc1yVpWVY6nQ622u/3wSNlCYU8khRCACiVSsfj0TAMkrZtZzKZzWYj+ygL/pFDnueRbDQaAHa7nWmalUplsVgAGAwG0iRZo6DQQI7jkOz3+wBGoxFJwzCq1SrJZrMJoNPpyErf998O9Hw+Sc5mMwDtdpvk9XrVdb3X68mCbrcLwDRNZaYQQLILh8MBQLlclovn8xnAcDgMzBuPxwBqtRqVAq6HShuAVquVSqWm06lctCwLQC6XAyCEcF23Xq9ns9nL5QIgkQg/Vv6eXfq/3W5PpxPJx+NBcrlcApjP54Efsq1q/QrnkBCCZLFYBOB5nq7rchGA7/tBma7rcjxqmqZw6kMAydfLd/8Yyj+mjhqKChD+EAt+z20vfVIJ75uAHMcBkEwmvwVI/c56E1DkehVIxvmLQi1PuJxJ0UhhmP6u2+02mUzu9/uL+wRS+UB7qyIIdVT/G1L/o0MxUAz0XYqBYqAY6N36BZGLD912Q5amAAAAJXRFWHRkYXRlOmNyZWF0ZQAyMDI2LTA4LTI0VDA5OjA1OjM4KzAwOjAwqx11nwAAACV0RVh0ZGF0ZTptb2RpZnkAMjAyNi0wOC0yNFQwOTowNTozOCswMDowMNpAzSMAAAAodEVYdGRhdGU6dGltZXN0YW1wADIwMjYtMDgtMjRUMDk6MDU6MzgrMDA6MDCNVez8AAAAAElFTkSuQmCC";
  let nextId = 0;
  const pending = new Map();
  const listeners = new Map();
  let accounts = [];

  function post(message) {
    window.postMessage(message, "*");
  }

  function randomUUID() {
    if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0"));
    return `${hex.slice(0, 4).join("")}-${hex.slice(4, 6).join("")}-${hex.slice(6, 8).join("")}-${hex.slice(8, 10).join("")}-${hex.slice(10).join("")}`;
  }

  function request({ method, params }) {
    if (typeof method !== "string" || method.length === 0) {
      return Promise.reject(new Error("stupid wallet: missing method"));
    }
    return new Promise((resolve, reject) => {
      const id = ++nextId;
      pending.set(id, { resolve, reject, method, params });
      post({
        __channel: SRC_CHANNEL,
        id,
        requestKey: `${providerSessionID}:${id}`,
        method,
        params,
      });
    });
  }

  window.addEventListener("message", (event) => {
    if (event.source !== window) return;
    const data = event.data;
    if (!data) return;
    if (data.__channel === EVENT_CHANNEL) {
      if (data.event === "chainChanged" && typeof data.value === "string") {
        const changed = ethereum.chainId !== null && ethereum.chainId !== data.value;
        ethereum.chainId = data.value;
        if (changed) emit("chainChanged", data.value);
      } else if (data.event === "accountsChanged") {
        updateAccounts(data.value);
      }
      return;
    }
    if (data.__channel !== DST_CHANNEL) return;
    const entry = pending.get(data.id);
    if (!entry) return;
    pending.delete(data.id);
    if (data.ok) {
      const method = entry.method.toLowerCase();
      if (method === "eth_chainid" && typeof data.result === "string") {
        ethereum.chainId = data.result;
      } else if (
        (method === "eth_accounts" ||
          method === "eth_requestaccounts" ||
          method === "wallet_connect") &&
        Array.isArray(data.result)
      ) {
        updateAccounts(data.result);
      } else if (method === "wallet_disconnect") {
        updateAccounts([]);
      }
      entry.resolve(data.result);
    } else {
      entry.reject(EIP1193Error(data.error, data.code, data.data));
    }
  });

  const ethereum = {
    isStupidWallet: true,
    chainId: null,
    accounts: [],
    request,
    on(event, listener) {
      if (typeof listener !== "function") return;
      const handlers = listeners.get(event) || new Set();
      handlers.add(listener);
      listeners.set(event, handlers);
    },
    removeListener(event, listener) {
      listeners.get(event)?.delete(listener);
    },
    removeAllListeners(event) {
      if (event === undefined) listeners.clear();
      else listeners.delete(event);
    },
  };
  window.ethereum = ethereum;

  function emit(event, value) {
    for (const listener of listeners.get(event) || []) listener(value);
  }

  function updateAccounts(value) {
    if (!Array.isArray(value) || value.some((account) => typeof account !== "string")) return;
    const next = value.slice();
    const changed =
      accounts.length !== next.length || accounts.some((account, index) => account !== next[index]);
    accounts = next;
    ethereum.accounts = next.slice();
    if (changed) emit("accountsChanged", next.slice());
  }

  // EIP-6963 discovery.
  const providerDetail = Object.freeze({
    info: Object.freeze({
      uuid: providerSessionID,
      name: "stupid wallet",
      icon: WALLET_ICON,
      rdns: "co.za.stephancill.stupid-wallet",
    }),
    provider: ethereum,
  });

  function announceProvider() {
    window.dispatchEvent(
      new CustomEvent("eip6963:announceProvider", {
        detail: providerDetail,
      }),
    );
  }

  window.addEventListener("eip6963:requestProvider", announceProvider);
  announceProvider();

  function EIP1193Error(message, code, data) {
    const err = new Error(message || "stupid wallet error");
    err.code = code || -32603;
    if (data !== undefined) err.data = data;
    return err;
  }
})();
