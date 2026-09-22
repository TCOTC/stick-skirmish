extends Node3D
## 竞技场：地板 + 掩体，全部由数据生成。
## 掩体坐标是左右、上下严格对称的，避免开局就有一方吃亏。

const FLOOR_SIZE := 40.0
const WALL_HEIGHT := 3.0
const WALL_THICKNESS := 1.0

# Vector4(中心X, 中心Z, X方向长度, Z方向长度)
const WALL_DATA: Array[Vector4] = [
	# 四角 L 形掩体
	Vector4(-13.0, -13.0, 7.0, 1.0),
	Vector4(-13.0, -13.0, 1.0, 7.0),
	Vector4(13.0, -13.0, 7.0, 1.0),
	Vector4(13.0, -13.0, 1.0, 7.0),
	Vector4(-13.0, 13.0, 7.0, 1.0),
	Vector4(-13.0, 13.0, 1.0, 7.0),
	Vector4(13.0, 13.0, 7.0, 1.0),
	Vector4(13.0, 13.0, 1.0, 7.0),
	# 中央方柱
	Vector4(0.0, 0.0, 4.0, 4.0),
	# 东西两个边掩体
	Vector4(-17.0, 0.0, 1.0, 8.0),
	Vector4(17.0, 0.0, 1.0, 8.0),
	# 南北两个边掩体
	Vector4(0.0, -17.0, 8.0, 1.0),
	Vector4(0.0, 17.0, 8.0, 1.0),
]

var _floor_mat := StandardMaterial3D.new()
var _wall_mat := StandardMaterial3D.new()


func _ready() -> void:
	_floor_mat.albedo_color = Color(0.15, 0.17, 0.21)
	_floor_mat.roughness = 0.9
	_wall_mat.albedo_color = Color(0.26, 0.30, 0.36)
	_wall_mat.roughness = 0.75

	_build_floor()
	_build_walls()
	print("[arena] floor=", FLOOR_SIZE, " 掩体+边界=", WALL_DATA.size() + 4)


func _build_floor() -> void:
	var size := Vector3(FLOOR_SIZE, 1.0, FLOOR_SIZE)
	var xform := Transform3D(Basis(), Vector3(0.0, -size.y * 0.5, 0.0))
	var body := _make_static_box(size, xform, _floor_mat, "Floor")
	add_child(body)


func _build_walls() -> void:
	var root := Node3D.new()
	root.name = "Walls"
	add_child(root)

	for i in WALL_DATA.size():
		var data := WALL_DATA[i]
		var size := Vector3(data.z, WALL_HEIGHT, data.w)
		var xform := Transform3D(Basis(), Vector3(data.x, WALL_HEIGHT * 0.5, data.y))
		root.add_child(_make_static_box(size, xform, _wall_mat, "Wall%02d" % i))

	# 场地四周围一圈薄墙，防止掉出地板
	var half := FLOOR_SIZE * 0.5
	var edges: Array[Vector4] = [
		Vector4(0.0, -half, FLOOR_SIZE, WALL_THICKNESS),
		Vector4(0.0, half, FLOOR_SIZE, WALL_THICKNESS),
		Vector4(-half, 0.0, WALL_THICKNESS, FLOOR_SIZE),
		Vector4(half, 0.0, WALL_THICKNESS, FLOOR_SIZE),
	]
	for i in edges.size():
		var e: Vector4 = edges[i]
		var size := Vector3(e.z, WALL_HEIGHT, e.w)
		var xform := Transform3D(Basis(), Vector3(e.x, WALL_HEIGHT * 0.5, e.y))
		root.add_child(_make_static_box(size, xform, _wall_mat, "Boundary%02d" % i))


## 造一个带碰撞的方盒。
## 注意：CollisionShape3D 必须是 StaticBody3D 的直接子节点，
## 中间夹一层 Node3D 的话物理引擎根本不会注册这个形状（这个坑踩过一次）。
func _make_static_box(
	size: Vector3, xform: Transform3D, material: StandardMaterial3D, node_name: String
) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.transform = xform

	var mesh_inst := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh_inst.mesh = box
	mesh_inst.material_override = material
	body.add_child(mesh_inst)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)

	return body
