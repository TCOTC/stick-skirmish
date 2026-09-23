extends Node
## 最小可用的局域网联机：每个客户端广播自己的位置，并为其他玩家画一个替身。
##
## 采用「各自广播、编号写在参数里」而不是 Godot 的定向 rpc 或 MultiplayerSynchronizer，
## 原因是中继把收到的每个包都标记为来自 1 号（见 README「联机」），
## 发送方身份无法获知，rpc_id 与 peer 可见性都不可靠。
##
## 房间由网址参数决定：?room=xxx，默认 game。两台设备必须用同一个房间名。
## 同一台机器开两个标签页也能看到替身，可以单独验证同步。
##
## 局限（这是"先跑起来看看"，不是成品）：
##   - 没有插值补偿，网络抖动大时会看到远端瞬移（只有位置平滑）
##   - 断线不重连，对端离开靠超时判定
##   - 命中的判定权在**被打中的人**那边，对方网络卡顿时会漏判（没有延迟补偿）

const TICK := 0.05          # 20 Hz 广播自身状态
const PEER_TIMEOUT := 2.0   # 超过这么久没收到就认为对方走了
const SMOOTH_RATE := 14.0   # 替身位置平滑速度
const PUBLISH_INTERVAL := 0.25  # 供自动化检查读取的间隔
const FIRE_RANGE := 200.0   # 复现别人弹道时的射线长度
const DEFAULT_MAX_HP := 100

# 替身放在第 3 碰撞层：**只给射线用，不做物理阻挡**。
# 默认碰撞层是 1，走到一起会互相卡住；而射线默认掩码包含所有层，所以曳光能停在替身上。
const AVATAR_COLLISION_LAYER := 3

## 目标位置离替身当前这么远（米）时直接瞬移，不做平滑。
##
## 回合重置与重生会让对方**瞬间**换位置，而平滑那些距离的表现是“横穿整个场地滑过去”，
## 比瞬移更奇怪。同理，朝向差超过 TELEPORT_YAW_DEG 度时也不做插值，否则会转一大圈。
const TELEPORT_DIST := 3.0
const TELEPORT_YAW_DEG := 75.0

const SPAWN_Z := 9.0
const SPAWN_X_OFFSET := 3.0
# 替身判定为“在地面上”的高度阈值。场地是平的，脚底 y 约为 0，跳跃时才会明显抬高。
const GROUND_Y_MAX := 0.3

# 用 preload 而不是全局类名：headless 与 --script 模式不会写 .godot 里的全局类缓存。
const StickFigureScript := preload("res://scripts/stick_figure.gd")
const HealthBarScript := preload("res://scripts/health_bar_3d.gd")

var my_id := 0
var connected := false
var status := "init"
var room := "game"
var url := ""
## 是否显示左上角那行开发信息（房间/编号/状态）。默认只在未连上时显示：
## 正常游玩时这一行只是噪声，而连不上时它又是唯一能看出问题的地方。
var _debug_label := false

var _api: MultiplayerAPI = null
var _peer: WebSocketMultiplayerPeer = null
var _player: Node3D = null
var _label: Label = null
var _hud: CanvasLayer = null
var _acc := 0.0
var _pub_at := 0.0
# 自己的样式序号（按进入房间的顺序，0 是第一个进来的）
var _my_rank := 0
# 远端玩家：编号 → {pos, yaw, at, speed, grounded}
var _targets: Dictionary = {}
# 编号 → 替身火柴人
var _avatars: Dictionary = {}
# 编号 → 已应用的样式序号（变了才重建外观）
var _avatar_ranks: Dictionary = {}
# 编号 → 替身头顶的血条
var _avatar_bars: Dictionary = {}


func _ready() -> void:
	if not OS.has_feature("web"):
		# 桌面端拿不到 location.host，暂时不接。要接的话把中继地址写死即可。
		status = "web only"
		set_process(false)
		return

	room = _query("room", "game")
	_debug_label = _query("debug", "") == "1"
	var base := str(JavaScriptBridge.eval(
		"(location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host"
	))
	if base.is_empty() or base.contains("null"):
		status = "no server"
		return

	# ?as=godot 让中继补上 Godot 需要的那 4 字节编号帧，否则高层 API 连不上。
	url = "%s/ws/%s?as=godot" % [base, room]
	# 真正的连接推迟到第一帧再建：在 _ready() 里建连接会被立刻断开（实测）。
	status = "idle"
	print("[net] 目标 ", url)


