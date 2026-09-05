import {
  recoverMessageAddress,
  recoverTypedDataAddress,
} from "../../PrototypeDapp/node_modules/viem/_esm/index.js";
let wallet;
addEventListener("eip6963:announceProvider", (event) => {
  if (
    event.detail?.info?.rdns === "net.stupidtech.wallet" ||
    event.detail?.info?.name?.toLowerCase().includes("stupid")
  )
    wallet = event.detail.provider;
});
dispatchEvent(new Event("eip6963:requestProvider"));
const result = document.querySelector("pre");
function show(text) {
  result.textContent = text;
}
async function run(action) {
  try {
    if (!wallet)
      throw new Error(
        "Wallet provider not discovered. Reload this tab after reloading the extension.",
      );
    await action();
  } catch (error) {
    show(`FAILED (${error.code ?? "error"}): ${error.message}`);
  }
}
document.querySelector("#connect").onclick = () =>
  run(async () => {
    show("Waiting for connection review in the wallet toolbar…");
    const accounts = await wallet.request({ method: "eth_requestAccounts" });
    show(
      accounts.length === 1 ? "PASS: wallet connected." : "FAILED: expected one active account.",
    );
  });
document.querySelector("#message").onclick = () =>
  run(async () => {
    const [account] = await wallet.request({ method: "eth_accounts" });
    if (!account) throw new Error("Connect the wallet first.");
    const message = `Stupid Wallet Chrome acceptance. No permissions or transactions. ${crypto.randomUUID()}`;
    const hex =
      "0x" +
      [...new TextEncoder().encode(message)].map((x) => x.toString(16).padStart(2, "0")).join("");
    show("Waiting for message review and fresh authentication…");
    const signature = await wallet.request({ method: "personal_sign", params: [hex, account] });
    const recovered = await recoverMessageAddress({ message, signature });
    show(
      recovered.toLowerCase() === account.toLowerCase()
        ? "PASS: authenticated signature independently recovered to the connected wallet."
        : "FAILED: signer mismatch.",
    );
  });
document.querySelector("#typed").onclick = () =>
  run(async () => {
    const [account] = await wallet.request({ method: "eth_accounts" });
    if (!account) throw new Error("Connect the wallet first.");
    const chainId = Number(await wallet.request({ method: "eth_chainId" }));
    const data = {
      domain: { name: "Stupid Wallet local acceptance", version: "1", chainId },
      primaryType: "Acceptance",
      types: { Acceptance: [{ name: "message", type: "string" }] },
      message: { message: `No permissions or transactions. ${crypto.randomUUID()}` },
    };
    show("Waiting for typed-data review and fresh authentication…");
    const signature = await wallet.request({
      method: "eth_signTypedData_v4",
      params: [account, JSON.stringify(data)],
    });
    const recovered = await recoverTypedDataAddress({ ...data, signature });
    show(
      recovered.toLowerCase() === account.toLowerCase()
        ? "PASS: typed-data signature independently recovered to the connected wallet."
        : "FAILED: signer mismatch.",
    );
  });
document.querySelector("#rpc").onclick = () =>
  run(async () => {
    const chain = await wallet.request({ method: "eth_chainId" });
    const block = await wallet.request({ method: "eth_blockNumber" });
    show(`PASS: native RPC chain ${chain}; block ${block}.`);
  });
document.querySelector("#disconnect").onclick = () =>
  run(async () => {
    await wallet.request({ method: "wallet_disconnect" });
    show("Disconnected local acceptance site.");
  });
