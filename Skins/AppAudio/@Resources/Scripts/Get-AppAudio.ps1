<#
.SYNOPSIS
    Watches which applications are playing audio and writes them for the Rainmeter widget.

.DESCRIPTION
    Audio: enumerates the Windows Core Audio sessions on every active output device and
    samples each session's peak meter ten times a second. A session counts as playing
    while its meter moves, and stays listed for a few seconds after it goes quiet so a
    pause between sentences or songs does not make the row flicker.

    Titles: the system media controls (the same feed as the volume flyout) give the
    track and artist for players, and the media title of the playing tab for browsers.
    Apps that publish no media session fall back to their window title - for a browser
    that is the active tab.

    Sessions are grouped by process name, because browsers and chat apps play through
    helper processes and often hold one session per output device.

    Runs as a single long-lived loop so the COM setup is paid once. A newer instance
    (the skin was refreshed) signals the running one to stop and takes over, and the
    loop exits by itself once Rainmeter is gone.

    Runs on Windows PowerShell 5.1.

.OUTPUTS
    Writes key=value lines to %APPDATA%\AppAudio\now.txt. Not JSON: window and track
    titles routinely contain quotes, and the WebParser regex would trip over escapes.
#>

[CmdletBinding()]
param(
    # Seconds between snapshots written for the skin.
    [int]$Interval = 2,

    # Seconds an app stays listed after its audio goes quiet.
    [int]$HoldSeconds = 6,

    # Number of rows the skin has room for.
    [int]$MaxSlots = 6,

    # Write one snapshot and exit, printing it. For testing by hand.
    [switch]$Once
)

$ErrorActionPreference = 'Stop'

$outputDir  = Join-Path $env:APPDATA 'AppAudio'
$outputPath = Join-Path $outputDir 'now.txt'
$utf8NoBom  = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# Peaks below this (-40 dBFS) are treated as silence. Music and speech peak far
# above it; a lower bar let near-silent streams - a wallpaper engine idling, a
# fade tail - show up as "playing" when nothing could be heard.
$audibleThreshold = 0.01

# Process names whose window title is the active tab.
$browsers = @('chrome', 'msedge', 'firefox', 'brave', 'opera', 'vivaldi', 'arc', 'zen', 'librewolf', 'waterfox')

