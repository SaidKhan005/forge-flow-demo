// Admin pressure suite — Lane C.
//
// AI surfaces: Plans and limits, Knowledge base, AI Metrics.
//
// Run:
//   flutter test integration_test/admin_pressure/lane_c_runner.dart `
//     -t lib/main_admin.dart `
//     --dart-define=ADMIN_SHARE_PREVIEW=true `
//     --dart-define=ADMIN_SHARE_PREVIEW_AS_SUPER_ADMIN=true `
//     --dart-define=ADMIN_ALLOW_PUBLIC_FIXTURE_AUTH=true `
//     -d chrome `
//     --timeout 180s

import 'ai_pricing/scenario_ai_pri_01_scope_picker_renders.dart' as pri_01;
import 'ai_pricing/scenario_ai_pri_02_apply_pilot_template_shows_confirmation.dart'
    as pri_02;
import 'ai_pricing/scenario_ai_pri_03_add_usage_limit_validates_required_fields.dart'
    as pri_03;
import 'ai_corpus/scenario_ai_cor_01_version_list_renders.dart' as cor_01;
import 'ai_corpus/scenario_ai_cor_02_upload_markdown_dialog_open_and_cancel.dart'
    as cor_02;
import 'ai_observability/scenario_ai_obs_01_run_metrics_check_opens_confirmation.dart'
    as obs_01;
import 'ai_observability/scenario_ai_obs_02_cancel_confirmation_dismisses.dart'
    as obs_02;

void main() {
  pri_01.main();
  pri_02.main();
  pri_03.main();
  cor_01.main();
  cor_02.main();
  obs_01.main();
  obs_02.main();
}
