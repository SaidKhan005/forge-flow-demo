# Audit Log Architecture Contract

> Created 2026-05-14 as part of Wave 2 Phase 2 closeout (AL-1 decision).
> Owner: orchestrator. Authority: this doc plus the underlying migrations
> + writer helpers cited under "Authority anchors".

## Overview

Forge & Flow maintains **two parallel tamper-proof audit chains**:

1. **`audit_logs`** — customer-scoped action history. Every row is
   tagged with `operator_id` and (when relevant) `location_id`. RLS
   scopes reads to the operator who owns the row. This is the chain
   customers and their regulators care about.
2. **`auth_events_audit`** — F&F-internal platform action history. This
   is where F&F Super Admin actions, F&F Support actions, and the
   service-principal worker fleet write their own audit trail. RLS is
   not the gate here — the rows are scoped to F&F itself.

Each table runs its own independent hash chain. Every new row carries
a SHA-256 hash that links to the previous row in the same table, so
tampering with rows in either table breaks that table's chain and is
detectable on re-verification.

There is no single unified chain across both. That is a deliberate
choice (see "Why two chains, not one" below), not a missing slice.

## When to use which

| Event kind | Table | Rationale |
|---|---|---|
| Operator user signs in | `audit_logs` | Operator-scoped action — belongs to the customer's history |
| Location Manager edits a shift | `audit_logs` | Operator-scoped action |
| Operator user changes their own email or name | `audit_logs` | Operator-scoped action |
| Operator user enrolls or removes 2FA | `audit_logs` | Operator-scoped action |
| Operator admin invites a team member | `audit_logs` | Operator-scoped action |
| Operator admin grants or revokes a role | `audit_logs` | Operator-scoped action |
| Vendor connection state transition for an operator | `audit_logs` | Operator-scoped action |
| Benchmark override applied to a location | `audit_logs` | Operator-scoped action |
| F&F Super Admin publishes Default Role Catalog v2 | `auth_events_audit` | F&F-internal action (no single operator scope) |
| F&F Super Admin edits the vendor-applicability matrix | `auth_events_audit` | F&F-internal action |
| F&F Support captures a heap snapshot | `auth_events_audit` | F&F-internal action |
| F&F Support runs a soak-harness command | `auth_events_audit` | F&F-internal action |
| Default Role Catalog publish blast-radius fans out | `audit_logs` (per affected operator) | Each operator who inherits the catalog change gets a row in their own chain — that is the operator-facing audit |
| Service principal renews its credentials | `auth_events_audit` | F&F-internal service identity, not an operator action |
| Hash anchor failure observed by `audit_anchor` worker | `auth_events_audit` | F&F-internal observability |

The general rule: if a customer's regulator could ask "show me every
action that touched my data" and the answer should include the row,
write to `audit_logs`. Otherwise, write to `auth_events_audit`.

## Schema-level enforcement

- `audit_logs.operator_id` is `NOT NULL`. The constraint is enforced
  at the database level. Every row has an operator owner by
  construction.
- `auth_events_audit.operator_id` is nullable. F&F-internal events
  write `NULL`. Events that involve a specific operator (e.g., F&F
  Support acting on behalf of one operator) can still fill the column
  for traceability, but the constraint does not require it.

This means relaxing `audit_logs.operator_id` to nullable to support
"one unified chain" is not a small change. It requires:

- Rewriting the RLS policies that read this table (today they assume
  `operator_id IS NOT NULL`).
- Updating the `OperatorScopedRepository` calling code that reads
  `audit_logs`.
- Migrating existing F&F-internal events out of `auth_events_audit`
  into the unified table without breaking the existing hash chain.

Each of those is a Phase 5 deploy risk on its own.

## Hash chain mechanics

The hash-chained write helper lives in `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql`.
Each new row computes a SHA-256 over `(prev_row_hash, this_row_payload)`
using `pgcrypto`, and stores both `prev_hash` and `this_hash` columns.
A daily anchor process writes the running tip into Azure Blob so a
later tamper check has an external witness.

The `auth_events_audit` table uses an analogous helper. Both helpers
guarantee single-writer ordering via row-level locking + the
`ORDER BY id` read pattern when computing `prev_hash`.

The `tool/audit_anchor` worker is the production verifier. It walks
each chain on its own schedule and emits a `notif.event.unwired` style
warning when the running tip diverges from the stored chain.

## Why two chains, not one

We considered three alternatives during Wave 2 Q-1-FU-sink (the
`ProductionHeapSnapshotCaptureAuditSink` inventory pass) and the
Phase 2 AL-1 closeout sweep:

1. **Relax `audit_logs.operator_id` to nullable.** Lets F&F-internal
   events live in the same chain. Cost: RLS policy rewrites + repository
   plumbing + a non-trivial deploy migration. Risk concentrates in Phase
   5 where everything else also lands.
2. **Build a third table `audit_logs_internal`.** Cleaner naming but
   adds code without changing audit fidelity. The dual chain we already
   have already covers the F&F-internal case.
3. **Keep the dual chain as today.** Selected 2026-05-14. Zero schema
   risk. Customers and regulators get a complete, tamper-proof
   operator-scoped chain. F&F gets a complete, tamper-proof
   F&F-internal chain. Tampering with either is detectable on its
   own. The cost is small read-side work — admin UIs that want to
   show "everything" need to merge two tables.

The trade-off F&F accepts: an admin "search all audit history" view
needs to query two tables and stitch results in display order. That
cost is one query + one timestamp merge. The benefit is zero deploy
risk on a constraint that the RLS policies already depend on.

## When to revisit

Reopen this decision if any of the following becomes true:

- A compliance vendor or auditor requests a single unified hash chain
  across F&F-internal and customer events for regulatory reasons.
- The dual-table admin "search all audit history" view starts hitting
  performance problems severe enough that the merge cost is no longer
  acceptable.
- A Phase 5 migration genuinely needs to relax the
  `audit_logs.operator_id NOT NULL` constraint for an unrelated reason
  — at that point folding AL-1 in as a side effect becomes cheap.

If none of those happen, the dual chain stays.

## Authority anchors

- `db/migrations/202604280005_phase_9_0sigma_f_audit_logs.sql` —
  `audit_logs` schema plus the hash-chained write helper.
- `db/migrations/202604280014_phase_9_0sigma_h2_audit_privacy_role.sql` —
  `admin_audit_privacy` role plus the read-side policies that depend
  on `operator_id IS NOT NULL`.
- `tool/advisor_proxy/proxy_bootstrap.dart` — declarative wiring of
  `ProductionDefaultRoleCatalogAuditSink` (precedent for F&F-internal
  write) and `ProductionHeapSnapshotCaptureAuditSink` (added by Wave 2
  Q-1-FU PR #724).
- `lib/operator_web/screens/audit_log_screen.dart` — operator-facing
  audit log reader. Reads `audit_logs` only; renders the per-operator
  chain.
- `lib/admin/screens/audit_log_admin_screen.dart` — F&F admin audit log
  reader. Merges `audit_logs` + `auth_events_audit` for the
  "everything" view.
- `tool/audit_anchor/main.dart` — daily anchor + tamper verifier.
- `docs/contracts/audit_attribution_contract.md` — companion contract
  that codifies actor/actor_kind attribution rules across both chains.
