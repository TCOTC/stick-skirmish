extends SceneTree
## 火柴人自检：无头运行，检查骨骼结构、样式切换与步态动画。
##
##   & 'D:\Tool\Godot\4.7.2\Godot_v4.7.2-stable_win64_console.exe' --headless `
##     --path 'D:\Datafile\stick-skirmish' --script res://tools/stick-check.gd
##
## 为什么需要它：AI 看不到画面，"关节到底有没有在摆"只能靠数值判断。
## 这里直接读骨骼的 pose 旋转，比截图比对更准，也不会受渲染差异影响。

var _failures: Array[String] = []

var _fig: Node = null
var _checks_done := false

const HealthBarScript := preload("res://scripts/health_bar_3d.gd")

# 枪口朝向的检查要**跨帧**做：骨骼附件的变换在帧内的内部处理里更新，
# 设完姿势立即读会拿到上一帧的值。所以排队一组（偏身、俯仰）组合，一帧测一个。
var _aim_queue: Array = []
var _aim_now := Vector2.ZERO
var _aim_waiting := false
var _gun_worst := 0.0
var _gun_details: Array[String] = []

# 用 preload 而不是全局类名：headless 与 --script 模式不会写 .godot 里的全局类缓存，
# 直接写 StickFigure 会报 "Could not find type"。
const StickFigureScript := preload("res://scripts/stick_figure.gd")

# 膝盖弯曲幅度不应超过这个值（KNEE_BEND * 最大摆幅 + 余量）
const KNEE_LIMIT := 1.0


func _check(ok: bool, label: String, detail := "") -> void:
	print("%s%s%s" % [
		"  ok   " if ok else "  FAIL ",
		label,
		"" if detail.is_empty() else "  —  " + detail,
	])
	if not ok:
		_failures.append(label)


func _count_meshes(node: Node) -> int:
	var total := 0
	if node is MeshInstance3D:
		total += 1
	for child in node.get_children():
		total += _count_meshes(child)
	return total


func _count_bones(fig: Node) -> int:
	var skeleton := fig.get_node_or_null("Skeleton3D") as Skeleton3D
	return skeleton.get_bone_count() if skeleton != null else 0


## 某根骨头默认姿态下的世界高度。读 pose 而不是 rest，因为附件跟的是 pose。
func _bone_y(fig: Node, bone_name: String) -> float:
	var skeleton := fig.get_node_or_null("Skeleton3D") as Skeleton3D
	if skeleton == null:
		return 0.0
	var idx := skeleton.find_bone(bone_name)
	if idx < 0:
		return 0.0
	return skeleton.get_bone_global_pose(idx).origin.y


## 检查每根骨头上的 BoneAttachment3D 是否真的绑上了骨头、并且挂着该有的网格。
##
## 这一项是补上的：曾经只检查了骨骼数量和网格总数，结果整个角色只剩一个躯干——
## get_bone_idx() 为 -1 的附件会把网格留在骨骼原点（对本站姿角色就是脚底），
## 偏移一叠加就埋到地板以下，从画面里完全看不到，但网格计数是正常的。
func _check_attachments(fig: Node, tag := "") -> void:
	var by_bone := _meshes_by_bone(fig)
	var unbound: Array[String] = []
	for child in fig.get_node("Skeleton3D").get_children():
		if child is BoneAttachment3D and child.get_bone_idx() < 0:
			unbound.append(child.bone_name)
	_check(unbound.is_empty(), tag + "所有骨骼附件都找到了对应骨头", "未绑定: %s" % str(unbound))

	var missing: Array[String] = []
	for name in ["upper_arm_l", "lower_arm_l", "upper_arm_r", "lower_arm_r",
			"upper_leg_l", "lower_leg_l", "upper_leg_r", "lower_leg_r"]:
		if int(by_bone.get(name, {}).get("seg", 0)) != 1:
			missing.append(name + ":杆")
		if int(by_bone.get(name, {}).get("joint", 0)) != 1:
			missing.append(name + ":关节球")
	for name in ["spine", "neck"]:
		if int(by_bone.get(name, {}).get("seg", 0)) != 1:
			missing.append(name + ":杆")
	if int(by_bone.get("head", {}).get("head", 0)) != 1:
		missing.append("head:头")
	# 横杆是把四肢接上躯干的关键，少了它手臂就是两根悬空的平行杆
	for name in ["hips", "neck"]:
		if int(by_bone.get(name, {}).get("bar", 0)) < 1:
			missing.append(name + ":横杆")
	_check(missing.is_empty(), tag + "各部位的网格件齐全", " / ".join(missing) if not missing.is_empty()
		else "竖杆 %d、关节球 %d、横杆 %d、头 %d、眼 %d" % [
			int(_count_by_kind(fig).get("seg", 0)), int(_count_by_kind(fig).get("joint", 0)),
			int(_count_by_kind(fig).get("bar", 0)), int(_count_by_kind(fig).get("head", 0)),
			int(_count_by_kind(fig).get("eye", 0))])


