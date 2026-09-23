#!/usr/bin/env node
/**
 * 给网页版截图，用来核对渲染出来的东西"长什么样"。
 *
 *   node tools/shot.mjs                                   # 整屏 + 画面中央放大各一张
 *   node tools/shot.mjs https://127.0.0.1:8001 out.png
 *   node tools/shot.mjs --wait 9000 --clip 340,80,600,620
 *   node tools/shot.mjs https://127.0.0.1:8001 out.png --key w   # 按住 W 拍走路姿态
 *
 * 前置：另开一个终端跑 node tools/serve.mjs
 *
 * **默认输出到系统临时目录，不要写进项目里。** 导出预设是 all_resources，
 * 项目目录下的 PNG 会被 Godot 当资源导入（生成 .import）并打进 index.pck，
 * 实测多几张截图就让包从 55 KB 涨到 84 KB。
 *
 * 用无头 Chrome + SwiftShader 软件渲染，所以阴影质量与真机有差别，
 * 但形状、比例、颜色是可信的。
 */
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parseGuardReport, startCursorGuard } from "./cursor-guard.mjs";

const CHROME = process.env.CHROME
  ?? "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";
const PORT = Number(process.env.SHOT_PORT ?? 9345);

const argv = process.argv.slice(2);
function opt(name, fallback) {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
}
const positional = argv.filter((a, i) => !a.startsWith("--") && !argv[i - 1]?.startsWith("--"));
const BASE = (positional[0] ?? "https://127.0.0.1:8001").replace(/\/$/, "");
const OUT = positional[1] ?? path.join(os.tmpdir(), "stick-shot.png");
const WAIT_MS = Number(opt("wait", 7000));
// 画面中央那一块，默认把角色框进去（1280x720 视口的中间偏上）
const CLIP = opt("clip", "340,60,600,640").split(",").map(Number);
// "宽,高[,纵向偏移]"：按**当前**视口中心裁剪。
// 点击画面会触发全屏，视口尺寸随之改变（实测 1258x566 → 800x544），
// 写死坐标会捕空，所以按住键拍姿态时用这个。
const CENTER = opt("center", "");
const ZOOM = Number(opt("zoom", 2));
// 可选：截图前按住某些键，用来拍走路之类的姿态。可多个，用逗号分隔（如 a,s 或 w,shift）。
// 名字用字母或 shift / space。Godot 网页版按 event.code 匹配物理键位。
const HOLD_KEY = opt("key", "");
const HOLD_MS = Number(opt("hold", 1200));

const KEYS = {
  shift: { code: "ShiftLeft", vk: 16, key: "Shift" },
  space: { code: "Space", vk: 32, key: " " },
};

function keyInfo(name) {
  if (KEYS[name]) return KEYS[name];
  if (name.length !== 1 || !/[a-z]/.test(name)) {
    throw new Error(`未登记的按键: ${name}（可用字母、shift、space）`);
  }
  return { code: `Key${name.toUpperCase()}`, vk: 65 + name.charCodeAt(0) - 97, key: name };
}
// 可选：附加查询串，例如 cam=front（把相机转到角色正面核对面部）
const QUERY = opt("query", "");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let usedPointerLock = false;

/**
 * 按过键就会触发指针锁定，收尾时要处理：
 * 浏览器进入指针锁定会调用 Windows 的 ClipCursor 把光标圈在窗口内，
 * 进程被强杀时来不及还原，限制就留在系统里（症状：鼠标困在屏幕一小块区域）。
 * 所以先让页面自己 exitPointerLock、再优雅关闭，最后兜底跑一次 free-cursor.ps1。
 */
async function releasePointerLock() {
  if (!usedPointerLock) return;
  try {
    await cdp?.evaluate("document.exitPointerLock && document.exitPointerLock()");
  } catch { /* 页面可能已经关了 */ }
  await sleep(600);
}

function clearClipCursor() {
  if (!usedPointerLock) return;
  const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "free-cursor.ps1");
  if (!fs.existsSync(script)) return;
  try {
    const out = execFileSync(
      "powershell",
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script],
      { encoding: "utf8" }
    );
    // 只取 ASCII 数字：脚本用 Write-Host 输出，捕获时中文会乱码
    const rects = [...out.matchAll(/(\d+),(\d+)\s*-\s*(\d+),(\d+)/g)];
    if (rects.length) {
      const r = rects[rects.length - 1];
      console.log(`  鼠标裁剪范围：${r[1]},${r[2]} - ${r[3]},${r[4]}`);
    }
  } catch { /* 忽略 */ }
}

