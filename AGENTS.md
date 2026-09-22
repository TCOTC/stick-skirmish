# Stick Skirmish —— 给 AI 协作者的项目上下文

双人局域网 3D 第三人称射击。两台笔记本、同一个 wifi、浏览器打开就能玩。
目标是"临时做点好玩的东西带去做客时玩"，所以**能跑通 > 做完整**。

## 位置与版本

- 项目：`D:\Datafile\stick-skirmish`（显示名 `Stick Skirmish`）
- Godot：`D:\Tool\Godot\4.7.2\Godot_v4.7.2-stable_win64_console.exe`
- 导出模板：**只装了网页平台**（`%APPDATA%\Godot\export_templates\4.7.2.stable\`）。
  想导出 Windows 版得另外补 `windows_release_x86_64.exe` 等文件。

## 五条硬约束（不知道会白干半天）

1. **渲染器必须是 Compatibility（WebGL 2）。** Godot 4 的网页版不支持 Forward+/Mobile，
   编辑器里看到的画面就是上限，不要往更高画质调。
2. **网页版要求 Secure Context。** 浏览器只认 `localhost` 和 `https://`，
   明文 HTTP 的局域网 IP 会被引擎直接拒绝，报 `Secure Context ... (use HTTPS)`。
   这个检查硬编码在 Godot 生成的 loader 里，没有开关。所以 `tools/serve.mjs` 必须开 HTTPS。
3. **Cloudflare 部署不了**：Pages 和 Workers 静态资源的单文件上限都是 25 MiB，
   而 `index.wasm` 有 37.7 MiB。要上云得先开 R2 桶，或把 wasm 预压后让 Worker 补
   `Content-Encoding: gzip`。
4. **这台机器 `github.com:443` 不通**（DNS 正常，`api.github.com` 和
   `objects.githubusercontent.com` 通）。编辑器里「管理导出模板」的自动下载必然失败。
   抓 GitHub release 文件走 `api.github.com/repos/<owner>/<repo>/releases/assets/<id>`
   加 `Accept: application/octet-stream`，让 curl 跟着 302 去 CDN。

5. **联机只能走 `tools/serve.mjs` 的中继。** 浏览器不能监听端口（Godot 网页版也不能），
   ENet（UDP）在网页版不可用，所以「一方开房间、另一方连过去」这个结构不成立。
   中继与网页**共用端口**（`ws://…:8000/ws`、`wss://…:8001/ws`）和同一张自签证书。
   另外：Godot 高层联机 API 需要服务端先发一个 4 字节编号才肯进入已连接状态（详见 README 的「联机」）。

## 日常命令

无头跑一遍看有没有脚本/配置错误：

```powershell
& 'D:\Tool\Godot\4.7.2\Godot_v4.7.2-stable_win64_console.exe' --headless `
  --path 'D:\Datafile\stick-skirmish' --quit-after 60
```

导出网页版（**`build/` 目录必须先存在**，Godot 不会自动创建）：

```powershell
& 'D:\Tool\Godot\4.7.2\Godot_v4.7.2-stable_win64_console.exe' --headless `
  --path 'D:\Datafile\stick-skirmish' --export-release 'Web' 'build/index.html'
```

起局域网服务（HTTP 8000 仅本机 / HTTPS 8001 给另一台设备；证书按当前局域网 IP 自动重签）：

```powershell
node tools/serve.mjs
```

联机自测（中继单测；探针需要服务已在运行）：

```powershell
node tools/relay-selftest.mjs
node tools/net-probe-check.mjs https://127.0.0.1:8001
```

## 验证手段

**AI 看不到画面**（不支持图像输入），"好不好看"必须由人判断。但结构和行为可以自动验证：

- 无头跑一遍查错
- 用 CDP 驱动真实 Chrome：注入脚本、派发**真实**鼠标键盘事件、截图、读 DOM
- **像素比对**判断"角色动没动"：同场景两帧平均差 `0.00/765` = 完全没动，
  `5~6/765` = 确实移动了。这个判据在本项目里反复用过，比"看起来对"可靠得多

CDP 测试的两个坑：

- 无头 Chrome 默认不给页面前台焦点 → 指针锁会失败并报
  `WrongDocumentError: The root document ... not valid for pointer lock`。
  先发 `Page.bringToFront`，确认 `document.hasFocus()` 为 true。
- **测完一定要调 `ClipCursor(NULL)` 解除鼠标裁剪。** 浏览器进入指针锁定时会把光标圈在窗口内，
  进程异常退出会留下孤儿限制，症状是"鼠标被困在屏幕左上角动不了"。
  `tools/free-cursor.ps1` 专门干这个，别忘了。

## 已经踩过并修好的坑（别踩第二遍）

