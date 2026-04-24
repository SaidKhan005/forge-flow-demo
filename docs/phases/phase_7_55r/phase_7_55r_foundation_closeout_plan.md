# Phase 7.55r - Foundation Closeout

Updated: 2026-04-24
Status: In Progress
Owner: Foundation closeout lane

## Decisions Locked (2026-04-23 review)

- **Scope is bounded to the 5 verified-open orphan items.** Phase 7.55r
  is not a general "clean up every old seam" lane. It exists only to
  close the still-open foundation items verified by the orphan audit.

- **Sequencing: alongside or just before Phase 10.5.** The service-period
  runtime fixes are directly consumed by Phase 10.5. The other four items
  are independent correctness and hygiene closeout work. Phase 7.55r does
  not block Phase 8, Phase 9, or Phase 10a.

- **Persisted timing config is already the authority.** `businessDayStartLocalTime`,
  `weekStartDay`, `shiftCloseAuthority`, and `servicePeriodDefinitions`
  already persist on `RestaurantTimingConfig`. Phase 7.55r closes the
  remaining runtime callers that still behave as if demo definitions are
  the source of truth.

- **Retire fixture-era daypart helpers where runtime timing truth takes over.**
  Once the verified orphan callers migrate to persisted service-period
  definitions, `WeekDayOrder.daypartsFor(...)` should no longer stay
  load-bearing in those shared runtime paths.

- **UTC metadata normalization is a consistency lane, not an architecture
  rewrite.** Standard for this phase: timestamps written to repository,
  audit, and metadata columns should be created with
  `DateTime.now().toUtc()` before persistence or serialization.

- **DataAlignmentAuditPanel stays dev-only.** The change here is boundary
  hygiene: add a thin read service in front of the panel so the widget no
  longer imports SQLite repositories directly.

- **Non-locked WTD week membership is an audit pass first.** Phase 7.55r
  verifies that the read sites touching `weekId` honor restaurant-configured
  `weekStartDay`. It should only patch real hardcoded fallbacks, not reopen
  locked weekly-plan authority.

## Decisions Locked (2026-04-24 review — scope expansion)

- **Audit panel scope expanded: item 4 now includes cross-section drift
  detection.** The dev-only `DataAlignmentAuditPanel` cleanup grows from
  pure boundary hygiene to also include regression-detection flags for
  the q-lane conformance contracts. Tier 1 (boundary hygiene) and Tier 2
  (drift flags) ship together as one combined slice.

- **Audit panel scope also includes cycle/week provenance visibility.**
  The panel should expose the specific locked-week and target-cycle
  linkage behind the current read path so a developer can answer
  "which week / which cycle produced this screen?" without dropping to
  SQLite inspection.

- **Rationale for the expansion.** The drift detector is a safety net
  for the refactoring slices that follow (items 1 & 2 retire
  `demoDefinitions` callers and `WeekDayOrder.daypartsFor(...)`; item 5
  audits the `weekId` touch sites). Landing it first catches any
  accidental re-introduction of per-surface authority derivation while
  those touches happen. This is feature work beyond strict orphan
  closeout, but sized to ship inside one slice and explicitly paired
  with the refactor risk it mitigates.

- **Execution order: the audit panel lands as one combined diagnostic
  slice.** Tier 1 (boundary hygiene), Tier 2 (drift flags), and
  provenance visibility land before the service-period runtime wiring
  changes, so the detector and provenance readout are active when those
  surfaces change.

- **UTC metadata normalization item closed (2026-04-24) — scope by
  design, not partial delivery.** Two `createdAt` callsites migrated
  (`lib/data/target_cycle_service.dart:379`,
  `lib/data/learn_benchmark_context_service.dart:218`). These are the
  **full** in-scope set. The helper's declared scope is exactly the
  four audit-metadata families (`createdAt` / `updatedAt` /
  `generatedAt` / `lockedAt`), and no other callsites in `lib/`
  currently produce fields in those families via raw
  `DateTime.now().toUtc()`.

  The remaining 8 raw `DateTime.now().toUtc()` callsites all sit on
  the excluded side of the helper's docstring boundary:

  - **Event-family stamps** (`managerOverrideAt`, `adminReplacedAt`
    in `target_cycle_service.dart`; `deactivated_at` in
    `target_cycle_dao.dart`) — semantically `lastEventAt`-family,
    which the helper's docstring explicitly excludes.
  - **Computation stamps** (`builtAt` in
    `target_cycle_active_target_profile_projector.dart`) — literally
    named in the helper's exclusion list.
  - **DateTime-typed passes** (`evaluatedAt` and `now` in
    `shift_dashboard_notifier.dart`; local `nowUtc` in
    `target_cycle_service.dart`) — return `DateTime` objects, not
    ISO strings. Type-incompatible with the helper and used for
    comparison/arithmetic, not as audit metadata stamps.

  The earlier "23 calls across 14 files" framing in this phase doc
  came from a broad `DateTime.now()` grep that counted duration math,
  test fixtures, and device-clock passes that are not audit metadata
  at all. That framing overstated the scope; the helper-bounded scope
  is what item 3 actually owns, and it is now landed.

  A future refactoring phase could introduce a companion helper
  (e.g. `nowIsoUtcLifecycleEvent()`) if a concrete need emerges —
  but refactoring today would be cosmetic: output is byte-for-byte
  identical to the raw pattern, and callsite variable names already
  carry the semantic distinction. No current reason to act.

