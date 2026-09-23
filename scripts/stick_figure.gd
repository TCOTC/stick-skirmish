class_name StickFigure
extends Node3D
## 火柴人角色：Skeleton3D 骨骼 + BoneAttachment3D 挂网格 + 程序化步态动画。
##
## 【外观：有体积的“火柴棍”】肢体用**胶囊**而不是细杆，半径从 1.7 毫米级的“线”
## 提到 3~4 厘米（直径 6~8 厘米）——圆柱只能给出“细线”，胶囊两端是半球，
## 看起来像根粗短的火柴棍，而且不需要额外加关节球去填端面的缝。
## 每个部件外面套一圈墨线（反壳描边，见 ink.gd），整个角色就是一幅线描。
##
## 【黑白里怎么区分两个人】旧配色靠橙/青的色相差，去色之后两者都是白，必须换一套区分方式：
##   - ember：头是**实心墨块**（白眼睛），肢体粗一点
##   - frost：头是纸白带墨线（黑眼睛），胸前多一道墨带，肢体细一点
## 另外两人的“墨水色”也不一样（墨黑 / 石墨灰），所以能分辨弹道是谁打出来的。
## 这三条都是**不用色相**就能看到的差别，tools/art-check.gd 会断言它们在灰度下可区分。
##
## 为什么用真正的 Skeleton3D 而不是一堆 Node3D 关节：每根骨头由 BoneAttachment3D 挂网格，
## 旋转骨骼就是摆动肢体。这是 Godot 里骨骼绑定的正规做法，将来换成导入的模型
## 或者改用 AnimationPlayer 轨道时，层级结构不用动。
##
## 【易错】rest 与 pose 是两回事。`add_bone()` 会把两者都设成单位矩阵，而 `set_bone_rest()`
## 只改 rest。骨骼附件（BoneAttachment3D）跟随的是 **pose**（`get_bone_global_pose()`），
## 所以只设 rest 的话所有骨头都堆在骨骼原点，整个角色缩成一团（曾踩过：头在 1.04 米、
## 脚在 0.70 米，看起来只有头和一根躯干，手臂和腿全部重叠）。建骨时必须把 pose 一并设上。
##
## 动画为什么不用 AnimationPlayer：步态需要随移动速度连续变化（走得快摆幅就大），
## 用轨道资源是先量化再插值，反而更绕；而且轨道路径写错了不会报错，只是不生效，很难发现。
## 这里按相位直接算骨骼角度，参数集中在下方的常量里，方便调手感。
##
## 两套样式由 style_index 选择，按玩家进入房间的顺序分配（见 scripts/net.gd）。
##
## 身体是**连成一体**的：只把四肢做成各自独立的杆，手臂就会变成与躯干平行的两根
## 悬空细杆、头也会浮在躯干上方（曾今就是这样）。所以除了竖杆，还需要：
##   - 骨盆横杆：把两条腿连到躯干
##   - 肩横杆：把两条手臂连到躯干
##   - 关节球：肢体一转动，两段的接缝处会裂开一个 V 形缝，用小球填住
##
## 持枪（`equip_gun`）：枪挂在右手骨头上，右臂摆出**持枪姿态**（`_aim_arm_rotation`）。
## 关键在于手臂要**反向补偿身体偏转**，否则枪口会跟着偏身歪掉、与准星不再一致。
##
## 坐标约定：脚本节点的原点是**脚底**，与 CharacterBody3D 的碰撞胶囊底部对齐。

# 不用 class_name：headless 与 --script 模式不写全局类缓存，写类名会报找不到类型。
const Ink := preload("res://scripts/ink.gd")

## 两套样式的差异都在这里。radius 是肢体半径（米）：
## 太大（超过 5 厘米）两条腿会连成一块，太小（小于 2 厘米）就退回“骨架”而不是“火柴棍”。
##
## 眼睛的位置、大小都按 head_size 比例算，两套头形只需各自给出“前表面在哪”。
## eye_surface 是头中心到前表面的距离（球头取 0.88 是因为该高度上的球面会往内收）。
const STYLES: Array = [
	{
		"name": "ember",
		"radius": 0.038,
		"head_shape": "sphere",
		"head_size": 0.115,
		"eye_surface": 0.88,
		# 实心墨色的头：黑白里最好认的差异就是一个是墨块、一个是白纸
		"head_fill": Ink.INK,
		"eye": Ink.PAPER,
		# 这个角色的“墨水”：描边、弹道、命中特效、枪的配色都用它
		"ink": Ink.INK,
		"chest_band": false,
	},
	{
		"name": "frost",
		"radius": 0.033,
		"head_shape": "box",
		"head_size": 0.105,
		"eye_surface": 1.0,
		"head_fill": Ink.PAPER,
		"eye": Ink.INK,
		"ink": Ink.GRAPHITE,
		"chest_band": true,
	},
]

