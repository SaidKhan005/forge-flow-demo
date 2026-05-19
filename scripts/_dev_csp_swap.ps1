# Shared dev-CSP swap helper for the Flutter web runners.
#
# `web/index.html` ships with a strict production CSP that does NOT allow
# `'unsafe-inline'` or `'unsafe-eval'`. Flutter Web's DDC dev compiler relies
# on both: it uses `eval()` to load Dart modules and injects inline script
# tags during hot reload. Without the relaxed dev CSP, every `flutter run`
# (admin or operator-web) loads the bundle, runs DDC, then dies at the first
# inline-eval with `Refused to execute inline script because it violates...`
# — the operator never gets past the splash.
#
# Both `scripts/run_operator_web_dev.ps1` and `scripts/run_admin_console_dev.ps1`
# serve files from the same `web/index.html`, so both need the swap. The swap
# is reversible: this helper backs the production file up to
# `web/index.prod.html.bak`, applies the dev-relaxed CSP, and restores the
# backup on exit. Idempotent: a prior interrupted run that left the backup
# behind is restored on entry before the new swap runs.
#
# The dev-relaxed CSP block is kept in sync with
# `scripts/apply_operator_web_dev_csp.sh` (Docker side) and the canonical
# block in `docs/archive/_audits/wave_2/phase_2_walkthrough_master_plan.md` Patch 1.
#
# Usage:
#
#   . (Join-Path $PSScriptRoot '_dev_csp_swap.ps1')
#   $repoRoot = Split-Path -Parent $PSScriptRoot
#   Begin-DevCspSwap -RepoRoot $repoRoot       # before invoking `flutter run`
#   try {
#     & flutter @argsList
#     $exitCode = $LASTEXITCODE
#   } finally {
#     End-DevCspSwap -RepoRoot $repoRoot       # on Ctrl-C, error, or normal exit
#   }
#   exit $exitCode
#
# For `-PrintCommandOnly` dry runs, call `Write-DevCspSwapNotice` instead so
# the operator can see the swap that would happen without modifying disk.

$script:DevCspMeta = @'
<meta http-equiv="Content-Security-Policy" content="
    default-src 'self' 'unsafe-inline' 'unsafe-eval';
    script-src 'self' 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' https://www.gstatic.com https://*.firebaseapp.com;
    style-src 'self' 'unsafe-inline' https://fonts.googleapis.com;
    img-src 'self' data: blob: https:;
    font-src 'self' data: https://fonts.gstatic.com;
    connect-src 'self' ws://localhost:* http://localhost:* https://www.gstatic.com https://fonts.gstatic.com https://*.googleapis.com https://*.firebaseio.com https://*.cloudfunctions.net wss://*.firebaseio.com https://admin-proxy.forgeflow.app https://proxy.forgeflow.app https://*.forgeflow.app https://*.run.app;
    frame-src 'self' https://*.firebaseapp.com;
    object-src 'none';
    base-uri 'self';
    form-action 'self';
  ">
'@

function Get-DevCspIndexPath {
  param([string] $RepoRoot)
  return (Join-Path $RepoRoot 'web\index.html')
}

function Get-DevCspBackupPath {
  param([string] $RepoRoot)
  return (Join-Path $RepoRoot 'web\index.prod.html.bak')
}

function Restore-FromDevCspBackup {
  param([string] $Target, [string] $Backup)

  if (Test-Path -LiteralPath $Backup) {
    Copy-Item -LiteralPath $Backup -Destination $Target -Force
    Remove-Item -LiteralPath $Backup -Force
    Write-Host "dev-csp-swap: restored production CSP from $Backup"
  }
}

function Apply-DevCsp {
  param([string] $Target)

  $html = Get-Content -LiteralPath $Target -Raw
  # Single-line regex with DOTALL so the `.*?` spans the multi-line CSP
  # block. Anchor on the opening `<meta http-equiv=...>` and the closing
  # `">` to avoid greedy matching downstream tags.
  $pattern = '(?s)<meta\s+http-equiv="Content-Security-Policy".*?">'
  $matches = [regex]::Matches($html, $pattern)
  if ($matches.Count -lt 1) {
    Write-Host 'BLOCKED: could not locate CSP <meta> tag in web/index.html'
    exit 1
  }
  $script:_devCspReplacementCount = 0
  $rewritten = [regex]::Replace(
    $html,
    $pattern,
    [System.Text.RegularExpressions.MatchEvaluator] {
      param($m)
      $script:_devCspReplacementCount = ($script:_devCspReplacementCount + 1)
      if ($script:_devCspReplacementCount -eq 1) { return $script:DevCspMeta }
      return $m.Value
    },
    [System.Text.RegularExpressions.RegexOptions]::Singleline
  )
  Set-Content -LiteralPath $Target -Value $rewritten -Encoding UTF8 -NoNewline
  Write-Host "dev-csp-swap: applied dev CSP to $Target"
}

function Begin-DevCspSwap {
  param([Parameter(Mandatory)][string] $RepoRoot)

  $indexPath = Get-DevCspIndexPath -RepoRoot $RepoRoot
  $backupPath = Get-DevCspBackupPath -RepoRoot $RepoRoot

  if (-not (Test-Path -LiteralPath $indexPath)) {
    Write-Host "BLOCKED: web/index.html not found at $indexPath"
    exit 1
  }

  # Idempotency: a prior interrupted run may have left a .bak behind, with
  # the on-disk index.html still carrying the dev CSP. Restore first so we
  # always start the swap from a known production-CSP baseline.
  Restore-FromDevCspBackup -Target $indexPath -Backup $backupPath

  Copy-Item -LiteralPath $indexPath -Destination $backupPath -Force
  Write-Host "dev-csp-swap: backed up production index.html to $backupPath"

  Apply-DevCsp -Target $indexPath
}

function End-DevCspSwap {
  param([Parameter(Mandatory)][string] $RepoRoot)

  $indexPath = Get-DevCspIndexPath -RepoRoot $RepoRoot
  $backupPath = Get-DevCspBackupPath -RepoRoot $RepoRoot
  Restore-FromDevCspBackup -Target $indexPath -Backup $backupPath
}

function Write-DevCspSwapNotice {
  param([Parameter(Mandatory)][string] $RepoRoot)

  $indexPath = Get-DevCspIndexPath -RepoRoot $RepoRoot
  $backupPath = Get-DevCspBackupPath -RepoRoot $RepoRoot
  Write-Host "dev-csp-swap: would apply dev CSP to $indexPath (backup at $backupPath) before flutter, then restore on exit."
}
