// === InlineEmphasisText : Variance Coaching V2 (Lane E) =====================
// Implements the V2-4 inline-emphasis markup convention from
// docs/contracts/phase_7_58_primary_driver_contract.md.
//
// Catalog strings (Lane B) are persisted as byte-for-byte plain prose with NO
// markup. A small per-lever emphasis map (Lane F / a later wiring slice) wraps
// existing spans in the safe markup tokens this renderer recognises, never
// mutating the catalog. This file owns:
//
//   1. the parser that turns a marked-up teaching string into a sequence of
//      typed segments (plain / causal-phrase / value-chip), and
//   2. the Flutter renderer that promotes causal phrases to the V2-2 sentiment
//      colours and renders dollar values as monospace chips, and
//   3. the plain-text fallback that strips every token and emits only the
//      inner text, so the string reads as the exact verbatim catalog sentence
//      on Shift, exports, short badges, accessibility, and any logging surface.
//
// V2-2 sentiment convention (binding): loss = red, profit = green. Colour is
// driven by the markup token's sentiment suffix, never by the arithmetic sign
// of any number. This renderer uses the codebase-canonical sentiment palette
// (`AppColors.negative` for loss/red, `AppColors.positive` for profit/green),
// which is the same palette dollar_impact_card / lever_card already use.
//
// Hard rules honoured here (V2-4):
//   - Words are preserved byte-for-byte minus the markup tokens. The renderer
//     never adds, drops, or reorders a word; it only wraps existing spans.
//   - No markup token may leak into a non-rendering surface. `stripMarkup`
//     guarantees zero token leakage and equals the verbatim catalog string.
//   - Unrecognised or malformed `[[...]]` sequences are emitted verbatim as
//     plain text (no token swallowing, no silent word loss).
//   - The renderer never introduces an em dash (U+2014) or en dash (U+2013):
//     it only re-styles spans the input already contains.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// The kind of an [InlineEmphasisSegment] parsed out of a V2-4 teaching
/// string.
enum InlineEmphasisKind {
  /// Verbatim prose carried through unchanged.
  plain,

  /// A causal phrase the renderer promotes to the unfavourable (loss / red)
  /// emphasis style. Markup token: `[[bad:…]]`.
  causalBad,

  /// A causal phrase the renderer promotes to the favourable (profit / green)
  /// emphasis style. Markup token: `[[good:…]]`.
  causalGood,

  /// A dollar value rendered as a monospace chip in the unfavourable
  /// (loss / red) sentiment. Markup token: `[[chip:…]]`.
  chipBad,

  /// A dollar value rendered as a monospace chip in the favourable
  /// (profit / green) sentiment. Markup token: `[[chipg:…]]`.
  chipGood,
}

/// One parsed span of a V2-4 teaching string. [text] is always the inner,
/// markup-free text exactly as it appeared in the verbatim catalog sentence.
@immutable
class InlineEmphasisSegment {
  const InlineEmphasisSegment(this.kind, this.text);

  final InlineEmphasisKind kind;
  final String text;

  bool get isPlain => kind == InlineEmphasisKind.plain;
  bool get isChip =>
      kind == InlineEmphasisKind.chipBad || kind == InlineEmphasisKind.chipGood;

  @override
  bool operator ==(Object other) =>
      other is InlineEmphasisSegment &&
      other.kind == kind &&
      other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => 'InlineEmphasisSegment($kind, ${text.length} chars)';
}

/// Parser + fallback for the V2-4 inline-emphasis markup convention.
///
/// The four recognised tokens (and nothing else) are:
///
/// | Token            | Segment kind                 | Render          |
/// | ---------------- | ---------------------------- | --------------- |
/// | `[[bad:…]]`      | [InlineEmphasisKind.causalBad]  | red bold span   |
/// | `[[good:…]]`     | [InlineEmphasisKind.causalGood] | green bold span |
/// | `[[chip:…]]`     | [InlineEmphasisKind.chipBad]    | red mono chip   |
/// | `[[chipg:…]]`    | [InlineEmphasisKind.chipGood]   | green mono chip |
///
/// Inner text may not itself contain `]]`; the first `]]` after the prefix
/// closes the token. Anything that does not match a recognised token is
/// emitted verbatim as plain text. The parser never swallows characters it
/// does not understand, so word preservation is total.
class InlineEmphasisMarkup {
  const InlineEmphasisMarkup._();

  /// Ordered (prefix, kind) table. Longest prefixes first so `chipg:` is not
  /// mis-read as `chip:` + a stray `g`.
  static const List<(String, InlineEmphasisKind)> _tokens =
      <(String, InlineEmphasisKind)>[
    ('[[chipg:', InlineEmphasisKind.chipGood),
    ('[[chip:', InlineEmphasisKind.chipBad),
    ('[[good:', InlineEmphasisKind.causalGood),
    ('[[bad:', InlineEmphasisKind.causalBad),
  ];

  static const String _open = '[[';
  static const String _close = ']]';

