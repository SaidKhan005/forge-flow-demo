// ─── InlineEmphasisText / InlineEmphasisMarkup tests (Lane E) ───────────────
// Pins the V2-4 inline-emphasis markup convention from
// docs/contracts/phase_7_58_primary_driver_contract.md:
//   - markup parses to the expected typed segments (causal spans + chips);
//   - the plain-text fallback yields the verbatim catalog sentence with
//     markup fully removed and ZERO token leakage;
//   - a string with no markup renders identically to a plain Text;
//   - words are preserved byte-for-byte (parser concatenation == strip);
//   - the renderer never introduces an em (U+2014) or en (U+2013) dash.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/theme/app_theme.dart';
import 'package:forge_and_flow/widgets/variance/inline_emphasis_text.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: child),
    );

// Verbatim catalog sentence (from covers_up.whatHappened, V2-1) used as the
// no-leakage proof string. NOT marked up.
const _verbatimCoversUp =
    'More guests showed up than you forecast, and the team carried '
    'them on the hours already scheduled. Both sides looked better '
    'because the extra covers grew the sales side. The rule before '
    'you celebrate a good number: check CPLH. If it held in the zone '
    'this was design. If it ran soft, the volume did work the '
    'schedule should have done.';

// The same sentence with the V2-4 emphasis map applied by a (future) wiring
// slice: causal phrases wrapped, no words changed.
const _markedCoversUp =
    'More guests showed up than you forecast, and the team carried '
    'them on the hours already scheduled. Both sides looked better '
    'because the extra covers grew the sales side. The rule before '
    'you celebrate a good number: [[bad:check CPLH]]. If it held in '
    'the zone this was design. If it ran soft, the volume did work '
    'the schedule should have done.';

