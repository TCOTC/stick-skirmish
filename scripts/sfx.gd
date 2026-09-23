extends Node
## 程序化音效：启动时用代码合成几个 AudioStreamWAV，不依赖任何音频素材。
##
## 【为什么不放素材文件】导出预设是 `all_resources`，往项目里加 wav/ogg 会被一起打进
## `index.pck` 并随页面发给局域网里每个人，而网页版体积本来就紧（wasm 已经 37 MB）。
## 合成的声音够用、零体积，也省去"找素材—授权—试听"这一圈。
##
## 【播放器是"建了就忘"】每个声音起一个 AudioStreamPlayer(3D)，播完自己释放；
## 同时存在的播放器有上限，超出就丢弃新的（连发时不会堆节点）。
## 有位置的声音（别人的枪声）用 3D 播放器，自己的枪声与提示音用普通播放器——
## 自己开枪时相机就在枪口旁边，定位没有意义，反而会随转头忽大忽小。
##
## 【怎么验证】headless 里听不到声音，所以自检（tools/sfx-check.gd）检查的是
## 合成结果本身：长度、格式、峰值、包络是否真的在衰减；运行时另外报出活跃播放器数，
## 让 --shoot 能断言"开火真的起了播放器"。

const MIX_RATE := 22050
## 同时存在的播放器上限。超过就丢弃新的，连发时节点数不会失控。
const MAX_VOICES := 24
## 归一化音量上限。留一点余量：多声叠加时不至于削顶失真。
const PEAK := 0.82

var _shot: AudioStreamWAV = null
var _impact: AudioStreamWAV = null
var _hurt: AudioStreamWAV = null
var _death: AudioStreamWAV = null
var _kill: AudioStreamWAV = null
var _spawn: AudioStreamWAV = null
var _round: AudioStreamWAV = null
var _victory: AudioStreamWAV = null
var _defeat: AudioStreamWAV = null

# 活跃播放器数。供自动化检查确认"开火真的起了播放器"。
var _live := 0


func _ready() -> void:
	_shot = _chirp(0.12, 320.0, 90.0, 2.6, 0.55, 0.6)
	_impact = _click(0.07, 1.0)
	_hurt = _chirp(0.22, 210.0, 110.0, 1.8, 0.45, 0.25)
	_death = _chirp(0.70, 400.0, 60.0, 1.2, 0.5, 0.15)
	_kill = _arpeggio([740.0, 990.0, 1320.0], 0.085, 0.34)
	_spawn = _chirp(0.28, 420.0, 900.0, 1.6, 0.3, 0.0)
	_round = _arpeggio([520.0, 780.0], 0.14, 0.32)
	_victory = _arpeggio([660.0, 880.0, 1100.0, 1470.0], 0.11, 0.32)
	_defeat = _arpeggio([470.0, 380.0, 290.0, 220.0], 0.14, 0.32)
	print("[sfx] 已合成 %d 个音效，采样率 %d" % [9, MIX_RATE])


# --- 对外播放接口 -----------------------------------------------------------

## 别人的枪声，按世界位置衰减，听得出对方在哪边。
func play_shot(at: Vector3) -> void:
	_play_3d(_shot, at, -5.0)


## 自己的枪声。不定位，音量固定。
func play_local_shot() -> void:
	_play_2d(_shot, -7.0)


func play_impact(at: Vector3) -> void:
	_play_3d(_impact, at, -9.0)


## 自己被打到（掉血）。
func play_hurt() -> void:
	_play_2d(_hurt, -6.0)


## 自己倒下。
func play_death() -> void:
	_play_2d(_death, -5.0)


## 自己击倒了别人。
func play_kill() -> void:
	_play_2d(_kill, -6.0)


## 重生（也用于回合重置后回到出生点）。
func play_spawn() -> void:
	_play_2d(_spawn, -9.0)


func play_round_start() -> void:
	_play_2d(_round, -5.0)


