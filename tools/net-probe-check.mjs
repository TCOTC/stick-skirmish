#!/usr/bin/env node
/**
 * 用 CDP 驱动两个真实 Chrome 实例，验证联机链路。两个模式：
 *
 *   node tools/net-probe-check.mjs [https://127.0.0.1:8001]            # 传输层探针
 *   node tools/net-probe-check.mjs [https://127.0.0.1:8001] --room     # 双方能不能看见对方
 *
 * 探针模式跑 scripts/net_probe.gd（需 ?probe=1），检查 wss 连接、中继转发、
 * Godot 高层 API 与广播 rpc；房间模式跑 scripts/net.gd，检查两个客户端进入同一房间后
 * 互相看到对方的替身。
 *
 * 前置：另开一个终端跑 node tools/serve.mjs。
 *
 * 为什么开两个 Chrome 进程而不是一个浏览器的两个标签页：非前台标签页的
 * requestAnimationFrame 会被节流甚至停掉，而 Godot 网页版的主循环就跑在 rAF 上，
 * 后台那个页面根本不会 poll 网络，测试会一直等不到消息。
 */
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import https from "node:https";
import os from "node:os";
import path from "node:path";

const BASE = (process.argv[2] ?? "https://127.0.0.1:8001").replace(/\/$/, "");
const MODE = process.argv[3] === "--room" ? "room" : "probe";
const ROOM_NAME = process.env.TEST_ROOM ?? "roomtest";
const CHROME = process.env.CHROME
  ?? "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";
const DEBUG_PORT = 9333;
const HARD_TIMEOUT_MS = Number(process.env.NET_CHECK_TIMEOUT_MS ?? 90_000);
const MP_SETTLE_SECONDS = 14; // 探针里 MP 从第 4 秒才开始，留出握手和几轮广播的时间

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const COMMON_FLAGS = [
  "--headless=new",
  "--enable-unsafe-swiftshader", // 无头环境没有 GPU，Godot 要 WebGL2
  "--ignore-certificate-errors", // 局域网自签证书
  "--disable-background-timer-throttling",
  "--disable-renderer-backgrounding",
  "--disable-backgrounding-occluded-windows",
  "--no-first-run",
  "--no-default-browser-check",
  "--disable-extensions",
  "--mute-audio",
  "--window-size=1280,720",
];

/** 极简 CDP 客户端：Node 自带 WebSocket，不需要 ws 之类的依赖。 */
class Cdp {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.nextId = 1;
    this.pending = new Map();
    this.console = [];
    this.exceptions = [];
    this.ws.addEventListener("message", (event) => {
      const msg = JSON.parse(event.data);
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(JSON.stringify(msg.error)));
        else resolve(msg.result);
        return;
      }
      if (msg.method === "Runtime.consoleAPICalled") {
        this.console.push(msg.params.args.map((a) => a.value ?? a.description ?? a.type).join(" "));
      } else if (msg.method === "Runtime.exceptionThrown") {
        this.exceptions.push(msg.params.exceptionDetails?.exception?.description
          ?? msg.params.exceptionDetails?.text ?? "unknown");
      }
    });
  }

  async open() {
    if (this.ws.readyState === WebSocket.OPEN) return;
    await new Promise((resolve, reject) => {
      this.ws.addEventListener("open", resolve, { once: true });
      this.ws.addEventListener("error", () => reject(new Error("CDP 连接失败")), { once: true });
    });
  }

  send(method, params = {}) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }

  /** 取页面里 window[expr] 的值（JSON 字符串或 null）。 */
  async evaluate(expression) {
    const res = await this.send("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: false,
    });
    return res.result?.value ?? null;
  }

  close() {
    try {
      this.ws.close();
    } catch {
      // 已经断了就算了
    }
  }
}

function launch(port, profile) {
  const child = spawn(
    CHROME,
    [
      ...COMMON_FLAGS,
      `--remote-debugging-port=${port}`,
      `--user-data-dir=${profile}`,
      "about:blank",
    ],
    { stdio: "ignore", detached: false }
  );
  child.on("error", (err) => {
    console.error(`  ✗ 启动 Chrome 失败: ${err.message}`);
    process.exit(1);
  });
  return child;
}

async function waitForDevTools(port, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (res.ok) return true;
    } catch {
      // 还没起来
    }
    await sleep(200);
  }
  return false;
}

async function firstPageTarget(port) {
  for (let i = 0; i < 50; i++) {
    const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    const page = list.find((t) => t.type === "page" && !t.url.startsWith("devtools://"));
    if (page) return page;
    await sleep(200);
  }
  throw new Error(`端口 ${port} 上没有找到页面目标`);
}

function kill(child) {
  if (!child || child.killed) return;
  try {
    execFileSync("taskkill", ["/PID", String(child.pid), "/T", "/F"], { stdio: "ignore" });
  } catch {
    // 可能已经退了
  }
}

// ---------------------------------------------------------------------------

