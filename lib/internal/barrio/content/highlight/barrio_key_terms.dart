// Key-term color emphasis (operator research pilot 2026-07-28; rolled out to
// all prose reading manuals 2026-07-29 after operator approval).
//
// Research-backed, author-CURATED emphasis: a small, hand-picked set of
// clearly-important, unambiguous domain concepts get a color+weight cue so
// the text-heavy reading manuals become more scannable. The pilot proved the
// look on "The Three Pillars of Hospitality"; the rollout adds a curated term
// list for EVERY text-heavy prose manual (handbook, interview playbook, labor
// model, foundation, table manicuring, suggestive selling, labour cost, food
// safety, responsible alcohol, mastering metrics, bold by design, host manual,
// bar manual). Non-prose docs (glossary term-card decks, SOP/screenshot
// manuals, recipe cards, menu slides, and picture-first docs) are deliberately
// NOT curated and return an empty term list, so they show no highlighting.
//
// Verbatim law (binding): the body TEXT is NEVER altered. This file only
// supplies which curated phrases to STYLE; the matcher returns
// [start, end) offsets into the original string and the card renders the
// exact original substring (case and characters unchanged) with added
// weight+color. No word is ever changed, added, or removed.
//
// Sparse by design ("if everything is bold, nothing is"):
//   * ~1 highlight per 2 sentences, capped HARD at [kBarrioKeyTermCardCap]
//     spans per card.
//   * Only the FIRST occurrence of each term per card is emphasized; later
//     repeats stay plain.
//   * Curated toward multi-word phrases and distinctive nouns; short common
//     words are deliberately excluded so nothing false-matches.
//
// Composition (lowest precedence): the caller passes the ranges already
// claimed by search highlights, tap-to-define term links, numeric fact
// pops, and quiz answer evidence as blockedRanges; any key-term range that
// overlaps one is dropped whole, so the existing span always wins.

import '../../search/barrio_training_search.dart';

/// Hard per-card cap on emphasized key-term spans. Density guard: at most
/// this many curated terms are colored on any single reading card.
const int kBarrioKeyTermCardCap = 6;

// Curation contract for every list below (mirrors the Three Pillars quality
// bar): ~10 to 18 entries; each entry is a genuine domain concept that appears
// VERBATIM (as a whole word, case-insensitive) in that manual's body prose,
// verified against the content file before inclusion (a term that does not
// appear is dead weight and is excluded). Multi-word phrases and distinctive
// nouns are preferred; short common words are excluded so nothing false-matches.
// Matching is case-insensitive and whole-word, so ordering here is irrelevant
// (the matcher sorts by position, longest-first at a tie).

/// "The Three Pillars of Hospitality" (`training_three_pillars`) - the pilot.
const List<String> _kThreePillarsKeyTerms = <String>[
  'hospitality',
  'three pillars',
  'guest experience',
  'guest satisfaction',
  'guest perception',
  'atmosphere',
  'ambiance',
  'lighting',
  'cleanliness',
  'service',
  'communication',
  'attentiveness',
  'food',
  'food quality',
  'presentation',
  'reputation',
  'standards',
];

/// Company handbook (`company_handbook`) - HR, safety, and workplace policy.
const List<String> _kCompanyHandbookKeyTerms = <String>[
  'barrio legado',
  'workplace harassment',
  'workplace violence',
  'family violence',
  'hazardous product',
  'safety data sheet',
  'unpaid leave',
  'disciplinary action',
  'work environment',
  'communicable disease',
  'designated investigator',
  'precautionary statements',
  'occupational health',
  'mental health',
  'formal complaint',
  'written notice',
];

/// Interview playbook (`interview_playbook`) - hiring and candidate signals.
const List<String> _kInterviewPlaybookKeyTerms = <String>[
  'green flags',
  'red flags',
  'candidate',
  'core values',
  'chaotic shift',
  'dining experience',
  'vibrant culture',
  'undeniable pressure',
  'evaluating candidates',
  'previous manager',
  'hiring',
  'resume',
  'interview',
  'culture',
];

