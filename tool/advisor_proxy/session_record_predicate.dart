// Slice A11.1 — Production session-record completeness predicate
// (proxy-side import path).
//
// The predicate itself lives at
// `tool/pressure/p4_session_record_predicate.dart` because it landed
// with the addendum B1+B2 pressure-soak harnesses (R3 §2 cited it as
// "the cheapest immediate defense" for Bug A — proxy returned an
// incomplete session record). This file is a one-line re-export so the
// proxy hot path imports it from `tool/advisor_proxy/` rather than
// reaching across into `tool/pressure/`. The pressure harnesses keep
// their existing import; the proxy uses this re-export.
//
// Authority anchors:
//   - docs/archive/_execution/lane_a_code_health/03_execution_slices.md
//     "Slice A11.1 — Production Session-Record Gauge"
//   - docs/archive/_execution/lane_a_code_health/01_product_rule_and_ia.md
//     R3 §2 stretch-goal recommendation #3
//   - docs/archive/_execution/lane_a_code_health/02_plumbing_audit_matrix.md
//     Lens 13 row "R3 §2 production gauge recommendation"
//
// The re-export is `export …`-style so dart-analyze treats this file
// as the canonical import path for proxy code without changing the
// authoring location of the predicate (Lane A's "Smallest set that
// proves the seam" testing rule + the slice doc's "refactor if needed"
// guidance — pure import is preferable to refactor).
export '../pressure/p4_session_record_predicate.dart'
    show SessionRecordAssertion, SessionRecordCompleteness;
