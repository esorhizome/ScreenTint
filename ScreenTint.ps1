# =====================================================================
#  ScreenTint.ps1  (v2)  -  a personal full-screen color filter for Windows
#  (c) 2026 esorhizome OU - CC BY 4.0 (creativecommons.org/licenses/by/4.0)
# =====================================================================
#  What this program does, in full:
#    1. Draws one borderless, click-through, always-on-top colored
#       window over each monitor (the "tint" veil).
#    2. NEW in v2: additionally lowers the display's blue/green output
#       through the graphics gamma table - the same mechanism Night
#       Light and f.lux use. Unlike a veil, this genuinely reduces
#       blue light and keeps blacks black. Restored on exit.
#    3. Shows a tray icon with a settings panel: five color presets,
#       a custom color, a tint slider, a blue-light slider, on/off,
#       a day/night schedule, and a start-with-Windows box.
#    4. Remembers your choices in "settings.json" next to this file.
#
#  What it deliberately does NOT do:
#    - It never reads your screen. It only draws over it and adjusts
#      the gamma table. (No screen-reading code exists in this file.)
#    - It never touches the network. There is no networking code of
#      any kind here - you can verify with Ctrl+F (see README).
#    - It never logs keys. The only keyboard code is RegisterHotKey,
#      which asks Windows to deliver your three chosen shortcuts
#      and nothing else.
#    - It needs no administrator rights. Its only registry write is
#      one autostart entry for your own user account, created only if
#      you tick "Start with Windows" (removed when you untick).
#
#  Hotkeys (change them in settings.json, "hotkeys" section):
#      toggle = Ctrl+Shift+F9      filter on/off
#      up     = Ctrl+Shift+F12     tint intensity +5%
#      down   = Ctrl+Shift+F11     tint intensity -5%
#  Format: modifiers Ctrl / Alt / Shift / Win joined with "+", then one
#  key: A-Z, 0-9, F1-F24, Home, End, PgUp, PgDn, Up, Down, Left, Right,
#  Space, Tab, Ins, Del, Pause. "none" disables a hotkey. Use the tray
#  menu's "Reload settings.json" after editing.
#
#  Panel too small? Set "panelFontSize" in settings.json (7-24) and
#  reload - the whole panel scales with it.
#
#  Run it with "Start ScreenTint.cmd" (same folder), or:
#    powershell -NoProfile -Sta -ExecutionPolicy Bypass -File ScreenTint.ps1
# =====================================================================

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# --- Editable defaults -----------------------------------------------
$Presets = @(
    @{ name = 'Pale yellow'; hex = '#F7F3C2' },
    @{ name = 'Yellow';      hex = '#F5C21B' },
    @{ name = 'Green';       hex = '#3DBE4B' },
    @{ name = 'Red';         hex = '#E63B2E' },
    @{ name = 'Black (dim)'; hex = '#000000' }
)
$MaxIntensity = 85       # tint cap, so the screen can never go fully dark
$RecommendedText = 'rec. 30-50'

# Blue-light curve: at slider 100%, blue output is multiplied by
# BlueFloor and green by GreenFloor. 0.50 is the deepest value Windows
# accepts without the optional gamma-range registry unlock (see README).
$BlueFloor  = 0.50
$GreenFloor = 0.70

# --- Session state ---------------------------------------------------
$script:ScriptPath   = $PSCommandPath
$script:SettingsPath = Join-Path (Split-Path -Parent $PSCommandPath) 'settings.json'
$script:Overlays     = @()
$script:OrigRamps    = @{}
$script:PrevIconH    = [IntPtr]::Zero
$script:UiSync       = $false
$script:DialogOpen   = $false
$script:EditProfile  = 'day'
$script:LastActive   = ''
$script:LastLayout   = ''
$script:TickN        = 0

# Default settings (used where settings.json is missing or invalid)
$script:S = @{
    enabled       = $true
    manualProfile = 'day'          # profile used when the schedule is off
    day           = @{ color = '#F7F3C2'; intensity = 40; blue = 25 }
    night         = @{ color = '#F5C21B'; intensity = 45; blue = 50 }
    schedule      = @{ enabled = $false; dayFrom = 8; dayTo = 18 }
    autostart     = $false
    panelFontSize = 10.5
    hotkeys       = @{ toggle = 'Ctrl+Shift+F9'; up = 'Ctrl+Shift+F12'; down = 'Ctrl+Shift+F11' }
}