const HIPS_HEIGHT := 0.93    # 髖骨高度（骨盆横杆与大腿根就在这里）
const SPINE_LEN := 0.58      # 骨盆到肩
const NECK_LEN := 0.09       # 肩到头底
const UPPER_ARM_LEN := 0.30
const LOWER_ARM_LEN := 0.28  # 手垂到髖部高度
const UPPER_LEG_LEN := 0.46
const LOWER_LEG_LEN := 0.44  # 脚离地 0.03
const SHOULDER_X := 0.19
const HIP_X := 0.09

# [名称, 父名称, 相对父的 rest 位置]。父必须排在子之前。
#
# spine 的原点与 hips 重合（都放在骨盆），不是为了省节点，而是让躯干前倾围绕**骨盆**旋转：
# 原点若设在躯干中段，前倾时下半截会向后甩，与骨盆、大腿之间裂开约 3.5 厘米的缝。
#
# 左右的符号约定：角色面朝 -Z，所以**角色右侧是 +X**（右手方向 = 前方 × 上方）。
# 所以 *_l 取负、*_r 取正，与眼部命名（eye_l 在 -X）保持一致。
const BONES: Array = [
	["hips", "", Vector3(0.0, HIPS_HEIGHT, 0.0)],
	["spine", "hips", Vector3(0.0, 0.0, 0.0)],
	["neck", "spine", Vector3(0.0, SPINE_LEN, 0.0)],
	["head", "neck", Vector3(0.0, NECK_LEN, 0.0)],
	["upper_arm_l", "neck", Vector3(-SHOULDER_X, 0.0, 0.0)],
	["lower_arm_l", "upper_arm_l", Vector3(0.0, -UPPER_ARM_LEN, 0.0)],
	["upper_arm_r", "neck", Vector3(SHOULDER_X, 0.0, 0.0)],
	["lower_arm_r", "upper_arm_r", Vector3(0.0, -UPPER_ARM_LEN, 0.0)],
	["upper_leg_l", "hips", Vector3(-HIP_X, 0.0, 0.0)],
	["lower_leg_l", "upper_leg_l", Vector3(0.0, -UPPER_LEG_LEN, 0.0)],
	["upper_leg_r", "hips", Vector3(HIP_X, 0.0, 0.0)],
	["lower_leg_r", "upper_leg_r", Vector3(0.0, -UPPER_LEG_LEN, 0.0)],
]

# 竖杆：[骨骼, 网格中心相对骨骼的位置, 长度, 半径系数]
# 方向约定：**躯干从骨盆向上长（+Y），四肢从骨骼原点向下垂（-Y）**。
# 符号写反不会报错，只是那一段会挂到身体外面去——自检里的相接检查就是为了抓这个。
const SEGMENTS: Array = [
	["spine", Vector3(0.0, SPINE_LEN * 0.5, 0.0), SPINE_LEN, 1.15],
	["neck", Vector3(0.0, 0.055, 0.0), 0.11, 0.90],
	["upper_arm_l", Vector3(0.0, -UPPER_ARM_LEN * 0.5, 0.0), UPPER_ARM_LEN, 0.85],
	["lower_arm_l", Vector3(0.0, -LOWER_ARM_LEN * 0.5, 0.0), LOWER_ARM_LEN, 0.75],
	["upper_arm_r", Vector3(0.0, -UPPER_ARM_LEN * 0.5, 0.0), UPPER_ARM_LEN, 0.85],
	["lower_arm_r", Vector3(0.0, -LOWER_ARM_LEN * 0.5, 0.0), LOWER_ARM_LEN, 0.75],
	["upper_leg_l", Vector3(0.0, -UPPER_LEG_LEN * 0.5, 0.0), UPPER_LEG_LEN, 0.95],
	["lower_leg_l", Vector3(0.0, -LOWER_LEG_LEN * 0.5, 0.0), LOWER_LEG_LEN, 0.85],
	["upper_leg_r", Vector3(0.0, -UPPER_LEG_LEN * 0.5, 0.0), UPPER_LEG_LEN, 0.95],
	["lower_leg_r", Vector3(0.0, -LOWER_LEG_LEN * 0.5, 0.0), LOWER_LEG_LEN, 0.85],
]

