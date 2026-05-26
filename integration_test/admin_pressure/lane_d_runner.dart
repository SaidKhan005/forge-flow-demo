// Admin pressure suite — Lane D.
//
// System monitoring + Service setup: System health, Support logs,
// Connected services, Launch controls, Default roles.
//
// Run:
//   flutter test integration_test/admin_pressure/lane_d_runner.dart `
//     -t lib/main_admin.dart `
//     --dart-define=ADMIN_SHARE_PREVIEW=true `
//     --dart-define=ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true `
//     --dart-define=ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH=true `
//     -d chrome `
//     --timeout 180s

import 'sysmon_health/scenario_sysmon_health_01_categories_render.dart'
    as health_01;
import 'sysmon_health/scenario_sysmon_health_02_run_check_button_present.dart'
    as health_02;
import 'sysmon_debug/scenario_sysmon_debug_01_log_list_renders.dart'
    as debug_01;
import 'sysmon_debug/scenario_sysmon_debug_02_scope_filter_changes_results.dart'
    as debug_02;
import 'setup_integrations/scenario_setup_int_01_provider_tiles_render.dart'
    as int_01;
import 'setup_feature_flags/scenario_setup_ff_01_flag_list_renders.dart'
    as ff_01;
import 'setup_feature_flags/scenario_setup_ff_02_destructive_flag_requires_type_to_confirm.dart'
    as ff_02;
import 'setup_default_roles/scenario_setup_dr_01_versions_list_renders.dart'
    as dr_01;
import 'setup_default_roles/scenario_setup_dr_02_publish_dialog_open_and_cancel.dart'
    as dr_02;

void main() {
  health_01.main();
  health_02.main();
  debug_01.main();
  debug_02.main();
  int_01.main();
  ff_01.main();
  ff_02.main();
  dr_01.main();
  dr_02.main();
}
