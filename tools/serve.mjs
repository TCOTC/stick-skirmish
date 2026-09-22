#!/usr/bin/env node
/**
 * 局域网静态服务：把 build/ 里的网页版发给同一网络下的另一台设备。
 *
 *   node tools/serve.mjs            # 服务 build/，HTTP 8000 + HTTPS 8001
 *   node tools/serve.mjs dist 9000  # 指定目录和端口
 *
 * 三个关键点（踩过就知道疼）：
 *   1. .wasm 必须用 application/wasm，否则浏览器不肯流式编译；
 *   2. 37MB 的 wasm 不压缩会很慢，这里对文本类资源开 gzip，实测降到 10MB 左右。
 *   3. 【最重要】Godot 4 的网页版要求 Secure Context。明文 HTTP 的局域网地址
 *      （非 localhost）不算安全上下文，引擎会直接拒绝启动，报
 *      "Secure Context - Check web server configuration (use HTTPS)"。
 *      所以必须同时开 HTTPS。自签证书会让浏览器报"不受信任"，
 *      点「高级 → 继续前往」之后 isSecureContext 就成立，游戏正常跑。
 *
 * 网页版用的是单线程模板（variant/thread_support=false），
 * 所以不需要 COOP/COEP 跨域隔离响应头。
 */
import http from "node:http";
import https from "node:https";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import zlib from "node:zlib";

const root = path.resolve(process.argv[2] ?? path.join(process.cwd(), "build"));
const port = Number(process.argv[3] ?? process.env.PORT ?? 8000);

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".wasm": "application/wasm",
  ".pck": "application/octet-stream",
  ".png": "image/png",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
};

const COMPRESSIBLE = new Set([".html", ".js", ".mjs", ".css", ".json", ".svg", ".wasm", ".pck"]);

const handler = (req, res) => {
  const url = new URL(req.url ?? "/", "http://localhost");
  let rel = decodeURIComponent(url.pathname);
  if (rel === "/") rel = "/index.html";

  const file = path.resolve(path.join(root, rel));
  if (!file.startsWith(root + path.sep) && file !== root) {
    res.writeHead(403).end("forbidden");
    return;
  }

  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) {
      res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" }).end("404 not found");
      return;
    }

    const ext = path.extname(file).toLowerCase();
    const type = MIME[ext] ?? "application/octet-stream";
    const wantsGzip = /gzip/.test(String(req.headers["accept-encoding"] ?? ""));

    if (COMPRESSIBLE.has(ext) && wantsGzip) {
      res.writeHead(200, {
        "Content-Type": type,
        "Content-Encoding": "gzip",
        "Vary": "Accept-Encoding",
        "Cache-Control": "no-store",
      });
      fs.createReadStream(file).pipe(zlib.createGzip({ level: 6 })).pipe(res);
    } else {
      res.writeHead(200, {
        "Content-Type": type,
        "Content-Length": st.size,
        "Cache-Control": "no-store",
      });
      fs.createReadStream(file).pipe(res);
    }
  });
};

const certDir = path.join(process.cwd(), "certs");
const keyFile = path.join(certDir, "lan.key");
const crtFile = path.join(certDir, "lan.crt");

function lanIPv4() {
  const found = [];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const ni of list ?? []) {
      if (ni.family === "IPv4" && !ni.internal) found.push(ni.address);
    }
  }
  return found;
}

const LAN_IPS = lanIPv4();

// --- 自签证书：缺了就生成，局域网 IP 变了就重签 ---------------------------
// 证书的 SAN 里写死了 IP。换个网络（比如去表弟家）IP 就会变，浏览器会一直
// 提示不安全。所以每次启动都比对一遍，对不上就按当前 IP 重新签一张。
function readSan() {
  try {
    return new crypto.X509Certificate(fs.readFileSync(crtFile)).subjectAltName ?? "";
  } catch {
    return "";
  }
}

