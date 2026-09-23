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

音效自检（合成结果与播放器生命周期，无头环境听不到声音）：

```powershell
& 'D:\Tool\Godot\4.7.2\Godot_v4.7.2-stable_win64_console.exe' --headless `
  --path 'D:\Datafile\stick-skirmish' --script res://tools/sfx-check.gd
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
node tools/net-probe-check.mjs https://127.0.0.1:8001 --shoot
node tools/net-probe-check.mjs https://127.0.0.1:8001 --score   # 记分/判胜负/下一回合（?kills=1）
```

`NET_SHOT_DIR=<目录>` 会把每个实例的画面存下来（含开火中整屏 + 准星放大），
用于人眼核对特效、血条、枪这类只能看的东西。

验证“后加入”场景（第二个人晚一点才进房间）：

```powershell
$env:TEST_JOIN_DELAY_MS='20000'; $env:TEST_ROOM='latejoin';
node tools/net-probe-check.mjs https://127.0.0.1:8001 --room
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
- **重建外观时不要遍历子节点全删。** 联机侧在角色节点上挂了命中框与头顶血条，
  `_rebuild()` 全删会把它们一并吞掉；症状只是“画面上看不到”，而字典里存的对象悄悄变成 `null`，
  很难定位。只拆自己建的骨骼就行。自检里有两项守这个（外部标记节点、血条）。
- **射速冷却要真的去读。** 曾经只写了 `_fire_cd = fire_rate` 却没人判断它，
  于是变成每帧一发（实测 39 发/秒，配置是 9）。`--shoot` 模式会把时长与发数相除来断言射速。
- **后坐力是累积上飘且不回落（用户指定）。** 每发直接写进俯仰基准 `_pitch`，
  唯一的边界是俯仰上限；玩家得自己把鼠标往下压来补偿。
  曾经做成“独立叠加量 + 自行回落”，被要求改成不回位，所以 `_recoil`/`recoil_max_deg`
  /`recoil_recovery` 都已删掉。
- **水平后坐力是随机的、而且没有上限。** 每发在 ±`recoil_yaw_deg` 内独立取值加到
  `rotation.y`，与俯仰一样累积不回位；水平不设上限是因为 yaw 会绕圈，限制它没有意义。
  断言它不能只看“总共偏了多少”（那是随机量的和），要**逐发取样**看“存在、有界、每发不同”。
  点射取样时点击间隔必须大于射速冷却，否则一次点击打出多发、样本就混了。
- **抬准星要放在开火计算完之后。** 写在前面的话，连第一发都会偏掉一个后坐力步长；
  子弹应当飞向开火前瞄的位置。
- **对方掉血要在开火期间盯，不能等打完再读。** 他被打死会在 3 秒后重生回满血，
  那时候读到的永远是 100（曾因此误判为“没打中”）。另外**松手后要等一拍再读俯仰**：
  Godot 还没处理完松开时，冷却到点会又打出一发，会把“不回落”误判成“回落了”。
- **“要抵消的旋转”在两种宿主下含义不同（持枪姿态踩过）。** `stick_figure.aim_lean` 必须由
  宿主告知，不能让组件自己读 `rotation.y`：本地玩家下它是“相对 Player 的偏身”（要抵消，
  因为 Player 的旋转在外层已生效），替身下它是“世界朝向”（不能抵消，否则枪恒指世界前方）。
  因为读了自己的 `rotation.y`，对手的枪永远指向同一个方向。
  自检已改成**同时模拟两种宿主**（带旋转的父节点 / 直接挂根节点），之前只模拟后者而漏掉了。
- **血条不要用 billboard 材质。** 两个方片几乎重合（只差 0.004），而 billboard 只改顶点
  朝向、**不改位置**，那点偏移的方向就随替身朝向变；再叠加 `no_depth_test`
  （深度完全不参与判定），从某些角度只能看到一个灰色矩形。改成节点每帧 `look_at` 相机。
