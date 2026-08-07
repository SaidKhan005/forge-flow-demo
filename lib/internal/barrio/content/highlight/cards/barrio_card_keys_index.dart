// Per-CARD key phrases: the lookup the reading card asks for its
// highlights (T8 slice 1, 2026-08-02 - MECHANISM ONLY, no data yet).
//
// WHY THIS EXISTS
//
// Today's highlighting is per-MANUAL: `barrioKeyTermsForUnit` returns one
// curated list of ~10 to 18 terms for a whole doc, and every card in that
// doc is matched against the same list. Which words light up on any given
// card is therefore a positional accident (whichever curated terms happen
// to appear first, capped at [kBarrioKeyTermCardCap]), not what that card
// teaches. The operator's bar is the opposite: scanning ONLY the
// highlighted phrases should still convey the card's information.
//
// The fix is per-card phrase sets. This file is the seam that makes that
// possible without a big-bang rewrite: the renderer asks
// [barrioCardKeysForUnit] instead of `barrioKeyTermsForUnit`, and the
// answer is the card's own authored phrases WHEN THEY EXIST, otherwise
// today's per-manual list. Slice 1 ships [kBarrioCardKeysByUnit] EMPTY, so
// every card takes the fallback and the app looks and behaves exactly as it
// does now (proved by `test/barrio_card_key_sets_test.dart`). The authored
// sets land later as pure data, doc by doc, with zero renderer churn.
//
// FILE LAYOUT (and why)
//
// This directory mirrors the two neighbouring content layouts:
//   * `content/highlight/barrio_key_terms.dart` - the matcher + the 14
//     per-manual lists it is fed today (kept: it IS the fallback).
//   * `content/quiz/` - one `barrio_quiz_<doc>.dart` data file per manual
//     plus `barrio_quiz_models.dart` holding the registry and the
//     by-unit-id lookup (`barrioAnswerEvidenceForUnit`).
// So: one `barrio_card_keys_<doc>.dart` data file per curated manual, each
// exporting a single `const Map<String, List<String>>` for its own doc, and
// THIS index holding the merged registry plus the lookup. Two properties
// this buys, both load-bearing for the authoring slice:
//   1. Authoring is conflict-free. ~932 cards get authored by many agents
//      in parallel; each writes only its own doc's file, and the merge
//      touches one small spread list here.
//   2. The key space is unit ids - the SAME key space as
//      [barrioAnswerEvidenceForUnit] - so lookup is one hash probe (no
//      prefix scan over doc ids like the per-manual lookup does), and the
//      test guards can resolve every key against a real `HandbookUnit`.
// The per-doc files are deliberately NOT created empty by this slice: an
// empty data file is dead weight that the authoring slice would overwrite
// anyway. The shape is documented here instead, and the registry below
// shows the exact spread line each new file adds.
//
// AUTHORING CONTRACT (binding on every phrase in every per-doc file)
//
//  1. 3 to 6 phrases per card (the upper bound is [kBarrioKeyTermCardCap];
//      fewer than 3 does not carry the teaching, more than 6 cannot render).
//  2. Every phrase is a VERBATIM substring of THAT card's own body, matched
//     case-insensitively as a whole word. Verbatim law is absolute: the
//     phrase list only says what to STYLE; no body word is ever changed.
//  3. Phrases within one card are mutually NON-OVERLAPPING in the body.
//     (This is what today's per-manual lists get wrong: 'average guest' plus
//     'guest check' fragments one clause into two half-highlights.)
//  4. Ordered by reading position in the body.
//  5. The scan-extraction test: read the card's phrases aloud in order and
//     they must reconstruct the card's teaching as a telegraphic sentence.
//     If they do not, the set is wrong even when every other rule passes.
//  6. Prefer the phrase that carries the FACT over the one that names the
//     TOPIC: '17 weeks unpaid leave' beats 'unpaid leave'.
//  7. No boilerplate: never a doc title, a chapter title, or 'Barrio Legado'
//     on its own. Those score like a concept and teach nothing.
//  8. No numeric fact tokens inside a phrase (no digits). The numeric-pop
//     tier already owns numbers in the manual's accent colour; keeping
//     digits out of key phrases makes the two tiers complementary instead of
//     making them fight for the same words.
//  9. No em dash (U+2014) inside a phrase, and no ' | ' or newline: a phrase
//     must sit inside ONE rendered chunk (the card splits its body on blank
//     lines, and table rows split again on ' | ').
// 10. On a card that backs a quiz question, a phrase must not duplicate that
//     card's [barrioAnswerEvidenceForUnit] wording (avoids teal-on-teal
//     adjacency; the answer tier outranks this one and would drop it).
// Every rule above except 5 is machine-enforced by
// `test/barrio_card_key_sets_test.dart`; rule 5 is the human bar the
// authoring slice is measured against.

