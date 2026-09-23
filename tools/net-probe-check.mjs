#!/usr/bin/env node
/**
 * 用 CDP 驱动真实 Chrome 实例，验证联机链路。四个模式：
 *
 *   node tools/net-probe-check.mjs [https://127.0.0.1:8001]            # 传输层探针
 *   node tools/net-probe-check.mjs [https://127.0.0.1:8001] --room     # 双方能不能看见对方
 *   node tools/net-probe-check.mjs [https://127.0.0.1:8001] --walk     # 走路时关节有没有在动
 *   node tools/net-probe-check.mjs [https://127.0.0.1:8001] --shoot    # 能否打中对方并扣血
 *   node tools/net-probe-check.mjs [https://127.0.0.1:8001] --score    # 记分、判胜负与下一回合
 *
 * 探针模式跑 scripts/net_probe.gd（需 ?probe=1），检查 wss 连接、中继转发、
 * Godot 高层 API 与广播 rpc；房间模式跑 scripts/net.gd，检查两个客户端进入同一房间后
 * 互相看到对方的替身与样式分配；走路模式注入真实的鼠标点击与键盘事件，
 * 读取火柴人的关节角度与自身位置，验证“走路时腿真的在摆、人真的在动”；
 * 射击模式把 alpha 转向 beta、开火，验证命中的判定与扣血真的发生在被打者身上；
 * 记分模式用 ?kills=1 把一局压缩到几秒，验证记分、胜负横幅与下一回合的重置。
 *
 * 环境变量：
 *   NET_SHOT_DIR      每个实例收尾时把画面截图写到这个目录（用来人眼核对）
 *   NET_CHECK_TIMEOUT_MS / TEST_ROOM / TEST_JOIN_DELAY_MS / WALK_ROOM / SHOOT_ROOM / SCORE_ROOM
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
import { fileURLToPath } from "node:url";
import { parseGuardReport, startCursorGuard } from "./cursor-guard.mjs";

const BASE = (process.argv[2] ?? "https://127.0.0.1:8001").replace(/\/$/, "");
const ARG = process.argv[3];
const MODE = ARG === "--room" ? "room"
  : ARG === "--walk" ? "walk"
  : ARG === "--shoot" ? "shoot"
  : ARG === "--score" ? "score"
  : "probe";
const ROOM_NAME = process.env.TEST_ROOM ?? "roomtest";
const WALK_ROOM = process.env.WALK_ROOM ?? "walktest";
const SHOOT_ROOM = process.env.SHOOT_ROOM ?? "shoottest";
const SCORE_ROOM = process.env.SCORE_ROOM ?? "scoretest";
const SHOT_DIR = process.env.NET_SHOT_DIR ?? "";
// 让第二个实例晚一点再加入，用来复现"一个人先开、另一个人后进"的真实场景。
//
// 记分模式**默认就延迟**：它的第一项断言是"单人时提示等待对手、对手到了才喊 ROUND 1"，
// 而两个实例同时启动时，对手往往在第一次采样之前就已经到场，等待态根本没被看到
// （实测就是这么假失败过一次）。让 beta 晚 6 秒进来，那段等待窗口才稳定可观察。
// 顺带这也覆盖了"后加入"这个真实场景。
const JOIN_DELAY_MS = Number(
  process.env.TEST_JOIN_DELAY_MS ?? (MODE === "score" ? 6000 : 0),
);

// 鼠标横移用一个固定的 x 累加，好让 movementX 已知（见 mouseDelta）。
let mouseX = 300;

// Godot 的高层 rpc 会用节点路径缓存来省带宽；缓存靠连接时的握手机制建立。
// 中继不参与握手，所以后加入者可能收不到先加入者早先发过的路径公告，
// 结果是包被丢掉并报 "ID 1 not found in cache of peer 1"。这类错误必须可见，
// 否则“某个方向的更新静默丢失”会被漏掉。
const RPC_ERROR = /not found in cache|Invalid packet received|Requested node was not found/;
const rpcErrorCount = (cdp) => cdp.console.filter((l) => RPC_ERROR.test(l)).length;
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

/**
 * 收尾的第一步：让页面自己关掉，浏览器随之退出。
 *
 * 为什么不直接 taskkill：/F 是强杀，会跳过浏览器的窗口销毁流程，
 * 而 Windows 的鼠标裁剪（ClipCursor）就是在那个流程里还原的。
 * 上次把鼠标困在屏幕角落，根因就是这个（详见 free-cursor.ps1 的注释）。
 * 优雅关闭失败时仍会强杀，否则会留下卡住的进程。
 */
async function stopInstances() {
  for (const inst of instances) {
    if (!inst.cdp) continue;
    try {
      await inst.cdp.send("Page.close");
    } catch {
      // 页面可能已经没了
    }
  }
  const deadline = Date.now() + 3000;
  while (Date.now() < deadline) {
    if (running.every((child) => child.exitCode !== null || child.killed)) break;
    await sleep(200);
  }
  for (const child of running) kill(child);
}

// 指针锁定被触发过之后，收尾还要额外做两件事：
//
//   1. 先让页面主动调用 exitPointerLock，这是能正确还原的那条路径；
//   2. 关闭之后兜底调一次 free-cursor.ps1，防止上一步没跑成。
let usedPointerLock = false;

async function releasePointerLock() {
  if (!usedPointerLock) return;
  for (const inst of instances) {
    if (!inst.cdp) continue;
    try {
      // exitPointerLock 是异步的，页面还要跑一帧才会真正交还指针。
      await inst.cdp.evaluate("document.exitPointerLock && document.exitPointerLock()");
    } catch {
      // 页面可能已经关了
    }
  }
  await sleep(600);
}

/** 兜底：调用项目自带的脚本把系统的裁剪范围清掉（幂等，没限制时也无害）。 */
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
    // 不要去找中文关键字：脚本用 Write-Host 输出，捕获时会被按控制台代码页解码，
    // 中文会变成乱码；但数字和逗号是 ASCII，不受影响。取最后一组数字（解除后的值）。
    const rects = [...out.matchAll(/(\d+),(\d+)\s*-\s*(\d+),(\d+)/g)];
    if (rects.length) {
      const r = rects[rects.length - 1];
      console.log(`  鼠标裁剪范围已恢复：${r[1]},${r[2]} - ${r[3]},${r[4]}`);
    } else {
      console.log("  已调用 tools/free-cursor.ps1 兜底清理鼠标裁剪");
    }
  } catch (err) {
    console.log(`  ⚠ 解除鼠标裁剪失败，可手动运行 tools/free-cursor.ps1（${err.message}）`);
  }
}

/** 鼠标在一次测试里最长可以被圈住多久（毫秒）。*/
const GUARD_MAX_CONFINED_MS = 500;

/**
 * 把光标守卫的统计打印出来，并把它变成断言。
 *
 * 【为什么要在乎】指针锁定会用 ClipCursor 把用户的光标圈在浏览器窗口里，而“还原”发生在
 * 窗口销毁的流程里——测试被强杀（例如把输出管道接到 Select-Object -First，读满 N 行时
 * 就会掐掉上游）就来不及还原，限制作为孤儿留在系统里，症状是鼠标只能在屏幕一角活动。
 * 守卫就是为此存在的，它必须做到两件事：
 *   1. 运行期间把裁剪清掉，所以鼠标在任何一个瞬间都不会被困超过一个采样间隔
 *   2. 自己退出前再清一次，并**报告离开时的裁剪范围**——与启动时的基准一致才叫干净
 * 第 2 条是“没留下垃圾”的直接证据，第 1 条是“过程中也不难受”的证据。
 */
