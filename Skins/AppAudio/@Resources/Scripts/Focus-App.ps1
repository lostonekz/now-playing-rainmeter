<#
.SYNOPSIS
    Brings a window to the front. Run by the widget when a row is clicked.

.DESCRIPTION
    Restores the window if it is minimized or hidden in the tray, then makes it the
    foreground window. Windows only lets the foreground process hand focus on; the
    click makes Rainmeter that process, and this script is its child, so the plain
    call normally succeeds. If it is refused anyway, a tapped Alt key - the usual
    workaround - unlocks it for one more try.

    Runs on Windows PowerShell 5.1.

    For a browser, the window alone is not enough: the sound may come from a tab that
    is not the active one. So the tab marked as playing audio is looked up at click
    time, selected, and its window used instead of the handle from the snapshot.

.PARAMETER Hwnd
    The window handle, as written to now.txt by Get-AppAudio.ps1.

.PARAMETER Process
    The app's process name, as written to now.txt. Browsers get the tab lookup.
#>

[CmdletBinding()]
param(
    [long]$Hwnd = 0,
    [string]$Process = ''
)

$ErrorActionPreference = 'Stop'

$browsers = @('chrome', 'msedge', 'brave', 'opera', 'vivaldi', 'arc')

if ($Process -and ($browsers -contains $Process.ToLowerInvariant())) {
    try {
        . (Join-Path $PSScriptRoot 'BrowserTabs.ps1')
        $tab = Find-AudioTab @(Get-Process -Name $Process -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
        if ($tab) {
            $tab.Element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
            $Hwnd = $tab.Hwnd
        }
    } catch {
        # Tab lookup is a bonus; the window from the snapshot still gets focused.
    }
}

if ($Hwnd -eq 0) { return }

Add-Type -Namespace AppAudio -Name Focus -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
'@

$h = [IntPtr]$Hwnd
# The window may have closed since the last snapshot.
if (-not [AppAudio.Focus]::IsWindow($h)) { return }

$SW_RESTORE = 9
if ([AppAudio.Focus]::IsIconic($h) -or -not [AppAudio.Focus]::IsWindowVisible($h)) {
    $null = [AppAudio.Focus]::ShowWindow($h, $SW_RESTORE)
}

if (-not [AppAudio.Focus]::SetForegroundWindow($h) -or [AppAudio.Focus]::GetForegroundWindow() -ne $h) {
    $VK_MENU = 0x12; $KEYEVENTF_KEYUP = 0x2
    [AppAudio.Focus]::keybd_event($VK_MENU, 0, 0, [UIntPtr]::Zero)
    [AppAudio.Focus]::keybd_event($VK_MENU, 0, $KEYEVENTF_KEYUP, [UIntPtr]::Zero)
    $null = [AppAudio.Focus]::SetForegroundWindow($h)
}
