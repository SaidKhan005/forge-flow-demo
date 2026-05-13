// 7.58.2 — Single read source for the primary leak driver shown by
// Variance > Learn (three-card teaching shape: WHAT HAPPENED + WHAT TO
// DO + WHAT TO STUDY) and Variance > History (leak evidence card:
// LeverCardData.metric only). Both surfaces resolve the same lever id
// and the same LeverCardData from the same closed `shift_records`
// population, so the two tabs cannot disagree on the leak identity
// for the same scope.
//
// Per `docs/contracts/phase_7_58_primary_driver_contract.md` Single
// Source of Truth: every renderer reads the persisted `primaryLeverId`
// or its derived id; no surface re-computes a driver from rounded UI
// numbers or a partial axis subset (Findings F-3 / F-7 in the
// companion audit plan).
//
// The per-tab rendering *shape* stays as the contract Presentation
// Split table specifies — Learn keeps its three-card teaching shape,
// History keeps its single-card metric shape — this service only
// reconciles the underlying lever id + LeverCardData identity.

import '../domain/constants/app_defaults.dart';
import '../models/history_pattern_record.dart';
import 'history_teaching_analyzer.dart';

/// Shared resolution result for the primary leak driver. The lever id
/// is always lowercase snake_case (engine form, matches
/// `LaborModel.determineLever` output and `ShiftRecord.normalizedLeverId`).
/// The card is `null` when the lookup fails — empty pattern set,
/// all-unknown ids, or the `on_model` sentinel — in which case
/// renderers fall back to their existing degraded states (Learn
/// "no patterns yet"; History suppresses the leak evidence card).
class VarianceDriverPattern {
  final String leverId;
  final LeverCardData? card;

  const VarianceDriverPattern({required this.leverId, required this.card});

  const VarianceDriverPattern.empty() : leverId = '', card = null;
}

/// Single read source for the primary leak driver consumed by Variance
/// > Learn and Variance > History. Both tabs build their leak surfaces
/// off this service so a future refactor cannot let the two tabs drift
/// to different lever ids or different `LeverCardData.metric` copy for
/// the same closed-shift scope.
class VarianceDriverPatternReadService {
  const VarianceDriverPatternReadService();

  /// Resolves the primary leak driver id + its lever card from the
  /// closed-shift `HistoryPatternRecord` population. Delegates to the
  /// existing `HistoryTeachingAnalyzer.summarize` reducer — the
  /// authoritative tie-break + catalog-filter path the audit plan's
  /// Sub-Slice Family `.2` row binds Learn and History to.
  VarianceDriverPattern resolveLeakDriver(
    List<HistoryPatternRecord> records,
  ) {
    if (records.isEmpty) {
      return const VarianceDriverPattern.empty();
    }
    final summary = HistoryTeachingAnalyzer.summarize(records);
    final leverId = summary.mostCommonLeakId;
    return VarianceDriverPattern(
      leverId: leverId,
      card: LeverCards.lookup(leverId),
    );
  }
}