import '../barrio_key_terms.dart';
import 'barrio_card_keys_company_handbook.dart';
import 'barrio_card_keys_interview_playbook.dart';
import 'barrio_card_keys_jim_taylor_labor_model.dart';
import 'barrio_card_keys_training_bar_manual.dart';
import 'barrio_card_keys_training_bold_by_design.dart';
import 'barrio_card_keys_training_cheers_responsibility.dart';
import 'barrio_card_keys_training_clover_sop.dart';
import 'barrio_card_keys_training_food_safety.dart';
import 'barrio_card_keys_training_general_words.dart';
import 'barrio_card_keys_training_host_manual.dart';
import 'barrio_card_keys_training_labour_cost.dart';
import 'barrio_card_keys_training_latin_dishes.dart';
import 'barrio_card_keys_training_latin_ingredients.dart';
import 'barrio_card_keys_training_mastering_metrics.dart';
import 'barrio_card_keys_training_push_sop.dart';
import 'barrio_card_keys_training_strong_foundation.dart';
import 'barrio_card_keys_training_suggestive_selling.dart';
import 'barrio_card_keys_training_table_manicuring.dart';
import 'barrio_card_keys_training_three_pillars.dart';
import 'barrio_card_keys_training_wine.dart';

/// Per-CARD curated key phrases, keyed by [HandbookUnit.id].
///
/// Shape: `'<docId>_c<ci>_u<ui>': <phrases in reading order>`, for example
/// `'training_food_safety_c9_u0': ['harmful bacteria', 'danger zone']`.
/// Every entry must satisfy the authoring contract in this file's header.
///
/// POPULATED 2026-08-03 (T8 slice 2): 904 cards across the 14 curated
/// manuals, operator-approved after reviewing a 20-card sample. Every phrase
/// was verified against the live card body before landing here: unique,
/// whole-word, non-overlapping, inside a single paragraph. A phrase that
/// failed any of those would not have highlighted at all, silently, which is
/// why the check runs before the data ships rather than after.
///
/// EXTENDED 2026-08-06: the Wine Training manual, authored to the same
/// contract against the same pre-ship check. Wine is the first doc to carry
/// per-card phrases WITHOUT a per-manual list behind it, which makes the
/// partial-coverage rule visible: a wine card with an entry highlights its
/// own phrases, and a wine card without one highlights nothing at all,
/// exactly as it did before this data landed.
///
/// Cards outside these manuals, and the handful of very short cards that were
/// skipped, still fall through to the per-manual list below, so coverage can
/// grow without touching the renderer.
///
/// A duplicate unit id across two per-doc files is a compile-time error in a
/// const map, which is the cheapest possible guard against double-authoring.
const Map<String, List<String>> kBarrioCardKeysByUnit = <String, List<String>>{
  ...kBarrioCardKeysCompanyHandbook,
  ...kBarrioCardKeysInterviewPlaybook,
  ...kBarrioCardKeysJimTaylorLaborModel,
  ...kBarrioCardKeysTrainingBarManual,
  ...kBarrioCardKeysTrainingBoldByDesign,
  ...kBarrioCardKeysTrainingCheersResponsibility,
  ...kBarrioCardKeysTrainingCloverSop,
  ...kBarrioCardKeysTrainingFoodSafety,
  ...kBarrioCardKeysTrainingGeneralWords,
  ...kBarrioCardKeysTrainingHostManual,
  ...kBarrioCardKeysTrainingLabourCost,
  ...kBarrioCardKeysTrainingLatinDishes,
  ...kBarrioCardKeysTrainingLatinIngredients,
  ...kBarrioCardKeysTrainingMasteringMetrics,
  ...kBarrioCardKeysTrainingPushSop,
  ...kBarrioCardKeysTrainingStrongFoundation,
  ...kBarrioCardKeysTrainingSuggestiveSelling,
  ...kBarrioCardKeysTrainingTableManicuring,
  ...kBarrioCardKeysTrainingThreePillars,
  ...kBarrioCardKeysTrainingWine,
};

/// The key phrases to emphasize inside [unitId]'s body.
///
/// Per-CARD when the card has an authored set, else the per-manual fallback
/// [barrioKeyTermsForUnit] (which is itself empty for uncurated docs, so an
/// uncurated card still highlights nothing). This per-unit fallback is what
/// makes the rollout doc-by-doc and regression-free: an authored card
/// improves, every other card renders exactly what it renders today.
///
/// An entry with an EMPTY list also falls back: an empty list is not a way
/// to silence a card (the contract requires 3 to 6 phrases), so treating it
/// as "absent" keeps a malformed entry from quietly stripping a card's
/// highlighting. The test guards reject empty entries outright.
///
/// Pure, UI-free lookup with the same call shape as
/// [barrioAnswerEvidenceForUnit]: the reading card calls it with a rendering
/// unit's id, so no call site or constructor changes.
List<String> barrioCardKeysForUnit(String unitId) {
  final perCard = kBarrioCardKeysByUnit[unitId];
  if (perCard != null && perCard.isNotEmpty) return perCard;
  return barrioKeyTermsForUnit(unitId);
}
