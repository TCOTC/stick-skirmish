extends SceneTree
## 美术自检：把真正的主场景装出来，扫一遍全部材质与界面颜色，确认它就是“黑白线稿”。
##
##   & 'D:\Tool\Godot\4.7.2\Godot_v4.7.2-stable_win64_console.exe' --headless `
##     --path 'D:\Datafile\stick-skirmish' --script res://tools/art-check.gd
##
## 【为什么需要它】“像不像手绘”没法自动判断，但**这套风格的四条硬性事实可以**：
##   1. 全场景没有任何彩色（所有材质的饱和度都接近 0）——去色调风格最容易漏的就是某一处
##   2. 纸面够白、墨线够黑（不是“深灰墙配中灰描边”这种看着不明确的中间状态）
##   3. 方盒的棱线与角标真的建出来了（棱 + 角 + 地板网格），而且合并成了极少的绘制批次
##   4. 方盒不受阴影、背景是纸、光照是白色（明暗只来自朝向，没有色偏与硬影）
##
## 前三条都是“漏了不会报错、只会看起来有点不对”的东西：材质少改一处不会崩溃，
## 描边少画一条也不明显，只有把它们变成断言才守得住。
##
## 用 preload 而不是全局类名：`--script` 模式不写 .godot 里的全局类缓存。
## 检查要放在 `_process()` 的第一帧之后：`_initialize()` 阶段节点还没入树、`_ready` 还没跑。

const Ink := preload("res://scripts/ink.gd")

## 纸面亮度下限与墨线亮度上限。取 0.9 / 0.2 而不是“接近 1 / 接近 0”，
## 是因为纸白刻意偏暖（v=0.965）、墨刻意不用纯黑（v=0.085）。
const PAPER_MIN_V := 0.9
const INK_MAX_V := 0.2
## 场景里允许的绘制批次上限（方盒类）。17 个掩体 + 地板合并成 2 个网格，
## 角色的部件加起来几十个。这个数比“随便加节点”的情况小一个量级，够用来守合并。
const MAX_SCENE_MESHES := 120

var _failures: Array[String] = []
var _scene: Node = null
var _checked := false


func _check(ok: bool, label: String, detail := "") -> void:
	print("%s%s%s" % [
		"  ok   " if ok else "  FAIL ",
		label,
		"" if detail.is_empty() else "  —  " + detail,
	])
	if not ok:
		_failures.append(label)


func _initialize() -> void:
	_scene = load("res://scenes/main.tscn").instantiate()
	_scene.name = "MainScene"
	root.add_child(_scene)
	current_scene = _scene


func _process(_delta: float) -> bool:
	if _checked:
		return false
	_checked = true

	print("")
	print("  美术自检（黑白线稿）")
	_check_colors()
	_check_arena()
	_check_lighting()
	_finish()
	return false


# --- 1. 全场景没有彩色 -------------------------------------------------------

## 扫全部 MeshInstance3D 的材质（含 next_pass 描边）与全部界面控件的颜色。
##
## 这一项是这套风格最核心的守卫：旧配色里有一处橙色或青色漏网，画面上就是“还带点颜色”，
## 而那种“好像有哪里不对”很难靠看截图定位——扫描会直接报出是哪个节点。
func _check_colors() -> void:
	var colors: Array = []
	var where: Array = []
	_collect_mesh_colors(_scene, colors, where)
	_collect_ui_colors(_scene, colors, where)

	var bad: Array[String] = []
	var worst := 0.0
	var worst_at := ""
	for i in colors.size():
		var c: Color = colors[i]
		if c.s > worst:
			worst = c.s
			worst_at = where[i]
		if not Ink.is_gray(c):
			bad.append("%s 饱和度 %.2f" % [where[i], c.s])

	_check(
		colors.size() > 30,
		"扫到了足够多的材质与界面颜色",
		"%d 处（只扫到几处说明节点树没建起来）" % colors.size()
	)
	_check(bad.is_empty(), "全场景没有任何彩色（饱和度都接近 0）",
		"最大饱和度 %.2f（%s）" % [worst, worst_at]
		+ ("；带彩色的：" + " / ".join(bad) if not bad.is_empty() else ""))


func _collect_mesh_colors(node: Node, colors: Array, where: Array) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.material_override != null:
			_collect_material(mi.material_override, mi, colors, where)
		var mesh := mi.mesh
		if mesh != null:
			for i in mesh.get_surface_count():
				var mat := mesh.surface_get_material(i)
				if mat != null:
					_collect_material(mat, mi, colors, where)
	for child in node.get_children():
		_collect_mesh_colors(child, colors, where)


func _collect_material(mat: Material, node: Node, colors: Array, where: Array) -> void:
	var standard := mat as StandardMaterial3D
	if standard == null:
		return
	colors.append(standard.albedo_color)
	where.append("%s(%s)" % [node.name, node.get_parent().name if node.get_parent() != null else "?"])
	# 描边挂在 next_pass 上，它同样不能带彩色
	if standard.next_pass != null:
		_collect_material(standard.next_pass, node, colors, where)


## 界面颜色：ColorRect 的 color、Label 的 font_color、以及各控件的 modulate。
func _collect_ui_colors(node: Node, colors: Array, where: Array) -> void:
	if node is ColorRect:
		colors.append((node as ColorRect).color)
		where.append("%s(ColorRect)" % node.name)
	if node is Label:
		colors.append((node as Label).get_theme_color("font_color"))
		where.append("%s(Label)" % node.name)
	if node is CanvasItem:
		var cm := (node as CanvasItem).modulate
		# 完全透明的 modulate 是布局用的默认值，不参与判断
		if cm.a > 0.01:
			colors.append(cm)
			where.append("%s(modulate)" % node.name)
	for child in node.get_children():
		_collect_ui_colors(child, colors, where)


