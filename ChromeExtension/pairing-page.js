const api = globalThis.browser ?? globalThis.chrome;
const status = document.getElementById("status");
const code = document.getElementById("code");
const begin = document.getElementById("begin");
const confirm = document.getElementById("confirm");
const revoke = document.getElementById("revoke");
async function send(type) {
  const reply = await api.runtime.sendMessage({ type });
  if (!reply?.ok) throw new Error(reply?.error?.message || "Pairing unavailable. Reopen setup.");
  return reply;
}
async function run(operation) {
  for (const button of [begin, confirm, revoke]) button.disabled = true;
  try {
    await operation();
  } catch (error) {
    status.textContent = error.message;
  } finally {
    for (const button of [begin, confirm, revoke]) button.disabled = false;
  }
}
async function refresh() {
  const reply = await send("pairing.status");
  status.textContent = reply.paired
    ? "This Chrome profile is paired. You can close this tab and reopen the wallet popup."
    : "This Chrome profile needs pairing.";
  revoke.hidden = !reply.paired;
  begin.textContent = reply.paired ? "Replace pairing" : "Start pairing";
}
begin.onclick = () =>
  run(async () => {
    const reply = await send("pairing.begin");
    code.textContent = `Pairing code: ${reply.code}`;
    status.textContent =
      "Compare this code with the native helper. Only approve if both match. This code expires after two minutes.";
    confirm.hidden = false;
  });
confirm.onclick = () =>
  run(async () => {
    confirm.hidden = true;
    status.textContent = "Confirm the matching code in the native helper.";
    await send("pairing.confirm");
    code.textContent = "";
    await refresh();
  });
revoke.onclick = () =>
  run(async () => {
    await send("pairing.revoke");
    code.textContent = "";
    await refresh();
  });
run(refresh);
