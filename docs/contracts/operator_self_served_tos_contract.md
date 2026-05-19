# Operator-Self-Served T&Cs Contract

Updated: 2026-05-18
Authority order: see `CLAUDE.md`. This contract sits in Tier 3 (other Tier-2 contracts).

## Statement

Forge & Flow ships with operator-authored T&C content seeded into
`tos_versions` at deploy time. There is no external legal-review gate
for V1 launch; the operator is the founder and authors / accepts the
terms themselves. Acceptance is recorded in `tos_acceptances` with
`version_id` (FK to `tos_versions`), `scope`, `operator_id`,
`user_id`, `ip_address`, `user_agent`, and `accepted_at` per the
Phase 9.8 schema (`db/migrations/202605040100_phase_9_8_tos_versions.sql`).

## Current implementation

The legal intent (operator-authored terms, append-only acceptance
record, supersede-then-re-accept) is unchanged. The implementation as
it exists in the tree today is the Postgres schema half only; the
click-through UI seam is not currently present in app code.

What persists ToS state today:

- `tos_versions` and `tos_acceptances` Postgres tables, created by
  `db/migrations/202605040100_phase_9_8_tos_versions.sql`.
  `tos_versions` (`202605040100_phase_9_8_tos_versions.sql:75-95`)
  holds the scope-partitioned, append-only versioned legal text;
  `tos_acceptances`
  (`202605040100_phase_9_8_tos_versions.sql:140-158`) is the
  append-only acceptance log keyed by
  `(operator_id, user_id, version_id)` with `scope`, `ip_address`,
  `user_agent`, and `accepted_at`, under wrapper-only per-tenant RLS
  (`:198-207`) and INSERT/SELECT-only grants
  (`:227-231`, UPDATE/DELETE revoked).
- The legacy Phase 9.0 auth-foundation `public.tncs_acceptances`
  table (text version string only) remains in place
  (`db/migrations/202604250008_auth_schema_foundation.sql`); the
  Phase 9.8 schema is the richer scope + `version_id` model. The two
  are not yet reconciled (see the migration header,
  `202605040100_phase_9_8_tos_versions.sql:23-28`).
- The Phase 9.8 inbound-vendor T&Cs draft body
  (`docs/phases/phase_9_8/phase_9_8_inbound_vendor_tcs_draft.md`)
  is the operator-authored copy that ships into `tos_versions` for
  V1.

### Gap: clickwrap UI not implemented in app code

The Phase 9.8 migration header describes the schema as a write target
for a click-through screen, and an earlier revision of this contract
named `lib/operator_web/screens/tos_accept_screen.dart`, an
`OperatorWebAcceptingTos` state in
`lib/operator_web/auth/operator_web_auth_source.dart`, and
`tos_acceptance` references in
`lib/operator_web/screens/my_account_screen.dart` as the surviving
seams. None of those seams exist in the tree today:

- No `tos_accept_screen.dart` (or any `*tos*accept*` file) exists
  anywhere under `lib/`.
- `lib/operator_web/auth/operator_web_auth_source.dart` exists but
  carries no `OperatorWebAcceptingTos` state; its only ToS mentions
  are narrative comments describing onboarding flow steps
  (`operator_web_auth_source.dart:14`, `:315`).
- `lib/operator_web/screens/my_account_screen.dart` exists but
  contains no `tos_acceptance` reference.
- The only live ToS code in `lib/` is the "Terms of Service updated"
  notification template
  (`lib/screens/notifications_screen.dart`,
  `tos_version_updated_notice`), which informs the operator a new
  version exists; it does not capture acceptance.
- No proxy or server-side ToS-acceptance write path exists under
  `tool/`.

So no operator-facing clickwrap screen, re-acceptance gate, or
server/proxy acceptance write currently writes to `tos_acceptances`.
This is a pending implementation gap, not a removal of legal
requirement: the schema write target is in place, but the UI and
write path that record acceptance against it remain to be built (the
Phase 9.8 migration header itself notes the screen and the versioning
admin UI as later slices). Treat the click-through, re-acceptance
gate, and acceptance write as outstanding work, not as shipped
infrastructure.

## What is removed

The "needs lawyer signoff" / "blocked on counsel" / "escalate to
counsel" gates that previously blocked `cutover.2` and the V1 launch
punchlist. Those are dropped: the operator/founder authors and
accepts the terms themselves; no external legal-review step gates V1.

## Re-acceptance (intended design)

Re-acceptance follows the Phase 9.8 schema design: when a new version
supersedes the active one (`tos_versions.superseded_by_version_id`
points forward), the intended behaviour is that the next-session
re-acceptance gate fires the standard clickwrap and a new
`tos_acceptances` row is written; authoring of new versions follows
the same operator-self-served pattern. The append-only
`tos_acceptances` shape supports this (corrections land as a fresh
row, never a mutation). Per the "Gap" note above, the screen and
re-acceptance gate that drive this flow are not yet implemented in
app code; the schema supports it but the write path is outstanding.

## Cross-references

- `docs/phases/phase_9_8/phase_9_8_inbound_vendor_tcs_draft.md` —
  operator-authored body copy + click-through flow shape.
- `docs/phases/phase_9_8/phase_9_8_compliance_and_legal_plan.md` —
  parent compliance plan; processor-chain and DPA scope.
- `db/migrations/202605040100_phase_9_8_tos_versions.sql` — schema.
- `docs/archive/_execution/2026-05-05_v1_launch_punchlist.md` — V1 launch
  punchlist; the seeding task is what unblocks `cutover.2`.
- `docs/archive/_execution/2026-05-06_v1_operator_punchlist_execution.md` —
  operator-side punchlist; the seeding task is the operator-side
  prerequisite for first-operator onboarding.
