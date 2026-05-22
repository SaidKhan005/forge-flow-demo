// Lane D runner — settings/demo scenarios.
import 'settings/scenario_settings_01_account_tab.dart' as s01;
import 'settings/scenario_settings_02_authority_tab.dart' as s02;
import 'settings/scenario_settings_03_data_tab.dart' as s03;
import 'settings/scenario_settings_04_integrations.dart' as s04;
import 'settings/scenario_settings_05_role_editor.dart' as s05;
import 'settings/scenario_settings_06_demo_live_switch.dart' as s06;
import 'settings/scenario_settings_07_mfa_advisor.dart' as s07;
import 'settings/scenario_settings_08_pointer_rows_no_crash.dart' as s08;
import 'regression/scenario_reg_03_settings_unmounted_crash.dart' as reg_03;

void main() {
  s01.main();
  s02.main();
  s03.main();
  s04.main();
  s05.main();
  s06.main();
  s07.main();
  s08.main();
  reg_03.main();
}