function reportCursorGuard(stats) {
  if (!stats) {
    console.log("  ⚠ 光标守卫没有留下统计（它没起来？）——建议手动跑 tools/free-cursor.ps1");
    return;
  }
  const rectText = (r) => (r ? r.join(",") : "?");
  console.log(`  光标守卫：清除了 ${stats.cleared} 次鼠标裁剪，`
    + `最长被圈住 ${stats.worstConfinedMs} 毫秒（采样 ${stats.samples} 次）`);
  if (stats.orphanChrome > 0) {
    console.log(`  清掉了 ${stats.orphanChrome} 个遗留的测试 Chrome`);
  }
  if (!stats.freed) {
    console.log(`  ✗ 收尾后光标仍被裁剪：${rectText(stats.final)}`
      + `（启动时 ${rectText(stats.baseline)}）—— 手动跑 tools/free-cursor.ps1`);
    process.exitCode = 1;
  }
  if (stats.worstConfinedMs > GUARD_MAX_CONFINED_MS) {
    console.log(`  ✗ 鼠标曾被圈住 ${stats.worstConfinedMs} 毫秒，`
      + `超过上限 ${GUARD_MAX_CONFINED_MS}——守卫的采样间隔是不是被改大了？`);
    process.exitCode = 1;
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

// 按键辅助与角度工具必须在**顶层主流程之前**定义。
// 顶层 await 会暂停模块求值，声明写在下方的 const 会一直处于暂时性死区，
// 主流程里调用就会报 "Cannot access 'VK' before initialization"。

// Godot 网页版按 event.code 匹配物理键位，所以要一并给出 code、虚拟键码与 key 名。
const KEYS = {
  KeyW: { vk: 87, key: "w" },
  KeyA: { vk: 65, key: "a" },
  KeyS: { vk: 83, key: "s" },
  KeyD: { vk: 68, key: "d" },
  Space: { vk: 32, key: " " },
  ShiftLeft: { vk: 16, key: "Shift" },
};

async function keyDown(cdp, code) {
  const k = KEYS[code];
  if (!k) throw new Error(`未登记的按键: ${code}`);
  await cdp.send("Input.dispatchKeyEvent", {
    type: "rawKeyDown", windowsVirtualKeyCode: k.vk, nativeVirtualKeyCode: k.vk,
    code, key: k.key,
  });
}

async function keyUp(cdp, code) {
  const k = KEYS[code];
  if (!k) throw new Error(`未登记的按键: ${code}`);
  await cdp.send("Input.dispatchKeyEvent", {
    type: "keyUp", windowsVirtualKeyCode: k.vk, nativeVirtualKeyCode: k.vk,
    code, key: k.key,
  });
}

/** 点击画面：请求全屏并接管鼠标。键盘只在指针锁定后才生效。 */
async function clickToCapture(cdp) {
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mousePressed", x: 640, y: 360, button: "left", clickCount: 1,
  });
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mouseReleased", x: 640, y: 360, button: "left", clickCount: 1,
  });
  for (let i = 0; i < 25; i++) {
    if (await cdp.evaluate("!!document.pointerLockElement")) return true;
    await sleep(200);
  }
  return false;
}

/** 把角度差归一化到 -180..180。 */
function angleDiff(a, b) {
  return ((a - b) % 360 + 540) % 360 - 180;
}

/**
 * 相对横移鼠标。
 *
 * 注意：**合成的鼠标位移与 Godot 收到的移动量不成固定比例**——Windows 的指针加速
 * 会对它做非线性映射，实测同一种位移在两次运行里得到 0.05 与 0.23 度/像素两种结果。
 * 所以用它的检查只能断言“朝向确实变了”，不能拿它做定量转向。
 */
async function mouseDelta(cdp, px) {
  const steps = Math.max(1, Math.round(Math.abs(px) / 40));
  const each = px / steps;
  for (let i = 0; i < steps; i++) {
    mouseX += each;
    await cdp.send("Input.dispatchMouseEvent", {
      type: "mouseMoved", x: Math.round(mouseX), y: 360, buttons: 0,
    });
    await sleep(40);
  }
  await sleep(300);
}

/** 替身的装饰件（命中框、血条）都还在。它们曾被外观重建一起删掉。 */
function decorOk(state) {
  const entries = Object.entries(state.avatarDecor ?? {});
  return entries.length > 0 && entries.every(([, d]) => d.hitBox && d.barOk);
}

/**
 * 按住左键打一段，返回这段里的俯仰变化与对方的最低血量。
 *
 * 后坐力是“真抬准星、而且不回落”，所以开火期间 `pitchDeg` 会一路上升。
 * 拿它做断言比看截图可靠：飘了多少度是确定的数值。
 *
 * `opts.watch` 是另一个实例的 CDP：开火期间**同时**盯它的血量。
 * 不能等打完了再读——对方被打死会在 3 秒后重生回满血，那时候读到的永远是 100。
 */
async function fireBurst(cdp, samples, opts = {}) {
  const before = await readStat(cdp);
  const pitchBefore = before?.pitchDeg ?? 0;
  let peak = pitchBefore;
  let minHealth = 999;
  // 散布跟着连发增长、同时音效播放器会被起起来，这两项只能在开火**期间**取样。
  let maxSpread = before?.spreadDeg ?? 0;
  let maxSounds = 0;
  // 准星间距（散布的可视化）也只能在开火期间取。
  let maxGap = before?.hud?.crosshairGap ?? 0;
  // 击杀提示只挂 3.5 秒，而一轮射击之后测试还要跑十几秒，所以也得在开火期间取。
  let feedSeen = "";

  await cdp.send("Input.dispatchMouseEvent", {
    type: "mousePressed", x: 640, y: 360, button: "left", clickCount: 1,
  });
  for (let i = 0; i < samples; i++) {
    const s = await readStat(cdp);
    if (s) {
      if (opts.fxSink) opts.fxSink.push(s.fx);
      peak = Math.max(peak, s.pitchDeg ?? 0);
      maxSpread = Math.max(maxSpread, s.spreadDeg ?? 0);
      maxSounds = Math.max(maxSounds, s.sounds ?? 0);
      maxGap = Math.max(maxGap, s.hud?.crosshairGap ?? 0);
      if (!feedSeen && s.hud?.feed) feedSeen = s.hud.feed;
    }
    if (opts.watch) {
      const w = await readStat(opts.watch);
      if (w) minHealth = Math.min(minHealth, w.health);
    }
    await sleep(60);
  }
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mouseReleased", x: 640, y: 360, button: "left", clickCount: 1,
  });
  // 松手后要等一拍再读：Godot 还没处理完这次松开时，冷却到点就会又打出一发，
  // 于是“松手瞬间的俯仰”会偏小，被误判成“回落了”。
  await sleep(500);

  const afterRelease = await readStat(cdp);
  return {
    pitchBefore,
    pitchClimb: peak - pitchBefore,
    pitchAfterRelease: afterRelease?.pitchDeg ?? 0,
    minHealth,
    maxSpread,
    maxSounds,
    maxGap,
    feedSeen,
    shotsBefore: before?.shots ?? 0,
    shotsAfter: afterRelease?.shots ?? 0,
  };
}

/**
 * 一下一下地点射，逐发取“这一发让准星偏了多少”。
 *
 * 水平后坐力是随机的，无法用“总共偏了多少”来断言它是否随机，
 * 所以要一发一取样。间隔要大于射速冷却（0.11 秒），否则一次点击会打出多发、样本就混了。
 */
async function fireTaps(cdp, count) {
  const samples = [];
  for (let i = 0; i < count; i++) {
    const before = await readStat(cdp);
    await cdpFire(cdp, true);
    await sleep(45);
    await cdpFire(cdp, false);
    await sleep(220);
    const after = await readStat(cdp);
    if (!before || !after) continue;
    samples.push({
      shots: after.shots - before.shots,
      yaw: angleDiff(after.figure.bodyYawDeg, before.figure.bodyYawDeg),
      pitch: after.pitchDeg - before.pitchDeg,
    });
  }
  return samples;
}

/** 按下或松开鼠标左键。
 *
 * 命中判定走的就是真实输入，所以截图之类的地方也必须用同一套事件，
 * 不能去调游戏内部接口伪造。
 */
async function cdpFire(cdp, down) {
  await cdp.send("Input.dispatchMouseEvent", {
    type: down ? "mousePressed" : "mouseReleased",
    x: 640, y: 360, button: "left", clickCount: 1,
  });
}

