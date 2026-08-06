// Unit tests for BarrioHighlightsService (Kindle-style highlights and
// notes, Slice A): the device-local store behind marked passages.
//
// What is proven here:
//   * fresh state reads as "no highlights" (no phantom entries),
//   * add / getForDoc / loadAll round-trip every field, per doc, in
//     save order, and adding the same id twice writes nothing,
//   * recolour, note, and remove edit exactly one entry,
//   * an entry this build cannot read is skipped for rendering but
//     PRESERVED on every rewrite, so an older build can never destroy a
//     newer build's highlights (the forward-compatibility promise),
//   * an unavailable preferences store reads as "no highlights" and
//     turns every write into a no-op instead of crashing,
//   * the last-used marker colour round-trips and rejects a colour this
//     build cannot paint.

import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/services/barrio_highlights_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

BarrioHighlight _highlight({
  required String id,
  String unitId = 'training_tequila_c2_u3',
  String color = 'gold',
  String note = '',
  int createdAtMillis = 1722400000000,
  List<BarrioHighlightSegment> segments = const [
    BarrioHighlightSegment(
      chunk: 3,
      start: 12,
      end: 87,
      text: 'the exact highlighted words',
    ),
  ],
}) {
  return BarrioHighlight(
    id: id,
    unitId: unitId,
    color: color,
    note: note,
    createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMillis),
    segments: segments,
  );
}

