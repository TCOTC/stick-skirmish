extends CanvasLayer
## HUD：血量条、受伤红闪、命中提示、倒地提示、比分板、胜负横幅、击杀提示。
##
## 控件全部用代码建（`main.tscn` 里只留已有的准星），因为准星的位置与尺寸是场景数据、
## 而血量条这类会随状态变化的东西，写在代码里比在 .tscn 里改偏移量清楚。
##
## 文字一律用英文或数字：Godot 默认字体不含中日韩字形，中文会显示成空白方块。
##
## 它只是“显示层”：谁打倒了谁、回合结没结束都属于 Match 的职责，
## 这里只提供 `scoreboard` / `banner` / `feed` 这些幂等的写接口。

const BAR_WIDTH := 240.0
const BAR_HEIGHT := 16.0

const HITMARKER_TIME := 0.14
## 击杀提示停留更久一点，让它与普通命中区分得开。
const KILLMARKER_TIME := 0.45
## 一条击杀提示存活多久（秒），以及最多同时显示几条。
const FEED_TIME := 3.5
const FEED_MAX := 4
## 受伤红闪的淡出时长（秒）。
const FLASH_TIME := 0.35

## 准星刻度：四根短线，间距跟着当前散布张开。散布大时口子大。
## 这是玩家唯一能“看见”散布的地方——否则散布只是个看不见的数值。
const CROSS_BASE_GAP := 4.0
const CROSS_GAP_PER_DEG := 3.2
const CROSS_LEN := 6.0
const CROSS_THICK := 1.5
const CROSS_COLOR := Color(0.23, 0.88, 1.0, 0.85)

var _bar_fill: ColorRect = null
var _bar_label: Label = null
var _hitmarker: Label = null
var _down: Label = null
var _hitmarker_left := 0.0

var _score_title: Label = null
var _score_box: VBoxContainer = null
var _score_rows: Array[Label] = []

var _banner_box: VBoxContainer = null
var _banner_main: Label = null
var _banner_sub: Label = null

var _feed_box: VBoxContainer = null
# 每条 = {node: Label, left: float}
var _feed: Array = []

var _flash: ColorRect = null
var _flash_tween: Tween = null
## “点一下画面才能开始”的提示。文案写死在 HUD 里，玩家只告诉它“我接管鼠标了没”。
var _hint_box: VBoxContainer = null
var _hint_main: Label = null
var _hint_sub: Label = null
## 准星的四根刻度（上、下、左、右），以及当前间距（用来避免重复布局）。
var _cross: Array[ColorRect] = []
var _cross_gap := -1.0

# 命中提示出现过几次（含击杀）。供自动化检查确认提示真的触发过。
var _hitmarker_count := 0
var _kill_count := 0


func _ready() -> void:
	add_to_group("hud")
	_build_health_bar()
	_build_hitmarker()
	_build_down_label()
	_build_scoreboard()
	_build_banner()
	_build_feed()
	_build_flash()
	_build_crosshair()
	_build_hint()
	# 初始值先填上：player.gd 在 _ready 里推血量时，HUD 可能还没进 group，
	# 靠那次推送会留下一个空白的血量文字。
	set_health(100, 100)


func _process(delta: float) -> void:
	if _hitmarker_left > 0.0:
		_hitmarker_left -= delta
		if _hitmarker_left <= 0.0 and _hitmarker != null:
			_hitmarker.visible = false
	_tick_feed(delta)
	if _hitmarker_left <= 0.0 and _feed.is_empty():
		set_process(false)


## 更新自己的血量。fraction 会做 0..1 限制，所以传入超范围的数也不会画歪。
func set_health(hp: int, max_hp: int) -> void:
	if _bar_fill == null:
		return
	var frac := clampf(float(hp) / maxf(1.0, float(max_hp)), 0.0, 1.0)
	# 满血绿、空血红，中间连续过渡
	_bar_fill.color = Color(0.30 + 0.65 * (1.0 - frac), 0.25 + 0.60 * frac, 0.25)
	_bar_fill.offset_right = 2.0 + (BAR_WIDTH - 4.0) * frac
	if _bar_label != null:
		_bar_label.text = "HP %d / %d" % [maxi(hp, 0), max_hp]


## 受伤时整屏闪一下红。strength 是起始不透明度，倒地时给大一点。## 不设输入阻挡（mouse_filter = IGNORE）：它铺满整屏，若参与 GUI 输入会把点击吞掉。
func damage_flash(strength := 0.32) -> void:
	if _flash == null:
		return
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash.color = Color(0.85, 0.10, 0.12, clampf(strength, 0.0, 1.0))
	_flash_tween = create_tween()
	_flash_tween.tween_property(_flash, "color:a", 0.0, FLASH_TIME)


