// Lane C runner — plan/benchmark scenarios.
import 'plan/scenario_plan_01_schedule_builder_mounts.dart' as plan_01;
import 'plan/scenario_plan_02_interactions.dart' as plan_02;
import 'benchmark/scenario_bench_01_baseline_tracker_mounts.dart' as bench_01;
import 'benchmark/scenario_bench_02_drill_to_manager.dart' as bench_02;
import 'benchmark/scenario_bench_03_manager_sub_screens.dart' as bench_03;
import 'benchmark/scenario_bench_04_manager_interactions.dart' as bench_04;
import 'benchmark/scenario_bench_05_back_navigation.dart' as bench_05;

void main() {
  plan_01.main();
  plan_02.main();
  bench_01.main();
  bench_02.main();
  bench_03.main();
  bench_04.main();
  bench_05.main();
}
