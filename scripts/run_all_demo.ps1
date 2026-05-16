# One-tap demo launcher: spins up both web consoles in parallel.
#
# Operator Web Console -> port 8181 (lib/main_operator_web.dart)
# F&F Operations Console -> port 8182 (lib/main_admin.dart)
#
# Both run in `-Mode demo` (HP #2 writer-side switch) so there is no
# login, no onboarding, no proxy backend required. Logs go to
# `$env:TEMP\forge_flow_dev\` for the duration of the run.
#
# By default the script spawns both consoles as detached background
# processes and exits, so a terminal session is not blocked. The dev
# servers keep running until either:
#   * the operator runs `scripts/cleanup_dev_servers.ps1`, or
#   * the operator stops them via Stop-Process / Task Manager.
#
# Pass `-Foreground` to instead block the current shell until Ctrl-C.
# Ctrl-C then propagates to both child processes via the cleanup helper.
#
# Examples:
#   scripts/run_all_demo.ps1
#   scripts/run_all_demo.ps1 -Foreground
#   scripts/run_all_demo.ps1 -OperatorWebPort 9181 -AdminPort 9182
#   scripts/run_all_demo.ps1 -SkipAdmin            # operator-web only
#   scripts/run_all_demo.ps1 -SkipOperatorWeb      # admin only
#   scripts/run_all_demo.ps1 -PrintCommandOnly

param(
  [int] $OperatorWebPort = 8181,

  [int] $AdminPort = 8182,

  [switch] $SkipOperatorWeb,

  [switch] $SkipAdmin,

  # When set, block the current shell and reap both child processes on
  # Ctrl-C. Default = fire-and-forget; cleanup_dev_servers.ps1 reaps.
  [switch] $Foreground,

  # How long to wait for each port to bind before declaring failure.
  [int] $WaitForPortSeconds = 180,

  [switch] $PrintCommandOnly
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $env:TEMP 'forge_flow_dev'
if (-not (Test-Path -LiteralPath $logDir)) {
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Test-PortListening {
  param([int] $Port)
  return [bool] (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

function Wait-PortBind {
  param([int] $Port, [int] $TimeoutSeconds)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-PortListening -Port $Port) { return $true }
    Start-Sleep -Milliseconds 750
  }
  return $false
}

function Assert-PortFree {
  param([int] $Port, [string] $Label)
  if (Test-PortListening -Port $Port) {
    Write-Host "BLOCKED: port $Port is already in use by another process. Run scripts/cleanup_dev_servers.ps1 first, or pass a different -$Label port."
    exit 1
  }
}

function Start-Console {
  param(
    [string] $Label,
    [string] $Script,
    [string[]] $ScriptArgs,
    [int] $Port,
    [string] $LogFile
  )

  $argsList = @('-ExecutionPolicy', 'Bypass', '-File', $Script) + $ScriptArgs
  if ($script:PrintCommandOnly) {
    Write-Host "$Label -> powershell $($argsList -join ' ')"
    Write-Host "  log : $LogFile"
    Write-Host "  port: $Port"
    return $null
  }

  Write-Host "Launching $Label on port $Port..."
  $proc = Start-Process -FilePath 'powershell' `
    -ArgumentList $argsList `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $LogFile `
    -RedirectStandardError "$LogFile.err" `
    -PassThru `
    -WindowStyle Hidden
  Write-Host "  pid : $($proc.Id)"
  Write-Host "  log : $LogFile"
  return $proc
}

$launches = @()
if (-not $SkipOperatorWeb) {
  Assert-PortFree -Port $OperatorWebPort -Label 'OperatorWebPort'
  $launches += @{
    Label    = 'operator-web'
    Script   = (Join-Path $repoRoot 'scripts\run_operator_web_dev.ps1')
    Args     = @('-Mode', 'demo', '-WebPort', "$OperatorWebPort")
    Port     = $OperatorWebPort
    LogFile  = (Join-Path $logDir 'operator_web_demo.log')
  }
}
if (-not $SkipAdmin) {
  Assert-PortFree -Port $AdminPort -Label 'AdminPort'
  $launches += @{
    Label    = 'admin-console'
    Script   = (Join-Path $repoRoot 'scripts\run_admin_console_dev.ps1')
    Args     = @('-Mode', 'demo', '-WebServer', '-WebPort', "$AdminPort")
    Port     = $AdminPort
    LogFile  = (Join-Path $logDir 'admin_console_demo.log')
  }
}

if ($launches.Count -eq 0) {
  Write-Host 'BLOCKED: both -SkipOperatorWeb and -SkipAdmin were passed. Nothing to launch.'
  exit 1
}

$procs = @()
foreach ($launch in $launches) {
  $proc = Start-Console `
    -Label $launch.Label `
    -Script $launch.Script `
    -ScriptArgs $launch.Args `
    -Port $launch.Port `
    -LogFile $launch.LogFile
  if ($proc) { $procs += @{ Proc = $proc; Launch = $launch } }
}

if ($PrintCommandOnly) {
  exit 0
}

Write-Host ''
Write-Host "Waiting up to $WaitForPortSeconds s for each port to bind (first compile is slow)..."
$allReady = $true
foreach ($entry in $procs) {
  $label = $entry.Launch.Label
  $port  = $entry.Launch.Port
  if (Wait-PortBind -Port $port -TimeoutSeconds $WaitForPortSeconds) {
    Write-Host "  $label -> http://localhost:$port  (ready)"
  } else {
    Write-Host "  $label -> port $port DID NOT BIND in $WaitForPortSeconds s (check $($entry.Launch.LogFile))"
    $allReady = $false
  }
}

Write-Host ''
if ($allReady) {
  Write-Host 'Both consoles are up. Demo bypass: no login, no onboarding.'
} else {
  Write-Host 'Some consoles failed to bind. Check the log files above; run scripts/cleanup_dev_servers.ps1 to reap.'
}
Write-Host ''
Write-Host 'To stop everything: scripts/cleanup_dev_servers.ps1'

if (-not $Foreground) {
  if ($allReady) { exit 0 } else { exit 1 }
}

# Foreground mode: block until Ctrl-C, then reap children.
Write-Host 'Foreground mode: press Ctrl-C to stop both consoles.'
try {
  while ($true) {
    Start-Sleep -Seconds 1
    foreach ($entry in $procs) {
      if ($entry.Proc.HasExited) {
        Write-Host "$($entry.Launch.Label) exited (code=$($entry.Proc.ExitCode))."
      }
    }
  }
} finally {
  foreach ($entry in $procs) {
    if (-not $entry.Proc.HasExited) {
      Write-Host "Stopping $($entry.Launch.Label) (pid=$($entry.Proc.Id))..."
      Stop-Process -Id $entry.Proc.Id -Force -ErrorAction SilentlyContinue
    }
  }
  # Best-effort cleanup of orphaned flutter/dart children. The full reap
  # lives in scripts/cleanup_dev_servers.ps1; this is just enough to keep
  # ports free for the next launch.
  & (Join-Path $repoRoot 'scripts\cleanup_dev_servers.ps1') -Quiet -SkipCspRestore
}
