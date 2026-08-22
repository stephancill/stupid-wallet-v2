// Stupid Wallet service worker (background script).
// Owns method classification, prepares native approval requests, and routes
// completion back to the requesting tab once the popup resolves the request.
(() => {
    const pending = new Map(); // requestId -> { sendResponse }
    let account = null;

    function originFrom(sender) {
        if (sender && sender.origin) return sender.origin;
        if (sender && sender.tab && sender.tab.url) {
            try {
                return new URL(sender.tab.url).origin;
            } catch (e) {
                /* ignore */
            }
        }
        return "unknown";
    }

    // The flat native envelope matches the app's SafariWebExtensionHandler.
    function native({ action, method, params, origin, chainId, payload } = {}) {
        const message = { action };
        if (method !== undefined) message.method = method;
        if (params !== undefined) message.params = params;
        if (origin !== undefined) message.origin = origin;
        if (chainId !== undefined) message.chainId = chainId;
        if (payload !== undefined) message.payload = payload;
        return new Promise((resolve) => {
            browser.runtime.sendNativeMessage(undefined, message, (response) => {
                if (browser.runtime.lastError) {
                    resolve({ ok: false, error: String(browser.runtime.lastError.message) });
                } else {
                    resolve(response || { ok: false, error: "no native response" });
                }
            });
        });
    }

    function setBadge(text) {
        try {
            browser.action.setBadgeText({ text });
        } catch (e) {
            /* ignore */
        }
    }

    browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
        handle(message, sender, sendResponse);
        return true; // keep the channel open; we respond asynchronously
    });

    async function handle(message, sender, sendResponse) {
        try {
            switch (message.type) {
                case "ethereum.request":
                    return await route(message, sender, sendResponse);
                case "ethereum.status":
                    return await status(message, sendResponse);
                case "popup.getPending":
                    return getPending(sendResponse);
                case "popup.list":
                    // Read the durable native store (survives worker suspension).
                    const nativeList = await native({ action: "list" });
                    sendResponse(nativeList.ok && nativeList.data ? nativeList.data.pending : []);
                    return;
                case "popup.approve":
                    const approved = await native({
                        action: "approve",
                        payload: { requestId: message.requestId },
                    });
                    if (approved.ok && approved.data) {
                        sendResponse({ ok: true, signature: approved.data.signature });
                    } else {
                        sendResponse({ ok: false, error: approved.error || "approval failed" });
                    }
                    return;
                case "popup.reject":
                    await native({ action: "reject", payload: { requestId: message.requestId } });
                    sendResponse({ ok: true });
                    return;
                case "popup.resolve": {
                    const entry = pending.get(message.requestId);
                    if (!entry) {
                        sendResponse({ ok: false, error: "no matching pending request" });
                        return;
                    }
                    entry.sendResponse(message.result);
                    pending.delete(message.requestId);
                    setBadge(String(pending.size));
                    sendResponse({ ok: true });
                    return;
                }
                case "popup.reject-all":
                    for (const entry of pending.values()) {
                        entry.sendResponse({ error: { code: 4001, message: "User dismissed" } });
                    }
                    pending.clear();
                    setBadge("");
                    sendResponse({ ok: true });
                    return;
                default:
                    sendResponse({ error: { code: -32601, message: "Unknown background message" } });
            }
        } catch (error) {
            sendResponse({ error: { code: -32603, message: String(error) } });
        }
    }

    async function route(message, sender, sendResponse) {
        const method = message.method;
        const me = await native({ action: "me" });
        if (me.ok && me.data) account = me.data.account;

        if (method === "eth_accounts" || method === "eth_requestAccounts") {
            sendResponse(account ? [account] : []);
            return;
        }
        if (method === "eth_chainId") {
            sendResponse("0x1");
            return;
        }
        if (method === "net_version") {
            sendResponse("1");
            return;
        }

        if (method === "personal_sign") {
            const prepared = await native({
                action: "prepare",
                method,
                params: message.params,
                origin: originFrom(sender),
                chainId: "1",
            });
            if (!prepared.ok) {
                sendResponse({ error: { code: 4001, message: prepared.error } });
                return;
            }
            const requestId = prepared.data.requestId;
            pending.set(requestId, { sendResponse });
            setBadge(String(pending.size));
            // Hand the requestId to the bridge immediately; the bridge then polls
            // the native store for the result, so completion survives worker suspension.
            sendResponse({ __pendingId: requestId });
            return;
        }

        // Generic passthrough: forward every other method unchanged to the active RPC
        // through the single native resolver. Node results and structured errors return
        // untouched.
        const passthrough = await native({
            action: "passthrough",
            method,
            params: message.params ?? [],
            origin: originFrom(sender),
            chainId: "1",
        });
        if (passthrough.ok && passthrough.data && passthrough.data.result !== undefined) {
            sendResponse(passthrough.data.result);
            return;
        }
        const nodeError = passthrough ? passthrough.error : { code: -32603, message: "no response" };
        const code = nodeError && typeof nodeError === "object" && nodeError.code
            ? nodeError.code : -32603;
        sendResponse({ error: nodeError, code });
    }

    function getPending(sendResponse) {
        const ids = Array.from(pending.keys());
        Promise.all(
            ids.map((requestId) =>
                native({ action: "summary", payload: { requestId } }).then((summary) => ({
                    requestId,
                    ok: summary.ok,
                    data: summary.data || null,
                    error: summary.error || null,
                }))
            )
        ).then((list) => sendResponse({ pending: list }));
    }

    // Polled by the bridge: mirrors the persisted native status. This is a stateless
    // read on each poll, so a suspending service worker never loses the answer.
    async function status(message, sendResponse) {
        const res = await native({ action: "get", payload: { requestId: message.id } });
        if (!res.ok || !res.data) {
            pending.delete(message.id);
            setBadge(String(pending.size));
            sendResponse({ __missing: true });
            return;
        }
        if (res.data.status === "consumed" || res.data.status === "rejected") {
            pending.delete(message.id);
            setBadge(String(pending.size));
        }
        if (res.data.status === "consumed") {
            sendResponse({ __resolved: true, result: res.data.result });
            return;
        }
        if (res.data.status === "rejected") {
            sendResponse({ __error: "User rejected", code: 4001 });
            return;
        }
        sendResponse({ __pending: true });
    }
})();