extends CanvasLayer
## HUD：血量条、命中提示、倒地提示。
##
## 控件全部用代码建（`main.tscn` 里只留已有的准星），因为准星的位置与尺寸是场景数据、
## 而血量条这类会随状态变化的东西，写在代码里比在 .tscn 里改偏移量清楚。
##
## 文字一律用英文或数字：Godot 默认字体不含中日韩字形，中文会显示成空白方块。

const BAR_WIDTH := 240.0
const BAR_HEIGHT := 16.0

const HITMARKER_TIME := 0.14

var _bar_fill: ColorRect = null
var _bar_label: Label = null
var _hitmarker: Label = null
var _down: Label = null
var _hitmarker_left := 0.0


func _ready() -> void:
	add_to_group("hud")
	_build_health_bar()
	_build_hitmarker()
	_build_down_label()
	# 初始值先填上：player.gd 在 _ready 里推血量时，HUD 可能还没进 group，
	# 靠那次推送会留下一个空白的血量文字。
	set_health(100, 100)


func _process(delta: float) -> void:
	if _hitmarker_left > 0.0:
		_hitmarker_left -= delta
		if _hitmarker_left <= 0.0 and _hitmarker != null:
			_hitmarker.visible = false
	else:
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


## 命中提示：打中别人时闪一下。
func hitmarker() -> void:
	if _hitmarker == null:
		return
	_hitmarker.visible = true
	_hitmarker_left = HITMARKER_TIME
	set_process(true)


## 倒地提示。seconds <= 0 时隐藏。
func set_down(seconds: float) -> void:
	if _down == null:
		return
	if seconds <= 0.0:
		_down.visible = false
		return
	_down.visible = true
	_down.text = "DOWN  %.1f" % seconds


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
	_down.offset_left = -70.0
	_down.offset_top = 60.0
	_down.offset_right = 70.0
	_down.offset_bottom = 100.0
	_down.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_down.add_theme_color_override("font_color", Color(1.0, 0.35, 0.3))
	_down.visible = false
	add_child(_down)
