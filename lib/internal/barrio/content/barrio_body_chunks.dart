// Shared body-chunk enumerator for training card bodies
// (Kindle-style highlights, Slice A, 2026-08-05).
//
// WHY THIS EXISTS. Highlight anchors address the RENDERED chunk, not the
// raw `HandbookUnit.body` string, because the lesson card strips list
// markers before any text reaches a `Text`/`Text.rich`: a bullet drops
// its leading '- ', a numbered row drops the 'N. ' marker (the card
// renders that marker in its own separate `Text`), and a table row is
// split on ' | ' with each cell trimmed. If the anchor space and the
// render space ever disagree by a single character, a stored highlight
// paints on the wrong words. One parser, consumed by both sides, makes
// that impossible.
//
// SOURCE OF TRUTH. Slice B (2026-08-06) deleted the lesson card's
// private parse: `_BlockKind`, `_classifyPara`, `_BodyBlock`,
// `_parseBlocks`, and the `_numberedItem` pattern all lived in
// `widgets/handbook_lesson_card.dart` and all now live here. The card
// renders straight off [barrioBodyBlocks], so there is exactly one
// parse in the codebase and anchor space cannot drift from render
// space by construction.
//
// `test/barrio_body_chunks_test.dart` still holds the two together
// against real shipped manuals: it renders a card and asserts the
// strings this file produces are byte-identical, in order, to the
// strings the card actually put on screen. That test is the reason the
// rules below are stated as rules and not as "whatever the card does".
//
// The rules, all of which the card used to own:
//
//   * paragraphs split on a blank line, verbatim and untrimmed,
//   * a paragraph starting '- ' (after left-trim) is a bullet; the
//     marker is dropped because the card draws the dot,
//   * a paragraph starting 'N. ' (after left-trim) is a numbered step;
//     the marker is dropped into its own `Text`,
//   * a paragraph containing ' | ' is a table row, split on ' | ' with
//     every cell trimmed,
//   * consecutive same-kind list or table paragraphs merge into one
//     block so they render with real structure and even spacing.
//
// Pictures do not affect chunk order: an imaged card renders every
// picture ABOVE the body and then renders the full body as one run, so
// the chunk sequence is a pure function of the body string.

/// What the reader sees for one chunk of a card body.
///
/// A chunk is exactly one string the card hands to a `Text` widget:
/// * [prose] one whole paragraph, verbatim,
/// * [bullet] one bullet's words with the leading '- ' removed,
/// * [numbered] one step's words with the 'N. ' marker removed
///   (the card renders that marker separately),
/// * [tableCell] one trimmed cell of one table row.
enum BarrioBodyChunkKind { prose, bullet, numbered, tableCell }

/// One rendered chunk of a card body.
///
/// [text] is byte-identical to the string the card renders for this
/// chunk, so `[start, end)` offsets into [text] address exactly the
/// characters the reader selected on screen.
class BarrioBodyChunk {
  /// 0-based position of this chunk in the card's reading order.
  final int index;

  /// What kind of rendered chunk this is.
  final BarrioBodyChunkKind kind;

  /// The rendered string, verbatim.
  final String text;

  const BarrioBodyChunk({
    required this.index,
    required this.kind,
    required this.text,
  });
}

/// One typed block of a card body: a paragraph, a bullet list, a run of
/// numbered steps, or a table. The card lays each kind out differently
/// (a dot beside a bullet, a mono marker beside a step, ruled columns
/// for a table), so the block shape has to survive the parse.
enum BarrioBodyBlockKind { prose, bullet, numbered, table }

/// One laid-out row of a block.
///
/// A prose block has one row of one cell. A bullet or numbered block has
/// one row per item, each of one cell. A table block has one row per
/// source line, with one cell per column.
class BarrioBodyRow {
  /// The marker the card draws BESIDE this row, outside the selectable
  /// chunk: 'N.' for a numbered step (or the fallback bullet glyph when
  /// a step in a numbered run carries no marker of its own). Null for
  /// every other kind.
  final String? marker;

  /// The rendered chunks of this row, left to right.
  final List<BarrioBodyChunk> cells;

  const BarrioBodyRow({required this.cells, this.marker});
}

/// One typed block of a card body, with its rows already split into
/// rendered chunks.
class BarrioBodyBlock {
  final BarrioBodyBlockKind kind;
  final List<BarrioBodyRow> rows;

  const BarrioBodyBlock({required this.kind, required this.rows});
}

