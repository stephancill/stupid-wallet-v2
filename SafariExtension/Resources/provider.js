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
  let nextId = 0;
  const pending = new Map();
  const listeners = new Map();

  function post(message) {
    window.postMessage(message, "*");
  }

  function request({ method, params }) {
    if (typeof method !== "string" || method.length === 0) {
      return Promise.reject(new Error("Stupid Wallet: missing method"));
    }
    return new Promise((resolve, reject) => {
      const id = ++nextId;
      pending.set(id, { resolve, reject, method, params });
      post({ __channel: SRC_CHANNEL, id, method, params });
    });
  }

  window.addEventListener("message", (event) => {
    if (event.source !== window) return;
    const data = event.data;
    if (!data) return;
    if (data.__channel === EVENT_CHANNEL && data.event === "chainChanged") {
      if (typeof data.value === "string") {
        const changed = ethereum.chainId !== null && ethereum.chainId !== data.value;
        ethereum.chainId = data.value;
        if (changed) emit("chainChanged", data.value);
      }
      return;
    }
    if (data.__channel !== DST_CHANNEL) return;
    const entry = pending.get(data.id);
    if (!entry) return;
    pending.delete(data.id);
    if (data.ok) {
      if (entry.method.toLowerCase() === "eth_chainid" && typeof data.result === "string") {
        ethereum.chainId = data.result;
      }
      entry.resolve(data.result);
    } else {
      entry.reject(EIP1193Error(data.error, data.code, data.data));
    }
  });

  const ethereum = {
    isStupidWallet: true,
    chainId: null,
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

  // EIP-6963 discovery.
  window.dispatchEvent(
    new CustomEvent("eip6963:announceProvider", {
      detail: {
        info: {
          uuid: "b0a2c3d4-e5f6-7a89-0b1c-2d3e4f506172",
          name: "Stupid Wallet",
          icon: "",
          rdns: "co.za.stephancill.stupid-wallet",
        },
        provider: ethereum,
      },
    }),
  );

  function EIP1193Error(message, code, data) {
    const err = new Error(message || "Stupid Wallet error");
    err.code = code || -32603;
    if (data !== undefined) err.data = data;
    return err;
  }
})();