class Cdp {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.nextId = 1;
    this.pending = new Map();
    this.console = [];
    this.ws.addEventListener("message", (event) => {
      const msg = JSON.parse(event.data);
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(JSON.stringify(msg.error)));
        else resolve(msg.result);
      } else if (msg.method === "Runtime.consoleAPICalled") {
        this.console.push(msg.params.args.map((a) => a.value ?? a.description ?? a.type).join(" "));
      }
    });
  }
  async open() {
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
  async evaluate(expression) {
    const res = await this.send("Runtime.evaluate", { expression, returnByValue: true });
    return res.result?.value ?? null;
  }
  close() {
    try { this.ws.close(); } catch { /* 已断开 */ }
  }
}

async function waitForDevTools(timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`http://127.0.0.1:${PORT}/json/version`);
      if (res.ok) return true;
    } catch { /* 还没起来 */ }
    await sleep(200);
  }
  return false;
}

async function firstPageTarget() {
  for (let i = 0; i < 50; i++) {
    const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
    const page = list.find((t) => t.type === "page");
    if (page) return page;
    await sleep(200);
  }
  throw new Error("没有找到页面目标");
}

if (!fs.existsSync(CHROME)) {
  console.error(`找不到 Chrome: ${CHROME}`);
  process.exit(1);
}

const profile = fs.mkdtempSync(path.join(os.tmpdir(), "stick-shot-"));
// 先起光标守卫再启动浏览器：它要在浏览器上锁之前拿到“没被裁剪”的基准值。
// 即使用户手动掐掉这次截图（或它崩溃），鼠标最多被圈住一个采样间隔（0.1 秒）。
const guard = startCursorGuard({ minutes: 15, label: "shot", profileDir: profile });
const child = spawn(CHROME, [
  "--headless=new",
  "--enable-unsafe-swiftshader",
  "--ignore-certificate-errors",
  "--disable-background-timer-throttling",
  "--disable-renderer-backgrounding",
  "--no-first-run",
  "--no-default-browser-check",
  "--mute-audio",
  "--window-size=1280,720",
  `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${profile}`,
  "about:blank",
], { stdio: "ignore" });

