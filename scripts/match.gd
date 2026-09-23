extends Node
## 比分与回合：谁打倒了谁、什么时候结束、结束后怎么开下一回合。
##
## 【比分为什么靠"击杀事件"而不是各端自报】
## 被打倒的人在自己的客户端里最先知道结果（判定权本来就在他手上，见 player.gd 的
## `receive_shot`），于是由他广播一条 `_peer_kill(被打者, 开枪者)`。
## 中继对所有人是同一份转发，所以两端**按同一顺序**应用同一条事件，比分天然一致，
## 也不需要"谁是权威"这类额外约定。
##
## 周期性状态里也带着各自的 kills/deaths，但**只在该编号第一次出现时用来补种**：
## 后进房间的人不至于看到 0:0。之后再收到就不再用它覆盖——否则重置回合时，
## 迟到的旧数据会把刚清零的比分又写回去。
##
## 【回合结束】各端本地用同一份比分判断"有人到上限了"，所以两端几乎同时进入终局；
## 不需要再发一条"回合结束"的确认消息（发了反而要处理重复触发）。
##
## 分数上限可以用网址参数覆盖（`?kills=1`），自动化检查靠它把一局压缩到几秒。

const Ink := preload("res://scripts/ink.gd")

const DEFAULT_SCORE_LIMIT := 3

## 胜负横幅停留多久后开下一回合（秒）。太短来不及看清比分。
const ROUND_HOLD := 4.5
## 回合开始时"ROUND n"横幅停留多久（秒）。
const ROUND_INTRO := 2.0

var score_limit := DEFAULT_SCORE_LIMIT
var round := 1
## 本回合是否已经结束（结算中）。
var over := false
## 本回合的胜者编号，0 表示还没结束。
var winner_id := 0
## 距离下一回合还有多久（秒）。
var reset_left := 0.0

## "ROUND n" 横幅还要挂多久（秒）。
var _intro_left := 0.0
# 编号 → {kills, deaths}。字典是引用类型，_entry() 返回后可以直接改。
var _scores: Dictionary = {}
# 上一次推给 HUD 的横幅内容。它每帧都会被算一次，但只在真的变了时才去改 Label：
# add_theme_color_override 每次都会让主题缓存失效，每帧调没有必要。
var _banner_key := ""


func _ready() -> void:
	if OS.has_feature("web"):
		score_limit = maxi(1, int(Net.query_param("kills", str(DEFAULT_SCORE_LIMIT))))
	# 每帧都要跑：横幅要在"等待对手 / 回合开场 / 胜负"之间切换，
	# 而这些都是随时间变的（对方进来、开场横幅到点）。帧成本可以忽略。
	print("[match] 先到 ", score_limit, " 杀")


## 自己连上房间时由 net.gd 通知。此时才知道自己的编号。
##
## 这里**不开场横幅**：一个人先开房间时应该看到"等待对手"，
## 等对方真的出现再喊 ROUND 1（见 on_peers_changed）。
func on_connected(id: int) -> void:
	_entry(id)
	_refresh_hud()


## 房间里的人数（不含自己）变了。
##
## 从 0 变到有人的那一刻就是本局真正开始的时候：两人都摆好了才开打，
## 而先开房间的人在此期间看到的是"等待对手"。
func on_peers_changed(count: int) -> void:
	if count <= 0:
		return
	_intro_left = ROUND_INTRO
	Sfx.play_round_start()


func my_kills() -> int:
	if Net.my_id <= 0:
		return 0
	return int(_entry(Net.my_id)["kills"])


func my_deaths() -> int:
	if Net.my_id <= 0:
		return 0
	return int(_entry(Net.my_id)["deaths"])


func other_kills() -> int:
	# 目前只有两个人，所以"别人"就是除了我以外唯一的那个编号。
	for id in _scores:
		if id != Net.my_id:
			return int(_scores[id]["kills"])
	return 0


## 我被打倒了。killer_id 为 0 表示没有明确的凶手。
func report_local_death(killer_id: int) -> void:
	if Net.my_id <= 0:
		return
	_apply_kill(Net.my_id, killer_id)
	Net.broadcast_kill(Net.my_id, killer_id)


## 别人被打倒的消息（由被打者广播，见文件头）。
func apply_remote_kill(victim_id: int, killer_id: int) -> void:
	_apply_kill(victim_id, killer_id)


## 第一次见到某个编号时用他自报的比分补种。已经有记录就直接返回，不覆盖。
func seed_remote(id: int, kills: int, deaths: int) -> void:
	if id <= 0 or _scores.has(id):
		return
	_scores[id] = {"kills": maxi(0, kills), "deaths": maxi(0, deaths)}
	_refresh_hud()


func _entry(id: int) -> Dictionary:
	if not _scores.has(id):
		_scores[id] = {"kills": 0, "deaths": 0}
	return _scores[id]


func _apply_kill(victim_id: int, killer_id: int) -> void:
	# 回合结束后的击杀不计分：比分已经结算，再累加会让"到上限"这件事重新发生。
	if over or victim_id <= 0:
		return
	var victim := _entry(victim_id)
	victim["deaths"] = int(victim["deaths"]) + 1
	if killer_id > 0 and killer_id != victim_id:
		var killer := _entry(killer_id)
		killer["kills"] = int(killer["kills"]) + 1
		if killer_id == Net.my_id:
			Sfx.play_kill()
			_hud_call("hitmarker", [true])
	_hud_call("feed", ["%s  >  %s" % [Net.player_name(killer_id), Net.player_name(victim_id)]])
	_check_round()
	_refresh_hud()