func play_victory() -> void:
	_play_2d(_victory, -5.0)


func play_defeat() -> void:
	_play_2d(_defeat, -5.0)


## 活跃播放器数。仅供自动化检查读取。
func live_voices() -> int:
	return _live


func stream_count() -> int:
	return 9


# --- 播放 -------------------------------------------------------------------

func _play_3d(stream: AudioStreamWAV, at: Vector3, volume_db: float) -> void:
	if stream == null or _live >= MAX_VOICES:
		return
	var player := AudioStreamPlayer3D.new()
	player.name = "Voice3D"
	player.stream = stream
	player.volume_db = volume_db
	# 默认的 unit_size 是 1 米，声音会很"小";场地只有 20 米见方，取 12 米让枪声
	# 在整块场地上都听得清，远一点就明显衰减。
	player.unit_size = 12.0
	player.max_distance = 80.0
	player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_attach(player)
	player.global_position = at
	player.play()


func _play_2d(stream: AudioStreamWAV, volume_db: float) -> void:
	if stream == null or _live >= MAX_VOICES:
		return
	var player := AudioStreamPlayer.new()
	player.name = "Voice"
	player.stream = stream
	player.volume_db = volume_db
	_attach(player)
	player.play()


## 入树后才算活跃，并且只有真的入树才会收到 finished 信号。
func _attach(player: Node) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		# 场景还没就绪（--script 自检、启动瞬间）：不动播放器，直接丢掉
		player.free()
		return
	_live += 1
	scene.add_child(player)
	player.finished.connect(_on_finished.bind(player))


func _on_finished(player: Node) -> void:
	_live = maxi(0, _live - 1)
	if is_instance_valid(player):
		player.queue_free()


# --- 合成 -------------------------------------------------------------------

## 逐样本合成。gen 接 (t, time)：t 是 0..1 的归一化进度，time 是秒。
func _synth(seconds: float, gen: Callable) -> AudioStreamWAV:
	var count := maxi(1, int(seconds * MIX_RATE))
	var data := PackedByteArray()
	data.resize(count * 2)
	for i in count:
		var t := float(i) / float(count)
		var v := clampf(float(gen.call(t, float(i) / MIX_RATE)), -1.0, 1.0)
		data.encode_s16(i * 2, int(round(v * 32000.0)))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = MIX_RATE
	stream.stereo = false
	stream.data = data
	return stream


## "枪声"式的短促爆音：噪声（起音）+ 下滑的正弦（音高感），整体指数衰减。
func _chirp(
	seconds: float, f0: float, f1: float, power: float, gain: float, noise: float
) -> AudioStreamWAV:
	return _synth(seconds, func(t: float, time: float) -> float:
		var env := pow(1.0 - t, power)
		var body := sin(TAU * (f0 + (f1 - f0) * t) * time) * gain
		var hiss := (randf() * 2.0 - 1.0) * noise * pow(1.0 - t, power * 2.0)
		return (body + hiss) * env * PEAK
	)


## 弹着/碰撞式的"嗒"：只有噪声，衰减极快。
func _click(seconds: float, gain: float) -> AudioStreamWAV:
	return _synth(seconds, func(t: float, _time: float) -> float:
		return (randf() * 2.0 - 1.0) * pow(1.0 - t, 5.0) * gain * PEAK
	)


## 一串定长音符，用来做"提示/胜负"这类有旋律感的声音。
## 每个音符内部重新起包络，所以是一颗一颗的，不是连奏。
func _arpeggio(freqs: Array, note_time: float, gain: float) -> AudioStreamWAV:
	var total := note_time * float(freqs.size())
	return _synth(total, func(_t: float, time: float) -> float:
		var idx := mini(int(time / note_time), freqs.size() - 1)
		var local := fmod(time, note_time) / note_time
		var env := pow(1.0 - local, 1.5)
		return sin(TAU * float(freqs[idx]) * time) * env * gain * PEAK
	)