func _start_client() -> void:
	_api = MultiplayerAPI.create_default_interface()
	_peer = WebSocketMultiplayerPeer.new()
	var err := _peer.create_client(url)
	if err != OK:
		status = "create failed %d" % err
		_api = null
		_peer = null
		return
	_api.multiplayer_peer = _peer
	# Node.multiplayer 是只读的，只能通过 SceneTree 把 API 注册到本节点路径上。
	get_tree().set_multiplayer(_api, get_path())

	# 握手超时默认只有 3 秒，而它从“创建客户端”那一刻就开始数了：
	# 如果首帧渲染耗时超过 3 秒（软件渲染、低端设备、冷启动都容易发生），
	# 第一次 poll 时超时已过，Godot 会直接放弃连接（poll() 一旦判定断开就永远返回），
	# 表现为连上后立刻断开、且没有任何错误信息。放宽到 20 秒。
	_peer.handshake_timeout = 20.0

	status = "connecting"
	print("[net] 已创建客户端，握手超时=", _peer.get_handshake_timeout())


func _query(key: String, fallback: String) -> String:
	var value := str(JavaScriptBridge.eval(
		"new URLSearchParams(location.search).get('%s') || ''" % key
	))
	return value if not value.is_empty() else fallback


## 读网址参数。match.gd 也要用它（分数上限可以用 ?kills=1 覆盖），所以做成公开的。
func query_param(key: String, fallback: String) -> String:
	return _query(key, fallback)


func _process(delta: float) -> void:
	if _api == null:
		_start_client()   # 只建连接，本帧不 poll（与探针一致）
		return

	_api.poll()   # 状态转换与收包都发生在这里

	match _peer.get_connection_status():
		MultiplayerPeer.CONNECTION_CONNECTING:
			status = "connecting"
		MultiplayerPeer.CONNECTION_CONNECTED:
			if my_id == 0:
				my_id = _peer.get_unique_id()
				_on_connected()
			connected = true
			_send_state(delta)
		MultiplayerPeer.CONNECTION_DISCONNECTED:
			if connected:
				print("[net] 连接断开")
			connected = false
			my_id = 0
			status = "disconnected"

	_expire_peers()
	_smooth_avatars(delta)

	_pub_at += delta
	if _pub_at >= PUBLISH_INTERVAL:
		_pub_at = 0.0
		_update_hud()
		_publish()


func _on_connected() -> void:
	status = "connected"
	print("[net] 已连接 编号=", my_id, " 房间=", room)
	_player = _find_player()
	if _player == null:
		push_warning("[net] 场景里没有找到玩家节点，无法上报位置")
		return
	# 两个玩家都从 (0, 1, 9) 出生会完全重叠，按编号奇偶错开。
	_player.global_position.x += SPAWN_X_OFFSET if (my_id % 2 == 0) else -SPAWN_X_OFFSET
	# 朝向对面：两人各偏 ±90°。默认都朝 -Z 的话开局看到的是墙，而且正好背对对手。
	_player.rotation.y = (PI * 0.5) if (my_id % 2 == 0) else (-PI * 0.5)
	print("[net] 出生点 ", _player.global_position, " 朝向 ", rad_to_deg(_player.rotation.y))
	# 告诉玩家出生点，重生时要用
	if _player.has_method("set_spawn_point"):
		_player.call("set_spawn_point", _player.global_position)
	_refresh_styles()
	# 无条件应用一次：_refresh_styles 只在「位次变了」时才会调它，
	# 而位次是 0 时“没变”，于是初始化就依赖了“默认样式正好是 0 号”这个巧合。
	_apply_my_style()
	# 比分与回合作者只认 Match，连上之后才拿得到自己的编号，所以在这里通知它。
	Match.on_connected(my_id)


