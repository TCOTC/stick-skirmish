extends Node3D
## 竞技场：地板 + 掩体，全部由数据生成。掩体坐标左右、上下严格对称，避免开局就有一方吃亏。
##
## 【外观：黑白线稿】所有实体都是纸白的方盒，**每一道棱与每一个角都画一条墨线**。
## 线的做法不是描边材质（反壳只能给出外轮廓），而是直接摆细长的墨色方条：
## 12 条棱 + 8 个角上的小方块，合起来才叫“边缘和角落有黑色描边”。
##
## 全部面与线**合并成两个网格**（纸白一个、墨线一个），而不是每根线一个节点：
## 17 个掩体 × (1 面 + 20 线) 会是 350 多个 MeshInstance3D，在 WebGL2 下全是独立的
## 绘制调用。合并之后无论加多少掩体，绘制调用都只有 2 次。
##
## 【碰撞与外观分离】外观是纯视觉的 MeshInstance3D（没有碰撞），物理形状仍是
## 一盒一个 StaticBody3D。地板网格线特意不做碰撞：它是画上去的辅助线，不是凸起，
## 有碰撞会让射线打在离地 8 毫米的“线”上。

const Ink := preload("res://scripts/ink.gd")

const FLOOR_SIZE := 40.0
const WALL_HEIGHT := 3.0
const WALL_THICKNESS := 1.0

## 墨线宽度（米）。整套观感全在这条线的粗细上：
## 细于 1 厘米在远处会断成虚线，粗于 3 厘米近看就是“方盒外面套了个黑框”。
const EDGE := 0.022
## 角上的小方块 = EDGE × 这个倍数。手绘线条在拐角处会积墨，加粗一点就出来了。
const CORNER_SCALE := 1.7
## 地板网格的间距与线宽。空白地板没有深度线索，人眼判断不了距离，
## 方格纸式的网格同时解决了这个与“手绘”两件事。
const GRID_STEP := 4.0
const GRID_LINE := 0.016
## 网格线的高度（贴地抬高一点点，避免与地面 z-fighting）。
const GRID_LIFT := 0.004

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

var _paper := SurfaceTool.new()
var _ink := SurfaceTool.new()
# 画了多少条墨线（棱 + 角 + 网格）。供自动化检查确认“描边真的建出来了”。
var _ink_marks := 0


func _ready() -> void:
	_paper.begin(Mesh.PRIMITIVE_TRIANGLES)
	_ink.begin(Mesh.PRIMITIVE_TRIANGLES)

	_build_floor()
	_build_walls()
	_commit()

	print("[arena] floor=", FLOOR_SIZE, " 掩体+边界=", WALL_DATA.size() + 4,
		" 墨线=", _ink_marks)


## 把两个 SurfaceTool 提交成两个 MeshInstance3D。
## 材质用 material_override：合并后的网格只有一个面，正好一种材质。
func _commit() -> void:
	var paper_inst := MeshInstance3D.new()
	paper_inst.name = "Surfaces"
	paper_inst.mesh = _paper.commit()
	paper_inst.material_override = Ink.paper()
	paper_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(paper_inst)

	var ink_inst := MeshInstance3D.new()
	ink_inst.name = "InkLines"
	ink_inst.mesh = _ink.commit()
	# 墨线平涂不受光：线的深浅不该随太阳角度变（手绘的线没有明暗）
	ink_inst.material_override = Ink.flat(Ink.INK)
	ink_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ink_inst)


## 把一个方盒面加进纸白网格。
func _add_solid(size: Vector3, xform: Transform3D) -> void:
	var box := BoxMesh.new()
	box.size = size
	_paper.append_from(box, 0, xform)


## 把一条棱线/角标加进墨线网格。细长方条是这套线稿里唯一的几何原语。
func _add_mark(size: Vector3, xform: Transform3D) -> void:
	var box := BoxMesh.new()
	box.size = size
	_ink.append_from(box, 0, xform)
	_ink_marks += 1