let cdp = null;
try {
  if (!await waitForDevTools()) throw new Error("DevTools 没起来");
  const target = await firstPageTarget();
  cdp = new Cdp(target.webSocketDebuggerUrl);
  await cdp.open();
  await cdp.send("Runtime.enable");
  await cdp.send("Page.enable");

  const url = QUERY ? `${BASE}/index.html?${QUERY}` : `${BASE}/index.html`;
  console.log(`  截图目标: ${url}`);
  await cdp.send("Page.navigate", { url });

  // 等到游戏主循环真的跑起来（net.gd 每 0.25 秒写一次这个全局变量）
  const deadline = Date.now() + 30_000;
  let running = false;
  while (Date.now() < deadline) {
    running = await cdp.evaluate("!!window.__netstat");
    if (running) break;
    await sleep(300);
  }
  console.log(`  游戏主循环: ${running ? "已启动" : "未检测到"}`);
  // 首帧之后还要等模型与材质就位
  await sleep(WAIT_MS);

  let holdKey = null;
  if (HOLD_KEY) {
    await cdp.send("Page.bringToFront");
    await cdp.send("Input.dispatchMouseEvent", {
      type: "mousePressed", x: 640, y: 360, button: "left", clickCount: 1,
    });
    await cdp.send("Input.dispatchMouseEvent", {
      type: "mouseReleased", x: 640, y: 360, button: "left", clickCount: 1,
    });
    for (let i = 0; i < 25; i++) {
      if (await cdp.evaluate("!!document.pointerLockElement")) break;
      await sleep(200);
    }
    usedPointerLock = true;   // 收尾时要用到
    const keys = HOLD_KEY.split(",").map((k) => k.trim().toLowerCase()).filter(Boolean);
    for (const name of keys) {
      const info = keyInfo(name);
      await cdp.send("Input.dispatchKeyEvent", {
        type: "rawKeyDown", windowsVirtualKeyCode: info.vk, nativeVirtualKeyCode: info.vk,
        code: info.code, key: info.key,
      });
    }
    await sleep(HOLD_MS);
  }

  const shot = async (file, clip) => {
    const opts = { format: "png" };
    if (clip) {
      opts.clip = { x: clip[0], y: clip[1], width: clip[2], height: clip[3], scale: ZOOM };
    }
    const res = await cdp.send("Page.captureScreenshot", opts);
    fs.writeFileSync(file, Buffer.from(res.data, "base64"));
    console.log(`  已保存 ${file}`);
  };

  await shot(OUT);
  const dir = path.dirname(OUT);
  const base = path.basename(OUT, path.extname(OUT));
  const zoomFile = path.join(dir, `${base}-zoom${path.extname(OUT)}`);

  var zoomClip = CLIP;
  if (CENTER) {
    const parts = CENTER.split(",").map(Number);
    const cw = parts[0];
    const ch = parts[1];
    const dy = parts.length > 2 ? parts[2] : 0;
    const vw = await cdp.evaluate("innerWidth");
    const vh = await cdp.evaluate("innerHeight");
    zoomClip = [Math.round(vw / 2 - cw / 2), Math.round(vh / 2 - ch / 2 + dy), cw, ch];
    console.log(`  居中裁剪: ${zoomClip.join(",")}（当前视口 ${vw}x${vh}）`);
  }
  await shot(zoomFile, zoomClip);

  if (HOLD_KEY) {
    const keys = HOLD_KEY.split(",").map((k) => k.trim().toLowerCase()).filter(Boolean);
    for (const name of keys.reverse()) {
      const info = keyInfo(name);
      await cdp.send("Input.dispatchKeyEvent", {
        type: "keyUp", windowsVirtualKeyCode: info.vk, nativeVirtualKeyCode: info.vk,
        code: info.code, key: info.key,
      });
    }
  }

  const errors = cdp.console.filter((l) => /ERROR|error|SCRIPT/.test(l));
  if (errors.length) {
    console.log("  控制台错误:");
    for (const line of errors.slice(-8)) console.log(`    ${line}`);
  }

  // 顺便把游戏状态里的诊断数据打出来，方便核对画面与数据是否一致
  if (argv.includes("--stat")) {
    const view = await cdp.evaluate(
      "JSON.stringify({w: innerWidth, h: innerHeight, dpr: devicePixelRatio,"
      + " canvas: (() => { const c = document.getElementById('canvas');"
      + " if (!c) return null; const r = c.getBoundingClientRect();"
      + " return [r.x, r.y, r.width, r.height]; })()})"
    );
    console.log(`  viewport: ${view}`);
    const raw = await cdp.evaluate("JSON.stringify(window.__netstat || null)");
    if (raw) console.log(`  __netstat: ${raw}`);
    const probe = await cdp.evaluate("JSON.stringify(window.__netprobe || null)");
    if (probe) console.log(`  __netprobe: ${probe}`);
  }
} catch (err) {
  console.error(`  失败: ${err.message}`);
  process.exitCode = 1;
} finally {
  await releasePointerLock();
  // 先让页面自己关掉：**优雅关闭**才会走浏览器的窗口销毁流程，而 ClipCursor 的还原就在那里。
  // 以前这里无条件 taskkill /F（强杀），于是每一次截图都可能在系统里留下一块裁剪区。
  try { await cdp?.send("Page.close"); } catch { /* 页面可能已经没了 */ }
  const closeDeadline = Date.now() + 2500;
  while (Date.now() < closeDeadline) {
    if (child.exitCode !== null || child.killed) break;
    await sleep(200);
  }
  try { execFileSync("taskkill", ["/PID", String(child.pid), "/T", "/F"], { stdio: "ignore" }); } catch { /* 已退出 */ }
  clearClipCursor();
  await guard.stop();
  // 报告守卫统计。它的意义不是“好看”，而是“用户鼠标在这次截图里没被困住”这两条证据：
  // 过程中最长被圈住多久（采样间隔量级），以及离开时的裁剪范围是否与启动时一致。
  const guardStats = parseGuardReport(guard.report());
  if (guardStats) {
    console.log(`  光标守卫：清除 ${guardStats.cleared} 次裁剪，最长被圈住 ${guardStats.worstConfinedMs} 毫秒`);
    if (!guardStats.freed) {
      console.log(`  ✗ 收尾后光标仍被裁剪：${(guardStats.final ?? []).join(",")}`
        + " —— 手动跑 tools/free-cursor.ps1");
      process.exitCode = 1;
    }
  }
  cdp?.close();
  // 强杀之后文件可能还被占着，删不掉就退避重试几次
  for (let i = 0; i < 5; i++) {
    try {
      fs.rmSync(profile, { recursive: true, force: true });
      break;
    } catch {
      await sleep(400);
    }
  }
  if (fs.existsSync(profile)) console.log(`  （临时配置目录未删掉，可手动清理: ${profile}）`);
}
