<#
.SYNOPSIS
    Builds the songbox .ico from the Android master PNG and installs it where the
    Windows runner and the single-file launcher both pick it up.
.DESCRIPTION
    Runs on Windows PowerShell 5.1 only. System.Drawing there is .NET Framework's;
    pwsh 7 ships a different one (Drawing.Common) and I do not want to bet the icon
    on that.

    Why the icon is generated instead of committed: the logo changed three times
    around 0.8.32-0.8.34 and a committed binary is exactly what the next logo change
    forgets to regenerate.

    Why the same file must also land in windows/runner/resources/app_icon.ico:
    the window class icon comes from that resource (win32_window.cpp loads
    IDI_APP_ICON), so whatever is in there is what the titlebar and the taskbar
    button draw. flutter create puts Flutter's own logo there, which is why the
    taskbar icon did not match the app.

    This script body is pure ASCII on purpose -- see the note in
    .github/workflows/windows-portable.yml about BOM-less UTF-8 and the ANSI code page.
#>
[CmdletBinding()]
param(
    [string]$Master = 'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
    [string]$Ico = '',
    [string]$RunnerResourceDir = '',
    [string]$VerifyExe = ''
)
$ErrorActionPreference = 'Stop'

function Say([string]$Message) { Write-Host $Message }

if (-not $Ico) {
    $root = $env:RUNNER_TEMP
    if (-not $root) { $root = $env:TEMP }
    $Ico = Join-Path $root 'songbox.ico'
}

# ---------------------------------------------------------------- build the ICO
$sizes = @(16, 24, 32, 48, 64, 96, 128, 192)
if (-not (Test-Path $Master)) { throw "icon master missing: $Master" }
Add-Type -AssemblyName System.Drawing
$srcImg = [System.Drawing.Image]::FromFile((Resolve-Path $Master).Path)
$blobs = @()
foreach ($s in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap $s, $s
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($srcImg, 0, 0, $s, $s)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $blobs += , $ms.ToArray()
    $ms.Dispose()
}
$srcImg.Dispose()

# PNG frames inside an ICO container (Vista and later desktops read it).
# Width/height bytes: 0 means 256, so anything below that must be literal --
# writing 0 for a 192 frame tells the desktop it is 256x256 and it resamples
# the wrong thing.
$icoDir = Split-Path -Parent $Ico
if ($icoDir -and -not (Test-Path $icoDir)) { New-Item -ItemType Directory -Force -Path $icoDir | Out-Null }
$ms2 = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms2)
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$sizes.Count)
$off = 6 + (16 * $sizes.Count)
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    $b = $blobs[$i]
    $w = $(if ($s -ge 256) { 0 } else { $s })
    $bw.Write([Byte]$w); $bw.Write([Byte]$w)
    $bw.Write([Byte]0); $bw.Write([Byte]0)
    $bw.Write([UInt16]1); $bw.Write([UInt16]32)
    $bw.Write([UInt32]$b.Length); $bw.Write([UInt32]$off)
    $off += $b.Length
}
foreach ($b in $blobs) { $bw.Write($b) }
$bw.Flush()
[System.IO.File]::WriteAllBytes($Ico, $ms2.ToArray())
$bw.Dispose(); $ms2.Dispose()
Say "ico: $((Get-Item $Ico).Length) bytes / $($sizes.Count) frames -> $Ico"

# ------------------------------------------------- install it into the runner rc
# Overwriting here is the whole fix: rc.exe compiles this file into lyric_music.exe
# as IDI_APP_ICON, and that is the icon the window class hands to the taskbar.
if ($RunnerResourceDir) {
    $target = Join-Path $RunnerResourceDir 'app_icon.ico'
    if (-not (Test-Path $RunnerResourceDir)) { throw "runner resources dir missing: $RunnerResourceDir" }
    if (-not (Test-Path $target)) { throw "template icon missing: $target" }
    $before = (Get-Item $target).Length
    Copy-Item -Path $Ico -Destination $target -Force
    $a = [System.IO.File]::ReadAllBytes($Ico)
    $b = [System.IO.File]::ReadAllBytes($target)
    if ($a.Length -ne $b.Length) { throw "icon copy length mismatch: $target" }
    for ($i = 0; $i -lt $b.Length; $i++) {
        if ($a[$i] -ne $b[$i]) { throw "icon copy differs at byte $i" }
    }
    Say "runner icon: replaced Flutter template icon ($before bytes) with ours ($($b.Length) bytes)"
}

# ------------------------------------ prove the shipped exe carries that resource
# When a .ico is compiled into an exe, each frame lands as its own RT_ICON resource
# with the bytes kept verbatim -- measured here with csc -win32icon, and rc.exe is the
# other half of this build. So the largest frame's bytes have to appear inside the
# built exe. If the copy above silently missed (template layout change, rc refusing
# the file), the build would still succeed and what she double-clicks would keep the
# Flutter logo -- hence this check biting instead.
if ($VerifyExe) {
    if (-not (Test-Path $VerifyExe)) { throw "exe to inspect missing: $VerifyExe" }
    $icoBytes = [System.IO.File]::ReadAllBytes($Ico)
    $frameCount = [BitConverter]::ToUInt16($icoBytes, 4)
    $biggest = 0
    $needle = $null
    for ($i = 0; $i -lt $frameCount; $i++) {
        $e = 6 + (16 * $i)
        $len = [BitConverter]::ToUInt32($icoBytes, $e + 8)
        $off2 = [BitConverter]::ToUInt32($icoBytes, $e + 12)
        if ($off2 + $len -gt $icoBytes.Length) { throw "ico frame $i runs past the file" }
        if ($len -gt $biggest) {
            $biggest = $len
            $needle = New-Object byte[] $len
            [Array]::Copy($icoBytes, $off2, $needle, 0, $len)
        }
    }
    if (-not $needle) { throw 'ico has no frames' }
    # Latin1 maps bytes to chars one-to-one, so an ordinal search finds raw bytes.
    $enc = [System.Text.Encoding]::GetEncoding(28591)
    $hay = $enc.GetString([System.IO.File]::ReadAllBytes($VerifyExe))
    if (-not $hay.Contains($enc.GetString($needle))) {
        throw "$VerifyExe does not carry our icon frame ($biggest bytes): taskbar would show the Flutter logo"
    }
    Say "exe icon verified: $([System.IO.Path]::GetFileName($VerifyExe)) embeds the $($biggest)-byte frame"
}
