import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cover_facts.covers is nullable while shift_records.covers remains '
      'non-null', () {
    final sql = File(
      'db/migrations/202605061650_phase_8_legacy_fact_tables_postgres_create.sql',
    ).readAsStringSync().toLowerCase();

    expect(sql, contains('create table if not exists public.shift_records'));
    expect(sql, contains('covers integer not null default 0'));

    final coverFactsStart = sql.indexOf(
      'create table if not exists public.cover_facts',
    );
    expect(coverFactsStart, isNonNegative);
    final coverFactsEnd = sql.indexOf(
      'comment on table public.cover_facts',
      coverFactsStart,
    );
    expect(coverFactsEnd, isNonNegative);
    final coverFactsDdl = sql.substring(coverFactsStart, coverFactsEnd);
    expect(coverFactsDdl, contains('covers integer,'));
    expect(coverFactsDdl, isNot(contains('covers integer not null default 0')));
  });
}
