extends CharacterBody3D
## 第三人称角色控制器。
##
## 朝向策略：身体始终跟着镜头转（射击游戏常见的"侧移"手感），
## 移动方向按镜头朝向换算，所以按 A/D 是横向平移，不是原地转身。
##
## 键位不写进 project.godot，而是在 _ensure_actions() 里用引擎常量注册，
## 避免手写键盘码出错；以后想改，直接在 Project Settings → Input Map 里加即可。

@export var move_speed: float = 8.0
@export var jump_velocity: float = 9.0
@export_range(0.0005, 0.01, 0.0005) var mouse_sensitivity: float = 0.0025
@export var pitch_min_deg: float = -70.0
@export var pitch_max_deg: float = 35.0

@onready var _arm: SpringArm3D = $SpringArm

const MOVE_ACTIONS := ["move_forward", "move_back", "move_left", "move_right", "jump"]

# 用 preload 而不是全局类名：headless 与 --script 模式不会写 .godot 里的全局类缓存。
const StickFigureScript := preload("res://scripts/stick_figure.gd")

var _pitch: float = -0.22
var _gravity: float = 24.0
# 是否处于"正在操作"状态。判定标准就是鼠标是否被锁定：
# 光标还露在外面（还没点进游戏，或者刚按了 Esc）就不该能操作。
var _input_active := false

## 火柴人外观。样式（两套之一）由 net.gd 按进入房间的顺序决定。
var figure: StickFigureScript = null


func _ready() -> void:
	_ensure_actions()
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_arm.rotation.x = _pitch
	_build_figure()
	# 注意：不要在这里抢鼠标锁定。浏览器要求 pointer lock 必须由用户手势触发，
	# 否则会抛 WrongDocumentError；玩家第一次点击时再接管（见 _unhandled_input）。
	print("[player] ready pos=", global_position)


## 外观用骨骼绑定的火柴人（见 stick_figure.gd），不再用胶囊网格。
## 脚本节点的原点是脚底，与碰撞胶囊底部对齐，所以直接放在本地原点即可。
func _build_figure() -> void:
	figure = StickFigureScript.new()
	figure.name = "Figure"
	add_child(figure)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_pitch = clampf(
			_pitch - event.relative.y * mouse_sensitivity,
			deg_to_rad(pitch_min_deg),
			deg_to_rad(pitch_max_deg)
		)
		_arm.rotation.x = _pitch
	elif event is InputEventMouseButton and event.pressed:
		# 只认左键：滚轮也会产生 InputEventMouseButton（button_index 是 WHEEL_*），
		# 但"滚一下滚轮"不该等于"我要开始玩"。
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		# 网页上"锁指针"这一步交给注入的脚本做，这里刻意不碰。
		# 原因：requestFullscreen 和 requestPointerLock 都由浏览器要求"必须在用户手势里发出"，
		# 两者同时发出会打架 —— 全屏切换过程中发出的锁定请求偶尔被拒，
		# 表现就是"全屏进去了、鼠标还显示着，得再点一次"。
		# 脚本里把两者串成"先全屏 → 等切换完成 → 再锁"，并带两次重试；
		# Godot 会自己跟随浏览器真实的指针锁状态，不需要引擎再发一次请求。
		# 桌面端没有全屏这回事，照旧由引擎自己锁。
		if not OS.has_feature("web") and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _physics_process(delta: float) -> void:
	var active := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if active != _input_active:
		_input_active = active
		if not active:
			_stop_moving()

	var want := Vector2.ZERO
	if active:
		want = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := (transform.basis * Vector3(want.x, 0.0, want.y)).normalized()

	if not is_on_floor():
		velocity.y -= _gravity * delta
	elif active and Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity

	velocity.x = dir.x * move_speed
	velocity.z = dir.z * move_speed
	move_and_slide()

	# 步态用水平速度驱动：走快摆幅大、停下回直立、离地换空中姿势。
	if figure != null:
		figure.animate(Vector2(velocity.x, velocity.z).length(), is_on_floor(), delta)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		# 标签页/窗口被切走之后，keyup 事件收不到，按键状态会卡在"按下"。
		# 不手动清掉的话，切回来一点画面角色就自己开始走。
		_stop_moving()


func _stop_moving() -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	for action in MOVE_ACTIONS:
		Input.action_release(action)


static func _ensure_actions() -> void:
	var key_bindings := {
		"move_forward": [KEY_W, KEY_UP],
		"move_back": [KEY_S, KEY_DOWN],
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"jump": [KEY_SPACE],
		"dash": [KEY_SHIFT],
	}
	for action_name in key_bindings:
		if InputMap.has_action(action_name):
			continue
		InputMap.add_action(action_name)
		for code in key_bindings[action_name]:
			var ev := InputEventKey.new()
			ev.physical_keycode = code
			InputMap.action_add_event(action_name, ev)

	var mouse_bindings := {
		"fire": [MOUSE_BUTTON_LEFT],
		"aim": [MOUSE_BUTTON_RIGHT],
	}
	for action_name in mouse_bindings:
		if InputMap.has_action(action_name):
			continue
		InputMap.add_action(action_name)
		for button in mouse_bindings[action_name]:
			var ev := InputEventMouseButton.new()
			ev.button_index = button
			InputMap.action_add_event(action_name, ev)
