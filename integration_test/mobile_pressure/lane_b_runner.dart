// Lane B runner — shift/variance scenarios.
import 'shift/scenario_shift_01_sections_render.dart' as shift_01;
import 'shift/scenario_shift_02_daypart_interactions.dart' as shift_02;
import 'shift/scenario_shift_03_empty_state_path.dart' as shift_03;
import 'variance/scenario_variance_01_three_tabs_mount.dart' as var_01;
import 'variance/scenario_variance_02_this_week_deep.dart' as var_02;
import 'variance/scenario_variance_03_history_tab.dart' as var_03;
import 'variance/scenario_variance_04_learn_tab.dart' as var_04;
import 'variance/scenario_variance_05_data_integrity.dart' as var_05;

void main() {
  shift_01.main();
  shift_02.main();
  shift_03.main();
  var_01.main();
  var_02.main();
  var_03.main();
  var_04.main();
  var_05.main();
}