## 命中提示：打中别人时闪一下。kill = true 时用红色并停留更久。
func hitmarker(kill := false) -> void:
	if _hitmarker == null:
		return
	_hitmarker_count += 1
	if kill:
		_kill_count += 1
	_hitmarker.text = "X" if kill else "x"
	_hitmarker.add_theme_color_override(
		"font_color", Color(1.0, 0.32, 0.28) if kill else Color(1.0, 0.95, 0.4)
	)
	_hitmarker.visible = true
	_hitmarker_left = KILLMARKER_TIME if kill else HITMARKER_TIME
	set_process(true)


## 倒地提示。seconds <= 0 时隐藏。killer 是把自己打倒的人的名字（可为空）。
func set_down(seconds: float, killer := "") -> void:
	if _down == null:
		return
	if seconds <= 0.0:
		_down.visible = false
		return
	_down.visible = true
	_down.text = "DOWN  %.1f" % seconds
	if not killer.is_empty():
		_down.text += "   (by %s)" % killer


# --- 比分板 / 横幅 / 击杀提示 -----------------------------------------------

## 是否已经在游玩（鼠标被接管）。没在游玩时显示“点一下画面”的提示。
##
## 浏览器不允许程序主动抢鼠标锁定，所以“必须点一下”是硬性前提；
## 对第一次打开链接的人来说，不说这一句他就只会看到一个不会动的场地。
func set_playing(playing: bool) -> void:
	if _hint_box != null:
		_hint_box.visible = not playing


## 比分板。rows 是 [{name, kills, deaths, me}]，按进入顺序排。
## 幂等：行数不变就只改文字，不重建控件。
func scoreboard(title: String, rows: Array) -> void:
	if _score_box == null:
		return
	_score_title.text = title
	while _score_rows.size() < rows.size():
		var label := Label.new()
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		label.add_theme_font_size_override("font_size", 18)
		_score_box.add_child(label)
		_score_rows.append(label)
	while _score_rows.size() > rows.size():
		var extra: Label = _score_rows.pop_back()
		extra.queue_free()
	for i in rows.size():
		var row: Dictionary = rows[i]
		var label := _score_rows[i]
		# rpad 让两行的数字对齐：默认字体不是等宽，用空格排版就得先补齐名字长度。
		label.text = "%s %2d / %d" % [str(row["name"]).rpad(6), int(row["kills"]), int(row["deaths"])]
		label.add_theme_color_override(
			"font_color", Color(0.72, 0.94, 1.0) if bool(row["me"]) else Color(0.62, 0.66, 0.74)
		)


## 胜负 / 回合横幅。main 为空表示收起。color 是主标题颜色。
func banner(main: String, sub: String, color := Color(0.72, 0.94, 1.0)) -> void:
	if _banner_box == null:
		return
	if main.is_empty():
		_banner_box.visible = false
		return
	_banner_box.visible = true
	_banner_main.text = main
	_banner_main.add_theme_color_override("font_color", color)
	_banner_sub.text = sub
	_banner_sub.visible = not sub.is_empty()


## 击杀提示：一行字排在最上面，几秒后自己淡出。
func feed(text: String) -> void:
	if _feed_box == null:
		return
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", Color(0.92, 0.80, 0.55))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_feed_box.add_child(label)
	# 新的一条排在最上面
	_feed_box.move_child(label, 0)
	_feed.push_front({"node": label, "left": FEED_TIME})
	# 超出上限的立刻收掉，不让它堆在屏幕上
	while _feed.size() > FEED_MAX:
		var old: Dictionary = _feed.pop_back()
		var old_label: Label = old["node"]
		if is_instance_valid(old_label):
			old_label.queue_free()
	set_process(true)


func _tick_feed(delta: float) -> void:
	if _feed.is_empty():
		return
	var keep: Array = []
	for item in _feed:
		var label: Label = item["node"]
		if not is_instance_valid(label):
			continue
		var left := float(item["left"]) - delta
		if left <= 0.0:
			label.queue_free()
			continue
		# 最后 0.8 秒淡出，避免突然消失
		label.modulate.a = clampf(left / 0.8, 0.0, 1.0)
		item["left"] = left
		keep.append(item)
	_feed = keep


# --- 供自动化检查读取 -------------------------------------------------------

## 准星间距（像素）。散布变化时自动化检查靠它确认“准星真的跟着张开了”。
func crosshair_gap() -> float:
	return snappedf(_cross_gap, 0.1)

## 比分板的文字（按行用 " | " 连接）。检查“界面真的显示了比分”要靠它，
## 只读 Match 里的数字不够——数字对、界面没画出来也是一样的。
func scoreboard_text() -> String:
	var parts := PackedStringArray()
	for label in _score_rows:
		if is_instance_valid(label):
			parts.append(label.text)
	return " | ".join(parts)


