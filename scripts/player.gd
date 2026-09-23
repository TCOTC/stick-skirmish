extends CharacterBody3D
## 第三人称角色控制器。
##
## 朝向策略：**镜头与移动方向基准只由鼠标改变，方向键只平移 + 让身体偏转一点**。
##   - 鼠标旋转 Player（镜头与外观都是它的子节点），这就是移动换算的参考系
##   - W A S D 只改变速度，并让火柴人的身体偏转（见 _update_lean）
##   - 镜头不跟随这个偏转，仍然只由鼠标控制
##
## 身体偏转的规则（用户指定，见 _update_lean）：横向输入决定偏哪侧，后退时横向镜像。
## 于是偏转**不随移动方向单调变化**，不能用“朝移动方向限幅”那类公式实现。
##
## 试过让外观完全朝移动方向转、并让镜头跟着转，结果是方向键一按画面就转，
## 操作失去参考（“朝屏幕里走”与 W 键的语义不再一致），已回退。
## 若以后要再试，务必把移动换算的参考系与镜头旋转分开，否则会形成正反馈
## （按 D → 右转 → 镜头转 → “右”又变成新的右 → 一直转圈）。
##
## 键位不写进 project.godot，而是在 _ensure_actions() 里用引擎常量注册，
## 避免手写键盘码出错；以后想改，直接在 Project Settings → Input Map 里加即可。

@export var move_speed: float = 8.0
@export var jump_velocity: float = 9.0
@export_range(0.0005, 0.01, 0.0005) var mouse_sensitivity: float = 0.0025
@export var pitch_min_deg: float = -70.0
@export var pitch_max_deg: float = 35.0
## 身体随方向键偏转的最大角度（度）。“一点”到底多少由这里定，请自行试。
@export_range(0.0, 89.0, 1.0) var lean_deg: float = 45.0
## 偏转的逼近速度，越大转得越快。
@export var lean_rate: float = 12.0
## 两发之间的最短间隔（秒）。0.11 ≈ 9 发/秒。
@export var fire_rate: float = 0.11
## 命中一发的伤害。100 血 = 三发倒。
@export var bullet_damage: int = 34
@export var max_range: float = 200.0
## 倒地后多久重生（秒）。
@export var respawn_delay: float = 3.0

## 每发抬起的俯仰角（度）。
##
## 后坐力是**累积上飘且不回落**的：连发时准星逐渐往上飘，松开后**停在抬起的位置**，
## 要靠自己把鼠标往下压来补偿。这比“抬一下再弹回去”更吃操作，也让压枪成为一门手艺。
@export var recoil_per_shot_deg: float = 1.4
## 每发的**水平随机偏移上限**（度）。左右各取 [-此值, +此值] 内的随机值。
##
## 它是随机的（每一发都不一样），而且和俯仰一样累积、不回落，所以连发时准星会左右乱蹿，
## 越持续扫射越难控制。水平方向**没有上限**：yaw 会绕圈，硬设一个限制反而奇怪。
@export var recoil_yaw_deg: float = 0.6

## 静止/首发时的散布半径（度）。子弹不再精确地打在准星那一点上。
##
## 散布是**跟着连发长**的：每发涨 spread_per_shot_deg，停火之后按
## spread_recover_per_sec 回落。这样点射准、扫射散，压枪之外又多一层取舍。
@export var spread_min_deg: float = 0.25
## 连发散布的上限（度）。
@export var spread_max_deg: float = 2.4
## 每发让散布增长多少（度）。
@export var spread_per_shot_deg: float = 0.45
## 停火后散布的回落速度（度/秒）。
@export var spread_recover_per_sec: float = 3.2

## 站立时相机相对角色的高度（米）。下蹲时会降到 crouch_cam_y。
##
## crouch_cam_y 不能取太矮：相机一低，角色在画面上就升，蹲下时头会正好压在准星上
## （实测 1.6 时头顶到屏幕纵向 0.48，而准星在 0.50）——刚腾出来的位置又没了。
## 快照里的 headScreenY 可以核对，--shoot 模式也有一项断言守它。
@export var stand_cam_y: float = 2.5
@export var crouch_cam_y: float = 2.2
## 下蹲后的移动速度倍率。
@export var crouch_speed_scale: float = 0.45
## 下蹲后后坐力的倍率。
@export var crouch_recoil_scale: float = 0.35
## 站立↔下蹲的过渡时长（秒）。
@export var crouch_time: float = 0.18

