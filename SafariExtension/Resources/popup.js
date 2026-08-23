// Safari-owned review surface. Every displayed value comes from the native canonical
// summary; approval submits only the persisted request ID.
(() => {
  const tray = document.getElementById("tray");

  const PRESENTATION = {
    connect: {
      description: "This site wants to connect to your wallet.",
      primary: "Connect",
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
    chain: {
      description: "Review the network details before adding it.",
      primary: "Add",
    },
  };

  function call(message) {
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
      detail.textContent = "Open a dapp to connect, sign, or send.";
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
    }
    section.appendChild(heading);

    const intro = document.createElement("p");
    intro.className = "intro";
    intro.textContent = presentation.description;
    section.appendChild(intro);

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
    const summaryRows = detailRows.filter((row) => !transactionRows.includes(row));

    const summary = document.createElement("div");
    summary.className = "summary";
    appendSummaryRow(summary, "Site", hostFor(data.origin), true);
    for (const row of summaryRows) appendSummaryRow(summary, row.label, row.value);
    if (kind === "connect" && account) appendSummaryRow(summary, "Wallet", account);
    section.appendChild(summary);

    if (transactionRows.length > 0) appendSection(section, "Details", transactionRows);

    if (domainRows.length > 0) {
      appendSection(
        section,
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
    if (messageRows.length > 0) appendSection(section, "Message", messageRows.map(unlabelled));
    if (typedMessageRows.length > 0) {
      appendSection(
        section,
        "Message",
        typedMessageRows.map((row) => ({
          label: row.label.slice("Message / ".length),
          value: row.value,
        })),
      );
    }

    if (account && kind !== "connect") {
      const footerAccount = document.createElement("div");
      footerAccount.className = "account";
      footerAccount.textContent = account;
      section.appendChild(footerAccount);
    }

    section.appendChild(actionsFor({ requestId, data, primary: presentation.primary }));
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
    content.className = `row-value${emphasis ? " emphasis" : ""}${isCode(value) ? " code" : ""}`;
    content.textContent = value == null ? "Unavailable" : value;
    container.append(key, content);
  }

  function appendSection(container, titleText, rows) {
    const section = document.createElement("section");
    section.className = "section";
    const title = document.createElement("h2");
    title.textContent = titleText;
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
      const value = document.createElement("pre");
      value.className = "message-value";
      value.textContent = row.value == null ? "Unavailable" : row.value;
      item.appendChild(value);
      list.appendChild(item);
    }
    section.append(title, list);
    container.appendChild(section);
  }

  function isCode(value) {
    return (
      typeof value === "string" && (value.startsWith("0x") || value.startsWith("keccak256 0x"))
    );
  }

  function actionsFor({ requestId, data, primary }) {
    const actions = document.createElement("div");
    actions.className = "actions";
    const reject = document.createElement("button");
    reject.className = "reject";
    reject.textContent = "Reject";
    reject.addEventListener("click", () => decide(requestId, false, actions));
    const approve = document.createElement("button");
    approve.className = "approve";
    approve.textContent = data.queued ? "Queued" : primary;
    approve.disabled = !!data.queued;
    approve.addEventListener("click", () => decide(requestId, true, actions));
    actions.append(reject, approve);
    return actions;
  }

  async function decide(requestId, approve, actions) {
    const buttons = [...actions.querySelectorAll("button")];
    const buttonStates = buttons.map((button) => ({
      button,
      disabled: button.disabled,
      text: button.textContent,
    }));
    for (const button of buttons) button.disabled = true;
    const primary = actions.querySelector(".approve");
    if (approve && primary) primary.textContent = "Confirming...";
    const reply = await call({
      type: approve ? "popup.approve" : "popup.reject",
      requestId,
    });
    if (!reply || reply.ok === false || reply.error) {
      const existing = tray.querySelector(".toast");
      if (existing) existing.remove();
      const toast = document.createElement("div");
      toast.className = "toast";
      toast.textContent = errorMessage(reply);
      tray.insertBefore(toast, tray.firstChild);
      for (const state of buttonStates) {
        state.button.disabled = state.disabled;
        state.button.textContent = state.text;
      }
      return;
    }
    window.close();
  }

  function errorMessage(reply) {
    if (typeof reply?.message === "string") return reply.message;
    if (typeof reply?.error?.message === "string") return reply.error.message;
    if (typeof reply?.error === "string") return reply.error;
    return "Request failed";
  }

  async function refresh() {
    let reply = await call({ type: "popup.list" });
    if (reply === null) {
      await new Promise((resolve) => setTimeout(resolve, 500));
      reply = await call({ type: "popup.list" });
    }
    render(Array.isArray(reply) ? reply : []);
  }

  refresh();
})();
