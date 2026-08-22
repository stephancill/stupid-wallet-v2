// Stupid Wallet popup: the Safari-owned review surface. It renders the native canonical
// summaries (via the background worker, which owns native messaging) and submits only a
// request ID + decision. It never interprets signing params itself. On iOS the popup
// must reach native through the background; direct popup->native is unreliable here.
(() => {
  function call(message) {
    return browser.runtime.sendMessage(message).catch(() => null);
  }

  const tray = document.getElementById("tray");
  const chainPill = document.getElementById("chain");

  const KIND_ICON = {
    connect: "🔗",
    message: "✍️",
    typedData: "🧾",
    send: "💸",
    chain: "🛜",
    denied: "🚫",
    passthrough: "🔄",
  };

  function render(items) {
    tray.textContent = "";
    if (!items || items.length === 0) {
      const box = document.createElement("div");
      box.className = "standby";
      box.innerHTML = `<div class="emoji">🔒</div><p>No pending requests. Open a dapp to connect or sign.</p>`;
      tray.appendChild(box);
      return;
    }
    for (const item of items) {
      tray.appendChild(requestCard(item));
    }
    if (items.length > 1) {
      const note = document.createElement("p");
      note.className = "queue-note";
      note.textContent = "Requests are handled one at a time in order.";
      tray.appendChild(note);
    }
  }

  function requestCard(item) {
    const data = item.data || item || {};
    const requestId = item.requestId || data.id;
    const kind = data.kind || "message";
    const card = document.createElement("section");
    card.className = "request" + (data.queued ? " queued" : "");

    const host = document.createElement("div");
    try {
      host.textContent = new URL(data.origin || "").host || data.origin || "unknown";
    } catch (e) {
      host.textContent = data.origin || "unknown";
    }
    host.className = "sub";

    const title = document.createElement("h2");
    title.textContent = `${KIND_ICON[kind] || "📄"} ${data.title || "Request"}`;

    card.appendChild(title);
    card.appendChild(host);

    const rows = data.rows || [];
    for (const row of rows) {
      card.appendChild(rowLabel(row.label, row.value));
    }

    if (kindsDangerous(kind)) {
      const warn = document.createElement("div");
      warn.className = "warn";
      warn.textContent =
        "This could act on your behalf. Only approve if you trust the site and check the details.";
      card.appendChild(warn);
    }

    const actions = document.createElement("div");
    actions.className = "actions";

    const reject = document.createElement("button");
    reject.className = "reject";
    reject.textContent = "Cancel";
    reject.addEventListener("click", () => decide(requestId, false, reject));

    const approve = document.createElement("button");
    approve.className = "approve";
    approve.textContent = data.queued ? "Queued" : "Approve";
    approve.disabled = !!data.queued;
    approve.addEventListener("click", () => decide(requestId, true, approve));

    actions.appendChild(reject);
    actions.appendChild(approve);
    card.appendChild(actions);
    return card;
  }

  function kindsDangerous(kind) {
    return kind === "message" || kind === "typedData" || kind === "send";
  }

  function rowLabel(key, value) {
    const el = document.createElement("div");
    el.className = "row";
    const k = document.createElement("span");
    k.className = "k";
    k.textContent = key;
    const v = document.createElement("span");
    v.className = (value || "").startsWith("0x") ? "addr" : "val";
    v.textContent = value == null ? "—" : value;
    el.appendChild(k);
    el.appendChild(v);
    return el;
  }

  function decide(requestId, approve, button) {
    button.disabled = true;
    call({
      type: approve ? "popup.approve" : "popup.reject",
      requestId: requestId,
    }).then((reply) => {
      if (reply && reply.error) {
        const toast = document.createElement("div");
        toast.className = "toast";
        toast.textContent = reply.message || String(reply.error);
        tray.insertBefore(toast, tray.firstChild);
        button.disabled = false;
        return;
      }
      if (window.close) window.close();
    });
  }

  function refresh() {
    call({ type: "popup.list" }).then((reply) => {
      render(Array.isArray(reply) ? reply : []);
      updateChain(reply);
    });
    // Retry shortly if the background worker was still waking up.
    setTimeout(() => {
      if (!tray.hasChildNodes()) {
        call({ type: "popup.list" }).then((reply) => {
          render(Array.isArray(reply) ? reply : []);
          updateChain(reply);
        });
      }
    }, 1500);
  }

  function updateChain(reply) {
    if (reply && reply.length > 0) {
      const first = reply[0].data || reply[0] || {};
      const chainId = first.chainId;
      if (chainId) chainPill.textContent = chainId === "1" ? "Ethereum" : `Chain ${chainId}`;
    }
  }

  refresh();
})();