func _find_player() -> Node3D:
	var found := get_tree().get_nodes_in_group("player")
	if found.is_empty():
		return null
	return found[0]


func _send_state(delta: float) -> void:
	if _player == null:
		_player = _find_player()
	if _player == null:
		return
	_acc += delta
	if _acc < TICK:
		return
	_acc = 0.0
	# 广播：中继不做定向，rpc() 默认就是发给所有对端。
	# 发的是**视觉朝向**（火柴人面朝哪边），不是 player.rotation.y（镜头朝向）：
	# 本地火柴人跟着移动方向转，发镜头朝向的话双方看到的脸就不一致了。
	# kills/deaths 也一并带上，但接收方**只在第一次见到这个编号时**用它补种比分
	# （见 match.gd 的文件头），之后比分只跟击杀事件走。
	rpc("_peer_state", my_id, _player.global_position, _visual_yaw(), _visual_pitch(),
		_visual_crouch(), Match.my_kills(), Match.my_deaths())


## 问玩家节点要当前的外观朝向。外观策略属于 player.gd，这里不自己拼 rotation.y。
func _visual_yaw() -> float:
	if _player == null:
		return 0.0
	if _player.has_method("facing_yaw"):
		return float(_player.call("facing_yaw"))
	return _player.rotation.y


## 镜头俯仰。替身拿它摆枪口角度，不然对方的枪会一直平指。
## 取的是**含后坐力**的生效俯仰（player.aim_pitch），否则开枪时对方的枪不会跟着抬。
func _visual_pitch() -> float:
	if _player != null and _player.has_method("aim_pitch"):
		return float(_player.call("aim_pitch"))
	return 0.0


## 下蹲程度。替身据此摆蹲姿。
func _visual_crouch() -> float:
	if _player != null and _player.has_method("crouch_amount"):
		return float(_player.call("crouch_amount"))
	return 0.0


## 收到的每个包都会被标成来自 1 号，所以发送者身份只能自己写在参数里。
@rpc("any_peer", "call_remote")
func _peer_state(
	id: int, pos: Vector3, yaw: float, pitch: float, crouch: float, kills: int, deaths: int
) -> void:
	if id == my_id or id <= 1:
		return

	var now := Time.get_ticks_msec() / 1000.0
	var entry: Dictionary = _targets.get(id, {})
	var first := entry.is_empty()

	# 用两次收到的位置差算出速度，用来驱动替身的步态（平滑后的位置会掩盖真实速度）。
	var speed := 0.0
	var prev_at := float(entry.get("at", 0.0))
	if prev_at > 0.0:
		var moved: Vector3 = pos - (entry["pos"] as Vector3)
		moved.y = 0.0
		speed = moved.length() / maxf(0.001, now - prev_at)

	entry["pos"] = pos
	entry["yaw"] = yaw
	entry["pitch"] = pitch
	entry["crouch"] = crouch
	entry["at"] = now
	entry["speed"] = speed
	entry["grounded"] = pos.y < GROUND_Y_MAX
	_targets[id] = entry

	if first:
		print("[net] 见到玩家 ", id)
		_avatars[id] = _make_avatar(id, pos, yaw)
		_add_avatar_body(_avatars[id])
		_add_avatar_bar(id, _avatars[id])
		_refresh_styles()
		# 只补种这一次：之后的比分以击杀事件为准（详见 match.gd 的文件头）。
		Match.seed_remote(id, kills, deaths)
		# 对手到场就是本局真正的开场（先开房间的人之前看到的是“等待对手”）。
		Match.on_peers_changed(_targets.size())


## 替身也是火柴人：脚底对齐玩家原点，所以位置不加偏移。
func _make_avatar(id: int, pos: Vector3, yaw: float) -> Node3D:
	var avatar = StickFigureScript.new()
	avatar.name = "Remote%d" % id

	var scene := get_tree().current_scene
	if scene == null:
		scene = self
	scene.add_child(avatar)
	avatar.global_position = pos
	avatar.rotation.y = yaw
	# 入树后 build 已完成，才能挂枪（枪的配色取自样式材质）
	avatar.equip_gun()
	return avatar


