# Stick Skirmish

双人局域网 3D 第三人称射击。目标场景：两台笔记本各占一块全屏，同一网络，浏览器打开就能玩。

## 环境

- Godot `4.7.2-stable`：`D:\Tool\Godot\4.7.2\Godot_v4.7.2-stable_win64.exe`
- 导出模板只装了**网页平台**（`%APPDATA%\Godot\export_templates\4.7.2.stable\`）

## 渲染器

项目锁定 **Compatibility（WebGL 2）**。Godot 4 的网页版不支持 Forward+/Mobile，
所以本地编辑器里看到的画面就是浏览器里能得到的上限，不要往更高画质上调。

## 当前进度

- [x] 项目骨架、网页导出预设
- [x] 对称竞技场（地板 + 掩体 + 边界，由 `scripts/arena.gd` 数据生成）
- [x] 第三人称角色：镜头相对移动、鼠标视角、重力跳跃、SpringArm 镜头避障
- [x] 网页版链路跑通：导出 → 局域网服务 → 浏览器里真的渲染出场景
- [x] 联机传输链路验证：中继双向收发、Godot 高层 API 的广播 `rpc`（见下文「联机」）
- [x] 基础联机同步：各自广播位置与朝向，为其他玩家画替身（能看见对方在动）
- [ ] 射击与命中判定
- [ ] 联机同步的完整化：替身碰撞、插值补偿、断线重连
- [ ] 计分、复活、胜负

## 跑起来

编辑器里按 F5。或命令行：

```powershell
& 'D:\Tool\Godot\4.7.2\Godot_v4.7.2-stable_win64_console.exe' --path 'D:\Datafile\stick-skirmish'
```

## 导出网页版

```powershell
& 'D:\Tool\Godot\4.7.2\Godot_v4.7.2-stable_win64_console.exe' --headless `
  --path 'D:\Datafile\stick-skirmish' --export-release "Web" build/index.html
```

产物在 `build/`。注意：`index.html` 必须用 HTTP 服务打开，直接双击 `file://` 打不开。

## 局域网怎么跑

```powershell
node tools/serve.mjs
```

会同时监听两个端口：HTTP（默认 8000，**只有本机能用**）和 HTTPS（默认 8001，**另一台设备用这个**）。

### 为什么另一台设备必须走 HTTPS

Godot 4 的网页版要求页面处于 **Secure Context**。浏览器只把 `localhost` 和 `https://`
算作安全上下文，**明文 HTTP 的局域网 IP 不算**，引擎会直接拒绝启动并报：

```
Secure Context - Check web server configuration (use HTTPS)
```

这个检查硬编码在 Godot 生成的 loader 里（`build/index.js`），没有开关。
所以 `certs/` 里放了一张自签证书（已 gitignore）。另一台设备第一次打开会看到
「您的连接不是私密连接」，点「高级」→「继续前往 192.168.x.x（不安全）」，之后一切正常。

**证书是自动的**：`serve.mjs` 每次启动都会比对当前局域网 IP，缺了或对不上就自动重签一张，
覆盖本机所有网卡地址。需要 openssl（Git for Windows 自带，脚本会自动去找）。
换了网络（比如去别人家）直接启动即可，不用记命令。

万一自动生成失败，手动命令是（注意 `MSYS_NO_PATHCONV`，否则 MSYS 版 openssl 会把
`/CN=...` 当路径改写）：

```powershell
$env:MSYS_NO_PATHCONV = '1'
& 'C:\Program Files\Git\usr\bin\openssl.exe' req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes `
  -keyout 'certs/lan.key' -out 'certs/lan.crt' -subj '/CN=Stick Skirmish LAN' `
  -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1,IP:<你的局域网IP>'
```

## 联机

两台设备之间**没有「一方开房间、另一方连过去」这个选项**：浏览器不能监听端口，
Godot 网页版同样不能，而 ENet（UDP）在网页版不可用。所以 `tools/serve.mjs` 兼任中继，
两个浏览器都作为客户端连上来，中继把消息转给同房间的其他连接。

中继与网页**共用同一个端口**（`ws://…:8000/ws` 与 `wss://…:8001/ws`），
目的是让自签证书只处理一次。

### 两台设备怎么玩

1. 一台跑 `node tools/serve.mjs`
2. **这台机器**打开 `http://localhost:8000/`（`localhost` 也算安全上下文，没有证书提示）
3. **另一台**打开 `https://<本机局域网IP>:8001/`（会提示证书，点「高级」→「继续前往」）
4. 两台都**左键点一下画面**（全屏 + 接管鼠标），就能看见对方的胶囊了

两边网址不带参数就都进 `game` 房间。要分开测试时用 `?room=xxx`，**房间名必须一致**。
画面左上角会显示 `room=game  me=<编号>  connected  others=[<编号>]`。

同步由 `scripts/net.gd` 负责：每个客户端以 20 Hz 广播自己的位置与朝向，
替身做位置平滑。当前只同步位置与朝向——替身没有碰撞、没有射击、没有血量。

### 踩过的坑：握手超时只有 3 秒

