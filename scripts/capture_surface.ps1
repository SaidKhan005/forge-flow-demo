#requires -Version 5.1
# Capture an Android emulator (or physical device) screenshot and produce
# both a full-res evidence PNG and a downscaled thumbnail safe for inclusion
# in an Anthropic many-image request (<= 1600px on the long side; the API
# cap is 2000px, so 1600 leaves headroom).
#
# Usage (from the worktree root):
#   . ./scripts/capture_surface.ps1
#   Capture-Surface p1_05_benchmark_default
#   Capture-Surface p1_06_benchmark_star_shift -Device R5CW503HJHP   # physical
#   Capture-Surface p2_01_splash -Pass 2
#
# Full-res lands at:
#   docs/_audits/wave_2/phase_2_walkthrough_evidence/mobile/<name>.png
# Thumbnail (resized for Claude) lands at:
#   docs/_audits/wave_2/phase_2_walkthrough_evidence/mobile/thumbs/<name>.png
#
# Discipline:
#   - Capture every surface to the evidence dir at full res; that is the
#     durable audit record.
#   - Only Read the thumbnail in Claude when investigating an anomaly. The
#     matrix annotation, not the image, is the work output.
#   - Pixel 9 emulator produces 1080x2424. The 2424 exceeds Anthropic's
#     2000px many-image cap, which is why we always thumb.

function Resize-Png {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination,
        [int]$MaxDimension = 1600
    )
    Add-Type -AssemblyName System.Drawing
    # GDI+ resolves paths against the CLR working directory, not PowerShell's
    # $PWD. Always pass absolute paths to FromFile / Save.
    $absSource = (Resolve-Path -LiteralPath $Source).ProviderPath
    $destDir = Split-Path -Parent $Destination
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir | Out-Null }
    $absDest = [System.IO.Path]::GetFullPath((Join-Path (Resolve-Path -LiteralPath $destDir).ProviderPath (Split-Path -Leaf $Destination)))
    $src = [System.Drawing.Image]::FromFile($absSource)
    try {
        $longSide = [Math]::Max($src.Width, $src.Height)
        if ($longSide -le $MaxDimension) {
            Copy-Item -LiteralPath $absSource -Destination $absDest -Force
            return [pscustomobject]@{ Width = $src.Width; Height = $src.Height; Scaled = $false }
        }
        $ratio = $MaxDimension / $longSide
        $w = [int]($src.Width * $ratio)
        $h = [int]($src.Height * $ratio)
        $dst = New-Object System.Drawing.Bitmap $w, $h
        $g = [System.Drawing.Graphics]::FromImage($dst)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.DrawImage($src, 0, 0, $w, $h)
        $dst.Save($absDest, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $dst.Dispose()
        return [pscustomobject]@{ Width = $w; Height = $h; Scaled = $true }
    } finally {
        $src.Dispose()
    }
}

function Capture-Surface {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [string]$Device = 'emulator-5554',
        [ValidateRange(1,3)][int]$Pass = 1,
        [int]$MaxDimension = 1600
    )

    $adb = 'C:/Users/saidu/AppData/Local/Android/Sdk/platform-tools/adb.exe'
    if (-not (Test-Path $adb)) { throw "adb not found at $adb" }

    $base = 'docs/_audits/wave_2/phase_2_walkthrough_evidence/mobile'
    $thumbs = "$base/thumbs"
    if (-not (Test-Path $base))   { New-Item -ItemType Directory -Path $base   | Out-Null }
    if (-not (Test-Path $thumbs)) { New-Item -ItemType Directory -Path $thumbs | Out-Null }

    $full  = Join-Path $base   "$Name.png"
    $thumb = Join-Path $thumbs "$Name.png"

    # PowerShell 5.1's byte-pipe is broken for native exe stdout, so we go
    # the longer way: screencap to /sdcard, then adb pull. Cleaned up after.
    $absFull = [System.IO.Path]::GetFullPath((Join-Path (Resolve-Path -LiteralPath $base).ProviderPath "$Name.png"))
    $remote = "/sdcard/_capture_surface_tmp.png"
    & $adb -s $Device shell screencap -p $remote | Out-Null
    & $adb -s $Device pull $remote $absFull | Out-Null
    & $adb -s $Device shell rm -f $remote | Out-Null
    if (-not (Test-Path $absFull) -or (Get-Item $absFull).Length -lt 100) {
        throw "screencap failed for device $Device (output missing or empty: $absFull)"
    }
    $full = $absFull

    $info = Resize-Png -Source $full -Destination $thumb -MaxDimension $MaxDimension

    $size = (Get-Item $full).Length
    $sizeKb = [Math]::Round($size / 1KB, 1)
    $thumbKb = [Math]::Round((Get-Item $thumb).Length / 1KB, 1)

    [pscustomobject]@{
        Name        = $Name
        Pass        = $Pass
        Device      = $Device
        FullPath    = $full
        FullSizeKb  = $sizeKb
        ThumbPath   = $thumb
        ThumbSizeKb = $thumbKb
        ThumbW      = $info.Width
        ThumbH      = $info.Height
        Scaled      = $info.Scaled
    }
}

function Thumb-Existing {
    # Backfill thumbnails for full-res screenshots that predate this script.
    param([int]$MaxDimension = 1600)
    $base = 'docs/_audits/wave_2/phase_2_walkthrough_evidence/mobile'
    $thumbs = "$base/thumbs"
    if (-not (Test-Path $thumbs)) { New-Item -ItemType Directory -Path $thumbs | Out-Null }
    Get-ChildItem $base -Filter '*.png' -File | ForEach-Object {
        $dst = Join-Path $thumbs $_.Name
        if (-not (Test-Path $dst)) {
            $info = Resize-Png -Source $_.FullName -Destination $dst -MaxDimension $MaxDimension
            "{0} -> {1}x{2} (scaled={3})" -f $_.Name, $info.Width, $info.Height, $info.Scaled
        }
    }
}
