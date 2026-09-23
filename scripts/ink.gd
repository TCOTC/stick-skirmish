extends Node
## 黑白手绘（“墨水画在纸上”）风格的**唯一来源**：调色板 + 材质工厂。
##
## 【为什么要有这个文件】这套风格靠三样东西表达：纸白、墨黑、以及沿轮廓的墨线。
## 如果每个脚本各写一份颜色，改一次风格要动六七个文件，而且漏掉一处不会报错——
## 只会有一个部件还是彩色的。集中定义之后，`tools/art-check.gd` 里那条
## “任何材质的饱和度都必须接近 0”的断言才有意义：它扫的是全场景，而调色板只有这里一处。
##
## 【两种材质】
##   - `paper()` 表面：漫反射纸白，加一点自发光，保证背光面也是纸白而不是灰黑。
##     不用纯白：纯白在显示器上刺眼，也不像纸。
##   - `outline()` 描边：**反壳**——把网格沿法线放大一圈、并反转面剔除，
##     于是只在物体外沿露出一圈，看起来就是一条墨线。
##
## 【为什么描边用反壳而不是加一圈网格】网格描边要为每个部件复刻形状（圆柱要画圆环，
## 球要画球壳），形状一改就得同步改描边；反壳对任何形状都自动成立。
## 竞技场那种方盒则相反：方盒要的是“棱线与角”，反壳只能给出外轮廓，
## 所以那里直接画棱边（见 arena.gd），两者各取所长。
##
## 【用法】`const Ink := preload("res://scripts/ink.gd")`，然后 `Ink.paper()`。
## 不用 `class_name`：headless 与 `--script` 模式不写全局类缓存，写类名会报找不到类型。

## 纸白。略偏暖：纯白在显示器上刺眼，也不像纸。这点偏色只有 4% 饱和度，
## 远远够不上“彩色”，但它就是“纸”与“白屏”的差别。
const PAPER := Color(0.965, 0.953, 0.925)
## 墨黑。严格中性灰（RGB 相等）：黑白风格里的墨不能带任何色相，
## 否则一整幅画会偷惄惄偏色。也不用纯黑：纯黑与纸白对比过刚，反壳描边叠在暗处会糊成一片。
const INK := Color(0.085, 0.085, 0.085)
## 石墨灰。用于“次要线条”（对手的弹道、次要的界面文字），在黑白里提供第二层级。
const GRAPHITE := Color(0.44, 0.44, 0.44)

## 角色描边宽度（米）。肢体半径约 3~4 厘米，所以 1.6 厘米差不多是“钢笔线”的比例。
## 从相机（在身后约 5 米）看过去，1 厘米约合 0.9 像素，所以这条线在实测里"看得见但不刺眼"。
## 再细（曾用 1.2 厘米）在远处就溶掉，角色会变成一团浮在纸上的白。
const OUTLINE_LIMB := 0.016
## 方盒类物体（枪的零件）用的描边宽度。比肢体细：零件本身只有几厘米宽，
## 用肢体的 1.2 厘米会把零件吃掉。
const OUTLINE_PART := 0.005

## 自发光强度。它的作用是给暗面托底：没有它，背光的肢体在深色背景下会变成灰黑块。
## 取 0.1 而不是更高，是为了仍然保留“铅笔排线”那种明暗差别（见 README 的取景一节）。
const PAPER_GLOW := 0.1


## 纸白表面。`outline` 为 0 时不描边（实心墨块、被包在别的形状里的部件不需要）。
static func paper(color: Color = PAPER, outline := OUTLINE_LIMB, outline_color: Color = INK) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	# 纸是粗糙的：不要高光、不要金属感，否则会变成塑料
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = PAPER_GLOW
	if outline > 0.0:
		mat.next_pass = outline_pass(outline, outline_color)
	return mat


## 不带光照的平涂（眼睛、界面用的方片）：没有明暗，颜色就是纸/墨本身。
static func flat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.roughness = 1.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return mat


## 反壳描边材质。当作 `next_pass` 挂在表面材质后面。
##
## 关键是两件事同时成立：
##   - `grow` 把顶点沿法线外推，网格整体变大一圈
##   - `cull_mode = CULL_FRONT` 把正面剔掉，于是看见的是放大后壳体的**内侧反面**
## 两者合起来，只有超出原物体外沿的那一圈会留在画面上，正好是轮廓线。
## 少了任何一件都不成立：只放大不剔面 → 描边整个盖住物体；只剔面不放大 → 什么也看不见。
static func outline_pass(width: float, color: Color = INK) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	# 不受光照：轮廓线的深浅不该随太阳角度变
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_FRONT
	mat.grow = true
	mat.grow_amount = width
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return mat


## 颜色是不是“接近灰”——用来断言整个画面没有彩色（见 tools/art-check.gd）。
##
## 用 HSV 的饱和度判：墨黑与石墨灰是严格 0，纸白因为刻意偏暖是 0.04，
## 而旧配色里的橙（0.90, 0.42, 0.20）饱和度是 0.78，一测就出来。
## 容差 0.08 就是为了给“暖纸白”留位置，再调大就会开始放过浅彩色了。
static func is_gray(color: Color, tolerance := 0.08) -> bool:
	return color.s <= tolerance