## 给替身加一个只有射线能碰到的碰撞体（见 AVATAR_COLLISION_LAYER 的说明）。
## 没有它的话，射击方的曳光会直接穿过替身，看不出打没打中。
func _add_avatar_body(avatar: Node3D) -> void:
	var body := StaticBody3D.new()
	body.name = "HitBox"
	body.collision_layer = 1 << (AVATAR_COLLISION_LAYER - 1)
	body.collision_mask = 0        # 不去碰别人，只被射线查
	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.4
	shape.height = 1.8
	col.shape = shape
	# CollisionShape3D 必须是 CollisionObject3D 的直接子节点，中间夹一层就不注册
	body.add_child(col)
	body.position = Vector3(0.0, 0.9, 0.0)
	avatar.add_child(body)


func _add_avatar_bar(id: int, avatar: Node3D) -> void:
	var bar = HealthBarScript.new()
	bar.name = "HealthBar"
	avatar.add_child(bar)
	bar.set_health(DEFAULT_MAX_HP, DEFAULT_MAX_HP)
	_avatar_bars[id] = bar


## 样式按“进入房间的顺序”分配。
##
## 中继下发的编号是全局递增的，所以同一房间内编号的大小关系就是先后顺序。
## 把已知编号排序，各自的位次就是它的序号——两个客户端算出来的结果一致。
func _refresh_styles() -> void:
	var ids := _known_ids()
	ids.sort()

	for id in _targets:
		var rank := ids.find(id)
		if rank < 0:
			rank = 0
		if int(_avatar_ranks.get(id, -1)) == rank:
			continue
		_avatar_ranks[id] = rank
		var avatar: Node3D = _avatars.get(id)
		if avatar != null:
			avatar.apply_style(rank)

	var my_rank := ids.find(my_id)
	if my_rank < 0:
		my_rank = 0
	if my_rank != _my_rank:
		_my_rank = my_rank
		_apply_my_style()


func _apply_my_style() -> void:
	var figure := _my_figure()
	if figure != null:
		figure.apply_style(_my_rank)


func _my_figure() -> Node:
	if _player == null:
		_player = _find_player()
	if _player == null:
		return null
	return _player.get_node_or_null("Figure")


## 自己 + 所有已知对端的编号。
func _known_ids() -> Array:
	var ids: Array = []
	if my_id > 0:
		ids.append(my_id)
	for id in _targets:
		if not ids.has(id):
			ids.append(id)
	return ids


func _expire_peers() -> void:
	if _targets.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	var gone: Array = []
	for id in _targets:
		if now - float(_targets[id]["at"]) > PEER_TIMEOUT:
			gone.append(id)
	if gone.is_empty():
		return
	for id in gone:
		_targets.erase(id)
		_avatar_ranks.erase(id)
		_avatar_bars.erase(id)
		var avatar = _avatars.get(id)
		if avatar != null:
			avatar.queue_free()
		_avatars.erase(id)
		print("[net] 玩家 ", id, " 超时离开")
	_refresh_styles()
	Match.on_peers_changed(_targets.size())


func _smooth_avatars(delta: float) -> void:
	var weight := 1.0 - exp(-SMOOTH_RATE * delta)
	for id in _targets:
		var avatar: Node3D = _avatars.get(id)
		if avatar == null:
			continue
		var entry: Dictionary = _targets[id]
		var target: Vector3 = entry["pos"]
		if avatar.global_position.distance_to(target) > TELEPORT_DIST:
			# 瞬移（回合重置、重生）：平滑在这里只会变成一段奇怪的滑行
			avatar.global_position = target
		else:
			avatar.global_position = avatar.global_position.lerp(target, weight)
		var yaw := float(entry["yaw"])
		if absf(rad_to_deg(angle_difference(avatar.rotation.y, yaw))) > TELEPORT_YAW_DEG:
			avatar.rotation.y = yaw
		else:
			avatar.rotation.y = lerp_angle(avatar.rotation.y, yaw, weight)
		avatar.aim_pitch = float(entry.get("pitch", 0.0))
		avatar.animate(
			float(entry.get("speed", 0.0)), bool(entry.get("grounded", true)), delta,
			float(entry.get("crouch", 0.0))
		)