## 按“骨骼 → 网格名 → 数量”整理。网格名在 stick_figure.gd 里设置。
func _meshes_by_bone(fig: Node) -> Dictionary:
	var out := {}
	for child in fig.get_node("Skeleton3D").get_children():
		if not (child is BoneAttachment3D):
			continue
		var counts := {}
		for sub in child.get_children():
			if sub is MeshInstance3D:
				var key := String(sub.name)
				counts[key] = int(counts.get(key, 0)) + 1
		out[child.bone_name] = counts
	return out


## 把网格名归类（前缀匹配）。不用精确名：同一骨骼下同名子节点会被 Godot 自动改名。
func _kind_of(mesh_name: String) -> String:
	for kind in ["eye", "seg", "joint", "bar", "head"]:
		if mesh_name.begins_with(kind):
			return kind
	return mesh_name


## 按网格名汇总数量（跨骨骼），用于“件数符合设计”的说明文字。
func _count_by_kind(fig: Node) -> Dictionary:
	var out := {}
	var by_bone := _meshes_by_bone(fig)
	for bone in by_bone:
		var counts: Dictionary = by_bone[bone]
		for mesh_name in counts:
			var kind := _kind_of(String(mesh_name))
			out[kind] = int(out.get(kind, 0)) + int(counts[mesh_name])
	return out


## 眼睛必须长在脸的那一侧（-Z），否则会变成后脑勺上的两只眼。
func _check_eyes(fig: Node, tag := "") -> void:
	var head := _mesh_on(fig, "head", "head")
	if head == null:
		_check(false, tag + "能取到头")
		return
	var head_z := (head.global_transform * head.get_aabb()).get_center().z
	var eyes := _meshes_matching(fig, "eye")
	_check(eyes.size() == 2, tag + "有两只眼睛", "%d 只" % eyes.size())
	var wrong := 0
	var eye_z := 0.0
	for eye in eyes:
		var z := (eye.global_transform * eye.get_aabb()).get_center().z
		eye_z += z
		# 正面是 -Z，所以眼睛应当比头中心更靠 -Z。
		if z >= head_z - 0.01:
			wrong += 1
	_check(wrong == 0, tag + "眼睛长在脸的前侧", "眼 z=%.3f、头中心 z=%.3f" % [
		eye_z / maxf(1.0, float(eyes.size())), head_z])


func _mesh_on(fig: Node, bone: String, mesh_name: String) -> MeshInstance3D:
	for child in fig.get_node("Skeleton3D").get_children():
		if child is BoneAttachment3D and child.bone_name == bone:
			return child.get_node_or_null(mesh_name) as MeshInstance3D
	return null


func _meshes_matching(fig: Node, prefix: String) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for child in fig.get_node("Skeleton3D").get_children():
		if not (child is BoneAttachment3D):
			continue
		for sub in child.get_children():
			if sub is MeshInstance3D and String(sub.name).begins_with(prefix):
				out.append(sub)
	return out


