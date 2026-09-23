# 光标守卫的自检：人为制造一个鼠标裁剪区，确认守卫会在一个采样间隔内解除它。
#
# 【为什么需要】“鼠标不再被困住”这件事靠肉眼很难验证——正常跑测试时未必会触发指针锁定，
# 触发了也只是“偶尔卡一下”。这里直接把系统置成那个坏状态（ClipCursor 到一个小矩形），
# 再看守卫能不能在一百毫秒级把它清掉。这是唯一能证明守卫有效的办法。
#
# 用法:  powershell -ExecutionPolicy Bypass -File tools/cursor-guard-check.ps1

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class CursorCheckNative {
  public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool ClipCursor(IntPtr rect);
  [DllImport("user32.dll")] public static extern bool ClipCursor(ref RECT rect);
  [DllImport("user32.dll")] public static extern bool GetClipCursor(out RECT r);
}
"@

function Get-Rect {
	$r = New-Object CursorCheckNative+RECT
	[void][CursorCheckNative]::GetClipCursor([ref]$r)
	return $r
}

function Rect-Text($r) { return "$($r.Left),$($r.Top) - $($r.Right),$($r.Bottom)" }

function Same-Rect($a, $b) {
	return (
		[Math]::Abs($a.Left - $b.Left) -le 2 -and [Math]::Abs($a.Top - $b.Top) -le 2 -and
		[Math]::Abs($a.Right - $b.Right) -le 2 -and [Math]::Abs($a.Bottom - $b.Bottom) -le 2
	)
}

$failures = 0
function Check($ok, $label, $detail) {
	if ($ok) { Write-Host "  ok   $label  —  $detail" }
	else { Write-Host "  FAIL $label  —  $detail"; $script:failures++ }
}

Write-Host ""
Write-Host "  光标守卫自检"

# 先确保干净状态，并记下"正常"的范围
[void][CursorCheckNative]::ClipCursor([IntPtr]::Zero)
Start-Sleep -Milliseconds 100
$normal = Get-Rect
Write-Host "  正常范围: $(Rect-Text $normal)"
Write-Host "  守卫的启动开销约 0.4 秒（PowerShell 启动 + Add-Type 编译）；测试脚本里把它"
Write-Host "  放在启动浏览器**之前**，所以那段时间与浏览器启动是重叠的。"
Write-Host ""

# --- 1. 人为制造裁剪区（模拟浏览器上锁后留在系统里的孤儿限制） ---
$narrow = New-Object CursorCheckNative+RECT
$narrow.Left = 3
$narrow.Top = 41
$narrow.Right = 530
$narrow.Bottom = 397
[void][CursorCheckNative]::ClipCursor([ref]$narrow)
Start-Sleep -Milliseconds 100
$confined = Get-Rect
Check (-not (Same-Rect $confined $normal)) "能把系统置成'被裁剪'的状态" `
	"裁剪区 $(Rect-Text $confined)（正常是 $(Rect-Text $normal)）"

# --- 2. 启动守卫，它应当在一个采样间隔内解除 ---
$logFile = Join-Path $env:TEMP "cursor-guard-check.log"
$stopFile = "$logFile.stop"
Remove-Item $logFile, $stopFile -Force -ErrorAction SilentlyContinue

$intervalMs = 100
$guardProc = Start-Process -FilePath "powershell" -WindowStyle Hidden -PassThru -ArgumentList @(
	"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $scriptDir "cursor-guard.ps1"),
	"-ParentId", "$PID", "-MaxMinutes", "1", "-IntervalMs", "$intervalMs",
	"-LogFile", $logFile, "-StopFile", $stopFile
)

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$releasedAt = -1
while ($sw.ElapsedMilliseconds -lt 3000) {
	$now = Get-Rect
	if (Same-Rect $now $normal) { $releasedAt = [int]$sw.ElapsedMilliseconds; break }
	Start-Sleep -Milliseconds 20
}
Check ($releasedAt -ge 0) "守卫解除了人为设置的裁剪区" `
	$(if ($releasedAt -ge 0) { "在 $releasedAt 毫秒内恢复（采样间隔 $intervalMs 毫秒）" }
	else { "3 秒内仍在裁剪区 $(Rect-Text (Get-Rect))" })

# --- 3. 让守卫多跑几轮采样再收尾 ---
# 注意要等一拍：守卫的启动开销约 0.4 秒（PowerShell 启动 + Add-Type 编译），
# 若一发现恢复就立刻写停止文件，守卫可能还没进主循环就退出了（samples=0）。
Start-Sleep -Milliseconds 500
New-Item -ItemType File -Path $stopFile -Force | Out-Null
# 等的是**统计行**而不是“日志文件出现”：现在守卫一启动就写一行 started，
# 若按文件存在与否判断，就会在守卫还没进主循环时把它杀掉。
$deadline = (Get-Date).AddSeconds(6)
while ((Get-Date) -lt $deadline) {
	if ((Test-Path $logFile) -and ((Get-Content $logFile -Raw) -match 'cleared=')) { break }
	Start-Sleep -Milliseconds 100
}
if (-not $guardProc.HasExited) { $guardProc | Stop-Process -Force -ErrorAction SilentlyContinue }
[void][CursorCheckNative]::ClipCursor([IntPtr]::Zero)

$line = if (Test-Path $logFile) { (Get-Content $logFile -Raw).Trim() } else { "" }
Check ($line -match 'cleared=[1-9]') "守卫报告了它清除了裁剪" `
	$(if ($line -ne "") { $line } else { "没有统计行（守卫没起来？）" })

Remove-Item $logFile, $stopFile -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($failures -eq 0) {
	Write-Host "  全部通过"
	exit 0
} else {
	Write-Host "  失败 $failures 项"
	exit 1
}