/// The stored list for [docId] exactly as it sits in preferences.
Future<List<Object?>> _rawEntries(String docId) async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(BarrioHighlightsService.keyFor(docId));
  if (raw == null) return <Object?>[];
  return List<Object?>.from(json.decode(raw) as List);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------------------------------------------------------------
  // Declared FIRST on purpose: this group needs the real (unmocked)
  // preferences platform so the channel handler below is what answers.
  // Once another group calls SharedPreferences.setMockInitialValues, the
  // in-memory store takes over the process. The precondition assertion
  // in each test fails loudly if that ever happens, rather than passing
  // for the wrong reason.
  // ---------------------------------------------------------------------
  group('BarrioHighlightsService: the preferences store is unavailable', () {
    const channel = MethodChannel('plugins.flutter.io/shared_preferences');

    setUp(() {
      SharedPreferences.resetStatic();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'unavailable',
          message: 'no preferences store on this device',
        );
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      SharedPreferences.resetStatic();
    });

    Future<void> expectStoreReallyFails() async {
      await expectLater(
        SharedPreferences.getInstance(),
        throwsA(anything),
        reason: 'precondition: this group must run against the failing '
            'store, so it has to stay first in the file',
      );
    }

    test('reads degrade to "no highlights" instead of throwing', () async {
      await expectStoreReallyFails();

      expect(await BarrioHighlightsService.getForDoc('training_tequila'),
          isEmpty);
      expect(await BarrioHighlightsService.loadAll(['training_tequila']),
          isEmpty);
      expect(await BarrioHighlightsService.getLastColor(),
          kBarrioHighlightDefaultColor);
    });

    test('every write is a silent no-op', () async {
      await expectStoreReallyFails();

      await BarrioHighlightsService.add('doc_a', _highlight(id: 'h_1_0001'));
      await BarrioHighlightsService.setColor('doc_a', 'h_1_0001', 'plum');
      await BarrioHighlightsService.setNote('doc_a', 'h_1_0001', 'a note');
      await BarrioHighlightsService.remove('doc_a', 'h_1_0001');
      await BarrioHighlightsService.setLastColor('steel');

      expect(await BarrioHighlightsService.getForDoc('doc_a'), isEmpty);
      expect(await BarrioHighlightsService.getLastColor(),
          kBarrioHighlightDefaultColor);
    });
  });

  group('BarrioHighlightsService: fresh state', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a device with nothing highlighted reads as empty', () async {
      expect(await BarrioHighlightsService.getForDoc('doc_a'), isEmpty);
      expect(await BarrioHighlightsService.loadAll(['doc_a', 'doc_b']),
          isEmpty);
      expect(await BarrioHighlightsService.getLastColor(), 'gold');
    });
  });

  group('BarrioHighlightsService: add and read back', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('one highlight round-trips every field', () async {
      final saved = _highlight(
        id: 'h_1722400000000_4821',
        unitId: 'training_tequila_c2_u3',
        color: 'plum',
        note: 'ask the chef about this',
        segments: const [
          BarrioHighlightSegment(
              chunk: 3, start: 12, end: 87, text: 'the exact highlighted'),
          BarrioHighlightSegment(
              chunk: 4, start: 0, end: 5, text: 'words'),
        ],
      );
      await BarrioHighlightsService.add('training_tequila', saved);

      final read =
          await BarrioHighlightsService.getForDoc('training_tequila');
      expect(read, hasLength(1));
      final one = read.single;
      expect(one.version, BarrioHighlight.kCurrentVersion);
      expect(one.id, 'h_1722400000000_4821');
      expect(one.unitId, 'training_tequila_c2_u3');
      expect(one.color, 'plum');
      expect(one.note, 'ask the chef about this');
      expect(one.hasNote, isTrue);
      expect(one.createdAt.millisecondsSinceEpoch, 1722400000000);
      expect(one.segments, hasLength(2));
      expect(one.segments.first.chunk, 3);
      expect(one.segments.first.start, 12);
      expect(one.segments.first.end, 87);
      expect(one.segments.first.text, 'the exact highlighted');
      expect(one.plainText, 'the exact highlighted words');
    });

    test('highlights keep save order and stay in their own doc', () async {
      await BarrioHighlightsService.add('doc_a', _highlight(id: 'h_1'));
      await BarrioHighlightsService.add('doc_a', _highlight(id: 'h_2'));
      await BarrioHighlightsService.add('doc_b', _highlight(id: 'h_3'));

      expect(
        [for (final h in await BarrioHighlightsService.getForDoc('doc_a')) h.id],
        ['h_1', 'h_2'],
        reason: 'oldest first, the order they were marked in',
      );
      expect(
        [for (final h in await BarrioHighlightsService.getForDoc('doc_b')) h.id],
        ['h_3'],
      );
      expect(await BarrioHighlightsService.getForDoc('doc_c'), isEmpty);
    });

    test('adding the same id twice writes nothing', () async {
      await BarrioHighlightsService.add('doc_a', _highlight(id: 'h_1'));
      await BarrioHighlightsService.add(
          'doc_a', _highlight(id: 'h_1', color: 'steel'));

      final read = await BarrioHighlightsService.getForDoc('doc_a');
      expect(read, hasLength(1));
      expect(read.single.color, 'gold',
          reason: 'the first write stands; add is not an update');
    });

    test('loadAll answers only for docs that actually have highlights',
        () async {
      await BarrioHighlightsService.add('doc_a', _highlight(id: 'h_1'));
      await BarrioHighlightsService.add('doc_b', _highlight(id: 'h_2'));

      final all = await BarrioHighlightsService.loadAll(
          ['doc_a', 'doc_b', 'doc_untouched']);
      expect(all.keys, unorderedEquals(['doc_a', 'doc_b']),
          reason: 'no entry honestly means nothing highlighted');
      expect(all['doc_a']!.single.id, 'h_1');
    });

    test('the doc list is stored under the per-doc key as one JSON list',
        () async {
      await BarrioHighlightsService.add('doc_a', _highlight(id: 'h_1'));
      expect(BarrioHighlightsService.keyFor('doc_a'), 'barrio_highlights_doc_a');
      final entries = await _rawEntries('doc_a');
      expect(entries, hasLength(1));
      expect((entries.single! as Map)['v'], 1);
      expect((entries.single! as Map)['id'], 'h_1');
    });
  });

  group('BarrioHighlightsService: edits', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await BarrioHighlightsService.add('doc_a', _highlight(id: 'h_1'));
      await BarrioHighlightsService.add('doc_a', _highlight(id: 'h_2'));
    });

    test('setColor repaints exactly one highlight', () async {
      await BarrioHighlightsService.setColor('doc_a', 'h_2', 'fresh');

      final read = await BarrioHighlightsService.getForDoc('doc_a');
      expect(read.first.color, 'gold');
      expect(read.last.color, 'fresh');
    });

    test('setColor ignores a colour this build cannot paint', () async {
      await BarrioHighlightsService.setColor('doc_a', 'h_1', 'teal');
      await BarrioHighlightsService.setColor('doc_a', 'h_1', '');

      final read = await BarrioHighlightsService.getForDoc('doc_a');
      expect(read.first.color, 'gold',
          reason: 'teal already means "search hit" and is not a marker');
    });

    test('setColor on an unknown id changes nothing', () async {
      await BarrioHighlightsService.setColor('doc_a', 'h_missing', 'plum');
      final read = await BarrioHighlightsService.getForDoc('doc_a');
      expect([for (final h in read) h.color], ['gold', 'gold']);
    });

    test('setNote writes and clears the note', () async {
      await BarrioHighlightsService.setNote('doc_a', 'h_1', 'check the spec');
      var read = await BarrioHighlightsService.getForDoc('doc_a');
      expect(read.first.note, 'check the spec');
      expect(read.first.hasNote, isTrue);
      expect(read.last.note, isEmpty);

      await BarrioHighlightsService.setNote('doc_a', 'h_1', '');
      read = await BarrioHighlightsService.getForDoc('doc_a');
      expect(read.first.note, isEmpty);
      expect(read.first.hasNote, isFalse);
    });

    test('remove deletes one highlight and leaves the rest', () async {
      await BarrioHighlightsService.remove('doc_a', 'h_1');
      final read = await BarrioHighlightsService.getForDoc('doc_a');
      expect([for (final h in read) h.id], ['h_2']);
    });

    test('removing an unknown id changes nothing', () async {
      await BarrioHighlightsService.remove('doc_a', 'h_missing');
      expect(await BarrioHighlightsService.getForDoc('doc_a'), hasLength(2));
    });

    test('removing the last highlight clears the doc key', () async {
      await BarrioHighlightsService.remove('doc_a', 'h_1');
      await BarrioHighlightsService.remove('doc_a', 'h_2');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(BarrioHighlightsService.keyFor('doc_a')), isNull);
      expect(await BarrioHighlightsService.getForDoc('doc_a'), isEmpty);
    });
  });

  group('BarrioHighlightsService: entries this build cannot read', () {
    // One readable entry, one malformed entry, one entry that is not even
    // an object, and one written by a NEWER build (v: 2).
    final seeded = <Object?>[
      _highlight(id: 'h_ok').toJson(),
      <String, Object?>{'v': 1, 'id': 'h_broken', 'unitId': 'u', 'color': 'gold'},
      'not even an object',
      <String, Object?>{
        'v': 2,
        'id': 'h_future',
        'unitId': 'training_coffee_c1_u1',
        'color': 'sunrise',
        'note': 'written by a newer build',
        'createdAt': 1800000000000,
        'shape': <String, Object?>{'kind': 'squiggle'},
      },
    ];

    setUp(() {
      SharedPreferences.setMockInitialValues({
        BarrioHighlightsService.keyFor('doc_a'): json.encode(seeded),
      });
    });

    test('only the readable entry renders', () async {
      final read = await BarrioHighlightsService.getForDoc('doc_a');
      expect([for (final h in read) h.id], ['h_ok'],
          reason: 'malformed and newer-version entries are skipped, not '
              'guessed at');
    });

    test('an edit preserves every entry this build cannot read', () async {
      await BarrioHighlightsService.setNote('doc_a', 'h_ok', 'my note');

      final entries = await _rawEntries('doc_a');
      expect(entries, hasLength(4), reason: 'nothing was dropped');
      expect((entries[0]! as Map)['note'], 'my note');
      expect(entries[1], equals(seeded[1]), reason: 'malformed, untouched');
      expect(entries[2], equals(seeded[2]), reason: 'not an object, kept');
      expect(entries[3], equals(seeded[3]),
          reason: 'a newer build\'s highlight survives an older build');
    });

    test('adding a new highlight preserves them too', () async {
      await BarrioHighlightsService.add('doc_a', _highlight(id: 'h_new'));

      final entries = await _rawEntries('doc_a');
      expect(entries, hasLength(5));
      expect(entries[3], equals(seeded[3]));
      expect((entries[4]! as Map)['id'], 'h_new');
    });

    test('remove never deletes an entry this build cannot read', () async {
      await BarrioHighlightsService.remove('doc_a', 'h_future');
      await BarrioHighlightsService.remove('doc_a', 'h_broken');

      final entries = await _rawEntries('doc_a');
      expect(entries, hasLength(4),
          reason: 'they are never shown, so no reader asked to delete them');

      await BarrioHighlightsService.remove('doc_a', 'h_ok');
      expect(await _rawEntries('doc_a'), hasLength(3));
      expect(await BarrioHighlightsService.getForDoc('doc_a'), isEmpty);
    });

    test('a stored value that is not readable at all reads as empty',
        () async {
      SharedPreferences.setMockInitialValues({
        BarrioHighlightsService.keyFor('doc_junk'): 'not json at all',
        // A value of the wrong type: the read throws inside the store and
        // must degrade, not crash.
        BarrioHighlightsService.keyFor('doc_wrong_type'): 42,
      });

      expect(await BarrioHighlightsService.getForDoc('doc_junk'), isEmpty);
      expect(await BarrioHighlightsService.getForDoc('doc_wrong_type'),
          isEmpty);
      expect(
        await BarrioHighlightsService.loadAll(['doc_junk', 'doc_wrong_type']),
        isEmpty,
      );
    });
  });

  group('BarrioHighlightsService: last marker colour', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('round-trips the colour the reader picked last', () async {
      await BarrioHighlightsService.setLastColor('plum');
      expect(await BarrioHighlightsService.getLastColor(), 'plum');

      await BarrioHighlightsService.setLastColor('steel');
      expect(await BarrioHighlightsService.getLastColor(), 'steel');
    });

    test('a colour this build cannot paint is ignored', () async {
      await BarrioHighlightsService.setLastColor('plum');
      await BarrioHighlightsService.setLastColor('teal');
      expect(await BarrioHighlightsService.getLastColor(), 'plum');
    });

    test('an unreadable stored colour falls back to the default', () async {
      SharedPreferences.setMockInitialValues({
        BarrioHighlightsService.kLastColorKey: 'sunrise',
      });
      expect(await BarrioHighlightsService.getLastColor(), 'gold');
      expect(BarrioHighlightsService.kLastColorKey,
          'barrio_highlight_last_color');
    });
  });

  group('BarrioHighlight model (pure)', () {
    test('decode rejects malformed entries', () {
      final good = _highlight(id: 'h_1').toJson();
      expect(BarrioHighlight.decode(good), isNotNull);

      expect(BarrioHighlight.decode('a string'), isNull);
      expect(BarrioHighlight.decode(<String, Object?>{...good, 'id': ''}),
          isNull);
      expect(BarrioHighlight.decode(<String, Object?>{...good, 'unitId': 7}),
          isNull);
      expect(
          BarrioHighlight.decode(<String, Object?>{...good, 'createdAt': 0}),
          isNull);
      expect(
          BarrioHighlight.decode(
              <String, Object?>{...good, 'segments': <Object?>[]}),
          isNull);
      expect(
        BarrioHighlight.decode(<String, Object?>{
          ...good,
          'segments': <Object?>[
            <String, Object?>{'chunk': 0, 'start': 5, 'end': 5, 'text': 'x'},
          ],
        }),
        isNull,
        reason: 'an empty range marks nothing',
      );
      expect(
        BarrioHighlight.decode(<String, Object?>{
          ...good,
          'segments': <Object?>[
            (good['segments']! as List).first,
            <String, Object?>{'chunk': 1, 'start': 0},
          ],
        }),
        isNull,
        reason: 'one bad segment makes the whole entry unreadable: a '
            'partly painted highlight would claim the wrong words',
      );
    });

    test('decode reads a missing note as no note', () {
      final raw = _highlight(id: 'h_1').toJson()..remove('note');
      final decoded = BarrioHighlight.decode(raw);
      expect(decoded, isNotNull);
      expect(decoded!.note, isEmpty);
      expect(decoded.hasNote, isFalse);
    });

    test('create stamps an h_<millis>_<rand> id and the current version',
        () {
      final made = BarrioHighlight.create(
        unitId: 'training_coffee_c1_u1',
        segments: const [
          BarrioHighlightSegment(chunk: 0, start: 0, end: 4, text: 'Pull'),
        ],
        now: DateTime.fromMillisecondsSinceEpoch(1722400000000),
        random: Random(7),
      );
      expect(made.id, matches(RegExp(r'^h_1722400000000_\d{4}$')));
      expect(made.version, 1);
      expect(made.color, kBarrioHighlightDefaultColor);
      expect(made.note, isEmpty);
      expect(made.createdAt.millisecondsSinceEpoch, 1722400000000);
    });

    test('colour tokens are names, and an unknown one resolves to gold', () {
      expect(kBarrioHighlightColorTokens, ['gold', 'fresh', 'plum', 'steel']);
      expect(kBarrioHighlightDefaultColor, 'gold');
      expect(isBarrioHighlightColor('teal'), isFalse,
          reason: 'teal is the search-hit wash, never a marker');
      expect(barrioHighlightColorOrDefault('plum'), 'plum');
      expect(barrioHighlightColorOrDefault('sunrise'), 'gold');
    });
  });
}