## 界面文字一律用英文：Godot 默认字体不含中日韩字形，中文会显示成空白方块。
func _update_hud() -> void:
	if _label == null:
		if _hud == null:
			var scene := get_tree().current_scene
			_hud = scene.get_node_or_null("HUD") if scene != null else null
		if _hud == null:
			return
		_label = Label.new()
		_label.position = Vector2(12.0, 10.0)
		_label.add_theme_color_override("font_color", Color(0.72, 0.86, 1.0))
		_hud.add_child(_label)

	# 连上了就不再占着屏幕：房间名与等待提示已经由 Match 的横幅负责，
	# 而这行字（编号/rank/状态）只是排查用的。要看就加 ?debug=1。
	_label.visible = _debug_label or not connected
	var text := "room=%s  me=%d  rank=%d  %s" % [room, my_id, _my_rank, status]
	if connected and not _targets.is_empty():
		text += "  others=%s" % str(_targets.keys())
	_label.text = text


## 供 tools/net-probe-check.mjs 读取，方便自动化验证"两边都看见了对方"以及样式分配。
## 关节角度也一并输出：试着走动时可以看到这两个数在变，能区分"角色在动"与"腿部在摆"。
func _publish() -> void:
	var ranks := {}
	for id in _avatar_ranks:
		ranks[str(id)] = _avatar_ranks[id]

	var own_health := DEFAULT_MAX_HP
	if _player != null and "health" in _player:
		own_health = int(_player.get("health"))

	var head_screen_y := _head_screen_y()

	var figure_info := {}
	var figure := _my_figure()
	if figure != null:
		figure_info = {
			"style": _style_name(_my_rank),
			"legAngle": snappedf(figure.bone_angle("upper_leg_l"), 0.001),
			"armAngle": snappedf(figure.bone_angle("upper_arm_l"), 0.001),
			# 报告**实际广播出去**的那个朝向（facing_yaw），而不是某个节点的 rotation.y。
			# 曾经报的是 figure.rotation.y：改成“外观不再自己转身”后它恒为 0，
			# 于是“报告的量”与“同步的量”悄悄分家，检查会得出无意义的结论。
			"facingDeg": snappedf(rad_to_deg(_visual_yaw()), 0.1),
			# 鼠标控制的那个节点（移动基准）的朝向，用于断言“方向键不带动它”。
			"bodyYawDeg": snappedf(rad_to_deg(_player.rotation.y), 0.1) if _player != null else 0.0,
			# 身体随方向键的偏转，用于验证那张偏转表（后退时镜像）。
			"leanDeg": snappedf(rad_to_deg(figure.rotation.y), 0.1),
			"camYawDeg": snappedf(rad_to_deg(_cam_offset()), 0.1),
		}

	var pos := Vector3.ZERO
	if _player != null:
		pos = _player.global_position

	# 替身的世界朝向。房间模式用它验证“远端看到的脸朝向”与本体一致。
	var avatar_yaw := {}
	for id in _avatars:
		avatar_yaw[str(id)] = snappedf(rad_to_deg(_avatars[id].rotation.y), 0.1)

	# 替身的位置。射击检查要用它算出“该朝哪边转才能打到对方”。
	var peer_pos := {}
	for id in _targets:
		var p: Vector3 = _targets[id]["pos"]
		peer_pos[str(id)] = [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)]

	# 替身**实际画在**哪里。它与 peerPos（收到的目标点）之差就是平滑的滞后；
	# 回合重置之后两者应当几乎重合（那时走的是瞬移分支，不是平滑）。
	var avatar_pos := {}
	for id in _avatars:
		var a: Vector3 = _avatars[id].global_position
		avatar_pos[str(id)] = [snappedf(a.x, 0.01), snappedf(a.y, 0.01), snappedf(a.z, 0.01)]

	var shots := 0
	if _player != null and "shots_fired" in _player:
		shots = int(_player.get("shots_fired"))

	# 后坐力与下蹲的实时值，供自动化检查验证“开火逐渐上飘、不回落、蹲下上飘更小”。
	# 后坐力现在写进俯仰基准里，所以“抬了多少”就由 pitchDeg 本身反映，不再单列一个量。
	var crouch := 0.0
	var pitch_deg := 0.0
	var cam_y := 0.0
	# 配置值一并报出去：自动化检查据此断言，改了配置测试会跟着变，
	# 而不是在测试里另写一份常量（那样就有两个真相来源）。
	var recoil_per_shot_deg := 0.0
	var pitch_max_deg := 0.0
	var crouch_recoil_scale := 1.0
	var recoil_yaw_deg := 0.0
	var spread_deg := 0.0
	var spread_min_deg := 0.0
	var spread_max_deg := 0.0
	if _player != null:
		if _player.has_method("crouch_amount"):
			crouch = float(_player.call("crouch_amount"))
		if _player.has_method("aim_pitch"):
			pitch_deg = rad_to_deg(float(_player.call("aim_pitch")))
		if _player.has_method("spread_amount"):
			spread_deg = float(_player.call("spread_amount"))
		var arm := _player.get_node_or_null("SpringArm")
		if arm != null:
			cam_y = arm.position.y
		recoil_per_shot_deg = float(_player.get("recoil_per_shot_deg"))
		pitch_max_deg = float(_player.get("pitch_max_deg"))
		crouch_recoil_scale = float(_player.get("crouch_recoil_scale"))
		recoil_yaw_deg = float(_player.get("recoil_yaw_deg"))
		spread_min_deg = float(_player.get("spread_min_deg"))
		spread_max_deg = float(_player.get("spread_max_deg"))
		crouch = snappedf(crouch, 0.01)
		pitch_deg = snappedf(pitch_deg, 0.01)
		cam_y = snappedf(cam_y, 0.01)
		spread_deg = snappedf(spread_deg, 0.01)

	# 替身的装饰件（命中框、头顶血条）是否还在。
	# 它们挂在替身节点下，而外观重建曾经会把子节点全删掉，把这两个一起吞了——
	# 症状只是“画面上看不到”，所以宁可断言也不要靠看。
	var decor := {}
	for id in _avatars:
		var avatar = _avatars[id]
		decor[str(id)] = {
			"hitBox": avatar.get_node_or_null("HitBox") != null,
			"barOk": _avatar_bars.get(id) != null,
		}

	var snapshot := {
		"room": room,
		"url": url,
		"myId": my_id,
		"myRank": _my_rank,
		"myStyle": _style_name(_my_rank),
		"myName": player_name(my_id),
		"connected": connected,
		"status": status,
		"peers": _targets.keys(),
		"peerRanks": ranks,
		"peerNames": _peer_names(),
		"peerPos": peer_pos,
		"avatarPos": avatar_pos,
		"avatars": _avatars.size(),
		"avatarYawDeg": avatar_yaw,
		"avatarDecor": decor,
		"figure": figure_info,
		"pos": [snappedf(pos.x, 0.01), snappedf(pos.y, 0.01), snappedf(pos.z, 0.01)],
		"health": own_health,
		"shots": shots,
		"recoilDeg": pitch_deg,
		"crouch": crouch,
		"pitchDeg": pitch_deg,
		"camY": cam_y,
		"recoilPerShotDeg": recoil_per_shot_deg,
		"recoilYawDeg": recoil_yaw_deg,
		"pitchMaxDeg": pitch_max_deg,
		"crouchRecoilScale": crouch_recoil_scale,
		"spreadDeg": spread_deg,
		"spreadMinDeg": spread_min_deg,
		"spreadMaxDeg": spread_max_deg,
		"fx": _count_fx(),
		"fxBursts": Fx.burst_count(),
		"headScreenY": head_screen_y,
		"sounds": Sfx.live_voices(),
		"match": Match.snapshot(),
		"hud": _hud_info(),
	}
	JavaScriptBridge.eval("window.__netstat = " + JSON.stringify(snapshot))