- **相机不能压得太低。** 下蹲把相机降到 1.6 米时，角色的头就正好压在准星上
  （头顶到屏幕纵向 0.48，准星 0.50）——刚腾出来的位置又没了。取 2.2 米（0.56）。
  快照里的 `headScreenY` 可以核对，`--shoot` 里有一项断言守它。
- **`add_child` 之后不能假定 `_ready` 已经跑过。** 血条的 `set_health` 曾在 `_fill` 为 null 时
  访问它（`net.gd` 就是“add_child 完立刻 set_health”）；入树与就绪不是同一时刻。
  改成幂等的 `_ensure_built()`。
- **截图时机要避开累积状态。** 后坐力不回落后，测试里打几轮就会把视角永久抬高，
  拍到只剩曳光与准星。`--shoot` 的截图放在**第一轮开火之前**。
- **测试不要复制游戏常量。** 后坐力那几项断言用的是快照里报出来的 `recoilPerShotDeg`
  等配置值，而不是在测试里另写一份；否则改配置就得同步改测试（两个真相来源）。
- **合成的鼠标位移不能用来做定量转向。** Windows 的指针加速会做非线性映射，
  同一段代码两次运行得到 0.05 与 0.23 度/像素。所以用它只能断言“朝向确实变了”，
  要可重复的转向就把初始朝向设对（我们让两人出生时面对面）。
- **左右命名要对得上。** 角色面朝 -Z，所以**右侧是 +X**；`*_r` 必须在 +X、`*_l` 在 -X，
  与眼部命名保持一致。曾经手臂是反的（`upper_arm_r` 长在左边），枪就“拿在左手”。
- **`BoneAttachment3D` 要在入树之后再设 `bone_name`。** 反过来写（先设名再 `add_child`）
  在当前帧 `get_bone_idx()` 仍是 -1，要跑过一帧才解析出来。运行时看不出差别，
  但无头自检里会得到一个假的“未绑定”报告，容易误判。
- **`--script` 运行的脚本里，`_initialize()` 阶段读 `BoneAttachment3D.get_bone_idx()` 一定是 -1**
  （解析发生在帧内的内部处理）。自检要放到 `_process()` 的第一帧之后跑，见 `stick-check.gd`。
- **同一根骨头只留一个 `BoneAttachment3D`。** 每个网格各建一个附件时，同一骨骼的多个附件
  会在按骨骼统计网格时彼此覆盖（自检会误报“缺件”），节点数也平白翻倍。见 `stick_figure._attach()`。
- **火柴人的 Y 方向约定：躯干从骨盆向上长，四肢从骨骼原点向下垂。**
  偏移符号写反不报错，只是那一段挂到身体外面去——实测把胸前横带的偏移写成负值，
  它就横架到两条大腿上了。所以自检里有一项用外包围盒验证部件两两相交。- **击杀提示（`hud.feed`）只挂 3.5 秒，截图与断言都必须在它还在的时候做。**
  测试末尾统一读 HUD 会得到空字符串，看起来像“界面没显示”，实际是已经过期了；
  现在由 `fireBurst` 在开火期间取样（`feedSeen`）。
- **横幅只能有一个写入口。** 胜负、回合开场、“等待对手”三种状态都写同一块横幅，
  分散写会互相盖掉（“等待对手”会把开场的 ROUND 1 顶掉）。现在统一由
  `match.gd` 的 `_check_round_banner()` 按优先级决定，每帧刷一次。
- **回合重置会恢复开局朝向与俯仰，`--shoot` 必须躲开它。** 那个朝向跳变会被
  “每发左右偏移有界”的断言当成后坐力数据。所以射击模式用 `?kills=99`
  （分数上限可用网址参数覆盖），而 `--score` 反过来用 `?kills=1` 把一局压到几秒。
- **散布方向要在广播之前定下来**，而且本地特效、远端重放、命中判定三者必须用同一条弹道。
  在锥体内取点要用 `sqrt(randf())` 做径向半径，否则子弹会在中心堆成一团。
- **准星间距必须在同一帧推给 HUD**（在改写 `_spread` 之后立刻推）：放到下一帧的话，
  显示的间距永远比真实散布少一发，看起来像准星没跟上，断言也会差一个步长。