# 横杆：[骨骼, 相对位置, 长度, 半径系数]。它们是把四肢接上躯干的关键。
const CROSS_BARS: Array = [
	["hips", Vector3.ZERO, HIP_X * 2.0 + 0.04, 1.00],           # 骨盆：连两条腿
	["neck", Vector3.ZERO, SHOULDER_X * 2.0 + 0.06, 0.95],     # 肩：连两条手臂
]

# 下蹲姿态：[骨盆下降幅度, 膝盖额外弯曲, 大腿额外前摆, 躯干额外前倾]
# 骨盆下降只是“跷跷板”式的视觉下蹲，**不改碰撞胶囊**，所以现在钻不进矮掩体。
const CROUCH_DROP := 0.32
const CROUCH_KNEE := 0.85
const CROUCH_LEG := 0.30
const CROUCH_LEAN := 0.16

# 关节球：[骨骼, 相对位置, 半径系数]。填住两段圆柱转动时裂开的 V 形缝。
const JOINTS: Array = [
	["upper_arm_l", Vector3.ZERO, 1.35],
	["lower_arm_l", Vector3.ZERO, 1.20],
	["upper_arm_r", Vector3.ZERO, 1.35],
	["lower_arm_r", Vector3.ZERO, 1.20],
	["upper_leg_l", Vector3.ZERO, 1.30],
	["lower_leg_l", Vector3.ZERO, 1.20],
	["upper_leg_r", Vector3.ZERO, 1.30],
	["lower_leg_r", Vector3.ZERO, 1.20],
]

# --- 步态参数（弧度） -------------------------------------------------------
const STEP_FREQ_BASE := 5.5      # 刚起步时的步频（弧度/秒）
const STEP_FREQ_PER_SPEED := 0.85 # 每快 1 m/s 追加的步频
const STEP_SPEED_FULL := 5.0     # 达到多少 m/s 时摆幅到最大
const STEP_AMP_MIN := 0.30
const LEG_SWING := 0.62
const KNEE_BEND := 0.80
const ARM_SWING := 0.50
const ELBOW_BEND := 0.32
const TORSO_LEAN := 0.12
const BOB := 0.035
const AMP_RATE := 3.5            # 摆幅增减速度
const AIR_BLEND_RATE := 7.0      # 地面/空中姿态的过渡速度
const WALK_THRESHOLD := 0.4      # 低于这个速度算站着

# --- 空中姿态 ---------------------------------------------------------------
const AIR_LEG_L := 0.55
const AIR_LEG_R := -0.30
const AIR_KNEE_L := -1.00
const AIR_KNEE_R := -0.50
const AIR_ARM := -1.90
const AIR_ELBOW := 0.45
const AIR_LEAN := 0.18

var style_index := 0

var _skeleton: Skeleton3D = null
var _bones: Dictionary = {}
var _limb_mat: StandardMaterial3D = null
var _head_mat: StandardMaterial3D = null
var _eye_mat: StandardMaterial3D = null
var _phase := 0.0
var _amp := 0.0
var _air := 0.0
var _built := false

# 用 preload 而不是全局类名：headless 与 --script 模式不会写 .godot 里的全局类缓存。
const GunScript := preload("res://scripts/gun.gd")

## 持枪姿态用到的俯仰（弧度）。由 player.gd 每帧写入，取自镜头。
## 不带上它的话枪管会水平前伸，而子弹是沿带俯仰的镜头方向飞的，两者不一致。
var aim_pitch := 0.0

## 持枪姿态要**额外抵消**的偏身（弧度）。由 player.gd 每帧写入。
##
## 为什么不能直接用本节点的 `rotation.y`：那个量在不同宿主下含义不同，
##   - 本地玩家：figure 挂在 Player 下，`rotation.y` 是相对 Player 的偏身，
##     需要抵消（Player 的那份旋转在外层已经生效了，子弹方向就在 Player 空间里）
##   - 替身：figure 直接挂在场景根下，`rotation.y` 是**世界朝向**，
##     **不能**抵消，否则枪会恒指世界前方 -Z、与朝向无关
## 曾因为这个差别出过 bug：对手的枪永远指向同一个方向。所以改成由宿主显式告知。
## 替身保持默认 0 即可。
var aim_lean := 0.0

