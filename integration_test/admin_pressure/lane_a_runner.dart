// Admin pressure suite — Lane A.
//
// Shell / Auth / Navigation regressions.
//
// Run:
//   flutter test integration_test/admin_pressure/lane_a_runner.dart `
//     -t lib/main_admin.dart `
//     --dart-define=ADMIN_SHARE_PREVIEW=true `
//     --dart-define=ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true `
//     --dart-define=ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH=true `
//     -d chrome `
//     --timeout 180s
//
// See `integration_test/admin_pressure/README.md` for the suite-wide
// run rules and lane-to-scenario mapping.

import 'auth/scenario_auth_01_share_preview_boot.dart' as auth_01;
import 'auth/scenario_auth_02_role_pill_and_identity.dart' as auth_02;
import 'shell/scenario_shell_01_all_nav_routes_mount.dart' as shell_01;
import 'shell/scenario_shell_02_compact_layout_switch.dart' as shell_02;
import 'shell/scenario_shell_03_header_overflow_guard.dart' as shell_03;
import 'shell/scenario_shell_04_signout_button_present.dart' as shell_04;

void main() {
  auth_01.main();
  auth_02.main();
  shell_01.main();
  shell_02.main();
  shell_03.main();
  shell_04.main();
}