- **Item 5 non-locked WTD audit — findings (2026-04-24).** Audit
  completed. Key findings:
  - `ShiftService.getWeekToDate(weekId, weekLabel)` (non-locked path)
    has **zero production callers**. Production goes through
    `LiveShiftDataSource.getWeekToDate()` → `ShiftService.getLiveWeekToDate()`
    which is the locked-snapshot path already business-date-aware from
    `7.55n.4` / `7.55n.4a`. Three test callsites remain.
  - `WeeklyPlanSnapshotService._resolveWeekStartDay` already honors
    `config?.weekStartDay ?? DateTime.monday` — the honest fallback
    shape 7.55r's rule describes.
  - `sqlite_database.dart:825, 1567` hardcode `DateTime.monday` only as
    SQLite schema defaults when no timing config is persisted.
    Downstream readers consult persisted config first; the SQL default
    is honest-fallback-adjacent, not a "real hardcoded fallback where
    non-empty timing config already exists".
  - `app_data_status_service.dart` uses ISO weekId for freshness-state
    evaluation; correct for that concern, not a business-week concern.
  - `mock_integration_replay_seed._weekIdFromDate` produces ISO
    Monday-anchored weekIds at seed time — acceptable for the demo and
    properly reassigned to adapter-layer work (Phase 8 / 8R) for real
    restaurants. Not a 7.55r patch target.
  - **Conclusion:** no patch targets in the repo today. The rule
    "patch only real hardcoded fallbacks where non-empty timing config
    already exists" matches zero surfaces. Item 5 closes as an
    audit-delivered finding. The non-locked WTD path remains as a
    documented legacy test helper; production runtime correctness is
    owned by the already-landed locked path.

## Goal

Close the remaining foundation orphans that are still genuinely open in
code after the tracker-authority and orphan-audit passes, so the timing,
metadata, audit-panel, and week-membership seams stop lagging behind the
otherwise-landed 7.55 foundation.

## Scope

Phase 7.55r owns:

- **Service-period definitions runtime wiring**
  - replace the verified orphan-audit runtime callers that still read
    `ServicePeriodDefinitionResolver.demoDefinitions`
  - current verified shared runtime callers:
    - `lib/screens/schedule_builder.dart`
    - `lib/data/legacy_fixture_data.dart`
    - `lib/services/variance_week_projection_read_service.dart`
  - read persisted `RestaurantTimingConfig.servicePeriodDefinitions`
    instead

- **Retire `WeekDayOrder.daypartsFor(...)`** after those shared runtime
  callers migrate off fixture-era daypart ordering

- **UTC metadata timestamp normalization (landed 2026-04-24)**
  - Normalize the four audit-metadata families
    (`createdAt` / `updatedAt` / `generatedAt` / `lockedAt`) onto the
    `nowIsoUtc()` helper in
    `lib/domain/services/utc_metadata_timestamp.dart`.
  - 2 in-scope callsites migrated:
    - `lib/data/target_cycle_service.dart:379` — `createdAt` on cycle write
    - `lib/data/learn_benchmark_context_service.dart:218` — `createdAt`
      on selection summary write
  - Event-family and computation-family timestamps
    (`managerOverrideAt`, `adminReplacedAt`, `builtAt`, `deactivated_at`,
    `evaluatedAt`, local `nowUtc` for comparison) stay as raw inline
    patterns by design — see the helper's docstring for the semantic
    boundary and the 2026-04-24 Decisions Locked section above for the
    full rationale.

