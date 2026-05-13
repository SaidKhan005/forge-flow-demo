import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _path =
    'db/migrations/202605131550_benchmark_overrides_hierarchy.sql';

void main() {
  group('benchmark overrides hierarchy migration', () {
    late String sql;
    late String lower;
    late String normalized;

    setUpAll(() {
      final file = File(_path);
      expect(file.existsSync(), isTrue, reason: 'migration must exist');
      sql = file.readAsStringSync();
      lower = sql.toLowerCase();
      normalized = lower.replaceAll('\r\n', '\n');
    });

    test('adds the additive benchmark_overrides table and scope checks', () {
      expect(
        lower,
        contains('create table if not exists public.benchmark_overrides'),
      );
      expect(lower, contains('scope_type text not null'));
      expect(lower, contains("scope_type in ('operator_wide', 'org_unit', 'location')"));
      expect(lower, contains("metric_key in ('target_cplh', 'target_splh', 'target_ppa')"));
      expect(lower, contains('benchmark_overrides_scope_payload_ck'));
      expect(lower, contains('override_value numeric(12, 4) not null'));
    });

    test('uses timestamptz and avoids timestamp without time zone', () {
      expect(lower, contains('effective_from timestamptz not null'));
      expect(lower, contains('effective_until timestamptz'));
      expect(lower, contains('created_at timestamptz not null default now()'));
      expect(lower, contains('updated_at timestamptz not null default now()'));
      expect(lower, isNot(contains('timestamp without time zone')));
    });

    test('keeps operator-leading indexes and current-row uniqueness', () {
      expect(lower, contains('benchmark_overrides_current_uq'));
      expect(
        normalized,
        contains('on public.benchmark_overrides (\n    operator_id'),
      );
      expect(lower, contains('where effective_until is null'));
      expect(lower, contains('benchmark_overrides_operator_scope_idx'));
      expect(lower, contains('benchmark_overrides_operator_metric_current_idx'));
    });

    test('enables RLS through wrappers and does not mutate audit_logs', () {
      expect(
        lower,
        contains('alter table public.benchmark_overrides enable row level security'),
      );
      expect(lower, contains('public.app_current_operator()'));
      expect(lower, contains('with check (operator_id = public.app_current_operator())'));
      expect(lower, contains('does not clamp every row to app_current_location()'));
      expect(lower, contains('forgeflow.baseline.override permission'));
      expect(lower, contains('grant select, insert, update on public.benchmark_overrides'));
      expect(lower, isNot(contains('update public.audit_logs')));
    });
  });
}
