// Isolated-world bridge: forwards provider requests to the background service
// worker and relays responses back to the MAIN world provider. For approval
// methods the background returns a pendingId; the bridge polls native status
// until the request is consumed/rejected, so worker suspension cannot strand the
// dapp's promise.
(() => {
  const SRC_CHANNEL = "__stupid-wallet:request";
  const DST_CHANNEL = "__stupid-wallet:response";
  const EVENT_CHANNEL = "__stupid-wallet:event";

  browser.runtime.onMessage.addListener((message) => {
    if (message?.type !== "wallet.chainChanged" || typeof message.chainIdHex !== "string") {
      return;
    }
    postChainChanged(message.chainIdHex);
  });

  browser.runtime.sendMessage({ type: "wallet.getChain" }).then((chain) => {
    if (chain && typeof chain.chainIdHex === "string") postChainChanged(chain.chainIdHex);
  });

  window.addEventListener("message", (event) => {
    if (event.source !== window) return;
    const data = event.data;
    if (!data || data.__channel !== SRC_CHANNEL) return;
    if (typeof data.requestKey !== "string" || data.requestKey.length > 128) return;

    browser.runtime
      .sendMessage({
        type: "ethereum.request",
        requestKey: data.requestKey,
        method: data.method,
        params: data.params,
      })
      .then(
        (result) => {
          if (!result || result.__envelope !== true) {
            respond(data.id, false, "Unexpected extension response");
            return;
          }
          if (result.ok && result.pendingId) {
            pollPending(data.id, result.pendingId);
          } else if (result.ok) {
            respond(data.id, true, result.result);
          } else {
            respond(data.id, false, errorShape(result.error));
          }
        },
        async (error) => {
          // The service worker may have been suspended between the page message and its
          // response (e.g. the Safari window was switched away). Retries preserve the
          // provider-session request key, so native preparation can distinguish a transport
          // retry from a separate, deliberately identical request.
          for (let attempt = 0; attempt < 2; attempt++) {
            await sleep(600 * (attempt + 1));
            const retried = await browser.runtime
              .sendMessage({
                type: "ethereum.request",
                requestKey: data.requestKey,
                method: data.method,
                params: data.params,
              })
              .catch(() => null);
            if (retried && retried.__envelope === true) {
              if (retried.ok && retried.pendingId) pollPending(data.id, retried.pendingId);
              else if (retried.ok) respond(data.id, true, retried.result);
              else respond(data.id, false, errorShape(retried.error));
              return;
            }
          }
          respond(data.id, false, errorMessage(error));
        },
      );
  });

  function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  function postChainChanged(chainId) {
    window.postMessage({ __channel: EVENT_CHANNEL, event: "chainChanged", value: chainId }, "*");
  }

  async function pollPending(id, requestId) {
    for (let attempt = 0; attempt < 600; attempt++) {
      // Back off so a waiting request does not saturate the native plugin with a `get`
      // every second (which delays the popup's own `list` call behind the queue).
      await sleep(Math.min(1000 + attempt * 250, 4000));
      let reply;
      try {
        reply = await browser.runtime.sendMessage({
          type: "ethereum.status",
          id: requestId,
        });
      } catch {
        continue; // worker waking up; retry
      }
      if (reply && reply.__resolved) {
        hideNotice();
        respond(id, true, reply.result);
        return;
      }
      if (reply && reply.__error) {
        hideNotice();
        respond(id, false, { message: reply.__error, code: reply.code, data: reply.data });
        return;
      }
      if (reply && reply.__missing) {
        hideNotice();
        respond(id, false, { message: "Request no longer available", code: -32603 });
        return;
      }
      // Pending: surface a non-authoritative "open the Safari toolbar" hint.
      showNotice();
    }
    hideNotice();
    respond(id, false, { message: "Request timed out", code: -32603 });
  }

  // --- In-page notice (status + instructions; NEVER approval authority) ---
  const NOTICE_ID = "__stupid-wallet-pending-notice";
  let notice;

  function showNotice() {
    if (notice) return;
    notice = document.createElement("div");
    notice.id = NOTICE_ID;

    const icon = document.createElement("img");
    icon.src = browser.runtime.getURL("icon-48.png");
    icon.alt = "";
    icon.setAttribute("aria-hidden", "true");
    icon.style.cssText = [
      "display:block",
      "width:28px",
      "height:28px",
      "flex:0 0 28px",
      "border-radius:7px",
    ].join(";");

    const copy = document.createElement("span");
    copy.style.cssText = ["display:grid", "gap:1px", "min-width:0"].join(";");

    const title = document.createElement("span");
    title.textContent = "Open stupid wallet";
    title.style.cssText = ["font-size:13px", "font-weight:600", "line-height:17px"].join(";");

    const instruction = document.createElement("span");
    instruction.textContent = "Tap the extension in Safari to continue";
    instruction.style.cssText = [
      "color:rgba(17,17,19,0.62)",
      "font-size:12px",
      "font-weight:400",
      "line-height:16px",
    ].join(";");

    copy.append(title, instruction);
    notice.append(icon, copy);
    notice.setAttribute("role", "status");
    notice.style.cssText = [
      "position:fixed",
      "top:max(12px, env(safe-area-inset-top))",
      "left:50%",
      "transform:translateX(-50%)",
      "z-index:2147483647",
      "pointer-events:none",
      "display:flex",
      "align-items:center",
      "gap:10px",
      "box-sizing:border-box",
      "width:max-content",
      "max-width:calc(100vw - 24px)",
      "padding:8px 12px 8px 8px",
      "border:1px solid rgba(17,17,19,0.08)",
      "border-radius:14px",
      "background:rgba(250,250,250,0.94)",
      "box-shadow:0 6px 20px rgba(0,0,0,0.14)",
      "backdrop-filter:blur(16px)",
      "-webkit-backdrop-filter:blur(16px)",
      "color:#111113",
      "font-family:-apple-system, BlinkMacSystemFont, system-ui, sans-serif",
      "text-align:left",
    ].join(";");
    document.documentElement.appendChild(notice);
  }

  function hideNotice() {
    if (!notice) return;
    const el = notice;
    notice = null;
    try {
      el.remove();
    } catch {
      /* ignore */
    }
  }

  function respond(id, ok, payload) {
    const message = { __channel: DST_CHANNEL, id, ok };
    if (ok) {
      message.result = payload;
    } else {
      if (payload && typeof payload === "object" && payload.code !== undefined) {
        message.error = payload.message || "stupid wallet error";
        message.code = payload.code;
        if (payload.data !== undefined) message.data = payload.data;
      } else {
        message.error = payload;
      }
    }
    window.postMessage(message, "*");
  }

  // Normalize a structured error into `{ message, code }` for the page provider.
  function errorShape(err) {
    if (err && typeof err === "object") {
      return { message: err.message || String(err), code: err.code, data: err.data };
    }
    return { message: String(err || "Unknown error") };
  }

  function errorMessage(error) {
    if (error && error.message) return error.message;
    return String(error || "Unknown error");
  }
})();
