import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'corpus ledger seed migration only backfills an empty ledger with active chunks',
    () {
      final sql = File(
        'db/migrations/202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n').toLowerCase();

      expect(
        sql,
        contains('not exists (\n    select 1 from public.corpus_versions'),
      );
      expect(sql, contains('from public.advisor_source_chunks'));
      expect(sql, contains('active = true'));
      expect(sql, contains('superseded_at is null'));
      expect(sql, contains('insert into public.corpus_versions'));
      expect(
        sql,
        contains('seeded baseline from pre-11a.3a active corpus chunks'),
      );
      expect(sql, contains('insert into public.corpus_version_chunks'));
      expect(sql, contains('select v_seed_version_id, chunk_id'));
      expect(
        sql,
        contains('set version_id = v_seed_version_id'),
        reason:
            'the informational first-introduced pointer should be filled only '
            'for active legacy chunks that had no version_id',
      );
      expect(sql, contains('and version_id is null'));
    },
  );
}
