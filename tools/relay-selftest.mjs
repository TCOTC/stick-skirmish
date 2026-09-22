#!/usr/bin/env node
/**
 * ws-relay.mjs 的自测。
 *
 * 手写的帧解析（长度三档、掩码、控制帧、分片）是"写错了也不报错、只是消息悄悄丢"的典型，
 * 所以用 Node 自带的 WebSocket 客户端（v22+ 内置，零依赖）跑一遍。
 * 客户端是浏览器级实现，它肯收就说明服务端帧格式符合 RFC 6455。
 *
 *   node tools/relay-selftest.mjs
 */
import http from "node:http";
import { attachWebSocketRelay } from "./ws-relay.mjs";

const PORT = Number(process.env.RELAY_TEST_PORT ?? 8765);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const failures = [];
function check(ok, label, detail = "") {
  console.log(`${ok ? "  ok  " : "  FAIL"} ${label}${detail ? " — " + detail : ""}`);
  if (!ok) failures.push(label);
}

// 退出码必须是 0，所以把“打印了全部通过但进程还是非零退出”这种情况暴露出来。
process.on("uncaughtException", (err) => {
  console.log("\n  UNCAUGHT", err);
  process.exit(2);
});
process.on("unhandledRejection", (err) => {
  console.log("\n  UNHANDLED", err);
  process.exit(3);
});

const server = http.createServer((req, res) => res.writeHead(404).end());
attachWebSocketRelay(server, { log: (msg) => console.log("  [relay]" + msg) });
await new Promise((resolve) => server.listen(PORT, "127.0.0.1", resolve));
const url = `ws://127.0.0.1:${PORT}/ws`;

function client(path = "/ws") {
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}${path}`);
  ws.binaryType = "arraybuffer";
  ws.texts = [];
  ws.bins = [];
  ws.addEventListener("message", (e) => {
    if (typeof e.data === "string") ws.texts.push(e.data);
    else ws.bins.push(Buffer.from(e.data));
  });
  return ws;
}
const opened = (ws) =>
  new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", reject, { once: true });
  });

// 中继不主动发帧：客户端没请求就不应该收到控制消息。
const a = client();
await opened(a);
await sleep(200);
check(a.texts.length === 0, "新连接不会收到中继主动发的帧", JSON.stringify(a.texts));

a.send("relay:whoami");
await sleep(150);
check(
  a.texts.some((t) => t === "relay:hello id=1 room=default peers=1 ids=1"),
  "whoami 拿到自身编号",
  JSON.stringify(a.texts)
);

const b = client();
await opened(b);
b.send("relay:whoami");
b.send("relay:subscribe");
await sleep(200);
check(
  b.texts.some((t) => t === "relay:hello id=2 room=default peers=2 ids=1,2"),
  "whoami 拿到房间花名册",
  JSON.stringify(b.texts)
);
check(
  b.texts.some((t) => t === "relay:subscribed id=2 room=default peers=2"),
  "subscribe 有回执",
  JSON.stringify(b.texts)
);

// 不同路径 = 不同房间，同名编号也不会碰撞
const c = client("/ws/other");
await opened(c);
c.send("relay:whoami");
await sleep(150);
check(
  c.texts.some((t) => t === "relay:hello id=3 room=other peers=1 ids=3"),
  "不同路径是不同房间",
  JSON.stringify(c.texts)
);

// Godot 伪装：连上后的第一个包必须是 4 字节小端 int32，且 ≥ 2
const g = client("/ws/probe-mp?as=godot");
await opened(g);
await sleep(150);
check(
  g.bins.length === 1 && g.bins[0].length === 4 && g.bins[0].readInt32LE(0) >= 2,
  "Godot 伪装会先发 4 字节编号",
  `${g.bins.length} 条，${g.bins[0]?.length ?? 0} 字节，值 ${g.bins[0]?.readInt32LE?.(0)}`
);
check(g.texts.length === 0, "Godot 伪装不需要先请求 whoami", JSON.stringify(g.texts));

const g2 = client("/ws/probe-mp?as=godot");
await opened(g2);
await sleep(150);
check(
  g2.bins.length === 1 && g2.bins[0].readInt32LE(0) !== g.bins[0].readInt32LE(0),
  "Godot 伪装下发的编号各不相同",
  `${g.bins[0]?.readInt32LE?.(0)} / ${g2.bins[0]?.readInt32LE?.(0)}`
);

// 三档长度：<126 单字节、<65536 两字节、其余八字节
const cases = [
  ["小消息 3 字节", Buffer.from([1, 2, 3])],
  ["中消息 200 字节", Buffer.from(Array.from({ length: 200 }, (_, i) => i & 0xff))],
  ["大消息 70000 字节", Buffer.from(Array.from({ length: 70000 }, (_, i) => i & 0xff))],
];
for (const [label, payload] of cases) {
  a.bins.length = 0;
  b.bins.length = 0;
  c.bins.length = 0;
  a.send(payload);
  await sleep(250);
  check(
    b.bins.length === 1 && b.bins[0].equals(payload),
    `B 完整收到${label}`,
    `实收 ${b.bins.length} 条，${b.bins[0]?.length ?? 0} 字节`
  );
  check(a.bins.length === 0, `A 不会收到自己发的${label}`);
  check(c.bins.length === 0, `别的房间不会收到${label}`);
}

// 二进制与文本互不干扰
const cTextsBefore = c.texts.length;
a.bins.length = 0;
b.bins.length = 0;
b.texts.length = 0;
c.bins.length = 0;
a.send(Buffer.from("这看起来像文本，但走的是二进制帧", "utf8"));
await sleep(200);
check(
  b.bins.length === 1 && b.texts.length === 0,
  "二进制帧不会被当成控制消息",
  `二进制 ${b.bins.length} 条 / 文本 ${b.texts.length} 条`
);

// 离开通知只给同房间且订阅过的连接
c.close();
await sleep(250);
check(c.texts.length === cTextsBefore, "别的房间有人离开不会通知本房间");

b.texts.length = 0;
a.close();
await sleep(250);
check(
  b.texts.some((t) => t === "relay:peer-left id=1 room=default peers=1 ids=2"),
  "订阅过的连接收到同事离开通知",
  JSON.stringify(b.texts)
);

b.close();
await sleep(100);
for (const ws of [a, b, c, g, g2]) {
  try {
    ws.close();
  } catch {
    // 已经关了
  }
}
await sleep(200);
server.close();

console.log("");
if (failures.length) {
  console.log(`  ${failures.length} 项失败: ${failures.join(" / ")}`);
  process.exit(1);
}
console.log("  全部通过");
process.exit(0);
