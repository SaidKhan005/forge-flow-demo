# Wave 2 testing-prep -- single-command runner.
#
# Runs all four Wave 2 integration test harnesses in sequence,
# captures per-harness pass / skip / fail status, and prints a
# summary table at the end. Exit code is 0 if all REQUIRED
# harnesses pass; non-zero if any required harness fails.
#
# Harnesses
# ---------
# 1. Phase 4 emulator click-path     (REQUIRED -- always runs)
# 2. In-app notifications (Patrol)   (REQUIRED -- always runs)
# 3. Email soak (Mailosaur+SendGrid) (OPTIONAL -- skipped if MAILOSAUR_API_KEY unset)
# 4. Firebase Test Lab (push)        (OPTIONAL -- skipped if FIREBASE_TEST_LAB_PROJECT_ID unset)
#
# Usage
# -----
#   pwsh tool/wave_2_test_harness/run_all.ps1
#
# Optional parameters
#   -FlutterCommand <name>  Override the Flutter binary (default: flutter).
#   -DartCommand <name>     Override the Dart binary    (default: dart).
#   -OutputDir <path>       Where the dart harnesses write reports
#                           (default: test/wave_2_test_harness/<utc-ts>).
#   -SkipPhase4             Force-skip the Phase 4 emulator harness.
#   -SkipInAppNotifications Force-skip the in-app notifications harness.
#   -SkipEmailSoak          Force-skip the email soak harness regardless of env.
#   -SkipFirebaseTestLab    Force-skip the Firebase Test Lab harness regardless of env.
#
# Environment
# -----------
# Each harness owns its own env-gated-skip behavior. The runner only
# reads:
#   MAILOSAUR_API_KEY            -- gates the email soak harness.
#   FIREBASE_TEST_LAB_PROJECT_ID -- gates the Firebase Test Lab harness.
# Other env vars (MAILOSAUR_SERVER_ID, PROXY_URL, PROXY_ADMIN_TOKEN,
# EMAIL_SOAK_PROBE_TOKEN, FIREBASE_TEST_LAB_RESULTS_BUCKET, ...) are
# read inside the dart harness binaries -- see their READMEs:
#   - tool/email_soak/email_soak_orchestrator.dart
#   - tool/firebase_test_lab/README.md
#
# Demo-mode parity (HP #2)
# ------------------------
# Phase 4 emulator + in-app notifications run under
# `--dart-define=kDemoMode=true` so they exercise the SAME
# SQLite tables production reads from. The runner does NOT add or
# remove any `kDemoMode` carve-out.

param(
  [string]$FlutterCommand = "flutter",
  [string]$DartCommand = "dart",
  [string]$OutputDir = "",
  [switch]$SkipPhase4,
  [switch]$SkipInAppNotifications,
  [switch]$SkipEmailSoak,
  [switch]$SkipFirebaseTestLab
)

$ErrorActionPreference = "Continue"

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $ts = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
  $OutputDir = "test/wave_2_test_harness/$ts"
}

# Outcome enum: PASS / SKIP / FAIL
$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
  param(
    [string]$Name,
    [string]$Path,
    [string]$Status,    # PASS | SKIP | FAIL
    [int]$ExitCode,
    [string]$Reason,
    [string]$LogPath,
    [bool]$Required
  )
  $results.Add([pscustomobject]@{
      Name     = $Name
      Path     = $Path
      Status   = $Status
      ExitCode = $ExitCode
      Reason   = $Reason
      LogPath  = $LogPath
      Required = $Required
    })
}

function Write-Header {
  param([string]$Name, [string]$Path)
  Write-Host ""
  Write-Host "============================================================"
  Write-Host ">> Running $Name ($Path)"
  Write-Host "============================================================"
}

