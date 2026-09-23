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
##   - 替身没有碰撞，走过对方身体不会撞到
##   - 没有插值补偿，网络抖动大时会看到远端瞬移（只有位置平滑）
##   - 断线不重连，对端离开靠超时判定
##   - 只同步位置与朝向，没有射击、血量、计分

const TICK := 0.05          # 20 Hz 广播自身状态
const PEER_TIMEOUT := 2.0   # 超过这么久没收到就认为对方走了
const SMOOTH_RATE := 14.0   # 替身位置平滑速度
const PUBLISH_INTERVAL := 0.25  # 供自动化检查读取的间隔

const SPAWN_Z := 9.0
const SPAWN_X_OFFSET := 3.0
# 替身判定为“在地面上”的高度阈值。场地是平的，脚底 y 约为 0，跳跃时才会明显抬高。
const GROUND_Y_MAX := 0.3

# 用 preload 而不是全局类名：headless 与 --script 模式不会写 .godot 里的全局类缓存。
const StickFigureScript := preload("res://scripts/stick_figure.gd")

var my_id := 0
var connected := false
var status := "init"
var room := "game"
var url := ""

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


func _ready() -> void:
	if not OS.has_feature("web"):
		# 桌面端拿不到 location.host，暂时不接。要接的话把中继地址写死即可。
		status = "web only"
		set_process(false)
		return

	room = _query("room", "game")
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
	print("[net] 出生点 ", _player.global_position)
	_refresh_styles()
	# 无条件应用一次：_refresh_styles 只在「位次变了」时才会调它，
	# 而位次是 0 时“没变”，于是初始化就依赖了“默认样式正好是 0 号”这个巧合。
	_apply_my_style()


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
	rpc("_peer_state", my_id, _player.global_position, _visual_yaw())


## 问玩家节点要当前的外观朝向。外观策略属于 player.gd，这里不自己拼 rotation.y。
func _visual_yaw() -> float:
	if _player == null:
		return 0.0
	if _player.has_method("facing_yaw"):
		return float(_player.call("facing_yaw"))
	return _player.rotation.y


## 收到的每个包都会被标成来自 1 号，所以发送者身份只能自己写在参数里。
@rpc("any_peer", "call_remote")
func _peer_state(id: int, pos: Vector3, yaw: float) -> void:
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
	entry["at"] = now
	entry["speed"] = speed
	entry["grounded"] = pos.y < GROUND_Y_MAX
	_targets[id] = entry

	if first:
		print("[net] 见到玩家 ", id)
		_avatars[id] = _make_avatar(id, pos, yaw)
		_refresh_styles()


## 替身也是火柴人：脚底对齐玩家原点，所以位置不加偏移。
func _make_avatar(id: int, pos: Vector3, yaw: float) -> Node3D:
	var avatar: Node3D = StickFigureScript.new()
	avatar.name = "Remote%d" % id

	var scene := get_tree().current_scene
	if scene == null:
		scene = self
	scene.add_child(avatar)
	avatar.global_position = pos
	avatar.rotation.y = yaw
	return avatar


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
		var avatar = _avatars.get(id)
		if avatar != null:
			avatar.queue_free()
		_avatars.erase(id)
		print("[net] 玩家 ", id, " 超时离开")
	_refresh_styles()


func _smooth_avatars(delta: float) -> void:
	var weight := 1.0 - exp(-SMOOTH_RATE * delta)
	for id in _targets:
		var avatar: Node3D = _avatars.get(id)
		if avatar == null:
			continue
		var entry: Dictionary = _targets[id]
		avatar.global_position = avatar.global_position.lerp(entry["pos"], weight)
		avatar.rotation.y = lerp_angle(avatar.rotation.y, float(entry["yaw"]), weight)
		avatar.animate(
			float(entry.get("speed", 0.0)), bool(entry.get("grounded", true)), delta
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

	var snapshot := {
		"room": room,
		"url": url,
		"myId": my_id,
		"myRank": _my_rank,
		"myStyle": _style_name(_my_rank),
		"connected": connected,
		"status": status,
		"peers": _targets.keys(),
		"peerRanks": ranks,
		"avatars": _avatars.size(),
		"avatarYawDeg": avatar_yaw,
		"figure": figure_info,
		"pos": [snappedf(pos.x, 0.01), snappedf(pos.y, 0.01), snappedf(pos.z, 0.01)],
	}
	JavaScriptBridge.eval("window.__netstat = " + JSON.stringify(snapshot))


func _style_name(rank: int) -> String:
	var styles: Array = StickFigureScript.STYLES
	return str(styles[((rank % styles.size()) + styles.size()) % styles.size()]["name"])


## 镜头相对玩家参考系的偏转。相机跟随外观，所以它应当与 facingDeg 一致。
func _cam_offset() -> float:
	if _player != null and _player.has_method("camera_offset_yaw"):
		return float(_player.call("camera_offset_yaw"))
	return 0.0
