// Phase 7.51b â€” Active target profile notifier tests.
//
// Validates:
// A. Notifier loads persisted active profile
// B. Notifier revision advances after manager override persistence

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/active_target_profile_notifier.dart';
import 'package:forge_and_flow/data/baseline_manager_service.dart';
import 'package:forge_and_flow/data/legacy_fixture_data.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  setUp(() async {
    BaselineData.clearManagerOverride();
    await SqliteDatabase.instance.reseedDemo();
  });

  // â”€â”€ A: Notifier loads persisted active profile â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('A â€” initial load', () {
    test('notifier exposes non-null profile for demo_restaurant_001',
        () async {
      final notifier = ActiveTargetProfileNotifier();
      // Wait for async load
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.profile, isNotNull);
      expect(notifier.profile!.restaurantId, 'demo_restaurant_001');
      expect(notifier.profile!.targetCPLH, greaterThan(0));
      expect(notifier.isLoading, isFalse);

      notifier.dispose();
    });

    test('initial revision is 0', () async {
      final notifier = ActiveTargetProfileNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.revision, 0);

      notifier.dispose();
    });
  });

  // â”€â”€ B: Revision advances after manager override persistence â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  group('B â€” revision after override', () {
    test('revision increments after saveSelection persists new profile',
        () async {
      final notifier = ActiveTargetProfileNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final initialRevision = notifier.revision;

      // Apply manager override through existing service path
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      expect(candidates, isNotEmpty);
      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey});

      // The callback should have fired refresh()
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.revision, greaterThan(initialRevision));
      expect(notifier.profile!.sourceType, 'manager_override');

      notifier.dispose();
    });

    test('clearing override advances revision and restores system_baseline',
        () async {
      final notifier = ActiveTargetProfileNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // First apply override
      final candidates =
          await BaselineManagerService.instance.getCandidateShifts();
      await BaselineManagerService.instance
          .saveSelection({candidates[0].recordKey});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final revAfterOverride = notifier.revision;

      // Now clear it
      await BaselineManagerService.instance.saveSelection({});
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(notifier.revision, greaterThan(revAfterOverride));
      expect(notifier.profile!.sourceType, 'system_baseline');

      notifier.dispose();
    });
  });
}