function findOpenssl() {
  const candidates = [
    process.env.OPENSSL,
    "C:\\Program Files\\Git\\usr\\bin\\openssl.exe",
    "C:\\Program Files\\Git\\mingw64\\bin\\openssl.exe",
    "C:\\Program Files (x86)\\Git\\usr\\bin\\openssl.exe",
  ].filter(Boolean);
  for (const c of candidates) {
    if (fs.existsSync(c)) return c;
  }
  try {
    const cmd = process.platform === "win32" ? "where" : "which";
    const first = execFileSync(cmd, ["openssl"], { encoding: "utf8" }).split(/\r?\n/)[0].trim();
    if (first && fs.existsSync(first)) return first;
  } catch {
    // 找不到就算了，下面会给提示
  }
  return null;
}

function ensureCert() {
  const san = readSan();
  if (fs.existsSync(keyFile) && fs.existsSync(crtFile)
      && san && LAN_IPS.every((ip) => san.includes(`IP Address:${ip}`))) {
    return true;
  }

  const openssl = findOpenssl();
  if (!openssl) {
    console.error("");
    console.error("  ⚠ 证书缺失或没覆盖当前 IP，又找不到 openssl，无法自动生成。");
    console.error("    手动生成命令见 README。");
    return false;
  }

  const altNames = ["DNS:localhost", "IP:127.0.0.1", ...LAN_IPS.map((ip) => `IP:${ip}`)].join(",");
  const toWinPath = (p) => p.replace(/\\/g, "/");
  try {
    execFileSync(
      openssl,
      [
        "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "3650", "-nodes",
        "-keyout", toWinPath(keyFile), "-out", toWinPath(crtFile),
        "-subj", "/CN=Stick Skirmish LAN",
        "-addext", `subjectAltName=${altNames}`,
      ],
      // MSYS 版的 openssl 会把 /CN=... 当成路径去改写，必须关掉路径转换
      { stdio: "ignore", env: { ...process.env, MSYS_NO_PATHCONV: "1" } }
    );
    console.log(`  已自动重新生成自签证书 → ${["localhost", "127.0.0.1", ...LAN_IPS].join(", ")}`);
    return true;
  } catch (err) {
    console.error("");
    console.error(`  ⚠ 自动生成证书失败: ${err.message}`);
    console.error("    手动生成命令见 README。");
    return false;
  }
}

fs.mkdirSync(certDir, { recursive: true });
const hasTls = ensureCert();

function banner(scheme, boundPort, note) {
  console.log("");
  console.log(`  ${scheme.toUpperCase()}  端口 ${boundPort}${note ? "   " + note : ""}`);
  for (const ip of LAN_IPS) {
    console.log(`    ${scheme}://${ip}:${boundPort}/`);
  }
  console.log(`    ${scheme}://localhost:${boundPort}/`);
}

function onError(err) {
  if (err.code === "EADDRINUSE") {
    // 端口被别人占了（比如上次没关干净），不要整个进程一起死
    console.error(`  端口被占用，跳过这个监听: ${err.message}`);
    return;
  }
  console.error(`启动失败: ${err.message}`);
  process.exit(1);
}

console.log("");
console.log("  Stick Skirmish 局域网服务");
console.log(`  服务目录: ${root}`);
console.log("");
console.log("  ⚠ Godot 网页版要求 Secure Context：明文 HTTP 只有本机能用，");
console.log("    另一台设备必须走 HTTPS 那个地址。");

http.createServer(handler).on("error", onError).listen(port, "0.0.0.0", () => {
  banner("http", port, "(仅本机可用)");
});

if (hasTls) {
  const tlsOptions = { key: fs.readFileSync(keyFile), cert: fs.readFileSync(crtFile) };
  https.createServer(tlsOptions, handler).on("error", onError)
    .listen(port + 1, "0.0.0.0", () => {
      banner("https", port + 1, "(另一台设备用这个)");
      console.log("");
      console.log("  浏览器提示证书不受信任 → 点「高级」→「继续前往」，之后正常玩。");
      console.log("  证书已按当前 IP 签好，有效期 10 年。");
      console.log("");
      console.log("  Ctrl+C 停止。");
      console.log("");
    });
} else {
  console.log("");
  console.log("  ⚠ HTTPS 未启动，另一台设备将无法运行（Secure Context 不满足）。");
  console.log("    需要一张自签证书放在 certs/，生成办法见 README。");
  console.log("");
}