func _check_round() -> void:
	if over:
		return
	var best := 0
	var best_id := 0
	for id in _scores:
		var kills := int(_scores[id]["kills"])
		if kills > best:
			best = kills
			best_id = id
	if best < score_limit or best_id <= 0:
		return
	over = true
	winner_id = best_id
	reset_left = ROUND_HOLD
	_check_round_banner()
	if winner_id == Net.my_id:
		Sfx.play_victory()
	else:
		Sfx.play_defeat()


func _process(delta: float) -> void:
	if over:
		reset_left -= delta
		if reset_left <= 0.0:
			_start_next_round()
	else:
		_intro_left = maxf(0.0, _intro_left - delta)
	_check_round_banner()


## 横幅只有一个写入口：胜负、回合开场、等待对手三选一。
##
## 分开写会打架——比如“等待对手”刚好在回合开场的两秒里把人家的 ROUND 1 盖掉。
## 优先级就是下面的顺序：结算 > 开场 > 等待。
func _check_round_banner() -> void:
	var key := _banner_state_key()
	if key == _banner_key:
		return
	_banner_key = key
	if over:
		var won := winner_id == Net.my_id
		# 横幅上除了胜负，还要把最终比分写清楚：两个人都在同一块屏幕上对不上号时，
		# “我赢了但几比几”是唯一能说明过程的信息。
		_hud_call("banner", [
			"YOU WIN" if won else "YOU LOSE",
			_score_line(),
			# 胜用墨黑（最重）、败用石墨灰：黑白里靠浓淡拉开区别
			Ink.INK if won else Ink.GRAPHITE,
		])
		return
	if _intro_left > 0.0:
		_hud_call("banner", ["ROUND %d" % round, "FIRST TO %d" % score_limit])
		return
	if Net.connected and not Net.has_opponent():
		# 一个人先把房间开起来是常态（两台笔记本、先到的那台），
		# 不提示的话对面看到的就是一个空场地，不知道还要不要把另一台打开。
		_hud_call("banner", ["WAITING FOR OPPONENT", _room_hint(), Ink.GRAPHITE])
		return
	_hud_call("banner", ["", ""])


## 横幅当前应当显示哪一态。它变了才需要重写 Label。
func _banner_state_key() -> String:
	if over:
		return "over:%d" % winner_id
	if _intro_left > 0.0:
		return "intro:%d" % round
	if Net.connected and not Net.has_opponent():
		return "waiting"
	return "none"


## 等待时告诉对方怎么进来：带上房间名，两台机器用同一个房间才会相遇。
func _room_hint() -> String:
	return "room=%s  -  open the same room on the other device" % Net.room


func _start_next_round() -> void:
	over = false
	winner_id = 0
	reset_left = 0.0
	for id in _scores:
		_scores[id]["kills"] = 0
		_scores[id]["deaths"] = 0
	round += 1
	# 两个人各自把自己送回出生点，位置随周期性状态同步过去。
	var player := _player()
	if player != null and player.has_method("reset_for_round"):
		player.call("reset_for_round")
	_intro_left = ROUND_INTRO
	Sfx.play_round_start()
	_refresh_hud()
	_check_round_banner()


## "ember 3  -  1 frost" 之类的单行比分，用于终局横幅。
func _score_line() -> String:
	var ids := _scores.keys()
	ids.sort()
	var parts := PackedStringArray()
	for id in ids:
		parts.append("%s %d" % [Net.player_name(id), int(_scores[id]["kills"])])
	return "   ".join(parts)


# --- HUD / 玩家访问 ----------------------------------------------------------

func _player() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var found := tree.get_nodes_in_group("player")
	return found[0] if not found.is_empty() else null


func _hud_call(method: String, args: Array) -> void:
	var tree := get_tree()
	if tree == null:
		return
	var hud := tree.get_first_node_in_group("hud")
	if hud != null:
		hud.callv(method, args)


## 把记分板推给 HUD。只在比分或回合变化时调，不是每帧。
func _refresh_hud() -> void:
	if Net.my_id <= 0:
		return
	var ids := _scores.keys()
	ids.sort()
	var rows: Array = []
	for id in ids:
		rows.append({
			"name": Net.player_name(id),
			"kills": int(_scores[id]["kills"]),
			"deaths": int(_scores[id]["deaths"]),
			"me": id == Net.my_id,
		})
	_hud_call("scoreboard", ["FIRST TO %d" % score_limit, rows])


## 供 net.gd 发布快照（自动化检查用）。
func snapshot() -> Dictionary:
	var scores := {}
	for id in _scores:
		scores[str(id)] = {
			"kills": int(_scores[id]["kills"]),
			"deaths": int(_scores[id]["deaths"]),
			"name": Net.player_name(id),
		}
	return {
		"scoreLimit": score_limit,
		"round": round,
		"over": over,
		"winner": winner_id,
		"resetLeft": snappedf(reset_left, 0.01),
		"scores": scores,
	}
