// 一次性诊断脚本：用 CDP 打开页面，问它几个问题。
//   node tools/dev-peek.mjs https://127.0.0.1:8001 "document.readyState"
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const CHROME = process.env.CHROME ?? "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";
const BASE = process.argv[2] ?? "https://127.0.0.1:8001";
const PORT = 9351;
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "stick-peek-"));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const exprs = process.argv.slice(3);
if (!exprs.length) {
  exprs.push(
    "document.readyState",
    "typeof window.__fireBtn",
    "typeof window.__fireDown",
    "typeof window.__fireAnswer",
    "!!document.getElementById('canvas')",
    "document.querySelectorAll('script').length",
  );
}

const child = spawn(CHROME, [
  "--headless=new", "--enable-unsafe-swiftshader", "--ignore-certificate-errors",
  "--no-first-run", "--no-default-browser-check", "--mute-audio",
  "--window-size=1280,720", `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${profile}`, "about:blank",
], { stdio: "ignore" });

let ws = null;
const logs = [];
try {
  let target = null;
  for (let i = 0; i < 60 && !target; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
      target = list.find((t) => t.type === "page" && !t.url.startsWith("devtools://"));
    } catch { /* 还没起来 */ }
    if (!target) await sleep(200);
  }
  if (!target) throw new Error("DevTools 没起来");

  ws = new WebSocket(target.webSocketDebuggerUrl);
  let nextId = 1;
  const pending = new Map();
  ws.addEventListener("message", (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) {
      const { resolve, reject } = pending.get(m.id);
      pending.delete(m.id);
      if (m.error) reject(new Error(JSON.stringify(m.error)));
      else resolve(m.result);
      return;
    }
    if (m.method === "Runtime.consoleAPICalled") {
      logs.push("console: " + m.params.args.map((a) => a.value ?? a.description ?? a.type).join(" "));
    }
    if (m.method === "Runtime.exceptionThrown") {
      logs.push("EXCEPTION: " + (m.params.exceptionDetails?.exception?.description
        ?? m.params.exceptionDetails?.text));
    }
  });
  await new Promise((res, rej) => {
    ws.addEventListener("open", res, { once: true });
    ws.addEventListener("error", rej, { once: true });
  });
  const send = (method, params = {}) => {
    const id = nextId++;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params }));
    });
  };
  const evaluate = async (expr) => {
    const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true });
    return r.result?.value ?? r.result?.description ?? JSON.stringify(r);
  };

  await send("Runtime.enable");
  await send("Page.enable");
  await send("Page.navigate", { url: `${BASE}/index.html?room=peek` });
  await sleep(Number(process.env.PEEK_WAIT_MS ?? 9000));

  console.log(`  页面: ${BASE}/index.html?room=peek`);
  for (const e of exprs) console.log(`  ${e}  →  ${await evaluate(e)}`);
  if (logs.length) {
    console.log("  控制台/异常：");
    for (const l of logs.slice(-15)) console.log(`    ${l}`);
  }
} finally {
  try { ws?.close(); } catch { /* 忽略 */ }
  try { execFileSync("taskkill", ["/PID", String(child.pid), "/T", "/F"], { stdio: "ignore" }); } catch { /* 已退出 */ }
  for (let i = 0; i < 5; i++) {
    try { fs.rmSync(profile, { recursive: true, force: true }); break; } catch { await sleep(300); }
  }
}