## 刚接管鼠标后这段时间内不开火：那一次点击是用来锁定指针的，不该顺手打出一发。
const FIRE_BLOCK_AFTER_CAPTURE := 0.25

## 默认/开局俯仰（弧度）。回合重置时回到这里。
const START_PITCH := -0.22

@onready var _arm: SpringArm3D = $SpringArm
@onready var _camera: Camera3D = $SpringArm/Camera3D

const MOVE_ACTIONS := ["move_forward", "move_back", "move_left", "move_right", "jump"]

# 用 preload 而不是全局类名：headless 与 --script 模式不会写 .godot 里的全局类缓存。
const StickFigureScript := preload("res://scripts/stick_figure.gd")

# 鼠标控制的**基准**俯仰。后坐力也写进这里（它要留在原地不回落），
# 所以玩家得靠往下拖鼠标把准星压回来。正值为向上看。
var _pitch: float = START_PITCH
# 下蹲程度：0 = 站立，1 = 完全蹲下。
var _crouch := 0.0
var _gravity: float = 24.0
# 是否处于"正在操作"状态。判定标准就是鼠标是否被锁定：
# 光标还露在外面（还没点进游戏，或者刚按了 Esc）就不该能操作。
var _input_active := false

# --- 战斗状态 ---------------------------------------------------------------
var max_health := 100
var health := 100
var alive := true
var _fire_cd := 0.0
var _fire_block := 0.0
var _respawn_left := 0.0
# 已开火次数。供自动化检查确认“真的打出去了”。
var shots_fired := 0
# 出生点由 net.gd 在错开位置后告知（见 set_spawn_point）
var _spawn_pos := Vector3.ZERO
var _spawn_yaw := 0.0
var _spawn_known := false
# 当前的散布半径（度）。跟着连发增长、停火回落。
var _spread := 0.0
# 最后把自己打倒的人的编号与名字（用于记分与倒地提示）。
var _killer_id := 0
var _killer_name := ""

## 火柴人外观。样式（两套之一）由 net.gd 按进入房间的顺序决定。
var figure: StickFigureScript = null


func _ready() -> void:
	_ensure_actions()
	_gravity = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_arm.rotation.x = _pitch
	_arm.position.y = stand_cam_y
	_build_figure()
	if figure != null:
		figure.equip_gun()
	_spawn_pos = global_position
	_spawn_known = true
	# 延后一帧再推血量：HUD 在场景里排在 Player 之后，此刻它还没进 group("hud")，
	# 立即推送会找不到它，血量文字就一直是空的。
	_update_hud.call_deferred()
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
		if active:
			# 接管鼠标的那一下点击不要顺手打出一发
			_fire_block = FIRE_BLOCK_AFTER_CAPTURE
		else:
			_stop_moving()

	_fire_cd = maxf(0.0, _fire_cd - delta)
	_fire_block = maxf(0.0, _fire_block - delta)
	# 散布回落。与生死无关，所以放在存活判断之前。
	_spread = maxf(spread_min_deg, _spread - spread_recover_per_sec * delta)

	# 这两件事与生死无关（倒地时枪口姿态也要正确收尾），所以放在存活判断之前。
	_update_stance(active, delta)
	_apply_aim()

	if not alive:
		_tick_respawn(delta)
		# 倒地时不能让旧速度留着，否则尸体会滑行
		velocity.x = 0.0
		velocity.z = 0.0
		if not is_on_floor():
			velocity.y -= _gravity * delta
		move_and_slide()
		return

	var want := Vector2.ZERO
	if active:
		want = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var dir := (transform.basis * Vector3(want.x, 0.0, want.y)).normalized()
	_update_lean(want, delta)

	if not is_on_floor():
		velocity.y -= _gravity * delta
	elif active and Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity

	# 下蹲会明显拖慢移动，这样“蹲下换稳定”才有代价
	var speed := move_speed * lerpf(1.0, crouch_speed_scale, _crouch)
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed
	move_and_slide()

	# 步态用水平速度驱动：走快摆幅大、停下回直立、离地换空中姿势。
	if figure != null:
		# 持枪姿态要跟着镜头俯仰（含后坐力），否则枪口与子弹方向不一致
		figure.aim_pitch = aim_pitch()
		# figure 挂在 Player 下，所以它的 rotation.y 是"相对 Player 的偏身"，
		# 需要告诉手柄把它抵消掉（替身则相反，见 stick_figure.aim_lean 的注释）。
		figure.aim_lean = figure.rotation.y
		figure.animate(
			Vector2(velocity.x, velocity.z).length(), is_on_floor(), delta, _crouch
		)

	if active and _fire_block <= 0.0 and Input.is_action_pressed("fire"):
		_try_fire()