## 手里的枪。没装备时为 null。
##
## 类型故意留空（不写 `Gun`）：headless 与 `--script` 模式不写全局类缓存，
## 写成 `var gun: Gun` 会连带把引用它的脚本也弄成 “Could not resolve external class member”。
## 留空之后是 Variant，调用 `gun.flash()` 这类是动态解析，两种模式都正常。
var gun = null
var _gun_equipped := false


func _ready() -> void:
	build()


func build() -> void:
	if _built:
		return
	_built = true
	_rebuild()


## 按进入房间的顺序选样式。序号是取模的，所以传进来多少都不会越界。
func apply_style(index: int) -> void:
	var count := STYLES.size()
	style_index = ((index % count) + count) % count
	if _built:
		_rebuild()


func style_name() -> String:
	return str(STYLES[style_index]["name"])


## 读取某根骨头当前的俯仰角（弧度），供自动化检查判断"关节到底动没动"。
func bone_angle(bone_name: String) -> float:
	var idx: int = _bones.get(bone_name, -1)
	if idx < 0 or _skeleton == null:
		return 0.0
	return _skeleton.get_bone_pose_rotation(idx).get_euler().x


## 装备枪。右臂会随之摆出持枪姿态（见 animate）。
## 配色取自当前样式，所以换样式重建时会自动跟着变。
func equip_gun() -> void:
	_gun_equipped = true
	_attach_gun()


## 枪口的世界位置。曳光起点与射线起点都用它。
func muzzle_position() -> Vector3:
	return gun.muzzle_position() if gun != null else global_position


## 枪口指向（世界坐标）。应当恒等于角色前方，与身体偏转无关——自检会核对。
func muzzle_forward() -> Vector3:
	return gun.muzzle_forward() if gun != null else -global_transform.basis.z


func _attach_gun() -> void:
	gun = null
	if not _gun_equipped or _limb_mat == null:
		return
	var g = GunScript.new()
	g.name = "Gun"
	# 先入树再设位置：入树之后全局变换才成立
	_attach("lower_arm_r").add_child(g)
	g.position = Vector3(0.0, -LOWER_ARM_LEN, 0.0)   # 握在手的位置
	# 配色取这个角色的**墨水色**（不是肤色）：枪的黑零件与主人的轮廓线同色，
	# 而两人用不同灰度时，一眼能看出这把枪是谁的。
	g.build(ink_color())
	# 枪可能在“重建末尾那次关投影”之后才装上（equip_gun 是单独调的），
	# 所以这里要再扫一次，否则枪的零件会在白墙上留下淡影。
	_no_shadows(g)
	gun = g


## 这个角色的“墨水”色。弹道、命中特效、枪的配色都用它。
##
## 不能用肢体颜色：肢体现在是**纸白**，拿它去画弹道会得到一串看不见的白线
## （改成黑白风格时最容易漏的一个地方）。
func ink_color() -> Color:
	return STYLES[style_index]["ink"]


## 肢体表面色（纸白）。
func limb_color() -> Color:
	return _limb_mat.albedo_color if _limb_mat != null else Ink.PAPER


## 头部表面的填充色。黑白风格里两个人靠“头是不是实心墨块”最快分辨。
func head_color() -> Color:
	return _head_mat.albedo_color if _head_mat != null else Ink.PAPER


