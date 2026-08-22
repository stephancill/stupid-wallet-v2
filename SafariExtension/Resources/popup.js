// Stupid Wallet popup: the Safari-owned review surface. It renders the native
// summaries (via the background worker, which owns native messaging) and submits
// only a request ID + decision. On iOS the popup must reach native through the
// background; direct popup->native messaging is unreliable here.
(() => {
    function call(message) {
        return browser.runtime.sendMessage(message).catch(() => null);
    }

    const tray = document.getElementById("tray");

    function render(items) {
        tray.textContent = "";
        if (!items || items.length === 0) {
            const box = document.createElement("div");
            box.className = "standby";
            box.innerHTML = `<div class="emoji">🔒</div><p>No pending signatures. Open a dapp and request a sign-in.</p>`;
            tray.appendChild(box);
            return;
        }
        for (const item of items) {
            tray.appendChild(requestCard(item));
        }
    }

    function requestCard(item) {
        const data = item.data || item || {};
        const requestId = item.requestId || data.id;
        const card = document.createElement("section");
        card.className = "request";

        const host = document.createElement("div");
        try {
            host.textContent = new URL(data.origin || "").host;
        } catch (e) {
            host.textContent = data.origin || "unknown";
        }
        host.className = "sub";

        const title = document.createElement("h2");
        title.textContent = "Sign message";

        card.appendChild(title);
        card.appendChild(host);
        card.appendChild(rowLabel("From", data.origin || "—"));
        card.appendChild(rowLabel("Account", short(data.account)));
        card.appendChild(rowLabel("Method", (data.method || "") + " · " + (data.chainId || "1")));

        if (data.message) {
            const msg = document.createElement("div");
            msg.className = "message";
            msg.textContent = data.message;
            card.appendChild(msg);
        }

        const warn = document.createElement("div");
        warn.className = "warn";
        warn.textContent = "⚠️ This message could act on your behalf. Only sign if you trust it.";
        card.appendChild(warn);

        const actions = document.createElement("div");
        actions.className = "actions";

        const reject = document.createElement("button");
        reject.className = "reject";
        reject.textContent = "Cancel";
        reject.addEventListener("click", () => decide(requestId, false, reject));

        const approve = document.createElement("button");
        approve.className = "approve";
        approve.textContent = "Approve & Face ID";
        approve.addEventListener("click", () => decide(requestId, true, approve));

        actions.appendChild(reject);
        actions.appendChild(approve);
        card.appendChild(actions);
        return card;
    }

    function rowLabel(key, value) {
        const el = document.createElement("div");
        el.className = "row";
        const k = document.createElement("span");
        k.className = "k";
        k.textContent = key;
        const v = document.createElement("span");
        v.className = (value || "").startsWith("0x") ? "addr" : "";
        v.textContent = value;
        el.appendChild(k);
        el.appendChild(v);
        return el;
    }

    function short(addr) {
        if (!addr || addr.length <= 12) return addr || "—";
        return addr.slice(0, 6) + "…" + addr.slice(-4);
    }

    function decide(requestId, approve, button) {
        button.disabled = true;
        call({
            type: approve ? "popup.approve" : "popup.reject",
            requestId: requestId,
        }).then(() => {
            if (window.close) window.close();
        });
    }

    function refresh() {
        call({ type: "popup.list" }).then((reply) => {
            render(Array.isArray(reply) ? reply : []);
        });
        // Retry shortly if the background worker was still waking up.
        setTimeout(() => {
            if (!tray.hasChildNodes()) {
                call({ type: "popup.list" }).then((reply) => {
                    render(Array.isArray(reply) ? reply : []);
                });
            }
        }, 1500);
    }

    refresh();
})();