void main() {
  group('InlineEmphasisMarkup.parse: token recognition', () {
    test('plain string → single plain segment equal to input', () {
      final segs = InlineEmphasisMarkup.parse(_verbatimCoversUp);
      expect(segs, hasLength(1));
      expect(segs.single.kind, InlineEmphasisKind.plain);
      expect(segs.single.text, _verbatimCoversUp);
    });

    test('empty string → single empty plain segment (no null branch)', () {
      final segs = InlineEmphasisMarkup.parse('');
      expect(segs, hasLength(1));
      expect(segs.single.kind, InlineEmphasisKind.plain);
      expect(segs.single.text, '');
    });

    test('all four tokens parse to their typed segments', () {
      final segs = InlineEmphasisMarkup.parse(
        'a [[bad:loss phrase]] b [[good:win phrase]] c '
        '[[chip:−\$462]] d [[chipg:+\$686]] e',
      );
      expect(
        segs.map((s) => s.kind).toList(),
        const [
          InlineEmphasisKind.plain, // 'a '
          InlineEmphasisKind.causalBad, // 'loss phrase'
          InlineEmphasisKind.plain, // ' b '
          InlineEmphasisKind.causalGood, // 'win phrase'
          InlineEmphasisKind.plain, // ' c '
          InlineEmphasisKind.chipBad, // '−$462'
          InlineEmphasisKind.plain, // ' d '
          InlineEmphasisKind.chipGood, // '+$686'
          InlineEmphasisKind.plain, // ' e'
        ],
      );
      expect(segs[1].text, 'loss phrase');
      expect(segs[3].text, 'win phrase');
      expect(segs[5].text, '−\$462');
      expect(segs[7].text, '+\$686');
    });

    test('chipg is not mis-read as chip + stray g (longest-prefix)', () {
      final segs = InlineEmphasisMarkup.parse('[[chipg:+\$686]]');
      expect(segs, hasLength(1));
      expect(segs.single.kind, InlineEmphasisKind.chipGood);
      expect(segs.single.text, '+\$686');
    });

    test('adjacent tokens with no plain text between them', () {
      final segs = InlineEmphasisMarkup.parse('[[bad:x]][[good:y]]');
      expect(segs, hasLength(2));
      expect(segs[0].kind, InlineEmphasisKind.causalBad);
      expect(segs[0].text, 'x');
      expect(segs[1].kind, InlineEmphasisKind.causalGood);
      expect(segs[1].text, 'y');
    });

    test('marked covers_up parses with one causal-bad span', () {
      final segs = InlineEmphasisMarkup.parse(_markedCoversUp);
      final bad = segs
          .where((s) => s.kind == InlineEmphasisKind.causalBad)
          .toList();
      expect(bad, hasLength(1));
      expect(bad.single.text, 'check CPLH');
    });
  });

  group('InlineEmphasisMarkup.parse: malformed / unknown sequences', () {
    test('unterminated token is emitted verbatim, no word lost', () {
      const s = 'before [[bad:never closed and the rest of the sentence';
      final segs = InlineEmphasisMarkup.parse(s);
      // All segments are plain and concatenate to the exact input.
      expect(segs.every((x) => x.isPlain), isTrue);
      expect(segs.map((x) => x.text).join(), s);
    });

    test('unknown prefix is passed through untouched', () {
      const s = 'x [[warn:not a real token]] y';
      expect(InlineEmphasisMarkup.stripMarkup(s), s);
    });

    test('bare double-bracket without close is literal', () {
      const s = 'array[[0]] index';
      // "[[0]]" is not a known prefix; ensure no characters vanish.
      expect(InlineEmphasisMarkup.stripMarkup(s), s);
    });
  });

  group('InlineEmphasisMarkup.stripMarkup: plain-text fallback', () {
    test('marked sentence strips to the EXACT verbatim catalog sentence', () {
      expect(
        InlineEmphasisMarkup.stripMarkup(_markedCoversUp),
        _verbatimCoversUp,
      );
    });

    test('no markup token leaks into the stripped output', () {
      final out = InlineEmphasisMarkup.stripMarkup(
        'a [[bad:b]] c [[good:d]] e [[chip:−\$1]] f [[chipg:+\$2]] g',
      );
      for (final tok in const [
        '[[bad:',
        '[[good:',
        '[[chip:',
        '[[chipg:',
        ']]',
      ]) {
        expect(out.contains(tok), isFalse, reason: 'leaked token: $tok');
      }
      expect(out, 'a b c d e −\$1 f +\$2 g');
    });

    test('plain string strips to itself unchanged', () {
      expect(
        InlineEmphasisMarkup.stripMarkup(_verbatimCoversUp),
        _verbatimCoversUp,
      );
    });

    test('parse concatenation == stripMarkup (byte-for-byte word safety)', () {
      final joined = InlineEmphasisMarkup.parse(_markedCoversUp)
          .map((s) => s.text)
          .join();
      expect(joined, InlineEmphasisMarkup.stripMarkup(_markedCoversUp));
      expect(joined, _verbatimCoversUp);
    });

    test('fallback introduces no em-dash or en-dash', () {
      final out = InlineEmphasisMarkup.stripMarkup(_markedCoversUp);
      expect(out.contains('—'), isFalse); // em dash
      expect(out.contains('–'), isFalse); // en dash
    });
  });

  group('InlineEmphasisText widget render', () {
    testWidgets('plain string renders the full verbatim text', (tester) async {
      await tester.pumpWidget(_wrap(
        const InlineEmphasisText(_verbatimCoversUp),
      ));
      final richText = tester.widget<RichText>(find.byType(RichText));
      expect(
        richText.text.toPlainText(),
        _verbatimCoversUp,
      );
    });

    testWidgets('marked string renders preserving all words', (tester) async {
      await tester.pumpWidget(_wrap(
        const InlineEmphasisText(_markedCoversUp),
      ));
      // The rendered plain text (causal spans contribute their text; chips are
      // WidgetSpans so excluded here) still contains the causal phrase words.
      final richText = tester.widget<RichText>(find.byType(RichText));
      final rendered = richText.text.toPlainText();
      expect(rendered, _verbatimCoversUp);
    });

    testWidgets('causal-bad span uses the loss/red sentiment colour',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const InlineEmphasisText('keep [[bad:check CPLH]] going'),
      ));
      final richText = tester.widget<RichText>(find.byType(RichText));
      final root = richText.text as TextSpan;
      TextStyle? badStyle;
      root.visitChildren((span) {
        if (span is TextSpan && span.text == 'check CPLH') {
          badStyle = span.style;
        }
        return true;
      });
      expect(badStyle, isNotNull);
      expect(badStyle!.color, AppColors.negative);
      expect(badStyle!.fontWeight, FontWeight.w700);
    });

    testWidgets('causal-good span uses the profit/green sentiment colour',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const InlineEmphasisText('build [[good:covers divided by CPLH]] next'),
      ));
      final richText = tester.widget<RichText>(find.byType(RichText));
      final root = richText.text as TextSpan;
      TextStyle? goodStyle;
      root.visitChildren((span) {
        if (span is TextSpan && span.text == 'covers divided by CPLH') {
          goodStyle = span.style;
        }
        return true;
      });
      expect(goodStyle, isNotNull);
      expect(goodStyle!.color, AppColors.positive);
      expect(goodStyle!.fontWeight, FontWeight.w700);
    });

    testWidgets('chip tokens render as monospace pills (WidgetSpan)',
        (tester) async {
      await tester.pumpWidget(_wrap(
        const InlineEmphasisText(
          'net [[chip:−\$462]] vs [[chipg:+\$686]] today',
        ),
      ));
      // Two chip containers exist; their inner Text shows the money value.
      expect(find.text('−\$462'), findsOneWidget);
      expect(find.text('+\$686'), findsOneWidget);
    });
  });
}