- **Dev-only `DataAlignmentAuditPanel` boundary cleanup + drift detection**
  - Tier 1 — boundary hygiene:
    - add a thin dev-only read service such as
      `DataAlignmentAuditReadService`
    - stop importing SQLite repositories directly inside the widget
  - Tier 2 — cross-section drift detection (safety net for the
    service-period wiring refactor in items 1 & 2 and the WTD audit in
    item 5):
    - extend the read service to expose "drift checks" that compare
      conceptually-one metrics across authority surfaces — e.g. Shift
      `targetCPLH` vs `ActiveTargetProfile.targetCPLH`, Variance WTD
      `theoreticalBlendedWage` vs `ActiveTargetProfile.targetBlendedWage`
    - render green / red drift-flag badges on the audit panel for each
      drift-check pair
    - flag the cases where values should be equal per q-lane conformance
      Rules 2 and 3 but disagree — functioning as a live regression
      detector for the q-lane contracts the refactor work touches
    - remain value-comparison only; provenance-tagged drift (right
      number, wrong pathway) is out of scope for this slice
  - Tier 3 â€” cycle/week provenance visibility:
    - surface the current locked-week identity the panel is reading from
      (week key/label plus snapshot timing when available)
    - surface the target-cycle linkage behind that locked week
      (`targetCycleId`, effective/calibration timing when available)
    - keep this diagnostic-only; it should explain the read path, not
      introduce a second authority seam

- **Non-locked WTD business-date membership audit**
  - inspect the 30 files that touch `weekId`
  - confirm they honor restaurant-configured `weekStartDay`
  - remove hardcoded Monday fallbacks where non-empty timing config
    already exists

Adjacent work that plugs in:

- `Phase 10.5` daypart-aware Shift consumes the service-period-definition
  runtime fixes
- future timing edit flows from `Phase 10a` should land against the
  cleaned runtime seam, not the demo-definition seam

## Scope Does Not Own

Phase 7.55r does not own:

- editable restaurant timing + service-period settings write path
  (`Phase 10a`)
- live daypart Shift behavior, primary-driver teaching, or daypart UI
  (`Phase 10.5`)
- POS / Labor / Reservation transport (`Phase 8` / `8R`)
- auth, roles, permission enforcement, or session work (`Phase 9`)
- broad demo-fixture retirement outside the 5 verified orphan items
- legal / compliance work (`Phase 9.8`)

## Runtime Contract

```text
persisted restaurant_timing_config
-> service-period definition resolver
-> Schedule / Variance / shared runtime readers
-> one restaurant-scoped service-period truth

repository / audit / metadata writes
-> UTC-normalized timestamp creation
-> persisted metadata columns
-> consistent provenance across devices and environments

dev-only audit panel
-> DataAlignmentAuditReadService
-> canonical read models / repositories
-> widget renders diagnostics without importing SQLite repos directly
-> drift-check pairs (metrics that should be equal across surfaces)
-> green / red badges surface architecture-rule drift during dev
-> cycle/week provenance rows show which locked week / target cycle the
   panel is actually inspecting
```

## Dependencies

Required before Phase 7.55r can ship real:

- `7.55n` timing persistence foundation is already landed
- orphan-audit findings verified these items are still open in `lib/`
- `Phase 10.5` remains the first adjacent phase that materially consumes
  the service-period-definition runtime cleanup

Phase 7.55r does not wait on:

- `Phase 8`
- `Phase 9`
- `Phase 10a`

## Non-Negotiables

- do not invent a second service-period authority path alongside
  persisted `RestaurantTimingConfig`
- do not leave `WeekDayOrder.daypartsFor(...)` load-bearing once
  runtime service-period definitions are wired
- UTC normalization applies to persisted metadata / audit timestamps,
  not selectively by file
- keep `DataAlignmentAuditPanel` dev-only (drift badges are
  diagnostic-only; they must not block production render paths or
  escalate to user-visible warnings)
- provenance rows are diagnostic-only too; they explain the current
  read path and must not become a second authority surface
- treat week-membership fixes as correctness work, not permission to
  reopen locked weekly-plan authority

## Adjacent Phases

- `7.55o` remains the active extraction lane; `7.55r` is bounded
  foundation closeout
- `Phase 10a` later owns editable timing and service-period write paths
- `Phase 10.5` consumes the cleaned service-period runtime seam
- `Phase 8` / `8R` feed canonical facts, but not service-period
  authority

## Source Material

- [phase_7_55_time_boundary_contract.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/contracts/phase_7_55_time_boundary_contract.md)
- [phase_10_5_shift_daypart_service_period_view_and_primary_driver.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_10_5/phase_10_5_shift_daypart_service_period_view_and_primary_driver.md)
- [status_ledger_post_7_55p_deep_check.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/internal/status_ledger_post_7_55p_deep_check.md)
- [schedule_builder.dart](C:/Git%20Local%20Repos/forge_flow_demo/lib/screens/schedule_builder.dart)
- [legacy_fixture_data.dart](C:/Git%20Local%20Repos/forge_flow_demo/lib/data/legacy_fixture_data.dart)
- [variance_week_projection_read_service.dart](C:/Git%20Local%20Repos/forge_flow_demo/lib/services/variance_week_projection_read_service.dart)
- [data_alignment_audit_panel.dart](C:/Git%20Local%20Repos/forge_flow_demo/lib/widgets/data_alignment_audit_panel.dart)