# --- .NET / WinForms setup -------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Native helpers: window styles, topmost, DPI, hotkeys, gamma table.
# All plain user32/gdi32 calls - the same ones every desktop app uses.
if (-not ('ScreenTint.Native' -as [type])) {
Add-Type -ReferencedAssemblies 'System.Windows.Forms','System' -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace ScreenTint {
  public static class Native {
    [DllImport("user32.dll")] public static extern int  GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int  SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr hWnd, uint dwAffinity);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
    [DllImport("gdi32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr CreateDC(string driver, string device, string port, IntPtr initData);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern bool GetDeviceGammaRamp(IntPtr hDC, ushort[] ramp);
    [DllImport("gdi32.dll")] public static extern bool SetDeviceGammaRamp(IntPtr hDC, ushort[] ramp);
  }
  // Invisible message window that receives the registered hotkeys.
  public class HotkeyWindow : System.Windows.Forms.NativeWindow, IDisposable {
    public event Action<int> Pressed;
    public HotkeyWindow() { CreateHandle(new System.Windows.Forms.CreateParams()); }
    protected override void WndProc(ref System.Windows.Forms.Message m) {
      if (m.Msg == 0x0312) { var h = Pressed; if (h != null) h((int)m.WParam); }
      base.WndProc(ref m);
    }
    public void Dispose() { DestroyHandle(); }
  }
}
"@
}

# Crisp coordinates on high-DPI / mixed-DPI monitor setups.
try { $null = [ScreenTint.Native]::SetProcessDpiAwarenessContext([IntPtr](-4)) }
catch { try { $null = [ScreenTint.Native]::SetProcessDPIAware() } catch {} }

[System.Windows.Forms.Application]::EnableVisualStyles()

# --- Small helpers ---------------------------------------------------
function ColorFromHex([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
function HexFromColor($c) { '#{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B }
function Clamp-Intensity([int]$v) { [Math]::Max(0, [Math]::Min($MaxIntensity, $v)) }
function Clamp-Blue([int]$v) { [Math]::Max(0, [Math]::Min(100, $v)) }

function Load-Settings {
    if (-not (Test-Path $script:SettingsPath)) { return }
    try {
        $j = Get-Content -Path $script:SettingsPath -Raw | ConvertFrom-Json
        # Copy fields one by one, validating as we go - a corrupt or
        # hand-edited file can never crash the app or inject anything.
        if ($j.enabled -is [bool]) { $script:S.enabled = $j.enabled }
        if ($j.manualProfile -in @('day','night')) { $script:S.manualProfile = $j.manualProfile }
        foreach ($n in @('day','night')) {
            $p = $j.$n
            if ($p) {
                if ("$($p.color)" -match '^#[0-9A-Fa-f]{6}$') { $script:S[$n].color = "$($p.color)" }
                if ($null -ne $p.intensity) { try { $script:S[$n].intensity = Clamp-Intensity ([int]$p.intensity) } catch {} }
                if ($null -ne $p.blue)      { try { $script:S[$n].blue      = Clamp-Blue ([int]$p.blue) } catch {} }
            }
        }
        if ($j.schedule) {
            if ($j.schedule.enabled -is [bool]) { $script:S.schedule.enabled = $j.schedule.enabled }
            if ($null -ne $j.schedule.dayFrom) { try { $v = [int]$j.schedule.dayFrom; if ($v -ge 0 -and $v -le 23) { $script:S.schedule.dayFrom = $v } } catch {} }
            if ($null -ne $j.schedule.dayTo)   { try { $v = [int]$j.schedule.dayTo;   if ($v -ge 0 -and $v -le 24) { $script:S.schedule.dayTo   = $v } } catch {} }
        }
        if ($j.autostart -is [bool]) { $script:S.autostart = $j.autostart }
        try { $f = [double]$j.panelFontSize; if ($f -ge 7 -and $f -le 24) { $script:S.panelFontSize = $f } } catch {}
        if ($j.hotkeys) {
            foreach ($hk in @('toggle','up','down')) {
                $v = $j.hotkeys.$hk
                if ($v -is [string] -and $v.Length -le 40) { $script:S.hotkeys[$hk] = $v }
            }
        }
    } catch { }  # unreadable file -> keep defaults
}

function Save-Settings {
    try {
        $script:S | ConvertTo-Json -Depth 5 | Set-Content -Path $script:SettingsPath -Encoding UTF8
    } catch { }  # a failed save must never break the filter itself
}

function Get-ActiveProfileName {
    if ($script:S.schedule.enabled) {
        $h    = (Get-Date).Hour
        $from = [int]$script:S.schedule.dayFrom
        $to   = [int]$script:S.schedule.dayTo
        $isDay = if ($from -le $to) { ($h -ge $from) -and ($h -lt $to) }
                 else               { ($h -ge $from) -or  ($h -lt $to) }   # overnight span
        if ($isDay) { 'day' } else { 'night' }
    } else { $script:S.manualProfile }
}

# --- Hotkeys ---------------------------------------------------------
$script:NamedKeys = @{
    HOME = 0x24; END = 0x23; PGUP = 0x21; PAGEUP = 0x21; PGDN = 0x22; PAGEDOWN = 0x22
    INS = 0x2D; INSERT = 0x2D; DEL = 0x2E; DELETE = 0x2E; UP = 0x26; DOWN = 0x28
    LEFT = 0x25; RIGHT = 0x27; SPACE = 0x20; TAB = 0x09; PAUSE = 0x13; BACKSPACE = 0x08
}

function Parse-Hotkey([string]$spec) {
    # "Ctrl+Shift+F9" -> @{ mods = ..; vk = .. }, or $null if unusable
    if (-not $spec -or $spec.Trim() -match '^(?i)(none|off|0)$') { return $null }
    $mods = 0; $vk = -1
    foreach ($raw in ($spec -split '\+')) {
        $t = $raw.Trim().ToUpperInvariant()
        if     ($t -in @('CTRL','CONTROL'))  { $mods = $mods -bor 0x2 }
        elseif ($t -eq 'ALT')                { $mods = $mods -bor 0x1 }
        elseif ($t -eq 'SHIFT')              { $mods = $mods -bor 0x4 }
        elseif ($t -in @('WIN','WINDOWS'))   { $mods = $mods -bor 0x8 }
        elseif ($t -match '^F([1-9]|1[0-9]|2[0-4])$') { $vk = 0x6F + [int]$Matches[1] }
        elseif ($t -match '^[A-Z0-9]$')      { $vk = [int][char]$t }
        elseif ($script:NamedKeys.ContainsKey($t)) { $vk = $script:NamedKeys[$t] }
        else { return $null }   # unknown token -> treat whole spec as invalid
    }
    if ($vk -lt 0) { return $null }
    @{ mods = $mods; vk = $vk }
}

function Register-Hotkeys {
    if (-not $script:HK) { return }
    foreach ($id in 1..3) { $null = [ScreenTint.Native]::UnregisterHotKey($script:HK.Handle, $id) }
    $t = Parse-Hotkey $script:S.hotkeys.toggle
    $u = Parse-Hotkey $script:S.hotkeys.up
    $d = Parse-Hotkey $script:S.hotkeys.down
    # 0x4000 = no key-repeat (toggle only; up/down repeat while held)
    if ($t) { $null = [ScreenTint.Native]::RegisterHotKey($script:HK.Handle, 1, ($t.mods -bor 0x4000), $t.vk) }
    if ($u) { $null = [ScreenTint.Native]::RegisterHotKey($script:HK.Handle, 2, $u.mods, $u.vk) }
    if ($d) { $null = [ScreenTint.Native]::RegisterHotKey($script:HK.Handle, 3, $d.mods, $d.vk) }
}

# --- Gamma (true blue-light reduction) -------------------------------
function Get-DisplayNames {
    [System.Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.DeviceName }
}

function New-ScaledRamp($orig, [double]$rM, [double]$gM, [double]$bM) {
    # Scales the display's own gamma curve (or the identity curve when
    # none was captured), preserving any color calibration underneath.
    $ramp = New-Object 'System.UInt16[]' 768
    for ($i = 0; $i -lt 256; $i++) {
        $idn = $i * 257
        $r = if ($orig) { [double]$orig[$i] }       else { [double]$idn }
        $g = if ($orig) { [double]$orig[256 + $i] } else { [double]$idn }
        $b = if ($orig) { [double]$orig[512 + $i] } else { [double]$idn }
        $ramp[$i]       = [uint16][Math]::Max(0, [Math]::Min(65535, $r * $rM))
        $ramp[256 + $i] = [uint16][Math]::Max(0, [Math]::Min(65535, $g * $gM))
        $ramp[512 + $i] = [uint16][Math]::Max(0, [Math]::Min(65535, $b * $bM))
    }
    ,$ramp
}

function Save-OriginalRamps {
    # Remember each display's current curve once, so exit can restore it.
    foreach ($d in Get-DisplayNames) {
        if ($script:OrigRamps.ContainsKey($d)) { continue }
        $dc = [ScreenTint.Native]::CreateDC($null, $d, $null, [IntPtr]::Zero)
        if ($dc -eq [IntPtr]::Zero) { continue }
        try {
            $r = New-Object 'System.UInt16[]' 768
            if ([ScreenTint.Native]::GetDeviceGammaRamp($dc, $r)) { $script:OrigRamps[$d] = $r }
        } finally { $null = [ScreenTint.Native]::DeleteDC($dc) }
    }
}

function Apply-Gamma([int]$blue) {
    $blue = Clamp-Blue $blue
    if ($blue -le 0) { Restore-Ramps; return }
    $bM = 1.0 - (1.0 - $BlueFloor)  * ($blue / 100.0)
    $gM = 1.0 - (1.0 - $GreenFloor) * ($blue / 100.0)
    foreach ($d in Get-DisplayNames) {
        $dc = [ScreenTint.Native]::CreateDC($null, $d, $null, [IntPtr]::Zero)
        if ($dc -eq [IntPtr]::Zero) { continue }
        try {
            $orig = $null
            if ($script:OrigRamps.ContainsKey($d)) { $orig = $script:OrigRamps[$d] }
            $ok = [ScreenTint.Native]::SetDeviceGammaRamp($dc, (New-ScaledRamp $orig 1.0 $gM $bM))
            if (-not $ok -and $orig) {
                # A calibrated curve scaled down may leave Windows' accepted
                # range; fall back to scaling the plain identity curve.
                $null = [ScreenTint.Native]::SetDeviceGammaRamp($dc, (New-ScaledRamp $null 1.0 $gM $bM))
            }
        } finally { $null = [ScreenTint.Native]::DeleteDC($dc) }
    }
}

function Restore-Ramps {
    foreach ($d in Get-DisplayNames) {
        $dc = [ScreenTint.Native]::CreateDC($null, $d, $null, [IntPtr]::Zero)
        if ($dc -eq [IntPtr]::Zero) { continue }
        try {
            $r = if ($script:OrigRamps.ContainsKey($d)) { $script:OrigRamps[$d] } else { New-ScaledRamp $null 1.0 1.0 1.0 }
            $null = [ScreenTint.Native]::SetDeviceGammaRamp($dc, $r)
        } finally { $null = [ScreenTint.Native]::DeleteDC($dc) }
    }
}

function Reset-Gamma {
    # Escape hatch: push a clean identity curve to every display and
    # re-capture it as the baseline (useful if colors ever look stuck).
    foreach ($d in Get-DisplayNames) {
        $dc = [ScreenTint.Native]::CreateDC($null, $d, $null, [IntPtr]::Zero)
        if ($dc -eq [IntPtr]::Zero) { continue }
        try { $null = [ScreenTint.Native]::SetDeviceGammaRamp($dc, (New-ScaledRamp $null 1.0 1.0 1.0)) }
        finally { $null = [ScreenTint.Native]::DeleteDC($dc) }
    }
    $script:OrigRamps = @{}
    Save-OriginalRamps
    Apply-Tint
}

# --- The overlay windows (the tint veil) -----------------------------
function New-Overlay($bounds) {
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
    $f.ShowInTaskbar   = $false
    $f.Text            = 'ScreenTint overlay'
    $f.BackColor       = [System.Drawing.Color]::Black
    $f.Opacity         = 0.01
    $f.TopMost         = $true
    $f.Bounds          = $bounds
    $null = $f.Handle   # create the window handle so we can adjust its style

    # Make it click-through and invisible to Alt+Tab:
    #   0x00080000 layered | 0x20 transparent (clicks pass through)
    #   0x80 toolwindow (no Alt+Tab entry) | 0x08000000 never steals focus
    $ex = [ScreenTint.Native]::GetWindowLong($f.Handle, -20)
    $null = [ScreenTint.Native]::SetWindowLong($f.Handle, -20, ($ex -bor 0x00080000 -bor 0x20 -bor 0x80 -bor 0x08000000))

    # Exclude the veil from screenshots & screen sharing (Win10 2004+),
    # so captures of your screen come out clean and untinted.
    $null = [ScreenTint.Native]::SetWindowDisplayAffinity($f.Handle, 0x11)

    $f.Show()
    $f.Bounds = $bounds   # re-assert exact bounds after Show
    return $f
}

function Get-LayoutSignature {
    ([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.Bounds.ToString() }) -join '|'
}

function Rebuild-Overlays {
    Save-OriginalRamps   # capture curves for any newly-arrived display
    foreach ($o in $script:Overlays) { try { $o.Close(); $o.Dispose() } catch {} }
    $script:Overlays = @()
    foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
        $script:Overlays += New-Overlay $scr.Bounds
    }
    $script:LastLayout = Get-LayoutSignature
    Apply-Tint
}

function Apply-Tint {
    $name = Get-ActiveProfileName
    $p    = $script:S[$name]
    $c    = ColorFromHex $p.color
    $op   = (Clamp-Intensity ([int]$p.intensity)) / 100.0
    foreach ($o in $script:Overlays) {
        if ($o -and -not $o.IsDisposed) {
            $o.BackColor = $c
            $o.Opacity   = $op
            $o.Visible   = [bool]$script:S.enabled
        }
    }
    if ($script:S.enabled -and (Clamp-Blue ([int]$p.blue)) -gt 0) { Apply-Gamma ([int]$p.blue) }
    else { Restore-Ramps }
    $script:LastActive = $name
    Update-TrayIcon
    Sync-Ui
}

# --- Tray icon -------------------------------------------------------
function Update-TrayIcon {
    if (-not $script:Tray) { return }
    $name = Get-ActiveProfileName
    $p    = $script:S[$name]
    $bmp  = New-Object System.Drawing.Bitmap 16, 16
    $g    = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    if ($script:S.enabled) {
        $br = New-Object System.Drawing.SolidBrush (ColorFromHex $p.color)
        $g.FillEllipse($br, 1, 1, 13, 13)
        $g.DrawEllipse([System.Drawing.Pens]::DimGray, 1, 1, 13, 13)
        $br.Dispose()
    } else {
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Gray), 2
        $g.DrawEllipse($pen, 2, 2, 11, 11)
        $pen.Dispose()
    }
    $g.Dispose()
    $h = $bmp.GetHicon()
    $script:Tray.Icon = [System.Drawing.Icon]::FromHandle($h)
    if ($script:PrevIconH -ne [IntPtr]::Zero) { $null = [ScreenTint.Native]::DestroyIcon($script:PrevIconH) }
    $script:PrevIconH = $h
    $bmp.Dispose()
    $state = if ($script:S.enabled) { '{0}: {1}% tint, {2}% blue cut' -f $name, $p.intensity, $p.blue } else { 'off' }
    $script:Tray.Text = 'ScreenTint - ' + $state
    if ($script:MenuToggle) { $script:MenuToggle.Checked = [bool]$script:S.enabled }
}

# --- Actions ---------------------------------------------------------
function Toggle-Filter {
    $script:S.enabled = -not $script:S.enabled
    Save-Settings
    Apply-Tint
}

function Nudge-Intensity([int]$delta) {
    $name = Get-ActiveProfileName
    $script:S[$name].intensity = Clamp-Intensity ([int]$script:S[$name].intensity + $delta)
    Save-Settings
    Apply-Tint
}

function Set-ProfileColor([string]$profile, [string]$hex) {
    $script:S[$profile].color = $hex
    Save-Settings
    Apply-Tint
}

function Set-Autostart([bool]$on) {
    # The app's ONLY registry write: one value under your user's Run key.
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    try {
        if ($on) {
            $cmd = '"{0}\powershell.exe" -NoProfile -Sta -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}"' -f $PSHOME, $script:ScriptPath
            Set-ItemProperty -Path $runKey -Name 'ScreenTint' -Value $cmd
        } else {
            Remove-ItemProperty -Path $runKey -Name 'ScreenTint' -ErrorAction SilentlyContinue
        }
    } catch { }
    $script:S.autostart = $on
    Save-Settings
}

# --- Settings panel --------------------------------------------------
# Built with auto-sizing flow layouts so it fits itself to any DPI,
# Windows text-size setting, or high-contrast theme - nothing clips.
function New-Row {
    $r = New-Object System.Windows.Forms.FlowLayoutPanel
    $r.AutoSize = $true
    $r.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $r.WrapContents = $false
    $r.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $r.Margin = New-Object System.Windows.Forms.Padding 0, 2, 0, 2
    $r
}

function New-AutoLabel([string]$text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.AutoSize = $true
    $l.Margin = New-Object System.Windows.Forms.Padding 3, 7, 3, 3
    $l
}

function Build-SettingsForm {
    $fs = [double]$script:S.panelFontSize
    $SF = New-Object System.Windows.Forms.Form
    $SF.Text            = 'ScreenTint'
    $SF.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedToolWindow
    $SF.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $SF.AutoSize        = $true
    $SF.AutoSizeMode    = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $SF.TopMost         = $true
    $SF.MaximizeBox     = $false
    $SF.Font            = New-Object System.Drawing.Font 'Segoe UI', ([single]$fs)

    $stack = New-Object System.Windows.Forms.FlowLayoutPanel
    $stack.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $stack.WrapContents  = $false
    $stack.AutoSize      = $true
    $stack.AutoSizeMode  = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $stack.Padding       = New-Object System.Windows.Forms.Padding 12
    $SF.Controls.Add($stack)

    $tips = New-Object System.Windows.Forms.ToolTip

    # Row: profile selector --------------------------------------------
    $row = New-Row
    $row.Controls.Add((New-AutoLabel 'Editing:'))
    $script:RadDay = New-Object System.Windows.Forms.RadioButton
    $script:RadDay.Text = 'Day'; $script:RadDay.AutoSize = $true
    $row.Controls.Add($script:RadDay)
    $script:RadNight = New-Object System.Windows.Forms.RadioButton
    $script:RadNight.Text = 'Night'; $script:RadNight.AutoSize = $true
    $row.Controls.Add($script:RadNight)
    $script:LblActive = New-AutoLabel ''
    $script:LblActive.ForeColor = [System.Drawing.SystemColors]::GrayText
    $row.Controls.Add($script:LblActive)
    $stack.Controls.Add($row)

    $profHandler = {
        if ($script:UiSync) { return }
        $script:EditProfile = if ($script:RadNight.Checked) { 'night' } else { 'day' }
        $script:S.manualProfile = $script:EditProfile
        Save-Settings
        Apply-Tint
    }
    $script:RadDay.add_CheckedChanged($profHandler)
    $script:RadNight.add_CheckedChanged($profHandler)

    # Row: color swatches ----------------------------------------------
    $row = New-Row
    $sw = [int][Math]::Max(34, $fs * 3.6)
    foreach ($pr in $Presets) {
        $b = New-Object System.Windows.Forms.Button
        $b.Size = New-Object System.Drawing.Size $sw, $sw
        $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::DimGray
        $b.BackColor = ColorFromHex $pr.hex
        $tips.SetToolTip($b, $pr.name)
        $b.Tag = $pr.hex
        $b.add_Click({ param($s, $e) Set-ProfileColor $script:EditProfile ([string]$s.Tag) })
        $row.Controls.Add($b)
    }
    $bCustom = New-Object System.Windows.Forms.Button
    $bCustom.AutoSize = $true; $bCustom.Text = 'More...'
    $tips.SetToolTip($bCustom, 'Pick any color')
    $bCustom.add_Click({
        $dlg = New-Object System.Windows.Forms.ColorDialog
        $dlg.FullOpen = $true
        $dlg.Color = ColorFromHex $script:S[$script:EditProfile].color
        $script:DialogOpen = $true
        try {
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                Set-ProfileColor $script:EditProfile (HexFromColor $dlg.Color)
            }
        } finally {
            $script:DialogOpen = $false
            $dlg.Dispose()
        }
    })
    $row.Controls.Add($bCustom)
    $stack.Controls.Add($row)

    # Rows: tint slider ------------------------------------------------
    $row = New-Row
    $row.Controls.Add((New-AutoLabel 'Tint strength'))
    $script:LblTintPct = New-AutoLabel ''
    $script:LblTintPct.ForeColor = [System.Drawing.SystemColors]::GrayText
    $row.Controls.Add($script:LblTintPct)
    $stack.Controls.Add($row)

    $script:TintSlider = New-Object System.Windows.Forms.TrackBar
    $script:TintSlider.Width = [int]($fs * 30)
    $script:TintSlider.Minimum = 0; $script:TintSlider.Maximum = $MaxIntensity
    $script:TintSlider.TickFrequency = 5; $script:TintSlider.SmallChange = 1; $script:TintSlider.LargeChange = 5
    $script:TintSlider.add_ValueChanged({
        if ($script:UiSync) { return }
        $script:S[$script:EditProfile].intensity = $script:TintSlider.Value
        Save-Settings
        Apply-Tint
    })
    $stack.Controls.Add($script:TintSlider)

    # Rows: blue-light slider ------------------------------------------
    $row = New-Row
    $row.Controls.Add((New-AutoLabel 'Blue-light cut'))
    $script:LblBluePct = New-AutoLabel ''
    $script:LblBluePct.ForeColor = [System.Drawing.SystemColors]::GrayText
    $row.Controls.Add($script:LblBluePct)
    $stack.Controls.Add($row)

    $script:BlueSlider = New-Object System.Windows.Forms.TrackBar
    $script:BlueSlider.Width = [int]($fs * 30)
    $script:BlueSlider.Minimum = 0; $script:BlueSlider.Maximum = 100
    $script:BlueSlider.TickFrequency = 10; $script:BlueSlider.SmallChange = 5; $script:BlueSlider.LargeChange = 10
    $script:BlueSlider.add_ValueChanged({
        if ($script:UiSync) { return }
        $script:S[$script:EditProfile].blue = $script:BlueSlider.Value
        Save-Settings
        Apply-Tint
    })
    $stack.Controls.Add($script:BlueSlider)

    # Row: on/off ------------------------------------------------------
    $script:ChkOn = New-Object System.Windows.Forms.CheckBox
    $script:ChkOn.Text = 'Filter on'; $script:ChkOn.AutoSize = $true
    $script:ChkOn.add_CheckedChanged({
        if ($script:UiSync) { return }
        $script:S.enabled = $script:ChkOn.Checked
        Save-Settings
        Apply-Tint
    })
    $stack.Controls.Add($script:ChkOn)

    # Row: schedule ----------------------------------------------------
    $row = New-Row
    $script:ChkSched = New-Object System.Windows.Forms.CheckBox
    $script:ChkSched.Text = 'Auto day/night'; $script:ChkSched.AutoSize = $true
    $script:ChkSched.add_CheckedChanged({
        if ($script:UiSync) { return }
        $script:S.schedule.enabled = $script:ChkSched.Checked
        Save-Settings
        Apply-Tint
    })
    $row.Controls.Add($script:ChkSched)
    $row.Controls.Add((New-AutoLabel 'day from'))
    $script:NumFrom = New-Object System.Windows.Forms.NumericUpDown
    $script:NumFrom.Width = [int]($fs * 5); $script:NumFrom.Minimum = 0; $script:NumFrom.Maximum = 23
    $script:NumFrom.add_ValueChanged({
        if ($script:UiSync) { return }
        $script:S.schedule.dayFrom = [int]$script:NumFrom.Value
        Save-Settings
        Apply-Tint
    })
    $row.Controls.Add($script:NumFrom)
    $row.Controls.Add((New-AutoLabel 'to'))
    $script:NumTo = New-Object System.Windows.Forms.NumericUpDown
    $script:NumTo.Width = [int]($fs * 5); $script:NumTo.Minimum = 0; $script:NumTo.Maximum = 24
    $script:NumTo.add_ValueChanged({
        if ($script:UiSync) { return }
        $script:S.schedule.dayTo = [int]$script:NumTo.Value
        Save-Settings
        Apply-Tint
    })
    $row.Controls.Add($script:NumTo)
    $stack.Controls.Add($row)

    # Row: autostart ---------------------------------------------------
    $script:ChkAuto = New-Object System.Windows.Forms.CheckBox
    $script:ChkAuto.Text = 'Start with Windows'; $script:ChkAuto.AutoSize = $true
    $script:ChkAuto.add_CheckedChanged({
        if ($script:UiSync) { return }
        Set-Autostart $script:ChkAuto.Checked
    })
    $stack.Controls.Add($script:ChkAuto)

    # Rows: hints ------------------------------------------------------
    $script:LblKeys = New-AutoLabel ''
    $script:LblKeys.ForeColor = [System.Drawing.SystemColors]::GrayText
    $stack.Controls.Add($script:LblKeys)

    $lblNote = New-AutoLabel 'Panel size, hotkeys: edit settings.json, then tray > Reload.'
    $lblNote.ForeColor = [System.Drawing.SystemColors]::GrayText
    $stack.Controls.Add($lblNote)

    # Closing the panel hides it; the app lives in the tray.
    $SF.add_FormClosing({
        param($s, $e)
        if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $e.Cancel = $true
            $s.Hide()
        }
    })

    return $SF
}

