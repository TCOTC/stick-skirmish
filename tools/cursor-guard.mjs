#!/usr/bin/env node
/**
 * 光标守卫的 Node 侧封装（也兼作命令行工具）。
 *
 * 【问题】浏览器进入指针锁定会调用 Windows 的 ClipCursor 把光标圈在自己的窗口里，
 * 而还原发生在窗口销毁的流程里。只要测试没走到收尾（被强杀、崩溃、Ctrl+C），
 * 限制就作为孤儿留在系统里，用户鼠标只能在屏幕一角移动。
 *
 * 【做法】启动一个独立的 PowerShell 进程（tools/cursor-guard.ps1）在整个测试期间
 * 反复解除裁剪，并在父进程消失时顺手清掉遗留的测试用 Chrome。
 * 它不依赖测试进程的收尾逻辑，所以强杀也有效。
 *
 * 直接运行（整个开发时段的手动守护）：
 *   node tools/cursor-guard.mjs --minutes 60
 */
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const DIR = path.dirname(fileURLToPath(import.meta.url));
const GUARD_PS1 = path.join(DIR, "cursor-guard.ps1");

/**
 * 只清理测试用的 Chrome，按命令行里的标记匹配。
 *
 * **不要用端口号匹配**：mojo 参数里会偶然出现 9333 这类数字，会误伤用户自己的浏览器。
 * 这两个标记来自测试脚本自己的 profile 目录名（stick-netprobe-* / stick-shot-*）。
 */
const TEST_CHROME_MARKER = "stick-netprobe|stick-shot";

/**
 * 启动守卫。返回的对象里：
 *   - `stop()` 请测试收尾时调用（异步，等守卫写下统计）
 *   - `report()` 读取统计行，用于把「鼠标被圈住多久」变成可断言的数字
 *
 * 非 Windows 或脚本缺失时返回空实现，调用方不必分支。
 */
export function startCursorGuard({ minutes = 30, intervalMs = 100, label = "test", profileDir = "" } = {}) {
  const noop = { stop: async () => {}, report: () => "" };
  if (process.platform !== "win32" || !fs.existsSync(GUARD_PS1)) return noop;

  const logFile = path.join(os.tmpdir(), `cursor-guard-${label}-${process.pid}.log`);
  const stopFile = `${logFile}.stop`;
  for (const f of [logFile, stopFile]) {
    try { fs.rmSync(f, { force: true }); } catch { /* 不存在就算了 */ }
  }

  const psArgs = [
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", GUARD_PS1,
    "-ParentId", String(process.pid),
    "-MaxMinutes", String(minutes),
    "-IntervalMs", String(intervalMs),
    "-KillMarker", TEST_CHROME_MARKER,
    "-LogFile", logFile,
    "-StopFile", stopFile,
  ];
  // 测试自己的临时目录：父进程被强杀时由守卫负责删掉（那时测试的清理代码没机会跑）。
  if (profileDir) psArgs.push("-ProfileDir", profileDir);

  // 【为什么用 Start-Process 包一层】直接把 powershell 作为 node 的子进程启动时，
  // 它跟测试进程共用同一个控制台，而“测试被杀”会关闭那个控制台并给台上所有进程
  // 发 CTRL_CLOSE —— 守卫会跟着一起死，它准备的收尾（解除裁剪、清掉残留 Chrome）
  // 根本没机会执行。实测就是这么漏的：日志里只剩一行 started。
  // Start-Process 让守卫拿到**自己的控制台**，于是它与测试进程的生死脱钩。
  //
  // 另外实测：给 spawn 传 detached: true 会让守卫根本起不来
  // （PowerShell 5.1 + windowsHide + stdio:ignore 的组合），所以只能这样绕。
  const inner = psArgs.map((a) => `'${String(a).replace(/'/g, "''")}'`).join(",");
  const bootstrap = spawn(
    "powershell",
    ["-NoProfile", "-Command",
      `Start-Process -FilePath powershell -WindowStyle Hidden -ArgumentList @(${inner})`],
    { stdio: "ignore", windowsHide: true },
  );
  // 守卫本身失败不该影响测试：它只是“少了一层保护”，而不是测试的前提
  bootstrap.on("error", () => {});
  bootstrap.unref();

  const readLog = () => {
    try {
      return fs.readFileSync(logFile, "utf8").trim();
    } catch {
      return "";
    }
  };

  return {
    /**
     * 交还控制权。用「写停止文件」而不是直接杀进程，这样守卫能来得及写下统计行
     * （统计行是验证“鼠标真的没被困住”的唯一证据）。
     *
     * 注意等的是**统计行**而不是“日志文件出现”：守卫一启动就会写一行 started，
     * 若按文件存在与否判断，就会在它还没进主循环时把它杀掉。
     */
    async stop(timeoutMs = 3000) {
      try { fs.writeFileSync(stopFile, "stop"); } catch { /* 忽略 */ }
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        if (readLog().includes("cleared=")) break;
        await new Promise((r) => setTimeout(r, 100));
      }
      // 兜底：没听话就按**唯一的日志文件名**把它找出来杀掉
      // （守卫是 Start-Process 启的，手上没有它的句柄）。用日志名而不是脚本名匹配，
      // 免得把同时跑着的另一个测试的守卫一起杀掉。
      try {
        execFileSync("powershell", [
          "-NoProfile", "-Command",
          "Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\""
          + ` | Where-Object { $_.CommandLine -like '*${logFile}*' }`
          + " | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }",
        ], { stdio: "ignore" });
      } catch { /* 已经退了 */ }
      try { fs.rmSync(stopFile, { force: true }); } catch { /* 忽略 */ }
    },
    report() {
      return readLog();
    },
  };
}

