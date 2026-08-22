// Stupid Wallet EIP-1193 provider.
// Runs in the MAIN world of the page. It cannot touch WebExtension APIs, so it
// relays JSON-RPC requests to the isolated-world bridge via window.postMessage.
// It never sees private keys or signs anything.
(() => {
  if (window.__StupidWallet) return;
  window.__StupidWallet = true;

  const SRC_CHANNEL = "__stupid-wallet:request";
  const DST_CHANNEL = "__stupid-wallet:response";
  let nextId = 0;
  const pending = new Map();

  function post(message) {
    window.postMessage(message, "*");
  }

  function request({ method, params }) {
    if (typeof method !== "string" || method.length === 0) {
      return Promise.reject(new Error("Stupid Wallet: missing method"));
    }
    return new Promise((resolve, reject) => {
      const id = ++nextId;
      pending.set(id, { resolve, reject });
      post({ __channel: SRC_CHANNEL, id, method, params });
    });
  }

  window.addEventListener("message", (event) => {
    if (event.source !== window) return;
    const data = event.data;
    if (!data || data.__channel !== DST_CHANNEL) return;
    const entry = pending.get(data.id);
    if (!entry) return;
    pending.delete(data.id);
    if (data.ok) entry.resolve(data.result);
    else entry.reject(EIP1193Error(data.error, data.code));
  });

  const ethereum = {
    isStupidWallet: true,
    chainId: "0x1",
    request,
    on() {},
    removeListener() {},
    removeAllListeners() {},
  };
  window.ethereum = ethereum;

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

  function EIP1193Error(message, code) {
    const err = new Error(message || "Stupid Wallet error");
    err.code = code || -32603;
    return err;
  }
})();
