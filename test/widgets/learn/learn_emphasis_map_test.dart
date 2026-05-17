// ─── LearnEmphasisMap tests (Lane R-LRN) ───────────────────────────────────
// Pins the V2-4 no-wording-change guarantee for the Learn story-frame
// emphasis map (docs/contracts/phase_7_58_primary_driver_contract.md
// V2-4; approved mockup docs/f&f Coaching/variance_tab_v2_mockup.html
// `#learn` `.em-bad` / `.em-good` spans):
//
//   - Every span the map names is an EXACT substring of the verbatim
//     locked catalog string it is applied to (LeverCards in
//     lib/domain/constants/app_defaults.dart; CrossAxisPairs in
//     lib/domain/constants/cross_axis_pair_catalog.dart). No invented
//     copy, no changed wording.
//   - Emphasis is non-destructive: stripMarkup of every emphasised
//     field equals the plain catalog field byte-for-byte (the
//     plain-text fallback / non-UI consumer contract still holds).
//   - At least one Leak/Wins lever and the Cross-Axis pairs actually
//     gain a marked-up span (the operator-flagged "flat text" drift is
//     fixed, not silently degraded to plain).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/domain/constants/cross_axis_pair_catalog.dart';
import 'package:forge_and_flow/widgets/variance/inline_emphasis_text.dart';
import 'package:forge_and_flow/widgets/learn/learn_emphasis_map.dart';

void main() {
  group('LearnEmphasisMap - single-axis Leak / Wins levers', () {
    test(
      'every lever round-trips: stripMarkup(emphasised) == plain catalog '
      'for whatHappened / teachingNote / whatToDo',
      () {
        for (final card in LeverCards.all) {
          expect(
            LearnEmphasisMap.leverRoundTrips(
              card.id,
              card.whatHappened,
              card.teachingNote,
              card.whatToDo,
            ),
            isTrue,
            reason:
                'lever ${card.id}: an emphasis span is not an exact '
                'substring of its catalog field (would change wording).',
          );

          // Stronger explicit assertion per field: the stripped form is
          // byte-identical to the verbatim catalog string.
          expect(
            InlineEmphasisMarkup.stripMarkup(
              LearnEmphasisMap.emphasizeWhatHappened(
                  card.id, card.whatHappened),
            ),
            card.whatHappened,
          );
          expect(
            InlineEmphasisMarkup.stripMarkup(
              LearnEmphasisMap.emphasizeTeachingNote(
                  card.id, card.teachingNote),
            ),
            card.teachingNote,
          );
          expect(
            InlineEmphasisMarkup.stripMarkup(
              LearnEmphasisMap.emphasizeWhatToDo(card.id, card.whatToDo),
            ),
            card.whatToDo,
          );
        }
      },
    );

    test('all 16 levers actually gain at least one emphasis span', () {
      for (final card in LeverCards.all) {
        final emphasised =
            LearnEmphasisMap.emphasizeWhatHappened(
                  card.id, card.whatHappened,
                ) +
                LearnEmphasisMap.emphasizeTeachingNote(
                  card.id, card.teachingNote,
                ) +
                LearnEmphasisMap.emphasizeWhatToDo(
                  card.id, card.whatToDo,
                );
        expect(
          emphasised.contains('[[bad:') || emphasised.contains('[[good:'),
          isTrue,
          reason:
              'lever ${card.id} renders flat (no emphasis span) - the '
              'operator-flagged drift would persist for it.',
        );
      }
    });

    test('unknown lever id is a clean no-op (plain string unchanged)', () {
      const plain = 'Some plain catalog-shaped sentence with no markup.';
      expect(
        LearnEmphasisMap.emphasizeWhatHappened('not_a_lever', plain),
        plain,
      );
      expect(
        LearnEmphasisMap.emphasizeTeachingNote('not_a_lever', plain),
        plain,
      );
      expect(
        LearnEmphasisMap.emphasizeWhatToDo('not_a_lever', plain),
        plain,
      );
    });
  });

  group('LearnEmphasisMap - Cross-Axis pairs', () {
    test(
      'every pair round-trips: stripMarkup(emphasised) == plain catalog '
      'for whatHappened / whatToDo / teachingNote',
      () {
        for (final pair in CrossAxisPairs.all) {
          expect(
            LearnEmphasisMap.crossRoundTrips(
              pair.id,
              pair.whatHappened,
              pair.whatToDo,
              pair.teachingNote,
            ),
            isTrue,
            reason:
                'pair ${pair.id}: an emphasis span is not an exact '
                'substring of its catalog block (would change wording).',
          );

          expect(
            InlineEmphasisMarkup.stripMarkup(
              LearnEmphasisMap.emphasizeCrossWhatHappened(
                  pair.id, pair.whatHappened),
            ),
            pair.whatHappened,
          );
          expect(
            InlineEmphasisMarkup.stripMarkup(
              LearnEmphasisMap.emphasizeCrossWhatToDo(
                  pair.id, pair.whatToDo),
            ),
            pair.whatToDo,
          );
          expect(
            InlineEmphasisMarkup.stripMarkup(
              LearnEmphasisMap.emphasizeCrossTeachingNote(
                  pair.id, pair.teachingNote),
            ),
            pair.teachingNote,
          );
        }
      },
    );

    test('all 4 cross-axis pairs gain at least one emphasis span', () {
      for (final pair in CrossAxisPairs.all) {
        final emphasised =
            LearnEmphasisMap.emphasizeCrossWhatHappened(
                  pair.id, pair.whatHappened,
                ) +
                LearnEmphasisMap.emphasizeCrossWhatToDo(
                  pair.id, pair.whatToDo,
                ) +
                LearnEmphasisMap.emphasizeCrossTeachingNote(
                  pair.id, pair.teachingNote,
                );
        expect(
          emphasised.contains('[[bad:') || emphasised.contains('[[good:'),
          isTrue,
          reason: 'pair ${pair.id} renders flat (no emphasis span).',
        );
      }
    });
  });
}
