import { build } from "esbuild";
import { readFile, writeFile, mkdir, copyFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
function replaceOnce({ source, from, to }) {
  if (source.split(from).length !== 2)
    throw new Error("Shared Chrome adapter source changed; review the transform before building.");
  return source.replace(from, to);
}
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const output = resolve(root, ".build/chrome-extension");
await mkdir(output, { recursive: true });
const source = resolve(root, "SafariExtension/Resources");
const manifest = JSON.parse(await readFile(resolve(source, "manifest.json"), "utf8"));
manifest.name = "stupid wallet";
manifest.version = "0.0.6";
manifest.permissions = [...new Set([...manifest.permissions, "webNavigation"])];
manifest.minimum_chrome_version = "111";
manifest.incognito = "not_allowed";
manifest.action.default_icon = Object.fromEntries(
  [16, 19, 32, 38].map((size) => [String(size), `toolbar-light-${size}.png`]),
);
for (const size of [16, 19, 32, 38]) {
  const file = `toolbar-light-${size}.png`;
  await copyFile(resolve(root, "ChromeExtension/icons", file), resolve(output, file));
}
manifest.key = (
  await readFile(resolve(root, "ChromeExtension/development-public-key.txt"), "utf8")
).trim();
manifest.background.service_worker = "chrome-worker.js";
await writeFile(resolve(output, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
for (const file of [
  "provider.js",
  "bridge.js",
  "background.js",
  "popup.js",
  "popup.html",
  "popup.css",
  "icon-48.png",
  "icon-128.png",
  "toolbar-icon-16.png",
  "toolbar-icon-19.png",
  "toolbar-icon-32.png",
  "toolbar-icon-38.png",
]) {
  if (file.endsWith(".js")) {
    let text = await readFile(resolve(source, file), "utf8");
    text =
      "(() => { const browser = globalThis.browser ?? globalThis.chrome;\n" + text + "\n})();\n";
    if (file === "bridge.js") {
      const start = text.indexOf(
        "  // --- In-page notice (status + instructions; NEVER approval authority) ---",
      );
      const end = text.indexOf("  function respond(id, ok, payload) {");
      if (start < 0 || end <= start) throw new Error("Shared bridge notice boundary changed.");
      text =
        text.slice(0, start) +
        "  function showNotice() {}\n  function hideNotice() {}\n\n" +
        text.slice(end);
    }
    if (file === "background.js") {
      text = replaceOnce({
        source: text,
        from: 'action: "approve",\n            payload: { requestId: message.requestId, revision: message.revision },',
        to: 'action: "approve",\n            payload: { requestId: message.requestId, revision: message.revision, bindingDigest: message.bindingDigest },',
      });
      text = replaceOnce({
        source: text,
        from: "browser.runtime.onMessage.addListener((message, sender, sendResponse) => {",
        to: 'browser.runtime.onMessage.addListener((message, sender, sendResponse) => { if (message?.type?.startsWith("pairing.")) return;',
      });
    }
    if (file === "popup.js") {
      text = "const reviewedBindings = new Map();\n" + text;
      text = replaceOnce({
        source: text,
        from: "const message = { type: `popup.${action}` };",
        to: 'const message = { type: `popup.${action}` }; if (action === "approve") message.bindingDigest = reviewedBindings.get(payload.requestId + ":" + payload.revision);',
      });
      text = replaceOnce({
        source: text,
        from: "function render(items) {",
        to: 'function render(items) { for (const item of items || []) reviewedBindings.set(item.id + ":" + item.revision, item.bindingDigest);',
      });
      text = replaceOnce({
        source: text,
        from: "async function refresh() {",
        to: "async function refresh() { if (!(await globalThis.walletChromeReady)) return;",
      });
      text = "globalThis.walletChromePopup = true;\n" + text;
    }
    await writeFile(resolve(output, file), text);
  } else if (file === "popup.html") {
    const html = await readFile(resolve(source, file), "utf8");
    await writeFile(
      resolve(output, file),
      html.replace(
        '<script src="popup.js"></script>',
        '<script src="pairing-popup.js"></script><script src="popup.js"></script>',
      ),
    );
  } else await copyFile(resolve(source, file), resolve(output, file));
}
for (const file of ["pairing.html", "pairing-page.js", "pairing-popup.js"]) {
  await copyFile(resolve(root, "ChromeExtension", file), resolve(output, file));
}
await build({
  entryPoints: [resolve(root, "ChromeExtension/native-transport.js")],
  outfile: resolve(output, "native-transport.js"),
  bundle: true,
  format: "iife",
  platform: "browser",
  target: "chrome111",
  minify: true,
});
await writeFile(
  resolve(output, "chrome-worker.js"),
  'importScripts("native-transport.js", "background.js");\n',
);
console.log(output);