`WebSocketMultiplayerPeer` 的 `handshake_timeout` 默认 **3 秒**，而且它**从创建客户端的那一刻就开始计时**，
不是从连接建立开始。如果首帧渲染耗时超过 3 秒（软件渲染、低端设备、冷启动都会），
第一次 `poll()` 时超时已过，Godot 就判定握手失败并放弃连接：

- `poll()` 一旦看到 `CONNECTION_DISCONNECTED` 就**直接返回**（`websocket_multiplayer_peer.cpp` 的 `poll()`），
  所以即使底层 WebSocket 随后真的进入了 `OPEN`，也不会有任何东西再去读它
- `_clear()` 只把 `peers_map` 置空、**不关闭底层 socket**，也不重置 `handshake_timeout`
- 症状：连上后立刻“断开”，`get_connection_status()` 是 `disconnected`，
  而内层 `WebSocketPeer` 却是 `OPEN`、关闭码为 `-1`，没有任何错误信息

`net.gd` 因此把 `handshake_timeout` 设为 **20 秒**。

### 中继约定

| 项目 | 约定 |
| --- | --- |
| 房间 | 由路径决定：`/ws` 是默认房间，`/ws/<名字>` 是独立房间，房间之间不转发 |
| 编号 | 全局递增，从 1 开始。哪个是房主由游戏按编号判断，中继不参与 |
| 控制消息 | 文本帧，以 `relay:` 开头，**只在客户端请求之后才发出** |
| 游戏数据 | 一律用二进制帧，原样转发 |
| `?as=godot` | 该连接可以运行 Godot 的 `WebSocketMultiplayerPeer` |

请求房间信息：发出 `relay:whoami`，得到 `relay:hello id=<编号> room=<房间> peers=<人数> ids=<全部编号>`。
需要离开通知：发出 `relay:subscribe`，之后同房间有人离开会收到 `relay:peer-left …`。

### 高层联机 API 的实测结论

`?as=godot` 让中继在握手之后先发出一个 4 字节小端 int32（自身编号，且 ≥ 2）。
Godot 的客户端要求第一个包就是这个内容，否则主动断开并报 `Invalid ID received from server`
（见 `modules/websocket/websocket_multiplayer_peer.cpp` 的 `_poll_client`）。

启用之后 `MultiplayerAPI` 能进入已连接状态，**广播式 `rpc()` 双向可用**（实测无重复、无丢失）。
但是 Godot 把收到的每个包都标记为「来自 1 号」，也就是发送方身份无法获知。因此：

- `rpc()`（广播）可用；需要区分发送者时，把自身编号写在参数里
- `rpc_id()` 定向到某个玩家不可用
- 按 peer 的可见性（`MultiplayerSynchronizer`）不可用，状态同步需要自己写

### 验证

```powershell
node tools/relay-selftest.mjs                         # 中继单测，16 项
node tools/net-probe-check.mjs https://127.0.0.1:8001 # 传输层探针（两个无头 Chrome）
node tools/net-probe-check.mjs https://127.0.0.1:8001 --room  # 两个客户端能否看见对方
```

探针在 `scripts/net_probe.gd`（autoload `NetProbe`），只有网址带 `?probe=1` 时才启用，
结果同时打印到控制台并写入 `window.__netprobe`。

手动验证（两台设备）：这台打开 `https://<本机IP>:8001/index.html?probe=1&name=host`，
另一台打开 `https://<本机IP>:8001/index.html?probe=1&name=guest`，两边控制台都会输出 `[netprobe] …`。

### 本次验证没有覆盖的部分

- 无头 Chrome 用 `--ignore-certificate-errors` 绕过了证书提示，因此**真实浏览器里点过
  「继续前往」之后 `wss://<IP>:8001` 是否同样被授权还没有实测**（那个提示无法自动点击）
- 两台真实设备之间的延迟与丢包没有测，全部数据来自同一台机器的 `127.0.0.1`

## 全屏与鼠标锁定

Godot 默认生成的 HTML 外壳**没有任何全屏能力**，所以要自己加。相关代码在
`export_presets.cfg` 的 `html/head_include` 里——一段注入到 `<head>` 的小脚本。

实际行为：

- **点击画面** → 自动进入全屏，同时锁定鼠标（一次点击办完两件事，因为点击本身就是浏览器要求的"用户手势"）
- **按 Esc** → 释放鼠标并退出全屏
- Esc 之后**再点一下画面**，又回到全屏 + 锁定，可以反复

**退出全屏是浏览器自己做的，项目里没有相关代码。**
曾经写过一条 `pointerlockchange` 联动（丢指针锁就主动退出全屏），后来验证发现纯属多余——
用 CDP 把 `document.exitFullscreen` 换成空操作再按 Esc，全屏照样会退，说明浏览器原生就会处理。
既然多余，就删掉了：它多出来的那一次主动退出，反而可能在指针锁释放的同一瞬间干扰光标位置。

### 锁指针为什么不放在 GDScript 里

网页上"锁定鼠标"这一步交给注入脚本做，`player.gd` 里对 web 平台刻意不动 `mouse_mode`。

