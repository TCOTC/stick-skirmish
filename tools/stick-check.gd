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
	_check(missing.is_empty(), tag + "各部位的网格件齐全", " / ".join(missing) if not missing.is_empty() else "斜杆 12、关节球 8、横杆 2、头 1")


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


func _mesh_on(fig: Node, bone: String, mesh_name: String) -> MeshInstance3D:
	for child in fig.get_node("Skeleton3D").get_children():
		if child is BoneAttachment3D and child.bone_name == bone:
			return child.get_node_or_null(mesh_name) as MeshInstance3D
	return null


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


func _process(_delta: float) -> bool:
	if _checks_done:
		return false
	_checks_done = true
	_run_checks()
	return false


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
	for style_index in [0, 1]:
		fig.apply_style(style_index)
		var tag := "[%s] " % fig.style_name()
		_check(
			_count_meshes(fig) >= 22,
			tag + "网格件数符合设计（斜杆 12 + 关节球 8 + 横杆 2 + 头 1 + 朝向标记 1）",
			str(_count_meshes(fig))
		)
		_check_attachments(fig, tag)
		_check_connected(fig, tag)
		_check_extras(fig, tag)

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
	_check(_count_meshes(fig) >= 23, "样式 B 多了胸横带", str(_count_meshes(fig)))

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

	print("")
	if _failures.is_empty():
		print("  全部通过")
		quit(0)
	else:
		print("  %d 项失败: %s" % [_failures.size(), " / ".join(_failures)])
		quit(1)