# Media session ids that do not contain the process name.
$aumidAliases = @{
    '308046b0af4a39cb' = 'firefox'
    '6f193ccc56814779' = 'firefox'   # Firefox Nightly
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace AppAudio {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator {}

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
    }

    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int Item(int index, out IMMDevice device);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
    }

    [Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2 {
        [PreserveSig] int GetAudioSessionControl(IntPtr a, int b, out IntPtr c);
        [PreserveSig] int GetSimpleAudioVolume(IntPtr a, int b, out IntPtr c);
        [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator e);
    }

    [Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, out IAudioSessionControl2 s);
    }

    [Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2 {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName(IntPtr n);
        [PreserveSig] int SetDisplayName(IntPtr a, IntPtr b);
        [PreserveSig] int GetIconPath(IntPtr p);
        [PreserveSig] int SetIconPath(IntPtr a, IntPtr b);
        [PreserveSig] int GetGroupingParam(IntPtr g);
        [PreserveSig] int SetGroupingParam(IntPtr a, IntPtr b);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr a);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr a);
        [PreserveSig] int GetSessionIdentifier(IntPtr id);
        [PreserveSig] int GetSessionInstanceIdentifier(IntPtr id);
        [PreserveSig] int GetProcessId(out uint pid);
        [PreserveSig] int IsSystemSoundsSession();
    }

    [Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation {
        [PreserveSig] int GetPeakValue(out float peak);
    }

    [Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISimpleAudioVolume {
        [PreserveSig] int SetMasterVolume(float v, IntPtr g);
        [PreserveSig] int GetMasterVolume(out float v);
        [PreserveSig] int SetMute(int m, IntPtr g);
        [PreserveSig] int GetMute(out int m);
    }

    public class Session {
        public uint Pid;
        public float Peak;
        public float Volume;
        public bool Muted;
    }

    class Tracked {
        public uint Pid;
        public IAudioSessionControl2 Control;
        public IAudioMeterInformation Meter;
        public ISimpleAudioVolume Volume;
        public float Peak;
    }

    // Holds the live sessions between snapshots so the meters can be sampled
    // many times per snapshot without re-enumerating devices.
    public static class Tracker {
        static List<Tracked> sessions = new List<Tracked>();

        public static void Refresh() {
            var found = new List<Tracked>();
            var en = (IMMDeviceEnumerator)new MMDeviceEnumerator();
            IMMDeviceCollection devices;
            if (en.EnumAudioEndpoints(0, 1, out devices) != 0) return;   // eRender, DEVICE_STATE_ACTIVE
            int deviceCount;
            devices.GetCount(out deviceCount);
            var iid = typeof(IAudioSessionManager2).GUID;
            for (int d = 0; d < deviceCount; d++) {
                try {
                    IMMDevice device;
                    if (devices.Item(d, out device) != 0) continue;
                    object o;
                    if (device.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) continue;   // CLSCTX_ALL
                    IAudioSessionEnumerator se;
                    if (((IAudioSessionManager2)o).GetSessionEnumerator(out se) != 0) continue;
                    int count;
                    se.GetCount(out count);
                    for (int i = 0; i < count; i++) {
                        IAudioSessionControl2 s;
                        if (se.GetSession(i, out s) != 0) continue;
                        if (s.IsSystemSoundsSession() == 0) continue;   // S_OK = the system sounds session
                        int state;
                        s.GetState(out state);
                        if (state == 2) continue;   // AudioSessionStateExpired
                        var t = new Tracked();
                        t.Control = s;
                        s.GetProcessId(out t.Pid);
                        t.Meter = (IAudioMeterInformation)s;
                        t.Volume = (ISimpleAudioVolume)s;
                        found.Add(t);
                    }
                } catch (Exception) {
                    // A device unplugged mid-enumeration; skip it this round.
                }
            }
            sessions = found;
        }

        // Keeps the loudest peak seen since the last snapshot.
        public static void Sample() {
            foreach (var t in sessions) {
                try {
                    float p;
                    if (t.Meter.GetPeakValue(out p) == 0 && p > t.Peak) t.Peak = p;
                } catch (Exception) { }
            }
        }

        // Samples every stepMs for totalMs. Returns true if stop was signalled.
        // Lives here rather than in PowerShell, where the same loop cost ~10% of a core.
        public static bool SampleFor(int totalMs, int stepMs, System.Threading.WaitHandle stop) {
            var deadline = DateTime.UtcNow.AddMilliseconds(totalMs);
            do {
                Sample();
                if (stop != null) { if (stop.WaitOne(stepMs)) return true; }
                else System.Threading.Thread.Sleep(stepMs);
            } while (DateTime.UtcNow < deadline);
            return false;
        }

        public static List<Session> Snapshot() {
            var result = new List<Session>();
            foreach (var t in sessions) {
                try {
                    var s = new Session();
                    s.Pid = t.Pid;
                    s.Peak = t.Peak;
                    t.Volume.GetMasterVolume(out s.Volume);
                    int muted;
                    t.Volume.GetMute(out muted);
                    s.Muted = muted != 0;
                    result.Add(s);
                } catch (Exception) { }
                t.Peak = 0;
            }
            return result;
        }
    }
}
'@

# --- System media controls (WinRT) ---------------------------------------------------

Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]

$asTaskGeneric = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1

function Wait-WinRt {
    param($Operation, [type]$ResultType)
    $task = $asTaskGeneric.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    if (-not $task.Wait(2000)) { return $null }
    $task.Result
}

$mediaManager = $null
function Get-MediaManager {
    if (-not $script:mediaManager) {
        $script:mediaManager = Wait-WinRt ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
    }
    $script:mediaManager
}

# Process name the media session belongs to, or $null.
function Resolve-MediaOwner {
    param([string]$Aumid, [string[]]$Names)
    $a = $Aumid.ToLowerInvariant() -replace '\.exe$', ''
    if ($aumidAliases.ContainsKey($a)) { return $aumidAliases[$a] }
    foreach ($n in $Names) {
        $l = $n.ToLowerInvariant()
        if ($a -eq $l) { return $n }
    }
    # Packaged apps: "SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify"
    foreach ($n in $Names) {
        $l = $n.ToLowerInvariant()
        if ($l.Length -ge 3 -and $a.Contains($l)) { return $n }
    }
    $null
}