function Sync-Ui {
    if (-not $script:SF -or -not $script:SF.Visible) { return }
    $script:UiSync = $true
    try {
        if ($script:EditProfile -eq 'night') { $script:RadNight.Checked = $true } else { $script:RadDay.Checked = $true }
        $script:LblActive.Text = '(active now: ' + (Get-ActiveProfileName) + ')'
        $ti = Clamp-Intensity ([int]$script:S[$script:EditProfile].intensity)
        $bl = Clamp-Blue ([int]$script:S[$script:EditProfile].blue)
        $script:TintSlider.Value = $ti
        $script:BlueSlider.Value = $bl
        $script:LblTintPct.Text  = ('{0}%  ({1})' -f $ti, $RecommendedText)
        $script:LblBluePct.Text  = ('{0}%' -f $bl)
        $script:ChkOn.Checked    = [bool]$script:S.enabled
        $script:ChkSched.Checked = [bool]$script:S.schedule.enabled
        $script:NumFrom.Value    = [int]$script:S.schedule.dayFrom
        $script:NumTo.Value      = [int]$script:S.schedule.dayTo
        $script:ChkAuto.Checked  = [bool]$script:S.autostart
        $script:LblKeys.Text     = ('Hotkeys:  {0} = on/off      {1} / {2} = tint' -f `
            $script:S.hotkeys.toggle, $script:S.hotkeys.up, $script:S.hotkeys.down)
    } finally {
        $script:UiSync = $false
    }
}

function Show-Settings {
    $script:EditProfile = Get-ActiveProfileName
    $script:SF.Show()
    Sync-Ui
    $script:SF.Activate()
}

function Reload-Everything {
    Load-Settings
    Register-Hotkeys
    $wasVisible = $script:SF -and $script:SF.Visible
    try { $script:SF.Dispose() } catch {}
    $script:SF = Build-SettingsForm
    Apply-Tint
    if ($wasVisible) { Show-Settings }
}

# --- Shutdown --------------------------------------------------------
function Stop-App {
    try { foreach ($id in 1..3) { $null = [ScreenTint.Native]::UnregisterHotKey($script:HK.Handle, $id) } } catch {}
    try { $script:HK.Dispose() } catch {}
    try { Restore-Ramps } catch {}
    try { $script:Tray.Visible = $false; $script:Tray.Dispose() } catch {}
    foreach ($o in $script:Overlays) { try { $o.Close(); $o.Dispose() } catch {} }
    Save-Settings
    [System.Windows.Forms.Application]::Exit()
}

# =====================================================================
#  Main
# =====================================================================
try {
    # Only one copy at a time.
    $script:Mutex = New-Object System.Threading.Mutex($false, 'Local\ScreenTintSingleInstance')
    $haveLock = $false
    try { $haveLock = $script:Mutex.WaitOne(0, $false) } catch { $haveLock = $true }
    if (-not $haveLock) {
        $null = [System.Windows.Forms.MessageBox]::Show('ScreenTint is already running - look for its colored dot in the system tray.', 'ScreenTint')
        exit
    }

    Load-Settings

    # Tray icon + menu
    $script:Tray = New-Object System.Windows.Forms.NotifyIcon
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miOpen = $menu.Items.Add('Open settings')
    $miOpen.add_Click({ Show-Settings })
    $script:MenuToggle = $menu.Items.Add('Filter on')
    $script:MenuToggle.add_Click({ Toggle-Filter })
    $miReload = $menu.Items.Add('Reload settings.json')
    $miReload.add_Click({ Reload-Everything })
    $miReset = $menu.Items.Add('Reset display colors')
    $miReset.add_Click({ Reset-Gamma })
    $null = $menu.Items.Add('-')
    $miExit = $menu.Items.Add('Exit ScreenTint')
    $miExit.add_Click({ Stop-App })
    $script:Tray.ContextMenuStrip = $menu
    $script:Tray.add_MouseUp({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Settings }
    })
    $script:Tray.Visible = $true

    # Settings panel (hidden until asked for)
    $script:SF = Build-SettingsForm

    # The filter itself
    Rebuild-Overlays

    # Hotkeys (configurable in settings.json)
    $script:HK = New-Object ScreenTint.HotkeyWindow
    Register-Hotkeys
    $script:HK.add_Pressed([System.Action[int]]{
        param($id)
        switch ($id) {
            1 { Toggle-Filter }
            2 { Nudge-Intensity 5 }
            3 { Nudge-Intensity -5 }
        }
    })

    # Maintenance timer: keep the veil on top (other always-on-top apps,
    # like PowerToys, jump the queue - we politely jump back), follow
    # monitor changes, switch day/night on schedule, and periodically
    # re-assert gamma in case Night Light or a game overwrote it.
    $script:Timer = New-Object System.Windows.Forms.Timer
    $script:Timer.Interval = 1500
    $script:Timer.add_Tick({
        try {
            $script:TickN++
            if ((Get-LayoutSignature) -ne $script:LastLayout) { Rebuild-Overlays; return }
            if ((Get-ActiveProfileName) -ne $script:LastActive) { Apply-Tint; return }
            if (-not $script:DialogOpen) {
                foreach ($o in $script:Overlays) {
                    if ($o -and -not $o.IsDisposed -and $o.Visible) {
                        # HWND_TOPMOST = -1; NOMOVE|NOSIZE|NOACTIVATE = 0x13
                        $null = [ScreenTint.Native]::SetWindowPos($o.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x13)
                    }
                }
                # Keep the settings panel readable above its own veil.
                if ($script:SF -and $script:SF.Visible) {
                    $null = [ScreenTint.Native]::SetWindowPos($script:SF.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x13)
                }
            }
            if (($script:TickN % 10) -eq 0 -and $script:S.enabled) {
                $p = $script:S[(Get-ActiveProfileName)]
                if ((Clamp-Blue ([int]$p.blue)) -gt 0) { Apply-Gamma ([int]$p.blue) }
            }
        } catch { }
    })
    $script:Timer.Start()

    # Keep the autostart entry in sync (also heals the path after the
    # folder holding this script is moved or renamed).
    if ($script:S.autostart) { Set-Autostart $true }

    # Hand control to the Windows message loop until Exit is chosen.
    $ctx = New-Object System.Windows.Forms.ApplicationContext
    [System.Windows.Forms.Application]::Run($ctx)
}
catch {
    $msg = "ScreenTint hit an unexpected error and will close:`r`n`r`n" + $_.Exception.Message
    try { Restore-Ramps } catch {}
    try { $null = [System.Windows.Forms.MessageBox]::Show($msg, 'ScreenTint') } catch { Write-Host $msg }
}
