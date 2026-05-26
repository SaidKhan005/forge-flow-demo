// Admin pressure suite — Lane B.
//
// Operations surfaces: Business accounts, Data accuracy, Vendor
// applicability, Polling Setup, Members, Access, Security & audit,
// Vendor integrations, Timing.
//
// Run:
//   flutter test integration_test/admin_pressure/lane_b_runner.dart `
//     -t lib/main_admin.dart `
//     --dart-define=ADMIN_SHARE_PREVIEW=true `
//     --dart-define=ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true `
//     --dart-define=ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH=true `
//     -d chrome `
//     --timeout 180s

import 'ops_business_accounts/scenario_ops_ba_01_two_demo_operators_present.dart'
    as ba_01;
import 'ops_business_accounts/scenario_ops_ba_02_drill_into_demo_diner.dart'
    as ba_02;
import 'ops_business_accounts/scenario_ops_ba_03_account_profile_dialog_open_and_cancel.dart'
    as ba_03;
import 'ops_business_accounts/scenario_ops_ba_04_suspend_business_requires_confirmation.dart'
    as ba_04;
import 'ops_business_accounts/scenario_ops_ba_05_org_unit_tree_renders_with_actions.dart'
    as ba_05;
import 'ops_business_accounts/scenario_ops_ba_06_setup_tile_navigation.dart'
    as ba_06;
import 'ops_data_accuracy/scenario_ops_da_01_table_renders_per_location.dart'
    as da_01;
import 'ops_data_accuracy/scenario_ops_da_02_audit_history_toggle.dart'
    as da_02;
import 'ops_data_accuracy/scenario_ops_da_03_vendor_data_filter_opens.dart'
    as da_03;
import 'ops_vendor_applicability/scenario_ops_va_01_table_renders.dart'
    as va_01;
import 'ops_vendor_applicability/scenario_ops_va_02_edit_metadata_dialog_requires_reason.dart'
    as va_02;
import 'ops_polling/scenario_ops_pol_01_tier_definitions_render.dart'
    as pol_01;
import 'ops_polling/scenario_ops_pol_02_assign_scope_dialog_open_cancel.dart'
    as pol_02;
import 'ops_polling/scenario_ops_pol_03_tier_change_request_visible_at_business_scope.dart'
    as pol_03;
import 'ops_members/scenario_ops_mem_01_members_table_renders.dart' as mem_01;
import 'ops_members/scenario_ops_mem_02_invite_dialog_opens_and_validates.dart'
    as mem_02;
import 'ops_members/scenario_ops_mem_03_suspend_requires_admin_reason.dart'
    as mem_03;
import 'ops_access/scenario_ops_acc_01_three_tabs_present.dart' as acc_01;
import 'ops_security_audit/scenario_ops_sa_01_audit_log_renders.dart'
    as sa_01;
import 'ops_security_audit/scenario_ops_sa_02_reset_mfa_disabled_when_not_mfa_fresh.dart'
    as sa_02;
import 'ops_vendor_integrations/scenario_ops_vi_01_connection_list_renders.dart'
    as vi_01;
import 'ops_timing/scenario_ops_tim_01_resolution_renders.dart' as tim_01;

void main() {
  ba_01.main();
  ba_02.main();
  ba_03.main();
  ba_04.main();
  ba_05.main();
  ba_06.main();
  da_01.main();
  da_02.main();
  da_03.main();
  va_01.main();
  va_02.main();
  pol_01.main();
  pol_02.main();
  pol_03.main();
  mem_01.main();
  mem_02.main();
  mem_03.main();
  acc_01.main();
  sa_01.main();
  sa_02.main();
  vi_01.main();
  tim_01.main();
}
