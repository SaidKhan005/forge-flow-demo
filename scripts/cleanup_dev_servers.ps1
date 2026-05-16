# Reap stuck dev servers + free their ports.
#
# Default scope: any process holding TCP 8181 or 8182 (the Operator Web
# Console and F&F Operations Console dev ports), plus immediate parent
# `powershell.exe` wrappers if their child flutter/dart died. The
# operator-web dev-CSP swap backup (`web/index.prod.html.bak`) is
# restored to `web/index.html` so the next run starts from the
# canonical production CSP — same idempotency `run_operator_web_dev.ps1`
# applies on its own entry / exit.
#
# Pass `-All` to additionally Stop-Process every `dart.exe`,
# `dartaotruntime.exe`, and `flutter.bat` started by the current user.
# Use only when the targeted port-owner cleanup did not free the port
# (e.g. a `flutter run` orphaned by a Ctrl-C that did not reach all
# child processes).
#
# Pass `-Quiet` to suppress the per-action log (used by
# `run_all_demo.ps1 -Foreground` on Ctrl-C reap).
#
# Pass `-SkipCspRestore` to leave `web/index.html` alone (handy when
# you stopped the server mid-edit and want to inspect the dev CSP).
#
# Examples:
#   scripts/cleanup_dev_servers.ps1
#   scripts/cleanup_dev_servers.ps1 -All
#   scripts/cleanup_dev_servers.ps1 -OperatorWebPort 9181 -AdminPort 9182
#   scripts/cleanup_dev_servers.ps1 -Quiet -SkipCspRestore

param(
  [int] $OperatorWebPort = 8181,

  [int] $AdminPort = 8182,

  [int[]] $ExtraPorts,

  [switch] $All,

  [switch] $Quiet,

  [switch] $SkipCspRestore
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

function Write-Reap {
  param([string] $Message)
  if (-not $script:Quiet) { Write-Host $Message }
}

function Stop-PortOwner {
  param([int] $Port)

  $conns = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  if (-not $conns) {
    Write-Reap "port $Port : free"
    return
  }
  foreach ($conn in $conns) {
    $procId = $conn.OwningProcess
    if (-not $procId -or $procId -eq 0) { continue }
    try {
      $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
      $name = if ($proc) { $proc.ProcessName } else { '<gone>' }
      Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
      Write-Reap "port $Port : stopped pid=$procId ($name)"
    } catch {
      Write-Reap "port $Port : pid=$procId stop failed - $($_.Exception.Message)"
    }
  }
}

$ports = @($OperatorWebPort, $AdminPort)
if ($ExtraPorts) { $ports += $ExtraPorts }
$ports = $ports | Sort-Object -Unique

foreach ($port in $ports) {
  Stop-PortOwner -Port $port
}

if ($All) {
  $names = @('dart', 'dartaotruntime', 'flutter')
  foreach ($name in $names) {
    $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
    if (-not $procs) {
      Write-Reap "${name}.exe : no processes"
      continue
    }
    foreach ($p in $procs) {
      try {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        Write-Reap "${name}.exe : stopped pid=$($p.Id) (started $($p.StartTime))"
      } catch {
        Write-Reap "${name}.exe : pid=$($p.Id) stop failed - $($_.Exception.Message)"
      }
    }
  }
}

if (-not $SkipCspRestore) {
  $indexPath  = Join-Path $repoRoot 'web\index.html'
  $backupPath = Join-Path $repoRoot 'web\index.prod.html.bak'
  if (Test-Path -LiteralPath $backupPath) {
    Copy-Item -LiteralPath $backupPath -Destination $indexPath -Force
    Remove-Item -LiteralPath $backupPath -Force
    Write-Reap "csp        : restored web/index.html from $backupPath"
  } else {
    Write-Reap 'csp        : no backup present, web/index.html untouched'
  }
}

# Re-verify ports are free.
$stillBound = 0
foreach ($port in $ports) {
  if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
    Write-Reap "WARNING: port $port still bound after cleanup. Re-run with -All."
    $stillBound++
  }
}

Write-Reap 'cleanup done.'
exit $stillBound
