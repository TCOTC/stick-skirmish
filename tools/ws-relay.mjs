/**
 * 零依赖的 WebSocket 中继。
 *
 * 为什么需要它：游戏跑在浏览器里，浏览器不能监听端口，Godot 网页版因此没法"一方开房间、
 * 另一方连过去"；ENet 走 UDP，网页版同样没有。所以让本来就在跑的 tools/serve.mjs 兼职转发：
 * 两个浏览器都作为客户端连上来，中继把任何一方的消息转给其他人。
 *
 * 它不认识游戏协议，只做转发，而且**不会主动发任何帧**（被动客户端不会被无关数据打扰，
 * 这一条是实测出来的：Godot 的 WebSocketMultiplayerPeer 就是被中继主动发的帧搞断的）。
 * 想要房间信息就自己发一条文本控制消息：
 *   relay:whoami     → 回 relay:hello id=<本连接编号> room=<房间> peers=<房间内连接数> ids=<房间内全部编号>
 *   relay:subscribe  → 回 relay:subscribed ...，之后房间内有人离开会收到 relay:peer-left ...
 *
 * 房间由路径决定：/ws 是默认房间，/ws/<名字> 是独立房间，各自互不干扰。
 * 编号从 1 开始全局递增（不按房间重置），"编号最小的是房主"这类选主逻辑由游戏自己判断；
 * 房主离开后剩下的客户端要自己顶上，中继只负责通知。
 *
 * 另外支持 URL 参数 ?as=godot，让这个连接能直接跑 Godot 的 WebSocketMultiplayerPeer：
 * Godot 的客户端在连上后**必须**先收到一个 4 字节小端 int32（自身编号，且 ≥ 2），
 * 否则会 peer->close() 并报 "Invalid ID received from server"（见 Godot 源码
 * modules/websocket/websocket_multiplayer_peer.cpp 的 _poll_client）。
 * 但它同时把所有收到的包都标成来自 1 号（即服务端），发送方身份因此丢失；
 * 所以这个模式只适合广播式 rpc()，要区分谁发的就自己在参数里带上编号。
 *
 * 约定：控制消息是文本帧且以 relay: 开头，因此**游戏数据一律用二进制帧**，
 * 两者不会混淆（二进制帧原样转发，不做任何检查）。
 */
import crypto from "node:crypto";

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

// 转发的是位置、开枪这类小消息，1 MiB 足够；超过就断开，避免被单个连接拖死。
const MAX_PAYLOAD = 1 << 20;
// socket 写缓冲积压到 4 MiB 说明对端读得太慢，再丢消息没有意义。
const MAX_BUFFERED = 4 << 20;

const OP_CONT = 0x0;
const OP_TEXT = 0x1;
const OP_BINARY = 0x2;
const OP_CLOSE = 0x8;
const OP_PING = 0x9;
const OP_PONG = 0xa;

/** 服务端发出的帧不加掩码（RFC 6455 要求）。 */
function encodeFrame(opcode, payload) {
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.alloc(2);
    header[1] = len;
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  header[0] = 0x80 | opcode;
  return Buffer.concat([header, payload]);
}

/**
 * 把中继挂到 HTTP / HTTPS 服务上。
 * @param {import('node:http').Server | import('node:http').Server[]} servers
 * @param {{log?: (msg: string) => void}} [options]
 */