## 站立↔下蹲的过渡。下蹲只改相机高度与移动速度，碰撞胶囊高度不变——
## 所以现在是“视觉上的蹲”，还没法真的钻进矮掩体。要做成真下蹲得同步改胶囊。
func _update_stance(active: bool, delta: float) -> void:
	var want_crouch := active and Input.is_action_pressed("crouch") and is_on_floor()
	var target := 1.0 if want_crouch else 0.0
	var step := delta / maxf(0.01, crouch_time)
	_crouch = move_toward(_crouch, target, step)
	_arm.position.y = lerpf(stand_cam_y, crouch_cam_y, _crouch)


## 当前生效的俯仰。子弹方向与枪口都取这个值，后坐力的抬升也在其中。
func aim_pitch() -> float:
	return _pitch


func _apply_aim() -> void:
	_arm.rotation.x = aim_pitch()


## 下蹲程度（0 站、1 蹲）。供自动化检查与网络同步读取。
func crouch_amount() -> float:
	return _crouch


## 当前散布半径（度）。供自动化检查与快照读取。
func spread_amount() -> float:
	return _spread


## 开一发的后坐力：把准星往上抬一点、并左右随机偏一点，**而且都留在那里**。
##
## 唯一的边界是俯仰上限（pitch_max_deg）：一直按住不放会飘到顶，此时无法再往上。
## 水平方向没有限制（yaw 会绕圈）。不再有“累积上限 + 自行回落”那一套，
## 因为需求是“飘上去不要回原位”。
func _kick_recoil() -> void:
	var scale := lerpf(1.0, crouch_recoil_scale, _crouch)
	_pitch = clampf(
		_pitch + deg_to_rad(recoil_per_shot_deg * scale),
		deg_to_rad(pitch_min_deg), deg_to_rad(pitch_max_deg)
	)
	# 左右随机：每发独立取值，所以连发轨迹不是一条直线而是会左右乱蹿。
	rotation.y += deg_to_rad(randf_range(-recoil_yaw_deg, recoil_yaw_deg) * scale)


## 身体随方向键偏转一点，**不超过 lean_deg**。镜头不跟随这个偏转。
##
## 规则（用户指定）：**横向输入决定偏哪一侧，后退时横向镜像**。所以：
##
##   | 按键 | 移动 | 身体偏转 |
##   | --- | --- | --- |
##   | W / S | 前 / 后 | 0°（不偏） |
##   | A / WA | 左 / 左前 | 左 lean_deg |
##   | AS | 左后 | **右** lean_deg |
##   | D / WD | 右 / 右前 | 右 lean_deg |
##   | DS | 右后 | **左** lean_deg |
##
## 注意它**不随移动方向单调变化**（后退时镜像），因此不能用“身体朝移动方向、限幅”
## 这类公式表达；写成乘法而不是分支，是为了让符号关系一眼可见。
## 松手后回到直立（0°），不是保持偏转。
func _update_lean(want: Vector2, delta: float) -> void:
	if figure == null:
		return
	var target := 0.0
	if absf(want.x) > 0.01:
		# 前进一侧取负、后退一侧取正，实现“后退时镜像”。
		var backward := 1.0 if want.y > 0.0 else -1.0
		target = deg_to_rad(lean_deg) * signf(want.x) * backward
	figure.rotation.y = lerp_angle(
		figure.rotation.y, target, 1.0 - exp(-lean_rate * delta)
	)


## 火柴人当前的世界朝向（= 鼠标朝向 + 身体偏转）。
##
## 网络同步要发这个而不是 player.rotation.y：身体会偏转，只看 player 的话
## 远端看到的脸朝向会与本体不一致（相差正好是偏转角）。
func facing_yaw() -> float:
	return rotation.y + (figure.rotation.y if figure != null else 0.0)


## 镜头相对 Player 参考系多转了多少。方向键不应带动镜头，所以它应当恒为 0；
## 留这个访问器是为了让自动化检查能断言这一点。
func camera_offset_yaw() -> float:
	return _arm.rotation.y if _arm != null else 0.0


