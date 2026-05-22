// Lane F runner — form input and UI response scenarios (Wave 2).
// Run: flutter test integration_test/mobile_pressure/lane_f_runner.dart
//       --flavor forgeflow --dart-define=kDemoMode=true -d <device>
import 'forms/scenario_form_01_role_editor_input.dart' as f01;
import 'forms/scenario_form_02_role_editor_permission_toggles.dart' as f02;
import 'forms/scenario_form_03_demo_live_switch.dart' as f03;
import 'forms/scenario_form_04_pointer_rows_push_routes.dart' as f04;
import 'forms/scenario_form_05_covers_setup.dart' as f05;

void main() {
  f01.main();
  f02.main();
  f03.main();
  f04.main();
  f05.main();
}