  /// Parses [source] into an ordered list of segments. Concatenating every
  /// segment's [InlineEmphasisSegment.text] yields exactly [stripMarkup] of
  /// [source]: the verbatim catalog sentence with tokens removed.
  ///
  /// A string with no markup parses to a single
  /// [InlineEmphasisKind.plain] segment equal to the input, so it renders
  /// identically to a plain `Text`.
  static List<InlineEmphasisSegment> parse(String source) {
    final segments = <InlineEmphasisSegment>[];
    final plainBuffer = StringBuffer();

    void flushPlain() {
      if (plainBuffer.isNotEmpty) {
        segments.add(
          InlineEmphasisSegment(
            InlineEmphasisKind.plain,
            plainBuffer.toString(),
          ),
        );
        plainBuffer.clear();
      }
    }

    var i = 0;
    while (i < source.length) {
      final nextOpen = source.indexOf(_open, i);
      if (nextOpen < 0) {
        // No more potential tokens. The rest is plain.
        plainBuffer.write(source.substring(i));
        break;
      }

      // Carry everything before the candidate token as plain text.
      if (nextOpen > i) {
        plainBuffer.write(source.substring(i, nextOpen));
      }

      final match = _matchTokenAt(source, nextOpen);
      if (match == null) {
        // Not a recognised, well-formed token. Emit the literal "[["
        // verbatim and resume scanning after it so we never swallow a word.
        plainBuffer.write(_open);
        i = nextOpen + _open.length;
        continue;
      }

      flushPlain();
      segments.add(InlineEmphasisSegment(match.kind, match.inner));
      i = match.end;
    }

    flushPlain();

    if (segments.isEmpty) {
      // Empty input → a single empty plain segment so callers can render it
      // exactly like an empty Text without a null branch.
      return const [InlineEmphasisSegment(InlineEmphasisKind.plain, '')];
    }
    return segments;
  }

  /// Strips every recognised markup token from [source], leaving only the
  /// inner text. This is the V2-4 plain-text fallback: the result is the
  /// exact verbatim catalog sentence with zero token leakage, for Shift,
  /// exports, short badges, accessibility, and any logging surface.
  ///
  /// Unrecognised `[[…` sequences are passed through untouched (no word is
  /// ever lost), and no em/en dash is ever introduced.
  static String stripMarkup(String source) {
    final buffer = StringBuffer();
    for (final segment in parse(source)) {
      buffer.write(segment.text);
    }
    return buffer.toString();
  }

  /// Attempts to match a recognised token whose `[[` begins at [openIndex].
  /// Returns null if the prefix is unknown or the token is unterminated
  /// (no `]]`), in which case the caller treats `[[` as literal text.
  static _TokenMatch? _matchTokenAt(String source, int openIndex) {
    for (final (prefix, kind) in _tokens) {
      if (!source.startsWith(prefix, openIndex)) continue;
      final innerStart = openIndex + prefix.length;
      final closeIndex = source.indexOf(_close, innerStart);
      if (closeIndex < 0) {
        // Unterminated token → literal "[[".
        return null;
      }
      final inner = source.substring(innerStart, closeIndex);
      return _TokenMatch(kind, inner, closeIndex + _close.length);
    }
    return null;
  }
}

@immutable
class _TokenMatch {
  const _TokenMatch(this.kind, this.inner, this.end);
  final InlineEmphasisKind kind;
  final String inner;

  /// Index in the source immediately after the closing `]]`.
  final int end;
}

/// Renders a V2-4 teaching string with causal phrases promoted to the V2-2
/// sentiment colours and dollar values rendered as monospace chips. Words are
/// preserved byte-for-byte; only spans are restyled.
///
/// This is a standalone, reusable component. It is intentionally NOT wired
/// into `lever_card.dart`, `variance_this_week_tab.dart`,
/// `variance_learn_tab.dart`, or the catalog. Integration is a later wiring
/// slice (Lane F). For any non-rendering surface, callers use
/// [InlineEmphasisMarkup.stripMarkup] instead of this widget.
class InlineEmphasisText extends StatelessWidget {
  const InlineEmphasisText(
    this.source, {
    super.key,
    this.baseStyle,
    this.textAlign,
  });

  /// The (possibly marked-up) teaching string. May be plain prose, in which
  /// case this renders identically to a plain [Text].
  final String source;

  /// Style for plain (non-emphasised) prose. Emphasis spans inherit colour
  /// and weight from the V2-2 palette but keep this style's size/family.
  /// Defaults to the body-13 teaching style used across Variance.
  final TextStyle? baseStyle;

  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final base = baseStyle ?? AppTextStyles.body13(color: AppColors.textPrimary);
    final segments = InlineEmphasisMarkup.parse(source);

    return Text.rich(
      TextSpan(
        children: [
          for (final segment in segments) _spanFor(segment, base),
        ],
      ),
      textAlign: textAlign,
    );
  }

  InlineSpan _spanFor(InlineEmphasisSegment segment, TextStyle base) {
    switch (segment.kind) {
      case InlineEmphasisKind.plain:
        return TextSpan(text: segment.text, style: base);

      case InlineEmphasisKind.causalBad:
        return TextSpan(
          text: segment.text,
          style: base.copyWith(
            color: AppColors.negative,
            fontWeight: FontWeight.w700,
          ),
        );

      case InlineEmphasisKind.causalGood:
        return TextSpan(
          text: segment.text,
          style: base.copyWith(
            color: AppColors.positive,
            fontWeight: FontWeight.w700,
          ),
        );

      case InlineEmphasisKind.chipBad:
        return _chipSpan(segment.text, base, favorable: false);

      case InlineEmphasisKind.chipGood:
        return _chipSpan(segment.text, base, favorable: true);
    }
  }

  /// A money value rendered as a monospace pill, tinted to its sentiment.
  /// Mirrors the mockup `.chip` / `.chip.g`: monospace, bold, a faint
  /// sentiment-tinted background, snug padding, rounded corners.
  InlineSpan _chipSpan(String value, TextStyle base,
      {required bool favorable}) {
    final fg = favorable ? AppColors.positive : AppColors.negative;
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 1),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
        decoration: BoxDecoration(
          color: fg.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          value,
          style: AppTextStyles.mono12(color: fg, weight: FontWeight.w700)
              .copyWith(fontSize: (base.fontSize ?? 13) - 1),
        ),
      ),
    );
  }
}