export function attachWebSocketRelay(servers, { log = () => {} } = {}) {
  const list = Array.isArray(servers) ? servers : [servers];
  /** 房间名 -> 连接集合 @type {Map<string, Set<object>>} */
  const rooms = new Map();
  let nextId = 1;

  const peersIn = (room) => rooms.get(room) ?? new Set();
  const roster = (room) => [...peersIn(room)].map((p) => p.id);

  function write(peer, opcode, payload) {
    if (peer.socket.destroyed || !peer.socket.writable) return;
    if (peer.socket.writableLength > MAX_BUFFERED) {
      log(`  [ws] #${peer.id} 积压 ${peer.socket.writableLength} 字节，丢弃本条`);
      return;
    }
    peer.socket.write(encodeFrame(opcode, payload));
  }

  function sendControl(peer, text) {
    write(peer, OP_TEXT, Buffer.from(text, "utf8"));
  }

  /** 只在本房间内转发，不跨房间。 */
  function broadcast(from, opcode, payload) {
    for (const peer of peersIn(from.room)) {
      if (peer !== from) write(peer, opcode, payload);
    }
  }

  function drop(peer, why) {
    const peers = peersIn(peer.room);
    if (!peers.delete(peer)) return;
    log(`  [ws] -#${peer.id} ${why}（房间 ${peer.room} 剩 ${peers.size}）`);
    for (const other of peers) {
      if (!other.subscribed) continue;
      sendControl(other, `relay:peer-left id=${peer.id} room=${peer.room} peers=${peers.size} ids=${roster(peer.room).join(",")}`);
    }
  }

  /** 处理一个完整的数据帧。控制帧在 feed() 里就消化掉了，这里只会收到文本/二进制数据帧。 */
  function onMessage(peer, opcode, payload) {
    if (opcode === OP_TEXT) {
      const text = payload.toString("utf8");
      if (text === "relay:whoami") {
        const peers = peersIn(peer.room);
        sendControl(peer, `relay:hello id=${peer.id} room=${peer.room} peers=${peers.size} ids=${roster(peer.room).join(",")}`);
        return;
      }
      if (text === "relay:subscribe") {
        peer.subscribed = true;
        const peers = peersIn(peer.room);
        sendControl(peer, `relay:subscribed id=${peer.id} room=${peer.room} peers=${peers.size}`);
        return;
      }
    }
    broadcast(peer, opcode, payload);
  }

  /** 按需增量解析，帧被 TCP 拆开或粘在一起都能正确处理。 */
  function feed(peer, chunk) {
    peer.buffer = peer.buffer.length ? Buffer.concat([peer.buffer, chunk]) : chunk;

    for (;;) {
      const buf = peer.buffer;
      if (buf.length < 2) return;

      const fin = (buf[0] & 0x80) !== 0;
      const opcode = buf[0] & 0x0f;
      const masked = (buf[1] & 0x80) !== 0; // 客户端发来的帧必须带掩码
      let len = buf[1] & 0x7f;
      let off = 2;

      if (len === 126) {
        if (buf.length < off + 2) return;
        len = buf.readUInt16BE(off);
        off += 2;
      } else if (len === 127) {
        if (buf.length < off + 8) return;
        const big = buf.readBigUInt64BE(off);
        off += 8;
        if (big > BigInt(MAX_PAYLOAD)) {
          peer.socket.destroy();
          drop(peer, "消息过大");
          return;
        }
        len = Number(big);
      }

      if (len > MAX_PAYLOAD) {
        peer.socket.destroy();
        drop(peer, "消息过大");
        return;
      }

      let mask = null;
      if (masked) {
        if (buf.length < off + 4) return;
        mask = buf.subarray(off, off + 4);
        off += 4;
      }

      if (buf.length < off + len) return;

      const payload = Buffer.from(buf.subarray(off, off + len));
      peer.buffer = buf.subarray(off + len);
      if (mask) {
        for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
      }

      if (opcode === OP_PING) {
        write(peer, OP_PONG, payload);
        continue;
      }
      if (opcode === OP_PONG) continue;
      if (opcode === OP_CLOSE) {
        write(peer, OP_CLOSE, payload.subarray(0, 2));
        peer.socket.end();
        drop(peer, "对方关闭");
        return;
      }

      // 分片消息：攒到 FIN 再转发。转发时合成单帧，游戏端不用自己拼。
      if (opcode === OP_CONT) {
        if (peer.fragmentOpcode === null) continue; // 没有开头的续帧，忽略
        peer.fragment.push(payload);
      } else {
        if (peer.fragmentOpcode !== null) peer.fragment.length = 0; // 上一段没收全，丢弃
        peer.fragmentOpcode = opcode;
        peer.fragment = [payload];
      }

      if (!fin) continue;

      const op = peer.fragmentOpcode;
      const full = Buffer.concat(peer.fragment);
      peer.fragmentOpcode = null;
      peer.fragment = [];
      if (full.length > MAX_PAYLOAD) {
        peer.socket.destroy();
        drop(peer, "分片消息过大");
        return;
      }
      onMessage(peer, op, full);
    }
  }

  function onUpgrade(req, socket, head) {
    const upgrade = String(req.headers.upgrade ?? "").toLowerCase();
    const key = req.headers["sec-websocket-key"];
    const url = new URL(req.url ?? "/", "http://relay");
    const path = url.pathname;
    const room = path === "/ws" || path === "/ws/" ? "default" : path.startsWith("/ws/") ? path.slice(4) : null;

    if (upgrade !== "websocket" || room === null || !key || room.length > 64) {
      socket.write("HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
    if (String(req.headers["sec-websocket-version"] ?? "") !== "13") {
      socket.write("HTTP/1.1 426 Upgrade Required\r\nSec-WebSocket-Version: 13\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }

    const accept = crypto.createHash("sha1").update(key + GUID).digest("base64");
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        `Sec-WebSocket-Accept: ${accept}\r\n\r\n`
    );

    // 小消息延迟敏感，关掉 Nagle。
    socket.setNoDelay(true);
    socket.setTimeout(0);

    const peer = {
      id: nextId++,
      room,
      godotFacade: url.searchParams.get("as") === "godot",
      subscribed: false,
      socket,
      buffer: Buffer.alloc(0),
      fragment: [],
      fragmentOpcode: null,
    };
    if (!rooms.has(room)) rooms.set(room, new Set());
    rooms.get(room).add(peer);
    log(`  [ws] +#${peer.id} 连接（房间 ${room} 共 ${peersIn(room).size}${peer.godotFacade ? "，Godot 伪装" : ""}）`);

    // Godot 客户端在等这个 4 字节编号，必须紧跟握手发出。（编号从 2 开始，1 号留给"服务端"）
    if (peer.godotFacade) {
      const idFrame = Buffer.alloc(4);
      idFrame.writeInt32LE(peer.id + 1, 0);
      write(peer, OP_BINARY, idFrame);
    }

    socket.on("data", (chunk) => {
      try {
        feed(peer, chunk);
      } catch (err) {
        log(`  [ws] #${peer.id} 解析出错: ${err.message}`);
        socket.destroy();
        drop(peer, "解析出错");
      }
    });
    socket.on("error", (err) => {
      log(`  [ws] #${peer.id} socket 错误: ${err.message}`);
      drop(peer, "socket 错误");
    });
    socket.on("close", () => drop(peer, "连接关闭"));
    socket.on("end", () => drop(peer, "对端结束"));

    if (head && head.length) feed(peer, head);
  }

  for (const server of list) server.on("upgrade", onUpgrade);

  return {
    count() {
      let total = 0;
      for (const peers of rooms.values()) total += peers.size;
      return total;
    },
    closeAll() {
      for (const peers of rooms.values()) {
        for (const peer of peers) peer.socket.destroy();
        peers.clear();
      }
    },
  };
}