func _rebuild() -> void:
	# 只拆掉自己建的骨骼（枪挂在骨骼下面，会跟着一起去）。
	# **不要**遍历子节点全删：外部会在角色节点上挂东西（联机侧挂了命中框与头顶血条），
	# 全删会把它们一起清掉，而且症状很隐蔽——字典里存的对象变成 null，
	# 只表现为“画面上看不到”，查找起来很费劲。
	if _skeleton != null and is_instance_valid(_skeleton):
		remove_child(_skeleton)
		_skeleton.queue_free()
	_skeleton = null
	gun = null
	_bones.clear()

	var style: Dictionary = STYLES[style_index]
	var outline: float = Ink.OUTLINE_LIMB
	# 肢体：纸白 + 墨线描边。
	_limb_mat = Ink.paper(Ink.PAPER, outline)
	# 头：实心墨块（ember）不描边——墨块外面再套一条墨线只会糊成一团。
	var head_fill: Color = style["head_fill"]
	var head_dark := head_fill.v < 0.3
	_head_mat = Ink.paper(head_fill, 0.0 if head_dark else outline)
	_eye_mat = Ink.flat(style["eye"])

	_skeleton = Skeleton3D.new()
	_skeleton.name = "Skeleton3D"
	add_child(_skeleton)

	for bone in BONES:
		var bone_name: String = bone[0]
		_skeleton.add_bone(bone_name)
		var idx := _skeleton.get_bone_count() - 1
		var parent_name: String = bone[1]
		var parent_idx := -1
		if parent_name != "":
			parent_idx = int(_bones[parent_name])
		_skeleton.set_bone_parent(idx, parent_idx)
		# rest 与 pose 都要设：rest 是绑定姿势，pose 才是实际参与计算的那个。
		var offset: Vector3 = bone[2]
		_skeleton.set_bone_rest(idx, Transform3D(Basis(), offset))
		_skeleton.set_bone_pose_position(idx, offset)
		_skeleton.set_bone_pose_rotation(idx, Quaternion())
		_bones[bone_name] = idx

	var radius: float = style["radius"]
	for seg in SEGMENTS:
		_add_segment(seg[0], seg[1], seg[2], radius * float(seg[3]))

	for bar in CROSS_BARS:
		_add_bar(bar[0], bar[1], bar[2], radius * float(bar[3]))

	for joint in JOINTS:
		_add_joint(joint[0], joint[1], radius * float(joint[2]))

	_add_head(style, radius)

	if bool(style["chest_band"]):
		_add_chest_band(radius)

	# 样式重建会把旧子节点全部丢掉，也包括枪，所以要重新挂一支。
	if _gun_equipped:
		_attach_gun()

	# 线稿是平涂的：所有部件一律不投影。
	# 放在重建的末尾统一扫一遍，而不是在每个 _add_* 里各写一次：
	# 少写一处不会报错，只会让白墙上多一小块灰，很难发现。
	# 枪挂在骨骼下面，所以这一扫也盖住了它。
	_no_shadows(_skeleton)


## 递归关掉这棵子树里所有网格的投影。
func _no_shadows(node: Node) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_no_shadows(child)


## 取某根骨头的附件节点，没有就建一个。
##
## 必须复用：每根骨头只留一个附件，同一骨头上的杆、横杆、关节球都挂在它下面。
## 如果每个网格各建一个新附件，同一骨骼的附件会彼此覆盖（自检按骨骼统计网格时就会漏），
## 而且节点数会平白翻倍。
func _attach(bone_name: String) -> BoneAttachment3D:
	for child in _skeleton.get_children():
		if child is BoneAttachment3D and child.bone_name == bone_name:
			return child
	var attach := BoneAttachment3D.new()
	# 先入树再设 bone_name：反过来的话 bone_idx 要等跑过一帧才解析出来。
	_skeleton.add_child(attach)
	attach.bone_name = bone_name
	return attach


## 横向的连接杆，把四肢接上躯干（胶囊默认沿 Y，转 90 度变成沿 X）。
func _add_bar(bone_name: String, offset: Vector3, length: float, radius: float) -> void:
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "bar"
	mesh_inst.mesh = _make_capsule(length, radius)
	mesh_inst.rotation.z = PI * 0.5
	mesh_inst.position = offset
	mesh_inst.material_override = _limb_mat
	_attach(bone_name).add_child(mesh_inst)


## 关节处的球，半径比相邻细杆略粗，用来填住肢体转动时裂开的缝。
func _add_joint(bone_name: String, offset: Vector3, radius: float) -> void:
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "joint"
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	mesh_inst.mesh = sphere
	mesh_inst.position = offset
	mesh_inst.material_override = _limb_mat
	_attach(bone_name).add_child(mesh_inst)


## 造一段胶囊：两端是半球，所以看起来是根有体积的短棍，而不是一根线。
##
## `height` 是**包含两个半球**的总高，与本来的圆柱长度同义，所以调用处的偏移不用改。
## 半球半径不能大于总高的一半，否则 Godot 会把高度夹到 2×radius。
func _make_capsule(length: float, radius: float) -> CapsuleMesh:
	var capsule := CapsuleMesh.new()
	capsule.height = maxf(length, radius * 2.05)
	capsule.radius = radius
	capsule.radial_segments = 10
	capsule.rings = 3   # 半球部分的分段：太少会看得出明显倒角
	return capsule