## 编号 → 名字，供自动化检查核对两端对同一个人的称呼是否一致。
func _peer_names() -> Dictionary:
	var names := {}
	for id in _targets:
		names[str(id)] = player_name(id)
	return names


## HUD 上真的显示了什么。只读游戏内的数字不够：数字对、界面没画出来也是一样的。
func _hud_info() -> Dictionary:
	var hud := _hud_node()
	if hud == null:
		return {}
	return {
		"scoreboard": str(hud.call("scoreboard_text")),
		"banner": str(hud.call("banner_text")),
		"feed": str(hud.call("feed_text")),
		"hitmarkers": int(hud.call("hitmarker_count")),
		"kills": int(hud.call("kill_count")),
		"down": str(hud.call("down_text")),
		"crosshairGap": float(hud.call("crosshair_gap")),
	}


## 角色头顶在屏幕上的纵向位置，0 是屏幕顶端、1 是底端。
##
## 用相机的 unproject 算，而不是靠眼看截图：取景要求是“角色落在画面下方、
## 准星周围留出空间”，这是个可以断言的数值。看不到角色（-1）时检查会报出来。
func _head_screen_y() -> float:
	if _player == null:
		return -1.0
	var cam := _player.get_node_or_null("SpringArm/Camera3D") as Camera3D
	if cam == null or not cam.is_inside_tree():
		return -1.0
	var head := _player.global_position + Vector3(0.0, 1.75, 0.0)
	var vh := cam.get_viewport().get_visible_rect().size.y
	if vh <= 0.0:
		return -1.0
	return snappedf(cam.unproject_position(head).y / vh, 0.01)