// 自签证书在浏览器里点过「继续前往」就没事，但 Node 的 fetch 会直接拒绘，
// 所以预检单独走 https 模块并关掉校验。
function probeHead(url) {
  return new Promise((resolve, reject) => {
    const mod = url.startsWith("https:") ? https : http;
    const req = mod.request(url, { method: "HEAD", rejectUnauthorized: false }, (res) => {
      res.resume();
      resolve(res.statusCode ?? 0);
    });
    req.on("error", reject);
    req.setTimeout(5000, () => req.destroy(new Error("超时")));
    req.end();
  });
}

if (!fs.existsSync(CHROME)) {
  console.error(`找不到 Chrome: ${CHROME}（可用环境变量 CHROME 指定）`);
  process.exit(1);
}

try {
  const status = await probeHead(`${BASE}/index.html`);
  if (status < 200 || status >= 400) throw new Error(`HTTP ${status}`);
} catch (err) {
  console.error(`连不上 ${BASE}（${err.message}）`);
  console.error("先在另一个终端跑：node tools/serve.mjs");
  process.exit(1);
}

const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "stick-netprobe-"));
const instances = [
  { key: "a", name: "alpha", port: DEBUG_PORT },
  { key: "b", name: "beta", port: DEBUG_PORT + 1 },
];

const pageQuery = MODE === "room"
  ? `?room=${encodeURIComponent(ROOM_NAME)}`
  : null;

console.log(`  检查地址: ${BASE}`);
console.log(`  检查模式: ${MODE === "room" ? `房间联机（room=${ROOM_NAME}）` : "传输层探针"}`);
console.log(`  临时配置目录: ${tmpRoot}`);
console.log("");

const running = [];
try {
  for (const inst of instances) {
    const profile = path.join(tmpRoot, inst.key);
    fs.mkdirSync(profile, { recursive: true });
    inst.child = launch(inst.port, profile);
    running.push(inst.child);

    if (!await waitForDevTools(inst.port)) throw new Error(`端口 ${inst.port} 的 DevTools 没起来`);
    const target = await firstPageTarget(inst.port);
    inst.cdp = new Cdp(target.webSocketDebuggerUrl);
    await inst.cdp.open();
    await inst.cdp.send("Runtime.enable");
    await inst.cdp.send("Page.enable");

    const url = MODE === "room"
      ? `${BASE}/index.html${pageQuery}`
      : `${BASE}/index.html?probe=1&name=${inst.name}`;
    console.log(`  ${inst.name} → ${url}`);
    await inst.cdp.send("Page.navigate", { url });
  }
  console.log("");

  if (MODE === "room") {
    await checkRoom();
  } else {
    await checkProbe();
  }

  for (const inst of instances) {
    const pat = MODE === "room" ? "[net]" : "[netprobe]";
    const lines = inst.cdp.console.filter((l) => l.startsWith(pat));
    if (lines.length) {
      console.log(`  ${inst.name} 日志（末 4 条）:`);
      for (const line of lines.slice(-4)) console.log(`    ${line}`);
      console.log("");
    }
  }
} finally {
  for (const child of running) kill(child);
  for (const inst of instances) inst.cdp?.close();
  await sleep(500);
  try {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  } catch {
    console.log(`  （临时目录没删掉，可手动清理: ${tmpRoot}）`);
  }
}

/** 房间模式：两边都得连上，并且各自看到对方的编号与替身。 */
async function checkRoom() {
  const state = {};
  const deadline = Date.now() + HARD_TIMEOUT_MS;
  let settled = false;

  while (Date.now() < deadline) {
    for (const inst of instances) {
      const raw = await inst.cdp.evaluate("JSON.stringify(window.__netstat || null)");
      if (raw) {
        try {
          state[inst.name] = JSON.parse(raw);
        } catch {
          // 正在写入的时刻读到半个 JSON，下一轮再看
        }
      }
    }
    const a = state.alpha;
    const b = state.beta;
    const seen = a?.connected && b?.connected
      && a.peers.includes(b.myId) && b.peers.includes(a.myId)
      && a.avatars >= 1 && b.avatars >= 1;
    if (seen) {
      settled = true;
      break;
    }
    process.stdout.write(
      `\r  等待中… alpha=${a?.status ?? "-"}/peers=${JSON.stringify(a?.peers ?? [])}`
      + ` beta=${b?.status ?? "-"}/peers=${JSON.stringify(b?.peers ?? [])}   `
    );
    await sleep(400);
  }
  console.log("");

  const a = state.alpha;
  const b = state.beta;
  if (!a || !b) {
    console.log("  没拿到联机状态。控制台输出：");
    for (const inst of instances) {
      console.log(`  --- ${inst.name} ---`);
      for (const line of inst.cdp.console.slice(-25)) console.log(`    ${line}`);
      for (const line of inst.cdp.exceptions.slice(-5)) console.log(`    EXCEPTION ${line}`);
    }
    process.exitCode = 1;
    return;
  }

  console.log("  原始状态:");
  console.log(JSON.stringify(state, null, 2));
  console.log("");

  const results = [
    ["两个客户端都进入已连接状态", a.connected && b.connected,
      `alpha ${a.status} / beta ${b.status}`],
    ["双方编号不同", a.myId !== b.myId, `alpha=${a.myId} beta=${b.myId}`],
    ["各自看到对方的编号", a.peers.includes(b.myId) && b.peers.includes(a.myId),
      `alpha 看到 ${JSON.stringify(a.peers)} / beta 看到 ${JSON.stringify(b.peers)}`],
    ["各自为对方建了替身", a.avatars >= 1 && b.avatars >= 1,
      `alpha 替身 ${a.avatars} / beta 替身 ${b.avatars}`],
  ];

  console.log("  结论:");
  for (const [label, ok, detail] of results) {
    console.log(`  ${ok ? "✓" : "✗"} ${label} — ${detail}`);
  }
  console.log("");
  if (results.some(([, ok]) => !ok)) {
    process.exitCode = 1;
    console.log("  控制台输出：");
    for (const inst of instances) {
      console.log(`  --- ${inst.name} ---`);
      for (const line of inst.cdp.console.slice(-25)) console.log(`    ${line}`);
      for (const line of inst.cdp.exceptions.slice(-5)) console.log(`    EXCEPTION ${line}`);
    }
  }
  if (!settled) console.log("  ⚠ 是等超时才结束的。");
}