/// Jim Taylor labor model (`jim_taylor_labor_model`) - labor math and targets.
const List<String> _kJimTaylorKeyTerms = <String>[
  'theoretical labor',
  'blended wage',
  'labor cost',
  'wage mix',
  'forecasted sales',
  'forecasted covers',
  'target cplh',
  'target splh',
  'productivity',
  'variance',
  'daypart',
  'cplh',
  'splh',
  'labor hours',
  'food cost',
];

/// Strong foundation (`training_strong_foundation`) - consistency and standards.
const List<String> _kStrongFoundationKeyTerms = <String>[
  'consistency',
  'standards',
  'dining experience',
  'exceptional service',
  'high standards',
  'portion sizes',
  'repeat business',
  'collective success',
  'competitive landscape',
  'standardized recipes',
  'meticulous attention',
  'inventory management',
  'reputation',
  'atmosphere',
  'expectations',
  'trust',
];

/// Table manicuring (`training_table_manicuring`) - table maintenance craft.
const List<String> _kTableManicuringKeyTerms = <String>[
  'table manicuring',
  'dining experience',
  'table maintenance',
  'guest experience',
  'dining environment',
  'clearing plates',
  'inviting atmosphere',
  'guest satisfaction',
  'thoughtful approach',
  'delicate balance',
  'uncluttered dining',
  'atmosphere',
  'manicuring',
  'servers',
];

/// Suggestive selling (`training_suggestive_selling`) - selling technique.
const List<String> _kSuggestiveSellingKeyTerms = <String>[
  'suggestive selling',
  'dining experience',
  'guest experience',
  'passive selling',
  'active selling',
  'complementary items',
  'menu knowledge',
  'selling techniques',
  'guest check',
  'high-margin items',
  'personalized experience',
  'cross-selling',
  'upselling',
  'descriptive language',
  'beverage sales',
  'recommendations',
];

/// Labour cost (`training_labour_cost`) - productivity and cost control.
const List<String> _kLabourCostKeyTerms = <String>[
  'productivity',
  'average guest',
  'guest check',
  'labor costs',
  'labor percentage',
  'guest experience',
  'operational efficiency',
  'staffing levels',
  'chit times',
  'table turns',
  'informed decisions',
  'average wage',
  'table turnover',
  'service quality',
  'profitability',
  'productivity score',
];

/// Food safety (`training_food_safety`) - handling, allergens, temperature.
const List<String> _kFoodSafetyKeyTerms = <String>[
  'food safety',
  'foodborne illness',
  'allergic reactions',
  'danger zone',
  'food allergies',
  'public health',
  'food handling',
  'harmful bacteria',
  'tree nuts',
  'food allergens',
  'food preparation',
  'physical hazards',
  'internal temperature',
  'temperature',
  'bacteria',
  'cross-contamination',
];

/// Cheers to responsibility (`training_cheers_responsibility`) - alcohol law.
const List<String> _kCheersResponsibilityKeyTerms = <String>[
  'alcohol',
  'liquor',
  'responsible alcohol',
  'licensed establishment',
  'licensed premises',
  'alcoholic beverages',
  'liquor corporation',
  'liquor control',
  'alcohol service',
  'slurred speech',
  'binge drinking',
  'blood alcohol',
  'alcohol poisoning',
  'civil liability',
  'intoxication',
  'consumption',
];

/// Mastering metrics (`training_mastering_metrics`) - restaurant metrics.
const List<String> _kMasteringMetricsKeyTerms = <String>[
  'average guest',
  'guest check',
  'operational efficiency',
  'dining experience',
  'restaurant managers',
  'restaurant operators',
  'cover count',
  'guest experience',
  'guest traffic',
  'labor costs',
  'productivity score',
  'staffing levels',
  'guest satisfaction',
  'spending patterns',
  'seating capacity',
  'cplh',
];

/// Bold by design (`training_bold_by_design`) - the productivity system.
const List<String> _kBoldByDesignKeyTerms = <String>[
  'optimal productivity',
  'productivity zone',
  'labor percentage',
  'dining room',
  'guest experience',
  'labor hours',
  'guest spend',
  'optimal range',
  'financial performance',
  'low productivity',
  'service quality',
  'staffing levels',
  'guest behavior',
  'labor cost',
  'ticket times',
  'profit gap',
  'workload',
];

