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
// SOURCE OF TRUTH, TODAY. Until Slice B swaps the card over to this
// helper, the private parse inside `widgets/handbook_lesson_card.dart`
// is still the source of truth and this file mirrors it exactly:
//
//   * paragraph split          `_UnitBody.build`      card line 723
//   * paragraph classification `_classifyPara`        card line 621
//   * numbered-item pattern    `_numberedItem`        card line 619
//   * same-kind run grouping   `_parseBlocks`         card line 637
//   * chunk emission order     `_UnitBody._renderRun` card line 759
//                              `_renderBlock`         card line 775
//   * bullet marker strip      `_renderBlock` bullet  card line 782
//   * numbered marker strip    `_numberedRow`         card line 825
//   * table cell split + trim  `_table` / `_tableRow` card lines 849, 879
//
// `test/barrio_body_chunks_test.dart` locks the two together against
// real shipped manuals: it renders a card and asserts the strings this
// file produces are byte-identical, in order, to the strings the card
// actually put on screen. Slice B deletes the card's private parse and
// calls `chunksForBody` instead, at which point this file becomes the
// single source of truth on its own.
//
// Pictures do not affect chunk order: an imaged card renders every
// picture ABOVE the body and then renders the full body as one run
// (card lines 740 to 754), so the chunk sequence is a pure function of
// the body string.

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

/// Every rendered chunk of [body], in reading order.
///
/// Mirrors the lesson card's parse exactly (see the file header for the
/// rule-by-rule citations). The card has a fast path for a body that is
/// one lone prose block (card line 761); it emits the same single chunk
/// this general loop does, so no special case is needed here.
List<BarrioBodyChunk> chunksForBody(String body) {
  final chunks = <BarrioBodyChunk>[];

  void emit(BarrioBodyChunkKind kind, String text) {
    chunks.add(
      BarrioBodyChunk(index: chunks.length, kind: kind, text: text),
    );
  }

  for (final block in _parseBlocks(body.split('\n\n'))) {
    switch (block.kind) {
      case _BlockKind.prose:
        // Card line 762 / 778: the paragraph renders verbatim, untrimmed.
        emit(BarrioBodyChunkKind.prose, block.items.first);
      case _BlockKind.bullet:
        for (final item in block.items) {
          // Card line 782: the leading '- ' is dropped (the dot is drawn).
          emit(BarrioBodyChunkKind.bullet, item.trimLeft().substring(2));
        }
      case _BlockKind.numbered:
        for (final item in block.items) {
          // Card lines 826 to 828: the 'N. ' marker is dropped into its
          // own Text; an unmatched row renders its trimLeft'd self.
          final trimmed = item.trimLeft();
          final match = barrioNumberedItemPattern.firstMatch(trimmed);
          emit(
            BarrioBodyChunkKind.numbered,
            match != null ? match.group(2)! : trimmed,
          );
        }
      case _BlockKind.table:
        for (final row in block.items) {
          // Card lines 852 and 879: split on ' | ', each cell trimmed.
          for (final cell in row.split(' | ')) {
            emit(BarrioBodyChunkKind.tableCell, cell.trim());
          }
        }
    }
  }

  return chunks;
}

/// A numbered list row: 'N. ' plus its words. Group 1 is the number,
/// group 2 the rendered words. Mirrors `_numberedItem`, card line 619.
final RegExp barrioNumberedItemPattern =
    RegExp(r'^(\d+)\.\s+(.*)$', dotAll: true);

/// The four block kinds the card renders. Mirrors `_BlockKind`,
/// card line 617.
enum _BlockKind { prose, bullet, numbered, table }

/// One parsed block: prose carries a single paragraph, list and table
/// blocks carry one entry per source paragraph. Mirrors `_BodyBlock`,
/// card line 629.
class _BodyBlock {
  final _BlockKind kind;
  final List<String> items;
  const _BodyBlock(this.kind, this.items);
}

/// Classifies one paragraph. Mirrors `_classifyPara`, card line 621:
/// the bullet and numbered tests read the left-trimmed paragraph, the
/// table test reads the paragraph as written.
_BlockKind _classifyPara(String para) {
  final t = para.trimLeft();
  if (t.startsWith('- ')) return _BlockKind.bullet;
  if (barrioNumberedItemPattern.hasMatch(t)) return _BlockKind.numbered;
  if (para.contains(' | ')) return _BlockKind.table;
  return _BlockKind.prose;
}

/// Groups paragraphs into ordered blocks, merging runs of same-kind
/// list/table paragraphs. Mirrors `_parseBlocks`, card line 637.
List<_BodyBlock> _parseBlocks(List<String> paras) {
  final blocks = <_BodyBlock>[];
  var i = 0;
  while (i < paras.length) {
    final kind = _classifyPara(paras[i]);
    if (kind == _BlockKind.prose) {
      blocks.add(_BodyBlock(kind, [paras[i]]));
      i++;
      continue;
    }
    final items = <String>[];
    while (i < paras.length && _classifyPara(paras[i]) == kind) {
      items.add(paras[i]);
      i++;
    }
    blocks.add(_BodyBlock(kind, items));
  }
  return blocks;
}
