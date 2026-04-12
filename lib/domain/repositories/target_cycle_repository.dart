import '../models/target_cycle.dart';

/// Contract for TargetCycle persistence.
///
/// Phase 7.55l.1: contract only — SQLite implementation added in 7.55l.2.
abstract class TargetCycleRepository {
  Future<TargetCycle?> getActiveCycle(String restaurantId);
  Future<TargetCycle?> getCycleById(String cycleId);
  Future<void> upsertCycle(TargetCycle cycle);
  Future<void> deactivateCycle(String cycleId);
}