# Playing media sessions, keyed by owning process name. Paused sessions are ignored:
# a paused player says nothing about what is making sound right now.
function Get-PlayingMedia {
    param([string[]]$Names)
    $result = @{}
    $manager = Get-MediaManager
    if (-not $manager) { return $result }
    foreach ($session in $manager.GetSessions()) {
        try {
            if ($session.GetPlaybackInfo().PlaybackStatus -ne 'Playing') { continue }
            $owner = Resolve-MediaOwner $session.SourceAppUserModelId $Names
            if (-not $owner -or $result.ContainsKey($owner)) { continue }
            $props = Wait-WinRt ($session.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
            if ($props -and $props.Title) {
                $result[$owner] = [pscustomobject]@{ Title = $props.Title; Artist = $props.Artist }
            }
        } catch { }
    }
    $result
}

# --- Assembling a snapshot -------------------------------------------------------------

# Zero-width and bidi marks: Telegram and Edge put them in window titles. Built from
# code points so this file stays ASCII - 5.1 reads a BOM-less script as ANSI.
$invisibleMarks = '[{0}-{1}{2}-{3}{4}-{5}]' -f [char]0x200B, [char]0x200F, [char]0x202A, [char]0x202E, [char]0x2066, [char]0x2069

function ConvertTo-Line {
    param([string]$Text)
    if (-not $Text) { return '' }
    $t = ($Text -replace '[\r\n\t]+', ' ' -replace $invisibleMarks, '').Trim()
    if ($t.Length -gt 200) { $t = $t.Substring(0, 200) }
    $t
}

# "Instagram - Google Chrome" -> "Instagram"
function Remove-AppSuffix {
    param([string]$Title, [string]$AppName)
    if (-not $AppName) { return $Title }
    $pattern = '^(.*\S)\s+[-' + [char]0x2013 + [char]0x2014 + ']\s+' + [regex]::Escape($AppName) + '$'
    if ($Title -match $pattern) { return $Matches[1] }
    $Title
}

function Get-WindowTitle {
    param([string]$Name, [System.Diagnostics.Process[]]$Processes)
    $p = $Processes | Where-Object { $_.ProcessName -eq $Name -and $_.MainWindowTitle } | Select-Object -First 1
    if ($p) { ConvertTo-Line $p.MainWindowTitle } else { '' }
}

$lastHeard = @{}
$firstSeen = @{}
# Reading a description opens the exe's version resource; once per app is enough.
$displayNames = @{}
$seq = 0

function Get-Snapshot {
    $now = Get-Date
    $groups = @{}

    # One enumeration per snapshot. Get-Process -Id walks every process on
    # each call, and one call per session was most of the CPU this used.
    $processes = @(Get-Process)
    $byPid = @{}
    foreach ($p in $processes) { $byPid[[uint32]$p.Id] = $p }

    foreach ($s in [AppAudio.Tracker]::Snapshot()) {
        if ($s.Pid -eq 0) { continue }
        $proc = $byPid[$s.Pid]
        if (-not $proc) { continue }
        $name = $proc.ProcessName
        if (-not $groups.ContainsKey($name)) {
            $groups[$name] = [pscustomobject]@{
                Name = $name; Display = ''; Peak = 0.0; Volume = 0.0; AllMuted = $true
            }
        }
        $g = $groups[$name]
        if (-not $g.Display) {
            if (-not $displayNames.ContainsKey($name)) {
                $desc = $null
                try { $desc = $proc.Description } catch { }
                $displayNames[$name] = if ($desc) { ConvertTo-Line $desc } else { $name }
            }
            $g.Display = $displayNames[$name]
        }
        if ($s.Peak -gt $g.Peak) { $g.Peak = $s.Peak }
        if ($s.Volume -gt $g.Volume) { $g.Volume = $s.Volume }
        if (-not $s.Muted) { $g.AllMuted = $false }
        if ($s.Peak -ge $audibleThreshold) { $lastHeard[$name] = $now }
    }

    $media = Get-PlayingMedia @($groups.Keys)

    $visible = foreach ($g in $groups.Values) {
        $heard = $lastHeard.ContainsKey($g.Name) -and (($now - $lastHeard[$g.Name]).TotalSeconds -le $HoldSeconds)
        if ($heard -or $media.ContainsKey($g.Name)) {
            if (-not $firstSeen.ContainsKey($g.Name)) { $firstSeen[$g.Name] = $now }
            $g
        }
    }
    # Forget apps that dropped off, so they re-enter at the bottom next time.
    foreach ($k in @($firstSeen.Keys)) {
        if (-not ($visible | Where-Object { $_.Name -eq $k })) { $firstSeen.Remove($k) }
    }
    # Stable order: rows keep their place while they stay listed.
    $visible = @($visible | Sort-Object { $firstSeen[$_.Name] }, Name)

    $rows = foreach ($g in $visible) {
        $isBrowser = $browsers -contains $g.Name.ToLowerInvariant()
        $label = ''; $detail = ''
        if ($media.ContainsKey($g.Name)) {
            $m = $media[$g.Name]
            $title = ConvertTo-Line $m.Title
            $artist = ConvertTo-Line $m.Artist
            if ($isBrowser)  { $label = 'Tab';   $detail = $title }
            elseif ($artist) { $label = 'Track'; $detail = "$title $([char]0x00B7) $artist" }
            else             { $label = 'Media'; $detail = $title }
        } else {
            $title = Remove-AppSuffix (Get-WindowTitle $g.Name $processes) $g.Display
            if ($title -and $title -ne $g.Display) {
                $label = if ($isBrowser) { 'Tab' } else { 'Window' }
                $detail = $title
            }
        }
        $state = if ($g.AllMuted) { 'muted' }
                 elseif ($g.Peak -ge $audibleThreshold) { 'playing' }
                 else { 'quiet' }
        [pscustomobject]@{
            App    = $g.Display
            Label  = $label
            Detail = $detail
            Level  = [int][math]::Round($g.Volume * 100)
            State  = $state
        }
    }

    @($rows)
}

function Write-Snapshot {
    param([object[]]$Rows, [string]$Status = 'ok', [string]$Message = '')
    $script:seq++
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("status=$Status")
    $lines.Add("message=$(ConvertTo-Line $Message)")
    $lines.Add("count=$($Rows.Count)")
    $lines.Add("seq=$script:seq")
    $lines.Add("updated=$((Get-Date).ToString('HH:mm:ss'))")
    for ($i = 0; $i -lt $MaxSlots; $i++) {
        $n = $i + 1
        $r = if ($i -lt $Rows.Count) { $Rows[$i] } else { $null }
        $lines.Add("app$n=$(if ($r) { $r.App })")
        $lines.Add("label$n=$(if ($r) { $r.Label })")
        $lines.Add("detail$n=$(if ($r) { $r.Detail })")
        $lines.Add("level$n=$(if ($r) { $r.Level } else { 0 })")
        $lines.Add("state$n=$(if ($r) { $r.State })")
    }
    $text = ($lines -join "`n") + "`n"
    # Write beside and swap in, so WebParser never reads half a file.
    $tmp = "$outputPath.tmp"
    [System.IO.File]::WriteAllText($tmp, $text, $utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $outputPath -Force
    $text
}

# --- Main loop -------------------------------------------------------------------------

$sampleMs = 100
$intervalMs = [math]::Max(1, $Interval) * 1000

if ($Once) {
    [AppAudio.Tracker]::Refresh()
    $null = [AppAudio.Tracker]::SampleFor($intervalMs, $sampleMs, $null)
    Write-Snapshot (Get-Snapshot)
    return
}

# One loop at a time. A newer instance asks the running one to stop and waits for it.
$created = $false
$mutex = New-Object System.Threading.Mutex($false, 'Local\AppAudioRainmeter.Run')
$stop  = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\AppAudioRainmeter.Stop', [ref]$created)
try {
    $owned = $false
    try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        $null = $stop.Set()
        try { $owned = $mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { return }
    }
    $null = $stop.Reset()

    while ($true) {
        try {
            [AppAudio.Tracker]::Refresh()
            if ([AppAudio.Tracker]::SampleFor($intervalMs, $sampleMs, $stop)) { return }
            $null = Write-Snapshot (Get-Snapshot)
        } catch {
            $null = Write-Snapshot @() 'error' $_.Exception.Message
            $script:mediaManager = $null
            if ($stop.WaitOne(5000)) { return }
        }
        if (-not (Get-Process -Name Rainmeter -ErrorAction SilentlyContinue)) { return }
    }
} finally {
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
    $stop.Dispose()
}
