// Lane E runner — data correctness scenarios (Wave 2).
// Run: flutter test integration_test/mobile_pressure/lane_e_runner.dart
//       --flavor forgeflow --dart-define=kDemoMode=true -d <device>
import 'data_correctness/scenario_data_01_shift_metric_values.dart' as e01;
import 'data_correctness/scenario_data_02_variance_date_values.dart' as e02;
import 'data_correctness/scenario_data_03_plan_scheduled_hours.dart' as e03;
import 'data_correctness/scenario_data_04_benchmark_baseline.dart' as e04;
import 'data_correctness/scenario_data_05_active_sessions_count.dart' as e05;

void main() {
  e01.main();
  e02.main();
  e03.main();
  e04.main();
  e05.main();
}