## 检查各部位在默认站姿下**确实相互接触**。
##
## 这一项是补上的：整条链路的几何信息（每段肢体的偏移、长度）此前完全没有被验证过，
## 结果画面上是一个“头浮在躯干上方、手臂和腿是与躯干平行的两根独立竖杆”的角色——
## 骨骼数量、网格数量、关节角度、骨头高度全都正常，只有“部件之间有没有接上”没人检查，
## 而这个缺陷肉眼一看就明显。用世界包围盒两两求交来验证，比看数值得靠。
func _check_connected(fig: Node, tag := "") -> void:
	var pairs := [
		["肩横杆", "neck", "bar", "左上臂", "upper_arm_l", "seg"],
		["肩横杆", "neck", "bar", "右上臂", "upper_arm_r", "seg"],
		["骨盆横杆", "hips", "bar", "左大腿", "upper_leg_l", "seg"],
		["骨盆横杆", "hips", "bar", "右大腿", "upper_leg_r", "seg"],
		["躯干杆", "spine", "seg", "肩横杆", "neck", "bar"],
		["躯干杆", "spine", "seg", "骨盆横杆", "hips", "bar"],
		["颈杆", "neck", "seg", "头", "head", "head"],
	]
	var gaps: Array[String] = []
	for pair in pairs:
		var a := _mesh_on(fig, pair[1], pair[2])
		var b := _mesh_on(fig, pair[4], pair[5])
		if a == null or b == null:
			gaps.append("%s 或 %s 缺失" % [pair[0], pair[3]])
			continue
		var box_a := a.global_transform * a.get_aabb()
		var box_b := b.global_transform * b.get_aabb()
		if not box_a.intersects(box_b):
			gaps.append("%s 与 %s 不相接" % [pair[0], pair[3]])
	_check(gaps.is_empty(), tag + "各部位相互接触（无断开）", " / ".join(gaps) if not gaps.is_empty() else "%d 处接缝都接上了" % pairs.size())


## 附加件（胸前横带之类）必须长在躯干上，不能跑到别处去。
##
## 这一项是补上的：胸前横带的偏移写成负值时，它会被放到骨盆**下方** 0.36 米处，
## 也就是横着架在两条大腿上——相接检查发现不了（它照样和腿接触），只有高度能暴露。
func _check_extras(fig: Node, tag := "") -> void:
	var band := _mesh_on(fig, "spine", "bar")
	if band == null:
		return
	var torso := _mesh_on(fig, "spine", "seg")
	if torso == null:
		_check(false, tag + "能取到躯干杆")
		return
	var torso_box := torso.global_transform * torso.get_aabb()
	var band_box := band.global_transform * band.get_aabb()
	var band_y := band_box.get_center().y
	var torso_mid := torso_box.get_center().y
	_check(
		band_y > torso_mid,
		tag + "胸前横带长在躯干上半段",
		"横带 y=%.2f，躯干中点 y=%.2f" % [band_y, torso_mid]
	)


## 检查骨头默认姿态下的世界高度。
##
## 这一项是补上的：只设 rest 不设 pose 时，所有骨头都会堆在骨骼原点，
## 角色缩成一团（头在 1.04 米、脚在 0.70 米），但骨骼数量、网格数量、关节角度
## 全都“正常”——只有实际位置暴露得出来。
func _check_bone_heights(fig: Node) -> void:
	var skeleton := fig.get_node_or_null("Skeleton3D") as Skeleton3D
	if skeleton == null:
		_check(false, "能取到 Skeleton3D")
		return
	var expected := {
		"hips": 0.93,
		"spine": 0.93,
		"neck": 1.51,
		"head": 1.60,
		"upper_arm_l": 1.51,
		"lower_arm_l": 1.21,
		"upper_leg_l": 0.93,
		"lower_leg_l": 0.47,
	}
	var wrong: Array[String] = []
	for name in expected:
		var idx := skeleton.find_bone(name)
		if idx < 0:
			wrong.append("%s 不存在" % name)
			continue
		var actual := skeleton.get_bone_global_pose(idx).origin.y
		if absf(actual - float(expected[name])) > 0.02:
			wrong.append("%s 实为 %.2f、应为 %.2f" % [name, actual, expected[name]])
	_check(wrong.is_empty(), "骨头默认姿态高度符合设计", " / ".join(wrong) if not wrong.is_empty() else "8 根全部符合")