/** 轮询直到条件满足或超时。 */
async function waitFor(fn, timeoutMs, stepMs = 250) {
  const deadline = Date.now() + timeoutMs;
  let last = null;
  while (Date.now() < deadline) {
    last = await fn();
    if (last) return last;
    await sleep(stepMs);
  }
  return last;
}

// 走路模式只需要一个实例，而且不能有别的客户端：位置变化要来自真实的键盘输入。
const instances = MODE === "walk"
  ? [{ key: "a", name: "alpha", port: DEBUG_PORT }]
  : [
    { key: "a", name: "alpha", port: DEBUG_PORT },
    { key: "b", name: "beta", port: DEBUG_PORT + 1 },
  ];

// 网址参数：房间名决定跟谁同房，kills 决定分数上限。
// 射击模式故意把上限放到 99：回合重置会把两边送回出生点并恢复朝向，
// 而那个朝向变化会被“每发左右偏移”的断言当成后坐力数据，把测试弄脏。
// 记分模式反过来，用 1 杀结束一局，几秒就能跑完一个完整回合。
const PAGE_QUERY = {
  room: `?room=${encodeURIComponent(ROOM_NAME)}`,
  walk: `?room=${encodeURIComponent(WALK_ROOM)}`,
  shoot: `?room=${encodeURIComponent(SHOOT_ROOM)}&kills=99`,
  score: `?room=${encodeURIComponent(SCORE_ROOM)}&kills=1`,
};
const pageQuery = PAGE_QUERY[MODE] ?? null;

const MODE_LABEL = {
  room: `房间联机（room=${ROOM_NAME}）`,
  walk: `走路动画（room=${WALK_ROOM}）`,
  shoot: `射击命中（room=${SHOOT_ROOM}）`,
  score: `记分与回合（room=${SCORE_ROOM}，${1} 杀定胜负）`,
  probe: "传输层探针",
}[MODE];

console.log(`  检查地址: ${BASE}`);
console.log(`  检查模式: ${MODE_LABEL}`);
console.log(`  临时配置目录: ${tmpRoot}`);
console.log("");

// 先起光标守卫再启动浏览器：它要在浏览器上锁之前拿到"没被裁剪"的基准值。
// 这样即使用户手动掐掉这个测试（或它崩溃），鼠标最多被圈住一个采样间隔（0.1 秒）。
// 时间上限留宽：最坏情况是卡死很久才被发现，而守卫多跑一会的代价只是一个 100 毫秒的睡眠循环。
// 临时目录也一并交给它：被强杀时测试自己的清理代码没机会跑。
const guard = startCursorGuard({ minutes: 30, label: "netprobe", profileDir: tmpRoot });

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

    const url = MODE === "probe"
      ? `${BASE}/index.html?probe=1&name=${inst.name}`
      : `${BASE}/index.html${pageQuery}`;
    if (JOIN_DELAY_MS > 0 && inst.key === "b") {
      console.log(`  ${inst.name} 延迟 ${JOIN_DELAY_MS} ms 再加入…`);
      await sleep(JOIN_DELAY_MS);
    }
    console.log(`  ${inst.name} → ${url}`);
    await inst.cdp.send("Page.navigate", { url });

    // 记分模式要断言“一个人先进房间时显示等待对手”，而那个窗口是否存在取决于
    // alpha 的 WASM 启动速度与延迟谁先到——实测 alpha 的首页加载偶尔要十几秒，
    // 于是 beta 反而先连上了，出现偶发假失败（就是这一项）。改成**确定性的顺序**：
    // 等 alpha 真的连上（那时它必然是房间里的唯一一个人）再启动 beta。
    if (MODE === "score" && inst.key === "a") {
      const alone = await waitFor(async () => {
        const s = await readStat(inst.cdp);
        return s?.connected === true ? s : null;
      }, 45_000, 250);
      if (!alone) console.log("  ⚠ alpha 迟迟没连上，等待对手的窗口可能观察不到");
    }
  }
  console.log("");

  if (MODE === "room") {
    await checkRoom();
  } else if (MODE === "walk") {
    await checkWalk();
  } else if (MODE === "shoot") {
    await checkShoot();
  } else if (MODE === "score") {
    await checkScore();
  } else {
    await checkProbe();
  }

  // 可选：把每个实例的画面存下来，供人眼核对（特效、血条、枪的形状这类只能看）
  if (SHOT_DIR) {
    fs.mkdirSync(SHOT_DIR, { recursive: true });
    for (const inst of instances) {
      const res = await inst.cdp.send("Page.captureScreenshot", { format: "png" });
      const file = path.join(SHOT_DIR, `${MODE}-${inst.name}.png`);
      fs.writeFileSync(file, Buffer.from(res.data, "base64"));
      console.log(`  截图已保存 ${file}`);
    }
  }

  for (const inst of instances) {
    const pat = MODE === "probe" ? "[netprobe]" : "[net]";
    const lines = inst.cdp.console.filter((l) => l.startsWith(pat));
    if (lines.length) {
      console.log(`  ${inst.name} 日志（末 4 条）:`);
      for (const line of lines.slice(-4)) console.log(`    ${line}`);
      console.log("");
    }
  }} finally {
  await releasePointerLock();   // 先交还指针锁
  await stopInstances();        // 优雅关闭，失败才强杀
  clearClipCursor();            // 兜底清一次系统裁剪
  await guard.stop();           // 最后停守卫：它清了整场的裁剪，现在把统计交出来
  reportCursorGuard(parseGuardReport(guard.report()));
  for (const inst of instances) inst.cdp?.close();
  try {
    fs.rmSync(tmpRoot, { recursive: true, force: true });
  } catch {
    console.log(`  （临时目录没删掉，可手动清理: ${tmpRoot}）`);
  }
}

/** 读一次页面里的联机状态快照。 */
async function readStat(cdp) {
  const raw = await cdp.evaluate("JSON.stringify(window.__netstat || null)");
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    // 正在写入的时刻读到半个 JSON，下一次再读
    return null;
  }
}

/**
 * 走路模式：注入真实的鼠标点击与键盘事件，读取火柴人的关节角度与自身位置。
 *
 * 这是本文件里唯一能证明"骨骼动画真的在跑"的检查：前面的自检只验证了角度计算公式，
 * 这里走的是完整链路（浏览器输入 → Godot 输入映射 → 物理移动 → 关节角度 → 画面）。
 */
