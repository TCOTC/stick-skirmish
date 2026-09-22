extends Node
## 临时的联机连通性探针（只在网址带 ?probe=1 时启用，正常游玩完全不走这里）。
##
## 它要回答三个问题：
##   1. 网页版能不能连上 tools/serve.mjs 的 /ws 中继（含 wss + 自签证书这条路）；
##   2. 两个浏览器能不能通过中继互发消息；
##   3. Godot 高层联机 API（MultiplayerAPI + rpc）能不能跑在这种中继上。
##
## 两个测试各用一个房间，互不干扰：/ws/probe-ws 跑裸 WebSocketPeer，
## /ws/probe-mp?as=godot 跑高层 API（?as=godot 让中继补上 Godot 要求的那 4 字节编号帧）。
##
## 结果写到 window.__netprobe，供 tools/net-probe-check.mjs 读取；同时也 print 一份。
##
## 用完就该删掉：真正的联机逻辑不该长这个样子。

const HELLO_INTERVAL := 0.5   # 每隔多久重发一次自我介绍
const MP_START_AFTER := 4.0   # 裸 WebSocket 先单独跑一会儿，免得日志混在一起
const PUBLISH_INTERVAL := 0.25
const PRINT_INTERVAL := 2.0

const WS_ROOM := "probe-ws"
const MP_ROOM := "probe-mp"

var _enabled := false
var _name := "?"
var _base := ""           # wss://host 或 ws://host
var _url := ""            # 裸 WebSocket 测试用的完整地址

var _ws: WebSocketPeer = null
var _ws_state := "init"
var _ws_sent := 0
var _ws_hello_at := 0.0
var _ws_kicked := false   # whoami / subscribe 只发一次
var _ws_seen: Array[String] = []
var _ws_relay: Array[String] = []

var _api: MultiplayerAPI = null
var _mp: WebSocketMultiplayerPeer = null
var _mp_started := false
var _mp_url := ""
var _mp_state := "init"
var _mp_uid := -1
var _mp_hello_at := 0.0
var _mp_rpc_sent := 0
var _mp_rpc_seen: Array[String] = []

var _t := 0.0
var _publish_at := 0.0
var _print_at := 0.0


## 高层 API 的关键验证点：中继会把收到的包全部标成“来自 1 号”，
## 所以这里只能测广播式 rpc，发送者身份要自己写在参数里。
@rpc("any_peer", "call_remote")
func probe_rpc(who: String) -> void:
	if who != _name:
		_mp_rpc_seen.append(who)


func _ready() -> void:
	if not OS.has_feature("web"):
		set_process(false)
		return
	if not _query("probe", "").begins_with("1"):
		set_process(false)
		return
	_enabled = true
	_name = _query("name", "anonymous")
	print("[netprobe] 启动 name=", _name)


func _query(key: String, fallback: String) -> String:
	var value := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('%s') || ''" % key))
	return value if not value.is_empty() else fallback


func _process(delta: float) -> void:
	if not _enabled:
		return
	_t += delta
	_poll_ws(delta)
	if _t >= MP_START_AFTER:
		_poll_mp(delta)

	_publish_at += delta
	if _publish_at >= PUBLISH_INTERVAL:
		_publish_at = 0.0
		_publish()

	_print_at += delta
	if _print_at >= PRINT_INTERVAL:
		_print_at = 0.0
		print("[netprobe] ", JSON.stringify(_snapshot()))


## 页面是 https 就只能连 wss（混合内容会被浏览器拦掉），是 http（本机 localhost）就连 ws。
func _build_base() -> String:
	var js := "(location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host"
	return str(JavaScriptBridge.eval(js))


func _poll_ws(delta: float) -> void:
	if _ws == null:
		_base = _build_base()
		if _base.is_empty():
			_ws_state = "url-empty"
			return
		_url = "%s/ws/%s" % [_base, WS_ROOM]
		_ws = WebSocketPeer.new()
		var err := _ws.connect_to_url(_url)
		_ws_state = "connecting" if err == OK else "connect-error:%d" % err
		return

	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_CONNECTING:
			_ws_state = "connecting"
		WebSocketPeer.STATE_OPEN:
			_ws_state = "open"
			if not _ws_kicked:
				_ws_kicked = true
				_ws.send_text("relay:whoami")
				_ws.send_text("relay:subscribe")
			_ws_hello_at += delta
			if _ws_hello_at >= HELLO_INTERVAL:
				_ws_hello_at = 0.0
				if _ws.send_text("probe:%s" % _name) == OK:
					_ws_sent += 1
				else:
					_ws_state = "send-failed"
		WebSocketPeer.STATE_CLOSING:
			_ws_state = "closing"
		WebSocketPeer.STATE_CLOSED:
			_ws_state = "closed code=%d reason=%s" % [_ws.get_close_code(), _ws.get_close_reason()]

	while _ws.get_available_packet_count() > 0:
		var text := _ws.get_packet().get_string_from_utf8()
		if text.begins_with("probe:"):
			var who := text.substr("probe:".length())
			if not _ws_seen.has(who):
				_ws_seen.append(who)
		elif text.begins_with("relay:"):
			_ws_relay.append(text)


func _poll_mp(delta: float) -> void:
	if not _mp_started:
		_mp_started = true
		_mp_url = "%s/ws/%s?as=godot" % [_base, MP_ROOM]
		_api = MultiplayerAPI.create_default_interface()
		_mp = WebSocketMultiplayerPeer.new()
		var err := _mp.create_client(_mp_url)
		if err != OK:
			_mp_state = "create-error:%d" % err
			return
		_api.multiplayer_peer = _mp
		# Node.multiplayer 是只读的，只能通过 SceneTree 注册到本节点路径上；
		# 注册之后本节点的 rpc() 会走这个 API，主场景仍然用默认的那个。
		get_tree().set_multiplayer(_api, get_path())
		_mp_state = "connecting"
		return

	_api.poll()   # 状态转换与收包都发生在这里，不要再单独调 _mp.poll()
	match _mp.get_connection_status():
		MultiplayerPeer.CONNECTION_CONNECTING:
			_mp_state = "connecting"
		MultiplayerPeer.CONNECTION_CONNECTED:
			_mp_uid = _mp.get_unique_id()
			_mp_state = "connected"
			_mp_hello_at += delta
			if _mp_hello_at >= HELLO_INTERVAL:
				_mp_hello_at = 0.0
				rpc("probe_rpc", _name)
				_mp_rpc_sent += 1
		MultiplayerPeer.CONNECTION_DISCONNECTED:
			_mp_state = "disconnected"


func _snapshot() -> Dictionary:
	return {
		"name": _name,
		"url": _url,
		"t": snappedf(_t, 0.1),
		"ws": {
			"state": _ws_state,
			"sent": _ws_sent,
			"seen": _ws_seen,
			"relay": _ws_relay,
		},
		"mp": {
			"url": _mp_url,
			"state": _mp_state,
			"uid": _mp_uid,
			"rpcSent": _mp_rpc_sent,
			"rpcSeen": _mp_rpc_seen,
		},
	}


func _publish() -> void:
	JavaScriptBridge.eval("window.__netprobe = " + JSON.stringify(_snapshot()))
