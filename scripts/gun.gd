class_name Gun
extends Node3D
## 火柴人风格的枪：细杆 + 小方块拼成，与角色一样靠“细线 + 关节”辨识。
##
## 【朝向约定】枪沿**本地 -Y** 构造（与肢体竖杆一致）。于是把它挂到右手骨头上，
## 手臂往前伸时枪口自然朝前，不需要另算旋转。见 stick_figure.gd 的 `_aim_arm_rotation()`。
##
## 本地坐标系在“手臂前伸”后映射到角色空间：
##   -Y → 枪口方向（角色前方 -Z）
##   +Z → 枪的下方（角色 -Y），弹匣朝这边挂
##
## 膛口火光用 `flash()` 触发，靠一个计时器自动收起，不需要外部管理。

const METAL := Color(0.16, 0.17, 0.20)
const BARREL_LEN := 0.34
const BARREL_TIP := 0.44      # 枪口到握把原点的距离
const FLASH_TIME := 0.07      # 膛口火光时长，与曳光差不多，一起形成“一发的印象”

var _muzzle: Node3D = null
var _flash: MeshInstance3D = null
var _flash_left := 0.0


func _ready() -> void:
	set_process(false)   # 只有火光还亮着时才需要每帧跑


## accent 用角色样式的颜色，让枪和主人一眼能对上。
func build(accent: Color) -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

	var metal := _mat(METAL)
	var tint := _mat(accent)

	# 枪管：细杆，从握把往前伸
	_add_cylinder(Vector3(0.0, -BARREL_LEN * 0.5 - 0.05, 0.0), 0.015, BARREL_LEN, metal)
	# 机匣：握把附近的主体
	_add_box(Vector3(0.0, -0.02, 0.0), Vector3(0.05, 0.18, 0.05), metal)
	# 弹匣：朝下挂（+Z 就是枪的下方）
	_add_box(Vector3(0.0, -0.05, 0.055), Vector3(0.035, 0.10, 0.06), tint)
	# 握把：握把原点后方一点
	_add_box(Vector3(0.0, 0.05, 0.055), Vector3(0.035, 0.10, 0.05), tint)
	# 枪托：向后延伸
	_add_box(Vector3(0.0, 0.13, 0.015), Vector3(0.04, 0.13, 0.045), tint)
	# 准星：枪口前上方的小块（+Z 是下方，所以这里取负）
	_add_box(Vector3(0.0, -BARREL_TIP + 0.06, -0.025), Vector3(0.02, 0.03, 0.02), metal)

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
	var flash_mat := StandardMaterial3D.new()
	flash_mat.albedo_color = Color(1.0, 0.92, 0.62)
	flash_mat.emission_enabled = true
	flash_mat.emission = Color(1.0, 0.85, 0.45)
	flash_mat.emission_energy_multiplier = 2.0
	flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash.material_override = flash_mat
	_flash.visible = false
	add_child(_flash)


func _process(delta: float) -> void:
	_flash_left -= delta
	if _flash_left <= 0.0:
		if _flash != null:
			_flash.visible = false
		set_process(false)


## 亮一下膛口火光。连续开火时每发都会重新点亮。
func flash() -> void:
	if _flash == null:
		return
	_flash.visible = true
	_flash_left = FLASH_TIME
	set_process(true)


## 枪口的世界位置。曳光起点与射线起点都用它。
func muzzle_position() -> Vector3:
	return _muzzle.global_position if _muzzle != null else global_position


## 枪口指向（世界坐标）。子弹方向应当与它一致，自检会核对这一点。
func muzzle_forward() -> Vector3:
	if _muzzle == null:
		return -global_transform.basis.y
	return -_muzzle.global_transform.basis.y


func _mat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.55
	return mat


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
