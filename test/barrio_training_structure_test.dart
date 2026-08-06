// Giant-manual STRUCTURE pass (operator-approved 2026-07-26). Locks the
// presentation metadata the generator now emits for the two long manuals:
//
//   * BOLD By Design (training_bold_by_design): 34 chapters grouped into
//     5 named PARTS shown to the reader, plus the doc-level depth-framing
//     badge word 'DEEPER DIVE'.
//   * OE Cheers to Responsibility (training_cheers_responsibility): the 24
//     parsed chapters merged into 5 named SECTIONS, with every original
//     chapter heading surviving verbatim as a card title inside its
//     section (that is why the verbatim gate still reports lost=0w).
//
// Bodies, card order, and card titles are never altered by this pass; this
// test guards the structure so a future regeneration or grouping-table
// edit can never silently drop a part, rename a section, or lose the
// depth badge. If the structure changes deliberately, update these
// numbers/names in the same commit (that is the point of the guard).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/content/company_handbook_content.dart';
import 'package:forge_and_flow/internal/barrio/content/training/training_docs.dart';

void main() {
  final bold = kBarrioTrainingDocs['training_bold_by_design'];
  final cheers = kBarrioTrainingDocs['training_cheers_responsibility'];

  test('both restructured manuals are in the registry', () {
    expect(bold, isNotNull);
    expect(cheers, isNotNull);
  });

  // --- BOLD By Design: 5 named parts + depth badge ------------------------

  // The operator-approved part names, in reading order, each with the
  // count of chapters it covers (7 + 7 + 8 + 5 + 7 = 34).
  const boldParts = <(String, int)>[
    ('The Foundations', 7),
    ('Understanding Productivity', 7),
    ('Managing Productivity', 8),
    ('Building the Productivity System', 5),
    ('Leading for the Long Term', 7),
  ];

  test('BOLD By Design carries the DEEPER DIVE depth badge', () {
    expect(bold!.depthBadge, 'DEEPER DIVE');
  });

  test('every other manual has no depth badge (bold is the only one)', () {
    for (final entry in kBarrioTrainingDocs.entries) {
      if (entry.key == 'training_bold_by_design') continue;
      expect(entry.value.depthBadge, isNull,
          reason: '${entry.key} should not carry a depth badge');
    }
  });

  test('BOLD By Design still has 34 chapters (parts annotate, never merge)',
      () {
    expect(bold!.chapters, hasLength(34));
  });

  test('BOLD By Design groups its 34 chapters into the 5 named parts', () {
    final chapters = bold!.chapters;
    var ci = 0;
    for (var pi = 0; pi < boldParts.length; pi++) {
      final (name, span) = boldParts[pi];
      for (var k = 0; k < span; k++) {
        final chapter = chapters[ci];
        expect(chapter.partTitle, name,
            reason: 'chapter $ci should be in part "$name"');
        expect(chapter.partIndex, pi + 1);
        expect(chapter.partCount, boldParts.length);
        ci++;
      }
    }
    // Every chapter got covered exactly once, in order.
    expect(ci, chapters.length);
  });

  test('BOLD By Design part names are the operator-approved wording', () {
    final names = <String>{
      for (final chapter in bold!.chapters) chapter.partTitle!,
    };
    expect(names, {
      'The Foundations',
      'Understanding Productivity',
      'Managing Productivity',
      'Building the Productivity System',
      'Leading for the Long Term',
    });
  });

  // --- OE Cheers to Responsibility: 5 merged, named sections --------------

  const cheersSections = <String>[
    'Governing Bodies and Licenses',
    'Drinks, Intoxication, and ID',
    'Alcohol Combinations and Binge Drinking',
    'Serving Decisions and Liability',
    'Premises Rules, Hours, and Pricing',
  ];

  test('Cheers is merged from 24 parsed chapters into exactly 5 sections',
      () {
    expect(cheers!.chapters, hasLength(5));
    expect([for (final c in cheers.chapters) c.title], cheersSections);
  });

  test('Cheers sections carry no part grouping (merge, not parts)', () {
    for (final chapter in cheers!.chapters) {
      expect(chapter.partTitle, isNull);
      expect(chapter.partIndex, isNull);
      expect(chapter.partCount, isNull);
    }
  });

  test('every original Cheers chapter heading survives as a card title', () {
    // The 24 parsed chapter headings (the merge must keep each one as a
    // verbatim card title inside its section). A split section puts the
    // verbatim heading on the card that OPENS the run; cards 2..N carry
    // their own titles, so only run-start titles are matched here.
    const originalHeadings = <String>[
      'Responsible Alcohol Service In NL', // the doc intro chapter
      'Governing Bodies',
      'Newfoundland and Labrador Liquor Corporation',
      'Licenses',
      'Secondary Licenses',
      'Standard Drink Size',
      'BAC Chart',
      'Signs of Intoxication',
      'Identification',
      'Valid Forms of ID',
      'Alcohol Combination',
      'Alcohol and Energy Drinks',
      'Alcohol and Cannabis',
      'Alcohol and Other Drugs',
      'Binge Drinking',
      'Monitor Intoxication',
      'Refusing Service',
      'Drinking and Driving',
      'Liability',
      'Alcohol Leaving the Premises',
      'Overcrowding',
      'Hours of Sale and Consumption',
      'Mandatory Exit',
      'Minimum Pricing',
    ];
    final cardTitles = <String>{
      for (final chapter in cheers!.chapters)
        for (final unit in chapter.units)
          if (unit.runIndex == 1) unit.title,
    };
    for (final heading in originalHeadings) {
      expect(cardTitles, contains(heading),
          reason: '"$heading" must survive verbatim as a card title');
    }
  });

  // --- Run metadata: honest arithmetic, additive -------------------------

  test('split runs carry honest K-of-N run metadata (unsplit cards are 1/1)',
      () {
    var sawSplit = false;
    for (final doc in kBarrioTrainingDocs.values) {
      for (final chapter in doc.chapters) {
        final units = chapter.units;
        // Contiguous runs of the same runLength are the split groups.
        for (var i = 0; i < units.length; i++) {
          final unit = units[i];
          expect(unit.runIndex, inInclusiveRange(1, unit.runLength),
              reason: '${unit.id} runIndex within 1..runLength');
          if (unit.runLength > 1) sawSplit = true;
        }
      }
    }
    // The corpus has long sections that split, so at least one run exists.
    expect(sawSplit, isTrue);
  });

  test('a known BOLD By Design run reads 1..N in order', () {
    // The intro chapter's opening section splits across cards; whichever
    // chapter holds a multi-card run must number it 1..N contiguously.
    HandbookChapter? runChapter;
    for (final chapter in bold!.chapters) {
      if (chapter.units.any((u) => u.runLength > 1)) {
        runChapter = chapter;
        break;
      }
    }
    expect(runChapter, isNotNull,
        reason: 'BOLD By Design has long sections that split into runs');
    // Walk the first multi-card run and assert 1..N contiguity.
    final units = runChapter!.units;
    final start = units.indexWhere((u) => u.runLength > 1);
    final runLen = units[start].runLength;
    for (var k = 0; k < runLen; k++) {
      expect(units[start + k].runLength, runLen);
      expect(units[start + k].runIndex, k + 1);
    }
  });
}
