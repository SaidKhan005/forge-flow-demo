# Data Accuracy Covers Truth Plan

Date: 2026-05-19
Branch: codex/data-accuracy-covers-truth

## Plain-English Goal

- Keep manual cover entries written from mobile and Operator Web from wiping each other out.
- Treat a real POS cover count of `0` as real closed truth when the POS actually sends cover counts.
- Do not treat Square or Clover's missing covers as a real zero, because those vendors do not expose covers through public APIs.
- Scope operator Data Accuracy repeat-write keys by operator and location so one tenant cannot block another tenant's write by reusing the same key.
- Align the contract and migration text with the runtime truth.

## Findings

- Operator Web sends a full `covers_manual_entries` JSON object when saving settings.
- Mobile writes a single manual cover slot.
- The proxy currently replaces the whole manual-cover JSON object during the full settings save, so a stale Operator Web save can erase a newer mobile slot.
- Closed aggregation only accepts vendor covers when the summed value is greater than zero, so a real vendor zero falls through to manual or forecast data.
- The Postgres migration makes `cover_facts.covers` non-null with a default `0`, which blurs the difference between "vendor sent zero" and "vendor sent no cover field".
- Square and Clover intentionally write null covers because they do not expose cover counts through public APIs.
- Operator Data Accuracy writes use the shared admin idempotency table with caller-provided keys, so the runtime should scope those keys before storage.
- The Data Accuracy contract still says the keyed service-period settings table owns manual cover entries, but runtime still stores them on `data_accuracy_settings.covers_manual_entries`.

## Fix Plan

- Update `cover_facts.covers` in the Phase 8 legacy fact-table migration so fresh databases create it as nullable.
- Add a forward migration so already-applied databases also drop the old default and not-null constraint.
- Update closed-shift cover aggregation so:
  - vendor covers are used only when the POS vendor is marked as cover-capable;
  - a numeric vendor value of `0` is accepted as real vendor truth;
  - null cover values from non-capable vendors fall through to manual or forecast paths.
- Update the proxy full settings upsert so manual cover entries are merged per business date and service period, with incoming slots winning only for the slots included in that request.
- Prefix operator Data Accuracy idempotency keys with the resolved operator and location before writing to the shared idempotency table.
- Update the contract language to match current storage: per-period source rows live in the keyed table; manual cover entries still live in `data_accuracy_settings`.
- Add focused tests for zero-cover truth, non-capable POS fallback, SQL merge behavior, idempotency scoping, and migration shape.

## Guardrails

- Do not change Data Accuracy UI in this lane; UI service-period fixes are in a separate worker lane.
- Do not change Business Timing in this lane.
- Do not introduce a delete/tombstone behavior for manual cover slots; this lane only prevents stale overwrites.
- Keep migration lint and focused Dart tests green before opening the PR.

## Verification

- Run focused service integration tests for `canonical_fact_to_closed_shift_input`.
- Run focused proxy route/gateway tests for Data Accuracy writes.
- Run migration drift and cutoff lints because migration files change.
- Run targeted `dart analyze` for touched Dart files and tests.
- Run `git diff --check`.