async function checkWalk() {
  const cdp = instances[0].cdp;

  // 无头 Chrome 默认不给页面前台焦点，此时指针锁会失败（WrongDocumentError），
  // 而键盘又只在指针锁定时生效，所以焦点是这一步的前提。
  await cdp.send("Page.bringToFront");
  await sleep(700);
  const hasFocus = await cdp.evaluate("document.hasFocus()");
  console.log(`  页面焦点: ${hasFocus}`);
  if (!hasFocus) {
    console.log("  页面拿不到前台焦点，指针锁必然失败，无法测键盘输入。");
    process.exitCode = 1;
    return;
  }

  let state = null;
  const readyDeadline = Date.now() + 30_000;
  while (Date.now() < readyDeadline) {
    state = await readStat(cdp);
    if (state?.connected) break;
    await sleep(300);
  }
  if (!state?.connected) {
    console.log("  联机没就绪，无法测走路。");
    process.exitCode = 1;
    return;
  }
  console.log(`  已连接 编号=${state.myId} 样式=${state.myStyle}`);

  // 出生点在 y=1 的空中，落地前用的是空中姿势，先等它落地。
  await sleep(1500);

  // 点击画面 = 请求全屏 + 接管鼠标（由注入脚本串起来）。键盘只在锁定后生效。
  const locked = await clickToCapture(cdp);
  if (locked) usedPointerLock = true;   // 收尾时要用到：先释放再强杀
  console.log(`  指针锁定: ${locked}`);

  // 静置采样：用来确认"没走路时腿是直的"，否则摆幅数据没有对照。
  const idleLegs = [];
  for (let i = 0; i < 6; i++) {
    const s = await readStat(cdp);
    if (s?.figure) idleLegs.push(Math.abs(s.figure.legAngle));
    await sleep(70);
  }
  const idleMax = idleLegs.length ? Math.max(...idleLegs) : 0;

  // W 键对应 Godot 的 move_forward。
  await keyDown(cdp, "KeyW");

  const startPos = (await readStat(cdp))?.pos ?? null;
  const walkLegs = [];
  const walkArms = [];
  for (let i = 0; i < 44; i++) {
    const s = await readStat(cdp);
    if (s?.figure) {
      walkLegs.push(s.figure.legAngle);
      walkArms.push(s.figure.armAngle);
    }
    await sleep(50);
  }
  const endPos = (await readStat(cdp))?.pos ?? null;
  await keyUp(cdp, "KeyW");

  const legRange = walkLegs.length ? Math.max(...walkLegs) - Math.min(...walkLegs) : 0;
  const armRange = walkArms.length ? Math.max(...walkArms) - Math.min(...walkArms) : 0;
  const moved = startPos && endPos
    ? Math.hypot(endPos[0] - startPos[0], endPos[2] - startPos[2])
    : 0;

  // 逐键验证身体偏转表。这条规则**反直觉**（后退时横向镜像，所以 A 左倾而 AS 右倾），
  // 又不能用“朝移动方向限幅”那类公式概括，所以必须逐键锁住。
  //
  // 同时断言：方向键**不带动镜头**、也**不带动移动基准**（Player 节点）。
  // 曾经让外观完全朝移动方向转、镜头也跟着转，结果一按方向键画面就转，操作失去参考。
  const bodyBefore = (await readStat(cdp))?.figure?.bodyYawDeg ?? 0;
  const leanCases = [
    { keys: ["KeyA"], label: "按 A（左）", expect: 1 },
    { keys: ["KeyD"], label: "按 D（右）", expect: -1 },
    { keys: ["KeyA", "KeyS"], label: "按 AS（左后）", expect: -1 },
    { keys: ["KeyD", "KeyS"], label: "按 DS（右后）", expect: 1 },
    { keys: ["KeyW"], label: "按 W（前）", expect: 0 },
    { keys: ["KeyS"], label: "按 S（后）", expect: 0 },
  ];
  const leans = [];
  for (const c of leanCases) {
    for (const k of c.keys) await keyDown(cdp, k);
    const p0 = (await readStat(cdp))?.pos ?? null;
    await sleep(1100);                 // 等偏转与镜头都稳定
    const s = await readStat(cdp);
    for (const k of c.keys) await keyUp(cdp, k);
    const p1 = (await readStat(cdp))?.pos ?? null;
    await sleep(700);                  // 松手后让偏转回落到直立
    const after = await readStat(cdp);
    const moved = p0 && p1
      ? Math.hypot(p1[0] - p0[0], p1[2] - p0[2])
      : 0;
    leans.push({
      ...c,
      lean: s?.figure?.leanDeg ?? 0,
      cam: s?.figure?.camYawDeg ?? 0,
      body: s?.figure?.bodyYawDeg ?? 0,
      released: after?.figure?.leanDeg ?? 0,
      moved,
    });
  }

  const byLabel = Object.fromEntries(leans.map((l) => [l.label, l]));
  const signOk = (v, e) => (e === 0
    ? Math.abs(v) < 2.0
    : Math.sign(v) === e && Math.abs(v) > 10.0 && Math.abs(v) < 89.0);
  const maxAbsLean = Math.max(...leans.map((l) => Math.abs(l.lean)));
  const maxCamDrift = Math.max(...leans.map((l) => Math.abs(l.cam)));
  const maxBodyDrift = Math.max(...leans.map((l) => Math.abs(angleDiff(l.body, bodyBefore))));
  const maxReleased = Math.max(...leans.map((l) => Math.abs(l.released)));
  const mirrored = Math.sign(byLabel["按 A（左）"].lean)
    === -Math.sign(byLabel["按 AS（左后）"].lean)
    && Math.sign(byLabel["按 D（右）"].lean) === -Math.sign(byLabel["按 DS（右后）"].lean);

  const results = [
    ["点击画面后指针被锁定", locked, "键盘只在锁定后生效"],
    ["静置时腿是直的", idleMax < 0.1, `最大 |角度| = ${idleMax.toFixed(3)} 弧度`],
    ["走动时腿在前后摆", legRange > 0.6, `摆幅 ${legRange.toFixed(2)} 弧度`],
    ["走动时手臂在反相摆", armRange > 0.3, `摆幅 ${armRange.toFixed(2)} 弧度`],
    ["按住 W 时角色确实移动了", moved > 1.0, `水平位移 ${moved.toFixed(2)} 米`],
    ...leans.map((l) => [
      `${l.label} 的身体偏转`,
      signOk(l.lean, l.expect),
      `${l.lean.toFixed(1)}°（期望${l.expect === 0 ? "直立" : l.expect > 0 ? "左倾" : "右倾"}）`,
    ]),
    ["偏转不超过 90°", maxAbsLean < 89.0, `最大 ${maxAbsLean.toFixed(1)}°`],
    ["后退时横向镜像（A 与 AS 相反）", mirrored,
      `A ${byLabel["按 A（左）"].lean.toFixed(1)}° / AS ${byLabel["按 AS（左后）"].lean.toFixed(1)}°`],
    ["松手后回到直立", maxReleased < 3.0, `最大残留 ${maxReleased.toFixed(1)}°`],
    ["方向键不带动镜头", maxCamDrift < 1.0, `最大漂移 ${maxCamDrift.toFixed(2)}°`],
    ["方向键不带动移动基准", maxBodyDrift < 1.0, `最大漂移 ${maxBodyDrift.toFixed(2)}°`],
    ["按 D 仍能侧移", byLabel["按 D（右）"].moved > 1.0,
      `水平位移 ${byLabel["按 D（右）"].moved.toFixed(2)} 米`],
    ["接收过程没有 RPC 路径解析错误", rpcErrorCount(cdp) === 0,
      `${rpcErrorCount(cdp)} 条`],
  ];

  console.log("");
  console.log("  结论:");
  for (const [label, ok, detail] of results) {
    console.log(`  ${ok ? "✓" : "✗"} ${label} — ${detail}`);
  }
  console.log("");
  if (results.some(([, ok]) => !ok)) {
    process.exitCode = 1;
    console.log("  控制台输出：");
    for (const line of cdp.console.slice(-25)) console.log(`    ${line}`);
    for (const line of cdp.exceptions.slice(-5)) console.log(`    EXCEPTION ${line}`);
  }
}

/**
 * 射击模式：让 alpha 真的把 beta 打中，验证扣血发生在被打者身上。
 *
 * 这条链路的每一段都必须真的跑起来才算过：鼠标转镜头 → 准星对准 → 开火 →
 * 广播 → beta 用**自己的位置**判定命中 → 扣血并广播 → alpha 看到血条变化。
 * 所以这里不注入任何“作弊”接口，全部走真实输入。
 */