# --- 射击 -------------------------------------------------------------------

## 子弹的世界起点。取枪口而不是相机：从相机出发的射线要先穿过自己的身体。
func aim_origin() -> Vector3:
	if figure != null and figure.gun != null:
		return figure.muzzle_position()
	return global_position


## 子弹方向（单位向量）。它由**相机射线打到哪**决定，而不是直接取相机朝向。
##
## 这样做的原因：枪口在身体前方、相机的瞄准点在屏幕中心，两者有视差；
## 若直接沿相机朝向发射，近距离时子弹会偏离准星所指的目标。
## 改成“先算相机射线命中点，再从枪口朝那个点发射”，准星指哪就打哪。
func aim_direction() -> Vector3:
	var from := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	var hit := _raycast(from, dir, [self])
	var point := from + dir * max_range
	if not hit.is_empty():
		point = hit["position"]
	return (point - aim_origin()).normalized()


func _try_fire() -> void:
	# 冷却判断放在这里而不是调用处：只有一个入口，其他地方想加“顺手开一枪”也绕不过射速。
	if not alive or figure == null or figure.gun == null:
		return
	if _fire_cd > 0.0:
		return
	_fire_cd = fire_rate
	shots_fired += 1

	var from := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	var hit := _raycast(from, dir, [self])
	var point := from + dir * max_range
	if not hit.is_empty():
		point = hit["position"]

	var muzzle := figure.muzzle_position()
	var to_aim := point - muzzle
	var distance := to_aim.length()
	# 散布只改“这一发飞向哪”，起点仍是枪口。方向要**在广播之前**定下来，
	# 否则本地看到的弹道与远端重放的不是同一条。
	var shot_dir := _spread_direction(to_aim.normalized())

	# 本地特效从枪口沿这一发真实方向算，撞到墙就停在墙上。
	# 注意排除自己：枪口在身体前方，射线可能从自己的碰撞体里出发。
	var shot_hit := _raycast(muzzle, shot_dir, [self])
	var end := muzzle + shot_dir * distance
	if not shot_hit.is_empty():
		end = shot_hit["position"]

	figure.gun.flash()
	Sfx.play_local_shot()
	Fx.tracer(muzzle, end, figure.limb_color())
	if not shot_hit.is_empty():
		Fx.impact(shot_hit["position"], shot_hit["normal"], figure.limb_color())
		Sfx.play_impact(shot_hit["position"])

	# 广播的是“枪口 + 实际飞行方向”，这样远端用同一条射线重放，
	# 既不会有视差，也不会从自己的身体里穿出去。
	if Net.connected:
		Net.broadcast_fire(muzzle, shot_dir)

	# 抬准星与加大散布放在最后：子弹要飞向**开火前**瞄的那个位置，
	# 抬起来是留给下一发、以及玩家自己要压回来的那一份。
	# 写在前面的话，连第一发都会偏掉一个后坐力步长。
	_kick_recoil()
	_spread = minf(spread_max_deg, _spread + spread_per_shot_deg)


## 在方向周围取一个随机偏移，偏角最大为当前散布半径。
##
## 先绕一个与方向垂直的轴偏开一个角度，再绕方向自身转一圈：
## 直接两次“随机欧拉角”会在锥体里分布不均，而半径取 sqrt(randf()) 才能保证
## 单位面积上的概率相等（否则子弹会明显地向中心聚堆）。
func _spread_direction(dir: Vector3) -> Vector3:
	if _spread <= 0.0:
		return dir
	var cone := deg_to_rad(_spread * lerpf(1.0, crouch_recoil_scale, _crouch))
	var axis := dir.cross(Vector3.UP)
	if axis.length_squared() < 1e-6:
		# 正好垂直向上/向下时 cross 退化，换一个参考轴
		axis = dir.cross(Vector3.RIGHT)
	if axis.length_squared() < 1e-6:
		return dir
	var angle := cone * sqrt(randf())
	return dir.rotated(axis.normalized(), angle).rotated(dir, randf() * TAU)


