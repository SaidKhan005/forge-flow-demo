// Lane A runner — boot/auth/shell/nav/regression scenarios.
// Run: flutter test integration_test/mobile_pressure/lane_a_runner.dart
//       --flavor forgeflow --dart-define=kDemoMode=true -d <device>
import 'auth/scenario_auth_01_demo_login.dart' as auth_01;
import 'auth/scenario_auth_02_login_form_present.dart' as auth_02;
import 'shell/scenario_shell_01_all_tabs_mount.dart' as shell_01;
import 'shell/scenario_shell_02_settings_navigation.dart' as shell_02;
import 'shell/scenario_shell_03_notifications_navigation.dart' as shell_03;
import 'shell/scenario_shell_04_rapid_nav_stress.dart' as shell_04;
import 'regression/scenario_reg_01_crashreporter_no_freeze.dart' as reg_01;
import 'regression/scenario_reg_02_demo_banner_lifecycle.dart' as reg_02;

void main() {
  auth_01.main();
  auth_02.main();
  shell_01.main();
  shell_02.main();
  shell_03.main();
  shell_04.main();
  reg_01.main();
  reg_02.main();
}