func banner_text() -> String:
	if _banner_box == null or not _banner_box.visible:
		return ""
	return "%s %s" % [_banner_main.text, _banner_sub.text]


func feed_text() -> String:
	var parts := PackedStringArray()
	for item in _feed:
		var label: Label = item["node"]
		if is_instance_valid(label):
			parts.append(label.text)
	return " | ".join(parts)


func hitmarker_count() -> int:
	return _hitmarker_count


func kill_count() -> int:
	return _kill_count


func down_text() -> String:
	return _down.text if _down != null and _down.visible else ""


## 当前显示的提示文字（没显示时为空）。供自动化检查用。
func hint_text() -> String:
	if _hint_box == null or not _hint_box.visible:
		return ""
	return "%s %s" % [_hint_main.text, _hint_sub.text]


func _build_health_bar() -> void:
	var bg := ColorRect.new()
	bg.name = "HealthBar"
	bg.color = Color(0.05, 0.06, 0.08, 0.78)
	# 锚在左下角：anchor_top/bottom 用 1.0，偏移相对底边往上量
	bg.anchor_top = 1.0
	bg.anchor_bottom = 1.0
	bg.offset_left = 24.0
	bg.offset_right = 24.0 + BAR_WIDTH
	bg.offset_top = -44.0
	bg.offset_bottom = -44.0 + BAR_HEIGHT
	add_child(bg)

	_bar_fill = ColorRect.new()
	_bar_fill.name = "Fill"
	# 作为 bg 的子节点，偏移相对 bg 的矩形。锚点必须写明：
	# 只写 offset_bottom = -2 而不把 anchor_bottom 设成 1，矩形会从 +2 到 -2——高度是负的，画不出来。
	_bar_fill.anchor_bottom = 1.0
	_bar_fill.offset_left = 2.0
	_bar_fill.offset_top = 2.0
	_bar_fill.offset_right = 2.0 + (BAR_WIDTH - 4.0)
	_bar_fill.offset_bottom = -2.0
	_bar_fill.color = Color(0.30, 0.85, 0.25)
	bg.add_child(_bar_fill)

	_bar_label = Label.new()
	_bar_label.name = "Label"
	_bar_label.anchor_top = 1.0
	_bar_label.anchor_bottom = 1.0
	_bar_label.offset_left = 24.0
	_bar_label.offset_top = -66.0
	_bar_label.offset_bottom = -48.0
	_bar_label.add_theme_color_override("font_color", Color(0.82, 0.88, 0.95))
	add_child(_bar_label)


func _build_hitmarker() -> void:
	_hitmarker = Label.new()
	_hitmarker.name = "Hitmarker"
	_hitmarker.text = "x"
	_hitmarker.add_theme_font_size_override("font_size", 20)
	_hitmarker.anchor_left = 0.5
	_hitmarker.anchor_top = 0.5
	_hitmarker.anchor_right = 0.5
	_hitmarker.anchor_bottom = 0.5
	_hitmarker.offset_left = 8.0
	_hitmarker.offset_top = -8.0
	_hitmarker.offset_right = 24.0
	_hitmarker.offset_bottom = 20.0
	_hitmarker.add_theme_color_override("font_color", Color(1.0, 0.95, 0.4))
	_hitmarker.visible = false
	add_child(_hitmarker)


func _build_down_label() -> void:
	_down = Label.new()
	_down.name = "Down"
	_down.anchor_left = 0.5
	_down.anchor_top = 0.5
	_down.anchor_right = 0.5
	_down.anchor_bottom = 0.5
	_down.offset_left = -110.0
	_down.offset_top = 60.0
	_down.offset_right = 110.0
	_down.offset_bottom = 100.0
	_down.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_down.add_theme_color_override("font_color", Color(1.0, 0.35, 0.3))
	_down.visible = false
	add_child(_down)


func _build_scoreboard() -> void:
	_score_box = VBoxContainer.new()
	_score_box.name = "Scoreboard"
	_score_box.anchor_left = 1.0
	_score_box.anchor_right = 1.0
	_score_box.offset_left = -190.0
	_score_box.offset_right = -16.0
	_score_box.offset_top = 12.0
	_score_box.add_theme_constant_override("separation", 2)
	add_child(_score_box)

	_score_title = Label.new()
	_score_title.name = "Title"
	_score_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_score_title.add_theme_font_size_override("font_size", 13)
	_score_title.add_theme_color_override("font_color", Color(0.55, 0.60, 0.68))
	_score_box.add_child(_score_title)