func _add_segment(
	bone_name: String, offset: Vector3, length: float, radius: float
) -> void:
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.name = "seg"
	mesh_inst.mesh = _make_capsule(length, radius)
	mesh_inst.position = offset
	mesh_inst.material_override = _limb_mat
	_attach(bone_name).add_child(mesh_inst)


func _add_head(style: Dictionary, radius: float) -> void:
	var attach := _attach("head")

	var head := MeshInstance3D.new()
	head.name = "head"
	var head_size: float = style["head_size"]
	if str(style["head_shape"]) == "box":
		var box := BoxMesh.new()
		box.size = Vector3(head_size * 2.0, head_size * 2.0, head_size * 2.0)
		head.mesh = box
	else:
		var sphere := SphereMesh.new()
		sphere.radius = head_size
		sphere.height = head_size * 2.0
		sphere.radial_segments = 12
		sphere.rings = 6
		head.mesh = sphere
	head.position = Vector3(0.0, head_size * 0.75, 0.0)   # 球底与颈杆重叠，头不会浮着
	head.material_override = _head_mat
	attach.add_child(head)

	_add_eyes(style, head_size, attach)


## 两只眼睛。做得比“朝向标记”更像一张脸，同时仍然解决“轴对称分不出一朝向”的问题。
func _add_eyes(style: Dictionary, head_size: float, attach: BoneAttachment3D) -> void:
	var eye_r := head_size * 0.17
	var center_y := head_size * 0.75
	var surface := head_size * float(style["eye_surface"])
	# 向 -Z 偏移：火柴人的正面是 -Z（与 player.gd 的朝向换算一致）。
	var z := -(surface + eye_r * 0.25)
	var sides := [[-1.0, "eye_l"], [1.0, "eye_r"]]
	for entry in sides:
		var eye := MeshInstance3D.new()
		# 名字必须区分左右：同名子节点会被 Godot 自动改名，自检按名字统计就会漏。
		eye.name = entry[1]
		var sphere := SphereMesh.new()
		sphere.radius = eye_r
		sphere.height = eye_r * 2.0
		sphere.radial_segments = 8
		sphere.rings = 4
		eye.mesh = sphere
		eye.position = Vector3(float(entry[0]) * head_size * 0.42, center_y + head_size * 0.20, z)
		eye.material_override = _eye_mat
		attach.add_child(eye)


## 样式 B 专属：胸前横带，让两套样式在远处也能一眼分开。
## 注意符号：躯干从骨盆**向上**长，所以这里取正值（写成负值会落到膝盖上，曾踩过）。
func _add_chest_band(radius: float) -> void:
	_add_bar("spine", Vector3(0.0, SPINE_LEN * 0.62, 0.0), 0.30, radius * 0.9)