/**
 * 把守卫的统计行解析成数字，供测试断言。读不到返回 null。
 *
 * 日志里还有 started / phase 几行诊断信息，所以先挑出含 `cleared=` 的那一行再解析，
 * 否则 `samples=` 可能命中 phase 行（数值一样，但那是巧合，不该依赖）。
 */
export function parseGuardReport(line) {
  if (!line) return null;
  const summary = line.split(/\r?\n/).find((l) => l.includes("cleared=")) ?? "";
  if (!summary) return null;
  const pick = (key) => {
    const m = summary.match(new RegExp(`${key}=(-?\\d+)`));
    return m ? Number(m[1]) : null;
  };
  const rect = (key) => {
    const m = summary.match(new RegExp(`${key}=(-?\\d+),(-?\\d+),(-?\\d+),(-?\\d+)`));
    return m ? [Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4])] : null;
  };
  const cleared = pick("cleared");
  if (cleared === null) return null;
  const baseline = rect("baseline");
  const final = rect("final");
  const same = (a, b) => !!a && !!b && a.every((v, i) => Math.abs(v - b[i]) <= 2);
  return {
    samples: pick("samples") ?? 0,
    cleared,
    worstConfinedMs: pick("worst_confined_ms") ?? 0,
    orphanChrome: pick("orphan_chrome") ?? 0,
    startupClip: pick("startup_clip") ?? 0,
    seconds: pick("seconds") ?? 0,
    baseline,
    final,
    // 收尾之后光标是不是自由的（与启动时的基准一致）。这是“没把用户鼠标困住”的直接证据。
    freed: same(baseline, final),
  };
}

// --- 命令行模式 -------------------------------------------------------------

const isMain = process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
if (isMain) {
  const arg = (name, fallback) => {
    const i = process.argv.indexOf(`--${name}`);
    return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
  };
  const minutes = Number(arg("minutes", 60));
  console.log(`  光标守卫：接下来 ${minutes} 分钟内鼠标不会被指针锁定圈住（Ctrl+C 提前结束）`);
  const guard = startCursorGuard({ minutes, label: "manual" });
  const show = async () => {
    await guard.stop();
    console.log(`  ${guard.report() || "（没有统计行，守卫可能没起来）"}`);
    process.exit(0);
  };
  process.on("SIGINT", () => { void show(); });
  // 等的是**统计行**而不是“日志里有没有内容”：守卫一启动就写一行 started，
  // 按内容判断会让这个命令刚启动就退出（等于没有守护）。
  const wait = setInterval(() => {
    const line = guard.report();
    if (!line.includes("cleared=")) return;
    clearInterval(wait);
    console.log(`  ${line}`);
    console.log("  已到时间上限，守卫退出。要继续守护请重新运行。");
    process.exit(0);
  }, 2000);
}
