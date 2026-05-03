// Phase 8.0 (V1 lean cut 2) — Vendor timestamp sanity guard tests.
//
// Exhausts the three rules per
// `lib/services/integration/vendor_timestamp_sanity.dart`:
//   1. closed_at >= opened_at
//   2. opened_at <= now + 1 hour
//   3. opened_at >= now - 90 days (unless deliberate backfill)

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/vendor_timestamp_sanity.dart';

void main() {
  final guard = const VendorTimestampSanity();
  final now = DateTime.utc(2026, 5, 4, 12, 0, 0);

  group('VendorTimestampSanity', () {
    test('passes a sane within-window event', () {
      final result = guard.evaluate(
        payload: <String, Object?>{
          'opened_at':
              now.subtract(const Duration(hours: 2)).toIso8601String(),
          'closed_at':
              now.subtract(const Duration(hours: 1)).toIso8601String(),
        },
        now: now,
        isDeliberateBackfill: false,
      );
      expect(result.failed, isFalse);
    });

    test('rule 1: closed_at < opened_at -> closed_before_opened', () {
      final result = guard.evaluate(
        payload: <String, Object?>{
          'opened_at':
              now.subtract(const Duration(hours: 1)).toIso8601String(),
          'closed_at':
              now.subtract(const Duration(hours: 2)).toIso8601String(),
        },
        now: now,
        isDeliberateBackfill: false,
      );
      expect(result.failed, isTrue);
      expect(result.rule, SanityRule.closedBeforeOpened);
      expect(result.rule!.sqlValue, 'closed_before_opened');
    });

    test('rule 2: opened_at > now + 1h -> opened_in_future', () {
      final result = guard.evaluate(
        payload: <String, Object?>{
          'opened_at': now.add(const Duration(hours: 5)).toIso8601String(),
        },
        now: now,
        isDeliberateBackfill: false,
      );
      expect(result.failed, isTrue);
      expect(result.rule, SanityRule.openedInFuture);
      expect(result.rule!.sqlValue, 'opened_in_future');
    });

    test('rule 2: opened_at within +1h tolerance is OK', () {
      final result = guard.evaluate(
        payload: <String, Object?>{
          'opened_at': now.add(const Duration(minutes: 30)).toIso8601String(),
        },
        now: now,
        isDeliberateBackfill: false,
      );
      expect(result.failed, isFalse);
    });

    test('rule 3: opened_at < now - 90d -> opened_too_old (when not backfill)',
        () {
      final result = guard.evaluate(
        payload: <String, Object?>{
          'opened_at':
              now.subtract(const Duration(days: 100)).toIso8601String(),
        },
        now: now,
        isDeliberateBackfill: false,
      );
      expect(result.failed, isTrue);
      expect(result.rule, SanityRule.openedTooOld);
      expect(result.rule!.sqlValue, 'opened_too_old');
    });

    test('rule 3 bypass: deliberate backfill flag admits old events', () {
      final result = guard.evaluate(
        payload: <String, Object?>{
          'opened_at':
              now.subtract(const Duration(days: 100)).toIso8601String(),
        },
        now: now,
        isDeliberateBackfill: true,
      );
      expect(result.failed, isFalse,
          reason: 'rule 3 must yield to deliberate backfill flag');
    });

    test('payload without opened_at is skipped (returns OK)', () {
      final result = guard.evaluate(
        payload: const <String, Object?>{},
        now: now,
        isDeliberateBackfill: false,
      );
      expect(result.failed, isFalse);
    });

    test('payloadSummary contains the offending timestamps', () {
      final result = guard.evaluate(
        payload: <String, Object?>{
          'opened_at':
              now.subtract(const Duration(hours: 1)).toIso8601String(),
          'closed_at':
              now.subtract(const Duration(hours: 2)).toIso8601String(),
        },
        now: now,
        isDeliberateBackfill: false,
      );
      expect(result.failed, isTrue);
      expect(result.payloadSummary['opened_at'], isA<String>());
      expect(result.payloadSummary['closed_at'], isA<String>());
    });
  });
}