## 收到别人开火。**由被打中的人判定命中**（本函数在被打者的客户端运行）。
##
## 为什么不用射击方判定：射击方手上的目标位置是 20 Hz 同步过来的、有延迟的旧数据，
## 8 m/s 时误差可达 40 厘米；由被打者用**自己当前位置**判定才准。
## 代价是打人的人可能看到“明明打中却掉血”，这是没有延迟补偿时的必然取舍。
func receive_shot(origin: Vector3, direction: Vector3, damage: int, shooter_id := 0) -> bool:
	if not alive:
		return false
	var hit := _raycast(origin, direction, [])
	if hit.is_empty():
		return false
	# 只认打中自己的身体。被掩体或别人挡住时，第一个命中就不是我。
	if hit["collider"] != self:
		return false
	take_damage(damage, shooter_id)
	return true


func take_damage(amount: int, killer_id := 0) -> void:
	if not alive:
		return
	health = maxi(0, health - amount)
	_killer_id = killer_id
	_killer_name = Net.player_name(killer_id) if killer_id > 0 else ""
	# 受伤的“手感”全在这一帧：红闪 + 短音 + 血条。没有延迟补偿，
	# 所以这几件事是玩家判断“我挨打了”的唯一依据。
	var hud := _hud()
	if hud != null:
		hud.call("damage_flash", 0.32)
	Sfx.play_hurt()
	_update_hud()
	if Net.connected:
		Net.broadcast_health(health)
	if health <= 0:
		_die()


## 让 net.gd 在错开出生位置之后告知出生点与朝向，重生时用。
func set_spawn_point(pos: Vector3) -> void:
	_spawn_pos = pos
	_spawn_yaw = rotation.y
	_spawn_known = true


func _die() -> void:
	alive = false
	_respawn_left = respawn_delay
	velocity = Vector3.ZERO
	if figure != null:
		# 侧倒：绕 X 倒下去（figure 的 rotation.y 由 _update_lean 改，x 是空闲的）
		figure.rotation.x = deg_to_rad(85.0)
	Sfx.play_death()
	var hud := _hud()
	if hud != null:
		hud.call("damage_flash", 0.55)
	# 记分交给 Match：它是唯一维护比分与回合的地方。这里只上报**被打者的认定**，
	# 开枪的人是谁由击杀事件告诉所有人（见 match.gd 的文件头）。
	Match.report_local_death(_killer_id)
	print("[player] 倒地")


func _tick_respawn(delta: float) -> void:
	_respawn_left -= delta
	_set_hud_down(maxf(0.0, _respawn_left))
	if _respawn_left > 0.0:
		return
	respawn()


func respawn() -> void:
	health = max_health
	alive = true
	_respawn_left = 0.0
	if _spawn_known:
		global_position = _spawn_pos
	velocity = Vector3.ZERO
	if figure != null:
		figure.rotation.x = 0.0
	Sfx.play_spawn()
	_update_hud()
	_set_hud_down(0.0)
	if Net.connected:
		Net.broadcast_health(health)
	print("[player] 重生 at ", global_position)


## 开新回合时把自己摆回开局状态：位置、朝向、准星、散布都归位。
##
## 与 respawn() 的区别在于**朝向**：局中被打倒重生时不该掰回我的准星（那会让人
## 刚重生就被动转向），而回合开始时两边都回到面对面的初始姿态才公平。
func reset_for_round() -> void:
	respawn()
	rotation.y = _spawn_yaw
	_pitch = START_PITCH
	_spread = spread_min_deg
	_apply_aim()
	if figure != null:
		figure.rotation.y = 0.0
		figure.aim_pitch = aim_pitch()


## 一次射线查询。exclude 传自己要排除的节点。
## 用它统一处理「打中掩体」与「打中角色」两种情况，掩体后的人自然打不到。
func _raycast(origin: Vector3, direction: Vector3, exclude: Array) -> Dictionary:
	var space := get_world_3d().direct_space_state
	if space == null:
		return {}
	var query := PhysicsRayQueryParameters3D.create(
		origin, origin + direction.normalized() * max_range
	)
	query.exclude = exclude
	query.collide_with_areas = false
	return space.intersect_ray(query)


# --- HUD 通信 ---------------------------------------------------------------

## HUD 在 group("hud") 里注册自己，这里按需取，不持有强引用。
func _hud() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group("hud")


func _update_hud() -> void:
	var hud := _hud()
	if hud != null:
		hud.call("set_health", health, max_health)


func _set_hud_down(seconds: float) -> void:
	var hud := _hud()
	if hud != null:
		hud.call("set_down", seconds, _killer_name)


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
		# 这里曾经叫 dash，但一直没有实现行为；现在 Shift 是下蹲。
		"crouch": [KEY_SHIFT],
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