- **倒下碎屑的节点名要以 `Impact` 开头**（`ImpactSpark`）：这样 `net.gd` 的 `_count_fx()`
  把它一起数进去，“特效会自己清掉、不会越积越多”那条断言就自动盖住了它。
- **测试中途存的截图要先建目录**：`--shoot` 与 `--score` 的中途截图写在收尾之前，
  而目录原本靠收尾那一步创建；换个新目录就 ENOENT 崩溃，且**崩在断言之前**——
  只数“✗ 有几行”会把它误读成“全部通过”。统计时要同时确认 `结论` 那行在不在。
- **`--script` 模式下新加节点的 `_ready` 不是立刻跑的**（`sfx-check.gd` 踩过）：
  在 `_initialize()` 里 `root.add_child(sfx)` 之后立刻读它的音效全是 `null`，
  而 `[sfx] 已合成…` 那行日志出现在检查之后。检查要放到 `_process()` 的第一帧之后。- **点击画面会触发全屏，视口尺寸随之改变**（无头实测 1258x566 → 800x544），
  写死的截图裁剪坐标会捕空。要按当前视口算，或直接用 `shot.mjs --center`。
- **HUD 准星就在画面正中央**，截图放大时它会压在角色躯干上，看起来像角色身上的一个青色方块
  （色值 `0.23,0.88,1`）。别把它当成模型缺陷去查。
- **朝向分三部分，且身体偏转规则反直觉（用户指定）。** 鼠标转镜头（也是移动换算的基准）；
  方向键只平移并让身体偏转 `lean_deg`（默认 45°）；规则是**横向输入决定偏侧、后退时横向镜像**
  —— 所以 A 左倾而 AS 右倾，**不随移动方向单调变化**，不能用“朝移动方向限幅”表达。
  `net-probe-check.mjs --walk` 逐键锁住这张表，改动前先看它。
- **镜头不跟随身体偏转。** 曾试过“外观完全朝移动方向转 + 镜头跟随”，结果方向键一按画面就转，
  “朝屏幕里走”与 W 键语义不一致，操作失去参考，已回退。如果要再试：相机跟随外观时，
  移动换算的基准**不能**用镜头，否则正反馈（按 D → 右转 → 镜头转 → “右”又变成新的右）。
- **同步与检查要发同一个量。** `net.gd` 的 `facingDeg` 必须来自 `facing_yaw()`（实际广播的那个），
  而不是某个节点的 `rotation.y`：外观不自己转身后它恒为 0，报告量与同步量就会惄惄分家。
- **同一父节点下的同名子节点会被 Godot 自动改名**，按名字统计网格会漏（两只眼睛就只数到一只）。
  命名要区分（`eye_l` / `eye_r`），统计按前缀归类。

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
- 射击：`scripts/gun.gd` 的枪（挂在右手、枪口跟随镜头俯仰）、`scripts/fx.gd` 的膛口火光与曳光、
  **由被打中的人判定命中**、`scripts/hud.gd` 的血条与命中提示、倒地后重生
- 后坐力（累积上飘、不回落）与 Shift 下蹲（降相机、降速、后坐力降到 35%）
- 散布（连发变大、停火回落）与程序化音效（`scripts/sfx.gd`，零素材合成九个音）
- 计分与回合（`scripts/match.gd`）：击杀/阵亡、记分板、击杀提示、胜负横幅、下一回合重置
  （分数上限可用 `?kills=N` 覆盖）
- 命中表现的调味：准星随散布张开、开火时枪身后退、镜头抖动（开火/挨打）、倒下碎屑、
  远端的膛口火光

未完成（下一步按此顺序）：

- [ ] 联机同步的完整化：替身物理碰撞、延迟补偿、断线重连
  （目前是**有意的取舍**，已写在 README「局域网怎么跑」里；局域网下收益小于复杂度）
- [ ] 手感数值调优（偏好，得人定）：音效音量、散布与后坐力的大小、分数上限
- [ ] 真人试玩一轮，把“哪里不对劲”反馈回来（AI 判断不了手感）