## 每帧驱动步态。本机玩家传物理速度；替身传由收到的位置差分算出的速度。
## crouch 是下蹲程度（0 站、1 蹲），替身由同步过来的值给出。
func animate(move_speed: float, grounded: bool, delta: float, crouch := 0.0) -> void:
	if _skeleton == null:
		return

	_air = move_toward(_air, 0.0 if grounded else 1.0, delta * AIR_BLEND_RATE)

	var target_amp := 0.0
	if grounded and move_speed > WALK_THRESHOLD:
		target_amp = clampf(move_speed / STEP_SPEED_FULL, STEP_AMP_MIN, 1.0)
	_amp = move_toward(_amp, target_amp, delta * AMP_RATE)

	# 停下时摆幅衰减到 0，相位随之停住，姿态自然回到直立。
	if _amp > 0.01:
		_phase += delta * (STEP_FREQ_BASE + move_speed * STEP_FREQ_PER_SPEED)

	var swing := sin(_phase)
	var lift := absf(sin(_phase))

	# 走路姿态。骨骼沿 -Y 向下延伸，所以 rotation.x 为正 = 末端向前摆。
	var leg_l := swing * LEG_SWING * _amp
	var leg_r := -swing * LEG_SWING * _amp
	# 膝盖只能向后弯（负值），而且弯在“蹬地之后收腿”的摆动期：
	# sin(_phase) 为负就是腿在后半程，用 min(0, sin) 取到这一段。
	var knee_l := minf(0.0, swing) * KNEE_BEND * _amp
	var knee_r := minf(0.0, -swing) * KNEE_BEND * _amp
	var arm_l := -swing * ARM_SWING * _amp
	var arm_r := swing * ARM_SWING * _amp
	var elbow := ELBOW_BEND * _amp
	var bob := lift * BOB * _amp
	# 躯干朝 +Y 延伸，rotation.x 为正 = 向后倒，所以前倾取负。
	var lean := -TORSO_LEAN * _amp

	# 空中姿态
	leg_l = lerpf(leg_l, AIR_LEG_L, _air)
	leg_r = lerpf(leg_r, AIR_LEG_R, _air)
	knee_l = lerpf(knee_l, AIR_KNEE_L, _air)
	knee_r = lerpf(knee_r, AIR_KNEE_R, _air)
	arm_l = lerpf(arm_l, AIR_ARM, _air)
	arm_r = lerpf(arm_r, AIR_ARM, _air)
	elbow = lerpf(elbow, AIR_ELBOW, _air)
	bob = lerpf(bob, 0.0, _air)
	lean = lerpf(lean, -AIR_LEAN, _air)

	# 下蹲：降低胟部、膝盖更弯、大腿略微前摆、躯干略前倾。
	# 膝盖只能向后弯，所以这里在原有负值基础上再减。
	if crouch > 0.001:
		bob -= CROUCH_DROP * crouch
		knee_l -= CROUCH_KNEE * crouch
		knee_r -= CROUCH_KNEE * crouch
		leg_l += CROUCH_LEG * crouch
		leg_r += CROUCH_LEG * crouch
		lean -= CROUCH_LEAN * crouch

	_set_rot("upper_leg_l", leg_l)
	_set_rot("upper_leg_r", leg_r)
	_set_rot("lower_leg_l", knee_l)
	_set_rot("lower_leg_r", knee_r)
	_set_rot("upper_arm_l", arm_l)
	_set_rot("upper_arm_r", arm_r)
	_set_rot("lower_arm_l", elbow)
	_set_rot("lower_arm_r", elbow)
	_set_rot("spine", lean)
	_set_rot("hips", 0.0)

	if gun != null:
		# 持枪：右臂抬到正前方、肘部伸直，让枪口对准准星。
		# 左臂照旧摆动，这样走路姿态还能看得出来。
		_set_rot_quat("upper_arm_r", _aim_arm_rotation(lean))
		_set_rot("lower_arm_r", 0.0)

	var hips_idx: int = _bones.get("hips", -1)
	if hips_idx >= 0:
		_skeleton.set_bone_pose_position(hips_idx, Vector3(0.0, HIPS_HEIGHT + bob, 0.0))


## 持枪时右臂的旋转：让手臂（本来沿 -Y 向下）对准**子弹飞行的方向**。
##
## 要抵消/叠加的旋转有三级，漏掉任何一级枪口都会歪：
##   - 镜头的俯仰 `aim_pitch`（目标方向本身就带这个角）
##   - 宿主告知的偏身 `aim_lean`（见该变量的注释，本地玩家与替身不同）
##   - 躯干绕 X 的前倾：`spine_lean`（步态导致，走路时一直存在）
## 手臂的父级链累积起来是 `Ry(aim_lean)·Rx(spine_lean)`，取其逆作用到目标方向上。
##
## 用“把 -Y 转到目标方向”的最小旋转来求，而不是手写欧拉角：欧拉顺序记错就会差 90°，
## 而且躯干前倾那一级很难手算。自检里那项“枪口对准飞行方向”会验证结果。
func _aim_arm_rotation(spine_lean: float) -> Quaternion:
	# 镜头在 Player 空间里绕 X 转了 aim_pitch，所以前方是 (0, sin, -cos)
	var target := Vector3(0.0, sin(aim_pitch), -cos(aim_pitch))
	target = Basis(Vector3.RIGHT, -spine_lean) * Basis(Vector3.UP, -aim_lean) * target
	return Quaternion(Vector3(0.0, -1.0, 0.0), target)


func _set_rot_quat(bone_name: String, quat: Quaternion) -> void:
	var idx: int = _bones.get(bone_name, -1)
	if idx < 0:
		return
	_skeleton.set_bone_pose_rotation(idx, quat)


func _set_rot(bone_name: String, x: float) -> void:
	var idx: int = _bones.get(bone_name, -1)
	if idx < 0:
		return
	_skeleton.set_bone_pose_rotation(idx, Quaternion.from_euler(Vector3(x, 0.0, 0.0)))
