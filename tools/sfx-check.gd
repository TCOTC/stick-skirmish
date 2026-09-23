extends SceneTree
## 音效自检：无头运行，检查程序化合成的结果与播放器的回收路径。
##
##   & 'D:\Tool\Godot\4.7.2\Godot_v4.7.2-stable_win64_console.exe' --headless `
##     --path 'D:\Datafile\stick-skirmish' --script res://tools/sfx-check.gd
##
## 为什么需要它：headless 里根本听不到声音（Dummy 音频驱动），"好不好听"也没法断言。
## 能自动验证的是**合成结果与生命周期**：
##   - 九个音效都真的合成了，格式/采样率/声道符合预期，长度不为零
##   - 峰值落在合理区间（全零 = 静音，贴顶 = 削顶失真）
##   - 包络真的在衰减（首段能量显著大于尾段），否则听上去就是一声爆音
##   - 播放器播完会自己回收、同时存在的数量有上限（这两点是防内存/节点泄漏的）
##
## 用 preload 而不是全局类名：--script 模式不会写 .godot 里的全局类缓存（会报
## "Could not find type"）。同理，autoload 在 --script 模式下不存在，所以要自己建。

const SfxScript := preload("res://scripts/sfx.gd")

const NAMES := [
	"_shot", "_impact", "_hurt", "_death", "_kill",
	"_spawn", "_round", "_victory", "_defeat",
]

var _failures: Array[String] = []
var _sfx: Node = null
var _scene: Node3D = null
var _stage := 0
var _timer := 0.0
var _max_live := 0


func _check(ok: bool, label: String, detail := "") -> void:
	print("%s%s%s" % [
		"  ok   " if ok else "  FAIL ",
		label,
		"" if detail.is_empty() else "  —  " + detail,
	])
	if not ok:
		_failures.append(label)


func _initialize() -> void:
	# 播放器会被挂到 current_scene 下，所以先给它一个场景根。
	_scene = Node3D.new()
	_scene.name = "Scene"
	root.add_child(_scene)
	current_scene = _scene

	_sfx = SfxScript.new()
	_sfx.name = "Sfx"
	root.add_child(_sfx)   # 入树即触发 _ready，音效在这一步合成
	# 检查必须放到第一帧之后：_initialize 阶段这个节点的 _ready 还没跑（
	# 与 stick-check.gd 里“附件绑定要等一帧”是同一类问题），此时音效还是 null。


# --- 合成结果 ---------------------------------------------------------------

func _check_streams() -> void:
	var peak_min := 1.0
	var peak_max := 0.0
	var shortest := 999999
	var worst_env := 999.0
	var bad := PackedStringArray()
	for name in NAMES:
		var stream: AudioStreamWAV = _sfx.get(name)
		if stream == null:
			bad.append("%s:null" % name)
			continue
		if stream.format != AudioStreamWAV.FORMAT_16_BITS:
			bad.append("%s:format" % name)
		if stream.mix_rate != SfxScript.MIX_RATE:
			bad.append("%s:rate" % name)
		if stream.stereo:
			bad.append("%s:stereo" % name)
		var frames := stream.data.size() / 2
		shortest = mini(shortest, frames)
		var peak := _peak(stream)
		peak_min = minf(peak_min, peak)
		peak_max = maxf(peak_max, peak)
		worst_env = minf(worst_env, _envelope_ratio(stream))
	_check(bad.is_empty(), "%d 个音效都已合成（格式 16 位、%d Hz、单声道）" % [
		NAMES.size(), SfxScript.MIX_RATE], " / ".join(bad))
	_check(shortest > 1000, "最短的音效也有足够长度", "最短 %d 帧" % shortest)
	_check(peak_min > 0.2, "没有静音的音效", "最小峰值 %.2f" % peak_min)
	_check(peak_max < 1.0, "没有削顶（峰值低于满量程）", "最大峰值 %.2f" % peak_max)
	# 首段能量要明显大于尾段：这是"包络在衰减"的可测形式。
	_check(worst_env > 3.0, "包络在衰减（首段能量远大于尾段）",
		"最差的一个比值 %.1f 倍" % worst_env)
	_check(_distinct(_sfx.get("_shot")) > 50, "波形有变化（不是常量直流）",
		"%d 个不同取值" % _distinct(_sfx.get("_shot")))


func _peak(stream: AudioStreamWAV) -> float:
	var frames := stream.data.size() / 2
	var peak := 0.0
	for i in frames:
		peak = maxf(peak, absf(float(stream.data.decode_s16(i * 2)) / 32768.0))
	return peak


## 前 10% 与后 10% 的均方根之比。衰减良好的声音这个比值很大。
func _envelope_ratio(stream: AudioStreamWAV) -> float:
	var frames := stream.data.size() / 2
	var span := maxi(1, frames / 10)
	return _rms(stream, 0, span) / maxf(0.0001, _rms(stream, frames - span, frames))


func _rms(stream: AudioStreamWAV, from: int, to: int) -> float:
	var sum := 0.0
	for i in range(from, to):
		var v := float(stream.data.decode_s16(i * 2)) / 32768.0
		sum += v * v
	return sqrt(sum / maxf(1.0, float(to - from)))


func _distinct(stream: AudioStreamWAV) -> int:
	var seen := {}
	for i in stream.data.size() / 2:
		seen[stream.data.decode_s16(i * 2)] = true
		if seen.size() > 400:
			break
	return seen.size()


# --- 播放器的生命周期 -------------------------------------------------------

## 播放器是"建了就忘"的：必须验证它真的会被回收，且同时存在的数量有上限。
## 前者漏了就是每开一枪漏一个节点，后者漏了就是连发时节点数失控。
func _check_playback_cap() -> void:
	for i in SfxScript.MAX_VOICES + 16:
		_sfx.play_local_shot()
	_max_live = int(_sfx.call("live_voices"))
	_check(_max_live <= SfxScript.MAX_VOICES, "同时存在的播放器不超过上限",
		"造了 %d 个，活跃 %d 个（上限 %d）" % [
			SfxScript.MAX_VOICES + 16, _max_live, SfxScript.MAX_VOICES])
	_check(_max_live > 0, "播放请求真的起了播放器", "活跃 %d 个" % _max_live)


func _process(delta: float) -> bool:
	_timer += delta
	match _stage:
		0:
			if _timer > 0.1:
				print("")
				print("  音效自检")
				_check_streams()
				_check_playback_cap()
				_stage = 1
				_timer = 0.0
		1:
			# 最长的音效 0.7 秒，留足时间让它自然结束
			if _timer > 1.5:
				var live := int(_sfx.call("live_voices"))
				_check(live == 0, "播完之后播放器自己回收",
					"1.5 秒后还剩 %d 个" % live)
				_finish()
				return true
	return false


func _finish() -> void:
	print("")
	if _failures.is_empty():
		print("  全部通过")
		quit(0)
	else:
		print("  失败 %d 项：%s" % [_failures.size(), ", ".join(_failures)])
		quit(1)