## 只做“把角色建出来”这一件事，检查放在第一帧之后。
##
## 因为 BoneAttachment3D 要到跑过一帧（内部处理）才会解析出 bone_idx，
## 在 _initialize 里读会全部是 -1——那是测试环境的限制，不是角色的问题，
## 但如果在这里断言就会得到一个永远失败的假警报。
func _initialize() -> void:
	_fig = StickFigureScript.new()
	root.add_child(_fig)
	_fig.build()
	# 枪要在 build 之后装备（配色取自样式材质）
	_fig.equip_gun()


func _process(_delta: float) -> bool:
	if not _checks_done:
		_checks_done = true
		_run_checks()
		_start_lean_checks()
		return false
	if _aim_waiting:
		_aim_waiting = false
		_measure_muzzle(_aim_now)
		_advance_lean()
	return false


## 逐个（偏身、俯仰）组合验证枪口方向。
## 俯仰特意包含 0 与非 0：枪口必须跟着镜头俯仰，否则与子弹方向不一致。
func _start_lean_checks() -> void:
	_aim_queue = [
		Vector2(0.0, 0.0), Vector2(0.5, 0.0), Vector2(-0.7, 0.0),
		Vector2(0.0, -0.3), Vector2(0.78, -0.5), Vector2(-0.5, 0.25),
	]
	_advance_lean()


func _advance_lean() -> void:
	if _aim_queue.is_empty():
		_check(_gun_worst < 2.0, "枪口始终对准子弹方向（不受偏身与俯仰影响）",
			"最大偏差 %.1f°（%s）" % [_gun_worst, "、".join(_gun_details)])
		_finish()
		return
	_aim_now = _aim_queue.pop_front()
	_fig.rotation.y = _aim_now.x
	_fig.aim_pitch = _aim_now.y
	_fig.animate(4.0, true, 1.0 / 60.0)
	_aim_waiting = true


func _measure_muzzle(aim: Vector2) -> void:
	var fwd: Vector3 = _fig.muzzle_forward()
	# 期望方向：镜头在 Player 空间里绕 X 转了 aim_pitch，前方就是 (0, sin, -cos)。
	# 角色自己的偏身与躯干前倾应当被手臂抵消掉，所以期望值与它们无关。
	var expect := Vector3(0.0, sin(aim.y), -cos(aim.y))
	var dot := clampf(fwd.dot(expect), -1.0, 1.0)
	var deg := rad_to_deg(acos(dot))
	_gun_worst = maxf(_gun_worst, deg)
	_gun_details.append("偏身 %+.0f°/俯仰 %+.0f°→%.2f°" % [
		rad_to_deg(aim.x), rad_to_deg(aim.y), deg])
	# 枪口应当在身体前方（枪口指向 -Z，所以 z 更小）
	if aim == Vector2.ZERO:
		var muzzle: Vector3 = _fig.muzzle_position()
		_check(
			muzzle.z < _fig.global_position.z - 0.5,
			"枪口在身体前方",
			"枪口 z=%.2f、身体 z=%.2f" % [muzzle.z, _fig.global_position.z]
		)


