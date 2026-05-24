import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('plans & limits phase 0 subscription_tier CHECK migration', () {
    late String migration;
    late String executableSql;

    setUpAll(() {
      migration = File(
        'db/migrations/'
        '202605240900_plans_and_limits_phase0_subscription_tier_check.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      executableSql = migration
          .split('\n')
          .map((line) {
            final commentIdx = line.indexOf('--');
            return commentIdx == -1 ? line : line.substring(0, commentIdx);
          })
          .join('\n');
    });

    test('backfills the legacy launch placeholder to pilot', () {
      final collapsed = executableSql.replaceAll(RegExp(r'\s+'), ' ');
      expect(
        collapsed,
        contains(
          "update public.operators set subscription_tier = 'pilot' "
          "where subscription_tier = 'launch'",
        ),
      );
    });

    test('relaxes the column default away from launch to pilot', () {
      final collapsed = executableSql.replaceAll(RegExp(r'\s+'), ' ');
      expect(
        collapsed,
        contains(
          'alter table public.operators alter column subscription_tier '
          "set default 'pilot'",
        ),
      );
      // The retired placeholder must not survive as a live default.
      expect(executableSql, isNot(contains("set default 'launch'")));
    });

    test('adds a CHECK pinning the six operator-approved tier keys', () {
      expect(
        executableSql,
        contains('drop constraint if exists operators_subscription_tier_check'),
      );
      expect(
        executableSql,
        contains('add constraint operators_subscription_tier_check'),
      );
      final collapsed = executableSql.replaceAll(RegExp(r'\s+'), ' ');
      expect(collapsed, contains('check (subscription_tier in ('));
      for (final tier in <String>[
        'pilot',
        'starter',
        'premium',
        'elite',
        'pro',
        'enterprise',
      ]) {
        expect(
          collapsed,
          contains("'$tier'"),
          reason: 'CHECK must list the $tier tier key',
        );
      }
      // 'launch' is retired and must not be an allowed key.
      final checkClause = collapsed.substring(
        collapsed.indexOf('check (subscription_tier in ('),
      );
      expect(checkClause, isNot(contains("'launch'")));
    });

    test('backfill runs before the CHECK constraint is added', () {
      final updateIdx = executableSql.indexOf('update public.operators');
      final addCheckIdx = executableSql.indexOf(
        'add constraint operators_subscription_tier_check',
      );
      expect(updateIdx, greaterThanOrEqualTo(0));
      expect(addCheckIdx, greaterThan(updateIdx));
    });

    test('is wrapped in one transaction', () {
      final body = executableSql.trim();
      expect(body, startsWith('begin;'));
      expect(body, endsWith('commit;'));
    });
  });
}
