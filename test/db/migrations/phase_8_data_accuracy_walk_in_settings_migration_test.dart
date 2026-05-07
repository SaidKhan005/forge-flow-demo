import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migration =
    'db/migrations/202605080300_phase_8_data_accuracy_walk_in_settings.sql';

void main() {
  group('phase 8 data accuracy walk-in settings migration', () {
    late String sql;

    setUpAll(() {
      final file = File(_migration);
      expect(file.existsSync(), isTrue);
      sql = file.readAsStringSync().replaceAll('\r\n', '\n').toLowerCase();
    });

    test('adds durable walk-in mode and sparse entry columns additively', () {
      expect(sql, contains('add column if not exists walk_in_handling_mode'));
      expect(sql, contains("not null default 'reservations_only'"));
      expect(sql, contains('add column if not exists walk_in_manual_entries'));
      expect(sql, contains("not null default '{}'::jsonb"));
    });

    test('pins walk-in mode values and JSON object shape', () {
      expect(sql, contains('data_accuracy_settings_walk_in_mode_check'));
      expect(sql, contains("'reservations_only'"));
      expect(sql, contains("'walk_ins_added_to_reservations'"));
      expect(sql, contains("'walk_ins_tracked_separately'"));
      expect(
        sql,
        contains('jsonb_typeof(walk_in_manual_entries) = \'object\''),
      );
    });

    test('stays scoped to data_accuracy_settings and one transaction', () {
      expect(sql, contains('begin;'));
      expect(sql, contains('commit;'));
      expect(sql, contains('alter table public.data_accuracy_settings'));
      expect(sql, isNot(contains('open_shift_snapshots_cache')));
    });
  });
}