function Test-CommandAvailable {
  param([string]$Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# Stream a process's stdout + stderr to the console AND write the same
# text to $LogPath using UTF-8 (no BOM). Tee-Object's default encoding
# is UTF-16 on Windows PowerShell 5.1, which produces unreadable logs;
# this helper enforces UTF-8 so the file is consumable downstream.
function Invoke-AndLog {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$LogPath
  )
  # Truncate / create the log file with UTF-8 (no BOM).
  [System.IO.File]::WriteAllText($LogPath, "", (New-Object System.Text.UTF8Encoding $false))
  $sw = [System.IO.StreamWriter]::new($LogPath, $true, (New-Object System.Text.UTF8Encoding $false))
  try {
    # `2>&1` merges stderr into the pipeline. ForEach-Object writes each
    # line to console AND log without buffering the whole output.
    & $Executable @Arguments 2>&1 | ForEach-Object {
      $line = $_.ToString()
      Write-Host $line
      $sw.WriteLine($line)
    }
    return $LASTEXITCODE
  } finally {
    $sw.Flush()
    $sw.Close()
  }
}

# --- Output dir ----------------------------------------------------
if (-not (Test-Path $OutputDir)) {
  New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
Write-Host ""
Write-Host "Wave 2 testing-prep runner"
Write-Host "Output dir : $OutputDir"
Write-Host "Flutter cmd: $FlutterCommand"
Write-Host "Dart cmd   : $DartCommand"
Write-Host ""

# --- 1. Phase 4 emulator click-path -------------------------------
$phase4Name = "Phase 4 emulator click-path"
$phase4Path = "integration_test/phase_4_emulator/"
$phase4Log  = Join-Path $OutputDir "phase_4_emulator.log"

if ($SkipPhase4) {
  Write-Header $phase4Name $phase4Path
  Write-Host "[SKIPPED] -SkipPhase4 flag passed."
  Add-Result -Name $phase4Name -Path $phase4Path -Status "SKIP" -ExitCode 0 `
    -Reason "operator passed -SkipPhase4" -LogPath "" -Required $true
} elseif (-not (Test-CommandAvailable $FlutterCommand)) {
  Write-Header $phase4Name $phase4Path
  Write-Host "[SKIPPED] flutter command not found on PATH."
  Add-Result -Name $phase4Name -Path $phase4Path -Status "SKIP" -ExitCode 0 `
    -Reason "flutter not on PATH" -LogPath "" -Required $true
} else {
  Write-Header $phase4Name $phase4Path
  $exit = Invoke-AndLog -Executable $FlutterCommand -LogPath $phase4Log -Arguments @(
    'test',
    'integration_test/phase_4_emulator/',
    '--flavor', 'forgeflow',
    '--dart-define=kDemoMode=true'
  )
  if ($exit -eq 0) {
    Write-Host "[PASSED] $phase4Name (exit 0)" -ForegroundColor Green
    Add-Result -Name $phase4Name -Path $phase4Path -Status "PASS" -ExitCode 0 `
      -Reason "" -LogPath $phase4Log -Required $true
  } else {
    Write-Host "[FAILED] $phase4Name (exit $exit) -- see $phase4Log" -ForegroundColor Red
    Add-Result -Name $phase4Name -Path $phase4Path -Status "FAIL" -ExitCode $exit `
      -Reason "flutter test exit $exit" -LogPath $phase4Log -Required $true
  }
}

# --- 2. In-app notifications (Patrol) -----------------------------
$ianName = "In-app notifications (Patrol)"
$ianPath = "integration_test/in_app_notifications/"
$ianLog  = Join-Path $OutputDir "in_app_notifications.log"

if ($SkipInAppNotifications) {
  Write-Header $ianName $ianPath
  Write-Host "[SKIPPED] -SkipInAppNotifications flag passed."
  Add-Result -Name $ianName -Path $ianPath -Status "SKIP" -ExitCode 0 `
    -Reason "operator passed -SkipInAppNotifications" -LogPath "" -Required $true
} elseif (-not (Test-CommandAvailable $FlutterCommand)) {
  Write-Header $ianName $ianPath
  Write-Host "[SKIPPED] flutter command not found on PATH."
  Add-Result -Name $ianName -Path $ianPath -Status "SKIP" -ExitCode 0 `
    -Reason "flutter not on PATH" -LogPath "" -Required $true
} else {
  Write-Header $ianName $ianPath
  $exit = Invoke-AndLog -Executable $FlutterCommand -LogPath $ianLog -Arguments @(
    'test',
    'integration_test/in_app_notifications/',
    '--flavor', 'forgeflow',
    '--dart-define=kDemoMode=true'
  )
  if ($exit -eq 0) {
    Write-Host "[PASSED] $ianName (exit 0)" -ForegroundColor Green
    Add-Result -Name $ianName -Path $ianPath -Status "PASS" -ExitCode 0 `
      -Reason "" -LogPath $ianLog -Required $true
  } else {
    Write-Host "[FAILED] $ianName (exit $exit) -- see $ianLog" -ForegroundColor Red
    Add-Result -Name $ianName -Path $ianPath -Status "FAIL" -ExitCode $exit `
      -Reason "flutter test exit $exit" -LogPath $ianLog -Required $true
  }
}

# --- 3. Email soak (Mailosaur + SendGrid) -------------------------
$emailName = "Email soak (Mailosaur+SendGrid)"
$emailPath = "tool/email_soak/email_soak_orchestrator.dart"
$emailLog  = Join-Path $OutputDir "email_soak.log"
$emailOutput = Join-Path $OutputDir "email_soak.jsonl"

if ($SkipEmailSoak) {
  Write-Header $emailName $emailPath
  Write-Host "[SKIPPED] -SkipEmailSoak flag passed."
  Add-Result -Name $emailName -Path $emailPath -Status "SKIP" -ExitCode 0 `
    -Reason "operator passed -SkipEmailSoak" -LogPath "" -Required $false
} elseif ([string]::IsNullOrWhiteSpace($env:MAILOSAUR_API_KEY)) {
  Write-Header $emailName $emailPath
  Write-Host "[SKIPPED] MAILOSAUR_API_KEY not set -- wire MAILOSAUR_API_KEY + MAILOSAUR_SERVER_ID and re-run."
  Add-Result -Name $emailName -Path $emailPath -Status "SKIP" -ExitCode 0 `
    -Reason "MAILOSAUR_API_KEY not set" -LogPath "" -Required $false
} elseif (-not (Test-CommandAvailable $DartCommand)) {
  Write-Header $emailName $emailPath
  Write-Host "[SKIPPED] dart command not found on PATH."
  Add-Result -Name $emailName -Path $emailPath -Status "SKIP" -ExitCode 0 `
    -Reason "dart not on PATH" -LogPath "" -Required $false
} else {
  Write-Header $emailName $emailPath
  $exit = Invoke-AndLog -Executable $DartCommand -LogPath $emailLog -Arguments @(
    'run',
    $emailPath,
    "--output=$emailOutput"
  )
  if ($exit -eq 0) {
    Write-Host "[PASSED] $emailName (exit 0)" -ForegroundColor Green
    Add-Result -Name $emailName -Path $emailPath -Status "PASS" -ExitCode 0 `
      -Reason "" -LogPath $emailLog -Required $false
  } else {
    Write-Host "[FAILED] $emailName (exit $exit) -- see $emailLog" -ForegroundColor Red
    Add-Result -Name $emailName -Path $emailPath -Status "FAIL" -ExitCode $exit `
      -Reason "dart run exit $exit" -LogPath $emailLog -Required $false
  }
}

# --- 4. Firebase Test Lab ------------------------------------------
$ftlName = "Firebase Test Lab (push)"
$ftlPath = "tool/firebase_test_lab/firebase_test_lab_orchestrator.dart"
$ftlLog  = Join-Path $OutputDir "firebase_test_lab.log"
$ftlRunId = "wave2-prep-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")

if ($SkipFirebaseTestLab) {
  Write-Header $ftlName $ftlPath
  Write-Host "[SKIPPED] -SkipFirebaseTestLab flag passed."
  Add-Result -Name $ftlName -Path $ftlPath -Status "SKIP" -ExitCode 0 `
    -Reason "operator passed -SkipFirebaseTestLab" -LogPath "" -Required $false
} elseif ([string]::IsNullOrWhiteSpace($env:FIREBASE_TEST_LAB_PROJECT_ID)) {
  Write-Header $ftlName $ftlPath
  Write-Host "[SKIPPED] FIREBASE_TEST_LAB_PROJECT_ID not set -- see tool/firebase_test_lab/README.md."
  Add-Result -Name $ftlName -Path $ftlPath -Status "SKIP" -ExitCode 0 `
    -Reason "FIREBASE_TEST_LAB_PROJECT_ID not set" -LogPath "" -Required $false
} elseif (-not (Test-CommandAvailable $DartCommand)) {
  Write-Header $ftlName $ftlPath
  Write-Host "[SKIPPED] dart command not found on PATH."
  Add-Result -Name $ftlName -Path $ftlPath -Status "SKIP" -ExitCode 0 `
    -Reason "dart not on PATH" -LogPath "" -Required $false
} else {
  Write-Header $ftlName $ftlPath
  $exit = Invoke-AndLog -Executable $DartCommand -LogPath $ftlLog -Arguments @(
    'run',
    $ftlPath,
    "--output-dir=$OutputDir",
    "--run-id=$ftlRunId"
  )
  if ($exit -eq 0) {
    Write-Host "[PASSED] $ftlName (exit 0)" -ForegroundColor Green
    Add-Result -Name $ftlName -Path $ftlPath -Status "PASS" -ExitCode 0 `
      -Reason "" -LogPath $ftlLog -Required $false
  } else {
    Write-Host "[FAILED] $ftlName (exit $exit) -- see $ftlLog" -ForegroundColor Red
    Add-Result -Name $ftlName -Path $ftlPath -Status "FAIL" -ExitCode $exit `
      -Reason "dart run exit $exit" -LogPath $ftlLog -Required $false
  }
}

# --- Summary -------------------------------------------------------
Write-Host ""
Write-Host "============================================================"
Write-Host "Wave 2 Test Harness Summary"
Write-Host "============================================================"

$passRow = "[PASS]"
$failRow = "[FAIL]"
$skipRow = "[SKIP]"

foreach ($r in $results) {
  $marker = switch ($r.Status) {
    "PASS" { $passRow }
    "FAIL" { $failRow }
    "SKIP" { $skipRow }
    default { "[????]" }
  }
  $detail = switch ($r.Status) {
    "PASS" { "exit 0" }
    "FAIL" { "exit $($r.ExitCode) -- see $($r.LogPath)" }
    "SKIP" { "SKIPPED -- $($r.Reason)" }
    default { "" }
  }
  $required = if ($r.Required) { "required" } else { "optional" }
  Write-Host ("{0} {1} ({2}) {3}" -f $marker, $r.Name.PadRight(34), $required, $detail)
}

$requiredResults = $results | Where-Object { $_.Required }
$passedRequired = ($requiredResults | Where-Object { $_.Status -eq "PASS" }).Count
$totalRequired  = $requiredResults.Count
$skippedTotal   = ($results | Where-Object { $_.Status -eq "SKIP" }).Count
$failedRequired = ($requiredResults | Where-Object { $_.Status -eq "FAIL" }).Count

Write-Host "------------------------------------------------------------"
Write-Host ("Result: {0}/{1} required harnesses passed; {2} skipped." -f `
    $passedRequired, $totalRequired, $skippedTotal)
if ($failedRequired -gt 0) {
  Write-Host ("Failures: {0} required harness(es) reported FAIL -- surface in PR body." -f $failedRequired) -ForegroundColor Red
}
Write-Host "Output  : $OutputDir"
Write-Host "============================================================"

if ($failedRequired -gt 0) { exit 1 } else { exit 0 }
