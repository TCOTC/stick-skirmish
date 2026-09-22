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

const AVATAR_COLORS: Array[Color] = [
	Color(0.95, 0.45, 0.30),
	Color(0.35, 0.85, 0.45),
	Color(0.95, 0.80, 0.30),
	Color(0.65, 0.45, 0.95),
]

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
# 远端玩家：编号 → {pos: Vector3, yaw: float, at: float}
var _targets: Dictionary = {}
# 编号 → 替身节点
var _avatars: Dictionary = {}


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
	rpc("_peer_state", my_id, _player.global_position, _player.rotation.y)


## 收到的每个包都会被标成来自 1 号，所以发送者身份只能自己写在参数里。
@rpc("any_peer", "call_remote")
func _peer_state(id: int, pos: Vector3, yaw: float) -> void:
	if id == my_id or id <= 1:
		return

	var entry: Dictionary = _targets.get(id, {})
	var first := entry.is_empty()
	entry["pos"] = pos
	entry["yaw"] = yaw
	entry["at"] = Time.get_ticks_msec() / 1000.0
	_targets[id] = entry

	if first:
		print("[net] 见到玩家 ", id)
		_avatars[id] = _make_avatar(id, pos, yaw)


func _make_avatar(id: int, pos: Vector3, yaw: float) -> MeshInstance3D:
	var mesh_inst := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.4
	capsule.height = 1.8
	mesh_inst.mesh = capsule

	var mat := StandardMaterial3D.new()
	mat.albedo_color = AVATAR_COLORS[id % AVATAR_COLORS.size()]
	mesh_inst.material_override = mat

	var scene := get_tree().current_scene
	if scene == null:
		scene = self
	scene.add_child(mesh_inst)
	mesh_inst.global_position = pos + Vector3(0.0, 0.9, 0.0)
	mesh_inst.rotation.y = yaw
	return mesh_inst


func _expire_peers() -> void:
	if _targets.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	var gone: Array = []
	for id in _targets:
		if now - float(_targets[id]["at"]) > PEER_TIMEOUT:
			gone.append(id)
	for id in gone:
		_targets.erase(id)
		var avatar = _avatars.get(id)
		if avatar != null:
			avatar.queue_free()
		_avatars.erase(id)
		print("[net] 玩家 ", id, " 超时离开")


func _smooth_avatars(delta: float) -> void:
	var weight := 1.0 - exp(-SMOOTH_RATE * delta)
	for id in _targets:
		var avatar = _avatars.get(id)
		if avatar == null:
			continue
		var entry: Dictionary = _targets[id]
		var target: Vector3 = entry["pos"] + Vector3(0.0, 0.9, 0.0)
		avatar.global_position = avatar.global_position.lerp(target, weight)
		avatar.rotation.y = lerp_angle(avatar.rotation.y, float(entry["yaw"]), weight)


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

	var text := "room=%s  me=%d  %s" % [room, my_id, status]
	if connected and not _targets.is_empty():
		text += "  others=%s" % str(_targets.keys())
	_label.text = text


## 供 tools/net-probe-check.mjs 读取，方便自动化验证"两边都看见了对方"。
func _publish() -> void:
	var snapshot := {
		"room": room,
		"url": url,
		"myId": my_id,
		"connected": connected,
		"status": status,
		"peers": _targets.keys(),
		"avatars": _avatars.size(),
	}
	JavaScriptBridge.eval("window.__netstat = " + JSON.stringify(snapshot))
