class_name HealthBar3D
extends Node3D
## 替身头顶的血条：墨色外框 + 纸白填充。
##
## 【黑白里怎么表达血量】长度就是唯一的读数：底色画成**实心墨条**，填充画成纸白，
## 于是“还剩多少白”就是还剩多少血。不再按血量调色（绿→红）：色相在黑白风格里不存在，
## 而且同屏两个人都得能一眼读出各自的剩血。
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

const Ink := preload("res://scripts/ink.gd")

const WIDTH := 0.85
const HEIGHT := 0.12
## 墨色外框每边多出来的宽度。填充是纸白、底色是墨，所以这一圈就是“描边”。
const BORDER := 0.028
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
	_keep_height()
	_face_camera()


## 把血条保持在与宿主**世界原点**上方固定高度处。
##
## 为什么要按世界位置算，而不是用本地偏移：替身倒地时整个节点绕 X 转了 85°，
## 于是本地 (0, 2.05, 0) 会映射到“身后 2 米、贴地”——牌子会掉在地上，像是掉了。
## 宿主站立时两种算法结果完全相同（它只绕 Y 转），所以这里不会引入任何变化。
func _keep_height() -> void:
	var host := get_parent_node_3d()
	if host == null:
		return
	var pos := host.global_position
	pos.y += HEIGHT_ABOVE
	global_position = pos


## 更新血量。`frac` 会做 0..1 限制，所以传入超范围的数也不会画歪。
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


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	_build()


func _build() -> void:
	# 墨色底：比填充大一圈，于是周围留出的那圈就是描边。
	# 也不能太薄：空血时填充会隐藏，只剩这块墨，太薄就看不出这个人已经倒了。
	add_child(_quad(Vector3(0.0, 0.0, 0.0),
		Vector2(WIDTH + BORDER * 2.0, HEIGHT + BORDER * 2.0), Ink.INK))

	_pivot = Node3D.new()
	_pivot.name = "FillPivot"
	# 朝局部 +Z 前移：look_at 让 +Z 指向相机，所以这就是“朝相机前移”
	_pivot.position = Vector3(-WIDTH * 0.5, 0.0, FILL_FORWARD)
	add_child(_pivot)

	_fill = _quad(Vector3(WIDTH * 0.5, 0.0, 0.0), Vector2(WIDTH, HEIGHT), Ink.PAPER)
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

	# 用 ink.gd 的平涂材质：血条是一块牌子，不该受场景光照影响
	# （夜晚的暗光曾经把它压成一块看不出颜色的灰片）。
	mesh_inst.material_override = Ink.flat(color)
	return mesh_inst
