let wallet;
window.addEventListener("eip6963:announceProvider", (event) => {
  if (event.detail.info.name === "stupid wallet") wallet = event.detail.provider;
});
window.dispatchEvent(new Event("eip6963:requestProvider"));
document.getElementById("run").addEventListener("click", async () => {
  const output = document.getElementById("result");
  window.dispatchEvent(new Event("eip6963:requestProvider"));
  const lines = [];
  const record = (text) => {
    lines.push(text);
    output.textContent = lines.join("\n");
  };
  if (!wallet) {
    record("FAIL: Stupid Wallet was not discovered through EIP-6963.");
    return;
  }
  record("PASS: EIP-6963 discovered stupid wallet.");
  try {
    await wallet.request({ method: "eth_sign", params: [] });
    record("FAIL: eth_sign was allowed.");
  } catch (error) {
    record(`${error.code === 4200 ? "PASS" : "FAIL"}: eth_sign denied with code ${error.code}.`);
  }
  try {
    await wallet.request({ method: "eth_chainId" });
    record("FAIL: Proof host unexpectedly exposed wallet state.");
  } catch (error) {
    record(`PASS: Missing or disabled helper fails closed (${error.code}).`);
  }
});