浏览器要求 `requestFullscreen()` 和 `requestPointerLock()` 都必须在用户手势里发出，
而两者**同时发出会打架**：全屏切换过程中发出的锁定请求偶尔被拒，
表现就是"点一下，全屏进去了但鼠标还显示着，得再点一次才能操作"。
实测这个竞态可以复现：同样的 点→Esc→点 序列，有时成功有时失败。

改法是让脚本把两件事串起来：先请求全屏 → 等 `fullscreenchange` → 再锁指针，并带两次重试。
Godot 会自己跟随浏览器真实的指针锁状态（实测：脚本主动锁定后，角色按键立刻可操作），
所以引擎不需要再发一次请求。

### F11 和这条路径是两回事

F11 是**浏览器自己的**快捷键，任何网页都能用，项目里没有任何相关代码。区别在于：

| | F11（浏览器全屏） | 点击画面（Fullscreen API） |
| --- | --- | --- |
| `document.fullscreenElement` | 保持 null | 被设成根元素 |
| 触发上面那条指针锁联动 | 不触发 | 触发 |
| 谁发起 | 用户按键，浏览器处理 | 页面在用户手势里请求 |

所以用 F11 进的全屏，Esc 退出靠的是浏览器自身行为，不经过我们的联动。
正常玩就走"点画面"这条路径，全屏和鼠标锁定是一起给的。

### 如果鼠标被困在屏幕角落动不了

跑 `tools/free-cursor.ps1`。

这是 Windows 的 `ClipCursor`（鼠标裁剪）被"孤儿化"了：浏览器进入指针锁定时会把光标圈在窗口内，
如果那个进程异常退出、没来得及还原，限制就留在系统里。症状是光标被锁在某个小矩形里，
而且**找遍所有窗口都找不到尺寸吻合的那个**——因为设限制的窗口早关了。

急用的话也可以按 **Ctrl+Alt+Del**（那个界面会强制解除系统层面的捕获），再按 Esc 退出。

## 操作

| 操作 | 键位 |
| --- | --- |
| 全屏 + 锁定鼠标 | 点击画面 |
| 释放鼠标 + 退出全屏 | Esc |
| 移动 | W A S D / 方向键 |
| 跳跃 | 空格 |
| 视角 | 鼠标 |

**键盘只在鼠标被锁定（也就是"正在操作游戏"）时才生效。** 光标还露在外面时按 W 不会让角色移动。
判定标准是 `Input.mouse_mode == MOUSE_MODE_CAPTURED`，见 `player.gd` 的 `_input_active`。

进入游戏的方式只有一种：**左键点击画面**。
注意滚轮不算——Godot 里滚轮也是 `InputEventMouseButton`（`button_index` 为 4/5）且 `pressed` 为 true，
如果不校验按键类型，滚一下滚轮就会把游戏激活。

同理，切走标签页时 `keyup` 收不到，按键会卡在"按下"状态；`_notification()` 里监听
`NOTIFICATION_APPLICATION_FOCUS_OUT` 主动清掉按键并停下角色，否则切回来一点画面角色就自己走了。

## 已知坑

- **本项目所在的这台机器 `github.com:443` 不通**（DNS 正常，API 与 CDN 通）。
  编辑器里「管理导出模板」的自动下载会失败，需要走 `api.github.com/repos/.../releases/assets/<id>` 取 302 再抓。
- 网页导出用单线程模式（`variant/thread_support=false`），因此不需要 COOP/COEP 跨域隔离响应头。
- **`CollisionShape3D` 必须是 `CollisionObject3D` 的直接子节点。** 中间夹一层 `Node3D` 时物理引擎不报错、
  但完全不注册该形状——表现是角色穿过地板一直往下掉。`arena.gd` 里因此把网格和碰撞形状都直接挂在
  `StaticBody3D` 下。
- **浏览器不允许程序主动抢鼠标锁定。** `_ready()` 里设 `Input.mouse_mode = MOUSE_MODE_CAPTURED`
  会抛 `WrongDocumentError`，必须等玩家第一次点击（见 `player.gd` 的 `_unhandled_input`）。
- 导出前记得 `build/` 目录要存在，Godot 不会自动创建。
- **另一台设备必须用 HTTPS 打开**，明文 HTTP 的局域网地址会报 Secure Context 错误（见上）。
- **无头浏览器里指针锁会失败**，报 `WrongDocumentError: The root document ... not valid for pointer lock`。
  原因是无头模式默认不给页面前台焦点。用 CDP 测试时先发一次 `Page.bringToFront`、
  确认 `document.hasFocus()` 为 true，指针锁就正常了。真浏览器里不存在这个问题。
- **打包体积卡住了 Cloudflare 这条路**：Pages 和 Workers 静态资源的单文件上限都是
  **25 MiB**，而 `index.wasm` 有 **37.7 MiB**，直接超限。官方建议改用 R2 桶，
  或者把 wasm 预先 gzip 成 9.7 MB 再让 Worker 补 `Content-Encoding: gzip` 头。
  再加上 `github.com` 不通、`*.workers.dev` 在国内可达性不确定，本次没有走云部署。
