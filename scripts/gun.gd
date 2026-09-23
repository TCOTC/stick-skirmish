class_name Gun
extends Node3D
## 火柴人风格的枪：细杆 + 小方块拼成，与角色一样靠“结构件 + 墨线”辨识。
##
## 【颜色】零件只有两种：**纸白**（枪管、机匣、准星）与**主人的墨水色**（弹匣、握把、
## 枪托）。不再有“金属灰 + 彩色点缀”——黑白线稿里由墨线的位置而非色相区分零件。
##
## 【朝向约定】枪沿**本地 -Y** 构造（与肢体一致）。于是把它挂到右手骨头上，
## 手臂往前伸时枪口自然朝前，不需要另算旋转。见 stick_figure.gd 的 `_aim_arm_rotation()`。
##
## 本地坐标系在“手臂前伸”后映射到角色空间：
##   -Y → 枪口方向（角色前方 -Z）
##   +Z → 枪的下方（角色 -Y），弹匣朝这边挂
##
## 膛口火光用 `flash()` 触发，靠一个计时器自动收起，不需要外部管理。

const Ink := preload("res://scripts/ink.gd")

const BARREL_LEN := 0.34
const BARREL_TIP := 0.44      # 枪口到握把原点的距离
const FLASH_TIME := 0.07      # 膛口火光时长，与曳光差不多，一起形成“一发的印象”

## 开火那一瞬间枪身往后退的量（米）。枪沿本地 -Y 指向前方，所以 +Y 就是“往后退”。
## 它只是视觉上的跳动：子弹方向与枪口位置都不取这个偏移（否则曳光会跟着抽一下）。
const KICK := 0.03
## 回位速度（米/秒）。
const KICK_RECOVER := 0.42

var _muzzle: Node3D = null
var _flash: MeshInstance3D = null
var _flash_left := 0.0
# 握把相对手的位置。kick 是在它之上的偏移，回位就是回到它。
var _rest := Vector3.ZERO
var _kick := 0.0


func _ready() -> void:
	set_process(false)   # 只有火光还亮着或还在回位时才需要每帧跑


## 造出这把枪。`ink` 是主人的墨水色（见 stick_figure.ink_color）。
func build(ink: Color) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	# 调用方已经把这把枪摆到手上了（见 stick_figure._attach_gun），记下来当回位的目标。
	_kick = 0.0
	_rest = position

	var paper := Ink.paper(Ink.PAPER, Ink.OUTLINE_PART)
	var dark := Ink.paper(ink, Ink.OUTLINE_PART)

	# 枪管与机匣用**墨水色**、握把那一系用纸白：
	# 反过来（白枪管 + 黑握把）在远处就是一手白色里的一小团白，看不出手里有东西。
	# 深色主体在白手与白背景之间一下子就能读出来，这是第三人称下判断枪口朝向的前提。
	_add_cylinder(Vector3(0.0, -BARREL_LEN * 0.5 - 0.05, 0.0), 0.015, BARREL_LEN, dark)
	_add_box(Vector3(0.0, -0.02, 0.0), Vector3(0.05, 0.18, 0.05), dark)
	# 弹匣：朝下挂（+Z 就是枪的下方）
	_add_box(Vector3(0.0, -0.05, 0.055), Vector3(0.035, 0.10, 0.06), paper)
	# 握把：握把原点后方一点
	_add_box(Vector3(0.0, 0.05, 0.055), Vector3(0.035, 0.10, 0.05), paper)
	# 枪托：向后延伸
	_add_box(Vector3(0.0, 0.13, 0.015), Vector3(0.04, 0.13, 0.045), paper)
	# 准星：枪口前上方的小块（+Z 是下方，所以这里取负）
	_add_box(Vector3(0.0, -BARREL_TIP + 0.06, -0.025), Vector3(0.02, 0.03, 0.02), dark)

	# 枪口节点：曳光/命中判定从这里出发
	_muzzle = Node3D.new()
	_muzzle.name = "Muzzle"
	_muzzle.position = Vector3(0.0, -BARREL_TIP, 0.0)
	add_child(_muzzle)

	# 膛口火光：一个朝前的小锥体，默认藏着
	_flash = MeshInstance3D.new()
	_flash.name = "MuzzleFlash"
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.045
	cone.height = 0.14
	cone.radial_segments = 6
	cone.rings = 1
	_flash.mesh = cone
	# 锥体默认沿 Y、尖端在 +Y；绕 X 转 180 度让尖端指向 -Y（枪口方向）
	_flash.rotation.x = PI
	_flash.position = Vector3(0.0, -BARREL_TIP - 0.06, 0.0)
	# 黑白里的枪火用**墨**：纸白的火光在白底上什么也看不见，
	# 而一块射出的墨迹反而最像手绘的“砰”。
	_flash.material_override = Ink.flat(Ink.INK)
	_flash.visible = false
	add_child(_flash)


func _process(delta: float) -> void:
	_flash_left -= delta
	if _flash_left <= 0.0:
		if _flash != null:
			_flash.visible = false
	# 后退量线性回位
	if _kick > 0.0:
		_kick = maxf(0.0, _kick - KICK_RECOVER * delta)
		position = _rest + Vector3(0.0, _kick, 0.0)
	if _flash_left <= 0.0 and _kick <= 0.0:
		set_process(false)


## 亮一下膛口火光，并让枪身后退一点。连续开火时每发都会重新点亮。
func flash() -> void:
	if _flash == null:
		return
	_flash.visible = true
	_flash_left = FLASH_TIME
	_kick = KICK
	position = _rest + Vector3(0.0, _kick, 0.0)
	set_process(true)


## 枪口的世界位置。曳光起点与射线起点都用它。
func muzzle_position() -> Vector3:
	return _muzzle.global_position if _muzzle != null else global_position


## 枪口指向（世界坐标）。子弹方向应当与它一致，自检会核对这一点。
func muzzle_forward() -> Vector3:
	if _muzzle == null:
		return -global_transform.basis.y
	return -_muzzle.global_transform.basis.y


func _add_cylinder(offset: Vector3, radius: float, length: float, mat: Material) -> void:
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "part"
	var cyl := CylinderMesh.new()
	cyl.height = length
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.radial_segments = 6
	cyl.rings = 1
	mesh_inst.mesh = cyl
	mesh_inst.position = offset
	mesh_inst.material_override = mat
	add_child(mesh_inst)


func _add_box(offset: Vector3, size: Vector3, mat: Material) -> void:
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "part"
	var box := BoxMesh.new()
	box.size = size
	mesh_inst.mesh = box
	mesh_inst.position = offset
	mesh_inst.material_override = mat
	add_child(mesh_inst)
