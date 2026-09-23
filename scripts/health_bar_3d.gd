class_name HealthBar3D
extends Node3D
## 替身头顶的血条：底色 + 填充两个方片，材质开 billboard，自动面向镜头。
##
## 为什么用 billboard 材质而不是每帧算朝向：省掉每帧的矩阵运算，
## 而且不用去拿相机引用（替身由 net.gd 管，拿相机要多一层依赖）。
##
## 填充条要**从左端开始缩**，所以填充方片挂在一个 pivot 下，
## 方片自身右移半个宽度，于是缩放 pivot 的 x 就是从左边收。

const WIDTH := 0.85
const HEIGHT := 0.12
const HEIGHT_ABOVE := 2.05   # 火柴人约 1.75 米高，放在头顶上方

var _pivot: Node3D = null
var _fill: MeshInstance3D = null
var _max_hp := 100


func _ready() -> void:
	position.y = HEIGHT_ABOVE
	_build()


func set_health(hp: int, max_hp: int) -> void:
	_max_hp = maxi(1, max_hp)
	var frac := clampf(float(hp) / float(_max_hp), 0.0, 1.0)
	if _pivot != null:
		_pivot.scale = Vector3(frac, 1.0, 1.0)
	if _fill != null:
		_fill.visible = frac > 0.001
	# 血量越低越红，一眼能看出谁快倒了。数值取得比“正确颜色”更艳一点：
	# 场景是夜色调，还有滤镜式 tonemap，按理论值取会显得发脏。
	var mat := _fill.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = Color(0.35 + 0.65 * (1.0 - frac), 0.30 + 0.70 * frac, 0.28)


func _build() -> void:
	# 底色不能太黑：血量归零时填充会隐藏，只剩底色，太暗就看不见这个人已经倒了。
	add_child(_quad(Vector3(0.0, 0.0, 0.0), Vector2(WIDTH, HEIGHT),
		Color(0.10, 0.11, 0.14, 0.9)))

	_pivot = Node3D.new()
	_pivot.name = "FillPivot"
	_pivot.position = Vector3(-WIDTH * 0.5, 0.0, 0.004)   # 稍微靠前，压在底色上
	add_child(_pivot)

	_fill = _quad(Vector3(WIDTH * 0.5, 0.0, 0.0), Vector2(WIDTH, HEIGHT),
		Color(0.30, 0.85, 0.28))
	_pivot.add_child(_fill)


func _quad(offset: Vector3, size: Vector2, color: Color) -> MeshInstance3D:
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "quad"
	var quad := QuadMesh.new()
	quad.size = size
	mesh_inst.mesh = quad
	mesh_inst.position = offset
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	# 血条是界面信息，不该被墙挡住看不到
	mat.no_depth_test = true
	mesh_inst.material_override = mat
	return mesh_inst
