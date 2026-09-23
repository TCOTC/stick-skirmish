# 光标守卫：开发期间持续解除 Windows 的鼠标裁剪（ClipCursor）。
#
# 【为什么需要它】浏览器进入指针锁定时会调用 ClipCursor 把光标圈在自己的窗口里，
# 而"还原"发生在窗口销毁的流程里。测试进程被强杀（例如把输出管道接到 Select-Object -First，
# 它在读满 N 行时就会掐掉上游）就来不及还原，限制作为孤儿留在系统里——
# 症状是鼠标只能在屏幕的一小块区域里移动，找遍所有窗口都没有尺寸吻合的那个。
#
# 原来的做法是"收尾时清理一次"，但只要测试没走到收尾（强杀、崩溃、Ctrl+C）就漏了。
# 这个脚本作为**独立进程**运行，所以即使测试进程已经消失，它仍会把光标放出来；
# 它还会把留在系统里的测试用 Chrome 一起清掉（否则那个窗口仍处于锁定状态，可能再次上锁）。
#
# 用法：
#   powershell -File tools/cursor-guard.ps1 -ParentId 1234 -MaxMinutes 20 -KillMarker 'stick-'
#   powershell -File tools/cursor-guard.ps1 -MaxMinutes 60        # 整个开发时段的手动守护
#
# 输出：运行期间完全静默（不占终端），结束时往 $LogFile 写一行 ASCII 统计供测试脚本读取。

param(
	[int]$ParentId = 0,
	[int]$MaxMinutes = 60,
	[int]$IntervalMs = 100,
	[string]$KillMarker = "",
	[string]$LogFile = "",
	[string]$StopFile = "",
	[string]$ProfileDir = ""
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class CursorGuardNative {
  public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool ClipCursor(IntPtr rect);
  [DllImport("user32.dll")] public static extern bool GetClipCursor(out RECT r);
}
"@

function Get-ClipRect {
	$r = New-Object CursorGuardNative+RECT
	[void][CursorGuardNative]::GetClipCursor([ref]$r)
	return $r
}

function Test-ParentAlive {
	if ($ParentId -le 0) { return $true }
	try {
		$null = [System.Diagnostics.Process]::GetProcessById($ParentId)
		return $true
	} catch {
		return $false
	}
}

# 只清理测试用的 Chrome：按命令行里的标记匹配。
# **不要用端口号匹配**：mojo 参数里会偶然出现 9333 这类数字，会误伤用户自己的浏览器。
#
# 用 taskkill /T（连子进程一起）而不是 Stop-Process：Chrome 是主进程 + 一堆渲染进程，
# 只杀主进程会留下一串孤儿渲染进程，它们还占着临时 profile 目录。
# 另外只杀 `--type=` 为空的那个（就是浏览器主进程本身），避免遍历到一半时父子互相干扰。
function Stop-TestChrome {
	if ($KillMarker -eq '') { return 0 }
	$killed = 0
	$procs = Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
		Where-Object {
			$_.CommandLine -and $_.CommandLine -match $KillMarker -and $_.CommandLine -notmatch '--type='
		}
	foreach ($p in $procs) {
		$cmd = $p.CommandLine
		& taskkill /PID $p.ProcessId /T /F 2>$null | Out-Null
		$killed++

		# 顺手删掉它自己的临时 profile 目录：测试被强杀时那条清理路径没跑到，
		# 这些目录会留在临时目录里。目录名从**这条命令行**里取，而且必须带我们的标记，
		# 所以同时跑着的另一个测试（以及用户自己的浏览器）都不会被误删。
		$dir = $null
		if ($cmd -match '--user-data-dir=(?:"([^"]+)"|([^\s]+))') {
			$dir = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
		}
		if ($dir -and $dir -match 'stick-') {
			for ($i = 0; $i -lt 3; $i++) {
				try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Stop; break }
				catch { Start-Sleep -Milliseconds 300 }
			}
		}
	}
	return $killed
}

$started = Get-Date
$deadline = $started.AddMinutes($MaxMinutes)
$reason = 'timeout'
$samples = 0
$cleared = 0
$startupClip = 0
$confinedSince = $null
$worstMs = 0

# 启动就留一行痕迹：否则“守卫没起来”与“守卫起来了但没走到收尾”在日志上无法区分
# （写文件也可能失败，所以把它包起来，绝不让它把守卫本身弄挂）。
function Write-Log([string]$text) {
	if ($LogFile -eq '') { return }
	try { Add-Content -Path $LogFile -Value $text -Encoding ASCII -ErrorAction Stop } catch { }
}

