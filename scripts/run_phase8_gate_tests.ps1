param(
  [string]$FlutterCommand = "flutter",
  [switch]$GateOnly,
  [switch]$ContinueOnFailure,
  [string[]]$TestFiles
)

$ErrorActionPreference = "Stop"

$gateTests = @(
  "test/app_data_status_test.dart",
  "test/active_target_profile_notifier_test.dart",
  "test/current_state_alignment_test.dart",
  "test/connector_config_repository_test.dart",
  "test/persistence_scope_alignment_test.dart",
  "test/settings_screen_widget_test.dart",
  "test/shift_dashboard_empty_state_widget_test.dart",
  "test/shift_dashboard_notifier_test.dart",
  "test/shift_service_close_shift_test.dart",
  "test/shift_visual_widget_test.dart",
  "test/target_state_alignment_test.dart",
  "test/variance_history_widget_test.dart",
  "test/variance_visual_widget_test.dart",
  "test/wtd_variance_logic_test.dart"
)

$fullSuite = @(
  "test/active_target_profile_notifier_test.dart",
  "test/app_data_status_test.dart",
  "test/baseline_manager_screen_test.dart",
  "test/baseline_manager_service_test.dart",
  "test/baseline_override_propagation_test.dart",
  "test/baseline_range_logic_test.dart",
  "test/connector_config_repository_test.dart",
  "test/current_state_alignment_test.dart",
  "test/history_pattern_builder_test.dart",
  "test/history_teaching_analyzer_test.dart",
  "test/learn_layer_widget_test.dart",
  "test/learn_teaching_analyzer_test.dart",
  "test/lever_logic_test.dart",
  "test/persistence_scope_alignment_test.dart",
  "test/settings_screen_widget_test.dart",
  "test/shift_dashboard_empty_state_widget_test.dart",
  "test/shift_dashboard_notifier_test.dart",
  "test/shift_dynamic_truth_test.dart",
  "test/shift_fact_builder_test.dart",
  "test/shift_service_close_shift_test.dart",
  "test/shift_visual_widget_test.dart",
  "test/target_consistency_opz_test.dart",
  "test/target_snapshot_builder_test.dart",
  "test/target_state_alignment_test.dart",
  "test/variance_history_widget_test.dart",
  "test/variance_visual_widget_test.dart",
  "test/widget_test.dart",
  "test/wtd_variance_logic_test.dart"
)

$tests = if ($TestFiles -and $TestFiles.Count -gt 0) {
  $TestFiles
} elseif ($GateOnly) {
  $gateTests
} else {
  $fullSuite
}

$failures = New-Object System.Collections.Generic.List[string]

Write-Host ""
Write-Host "Forge & Flow test runner"
if ($TestFiles -and $TestFiles.Count -gt 0) {
  Write-Host "Mode: Explicit file list"
} elseif ($GateOnly) {
  Write-Host "Mode: Phase 8 gate subset"
} else {
  Write-Host "Mode: Full repo suite"
}
Write-Host "Flutter command: $FlutterCommand"
Write-Host "Test file count: $($tests.Count)"
Write-Host ""

if (-not (Get-Command $FlutterCommand -ErrorAction SilentlyContinue)) {
  Write-Error "Flutter command '$FlutterCommand' was not found on PATH."
}

foreach ($testFile in $tests) {
  Write-Host "============================================================"
  Write-Host "Running $testFile"
  Write-Host "============================================================"

  & $FlutterCommand test $testFile
  $exitCode = $LASTEXITCODE

  if ($exitCode -ne 0) {
    $failures.Add($testFile)
    Write-Host ""
    Write-Host "FAILED: $testFile (exit code $exitCode)" -ForegroundColor Red

    if (-not $ContinueOnFailure) {
      Write-Host ""
      Write-Host "Stopping on first failure." -ForegroundColor Yellow
      exit $exitCode
    }
  } else {
    Write-Host ""
    Write-Host "PASSED: $testFile" -ForegroundColor Green
  }

  Write-Host ""
}

if ($failures.Count -gt 0) {
  Write-Host "Failing files:" -ForegroundColor Red
  foreach ($failure in $failures) {
    Write-Host " - $failure" -ForegroundColor Red
  }
  exit 1
}

Write-Host "All selected test files passed." -ForegroundColor Green