## 一个方盒的 12 条棱 + 8 个角。
##
## 棱线长度取“整边 + 线宽”：相邻两条棱在角上会互相搭上，不留缝；
## 角上的小方块再把交会处加粗，形成手绘的“积墨”感。
func _add_box_marks(size: Vector3, xform: Transform3D) -> void:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5
	var inner := size + Vector3(EDGE, EDGE, EDGE)

	# 沿 X 的 4 条（上/下 × 前/后）
	for y in [-hy, hy]:
		for z in [-hz, hz]:
			_add_mark(Vector3(inner.x, EDGE, EDGE), xform * _at(Vector3(0.0, y, z)))
	# 沿 Y 的 4 条
	for x in [-hx, hx]:
		for z in [-hz, hz]:
			_add_mark(Vector3(EDGE, inner.y, EDGE), xform * _at(Vector3(x, 0.0, z)))
	# 沿 Z 的 4 条
	for x in [-hx, hx]:
		for y in [-hy, hy]:
			_add_mark(Vector3(EDGE, EDGE, inner.z), xform * _at(Vector3(x, y, 0.0)))

	# 8 个角
	var corner := EDGE * CORNER_SCALE
	for x in [-hx, hx]:
		for y in [-hy, hy]:
			for z in [-hz, hz]:
				_add_mark(Vector3(corner, corner, corner), xform * _at(Vector3(x, y, z)))


## 地板网格：方格纸式的辅助线。既是深度线索，也是“手绘”观感的一部分。
## 只有视觉、没有碰撞——它是画上去的线，不是地上的阶梯。
func _add_floor_grid() -> void:
	var steps := int(ceil(FLOOR_SIZE / GRID_STEP * 0.5))
	for i in range(-steps, steps + 1):
		var offset := float(i) * GRID_STEP
		_add_mark(Vector3(FLOOR_SIZE, GRID_LIFT, GRID_LINE),
			_at(Vector3(0.0, GRID_LIFT * 0.5, offset)))
		_add_mark(Vector3(GRID_LINE, GRID_LIFT, FLOOR_SIZE),
			_at(Vector3(offset, GRID_LIFT * 0.5, 0.0)))


func _at(offset: Vector3) -> Transform3D:
	return Transform3D(Basis(), offset)


## 画出来的墨线数量（棱 + 角 + 地板网格）。供 tools/art-check.gd 断言描边真的建出来了。
func ink_marks() -> int:
	return _ink_marks


func _build_floor() -> void:
	var size := Vector3(FLOOR_SIZE, 1.0, FLOOR_SIZE)
	var xform := Transform3D(Basis(), Vector3(0.0, -size.y * 0.5, 0.0))
	# 地板自身不画棱线：它的四边正好被场地围墙压住，画了也看不见。
	_add_solid(size, xform)
	_add_floor_grid()
	add_child(_make_static_box(size, xform, "Floor"))


func _build_walls() -> void:
	var root := Node3D.new()
	root.name = "Walls"
	add_child(root)

	for i in WALL_DATA.size():
		var data := WALL_DATA[i]
		var size := Vector3(data.z, WALL_HEIGHT, data.w)
		var xform := Transform3D(Basis(), Vector3(data.x, WALL_HEIGHT * 0.5, data.y))
		_add_solid(size, xform)
		_add_box_marks(size, xform)
		root.add_child(_make_static_box(size, xform, "Wall%02d" % i))

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
		_add_solid(size, xform)
		_add_box_marks(size, xform)
		root.add_child(_make_static_box(size, xform, "Boundary%02d" % i))


## 造一个带碰撞的方盒。外观不在这里，由 `_add_solid` / `_add_box_marks` 负责。
## 注意：CollisionShape3D 必须是 StaticBody3D 的直接子节点，
## 中间夹一层 Node3D 的话物理引擎根本不会注册这个形状（这个坑踩过一次）。
func _make_static_box(size: Vector3, xform: Transform3D, node_name: String) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.transform = xform

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	body.add_child(col)

	return body