async function checkShoot() {
  const a = instances.find((i) => i.name === "alpha");
  const b = instances.find((i) => i.name === "beta");

  await a.cdp.send("Page.bringToFront");
  await sleep(700);

  // 等两边都就绪并有对方的替身
  const ready = await waitFor(async () => {
    const sa = await readStat(a.cdp);
    const sb = await readStat(b.cdp);
    if (sa?.connected && sb?.connected && sa.peers.length > 0 && sb.peers.length > 0) {
      return { sa, sb };
    }
    return null;
  }, 30_000);
  if (!ready) {
    console.log("  联机没就绪，无法测射击。");
    process.exitCode = 1;
    return;
  }

  // alpha 要转镜头就得接管鼠标（键盘与鼠标事件只在指针锁定后生效）
  const idleHint = ready.sa.hud?.hint ?? "";
  const locked = await clickToCapture(a.cdp);
  if (locked) usedPointerLock = true;
  console.log(`  指针锁定: ${locked}`);
  await sleep(1200);   // 让“接管鼠标后短暂不开火”那段时间过去
  const capturedHint = (await readStat(a.cdp))?.hud?.hint ?? "";

  // 点击画面那一下**不该**顺手打出一发：那次点击是用来锁定指针的。
  // 这是最容易被玩家骂的细节之一，所以单独断言。
  const shotsAfterCapture = (await readStat(a.cdp))?.shots ?? -1;

  // 出生时两人就面对面（见 net.gd 的 _on_connected），所以不需要转镜头，
  // 只要确认朝向确实指着对方，然后开火。
  const fresh = await readStat(a.cdp);
  const me = fresh.pos;
  const peerId = String(fresh.peers[0]);
  const them = fresh.peerPos[peerId];
  const facingDeg = fresh.figure.bodyYawDeg;
  const targetYaw = (Math.atan2(-(them[0] - me[0]), -(them[2] - me[2])) * 180) / Math.PI;
  const aimErr = Math.abs(angleDiff(targetYaw, facingDeg));
  console.log(`  alpha ${JSON.stringify(me)} → beta ${JSON.stringify(them)}`
    + `，当前朝向 ${facingDeg.toFixed(1)}°，目标 ${targetYaw.toFixed(1)}°`);

  // 先拍两张开火中的截图（曳光只活 70 毫秒，得在持续开火时抓）。
  // 一张整屏、一张对准星周围放大：枪、血条、命中提示这类细节整屏看不清。
  //
  // 【时机】必须放在**第一轮开火之前**：后坐力是累积且不回落的，打几轮之后视角会被
  // 永久抬高到看不见对手（实测截图里只剩曳光与准星），拍出来没有参考价值。
  // 此时俯仰还是默认的 -12.6°，对手正在准星附近；而且对方满血，血条填充满宽、最清楚。
  if (SHOT_DIR) {
    await cdpFire(a.cdp, true);
    await sleep(180);
    fs.mkdirSync(SHOT_DIR, { recursive: true });

    const full = await a.cdp.send("Page.captureScreenshot", { format: "png" });
    const fullFile = path.join(SHOT_DIR, "shoot-firing.png");
    fs.writeFileSync(fullFile, Buffer.from(full.data, "base64"));
    console.log(`  开火中截图 ${fullFile}`);

    const vw = await a.cdp.evaluate("innerWidth");
    const vh = await a.cdp.evaluate("innerHeight");
    const cw = 150;
    const ch = 120;
    const zoom = await a.cdp.send("Page.captureScreenshot", {
      format: "png",
      clip: {
        // 略高于屏幕中心：要盖上对方头顶的血条
        x: Math.round(vw / 2 - cw / 2), y: Math.round(vh / 2 - ch * 0.75),
        width: cw, height: ch, scale: 5,
      },
    });
    const zoomFile = path.join(SHOT_DIR, "shoot-firing-zoom.png");
    fs.writeFileSync(zoomFile, Buffer.from(zoom.data, "base64"));
    console.log(`  准星放大截图 ${zoomFile}`);

    await cdpFire(a.cdp, false);
    await sleep(300);
  }

  // 开火：按住一段时间（射速约 9 发/秒）。
  // 记时长是为了**反推射速**：主循环受帧率影响，但冷却按时间算，所以射速应当恒定。
  const shotsBefore = (await readStat(a.cdp))?.shots ?? 0;
  const fireStart = Date.now();
  const fxSeen = [];
  const standBurst = await fireBurst(a.cdp, 12, { fxSink: fxSeen, watch: b.cdp });
  const fireMs = Date.now() - fireStart;

  const afterFire = await readStat(a.cdp);
  const shotsDelta = (afterFire?.shots ?? 0) - shotsBefore;
  const fxMax = fxSeen.length ? Math.max(...fxSeen) : 0;
  const ratePerSec = shotsDelta / Math.max(0.001, fireMs / 1000);

  // 再拍一张“打完之后”的画面：此时右侧还挂着击杀提示（只挂 3.5 秒）。
  if (SHOT_DIR) {
    fs.mkdirSync(SHOT_DIR, { recursive: true });
    const img = await a.cdp.send("Page.captureScreenshot", { format: "png" });
    const file = path.join(SHOT_DIR, "shoot-after-burst.png");
    fs.writeFileSync(file, Buffer.from(img.data, "base64"));
    console.log(`  开火后截图 ${file}（击杀提示还挂着）`);
  }

  // 后坐力**不回落**：准星应当停在抬起后的位置，而不是自己滑回开火前的水准
  // （这段时间里鼠标没动过）。比较基准取**松手那一瞬间**的俯仰，
  // 而不是采样期间的峰值——松手后到采样结束之间还会再打出几发。
  await sleep(1500);
  const afterHold = await readStat(a.cdp);
  const pitchHeld = afterHold?.pitchDeg ?? 0;
  const holdDrift = Math.abs(pitchHeld - standBurst.pitchAfterRelease);
  const climbedTotal = pitchHeld - standBurst.pitchBefore;

  // 再打一轮：既然不回落，第二轮的终点应当比第一轮更高（持续上飘）。
  const secondBurst = await fireBurst(a.cdp, 8);

  // 下蹲：按住 Shift 应当下蹲（相机下降）、并且后坐力明显变小。
  const crouchBefore = await readStat(a.cdp);
  const recoilPerShot = crouchBefore?.recoilPerShotDeg ?? 0;
  const pitchMax = crouchBefore?.pitchMaxDeg ?? 0;
  await keyDown(a.cdp, "ShiftLeft");
  const crouched = await waitFor(async () => {
    const s = await readStat(a.cdp);
    return s && s.crouch > 0.95 ? s : null;
  }, 4000, 200);

  const crouchBurst = await fireBurst(a.cdp, 8);
  await keyUp(a.cdp, "ShiftLeft");
  await waitFor(async () => {
    const s = await readStat(a.cdp);
    return s && s.crouch < 0.05 ? s : null;
  }, 4000, 200);
  const standAfter = await readStat(a.cdp);

  // 水平后坐力：逐发取样，验证“存在、有界、每发不同”。
  // 这一段里不能碰鼠标，否则分不清 yaw 的变化是后坐力还是鼠标造成的。
  const recoilYaw = (await readStat(a.cdp))?.recoilYawDeg ?? 0;
  const taps = (await fireTaps(a.cdp, 8)).filter((t) => t.shots === 1);
  const yawDeltas = taps.map((t) => t.yaw);
  const yawAbsMax = yawDeltas.length ? Math.max(...yawDeltas.map(Math.abs)) : 0;
  const yawSpread = yawDeltas.length
    ? Math.max(...yawDeltas) - Math.min(...yawDeltas)
    : 0;
  const anyYaw = yawAbsMax > 0.05;

  // 等 beta 血量恢复（后台标签页会被节流，给足时间）。
  // 注意：掉血本身是在开火期间盯出来的（见 fireBurst 的 watch），
  // 不能这时候再读——他被打死重生后就又是满血了。
  const betaHealth = standBurst.minHealth;

  // 血量归零后应当自动重生回满血（重生延迟 3 秒，后台页要给足时间）
  const revived = betaHealth <= 0
    ? await waitFor(async () => {
      const s = await readStat(b.cdp);
      return s && s.health >= 100 ? s : null;
    }, 15_000, 400)
    : null;

  // 特效应当自己清掉，不能越积越多
  await sleep(1200);
  const finalA = await readStat(a.cdp);
  const finalB = await readStat(b.cdp);
  const fxAfter = finalA?.fx ?? -1;
  // 散布要在这时候读：它按 3.2°/秒回落，再晚就分不清“回落了”与“根本没长大”
  const spreadRecovered = finalA?.spreadDeg ?? -1;
  const spreadMin = crouchBefore?.spreadMinDeg ?? 0;
  const spreadMax = crouchBefore?.spreadMaxDeg ?? 0;
  // 静止时的准星间距（散布在最小值的状态），用来对比“开火时张开了多少”
  const baseGap = ready.sa.hud?.crosshairGap ?? 0;
  const centerSize = ready.sa.hud?.crosshairCenter ?? 0;

  const idA = ready.sa.myId;
  const idB = ready.sb.myId;
  const nameA = ready.sa.myName;
  const scoreA = finalA?.match?.scores?.[String(idA)] ?? {};
  const scoreAonB = finalB?.match?.scores?.[String(idA)] ?? {};
  const deathsB = finalB?.match?.scores?.[String(idB)] ?? {};

  console.log("");
  const results = [
    ["指针被锁定（不然鼠标事件不生效）", locked, "点击画面后应进入指针锁定"],
    ["出生朝向指着对方", aimErr < 5.0,
      `当前 ${facingDeg.toFixed(1)}°、目标 ${targetYaw.toFixed(1)}°，差 ${aimErr.toFixed(1)}°`],
    ["点击进入游戏的那一下不开火", shotsAfterCapture === 0,
      `点击后已开火 ${shotsAfterCapture} 发`],
    ["进游戏前提示点击画面", /CLICK TO PLAY/.test(idleHint), `提示 "${idleHint}"`],
    ["接管鼠标后提示收起", capturedHint === "", `提示 "${capturedHint}"`],
    ["真的打出去了", shotsDelta > 0, `新增 ${shotsDelta} 发`],
    ["射速受冷却限制（不是每帧一发）", ratePerSec > 3.0 && ratePerSec < 15.0,
      `按住 ${fireMs} ms 打出 ${shotsDelta} 发，合 ${ratePerSec.toFixed(1)} 发/秒（配置 9）`],
    ["开火产生了特效（曳光/弹着点）", fxMax > 0, `同时存在的特效最多 ${fxMax} 个`],
    ["特效会自己清掉（不堆积）", fxAfter === 0, `1.2 秒后剩 ${fxAfter} 个`],
    ["开火时准星逐渐往上飘", standBurst.pitchClimb > 1.0,
      `俯仰 ${standBurst.pitchBefore.toFixed(1)}° → 峰值 ${(standBurst.pitchBefore + standBurst.pitchClimb).toFixed(1)}°，`
      + `飘升 ${standBurst.pitchClimb.toFixed(1)}°（每发 ${recoilPerShot}°、最大俯仰 ${pitchMax}°）`],
    ["飘上去后不回落（准星留在原位不动）", holdDrift < 0.5 && climbedTotal > 1.0,
      `松手瞬间 ${standBurst.pitchAfterRelease.toFixed(1)}°，1.5 秒后 ${pitchHeld.toFixed(1)}°`
      + `（漂移 ${holdDrift.toFixed(2)}°，约 0 才对），比开火前高 ${climbedTotal.toFixed(1)}°`],
    ["持续开火会继续往上飘", secondBurst.pitchClimb > 0.5,
      `第二轮又飘 ${secondBurst.pitchClimb.toFixed(1)}°`],
    ["飘升不超过俯仰上限", pitchHeld <= pitchMax + 0.3,
      `俯仰 ${pitchHeld.toFixed(1)}°（上限 ${pitchMax}°，配置值）`],
    ["按住 Shift 会下蹲", crouched !== null,
      `下蹲程度 ${(crouched?.crouch ?? 0).toFixed(2)}（0 站、1 蹲）`],
    ["下蹲时相机降低", crouched !== null && crouched.camY < crouchBefore.camY - 0.2,
      `相机 ${crouchBefore.camY.toFixed(2)} → ${(crouched?.camY ?? 0).toFixed(2)} 米`],
    ["下蹲时准星仍不被自己挡住", crouched !== null && crouched.headScreenY >= 0.55,
      `头顶屏幕纵向 ${(crouched?.headScreenY ?? -1).toFixed(2)}（准星 0.50，应当更大）`],
    ["下蹲后后坐力变小", crouchBurst.pitchClimb < standBurst.pitchClimb * 0.7,
      `站立抬 ${standBurst.pitchClimb.toFixed(1)}° / 下蹲抬 ${crouchBurst.pitchClimb.toFixed(1)}°`],
    ["松开 Shift 后能站起来", standAfter !== null && standAfter.crouch < 0.05,
      `下蹲程度 ${(standAfter?.crouch ?? -1).toFixed(2)}，相机回到 ${(standAfter?.camY ?? 0).toFixed(2)} 米`],
    ["开火会让准星左右偏", anyYaw,
      `${yawDeltas.length} 发里最大偏移 ${yawAbsMax.toFixed(2)}°`],
    ["每发的左右偏移不超出设定范围", yawAbsMax <= recoilYaw + 0.25,
      `最大 ${yawAbsMax.toFixed(2)}°（上限 ${recoilYaw}°，配置值；另留 0.25° 供快照取整）`],
    ["左右偏移是随机的（每发不一样）", yawSpread > 0.1,
      `极差 ${yawSpread.toFixed(2)}°（逐发：${yawDeltas.map((d) => d.toFixed(1)).join(", ")}）`],
    ["被打的人扣了血", betaHealth < 100, `beta 最低血量 ${betaHealth}`],
    ["血量归零后重生回满血", betaHealth > 0 || revived !== null,
      betaHealth > 0 ? `未打死（剩 ${betaHealth}）` : `重生后 ${revived?.health ?? "未恢复"}`],
    ["开火让散布变大", standBurst.maxSpread > spreadMin + 0.3,
      `散布 ${spreadMin}° → ${standBurst.maxSpread.toFixed(2)}°（上限 ${spreadMax}°，配置值）`],
    ["散布不超过上限", standBurst.maxSpread <= spreadMax + 0.15,
      `最大 ${standBurst.maxSpread.toFixed(2)}°，上限 ${spreadMax}°`],
    ["停火后散布回落到最小", Math.abs(spreadRecovered - spreadMin) < 0.35,
      `1.2 秒后 ${spreadRecovered}°，最小 ${spreadMin}°`],
    ["开火起了音效播放器", standBurst.maxSounds > 0,
      `开火期间同时有 ${standBurst.maxSounds} 个音效在播`],
    ["准星间距跟着散布张开", standBurst.maxGap > baseGap + 1.5,
      `准星间距 ${baseGap} → ${standBurst.maxGap} 像素（散布 ${spreadMin}° → ${standBurst.maxSpread.toFixed(2)}°）`],
    ["准星中心是小点、不挡视野", centerSize > 0 && centerSize <= 4.0,
      `中心点 ${centerSize} 像素（曾经是 6 像素的实心方块）`],
    ["准星中心与刻度分得开（不会并成一块）", baseGap - centerSize / 2 >= 1.0,
      `间隙 ${(baseGap - centerSize / 2).toFixed(1)} 像素（间距 ${baseGap}、中心半径 ${centerSize / 2}）`],
    ["打中对方后开枪方出现命中提示", (finalA?.hud?.hitmarkers ?? 0) > 0,
      `命中提示 ${finalA?.hud?.hitmarkers ?? 0} 次`],
    ["击倒对方时出现击杀提示", (finalA?.hud?.kills ?? 0) > 0,
      `击杀提示 ${finalA?.hud?.kills ?? 0} 次`],
    ["击杀与阵亡各自记在两端", (scoreA.kills ?? 0) >= 1 && (deathsB.deaths ?? 0) >= 1,
      `alpha 记 ${scoreA.kills ?? "-"} 杀（${nameA}）/ beta 记 ${deathsB.deaths ?? "-"} 阵亡`],
    ["两端对同一份比分看法一致",
      (scoreA.kills ?? -1) === (scoreAonB.kills ?? -2) && (scoreA.deaths ?? -1) === (scoreAonB.deaths ?? -2),
      `alpha 眼中 ${nameA}: ${scoreA.kills ?? "-"} 杀 / beta 眼中 ${nameA}: ${scoreAonB.kills ?? "-"} 杀`],
    ["记分板与击杀提示真的画在屏幕上",
      (finalA?.hud?.scoreboard ?? "").includes(nameA)
      && /[1-9]/.test(finalA?.hud?.scoreboard ?? "")
      && standBurst.feedSeen.includes(" > "),
      `记分板 "${finalA?.hud?.scoreboard ?? ""}"、击杀提示（开火期间拍到）"${standBurst.feedSeen}"`],
  ];
  console.log("  结论:");
  for (const [label, ok, detail] of results) {
    console.log(`  ${ok ? "✓" : "✗"} ${label} — ${detail}`);
  }
  console.log("");
  if (results.some(([, ok]) => !ok)) {
    process.exitCode = 1;
    for (const inst of instances) {
      console.log(`  --- ${inst.name} 控制台 ---`);
      for (const line of inst.cdp.console.slice(-20)) console.log(`    ${line}`);
      for (const line of inst.cdp.exceptions.slice(-5)) console.log(`    EXCEPTION ${line}`);
    }
  }
}

