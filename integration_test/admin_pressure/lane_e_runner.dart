// Admin pressure suite — Lane E.
//
// Your account + cross-surface regression suite.
//
// Run:
//   flutter test integration_test/admin_pressure/lane_e_runner.dart `
//     -t lib/main_admin.dart `
//     --dart-define=ADMIN_SHARE_PREVIEW=true `
//     --dart-define=ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true `
//     --dart-define=ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH=true `
//     -d chrome `
//     --timeout 180s

import 'account_my_account/scenario_account_ma_01_identity_displayed.dart'
    as ma_01;
import 'account_my_account/scenario_account_ma_02_sessions_list_present.dart'
    as ma_02;
import 'account_notifications/scenario_account_not_01_categories_render.dart'
    as not_01;
import 'account_notifications/scenario_account_not_02_toggle_persists_optimistically.dart'
    as not_02;
import 'regression/scenario_reg_01_no_renderflex_overflow_full_nav_tour.dart'
    as reg_01;
import 'regression/scenario_reg_02_account_profile_ai_plan_is_actually_disabled.dart'
    as reg_02;
import 'regression/scenario_reg_03_business_suspend_blocks_without_reason.dart'
    as reg_03;
import 'regression/scenario_reg_04_no_unhandled_exceptions_full_tour.dart'
    as reg_04;

void main() {
  ma_01.main();
  ma_02.main();
  not_01.main();
  not_02.main();
  reg_01.main();
  reg_02.main();
  reg_03.main();
  reg_04.main();
}