## 场上还活着的特效节点数（曳光、弹着点）。用来确认开火真的产生了效果。
func _count_fx() -> int:
	var scene := get_tree().current_scene
	if scene == null:
		return 0
	var n := 0
	for child in scene.get_children():
		var name := String(child.name)
		if name.begins_with("Tracer") or name.begins_with("Impact"):
			n += 1
	return n


func _style_name(rank: int) -> String:
	var styles: Array = StickFigureScript.STYLES
	return str(styles[((rank % styles.size()) + styles.size()) % styles.size()]["name"])


## 当前是否已经有对手在房间里。先开房间的那一方靠它决定要不要提示“等待对手”。
func has_opponent() -> bool:
	return not _targets.is_empty()


## 编号 → 展示名（记分板与击杀提示要用）。
##
## 没有名字输入，就拿火柴人样式名当名字（ember / frost）。两端算出来的结果一致：
## 样式按**进入房间的顺序**分配，而这个顺序就是编号的大小关系。
## 还没收到对方任何状态包时（比如击杀事件先到）按编号排序推出位次，
## 结果仍与 _refresh_styles 一致，不会出现同一个人两边叫两个名字。
func player_name(id: int) -> String:
	if id <= 0:
		return "?"
	if id == my_id:
		return _style_name(_my_rank)
	var rank := int(_avatar_ranks.get(id, -1))
	if rank < 0:
		var ids := _known_ids()
		ids.sort()
		rank = maxi(0, ids.find(id))
	return _style_name(rank)


## 镜头相对玩家参考系的偏转。相机跟随外观，所以它应当与 facingDeg 一致。
func _cam_offset() -> float:
	if _player != null and _player.has_method("camera_offset_yaw"):
		return float(_player.call("camera_offset_yaw"))
	return 0.0


# --- 射击同步 ---------------------------------------------------------------

## 告诉所有人“我开了一枪”。origin 是枪口，direction 是子弹实际飞行的方向
## （已含散布，所以不是“朝向准星”而是“这一发真的往哪飞”）。
func broadcast_fire(origin: Vector3, direction: Vector3) -> void:
	if my_id <= 0:
		return
	rpc("_peer_fire", my_id, origin, direction)


## 告诉所有人“我倒下了，凶手是他”。killer_id 为 0 表示没有明确凶手。
##
## 击杀由**被打者**广播：判定权本来就在他手上（见 player.gd 的 receive_shot），
## 中继对所有人是同一份转发，所以两端按同一顺序得到同一条事件，比分天然一致。
func broadcast_kill(victim_id: int, killer_id: int) -> void:
	if my_id <= 0:
		return
	rpc("_peer_kill", victim_id, killer_id)