Write-Log "cursor-guard-started pid=$PID parent=$ParentId interval=$IntervalMs max_minutes=$MaxMinutes"

# 先看一眼当前状态再放开：上一次崩溃可能留下了孤儿裁剪，那一次也要计入统计
# （否则“启动时就清掉了一个”会被报告成 cleared=0，看起来像守卫什么都没做）。
# 基准值必须在**已经放开**的状态下取，否则会把那条旧限制当成正常值，
# 于是守卫永远认为一切正常、再也不会去清它。
$initial = Get-ClipRect
[void][CursorGuardNative]::ClipCursor([IntPtr]::Zero)
Start-Sleep -Milliseconds 80
$baseline = Get-ClipRect
$startupDrift =
	[Math]::Abs($initial.Left - $baseline.Left) -gt 2 -or [Math]::Abs($initial.Top - $baseline.Top) -gt 2 -or
	[Math]::Abs($initial.Right - $baseline.Right) -gt 2 -or [Math]::Abs($initial.Bottom - $baseline.Bottom) -gt 2
if ($startupDrift) {
	$cleared++
	$startupClip = 1
}

while ((Get-Date) -lt $deadline) {
	if (-not (Test-ParentAlive)) { $reason = 'parent-gone'; break }
	if ($StopFile -ne '' -and (Test-Path -Path $StopFile)) { $reason = 'stop-file'; break }

	$r = Get-ClipRect
	$samples++
	$drifted =
		[Math]::Abs($r.Left - $baseline.Left) -gt 2 -or [Math]::Abs($r.Top - $baseline.Top) -gt 2 -or
		[Math]::Abs($r.Right - $baseline.Right) -gt 2 -or [Math]::Abs($r.Bottom - $baseline.Bottom) -gt 2
	if ($drifted) {
		if ($null -eq $confinedSince) { $confinedSince = Get-Date }
		[void][CursorGuardNative]::ClipCursor([IntPtr]::Zero)
		$cleared++
	} elseif ($null -ne $confinedSince) {
		# 从"第一次发现被圈"到"下一次采样确认已放开"之间的时长，
		# 就是用户鼠标真正被困住的上限（约等于采样间隔）。
		$ms = ((Get-Date) - $confinedSince).TotalMilliseconds
		if ($ms -gt $worstMs) { $worstMs = [int]$ms }
		$confinedSince = $null
	}
	Start-Sleep -Milliseconds $IntervalMs
}

# 退出路径分阶段留痕：这一段只在“父进程没了”或“收到停止文件”时才走，
# 而它曾经在这两个情况下表现不一致（有一边没写下统计行），分阶段才能定位卡在哪。
Write-Log "cursor-guard-phase loop-exit reason=$reason samples=$samples"

# 父进程已经没了（测试被强杀或崩溃）：把留下的测试 Chrome 一并清掉。
# 正常收尾（父进程写了 StopFile 后退出）不做这件事——父进程自己会优雅关闭浏览器。
$orphans = 0
if (-not (Test-ParentAlive)) {
	$orphans = Stop-TestChrome
	Write-Log "cursor-guard-phase orphans-killed n=$orphans"
	Start-Sleep -Milliseconds 200
	# 浏览器可能是被控制台关闭带走的（那时它自己会退，上面一条匹配不到任何东西），
	# 但它用过的临时 profile 目录会留在临时目录里，所以另行删一次。
	# 路径是测试脚本自己告知的，所以绝不会碰到同时跑着的另一个测试。
	if ($ProfileDir -ne '' -and (Test-Path -LiteralPath $ProfileDir)) {
		for ($i = 0; $i -lt 3; $i++) {
			try { Remove-Item -LiteralPath $ProfileDir -Recurse -Force -ErrorAction Stop; break }
			catch { Start-Sleep -Milliseconds 300 }
		}
	}
}
[void][CursorGuardNative]::ClipCursor([IntPtr]::Zero)
Start-Sleep -Milliseconds 60
$final = Get-ClipRect
Write-Log "cursor-guard-phase clip-cleared"

if ($LogFile -ne '') {
	$seconds = [int]((Get-Date) - $started).TotalSeconds
	$line = "cursor-guard samples=$samples cleared=$cleared worst_confined_ms=$worstMs" `
		+ " orphan_chrome=$orphans startup_clip=$startupClip seconds=$seconds reason=$reason" `
		+ " baseline=$($baseline.Left),$($baseline.Top),$($baseline.Right),$($baseline.Bottom)" `
		+ " final=$($final.Left),$($final.Top),$($final.Right),$($final.Bottom)"
	Write-Log $line
}
