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

  test('forward migration drops the old cover_facts covers default and '
      'not-null constraint for already-applied databases', () {
    final sql = File(
      'db/migrations/202605191845_data_accuracy_cover_facts_nullable_covers.sql',
    ).readAsStringSync().toLowerCase();

    expect(sql, contains('alter table public.cover_facts'));
    expect(sql, contains('alter column covers drop default'));
    expect(sql, contains('alter column covers drop not null'));
    expect(sql, contains('zero means a cover-capable vendor sent zero'));
  });
}