## 血量变化时告知所有人（包括自己被打倒后重生回满血）。
func broadcast_health(hp: int) -> void:
	if my_id <= 0:
		return
	rpc("_peer_health", my_id, hp)


## 收到别人的枪声。做两件事：把这条弹道画出来，再让本地玩家判定自己有没有被打到。
##
## 判定交给本地玩家而不是射击方，理由见 player.gd 的 `receive_shot`。
@rpc("any_peer", "call_remote")
func _peer_fire(shooter_id: int, origin: Vector3, direction: Vector3) -> void:
	if shooter_id == my_id or shooter_id <= 1:
		return

	var color := _peer_color(shooter_id)
	var hit := _trace(origin, direction)
	var end := origin + direction.normalized() * FIRE_RANGE
	if not hit.is_empty():
		end = hit["position"]
	Fx.tracer(origin, end, color)
	# 对方的枪也要亮膛口火光（顺带后退一点）：之前只有曳光，看不到“他从哪开火”。
	var avatar = _avatars.get(shooter_id)
	if avatar != null and avatar.gun != null:
		avatar.gun.flash()
	# 别人的枪声按世界位置播放：能听出他在左边还是右边，是这个视角下唯一的空间线索。
	Sfx.play_shot(origin)
	if not hit.is_empty():
		Fx.impact(hit["position"], hit["normal"], color)
		Sfx.play_impact(hit["position"])

	if _player != null and _player.has_method("receive_shot"):
		# 伤害取**本地**配置：判定权在被击中的人这边，伤害量也一并归他管，
		# 这样两端的“谁定结果”是同一个，不会一半在一个客户端、一半在另一个。
		# 开枪者编号也要传过去：倒下时 Match 靠它给对方记上一分。
		_player.call(
			"receive_shot", origin, direction, int(_player.get("bullet_damage")), shooter_id
		)


## 收到击杀事件（由被打者广播，见 broadcast_kill）。
@rpc("any_peer", "call_remote")
func _peer_kill(victim_id: int, killer_id: int) -> void:
	if victim_id == my_id or victim_id <= 1:
		return
	# 倒下的一瞬间溅一团碎屑：位置取替身当前位置，效果只在本机播，不需要同步。
	var avatar = _avatars.get(victim_id)
	if avatar != null:
		Fx.burst(avatar.global_position + Vector3(0.0, 1.1, 0.0), avatar.limb_color())
	Match.apply_remote_kill(victim_id, killer_id)


## 收到血量变化。打中提示就是从这里来的：看到别人的血真的掉了才算命中。
@rpc("any_peer", "call_remote")
func _peer_health(id: int, hp: int) -> void:
	if id == my_id or id <= 1:
		return
	var entry: Dictionary = _targets.get(id, {})
	var prev := int(entry.get("hp", DEFAULT_MAX_HP)) if entry.has("hp") else -1
	entry["hp"] = hp
	_targets[id] = entry

	var bar = _avatar_bars.get(id)
	if bar != null:
		bar.set_health(hp, DEFAULT_MAX_HP)

	# prev < 0 表示这是第一次收到他的血量（比如他刚重生上线），不算命中
	if prev >= 0 and hp < prev:
		var hud := _hud_node()
		if hud != null:
			hud.call("hitmarker")
		print("[net] 打中玩家 ", id, " 剩余 ", hp)


## 用玩家自己的世界做一次射线，取第一个命中（掩体也算）。
func _trace(origin: Vector3, direction: Vector3) -> Dictionary:
	if _player == null:
		return {}
	var space := _player.get_world_3d().direct_space_state
	if space == null:
		return {}
	var query := PhysicsRayQueryParameters3D.create(
		origin, origin + direction.normalized() * FIRE_RANGE
	)
	return space.intersect_ray(query)


## 射手样式的颜色，用来给曳光与弹着点上色，方便分辨是谁打的。
func _peer_color(id: int) -> Color:
	var avatar = _avatars.get(id)
	if avatar != null and avatar.has_method("limb_color"):
		return avatar.limb_color()
	return Color(1.0, 0.9, 0.5)


func _hud_node() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group("hud")