func _build_banner() -> void:
	_banner_box = VBoxContainer.new()
	_banner_box.name = "Banner"
	# 锚在顶部中央：不放进屏幕正中，免得挡住准星与对手
	_banner_box.anchor_left = 0.5
	_banner_box.anchor_right = 0.5
	_banner_box.offset_left = -260.0
	_banner_box.offset_right = 260.0
	_banner_box.offset_top = 92.0
	_banner_box.offset_bottom = 210.0
	_banner_box.visible = false
	add_child(_banner_box)

	_banner_main = Label.new()
	_banner_main.name = "Main"
	_banner_main.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_main.add_theme_font_size_override("font_size", 52)
	_banner_box.add_child(_banner_main)

	_banner_sub = Label.new()
	_banner_sub.name = "Sub"
	_banner_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_sub.add_theme_font_size_override("font_size", 20)
	_banner_sub.add_theme_color_override("font_color", Color(0.82, 0.88, 0.95))
	_banner_box.add_child(_banner_sub)


func _build_feed() -> void:
	_feed_box = VBoxContainer.new()
	_feed_box.name = "Feed"
	_feed_box.anchor_left = 1.0
	_feed_box.anchor_right = 1.0
	_feed_box.offset_left = -240.0
	_feed_box.offset_right = -16.0
	_feed_box.offset_top = 84.0
	_feed_box.add_theme_constant_override("separation", 1)
	add_child(_feed_box)


func _build_flash() -> void:
	_flash = ColorRect.new()
	_flash.name = "DamageFlash"
	_flash.anchor_right = 1.0
	_flash.anchor_bottom = 1.0
	_flash.color = Color(0.85, 0.10, 0.12, 0.0)
	# 铺满整屏的控件若参与 GUI 输入，会把点击吞掉（接管鼠标也要靠那一下点击）。
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_flash)


## 准星刻度。中心那个方块在 main.tscn 里，这里只加四根会动的短线。
func _build_crosshair() -> void:
	for i in 4:
		var rect := ColorRect.new()
		rect.name = "Cross%d" % i
		rect.anchor_left = 0.5
		rect.anchor_top = 0.5
		rect.anchor_right = 0.5
		rect.anchor_bottom = 0.5
		rect.color = CROSS_COLOR
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(rect)
		_cross.append(rect)
		# 0/1 是上下两根（竖向短杆），2/3 是左右两根（横向短杆）
		if i < 2:
			rect.offset_left = -CROSS_THICK * 0.5
			rect.offset_right = CROSS_THICK * 0.5
		else:
			rect.offset_top = -CROSS_THICK * 0.5
			rect.offset_bottom = CROSS_THICK * 0.5
	set_spread(0.0)


## 散布（度）→ 准星间距。角度越大，口子越开。
## 幂等：间距没变就不重新摆（每帧调也不会产生多余工作）。
func set_spread(deg: float) -> void:
	if _cross.size() < 4:
		return
	var gap := CROSS_BASE_GAP + clampf(deg, 0.0, 20.0) * CROSS_GAP_PER_DEG
	if absf(gap - _cross_gap) < 0.05:
		return
	_cross_gap = gap
	_cross[0].offset_top = -gap - CROSS_LEN
	_cross[0].offset_bottom = -gap
	_cross[1].offset_top = gap
	_cross[1].offset_bottom = gap + CROSS_LEN
	_cross[2].offset_left = -gap - CROSS_LEN
	_cross[2].offset_right = -gap
	_cross[3].offset_left = gap
	_cross[3].offset_right = gap + CROSS_LEN


## “点一下画面”的提示，放在画面下方中间（避开左下角的血条）。
## 文案是英文：Godot 默认字体不含中日韩字形。
func _build_hint() -> void:
	_hint_box = VBoxContainer.new()
	_hint_box.name = "Hint"
	_hint_box.anchor_left = 0.5
	_hint_box.anchor_right = 0.5
	_hint_box.anchor_top = 1.0
	_hint_box.anchor_bottom = 1.0
	_hint_box.offset_left = -320.0
	_hint_box.offset_right = 320.0
	_hint_box.offset_top = -134.0
	_hint_box.offset_bottom = -84.0
	add_child(_hint_box)

	_hint_main = Label.new()
	_hint_main.name = "Main"
	_hint_main.text = "CLICK TO PLAY"
	_hint_main.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_main.add_theme_font_size_override("font_size", 26)
	_hint_main.add_theme_color_override("font_color", Color(0.85, 0.94, 1.0))
	_hint_box.add_child(_hint_main)

	_hint_sub = Label.new()
	_hint_sub.name = "Sub"
	_hint_sub.text = "MOUSE look   WASD move   SHIFT crouch   LMB fire   ESC release"
	_hint_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_sub.add_theme_font_size_override("font_size", 14)
	_hint_sub.add_theme_color_override("font_color", Color(0.66, 0.74, 0.84))
	_hint_box.add_child(_hint_sub)