/// The card body of [body], parsed into the typed blocks the lesson card
/// renders, with every chunk already numbered in reading order.
///
/// This is the single parse in the codebase: the lesson card renders
/// straight off this, and highlight anchors address the chunks it
/// numbers, so the two can never disagree.
List<BarrioBodyBlock> barrioBodyBlocks(String body) {
  final blocks = <BarrioBodyBlock>[];
  var nextIndex = 0;

  BarrioBodyChunk chunk(BarrioBodyChunkKind kind, String text) =>
      BarrioBodyChunk(index: nextIndex++, kind: kind, text: text);

  BarrioBodyRow single(
    BarrioBodyChunkKind kind,
    String text, {
    String? marker,
  }) =>
      BarrioBodyRow(
        marker: marker,
        cells: <BarrioBodyChunk>[chunk(kind, text)],
      );

  for (final block in _parseBlocks(body.split('\n\n'))) {
    switch (block.kind) {
      case BarrioBodyBlockKind.prose:
        // The paragraph renders verbatim, untrimmed.
        blocks.add(BarrioBodyBlock(
          kind: block.kind,
          rows: <BarrioBodyRow>[
            single(BarrioBodyChunkKind.prose, block.items.first),
          ],
        ));
      case BarrioBodyBlockKind.bullet:
        blocks.add(BarrioBodyBlock(
          kind: block.kind,
          rows: <BarrioBodyRow>[
            // The leading '- ' is dropped: the card draws the dot.
            for (final item in block.items)
              single(
                BarrioBodyChunkKind.bullet,
                item.trimLeft().substring(2),
              ),
          ],
        ));
      case BarrioBodyBlockKind.numbered:
        final rows = <BarrioBodyRow>[];
        for (final item in block.items) {
          // The 'N. ' marker is dropped into its own Text; a row in a
          // numbered run that carries no marker keeps its whole
          // left-trimmed self as the chunk and gets the bullet glyph.
          final trimmed = item.trimLeft();
          final match = barrioNumberedItemPattern.firstMatch(trimmed);
          rows.add(single(
            BarrioBodyChunkKind.numbered,
            match != null ? match.group(2)! : trimmed,
            marker: match != null ? '${match.group(1)}.' : '•',
          ));
        }
        blocks.add(BarrioBodyBlock(kind: block.kind, rows: rows));
      case BarrioBodyBlockKind.table:
        blocks.add(BarrioBodyBlock(
          kind: block.kind,
          rows: <BarrioBodyRow>[
            // Each row splits on ' | ' and every cell is trimmed.
            for (final row in block.items)
              BarrioBodyRow(
                cells: <BarrioBodyChunk>[
                  for (final cell in row.split(' | '))
                    chunk(BarrioBodyChunkKind.tableCell, cell.trim()),
                ],
              ),
          ],
        ));
    }
  }

  return blocks;
}

/// Every rendered chunk of [body], in reading order.
///
/// The flattening of [barrioBodyBlocks]: same parse, same numbering,
/// without the layout shape. Anchor and validation code reads this;
/// the renderer reads the blocks.
List<BarrioBodyChunk> chunksForBody(String body) => <BarrioBodyChunk>[
      for (final block in barrioBodyBlocks(body))
        for (final row in block.rows) ...row.cells,
    ];

/// A numbered list row: 'N. ' plus its words. Group 1 is the number,
/// group 2 the rendered words.
final RegExp barrioNumberedItemPattern =
    RegExp(r'^(\d+)\.\s+(.*)$', dotAll: true);

/// One parsed block before its rows are split into chunks: prose carries
/// a single paragraph, list and table blocks carry one entry per source
/// paragraph.
class _RawBlock {
  final BarrioBodyBlockKind kind;
  final List<String> items;
  const _RawBlock(this.kind, this.items);
}

/// Classifies one paragraph. The bullet and numbered tests read the
/// left-trimmed paragraph; the table test reads the paragraph as
/// written.
BarrioBodyBlockKind _classifyPara(String para) {
  final t = para.trimLeft();
  if (t.startsWith('- ')) return BarrioBodyBlockKind.bullet;
  if (barrioNumberedItemPattern.hasMatch(t)) {
    return BarrioBodyBlockKind.numbered;
  }
  if (para.contains(' | ')) return BarrioBodyBlockKind.table;
  return BarrioBodyBlockKind.prose;
}

/// Groups paragraphs into ordered blocks, merging runs of same-kind
/// list/table paragraphs.
List<_RawBlock> _parseBlocks(List<String> paras) {
  final blocks = <_RawBlock>[];
  var i = 0;
  while (i < paras.length) {
    final kind = _classifyPara(paras[i]);
    if (kind == BarrioBodyBlockKind.prose) {
      blocks.add(_RawBlock(kind, [paras[i]]));
      i++;
      continue;
    }
    final items = <String>[];
    while (i < paras.length && _classifyPara(paras[i]) == kind) {
      items.add(paras[i]);
      i++;
    }
    blocks.add(_RawBlock(kind, items));
  }
  return blocks;
}
