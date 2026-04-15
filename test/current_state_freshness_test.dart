// Phase 7.55n.7 -- Current-state freshness tests.
//
// Validates:
// A. threshold boundaries (live / updated / stale with injectable now)
// B. age label formatting (Fmt.timeAgo)
// C. refreshing factory preserves prior context
// D. custom threshold overrides
// E. model age getter derivation
//
// All pure -- no SQLite, no Flutter widgets.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/models/current_state_freshness.dart';
import 'package:forge_and_flow/services/current_state_freshness_service.dart';
import 'package:forge_and_flow/utils/formatters.dart';

void main() {
  const service = CurrentStateFreshnessService();
  final now = DateTime.utc(2026, 4, 13, 12, 0, 0);

  // -- A: threshold boundaries ------------------------------------------------

  group('A -- threshold boundaries', () {
    test('updatedAt = now yields live', () {
      final f = service.evaluate(updatedAt: now, now: now);
      expect(f.state, FreshnessState.live);
      expect(f.updatedAt, now);
      expect(f.evaluatedAt, now);
    });

    test('updatedAt = now - 4m59s yields live', () {
      final updated = now.subtract(const Duration(minutes: 4, seconds: 59));
      final f = service.evaluate(updatedAt: updated, now: now);
      expect(f.state, FreshnessState.live);
    });

    test('updatedAt = now - 5m yields updated', () {
      final updated = now.subtract(const Duration(minutes: 5));
      final f = service.evaluate(updatedAt: updated, now: now);
      expect(f.state, FreshnessState.updated);
      expect(f.updatedAt, updated);
    });

    test('updatedAt = now - 30m yields updated', () {
      final updated = now.subtract(const Duration(minutes: 30));
      final f = service.evaluate(updatedAt: updated, now: now);
      expect(f.state, FreshnessState.updated);
    });

    test('updatedAt = now - 119m yields updated', () {
      final updated = now.subtract(const Duration(minutes: 119));
      final f = service.evaluate(updatedAt: updated, now: now);
      expect(f.state, FreshnessState.updated);
    });

    test('updatedAt = now - 120m yields stale', () {
      final updated = now.subtract(const Duration(minutes: 120));
      final f = service.evaluate(updatedAt: updated, now: now);
      expect(f.state, FreshnessState.stale);
      expect(f.updatedAt, updated);
    });

    test('updatedAt = now - 24h yields stale', () {
      final updated = now.subtract(const Duration(hours: 24));
      final f = service.evaluate(updatedAt: updated, now: now);
      expect(f.state, FreshnessState.stale);
    });

    test('null updatedAt yields stale with null age', () {
      final f = service.evaluate(updatedAt: null, now: now);
      expect(f.state, FreshnessState.stale);
      expect(f.updatedAt, isNull);
      expect(f.age, isNull);
    });
  });

  // -- B: age label formatting ------------------------------------------------

  group('B -- Fmt.timeAgo formatting', () {
    test('0 seconds yields just now', () {
      expect(Fmt.timeAgo(Duration.zero), 'just now');
    });

    test('30 seconds yields just now', () {
      expect(Fmt.timeAgo(const Duration(seconds: 30)), 'just now');
    });

    test('1 minute yields 1 min ago', () {
      expect(Fmt.timeAgo(const Duration(minutes: 1)), '1 min ago');
    });

    test('3 minutes yields 3 min ago', () {
      expect(Fmt.timeAgo(const Duration(minutes: 3)), '3 min ago');
    });

    test('14 minutes yields 14 min ago', () {
      expect(Fmt.timeAgo(const Duration(minutes: 14)), '14 min ago');
    });

    test('59 minutes yields 59 min ago', () {
      expect(Fmt.timeAgo(const Duration(minutes: 59)), '59 min ago');
    });

    test('60 minutes yields 1 hr ago', () {
      expect(Fmt.timeAgo(const Duration(minutes: 60)), '1 hr ago');
    });

    test('90 minutes yields 1 hr ago', () {
      expect(Fmt.timeAgo(const Duration(minutes: 90)), '1 hr ago');
    });

    test('150 minutes yields 2 hr ago', () {
      expect(Fmt.timeAgo(const Duration(minutes: 150)), '2 hr ago');
    });
  });

  // -- C: refreshing factory --------------------------------------------------

  group('C -- refreshing factory', () {
    test('preserves prior updatedAt', () {
      final prior = now.subtract(const Duration(minutes: 10));
      final f = CurrentStateFreshness.refreshing(
        priorUpdatedAt: prior,
        evaluatedAt: now,
      );
      expect(f.state, FreshnessState.refreshing);
      expect(f.updatedAt, prior);
      expect(f.evaluatedAt, now);
      expect(f.age, const Duration(minutes: 10));
    });

    test('null prior yields null age', () {
      final f = CurrentStateFreshness.refreshing(
        priorUpdatedAt: null,
        evaluatedAt: now,
      );
      expect(f.state, FreshnessState.refreshing);
      expect(f.updatedAt, isNull);
      expect(f.age, isNull);
    });
  });

  // -- D: custom thresholds ---------------------------------------------------

  group('D -- custom thresholds', () {
    test('wider live window (10m) keeps data live longer', () {
      final updated = now.subtract(const Duration(minutes: 7));
      final f = service.evaluate(
        updatedAt: updated,
        now: now,
        liveWindowMinutes: 10,
      );
      expect(f.state, FreshnessState.live);
    });

    test('tighter stale threshold (60m) makes data stale sooner', () {
      final updated = now.subtract(const Duration(minutes: 60));
      final f = service.evaluate(
        updatedAt: updated,
        now: now,
        staleThresholdMinutes: 60,
      );
      expect(f.state, FreshnessState.stale);
    });

    test('tighter stale threshold (60m) keeps 59m as updated', () {
      final updated = now.subtract(const Duration(minutes: 59));
      final f = service.evaluate(
        updatedAt: updated,
        now: now,
        staleThresholdMinutes: 60,
      );
      expect(f.state, FreshnessState.updated);
    });
  });

  // -- E: model age getter ----------------------------------------------------

  group('E -- model age getter', () {
    test('age = evaluatedAt - updatedAt', () {
      final updated = now.subtract(const Duration(minutes: 7));
      final f = CurrentStateFreshness(
        state: FreshnessState.updated,
        updatedAt: updated,
        evaluatedAt: now,
      );
      expect(f.age, const Duration(minutes: 7));
    });

    test('age is null when updatedAt is null', () {
      final f = CurrentStateFreshness(
        state: FreshnessState.stale,
        evaluatedAt: now,
      );
      expect(f.age, isNull);
    });

    test('live freshness has zero-ish age', () {
      final f = CurrentStateFreshness(
        state: FreshnessState.live,
        updatedAt: now,
        evaluatedAt: now,
      );
      expect(f.age!.inSeconds, 0);
    });
  });
}
