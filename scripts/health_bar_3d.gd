class_name HealthBar3D
extends Node3D
## 替身头顶的血条：底色 + 填充两个方片。
##
## 【为什么不用 billboard 材质】两个方片几乎完全重合，只靠零点几毫米的偏移分先后。
## billboard 只改顶点的朝向、**不改位置**，于是那点偏移朝哪个方向取决于血条节点的旋转，
## 也就是随替身朝向变；再叠加 no_depth_test（完全不参与深度判定），
## 谁盖在谁上面就不再确定——从某些角度会看到填充被底色盖住，剩一个灰色矩形。
## 现在改成每帧自己转向相机：朝向由代码掌握，局部 +Z 明确指向相机，
## 填充只要在 +Z 上多偏一点就永远在前面，前后关系由深度测试定死。
##
## 代价是每帧一次 look_at（一个替身一次，可以忽略），换来的是不随角度出错。
##
## 填充条要**从左端开始缩**，所以填充方片挂在一个 pivot 下，
## 方片自身右移半个宽度，于是缩放 pivot 的 x 就是从左边收。

const WIDTH := 0.85
const HEIGHT := 0.12
const HEIGHT_ABOVE := 2.05   # 火柴人约 1.75 米高，放在头顶上方
## 填充相对底色的前移量。它现在**朝相机**（局部 +Z 由 look_at 保证），
## 所以不会随替身朝向变成“跑到后面去”，可以放心用几何前后关系定顺序。
const FILL_FORWARD := 0.012

var _pivot: Node3D = null
var _fill: MeshInstance3D = null
var _max_hp := 100
var _built := false


func _ready() -> void:
	position.y = HEIGHT_ABOVE
	_ensure_built()


func _process(_delta: float) -> void:
	_face_camera()


func set_health(hp: int, max_hp: int) -> void:
	# 幂等建一次：调用方往往是“add_child 之后立刻 set_health”，
	# 而那种时机下 `_ready` 还没跑（入树与就绪不是同一时刻），不先建就会访问到 null。
	_ensure_built()
	_max_hp = maxi(1, max_hp)
	var frac := clampf(float(hp) / float(_max_hp), 0.0, 1.0)
	if _pivot != null:
		_pivot.scale = Vector3(frac, 1.0, 1.0)
	if _fill != null:
		_fill.visible = frac > 0.001
	# 血量越低越红，一眼能看出谁快倒了。数值取得比“正确颜色”更艳一点：
	# 场景是夜色调，还有 tonemap，按理论值取会显得发脏。
	var mat := _fill.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = Color(0.35 + 0.65 * (1.0 - frac), 0.30 + 0.70 * frac, 0.28)


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	_build()


func _build() -> void:
	# 底色不能太黑：血量归零时填充会隐藏，只剩底色，太暗就看不见这个人已经倒了。
	add_child(_quad(Vector3(0.0, 0.0, 0.0), Vector2(WIDTH, HEIGHT),
		Color(0.10, 0.11, 0.14, 0.9)))

	_pivot = Node3D.new()
	_pivot.name = "FillPivot"
	# 朝局部 +Z 前移：look_at 让 +Z 指向相机，所以这就是“朝相机前移”
	_pivot.position = Vector3(-WIDTH * 0.5, 0.0, FILL_FORWARD)
	add_child(_pivot)

	_fill = _quad(Vector3(WIDTH * 0.5, 0.0, 0.0), Vector2(WIDTH, HEIGHT),
		Color(0.30, 0.85, 0.28))
	_pivot.add_child(_fill)


## 让血条正对相机。
##
## QuadMesh 的正面是 +Z，所以用 `use_model_front = true` 让 +Z 指向相机。
## 相机的世界位置不会与血条重合（相机在角色身后上方），所以不会出现 look_at 反向的退化。
func _face_camera() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var to_cam := cam.global_position - global_position
	if to_cam.length_squared() < 0.0001:
		return
	# 与 UP 平行时 look_at 无解：相机几乎正在头顶正上方/正下方。
	# 此时保持上一帧朝向即可，不必特殊处理——下一帧通常就恢复了。
	if absf(to_cam.normalized().dot(Vector3.UP)) > 0.999:
		return
	look_at(cam.global_position, Vector3.UP, true)


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
	# 不再 no_depth_test：否则血条会隔着墙显示，而且填充与底色的先后就没人管了。
	# 现在两者差 FILL_FORWARD，由深度测试定死顺序。
	mesh_inst.material_override = mat
	return mesh_inst
