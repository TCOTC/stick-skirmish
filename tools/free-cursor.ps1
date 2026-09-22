# 解除 Windows 的全局鼠标裁剪（ClipCursor）。
#
# 症状：鼠标被限制在屏幕的一小块区域里（常见是左上角），怎么都移不出来。
# 成因：浏览器进入"指针锁定"（pointer lock）时会调用 ClipCursor 把光标圈在窗口内；
#       如果那个进程异常退出、没来得及还原，限制就会留在系统里变成孤儿。
# 表现就是本次遇到的：裁剪区 (3,41)-(530,397)，而找遍所有窗口都没有尺寸吻合的，
#       说明设限制的那个窗口早就关了。
#
# 用法:  powershell -ExecutionPolicy Bypass -File tools/free-cursor.ps1

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class CursorClip {
  public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool ClipCursor(IntPtr rect);
  [DllImport("user32.dll")] public static extern bool GetClipCursor(out RECT r);
}
"@

$before = New-Object CursorClip+RECT
[void][CursorClip]::GetClipCursor([ref]$before)
Write-Host ("解除前: {0},{1} - {2},{3}" -f $before.Left, $before.Top, $before.Right, $before.Bottom)

# 传 NULL 表示"不限制"
[void][CursorClip]::ClipCursor([IntPtr]::Zero)

$after = New-Object CursorClip+RECT
[void][CursorClip]::GetClipCursor([ref]$after)
Write-Host ("解除后: {0},{1} - {2},{3}" -f $after.Left, $after.Top, $after.Right, $after.Bottom)
Write-Host ""
Write-Host "解除后的范围应等于整个屏幕。如果它马上又变回小矩形，"
Write-Host "说明还有活着的程序在持续设置这个限制（多半是某个还开着的浏览器窗口在指针锁定状态），"
Write-Host "在那里面按 Esc 退出，或者直接关掉那个窗口。"
