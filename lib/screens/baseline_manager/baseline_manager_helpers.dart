// Phase 7.55o.5 — Baseline Manager shared helpers.
//
// Date parse/format helpers, a suggested-star predicate, and the
// lever-id → human label lookup. Extracted from the pre-split
// baseline_manager_screen.dart so the calendar, day detail, and
// shell files can share them by public name. Semantics unchanged.

import '../../data/legacy_fixture_data.dart';
import '../../models/baseline_candidate_shift.dart';

// ─── Date helpers ─────────────────────────────────────────────────────────────

DateTime parseIsoDate(String iso) {
  final p = iso.split('-');
  return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
}

String formatIsoDate(DateTime dt) {
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}'
      '-${dt.day.toString().padLeft(2, '0')}';
}

const monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String formatDisplayDate(String iso) {
  final dt = parseIsoDate(iso);
  return '${monthNames[dt.month - 1]} ${dt.day}';
}

String formatDayDetailDate(String iso) {
  final dt = parseIsoDate(iso);
  return '${_weekdayNames[dt.weekday - 1]}, ${monthNames[dt.month - 1]} ${dt.day}';
}

// ─── Suggested star shift helper ──────────────────────────────────────────────
// A candidate is "suggested" when its lever signal is favorable.
// Uses the canonical LeverCards lookup — no new scoring model.

bool isSuggestedStar(BaselineCandidateShift c) {
  final card = LeverCards.all.cast<LeverCardData?>().firstWhere(
        (l) => l!.id == c.primaryLeverId,
        orElse: () => null,
      );
  return card != null && card.isFavorable;
}

// ─── Lever label formatter ───────────────────────────────────────────────────
// Reuses canonical LeverCardData.metric for full natural-language lever meaning.
// This preserves direction (e.g. 'CPLH ABOVE TARGET' vs 'CPLH BELOW TARGET')
// instead of collapsing to a generic metric bucket ('CPLH').
// Falls back to title-casing the raw id if no match is found.

String leverLabel(String leverId) {
  final card = LeverCards.all.cast<LeverCardData?>().firstWhere(
        (l) => l!.id == leverId,
        orElse: () => null,
      );
  if (card != null) return card.metric;
  // Fallback: title-case the snake_case id
  return leverId
      .split('_')
      .map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}
