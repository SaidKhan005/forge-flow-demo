# Post-Codex Wave Decision Lock — 2026-05-12

Status: LOCKED by user approval.

Scope: governs the wave of work that follows the current Codex `admin_hierarchy_ux_cleanup` 10-slice push (Slices 0/1/6/8 merged; 2/3/4/5/7/9/10 in-flight). These decisions bind every plan doc, contract doc, and prompt produced for the next wave.

Read this doc before:

- Drafting any post-Codex execution slice plan under `docs/_execution/`.
- Spawning any research, lens-audit, or code-health agent for the next wave.
- Writing any prompt for a Codex or Claude worktree assigned to the next wave.

Authority position: this doc sits at Authority Order #3 alongside other Tier-2 contract material for any prompt that targets the post-Codex wave. The 8 locks below override earlier provisional guidance in the dump and in CLAUDE.md memory only for the next-wave scope; existing landed phases keep their own decision locks.

## Lock Table

| # | Topic | Locked Decision | Why |
|---|---|---|---|
| 1 | Hierarchy + inheritance rule | **Universal with documented carve-outs.** Default behavior across every settings, action, label, badge, log, and notification surface is hierarchy-scoped with full business → org-unit → location inheritance and lowest-configured-scope-wins. An item may be carved out (e.g. integrations are location-only because vendor connections bind to a specific restaurant account) only if (a) the carve-out is written into the relevant contract doc, and (b) the UI shows the operator why this surface is not hierarchy-scoped. | Preserves the HP #11 product rule and the existing integrations carve-out without leaving the door open for silent exceptions. |
| 2 | Default Roles authority + operator editability | **F&F admins edit the Default Role catalog from the admin console; edits propagate globally to every existing and future business. Default Roles are read-only inside operator businesses. Operators who want changes build a Custom Role; the Default Role catalog acts as a template library (operator-owner, operator-manager, etc.).** The ability to edit Default Roles is itself a permission key, held only by F&F admin tier. | Single source of truth for Default Roles. Avoids per-business fork drift. Custom Roles remain the operator's own surface. |
| 3 | Role key + rename behavior | **Hybrid identifier model.** Every role carries an immutable UUID (`role_<uuid>`) that is the only reference used by code, permission grants, audit log rows, ReBAC tuples, and external integrations. The display slug derived from the role name is presentation-only and may change freely on rename without migration. The role name is also user-supplied display copy; no UX prompt ever asks the operator for a role key. | Engineering safety: rename is cheap, audit history stays consistent, integrations don't break. Operator mental model stays clean — they only see the name. |
| 4 | Role taxonomy: products | **Two-product structure from day one.** Permissions are grouped by `Forge & Flow` and `Barrio` as sibling products in the role editor and the permission category tree. Barrio's permissions sit dormant in the catalog (no UI surfaces yet, AI-paused phases unchanged). Schema, editor, and seeded-role layout are shaped for both products now to avoid migration later. | Avoids a re-architecture when Barrio unpauses. Keeps the seam visible to F&F admins while operators see only the products their plan exposes. |
| 5 | Mobile → Ops Web deep-link handoff | **Reuse the mobile JWT in the deep link.** Mobile buttons (Manage Timing on Ops Web · Manage Wage on Ops Web · Manage Account on Ops Web) pass the existing mobile session token to the browser via deep link; browser opens already-signed-in and lands on the deep-link target. Guardrails written into the JWT-handoff contract: HTTPS-only, no iframe embedding, fresh-MFA step-up required on sensitive deep-link targets (account edits, MFA enroll, role mutations). No new handoff-ticket endpoint. | Operator wanted simplicity. The fresh-MFA gate on sensitive targets limits blast radius on a compromised link. |
| 6 | Mobile "Demo → Live" switch | **One master switch on the mobile Integrations tab, granular underneath.** UX shows a single operator-level switch. Under the hood the switch flips every `demo_mode_state` row for the current (operator, location, category) triples. The auto-flip-on-first-backfill behavior stays as the safety net for connected vendors — the master switch does not disable it. | Preserves the per-(operator, location, category) schema from HP #2 + the demo-mode contract. Single-button UX hides the granularity from the operator. |
| 7 | Sign-in Security route | **301 redirect to My Account.** `/operator-web/sign-in-security` (and any admin equivalent) returns a permanent redirect to the matching section of My Account. Existing email links, push notification deep-links, and operator bookmarks keep working. Email/notification copy may be migrated to the new URL on a follow-up sweep, not a blocker. | Cleanest deletion path that doesn't break inbound links. |
| 8 | Audit log hierarchy filter | **Read-side join only.** Audit log queries that filter by business / org-unit / location join `audit_logs → locations → org_units` at read time. Stored audit rows are not modified. Hash chain anchoring and `pg_partman` per-operator/day partitioning stay untouched. New audit row writes also do not gain hierarchy columns. | Hash chain integrity is non-negotiable. Read-time join performance is acceptable given audit-log query frequency. Re-opens only if filter latency becomes a real problem. |

## Carve-outs and Follow-ups

- **Carve-out for #1 — Integrations are location-only.** Already documented in HP #11 and the demo-mode contract. The hierarchy presentation contract (new doc) lists this as the canonical example carve-out. Every other not-hierarchy-scoped item must be added to that contract before shipping.
- **Carve-out for #5 — Sensitive deep-link targets.** The JWT-handoff contract enumerates the list of "sensitive" targets that require fresh-MFA step-up after redemption (account edits, MFA enroll, role mutations, billing). Non-sensitive targets (view-only timing, view-only wage) open without step-up.
- **Follow-up for #7 — Email copy sweep.** Email templates currently pointing at `/sign-in-security` keep working via the redirect. Sweeping them to the new My Account URL is queued as a low-priority cleanup, not a blocker.
- **Follow-up for #8 — Re-open if hierarchy filter latency on audit logs exceeds the proxy SLO at scale.** Trigger condition: a single audit-log filter query for an operator with >100 locations takes >2× the equivalent location-only query. Mitigation if triggered: denormalize `org_unit_id` + `business_id` onto new audit rows going forward (option (b) from the original decision), with no backfill.

## Open product decisions surfaced but not in this lock

These are real decisions the user dump raised, but they belong to subsequent waves and were not locked here:

- Exact Default Role catalog membership (which roles ship as defaults, what permissions each carries) — to be decided after the roles audit (Wave B2) runs.
- Whether the editable vendor-applicability lists for wage / covers / polling live in one shared schema or three separate ones — pending the data-model audit (Wave A4).
- The exact list of "sensitive" deep-link targets requiring fresh-MFA — pending the JWT-handoff contract draft (Wave B11).
- The full schema versioning + migration system shape — pending Wave A5.

## Change log

| Date | Change |
|---|---|
| 2026-05-12 | Initial lock of 8 decisions from inline Q&A. |