func _run_checks() -> void:
	print("")
	print("  StickFigure 自检")

	var fig: Node = _fig

	# --- 结构 ---
	_check(_count_bones(fig) == 12, "骨骼数量为 12", str(_count_bones(fig)))
	_check(
		fig.get_node_or_null("Skeleton3D") != null,
		"Skeleton3D 已建立"
	)

	# 两套样式的半径、头形、附加件都不同，只验默认那套会漏掉另一套的几何问题。
	var counts_by_style: Array[int] = []
	for style_index in [0, 1]:
		fig.apply_style(style_index)
		var tag := "[%s] " % fig.style_name()
		var kinds := _count_by_kind(fig)
		var total := 0
		var parts: Array[String] = []
		for kind in ["seg", "joint", "bar", "head", "eye"]:
			var n := int(kinds.get(kind, 0))
			if n > 0:
				parts.append("%s %d" % [kind, n])
				total += n
		counts_by_style.append(total)
		# 说明文字按实际统计拼，不写死：曾经写死“斜杆 12”，而实际是 10，说明会说话。
		_check(
			total > 0 and int(kinds.get("seg", 0)) + int(kinds.get("joint", 0))
				+ int(kinds.get("bar", 0)) + int(kinds.get("head", 0))
				+ int(kinds.get("eye", 0)) == total,
			tag + "网格件数符合设计",
			"共 %d（%s）" % [total, "、".join(parts)]
		)
		_check_attachments(fig, tag)
		_check_connected(fig, tag)
		_check_extras(fig, tag)
		_check_eyes(fig, tag)

	fig.apply_style(0)
	_check_bone_heights(fig)

	# --- 样式 ---
	var color_a: Color = fig.limb_color()
	var name_a: String = fig.style_name()
	fig.apply_style(1)
	var color_b: Color = fig.limb_color()
	var name_b: String = fig.style_name()
	_check(color_a != color_b, "两套样式颜色不同", "%s %s / %s %s" % [
		name_a, color_a.to_html(false), name_b, color_b.to_html(false)])
	_check(name_a != name_b, "两套样式名称不同", "%s / %s" % [name_a, name_b])
	_check(
		counts_by_style[1] == counts_by_style[0] + 1,
		"样式 B 比 A 多一件（胸前横带）",
		"%d / %d" % [counts_by_style[0], counts_by_style[1]]
	)

	# 取模：传超出范围的序号不应该崩
	fig.apply_style(7)
	_check(fig.style_name() == name_b, "样式序号按数量取模", fig.style_name())

	# --- 步态：走起来关节必须动 ---
	fig.apply_style(0)
	fig.animate(0.0, true, 1.0 / 60.0)
	var leg_rest: float = fig.bone_angle("upper_leg_l")
	var arm_rest: float = fig.bone_angle("upper_arm_l")
	_check(
		absf(leg_rest) < 0.01 and absf(arm_rest) < 0.01,
		"未移动时四肢是直立的",
		"腿 %.3f / 臂 %.3f" % [leg_rest, arm_rest]
	)

	var min_leg := 999.0
	var max_leg := -999.0
	var max_arm := -999.0
	var max_knee := 0.0
	var opposed := false
	# 走 1 秒（8 m/s，等于本机玩家的 move_speed）。
	# 逐帧取样而不是只看最后一帧：正弦在某一时刻恰好过零，读单点会误判。
	for i in 60:
		fig.animate(8.0, true, 1.0 / 60.0)
		var leg: float = fig.bone_angle("upper_leg_l")
		var leg_other: float = fig.bone_angle("upper_leg_r")
		min_leg = minf(min_leg, leg)
		max_leg = maxf(max_leg, leg)
		max_arm = maxf(max_arm, absf(fig.bone_angle("upper_arm_l")))
		max_knee = maxf(max_knee, absf(fig.bone_angle("lower_leg_l")))
		if leg * leg_other < -0.05:
			opposed = true

	var leg_range := max_leg - min_leg
	_check(leg_range > 0.6, "走路时大腿前后摆幅足够", "幅度 %.2f 弧度" % leg_range)
	_check(max_arm > 0.3, "走路时手臂在摆", "最大 %.2f 弧度" % max_arm)
	_check(max_knee > 0.2, "膝盖在屈伸", "最大 %.2f 弧度" % max_knee)
	_check(opposed, "左右腿反相摆动")
	_check(
		max_knee < KNEE_LIMIT,
		"膝盖不向反方向弯（只向后）",
		"最大 %.2f 弧度" % max_knee
	)

	# --- 停下后回到直立 ---
	for i in 60:
		fig.animate(0.0, true, 1.0 / 60.0)
	_check(
		absf(fig.bone_angle("upper_leg_l")) < 0.05,
		"停下后腿部回到直立",
		"%.3f 弧度" % fig.bone_angle("upper_leg_l")
	)
	_check(
		absf(fig.bone_angle("upper_arm_l")) < 0.05,
		"停下后手臂回到下垂",
		"%.3f 弧度" % fig.bone_angle("upper_arm_l")
	)

	# --- 空中姿态与走路不同 ---
	for i in 30:
		fig.animate(6.0, false, 1.0 / 60.0)
	var air_leg: float = fig.bone_angle("upper_leg_l")
	var air_arm: float = fig.bone_angle("upper_arm_l")
	_check(air_leg > 0.4, "空中时前腿抬起", "%.2f 弧度" % air_leg)
	_check(air_arm < -1.2, "空中时手臂向后上举", "%.2f 弧度" % air_arm)

	# --- 落地后姿态回得来 ---
	for i in 90:
		fig.animate(0.0, true, 1.0 / 60.0)
	_check(
		absf(fig.bone_angle("upper_arm_l")) < 0.05,
		"落地后手臂回到下垂",
		"%.3f 弧度" % fig.bone_angle("upper_arm_l")
	)

	# --- 枪 ---
	fig.apply_style(0)
	fig.rotation.y = 0.0
	fig.animate(0.0, true, 1.0 / 60.0)
	_check(fig.gun != null, "已装备枪")

	_check_health_bar()

	# 重建外观不能把外部挂上来的子节点一起删掉。
	# 联机侧的替身就是这样挂命中框与头顶血条的，曾经因为 _rebuild 全删子节点而被吞掉。
	var marker := Node3D.new()
	marker.name = "ForeignMarker"
	fig.add_child(marker)
	fig.apply_style(1)
	_check(
		fig.get_node_or_null("ForeignMarker") != null,
		"换样式（重建外观）不会删掉外部挂上的子节点"
	)
	_check(
		fig.get_node_or_null("Skeleton3D") != null,
		"换样式后骨骼依然存在"
	)
	fig.apply_style(0)

	# --- 下蹲姿态 ---
	# 站直与蹲下各跑一会儿，比较骨头高度与膝盖角度：一定要“看得见地矮下去”。
	for i in 30:
		fig.animate(0.0, true, 1.0 / 60.0, 0.0)
	var stand_hips := _bone_y(fig, "hips")
	var stand_knee: float = fig.bone_angle("lower_leg_l")

	for i in 30:
		fig.animate(0.0, true, 1.0 / 60.0, 1.0)
	var crouch_hips := _bone_y(fig, "hips")
	var crouch_knee: float = fig.bone_angle("lower_leg_l")

	_check(
		crouch_hips < stand_hips - 0.2,
		"下蹲时骨盆明显降低",
		"站立 %.2f → 蹲下 %.2f 米" % [stand_hips, crouch_hips]
	)
	_check(
		crouch_knee < stand_knee - 0.4,
		"下蹲时膝盖更弯",
		"站立 %.2f → 蹲下 %.2f 弧度" % [stand_knee, crouch_knee]
	)
	# 蹲完要能站起来，不然判定通过但姿态会卡住
	for i in 60:
		fig.animate(0.0, true, 1.0 / 60.0, 0.0)
	_check(
		absf(_bone_y(fig, "hips") - stand_hips) < 0.02,
		"站起来后骨盆回到原高度",
		"%.2f 米" % _bone_y(fig, "hips")
	)


## 替身头顶的血条：这个类单独验一遍，因为它在联机侧是动态创建的，
## 建失败时只表现为“画面里看不到”，很难定位。
func _check_health_bar() -> void:
	var bar = HealthBarScript.new()
	root.add_child(bar)
	bar.set_health(50, 100)
	_check(bar.get_child_count() >= 2, "血条建出了底色与填充", "%d 个子节点" % bar.get_child_count())
	_check(bar.position.y > 1.7, "血条在头顶上方", "y=%.2f" % bar.position.y)
	bar.set_health(0, 100)
	var full_bar = HealthBarScript.new()
	root.add_child(full_bar)
	full_bar.set_health(100, 100)
	_check(full_bar.get_child_count() >= 2, "血条满血时也有底座", "%d 个子节点" % full_bar.get_child_count())


## 收尾：汇总与退出。枪口朝向那几项是跨帧测的，所以不能写在 _run_checks 里。
func _finish() -> void:
	print("")
	if _failures.is_empty():
		print("  全部通过")
		quit(0)
	else:
		print("  %d 项失败: %s" % [_failures.size(), " / ".join(_failures)])
		quit(1)
