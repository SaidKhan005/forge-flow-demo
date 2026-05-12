# Operator-Self-Served T&Cs Contract

Updated: 2026-05-08
Authority order: see `CLAUDE.md`. This contract sits in Tier 3 (other Tier-2 contracts).

## Statement

Forge & Flow ships with operator-authored T&C content seeded into
`tos_versions` at deploy time. There is no external legal-review gate
for V1 launch; the operator is the founder and authors / accepts the
terms themselves. Acceptance is recorded in `tos_acceptances` with
`version_id` (FK to `tos_versions`), `scope`, `operator_id`,
`user_id`, `ip_address`, `user_agent`, and `accepted_at` per the
Phase 9.8 schema (`db/migrations/202605040100_phase_9_8_tos_versions.sql`).

## What stays

The clickwrap infrastructure is unchanged:

- `tos_versions` and `tos_acceptances` Postgres tables.
- `lib/operator_web/screens/tos_accept_screen.dart` — the
  click-through screen that renders the active version body and
  records acceptance.
- `OperatorWebAcceptingTos` state in
  `lib/operator_web/auth/operator_web_auth_source.dart`.
- The `tos_acceptance` references in
  `lib/operator_web/screens/my_account_screen.dart`.
- The Phase 9.8 inbound-vendor T&Cs draft body
  (`docs/phases/phase_9_8/phase_9_8_inbound_vendor_tcs_draft.md`)
  is the operator-authored copy that ships into `tos_versions` for
  V1.

## What is removed

The "needs lawyer signoff" / "blocked on counsel" / "escalate to
counsel" gates that previously blocked `cutover.2` and the V1 launch
punchlist. Those are dropped: the operator/founder authors and
accepts the terms themselves; no external legal-review step gates V1.

## Re-acceptance

Re-acceptance follows the existing Phase 9.8 design: when a new
version supersedes the active one, the next-session re-acceptance
gate fires the standard clickwrap, and a new `tos_acceptances` row is
written. Authoring of new versions follows the same operator-self-
served pattern.

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
