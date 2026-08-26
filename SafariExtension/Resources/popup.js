// Safari-owned review surface. Every displayed value comes from the native canonical
// summary; approval submits only the persisted request ID.
(() => {
  const NATIVE_APP_ID = "co.za.stephancill.stupid-wallet";
  const tray = document.getElementById("tray");

  const PRESENTATION = {
    connect: {
      description: "This site wants to connect to your wallet.",
      primary: "Connect",
    },
    siwe: {
      description: "Review the sign-in details before signing.",
      primary: "Sign In",
    },
    message: {
      description: "Review the message before signing.",
      primary: "Sign",
    },
    typedData: {
      description: "Review the structured data before signing.",
      primary: "Sign",
    },
    send: {
      description: "Review the transaction before sending.",
      primary: "Send",
    },
    batch: {
      description: "Review the calls that will execute.",
      primary: "Send Calls",
    },
    chain: {
      description: "Review the network details before adding it.",
      primary: "Add",
    },
  };

  function directNative(action, payload) {
    const message = { action };
    if (payload !== undefined) message.payload = payload;
    return new Promise((resolve) => {
      browser.runtime.sendNativeMessage(NATIVE_APP_ID, message, (response) => {
        if (browser.runtime.lastError) {
          resolve(null);
        } else {
          resolve(response || null);
        }
      });
    });
  }

  async function native(action, payload) {
    const direct = await directNative(action, payload);
    if (direct !== null) return direct;

    // Direct popup-to-native messaging is reliable on macOS Safari. Retain the worker
    // fallback for Safari environments where only background-to-native is available.
    const message = { type: `popup.${action}` };
    if (payload !== undefined) Object.assign(message, payload);
    return browser.runtime.sendMessage(message).catch(() => null);
  }

  function hostFor(origin) {
    try {
      return new URL(origin || "").host || origin || "Unknown";
    } catch {
      return origin || "Unknown";
    }
  }

  function render(items) {
    tray.textContent = "";
    if (!items || items.length === 0) {
      const standby = document.createElement("div");
      standby.className = "standby";
      const title = document.createElement("strong");
      title.textContent = "No pending requests";
      const detail = document.createElement("p");
      detail.textContent = "Open an app to connect, sign, or send.";
      standby.append(title, detail);
      tray.appendChild(standby);
      return;
    }

    for (const item of items) tray.appendChild(requestView(item));
    if (items.length > 1) {
      const note = document.createElement("p");
      note.className = "queue-note";
      note.textContent = "Requests are handled one at a time in order.";
      tray.appendChild(note);
    }
  }

  function requestView(item) {
    const data = item.data || item || {};
    const requestId = item.requestId || data.id;
    const kind = data.kind || "message";
    const presentation = PRESENTATION[kind] || {
      description: "Review this request before continuing.",
      primary: "Confirm",
    };
    const rows = Array.isArray(data.rows) ? data.rows : [];
    const account = data.account || rowValue(rows, "Account");
    const section = document.createElement("section");
    section.className = `request request-${kind}${data.queued ? " queued" : ""}`;

    const heading = document.createElement("div");
    heading.className = "request-heading";
    const title = document.createElement("h1");
    title.textContent = data.title || "Wallet request";
    heading.appendChild(title);
    if (data.queued) {
      const badge = document.createElement("span");
      badge.className = "queue-badge";
      badge.textContent = "Queued";
      heading.appendChild(badge);
      heading.setAttribute("role", "button");
      heading.setAttribute("tabindex", "0");
      heading.setAttribute("aria-expanded", "false");
      const toggle = () => {
        const collapsed = section.classList.toggle("collapsed");
        heading.setAttribute("aria-expanded", String(!collapsed));
      };
      heading.addEventListener("click", toggle);
      heading.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") return;
        event.preventDefault();
        toggle();
      });
    }
    section.appendChild(heading);

    const body = document.createElement("div");
    body.className = "request-body";

    const intro = document.createElement("p");
    intro.className = "intro";
    intro.textContent = presentation.description;
    body.appendChild(intro);

    const messageRows = rows.filter((row) => row.label === "Message");
    const typedMessageRows = rows.filter((row) => row.label.startsWith("Message / "));
    const domainRows = rows.filter((row) =>
      ["Domain", "Version", "Domain Chain", "Contract"].includes(row.label),
    );
    const detailRows = rows.filter(
      (row) =>
        ![
          "Origin",
          "From",
          "Account",
          "Message",
          "Domain",
          "Version",
          "Domain Chain",
          "Contract",
        ].includes(row.label) && !row.label.startsWith("Message / "),
    );
    const transactionRows =
      kind === "send"
        ? detailRows.filter((row) => !["Chain", "Value", "Network Fee"].includes(row.label))
        : [];
    const batchRows = kind === "batch" ? batchCallRows(detailRows) : [];
    const summaryRows = detailRows.filter(
      (row) =>
        !transactionRows.includes(row) &&
        !isBatchCallRow(row) &&
        !(kind === "batch" && row.label === "Calls"),
    );

    const summary = document.createElement("div");
    summary.className = "summary";
    appendSummaryRow(summary, "Site", hostFor(data.origin), true);
    for (const row of summaryRows) appendSummaryRow(summary, row.label, row.value);
    body.appendChild(summary);

    if (transactionRows.length > 0) appendSection(body, "Details", transactionRows);
    if (batchRows.length > 0) appendBatchSection(body, batchRows);

    if (domainRows.length > 0) {
      appendSection(
        body,
        "Domain",
        domainRows.map((row) => ({
          label:
            row.label === "Domain"
              ? "Name"
              : row.label === "Contract"
                ? "Verifying Contract"
                : row.label === "Domain Chain"
                  ? "Chain"
                  : row.label,
          value: row.value,
        })),
      );
    }
    if (messageRows.length > 0) appendSection(body, "Message", messageRows.map(unlabelled));
    if (typedMessageRows.length > 0) {
      appendSection(
        body,
        "Message",
        typedMessageRows.map((row) => ({
          label: row.label.slice("Message / ".length),
          value: row.value,
        })),
      );
    }

    body.appendChild(
      actionsFor({
        requestId,
        data,
        primary: presentation.primary,
        account,
      }),
    );
    section.appendChild(body);
    if (data.queued) section.classList.add("collapsed");
    return section;
  }

  function rowValue(rows, label) {
    return rows.find((row) => row.label === label)?.value;
  }

  function unlabelled(row) {
    return { label: "", value: row.value };
  }

  function appendSummaryRow(container, label, value, emphasis = false) {
    const key = document.createElement("div");
    key.className = "row-label";
    key.textContent = label;
    const content = document.createElement("div");
    content.className = `row-value${emphasis ? " emphasis" : ""}`;
    appendDisplayValue(content, value);
    container.append(key, content);
  }

  function appendSection(container, titleText, rows) {
    const section = document.createElement("section");
    section.className = "section";
    const title = document.createElement("h2");
    title.textContent = titleText;
    section.append(title, detailTable(rows));
    container.appendChild(section);
  }

  function detailTable(rows) {
    const list = document.createElement("div");
    list.className = "section-list";
    for (const row of rows) {
      const item = document.createElement("div");
      item.className = "section-row";
      if (row.label) {
        const label = document.createElement("div");
        label.className = "section-label";
        label.textContent = row.label;
        item.appendChild(label);
      }
      const address = isAddress(String(row.value ?? ""));
      const value = document.createElement(row.label === "Data" || address ? "div" : "pre");
      value.className = "message-value";
      appendDisplayValue(value, row.value, { calldata: row.label === "Data" });
      item.appendChild(value);
      list.appendChild(item);
    }
    return list;
  }

  function isBatchCallRow(row) {
    return /^Call \d+ (Target|Value|Data)$/.test(row.label);
  }

  function batchCallRows(rows) {
    const calls = [];
    for (const row of rows) {
      const match = /^Call (\d+) (Target|Value|Data)$/.exec(row.label);
      if (!match) continue;
      const index = Number(match[1]) - 1;
      calls[index] ||= {};
      calls[index][match[2].toLowerCase()] = row.value;
    }
    return calls.filter(Boolean);
  }

  function appendBatchSection(container, calls) {
    const section = document.createElement("section");
    section.className = "section";
    const title = document.createElement("h2");
    title.textContent = `Details (${calls.length} ${calls.length === 1 ? "call" : "calls"})`;
    const list = document.createElement("div");
    list.className = "call-list";
    for (const call of calls) {
      const rows = [{ label: "To", value: call.target }];
      if (call.value && !call.value.startsWith("0 ")) {
        rows.push({ label: "Value", value: call.value });
      }
      if (call.data && call.data !== "0x") {
        rows.push({ label: "Data", value: call.data });
      }
      list.appendChild(detailTable(rows));
    }
    section.append(title, list);
    container.appendChild(section);
  }

  function appendDisplayValue(container, value, { calldata = false } = {}) {
    const display = value == null ? "Unavailable" : String(value);
    if (isAddress(display)) {
      container.appendChild(addressView(display));
      return;
    }
    if (calldata) {
      container.appendChild(calldataView(display));
      return;
    }
    container.textContent = display;
  }

  function isAddress(value) {
    return /^0x[0-9a-f]{40}$/i.test(value);
  }

  function addressView(address, label) {
    const value = document.createElement("span");
    value.className = "address-value";
    value.title = address;
    const blockie = document.createElement("span");
    blockie.className = "blockie";
    blockie.setAttribute("aria-hidden", "true");
    appendBlockiePixels(blockie, address.toLowerCase());
    const text = document.createElement("span");
    if (label) text.className = "account-label";
    text.textContent = label || `${address.slice(0, 6)}...${address.slice(-4)}`;
    value.append(blockie, text);
    return value;
  }

  function appendBlockiePixels(container, seed) {
    const random = seededRandom(seed);
    // Keep blo's exact random-call and palette order: main, background, spot, then pixels.
    const main = blockieColor(random);
    const background = blockieColor(random);
    const spot = blockieColor(random);
    const colors = [background, main, spot];
    for (let row = 0; row < 8; row += 1) {
      const half = Array.from({ length: 4 }, () => Math.floor(random() * 2.3));
      for (const color of [...half, ...half.slice().reverse()]) {
        const pixel = document.createElement("span");
        pixel.style.backgroundColor = colors[color];
        container.appendChild(pixel);
      }
    }
  }

  function seededRandom(seed) {
    const state = new Uint32Array(4);
    for (let index = 0; index < seed.length; index += 1) {
      const slot = index % 4;
      state[slot] = (state[slot] << 5) - state[slot] + seed.charCodeAt(index);
    }
    return () => {
      const value = state[0] ^ (state[0] << 11);
      state[0] = state[1];
      state[1] = state[2];
      state[2] = state[3];
      state[3] = (state[3] ^ (state[3] >> 19) ^ value ^ (value >> 8)) >>> 0;
      return state[3] / 0x80000000;
    };
  }

  function blockieColor(random) {
    const hue = Math.floor(random() * 360);
    const saturation = Math.floor(random() * 60 + 40);
    const lightness = Math.floor((random() + random() + random() + random()) * 25);
    return `hsl(${hue} ${saturation}% ${lightness}%)`;
  }

  function calldataView(data) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "calldata-toggle";
    button.setAttribute("aria-expanded", "false");
    button.title = "Show full calldata";
    const value = document.createElement("span");
    value.className = "calldata-value";
    value.textContent = data;
    button.appendChild(value);
    button.addEventListener("click", () => {
      const expanded = button.classList.toggle("expanded");
      button.setAttribute("aria-expanded", String(expanded));
      button.title = expanded ? "Collapse calldata" : "Show full calldata";
    });
    return button;
  }

  function actionsFor({ requestId, data, primary, account }) {
    const actions = document.createElement("div");
    actions.className = "actions";
    if (account) {
      const selectable = data.kind === "connect" && !data.queued;
      const actionAccount = document.createElement(selectable ? "button" : "div");
      actionAccount.className = `account${selectable ? " account-select" : ""}`;
      if (isAddress(String(account))) {
        actionAccount.appendChild(addressView(account, data.accountLabel));
      } else {
        actionAccount.textContent = data.accountLabel || String(account);
      }
      if (selectable) {
        actionAccount.type = "button";
        actionAccount.title = "Choose account";
        actionAccount.setAttribute("aria-label", "Choose account");
        actionAccount.addEventListener("click", () =>
          openAccountPicker({ requestId, data, actions }),
        );
      }
      actions.appendChild(actionAccount);
    }
    const reject = document.createElement("button");
    reject.className = "reject";
    reject.textContent = "Reject";
    reject.addEventListener("click", () => decide(requestId, data.revision, false, actions));
    const approve = document.createElement("button");
    approve.className = "approve";
    approve.textContent = data.queued ? "Queued" : primary;
    approve.disabled = !!data.queued;
    approve.addEventListener("click", () => decide(requestId, data.revision, true, actions));
    actions.append(reject, approve);
    return actions;
  }

  async function openAccountPicker({ requestId, data, actions }) {
    setActionsDisabled(actions, true);
    const reply = await native("connectAccounts", { requestId, revision: data.revision });
    if (!reply || reply.ok === false || reply.error) {
      showError(reply);
      setActionsDisabled(actions, false);
      return;
    }
    const groups = reply.data?.groups;
    if (!Array.isArray(groups)) {
      showError({ error: "Accounts are unavailable" });
      setActionsDisabled(actions, false);
      return;
    }

    const picker = document.createElement("div");
    picker.className = "account-picker";
    const panel = document.createElement("div");
    panel.className = "account-picker-panel";
    const heading = document.createElement("div");
    heading.className = "account-picker-heading";
    const title = document.createElement("strong");
    title.textContent = "Choose account";
    const close = document.createElement("button");
    close.type = "button";
    close.className = "picker-close";
    close.textContent = "Close";
    close.addEventListener("click", () => {
      picker.remove();
      setActionsDisabled(actions, false);
    });
    heading.append(title, close);
    panel.appendChild(heading);

    for (const group of groups) {
      const section = document.createElement("section");
      section.className = "account-group";
      const label = document.createElement("h2");
      label.textContent = group.kind === "seed" ? "Seed wallet" : "Private key wallet";
      section.appendChild(label);
      for (const item of Array.isArray(group.accounts) ? group.accounts : []) {
        const option = document.createElement("button");
        option.type = "button";
        option.className = "account-option";
        if (String(item.address).toLowerCase() === String(data.account).toLowerCase()) {
          option.classList.add("selected");
          option.disabled = true;
        }
        const identity = document.createElement("span");
        appendDisplayValue(identity, item.address);
        const checkmark = document.createElement("span");
        checkmark.className = "account-checkmark";
        checkmark.textContent = option.classList.contains("selected") ? "✓" : "";
        option.append(identity, checkmark);
        option.addEventListener("click", async () => {
          for (const button of picker.querySelectorAll("button")) button.disabled = true;
          const rebound = await native("rebindConnect", {
            requestId,
            revision: data.revision,
            account: item.address,
          });
          if (!rebound || rebound.ok === false || rebound.error) {
            picker.remove();
            showError(rebound);
            await refresh();
            return;
          }
          picker.remove();
          await refresh();
        });
        section.appendChild(option);
      }
      panel.appendChild(section);
    }
    picker.appendChild(panel);
    tray.appendChild(picker);
  }

  function setActionsDisabled(actions, disabled) {
    for (const button of actions.querySelectorAll("button")) button.disabled = disabled;
  }

  function showError(reply) {
    const existing = tray.querySelector(".toast");
    if (existing) existing.remove();
    const toast = document.createElement("div");
    toast.className = "toast";
    toast.textContent = errorMessage(reply);
    tray.insertBefore(toast, tray.firstChild);
  }

  async function decide(requestId, revision, approve, actions) {
    const buttons = [...actions.querySelectorAll("button")];
    const buttonStates = buttons.map((button) => ({
      button,
      disabled: button.disabled,
      text: button.textContent,
    }));
    for (const button of buttons) button.disabled = true;
    const primary = actions.querySelector(".approve");
    if (approve && primary) primary.textContent = "Confirming...";
    const reply = await native(approve ? "approve" : "reject", { requestId, revision });
    if (!reply || reply.ok === false || reply.error) {
      showError(reply);
      for (const state of buttonStates) {
        state.button.disabled = state.disabled;
        state.button.textContent = state.text;
      }
      return;
    }
    // Direct popup-to-native decisions bypass the worker, which owns the toolbar badge's
    // in-memory count. Synchronize it before Safari destroys the popup document.
    await browser.runtime.sendMessage({ type: "popup.didDecide", requestId }).catch(() => null);
    window.close();
  }

  function errorMessage(reply) {
    if (typeof reply?.message === "string") return reply.message;
    if (typeof reply?.error?.message === "string") return reply.error.message;
    if (typeof reply?.error === "string") return reply.error;
    return "Request failed";
  }

  async function refresh() {
    // The review surface talks to native directly. Page status polling may keep the
    // background worker busy, but it must never delay listing or deciding a request.
    const reply = await native("list");
    const pending = Array.isArray(reply)
      ? reply
      : reply && reply.ok && reply.data
        ? reply.data.pending
        : [];
    render(Array.isArray(pending) ? pending : []);
  }

  refresh();
})();