/** 探针模式：传输层四项检查。 */
async function checkProbe() {
  const state = {};
  const deadline = Date.now() + HARD_TIMEOUT_MS;
  let settled = false;

  while (Date.now() < deadline) {
    for (const inst of instances) {
      const raw = await inst.cdp.evaluate("JSON.stringify(window.__netprobe || null)");
      if (raw) {
        try {
          state[inst.name] = JSON.parse(raw);
        } catch {
          // 正在写入的时刻读到半个 JSON，下一轮再看
        }
      }
    }
    const a = state.alpha;
    const b = state.beta;
    const wsOk = a?.ws.state === "open" && b?.ws.state === "open"
      && a.ws.seen.includes("beta") && b.ws.seen.includes("alpha");
    const mpSettled = (a?.t ?? 0) >= MP_SETTLE_SECONDS && (b?.t ?? 0) >= MP_SETTLE_SECONDS;
    if (wsOk && mpSettled) {
      settled = true;
      break;
    }
    process.stdout.write(`\r  等待中… alpha=${a?.ws.state ?? "-"}/${a?.mp.state ?? "-"} beta=${b?.ws.state ?? "-"}/${b?.mp.state ?? "-"}  `);
    await sleep(400);
  }
  console.log("");

  const a = state.alpha;
  const b = state.beta;
  if (!a || !b) {
    console.log("  没拿到探针结果。控制台输出：");
    for (const inst of instances) {
      console.log(`  --- ${inst.name} ---`);
      for (const line of inst.cdp.console.slice(-25)) console.log(`    ${line}`);
      for (const line of inst.cdp.exceptions.slice(-5)) console.log(`    EXCEPTION ${line}`);
    }
    process.exitCode = 1;
    return;
  }

  console.log("  原始结果:");
  console.log(JSON.stringify(state, null, 2));
  console.log("");

  const results = [];
  const wsOpen = a.ws.state === "open" && b.ws.state === "open";
  results.push(["网页版能通过 wss 连上中继", wsOpen, `${a.ws.state} / ${b.ws.state}`]);

  const relayed = a.ws.seen.includes("beta") && b.ws.seen.includes("alpha");
  results.push(["两个浏览器能通过中继互发消息", relayed,
    `alpha 看到 [${a.ws.seen}] / beta 看到 [${b.ws.seen}]`]);

  const relayHello = a.ws.relay.find((t) => t.startsWith("relay:hello")) ?? "(无)";
  results.push(["中继下发了连接编号", relayHello.startsWith("relay:hello"), relayHello]);

  const mpOk = a.mp.state === "connected" && b.mp.state === "connected"
    && a.mp.rpcSeen.includes("beta") && b.mp.rpcSeen.includes("alpha");
  results.push(["MultiplayerAPI + 广播 rpc 可用", mpOk,
    `alpha ${a.mp.state} uid=${a.mp.uid} 发出 ${a.mp.rpcSent} 收到 [${a.mp.rpcSeen}] / `
    + `beta ${b.mp.state} uid=${b.mp.uid} 发出 ${b.mp.rpcSent} 收到 [${b.mp.rpcSeen}]`]);

  console.log("  结论:");
  for (const [label, ok, detail] of results) {
    console.log(`  ${ok ? "✓" : "✗"} ${label} — ${detail}`);
  }
  console.log("");
  if (!settled) {
    console.log("  ⚠ 是等超时才结束的，结果可能不完整。");
    console.log("");
  }
  // MP 不可用属于预期内的发现，不算测试失败
}

