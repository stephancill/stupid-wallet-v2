// Isolated-world bridge: forwards provider requests to the background service
// worker and relays responses back to the MAIN world provider. For approval
// methods the background returns a pendingId; the bridge polls native status
// until the request is consumed/rejected, so worker suspension cannot strand the
// dapp's promise.
(() => {
  const SRC_CHANNEL = "__stupid-wallet:request";
  const DST_CHANNEL = "__stupid-wallet:response";

  window.addEventListener("message", (event) => {
    if (event.source !== window) return;
    const data = event.data;
    if (!data || data.__channel !== SRC_CHANNEL) return;

    browser.runtime
      .sendMessage({ type: "ethereum.request", method: data.method, params: data.params })
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
        (error) => respond(data.id, false, errorMessage(error)),
      );
  });

  function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  async function pollPending(id, requestId) {
    for (let attempt = 0; attempt < 600; attempt++) {
      await sleep(1000);
      let reply;
      try {
        reply = await browser.runtime.sendMessage({
          type: "ethereum.status",
          id: requestId,
        });
      } catch (err) {
        continue; // worker waking up; retry
      }
      if (reply && reply.__resolved) {
        hideNotice();
        respond(id, true, reply.result);
        return;
      }
      if (reply && reply.__error) {
        hideNotice();
        respond(id, false, { message: reply.__error, code: reply.code });
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
    const text = document.createElement("span");
    text.textContent =
      "Signature request pending — tap the Stup to Wallet icon in the Safari toolbar to approve.";
    notice.appendChild(text);
    notice.setAttribute("role", "status");
    notice.style.cssText = [
      "position:fixed",
      "top:12px",
      "left:50%",
      "transform:translateX(-50%)",
      "z-index:2147483647",
      "pointer-events:none",
      "background:rgba(20,22,28,0.92)",
      "color:#fff",
      "font:600 13px -apple-system, system-ui, sans-serif",
      "padding:9px 14px",
      "border-radius:999px",
      "box-shadow:0 2px 10px rgba(0,0,0,0.25)",
      "max-width:86vw",
      "text-align:center",
    ].join(";");
    document.documentElement.appendChild(notice);
  }

  function hideNotice() {
    if (!notice) return;
    const el = notice;
    notice = null;
    try {
      el.remove();
    } catch (e) {
      /* ignore */
    }
  }

  function respond(id, ok, payload) {
    const message = { __channel: DST_CHANNEL, id, ok };
    if (ok) {
      message.result = payload;
    } else {
      if (payload && typeof payload === "object" && payload.code !== undefined) {
        message.error = payload.message || "Stupid Wallet error";
        message.code = payload.code;
      } else {
        message.error = payload;
      }
    }
    window.postMessage(message, "*");
  }

  // Normalize a structured error into `{ message, code }` for the page provider.
  function errorShape(err) {
    if (err && typeof err === "object") {
      return { message: err.message || String(err), code: err.code };
    }
    return { message: String(err || "Unknown error") };
  }

  function errorMessage(error) {
    if (error && error.message) return error.message;
    return String(error || "Unknown error");
  }
})();
