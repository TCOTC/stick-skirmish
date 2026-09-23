extends Node
## 短命的视觉特效：曳光与弹着点。
##
## 全部**只在本机播放**，不参与同步：每个人自己看到枪火与弹道，
## 命中的真实结果由被打中的人决定（见 net.gd 的 `_peer_fire`）。
##
## 为什么用 SceneTreeTimer + tween 而不是自己维护列表：特效是"建了就忘"的东西，
## 自己记时间很容易漏掉回收路径（对端断了、场景切了都要清）。这里交给引擎，
## 节点会在到期后自己释放。

const TRACER_TIME := 0.07     # 曳光存在时长。太短（曾用 0.045）在画面上一闪即逝，截不到也看不清
const IMPACT_TIME := 0.22
const TRACER_RADIUS := 0.013


## 从 from 画一条到 to 的细线。
func tracer(from: Vector3, to: Vector3, color: Color) -> void:
	var dir := to - from
	var length := dir.length()
	if length < 0.05:
		return

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "Tracer"
	var box := BoxMesh.new()
	box.size = Vector3(TRACER_RADIUS, TRACER_RADIUS, length)
	mesh_inst.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.5
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_inst.material_override = mat

	# looking_at 把 -Z 对准 dir；盒子沿 Z 对称，所以正负无所谓。
	mesh_inst.transform = Transform3D(
		Basis.looking_at(dir / length, Vector3.UP), from + dir * 0.5
	)
	_spawn(mesh_inst)
	_expire_after(mesh_inst, TRACER_TIME)


## 弹着点：一个亮球，迅速缩小后消失。
func impact(at: Vector3, normal: Vector3, color: Color) -> void:
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "Impact"
	var sphere := SphereMesh.new()
	sphere.radius = 0.06
	sphere.height = 0.12
	sphere.radial_segments = 8
	sphere.rings = 4
	mesh_inst.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 2.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh_inst.material_override = mat
	# 稍微离开表面，免得被它自己所在的墙面埋掉
	mesh_inst.position = at + normal.normalized() * 0.03
	_spawn(mesh_inst)

	var tween := create_tween()
	tween.tween_property(mesh_inst, "scale", Vector3.ZERO, IMPACT_TIME)
	tween.tween_callback(func() -> void:
		if is_instance_valid(mesh_inst):
			mesh_inst.queue_free()
	)


func _spawn(node: Node3D) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		# 场景还没就绪（例如 --script 自检）时，直接释放，不要抛异常
		node.queue_free()
		return
	scene.add_child(node)


func _expire_after(node: Node, seconds: float) -> void:
	get_tree().create_timer(seconds).timeout.connect(func() -> void:
		if is_instance_valid(node):
			node.queue_free()
	)
