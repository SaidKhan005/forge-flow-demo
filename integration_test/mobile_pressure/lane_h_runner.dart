// Lane H runner — edge cases and resilience scenarios (Wave 2).
// Run: flutter test integration_test/mobile_pressure/lane_h_runner.dart
//       --flavor forgeflow --dart-define=kDemoMode=true -d <device>
import 'edge_cases/scenario_edge_01_role_editor_long_input.dart' as h01;
import 'edge_cases/scenario_edge_02_rapid_settings_cycles.dart' as h02;
import 'edge_cases/scenario_edge_03_shift_refresh_stress.dart' as h03;
import 'edge_cases/scenario_edge_04_settings_during_navigation.dart' as h04;
import 'edge_cases/scenario_edge_05_plan_reentry.dart' as h05;

void main() {
  h01.main();
  h02.main();
  h03.main();
  h04.main();
  h05.main();
}