/// Host manual (`training_host_manual`) - greeting, seating, guest care.
const List<String> _kHostManualKeyTerms = <String>[
  'barrio legado',
  'eye contact',
  'guest experience',
  'host stand',
  'active listening',
  'feel valued',
  'warm smile',
  'unhealthy conflict',
  'body language',
  'coat check',
  'genuine warmth',
  'lasting connections',
  'reservations',
  'welcoming',
  'memorable',
  'atmosphere',
];

/// Bar manual (`training_bar_manual`) - bartending and bar service.
const List<String> _kBarManualKeyTerms = <String>[
  'barrio legado',
  'dining experience',
  'guest experience',
  'exceptional service',
  'guest satisfaction',
  'suggestive selling',
  'broken glass',
  'warm smile',
  'net sales',
  'active listening',
  'table manicuring',
  'temperature logs',
  'unhealthy conflict',
  'bartenders',
  'cocktail',
  'ingredients',
  'liquor',
];

/// Per-manual curated term lists, keyed by the EXACT doc id used in
/// [kBarrioTrainingDocs] (some lack the `training_` prefix). A unit belongs
/// to a doc when its id starts with `<docId>_` (unit ids are
/// `<docId>_c<ci>_u<ui>`). Only prose reading manuals appear here; every doc
/// absent from this map returns an empty list (no highlighting).
const Map<String, List<String>> _kKeyTermsByDoc = <String, List<String>>{
  'training_three_pillars': _kThreePillarsKeyTerms,
  'company_handbook': _kCompanyHandbookKeyTerms,
  'interview_playbook': _kInterviewPlaybookKeyTerms,
  'jim_taylor_labor_model': _kJimTaylorKeyTerms,
  'training_strong_foundation': _kStrongFoundationKeyTerms,
  'training_table_manicuring': _kTableManicuringKeyTerms,
  'training_suggestive_selling': _kSuggestiveSellingKeyTerms,
  'training_labour_cost': _kLabourCostKeyTerms,
  'training_food_safety': _kFoodSafetyKeyTerms,
  'training_cheers_responsibility': _kCheersResponsibilityKeyTerms,
  'training_mastering_metrics': _kMasteringMetricsKeyTerms,
  'training_bold_by_design': _kBoldByDesignKeyTerms,
  'training_host_manual': _kHostManualKeyTerms,
  'training_bar_manual': _kBarManualKeyTerms,
};

/// The curated key terms to emphasize inside [unitId]'s body.
///
/// Per-manual lookup: returns the curated list for the doc that owns
/// [unitId] (matched by `unitId.startsWith('<docId>_')`), or an empty list
/// for any doc not in [_kKeyTermsByDoc] (non-prose docs show no
/// highlighting). Mirrors the [barrioAnswerEvidenceForUnit] lookup shape: a
/// pure, UI-free lookup the reading card calls with a rendering unit's id.
List<String> barrioKeyTermsForUnit(String unitId) {
  for (final entry in _kKeyTermsByDoc.entries) {
    if (unitId.startsWith('${entry.key}_')) return entry.value;
  }
  return const <String>[];
}

/// One emphasized key-term occurrence inside a text chunk: [start, end)
/// offsets index the chunk string itself (styling only, verbatim law).
class BarrioKeyTermMatch {
  final int start;
  final int end;

  /// The folded term, for first-occurrence-per-card bookkeeping.
  final String foldedTerm;

  const BarrioKeyTermMatch({
    required this.start,
    required this.end,
    required this.foldedTerm,
  });
}

/// Pure-Dart, render-time whole-word matcher for the curated key terms.
///
/// Case-insensitive and diacritic-folded via [BarrioTrainingSearch.fold]
/// (length-preserving, so fold-space offsets index the original text
/// directly). Whole-word only: 'service' never matches inside
/// 'serviceable', 'food' never matches inside 'foodborne'.
class BarrioKeyTermHighlight {
  BarrioKeyTermHighlight._();

