globalThis.walletChromeReady = (async () => {
  const api = globalThis.browser ?? globalThis.chrome;
  const tray = document.getElementById("tray");
  const setup = document.createElement("a");
  setup.href = api.runtime.getURL("pairing.html");
  setup.target = "_blank";
  setup.textContent = "Manage Chrome pairing";
  document.body.appendChild(setup);
  try {
    const result = await api.runtime.sendMessage({ type: "pairing.status" });
    if (result?.ok && result.paired) return true;
    tray.textContent = result?.ok
      ? "Pair Chrome with Stupid Wallet to review requests."
      : result?.error?.message ||
        "Wallet helper unavailable. Update the helper and extension together.";
  } catch {
    tray.textContent = "Wallet helper unavailable. Update the helper and extension together.";
  }
  return false;
})();
