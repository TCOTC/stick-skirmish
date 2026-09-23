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

火柴人的骨骼与步态自检（不联网，直接读骨骼角度）：

```powershell
& 'D:\Tool\Godot\4.7.2\Godot_v4.7.2-stable_win64_console.exe' --headless `
  --path 'D:\Datafile\stick-skirmish' --script res://tools/stick-check.gd
```

给网页版截图（需要服务已在运行；直接给出 PNG 路径就能看图）：

```powershell
node tools/shot.mjs                                              # 整屏 + 中央放大（写到系统临时目录）
node tools/shot.mjs https://127.0.0.1:8001 $env:TEMP\a.png --stat     # 同时输出游戏状态
node tools/shot.mjs https://127.0.0.1:8001 $env:TEMP\w.png --key w --center 150,230,30   # 按住 W 拍走路姿态
```

输出路径**不要写进项目目录**（会被 Godot 当资源导出，见下方“已经踩过的坑”）。

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
node tools/net-probe-check.mjs https://127.0.0.1:8001 --room
node tools/net-probe-check.mjs https://127.0.0.1:8001 --walk
```

## 验证手段

**AI 能看画面**：`node tools/shot.mjs` 会驱动无头 Chrome 打开网页版并截图，
返回的 PNG 可以直接看图（曾经以为不支持图像输入，结果把一个“角色只剩头和躯干”的
明显缺陷推给了人去看）。截图工具支持 `--clip x,y,w,h`、`--zoom`、`--key w`（按住键拍走路姿态）。

除图像之外，结构与行为都能自动验证：

- 无头跑一遍查错
- 用 CDP 驱动真实 Chrome：注入脚本、派发**真实**鼠标键盘事件、截图、读 DOM
- 读骨骼 / 节点的**数值**：如 `tools/stick-check.gd` 直接读骨骼 pose，判断关节有没有在动
- **像素比对**判断“角色动没动”：同场景两帧平均差 `0.00/765` = 完全没动，
  `5~6/765` = 确实移动了。这个判据在本项目里反复用过，比“看起来对”可靠得多

CDP 测试的两个坑：

- 无头 Chrome 默认不给页面前台焦点 → 指针锁会失败并报
  `WrongDocumentError: The root document ... not valid for pointer lock`。
  先发 `Page.bringToFront`，确认 `document.hasFocus()` 为 true。
- **测完一定要解除鼠标裁剪（`ClipCursor`）。** 浏览器进入指针锁定时会把光标圈在窗口内，
  进程被强杀时来不及还原，限制就留在系统里，症状是"鼠标被困在屏幕左上角动不了"。
  现在由 `tools/net-probe-check.mjs` 自动收尾（先 `exitPointerLock` → 优雅关闭页面 →
  兜底跑 `free-cursor.ps1`），所以用它跑测试不需要手动处理。
  但**用别的方式驱动浏览器时仍需手动跑 `tools/free-cursor.ps1`**。
  注意：强杀（`taskkill /F`）会跳过浏览器的窗口销毁流程，而还原就发生在那里，
  所以收尾要先让页面自己关。

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
- **headless 与 `--script` 模式不写 `.godot` 里的全局类缓存**，因此在那两种模式下直接用
  `class_name`（如 `StickFigure`）会报 `Could not find type`。要用 `preload(...)` 引用。
- **`--script` 运行的脚本里，函数返回值赋给 `:=` 变量会推断失败**（因为类型是 Variant），
  需要写显式类型注解，否则报 `Cannot infer the type of ...`。
- **导出预设是 `all_resources`，会把项目里的一切都打进 `index.pck`**，并随页面发给局域网内任何人
  （曾经连 `certs/lan.key` 私钥一起发）。现在 `export_presets.cfg` 里有
  `exclude_filter="certs/*, tools/*"` 把它们排掉了，加新目录时记得同步。
  另外：**不要往项目目录里写截图或其它图片**——Godot 会把它们导成资源并打进包，
  实测多几张 PNG 就让 `index.pck` 从 59 KB 涨到 84 KB。`tools/shot.mjs` 默认写到系统临时目录。
- **`Skeleton3D` 的 rest 与 pose 是两回事。** `add_bone()` 把两者都设成单位矩阵，
  `set_bone_rest()` 只改 rest；而 `BoneAttachment3D` 跟随的是 **pose**（`get_bone_global_pose()`）。
  只设 rest 的话所有骨头都堆在骨骼原点，角色缩成一团——曾表现为“头在 1.04 米、脚在 0.70 米”，
  画面上只剩一个头和一根竖线，而骨骼数量、网格数量、关节角度全都“正常”。建骨时 pose 要一并设。
- **`BoneAttachment3D` 要在入树之后再设 `bone_name`。** 反过来写（先设名再 `add_child`）
  在当前帧 `get_bone_idx()` 仍是 -1，要跑过一帧才解析出来。运行时看不出差别，
  但无头自检里会得到一个假的“未绑定”报告，容易误判。
- **`--script` 运行的脚本里，`_initialize()` 阶段读 `BoneAttachment3D.get_bone_idx()` 一定是 -1**
  （解析发生在帧内的内部处理）。自检要放到 `_process()` 的第一帧之后跑，见 `stick-check.gd`。
- **同一根骨头只留一个 `BoneAttachment3D`。** 每个网格各建一个附件时，同一骨骼的多个附件
  会在按骨骼统计网格时彼此覆盖（自检会误报“缺件”），节点数也平白翻倍。见 `stick_figure._attach()`。
- **火柴人的 Y 方向约定：躯干从骨盆向上长，四肢从骨骼原点向下垂。**
  偏移符号写反不报错，只是那一段挂到身体外面去——实测把胸前横带的偏移写成负值，
  它就横架到两条大腿上了。所以自检里有一项用外包围盒验证部件两两相交。
- **点击画面会触发全屏，视口尺寸随之改变**（无头实测 1258x566 → 800x544），
  写死的截图裁剪坐标会捕空。要按当前视口算，或直接用 `shot.mjs --center`。
- **HUD 准星就在画面正中央**，截图放大时它会压在角色躯干上，看起来像角色身上的一个青色方块
  （色值 `0.23,0.88,1`）。别把它当成模型缺陷去查。

## 人机分工

AI 能做（不用打开编辑器）：改 GDScript、改 `.tscn`、导出网页版、无头查错、
CDP 驱动真浏览器验证、截图看图、像素比对、读骨骼角度。

AI 做不了：**判断手感**（没有手）、**判断“这个数值好不好玩”**（射速、跳跃高度这类偏好的事）、
编辑器里点按钮的步骤（装模板、InputMap 图形界面）没有命令行等价物。

正常节奏：AI 改 + 导出 + 自动化验证 + 自己先看一遍截图 → 人玩一遍说"哪里不对劲" → 回到第一步。

## 当前进度

已完成：

- 项目骨架、Compatibility 渲染器、网页导出预设
- 对称竞技场（地板 + 13 个掩体 + 四周边界，由 `scripts/arena.gd` 数据生成）
- 第三人称角色（`scripts/player.gd`）：镜头相对移动、鼠标视角、重力跳跃、SpringArm 镜头避障
- 火柴人角色（`scripts/stick_figure.gd`）：Skeleton3D 骨骼绑定，走路 / 跳跃 / 站立的程序化步态，
  两套样式按进入房间的顺序分配
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
