// Lane G runner — deep navigation and state scenarios (Wave 2).
// Run: flutter test integration_test/mobile_pressure/lane_g_runner.dart
//       --flavor forgeflow --dart-define=kDemoMode=true -d <device>
import 'deep_nav/scenario_deep_01_settings_round_trip.dart' as g01;
import 'deep_nav/scenario_deep_02_benchmark_manager_round_trip.dart' as g02;
import 'deep_nav/scenario_deep_03_variance_tab_persistence.dart' as g03;
import 'deep_nav/scenario_deep_04_notifications_interaction.dart' as g04;
import 'deep_nav/scenario_deep_05_mid_load_switch.dart' as g05;

void main() {
  g01.main();
  g02.main();
  g03.main();
  g04.main();
  g05.main();
}