# --- 2. 竞技场的面与线 -------------------------------------------------------

## 纸白的面 + 墨黑的棱线，而且**合并成了 2 个网格**（这是绘制批次的关键）。
func _check_arena() -> void:
	var arena := _scene.get_node_or_null("Arena")
	if arena == null:
		_check(false, "场景里有 Arena 节点")
		return

	var surfaces := arena.get_node_or_null("Surfaces") as MeshInstance3D
	var lines := arena.get_node_or_null("InkLines") as MeshInstance3D
	_check(surfaces != null and lines != null, "竞技场分成“纸面 + 墨线”两个网格",
		"Surfaces=%s InkLines=%s" % [surfaces != null, lines != null])

	var meshes := 0
	for child in arena.get_children():
		if child is MeshInstance3D:
			meshes += 1
	_check(meshes == 2, "竞技场只有 2 个绘制批次（面与线各合并成一个）",
		"实际 %d 个 MeshInstance3D（分开建会是 350 多个）" % meshes)

	if surfaces != null:
		var paper := surfaces.material_override as StandardMaterial3D
		_check(
			paper != null and paper.albedo_color.v >= PAPER_MIN_V,
			"墙面与地板是纸白",
			"亮度 %.2f（下限 %.2f）" % [paper.albedo_color.v if paper != null else -1.0, PAPER_MIN_V]
		)
	if lines != null:
		var ink := lines.material_override as StandardMaterial3D
		_check(
			ink != null and ink.albedo_color.v <= INK_MAX_V,
			"描边是墨黑",
			"亮度 %.2f（上限 %.2f）" % [ink.albedo_color.v if ink != null else -1.0, INK_MAX_V]
		)

	# 17 个方盒 × (12 棱 + 8 角) = 340，再加地板网格若干
	var marks := int(arena.call("ink_marks")) if arena.has_method("ink_marks") else -1
	_check(marks >= 340, "每个方盒的棱与角都画了墨线",
		"%d 条（17 个方盒的棱角就要 340 条）" % marks)

	# 地板网格：没有它，一片白地上判断不了距离
	_check(marks >= 340 + 18, "地板上另有网格线（深度线索）",
		"多出的 %d 条" % (marks - 340))

	# 方盒不投影：硬阴影会在白墙上压出一片灰，与“画上去的线”不是一回事
	var shadow_casters := 0
	var mesh_total := 0
	for node in _all_nodes(_scene):
		if node is MeshInstance3D:
			mesh_total += 1
			var mi := node as MeshInstance3D
			if mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				shadow_casters += 1
	_check(shadow_casters == 0, "没有任何网格在投影（线稿是平涂的）",
		"仍在投影的网格 %d 个" % shadow_casters)
	# 场景里只有一个玩家（联机替身不在），两个玩家时大约是这个数的两倍
	_check(mesh_total <= MAX_SCENE_MESHES, "网格总数在预算内（WebGL2 下每个都是绘制调用）",
		"当前 %d 个（含描边那一趟就是 %d 次绘制），上限 %d" % [
			mesh_total, mesh_total * 2, MAX_SCENE_MESHES])


# --- 3. 光照与背景 -----------------------------------------------------------

## 白色光照 + 纸白背景：明暗只能来自朝向（铅笔的排线感），不能有色偏与硬影。
func _check_lighting() -> void:
	var env_node := _scene.get_node_or_null("WorldEnvironment") as WorldEnvironment
	var env := env_node.environment if env_node != null else null
	_check(env != null, "场景有 WorldEnvironment")
	if env != null:
		_check(env.background_color.v >= PAPER_MIN_V, "背景是纸白（不是天空或夜空）",
			"亮度 %.2f" % env.background_color.v)
		_check(Ink.is_gray(env.background_color) and Ink.is_gray(env.ambient_light_color),
			"背景与环境光都没有色偏",
			"背景饱和度 %.2f、环境光饱和度 %.2f" % [env.background_color.s, env.ambient_light_color.s])

	var sun := _scene.get_node_or_null("Sun") as DirectionalLight3D
	_check(sun != null, "场景有主光")
	if sun != null:
		_check(not sun.shadow_enabled, "主光不投影（避免白墙上压出灰块）")
		_check(Ink.is_gray(sun.light_color), "主光是白光（没有色偏）",
			"饱和度 %.2f" % sun.light_color.s)

	# 界面里的东西也不能例外（HUD 是 CanvasLayer，不在上面的网格扫描里）
	var hud := _scene.get_node_or_null("HUD")
	_check(hud != null, "场景有 HUD")
	if hud != null:
		var rects := 0
		for node in _all_nodes(hud):
			if node is ColorRect and (node as ColorRect).color.a > 0.01:
				rects += 1
		_check(rects >= 5, "HUD 的方片（准星、血条、红闪）都建出来了",
			"%d 个可见 ColorRect" % rects)


func _all_nodes(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for child in node.get_children():
		out.append_array(_all_nodes(child))
	return out


func _finish() -> void:
	print("")
	if _failures.is_empty():
		print("  全部通过")
		quit(0)
	else:
		print("  失败 %d 项：%s" % [_failures.size(), ", ".join(_failures)])
		quit(1)
