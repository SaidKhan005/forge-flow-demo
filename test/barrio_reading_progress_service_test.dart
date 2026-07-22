// Unit tests for the "the app remembers you" slice (2026-07-22):
// BarrioReadingProgressService (local reading memory over
// shared_preferences, exercised through SharedPreferences
// .setMockInitialValues) and BarrioReadingTime (runtime word-count
// reading estimates, 200 wpm, floor of 1 minute).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/barrio_training_doc.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_reading_progress_service.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_reading_time.dart';
import 'package:shared_preferences/shared_preferences.dart';

HandbookUnit _unit(String id, String title, String body) => HandbookUnit(
      id: id,
      type: HandbookUnitType.explainer,
      title: title,
      body: body,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BarrioReadingProgressService: fresh state', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('reads as never-touched: no position, no reads, no last doc',
        () async {
      expect(await BarrioReadingProgressService.getPosition('doc_a'), isNull);
      expect(await BarrioReadingProgressService.getReadUnitIds('doc_a'),
          isEmpty);
      expect(await BarrioReadingProgressService.getLastDocId(), isNull);

      final snapshot =
          await BarrioReadingProgressService.loadSnapshot(['doc_a', 'doc_b']);
      expect(snapshot.lastDocId, isNull);
      expect(snapshot.lastPosition, isNull);
      expect(snapshot.readUnitIds, isEmpty);
    });
  });

  group('BarrioReadingProgressService: positions', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('save then restore round-trips per doc and tracks the last doc',
        () async {
      await BarrioReadingProgressService.savePosition('doc_a', 3, 5);

      final position = await BarrioReadingProgressService.getPosition('doc_a');
      expect(position, isNotNull);
      expect(position!.chapterIndex, 3);
      expect(position.unitInChapter, 5);
      expect(await BarrioReadingProgressService.getLastDocId(), 'doc_a');

      // A second doc keeps its own position and takes over the pointer.
      await BarrioReadingProgressService.savePosition('doc_b', 0, 2);
      final positionA =
          await BarrioReadingProgressService.getPosition('doc_a');
      final positionB =
          await BarrioReadingProgressService.getPosition('doc_b');
      expect(positionA!.chapterIndex, 3);
      expect(positionB!.chapterIndex, 0);
      expect(positionB.unitInChapter, 2);
      expect(await BarrioReadingProgressService.getLastDocId(), 'doc_b');

      // Re-saving the same doc overwrites its position.
      await BarrioReadingProgressService.savePosition('doc_a', 1, 0);
      final updated = await BarrioReadingProgressService.getPosition('doc_a');
      expect(updated!.chapterIndex, 1);
      expect(updated.unitInChapter, 0);
    });

    test('malformed stored positions read as never-read, not a crash',
        () async {
      SharedPreferences.setMockInitialValues({
        BarrioReadingProgressService.positionKeyFor('doc_junk'): 'garbage',
        BarrioReadingProgressService.positionKeyFor('doc_triple'): '1:2:3',
        BarrioReadingProgressService.positionKeyFor('doc_negative'): '-1:2',
        BarrioReadingProgressService.positionKeyFor('doc_ok'): '2:4',
      });
      expect(
          await BarrioReadingProgressService.getPosition('doc_junk'), isNull);
      expect(await BarrioReadingProgressService.getPosition('doc_triple'),
          isNull);
      expect(await BarrioReadingProgressService.getPosition('doc_negative'),
          isNull);
      final ok = await BarrioReadingProgressService.getPosition('doc_ok');
      expect(ok!.chapterIndex, 2);
      expect(ok.unitInChapter, 4);
    });
  });

  group('BarrioReadingProgressService: read marks', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('markCardRead accumulates, is idempotent, and round-trips',
        () async {
      await BarrioReadingProgressService.markCardRead('doc_a', 'u1');
      await BarrioReadingProgressService.markCardRead('doc_a', 'u2');
      // Idempotent: marking an already-read card changes nothing.
      await BarrioReadingProgressService.markCardRead('doc_a', 'u1');

      final read = await BarrioReadingProgressService.getReadUnitIds('doc_a');
      expect(read, {'u1', 'u2'});

      // Docs are independent.
      expect(await BarrioReadingProgressService.getReadUnitIds('doc_b'),
          isEmpty);
    });
  });

  group('BarrioReadingProgressService: snapshot', () {
    test('aggregates the last doc, its position, and non-empty read sets',
        () async {
      SharedPreferences.setMockInitialValues({
        'barrio_reading_last_doc': 'doc_a',
        BarrioReadingProgressService.positionKeyFor('doc_a'): '1:3',
        BarrioReadingProgressService.readCardsKeyFor('doc_a'): <String>[
          'u1',
          'u2'
        ],
        BarrioReadingProgressService.readCardsKeyFor('doc_b'): <String>['x1'],
        BarrioReadingProgressService.readCardsKeyFor('doc_c'): <String>[],
      });

      final snapshot = await BarrioReadingProgressService.loadSnapshot(
          ['doc_a', 'doc_b', 'doc_c', 'doc_never']);
      expect(snapshot.lastDocId, 'doc_a');
      expect(snapshot.lastPosition!.chapterIndex, 1);
      expect(snapshot.lastPosition!.unitInChapter, 3);
      expect(snapshot.readUnitIds.keys.toSet(), {'doc_a', 'doc_b'},
          reason: 'empty or absent read lists carry NO entry: an absent '
              'entry honestly means untouched (no phantom zeroes)');
      expect(snapshot.readUnitIds['doc_a'], {'u1', 'u2'});
      expect(snapshot.readUnitIds['doc_b'], {'x1'});
    });

    test('only inspects the requested doc ids', () async {
      SharedPreferences.setMockInitialValues({
        BarrioReadingProgressService.readCardsKeyFor('doc_a'): <String>['u1'],
        BarrioReadingProgressService.readCardsKeyFor('doc_b'): <String>['x1'],
      });
      final snapshot =
          await BarrioReadingProgressService.loadSnapshot(['doc_a']);
      expect(snapshot.readUnitIds.keys.toSet(), {'doc_a'});
    });
  });

  group('BarrioReadingTime', () {
    // 400 words at 200 wpm = 2 minutes exactly. The title contributes
    // 3 words, the body the remaining 397.
    final twoMinuteChapter = HandbookChapter(
      id: 'rt_two',
      title: 'Two Minute Chapter',
      subtitle: 'fixture',
      iconCodePoint: 0xe533,
      units: [
        _unit('rt_two_u1', 'One Two Three', List.filled(397, 'word').join(' ')),
      ],
    );

    // 10 words total: far under a minute, floors to "about 1 min".
    final tinyChapter = HandbookChapter(
      id: 'rt_tiny',
      title: 'Tiny',
      subtitle: 'fixture',
      iconCodePoint: 0xe533,
      units: [
        _unit('rt_tiny_u1', 'Tiny Card', 'one two three four five six '
            'seven eight'),
      ],
    );

    test('per-chapter estimates: rounding and the 1 minute floor', () {
      final doc = BarrioTrainingDoc(
        id: 'rt_fixture_chapters',
        title: 'Reading Time Fixture',
        sourcePath: 'test://fixture',
        chapters: [twoMinuteChapter, tinyChapter],
      );
      expect(BarrioReadingTime.chapterMinutes(doc, 0), 2,
          reason: '400 words at 200 wpm is 2 minutes');
      expect(BarrioReadingTime.chapterMinutes(doc, 1), 1,
          reason: '10 words floors to about 1 min, never 0');
      expect(BarrioReadingTime.chapterMinutes(doc, 99), 1,
          reason: 'out-of-range indices degrade to the floor');
    });

    test('doc estimate uses the total word count', () {
      final doc = BarrioTrainingDoc(
        id: 'rt_fixture_doc_total',
        title: 'Reading Time Fixture',
        sourcePath: 'test://fixture',
        chapters: [twoMinuteChapter, tinyChapter],
      );
      // 410 words total: 410/200 = 2.05 rounds to 2.
      expect(BarrioReadingTime.docMinutes(doc), 2);
    });

    test('label reads as plain English', () {
      expect(BarrioReadingTime.label(1), 'about 1 min');
      expect(BarrioReadingTime.label(12), 'about 12 min');
    });
  });
}