/**
 * 记分模式：用 ?kills=1 把一局压到几秒，验证记分、胜负横幅与下一回合的重置。
 *
 * 能自动验证的边界：只有"界面真的显示了什么"需要读 HUD 的文字——比分数字对、
 * 界面上没画出来也是一样的，所以两项都断言。
 */
async function checkScore() {
  const a = instances.find((i) => i.name === "alpha");
  const b = instances.find((i) => i.name === "beta");

  await a.cdp.send("Page.bringToFront");
  await sleep(700);

  // 横幅会换文案：先连上的人先看到 WAITING FOR OPPONENT，对手出现那一刻才喊 ROUND 1。
  // 所以要把等待期间出现过的文案都收下来，不能只记第一条。
  const bannersSeen = new Set();
  const ready = await waitFor(async () => {
    const sa = await readStat(a.cdp);
    const sb = await readStat(b.cdp);
    if (sa?.hud?.banner) bannersSeen.add(sa.hud.banner);
    if (sa?.connected && sb?.connected && sa.peers.length > 0 && sb.peers.length > 0
      && sa.hud?.scoreboard) {
      return { sa, sb };
    }
    return null;
  }, 30_000);
  if (!ready) {
    console.log("  联机没就绪，无法测记分。");
    process.exitCode = 1;
    return;
  }

  // 开场横幅比“就绪”判定可能晚一两轮（它是在收到对手状态包那一刻才喊的），再看一会儿。
  await waitFor(async () => {
    const sa = await readStat(a.cdp);
    if (sa?.hud?.banner) bannersSeen.add(sa.hud.banner);
    return [...bannersSeen].some((t) => /ROUND 1/.test(t)) || null;
  }, 6_000, 200);
  const introBanners = [...bannersSeen];

  const idA = ready.sa.myId;
  const idB = ready.sb.myId;
  const nameA = ready.sa.myName;
  const nameB = ready.sa.peerNames[String(idB)] ?? "?";
  // 只比水平距离：出生点记的是 y=1（脚底在落地前的位置），重置后还会再落一次。
  const flatDist = (p, q) => Math.hypot(p[0] - q[0], p[2] - q[2]);
  const spawnA = ready.sa.pos.slice();
  const spawnYawA = ready.sa.figure.bodyYawDeg;
  const introScoreboard = ready.sa.hud.scoreboard;

  const locked = await clickToCapture(a.cdp);
  if (locked) usedPointerLock = true;
  console.log(`  指针锁定: ${locked}`);
  await sleep(800);

  // 打倒对方。一杀定胜负，所以这一轮按住打完就该结算。
  const burst = await fireBurst(a.cdp, 16, { watch: b.cdp });

  // 击杀事件要走一趋中继，等两端都记上再断言。
  const scored = await waitFor(async () => {
    const sa = await readStat(a.cdp);
    const sb = await readStat(b.cdp);
    const okA = (sa?.match?.scores?.[String(idA)]?.kills ?? 0) >= 1;
    const okB = (sb?.match?.scores?.[String(idA)]?.kills ?? 0) >= 1;
    return okA && okB ? { sa, sb } : null;
  }, 12_000, 200);

  const bannerA = scored?.sa?.hud?.banner ?? "";
  const bannerB = scored?.sb?.hud?.banner ?? "";
  const overScoresA = scored?.sa?.match?.scores ?? {};

  // 人眼核对用：此时胜负横幅、最终比分、击杀提示同时在场，是唯一能一起看到的时刻。
  // 击杀提示只挂 3.5 秒，所以必须在这里拍，不能等收尾那一张。
  if (SHOT_DIR && scored) {
    fs.mkdirSync(SHOT_DIR, { recursive: true });
    const img = await a.cdp.send("Page.captureScreenshot", { format: "png" });
    const file = path.join(SHOT_DIR, "score-round-over.png");
    fs.writeFileSync(file, Buffer.from(img.data, "base64"));
    console.log(`  回合结算截图 ${file}`);
  }

  // 结算期间故意离开出生点：不这样的话，“重置把人送回出生点”本来就成立，验了等于没验。
  await keyDown(a.cdp, "KeyD");
  await mouseDelta(a.cdp, 260);
  await sleep(500);
  await keyUp(a.cdp, "KeyD");
  await sleep(300);
  const movedA = await readStat(a.cdp);
  const movedDist = movedA ? flatDist(movedA.pos, spawnA) : 0;
  const turnedDeg = movedA ? Math.abs(angleDiff(movedA.figure.bodyYawDeg, spawnYawA)) : 0;

  // 等下一回合：比分清零、回合号 +1、人回到出生点
  const reset = await waitFor(async () => {
    const sa = await readStat(a.cdp);
    const sb = await readStat(b.cdp);
    return sa?.match?.round === 2 && sb?.match?.round === 2 ? { sa, sb } : null;
  }, 25_000, 250);

  const a2 = reset?.sa;
  const b2 = reset?.sb;
  const limit = ready.sa.match.scoreLimit;
  const posBack = a2 ? flatDist(a2.pos, spawnA) : 999;
  const yawBack = a2 ? Math.abs(angleDiff(a2.figure.bodyYawDeg, spawnYawA)) : 999;
  const resetScoresA = a2?.match?.scores ?? {};

  // 替身实际画在哪 vs 收到的目标点。两者差得大就说明还在平滑滑行——
  // 回合重置是瞬间换位置的，那段距离必须走瞬移分支。
  const peerIdB2 = b2 ? String(b2.myId) : "";
  const avatarLag = a2?.avatarPos?.[peerIdB2] && a2?.peerPos?.[peerIdB2]
    ? flatDist(a2.avatarPos[peerIdB2], a2.peerPos[peerIdB2]) : 999;
  const avatarFromSpawn = a2?.avatarPos?.[peerIdB2]
    ? flatDist(a2.avatarPos[peerIdB2], ready.sb.pos) : 999;

  console.log("");
  if (!scored) console.log("  ⚠ 没等到记分事件，后面的结论按“未发生”判定。");
  if (!reset) console.log("  ⚠ 没等到下一回合，后面的结论按“未发生”判定。");
  const results = [
    ["分数上限来自网址参数", limit === 1, `scoreLimit=${limit}（网址 ?kills=1）`],
    ["单人时提示等待对手，对手出现后喊回合开场",
      introBanners.some((t) => /WAITING FOR OPPONENT/.test(t))
      && introBanners.some((t) => /ROUND 1/.test(t)),
      `先后见到：${introBanners.map((b) => `"${b}"`).join(" → ")}`],
    ["记分板开局就列出双方且各为 0", introScoreboard.includes(nameA)
      && introScoreboard.includes(nameB) && !/[1-9]/.test(introScoreboard),
      `记分板 "${introScoreboard}"`],
    ["击倒对方后自己记上一杀", (overScoresA[String(idA)]?.kills ?? 0) === 1,
      `alpha(${nameA}) 记 ${overScoresA[String(idA)]?.kills ?? "-"} 杀，beta 最低血量 ${burst.minHealth}`],
    ["被打的人记上一次阵亡", (overScoresA[String(idB)]?.deaths ?? 0) === 1,
      `beta(${nameB}) 记 ${overScoresA[String(idB)]?.deaths ?? "-"} 次阵亡`],
    ["两端对同一份比分看法一致",
      (scored?.sa?.match?.scores?.[String(idA)]?.kills ?? -1)
      === (scored?.sb?.match?.scores?.[String(idA)]?.kills ?? -2),
      `alpha 眼中 ${nameA} ${scored?.sa?.match?.scores?.[String(idA)]?.kills ?? "-"} 杀 / beta 眼中`
      + ` ${nameA} ${scored?.sb?.match?.scores?.[String(idA)]?.kills ?? "-"} 杀`],
    ["胜负横幅按胜负区分", /YOU WIN/.test(bannerA) && /YOU LOSE/.test(bannerB),
      `alpha "${bannerA}" / beta "${bannerB}"`],
    ["横幅里带最终比分", bannerA.includes(nameA) && bannerA.includes(nameB), `"${bannerA}"`],
    ["击杀提示出现在两端",
      (scored?.sa?.hud?.feed ?? "").includes(nameB) && (scored?.sb?.hud?.feed ?? "").includes(nameB),
      `alpha "${scored?.sa?.hud?.feed ?? ""}" / beta "${scored?.sb?.hud?.feed ?? ""}"`],
    ["倒下时溅出碎屑（两端各算一次）",
      (scored?.sa?.fxBursts ?? 0) >= 1 && (scored?.sb?.fxBursts ?? 0) >= 1,
      `alpha ${scored?.sa?.fxBursts ?? "-"} 次 / beta ${scored?.sb?.fxBursts ?? "-"} 次`],
    ["结算期间真的离开了出生点", movedDist > 0.5 || turnedDeg > 5,
      `位移 ${movedDist.toFixed(2)} 米、转身 ${turnedDeg.toFixed(1)}°（这样“重置回出生点”才有意义）`],
    ["下一回合比分清零", (resetScoresA[String(idA)]?.kills ?? -1) === 0
      && (resetScoresA[String(idB)]?.deaths ?? -1) === 0,
      `alpha ${resetScoresA[String(idA)]?.kills ?? "-"} 杀 / beta ${resetScoresA[String(idB)]?.deaths ?? "-"} 阵亡`],
    ["回合号 +1 且两端同步进入", (a2?.match?.round ?? 0) === 2 && (b2?.match?.round ?? 0) === 2,
      `alpha round=${a2?.match?.round ?? "-"} / beta round=${b2?.match?.round ?? "-"}`],
    ["重置把人送回出生点", posBack < 0.6, `离出生点 ${posBack.toFixed(2)} 米`],
    ["重置恢复开局朝向", yawBack < 3.0, `与开局朝向差 ${yawBack.toFixed(1)}°`],
    ["重置把对方替身也送回出生点", avatarFromSpawn < 0.8,
      `替身离对方出生点 ${avatarFromSpawn.toFixed(2)} 米`],
    ["替身是瞬移过去的（不在半路滑行）", avatarLag < 0.35,
      `替身与收到的目标点差 ${avatarLag.toFixed(2)} 米`],
    ["重置后血量回满且复活", (a2?.health ?? 0) === 100, `血量 ${a2?.health ?? "-"}`],
    ["下一回合横幅显示 ROUND 2", /ROUND 2/.test(a2?.hud?.banner ?? ""),
      `横幅 "${a2?.hud?.banner ?? ""}"`],
  ];
  console.log("  结论:");
  for (const [label, ok, detail] of results) {
    console.log(`  ${ok ? "✓" : "✗"} ${label} — ${detail}`);
  }
  console.log("");
  if (results.some(([, ok]) => !ok)) {
    process.exitCode = 1;
    for (const inst of instances) {
      console.log(`  --- ${inst.name} 控制台 ---`);
      for (const line of inst.cdp.console.slice(-20)) console.log(`    ${line}`);
      for (const line of inst.cdp.exceptions.slice(-5)) console.log(`    EXCEPTION ${line}`);
    }
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

  // 两个实例是同时启动的，谁先连上不确定，所以只要求是 0 与 1 各一个。
  const ranks = [a.myRank, b.myRank].sort();

  // --- 朝向同步：用鼠标真实转向，再看远端替身有没有跟上 ---
  //
  // 方向键现在不带动任何旋转（只有鼠标会），所以转向必须用鼠标事件来制造。
  // 指针锁定下 Chrome 会用 x/y 的差值算出 movementX，Godot 的 _unhandled_input 据此旋转。
  const alphaInst = instances.find((i) => i.name === "alpha");
  await alphaInst.cdp.send("Page.bringToFront");
  await sleep(500);
  const alphaLocked = await clickToCapture(alphaInst.cdp);
  if (alphaLocked) usedPointerLock = true;

  const yawBefore = (await readStat(alphaInst.cdp))?.figure?.bodyYawDeg ?? 0;
  for (let i = 0; i < 12; i++) {
    await alphaInst.cdp.send("Input.dispatchMouseEvent", {
      type: "mouseMoved", x: 300 + i * 40, y: 360, buttons: 0,
    });
    await sleep(60);
  }
  // 等 Godot 把队列里的事件都处理完、朝向稳定下来再读。
  // 发完事件立刻就读会拿到中途值，把“采样时机”误判成“没有转动”。
  await sleep(1500);
  const yawAfter = (await readStat(alphaInst.cdp))?.figure?.bodyYawDeg ?? 0;
  const mouseTurned = Math.abs(angleDiff(yawAfter, yawBefore)) > 5;

  // 再等替身的插值收敛，然后同时读两侧，避免把“采样错位”当成朝向不一致。
  await sleep(1000);
  const lastAlpha = await readStat(alphaInst.cdp);
  const betaInst = instances.find((i) => i.name === "beta");
  const lastBeta = await readStat(betaInst.cdp);
  const selfFacing = lastAlpha?.figure?.facingDeg ?? 0;
  const remoteFacing = lastBeta?.avatarYawDeg?.[String(lastAlpha?.myId)] ?? null;
  const facingGap = remoteFacing === null ? 999 : Math.abs(angleDiff(remoteFacing, selfFacing));
  const rpcErrors = instances.reduce((sum, i) => sum + rpcErrorCount(i.cdp), 0);

  const results = [
    ["两个客户端都进入已连接状态", a.connected && b.connected,
      `alpha ${a.status} / beta ${b.status}`],
    ["双方编号不同", a.myId !== b.myId, `alpha=${a.myId} beta=${b.myId}`],
    ["各自看到对方的编号", a.peers.includes(b.myId) && b.peers.includes(a.myId),
      `alpha 看到 ${JSON.stringify(a.peers)} / beta 看到 ${JSON.stringify(b.peers)}`],
    ["各自为对方建了替身", a.avatars >= 1 && b.avatars >= 1,
      `alpha 替身 ${a.avatars} / beta 替身 ${b.avatars}`],
    ["按进入顺序分到 0 号与 1 号样式", ranks[0] === 0 && ranks[1] === 1,
      `alpha rank=${a.myRank}(${a.myStyle}) / beta rank=${b.myRank}(${b.myStyle})`],
    ["两人样式不同", a.myStyle !== b.myStyle, `${a.myStyle} / ${b.myStyle}`],
    ["替身样式与对方的进入顺序一致",
      a.peerRanks[String(b.myId)] === b.myRank && b.peerRanks[String(a.myId)] === a.myRank,
      `alpha 眼中 beta=${a.peerRanks[String(b.myId)]} / beta 眼中 alpha=${b.peerRanks[String(a.myId)]}`],
    ["替身的命中框与头顶血条都还在", decorOk(a) && decorOk(b),
      `alpha 眼中 beta=${JSON.stringify(a.avatarDecor[String(b.myId)])}`
      + ` / beta 眼中 alpha=${JSON.stringify(b.avatarDecor[String(a.myId)])}`],
    ["鼠标转向后远端替身朝向跟随", mouseTurned && facingGap < 15,
      `本体朝向 ${selfFacing.toFixed(1)}°，远端替身 ${remoteFacing === null ? "无" : remoteFacing.toFixed(1) + "°"}（差 ${facingGap.toFixed(1)}°）`],
    ["接收过程没有 RPC 路径解析错误", rpcErrors === 0,
      `${rpcErrors} 条（路径缓存丢失会让更新静默丢失）`],
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