- **`CollisionShape3D` 必须是 `CollisionObject3D` 的直接子节点。** 中间夹一层 `Node3D`
  不报任何错，但形状根本不注册——表现是角色穿过地板以 24m/s² 一直往下掉。
- **浏览器不允许程序主动抢鼠标锁定。** `_ready()` 里设 `MOUSE_MODE_CAPTURED` 会抛
  `WrongDocumentError`，必须等用户手势。
- **pointer lock 必须串在 fullscreen 之后。** 两者在同一次点击里并发发出，偶尔被拒，
  表现是"全屏进去了但鼠标还显示着，得再点一次"。现在由注入脚本负责
  "先请求全屏 → 等 `fullscreenchange` → 再锁 + 两次重试"，Godot 会自动跟随浏览器真实的
  锁定状态，所以 `player.gd` 对 web 平台**刻意不动** `mouse_mode`（桌面端照旧由引擎锁）。
- **滚轮也是 `InputEventMouseButton`**（`button_index` 是 4/5）且 `pressed` 为 true。
  判断"用户要开始玩"必须校验 `button_index == MOUSE_BUTTON_LEFT`，否则滚一下滚轮就进游戏。
- **键盘只在鼠标锁定时生效**，判据是 `Input.mouse_mode == MOUSE_MODE_CAPTURED`。
  另外切标签页会丢 `keyup` 让按键卡住，`_notification()` 里监听
  `NOTIFICATION_APPLICATION_FOCUS_OUT` 主动清。
- **退出全屏是浏览器原生行为**，不要重复实现（曾经写过 `pointerlockchange → exitFullscreen`，
  验证后发现纯属多余，已删）。
- **这台机器的 PowerShell 5.1 按 ANSI 读 `.ps1`**，带中文的脚本必须存成 UTF-8 **带 BOM**，
  否则直接语法崩溃。
- **Godot 的 WebSocket 客户端要求第一个包是 4 字节编号**：内容是小端 int32 的自身编号且 ≥ 2，
  否则主动断开并报 `Invalid ID received from server`。另外它把收到的每个包都标记为来自 1 号，
  发送方身份因此无法获知，影响 `rpc_id` 定向与 `MultiplayerSynchronizer` 的 peer 可见性。
- **`WebSocketMultiplayerPeer` 的握手超时只有 3 秒，且从创建客户端就开始计时。**
  首帧渲染超过 3 秒（软件渲染、冷启动）时，第一次 `poll()` 已超时 → 判定失败并放弃连接。
  此时 `poll()` 会因已断开而**永远直接返回**，底层 socket 却还是 `OPEN`、关闭码 `-1`、没有报错；
  `_clear()` 也不关闭 socket、不重置超时。`scripts/net.gd` 因此设为 20 秒。
- **导出预设是 `all_resources`，会把 `certs/lan.key` 打进 `index.pck`**，随页面发给局域网内任何人；
  `build/` 里的 `.import` 也会被扫描。需要加 `exclude_filter`，或在 `build/` 放一个 `.gdignore`。

## 人机分工

AI 能做（不用打开编辑器）：改 GDScript、改 `.tscn`、导出网页版、无头查错、
CDP 驱动真浏览器验证、像素比对。

AI 做不了：**判断好不好看**（看不到画面）、**判断手感**（没有手）、
编辑器里点按钮的步骤（装模板、InputMap 图形界面）没有命令行等价物。

正常节奏：AI 改 + 导出 + 自动化验证 → 人玩一遍说"哪里不对劲" → 回到第一步。

## 当前进度

已完成：

- 项目骨架、Compatibility 渲染器、网页导出预设
- 对称竞技场（地板 + 13 个掩体 + 四周边界，由 `scripts/arena.gd` 数据生成）
- 第三人称角色（`scripts/player.gd`）：镜头相对移动、鼠标视角、重力跳跃、SpringArm 镜头避障
- 网页导出 → 局域网 HTTPS 服务 → 浏览器里真实渲染出场景，整条链路验证通过
- 全屏与鼠标锁定：左键点击画面 = 全屏 + 接管鼠标；Esc = 释放鼠标 + 退全屏
- 联机传输：`tools/ws-relay.mjs`（零依赖中继，16 项单测）+ 两个无头浏览器实测；
  裸 `WebSocketPeer` 与 Godot 高层 `rpc()` 都双向可用（见 README「联机」）
- 基础联机同步：`scripts/net.gd` 各客户端以 20 Hz 广播位置与朝向，为其他玩家画替身
  （两个无头客户端已互相看见）

未完成（下一步按此顺序）：

- [ ] 射击：枪口、子弹、命中判定、掉血
- [ ] 联机同步的完整化：替身碰撞、插值补偿、断线重连
- [ ] 计分、复活、胜负

注：`dash`（Shift）目前只注册了按键，没有实现行为。
