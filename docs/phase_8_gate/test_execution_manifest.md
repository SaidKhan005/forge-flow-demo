# Test Execution Manifest

Run Flutter tests one file at a time. This repo's desktop SQLite test setup can hit file-locking issues when many files are executed in a single `flutter test` invocation.

## Runner

From the repo root:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_phase8_gate_tests.ps1 -GateOnly
```

Full suite:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_phase8_gate_tests.ps1
```

Continue past failures and collect a full failing-file list:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run_phase8_gate_tests.ps1 -ContinueOnFailure
```

## Phase 8 Gate Subset

These are the files most directly tied to the pre-Phase-8 alignment contract.

1. `test/app_data_status_test.dart`
2. `test/active_target_profile_notifier_test.dart`
3. `test/current_state_alignment_test.dart`
4. `test/connector_config_repository_test.dart`
5. `test/persistence_scope_alignment_test.dart`
6. `test/settings_screen_widget_test.dart`
7. `test/shift_dashboard_empty_state_widget_test.dart`
8. `test/shift_dashboard_notifier_test.dart`
9. `test/shift_service_close_shift_test.dart`
10. `test/shift_visual_widget_test.dart`
11. `test/target_state_alignment_test.dart`
12. `test/variance_history_widget_test.dart`
13. `test/variance_visual_widget_test.dart`
14. `test/wtd_variance_logic_test.dart`

## Full Repo Suite

The full repo currently has 28 `*_test.dart` files:

1. `test/active_target_profile_notifier_test.dart`
2. `test/app_data_status_test.dart`
3. `test/baseline_manager_screen_test.dart`
4. `test/baseline_manager_service_test.dart`
5. `test/baseline_override_propagation_test.dart`
6. `test/baseline_range_logic_test.dart`
7. `test/connector_config_repository_test.dart`
8. `test/current_state_alignment_test.dart`
9. `test/history_pattern_builder_test.dart`
10. `test/history_teaching_analyzer_test.dart`
11. `test/learn_layer_widget_test.dart`
12. `test/learn_teaching_analyzer_test.dart`
13. `test/lever_logic_test.dart`
14. `test/persistence_scope_alignment_test.dart`
15. `test/settings_screen_widget_test.dart`
16. `test/shift_dashboard_empty_state_widget_test.dart`
17. `test/shift_dashboard_notifier_test.dart`
18. `test/shift_dynamic_truth_test.dart`
19. `test/shift_fact_builder_test.dart`
20. `test/shift_service_close_shift_test.dart`
21. `test/shift_visual_widget_test.dart`
22. `test/target_consistency_opz_test.dart`
23. `test/target_snapshot_builder_test.dart`
24. `test/target_state_alignment_test.dart`
25. `test/variance_history_widget_test.dart`
26. `test/variance_visual_widget_test.dart`
27. `test/widget_test.dart`
28. `test/wtd_variance_logic_test.dart`

## Expected Run Rules

1. Run from the repo root: `C:\Git Local Repos\forge_flow_demo`
2. Execute one file at a time
3. Capture failures by file name
4. Do not rewrite docs with guessed counts or results
5. If Flutter is unavailable, report that explicitly instead of claiming pass/fail