  /// Finds the key-term spans to emphasize inside one text chunk of a card.
  ///
  /// [alreadyUsed] carries the folded terms emphasized earlier in the SAME
  /// card (the caller threads one set through the card's chunks in reading
  /// order): first-occurrence-per-card, and its size is the running span
  /// count that enforces [maxPerCard]. Accepted matches are added to it.
  ///
  /// [blockedRanges] are [start, end) ranges already claimed by
  /// higher-precedence styling (search highlights, term links, numeric
  /// pops, answer evidence); an overlapping key-term occurrence is dropped
  /// whole. Returned matches are sorted and mutually non-overlapping.
  static List<BarrioKeyTermMatch> matchesIn(
    String text,
    List<String> terms, {
    required Set<String> alreadyUsed,
    int maxPerCard = kBarrioKeyTermCardCap,
    List<List<int>> blockedRanges = const [],
  }) {
    if (terms.isEmpty || text.isEmpty) return const <BarrioKeyTermMatch>[];
    if (alreadyUsed.length >= maxPerCard) return const <BarrioKeyTermMatch>[];
    final candidates = _firstOccurrenceCandidates(text, terms, alreadyUsed)
      // Earliest first; at the same start the longer term wins ('food
      // quality' beats 'food'), so a shorter substring never steals the spot.
      ..sort(_byStartLongestFirst);
    if (candidates.isEmpty) return const <BarrioKeyTermMatch>[];
    final accepted = <BarrioKeyTermMatch>[];
    for (final match in candidates) {
      if (alreadyUsed.length >= maxPerCard) break; // card cap reached
      // No overlap among accepted key-term spans in this chunk, and a
      // higher-precedence span wins: drop the overlapping key-term whole.
      if (accepted.isNotEmpty && match.start < accepted.last.end) continue;
      if (_intersectsAny(match, blockedRanges)) continue;
      accepted.add(match);
      alreadyUsed.add(match.foldedTerm);
    }
    return accepted;
  }

  /// The first whole-word occurrence of each not-yet-used term inside [text]
  /// (fold-space offsets index the original). One candidate per distinct
  /// term: [alreadyUsed] skips terms emphasized earlier on the card and an
  /// in-chunk seen-set dedupes repeated curated entries.
  static List<BarrioKeyTermMatch> _firstOccurrenceCandidates(
    String text,
    List<String> terms,
    Set<String> alreadyUsed,
  ) {
    final folded = BarrioTrainingSearch.fold(text);
    final seenInChunk = <String>{};
    final candidates = <BarrioKeyTermMatch>[];
    for (final rawTerm in terms) {
      final term = BarrioTrainingSearch.fold(rawTerm.trim());
      if (term.isEmpty) continue;
      if (alreadyUsed.contains(term)) continue;
      if (!seenInChunk.add(term)) continue;
      final idx = _firstWholeWord(folded, term);
      if (idx < 0) continue;
      candidates.add(BarrioKeyTermMatch(
        start: idx,
        end: idx + term.length,
        foldedTerm: term,
      ));
    }
    return candidates;
  }

  /// Sort key: earliest start first, longer term first at a tie.
  static int _byStartLongestFirst(BarrioKeyTermMatch a, BarrioKeyTermMatch b) =>
      a.start != b.start ? a.start.compareTo(b.start) : b.end.compareTo(a.end);

  /// First whole-word occurrence of [term] in [folded], or -1. Boundaries
  /// are checked at the term's outer edges only, so a multi-word term keeps
  /// its internal spaces.
  static int _firstWholeWord(String folded, String term) {
    var from = 0;
    while (true) {
      final idx = folded.indexOf(term, from);
      if (idx < 0) return -1;
      final beforeOk = idx == 0 || !_isWordChar(folded.codeUnitAt(idx - 1));
      final after = idx + term.length;
      final afterOk =
          after >= folded.length || !_isWordChar(folded.codeUnitAt(after));
      if (beforeOk && afterOk) return idx;
      from = idx + 1;
    }
  }

  /// Whether the folded code unit belongs to a word ([a-z0-9]).
  static bool _isWordChar(int u) =>
      (u >= 0x61 && u <= 0x7A) || (u >= 0x30 && u <= 0x39);

  static bool _intersectsAny(
      BarrioKeyTermMatch match, List<List<int>> ranges) {
    for (final range in ranges) {
      if (match.start < range[1] && match.end > range[0]) return true;
    }
    return false;
  }
}
