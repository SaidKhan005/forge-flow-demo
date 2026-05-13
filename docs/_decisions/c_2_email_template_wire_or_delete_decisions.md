# C-2 — Email template wire-or-delete decision matrix

Created 2026-05-13 for the operator-approval pass on C-2 (`docs/_indices/WAVE_EXECUTION_LEDGER.md` row 84).
C-1 (PR #611) just merged, so the inbound SendGrid event webhook now exists and
Postgres-enforced dedupe per `email_event.provider_event_id` is live. C-2 is the
operator-led pass that closes each of the 7 wire-or-delete drafts named in
`docs/_execution/lane_c_parity/03_execution_slices.md` C-2.

## Slice spec source

`docs/_execution/lane_c_parity/03_execution_slices.md` C-2 (lines 30-51) lists
7 drafts (A through G) and asks for one operator-approved PR cluster.

## Authority order honored

1. The active C-2 prompt + slice spec.
2. `CLAUDE.md` Hard Promises (#1 transport-swap, #2 demo-mode, #7 F&F holds
   keys, #11 hierarchy-scoped settings — none of which a wire here violates).
3. `docs/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md` B4 (defers
   invite dual-path) + C3 (wire-or-delete is its own lane).
4. `project_v1_lean_cut_2_2026_05_03.md` round 2 ("3-strike auto-disable email
   wiring" listed as explicit V1 non-goal).

## Decision matrix (operator chooses per-draft)

C-2 ships the decision matrix + renderer doc-string updates only. Wiring
each draft requires substantive architecture decisions that the operator
should make explicitly rather than have the worker bake in defaults. The
following table summarizes the per-draft analysis; each row has a worker
recommendation that the operator may accept, override, or split.

| Draft | Template id | C-2 worker recommendation | Operator action |
|---|---|---|---|
| A | `operator_admin_invite.md` (was) + `operator_invite_first_admin.md` | **Already resolved.** A2.2 (PR #540, merged 2026-05-13) deleted `operator_admin_invite.md` + its id entry. `operator_invite_first_admin.md` is PRESERVED as the admin SendGrid test-connection fixture (`tool/advisor_proxy/admin_email_routes.dart`). Production invite path is Firebase action-link per addendum B4 path 1. | None — confirm A2.2 closure. |
| B | (alternative to A) Wire SendGrid invite emails | **DEFER.** Addendum B4 explicitly defers the dual invite path decision to the code-health wave when invite flows get a holistic audit. Reversing the Firebase invite path is auth-critical, multi-flow, and out of C-2 scope. | Acknowledge B4 deferral; revisit during invite-flow code-health pass. |
| C | `mfa_factor_changed_notice` | **DEFER wire.** No clear server-side "MFA factor changed" emission site exists. MFA enrollment is client-side (`lib/services/mfa/mfa_enrollment_service.dart`); MFA removal already emits to `event_outbox` topic `auth.user.mfa_factor_removed` and the in-app inbox via `AppNotificationService.emitMfaAuthenticatorRemoved`. Wiring an email here means (a) deciding whether email duplicates the existing inbox emit, (b) adding a server-side recipient-email resolver (the worker holds `userId`, not the user's email), and (c) constructing a new catalog entry (`notif.mfa.factor_changed`) so the fanout's role-gate machinery accepts it. ~250-500 LoC. | Pick: (1) wire from MFA removal worker only (skip enrollment until server-side enrollment hook exists), (2) wire from both enrollment + removal (requires new enrollment hook), or (3) delete and rely on the existing inbox emit + Firebase suspicious-sign-in template as the security-event signal. |
| D | `vendor_sync_error_alert` | **DEFER wire.** No production "sustained sync failure" aggregator exists. The polling tier emits per-tick `connector_sync_log` rows but does not detect "first failure of a new outage" — wiring a per-row email would spam on every transient hiccup. The OAuth refresh worker covers the auto-disable cap path (Draft F's territory). Wiring this requires a new aggregator + outage-window detector (~400-700 LoC + a new state table OR window-function query on `connector_sync_log`). | Pick: (1) build a new "first-failure-of-outage" detector + email, (2) delete and rely on the existing `error` chip on the Connected services card, or (3) defer until post-launch when sync-error volume justifies the aggregator. |
| E | `vendor_webhook_signature_alert` | **DEFER wire.** Webhook signature verification is distributed across 20+ per-vendor verifier files under `lib/integrations/{pos,reservation,labor}/*_webhook_signature_verifier.dart` with no centralized aggregator. The template hardcodes `{{failedSignatureCount}}` + `{{rateLimitWindowHumanReadable}}` so wiring requires (a) a per-`(operator, vendor)` failed-signature counter (new state table OR Redis/memory ring buffer), (b) a rate-limit window check, and (c) an aggregator service that walks the counter. ~500-800 LoC + new state surface. | Pick: (1) build the centralized verifier + counter + email, (2) delete and rely on signature-verifier unit tests + Cloud Logging alerts as the operational signal, or (3) defer until post-launch when adversarial webhook activity is observed. |
| F | `vendor_connection_auto_disabled` | **DEFER wire — RECOMMEND ship soon.** Phase 8 lean cut 2 explicitly deferred this. The trigger site IS clean (`tool/oauth_refresh_worker/main.dart:1196` + `:1226` both call `gateway.autoDisableConnection`) and well-bounded for a single fanout-hook insertion. BUT the worker is a Cloud Run binary with no current `NotificationEventFanout` dependency wired in its `WorkerRuntime` bootstrap. Wiring email here requires either (a) constructing a full fanout instance + recipient-resolution path in the worker (~600 LoC), or (b) a direct-enqueue path through `EmailOutboxEnqueueRepository` + a new `OperatorAdminEmailLookup` seam (parallel to `VendorLifecycleNotificationDispatcher`'s pattern, ~400 LoC). | Pick: (1) ship Path (a) — full fanout integration (preferred long-term, parallels backfill + audit-anchor wiring), (2) ship Path (b) — direct-enqueue mirror of vendor-lifecycle dispatcher (faster, narrower blast radius), or (3) keep V1 lean-cut deferral (operator sees `error` chip on admin Connected services card; revisit post-launch when alert volume justifies). |
| G | `tos_version_updated_notice` | **DEFER wire.** No production INSERT path into `public.tos_versions` exists in the codebase today. The runtime acceptance gate (`lib/operator_web/screens/tos_accept_screen.dart`) READS `tos_versions` but never WRITES. The schema migration ships the table with no seed data. `docs/contracts/operator_self_served_tos_contract.md` defers the publish workflow. Wiring email requires the publish workflow to exist FIRST — until then there is no trigger site to hook. | Pick: (1) defer until publish workflow ships (most likely correct), or (2) delete the template now and add it back when the publish slice lands. |

## What C-2 (this PR) actually ships

1. **Doc-string updates** on `lib/services/email/email_template_renderer.dart`: every TEMPLATE-ONLY id (`mfaFactorChangedNotice`, `vendorSyncErrorAlert`, `vendorWebhookSignatureAlert`, `vendorConnectionAutoDisabled`, `tosVersionUpdatedNotice`) now carries a per-id "wire deferred per C-2" doc string citing this decision doc + the specific architecture decision the operator owes. `operatorInviteFirstAdmin` also gains a doc string documenting its admin-test-fixture status (the previous doc string was missing).
2. **This decision matrix** at `docs/_decisions/c_2_email_template_wire_or_delete_decisions.md` so the operator can read once and pick per-draft.

## What C-2 (this PR) does NOT ship

C-2 ships zero production wiring. The worker contract for this slice
(operator-approval-required gate, medium-risk, 50-200 LoC per template
budget) was bounded to "produce the draft PRs for each decision so the
operator only has to approve." The honest finding from the discovery pass
is that each wire-draft (C, D, E, F, G) requires the operator to make an
architectural decision FIRST (which seam, which detector, whether to
build the prerequisite trigger site) — the worker default of "wire from
the matching emitter" assumed the emitter exists with a stable hook
surface, which is not the case for any of C, D, E, G and is only
partially true for F.

Shipping speculative wires per draft would mean each follow-up PR has to
choose between (i) honoring the speculative wire (locking the operator
into a default they may not want) or (ii) reverting the speculative wire
to ship the operator's preferred architecture. Neither path serves the
operator. The decision-matrix-first approach lets the operator pick once
and then the wire PR follows the chosen architecture verbatim.

## Why this is consistent with the worker contract

The C-2 worker brief (Block 3) says: "If after reading the actual emitter
code you decide a different default than 'wire' is better for any of
C-G (e.g. emitter requires a fundamental architectural decision the
operator should make), STOP for that draft and disclose. Ship the drafts
you CAN confidently land; the others can come in a follow-up." Five
drafts (C, D, E, F, G) hit that stop-and-disclose criterion; Drafts A
and B are already resolved (A by the A2.2 merge; B by the addendum B4
deferral). The decision matrix is the disclosure shipped per that
contract clause.

## Follow-up sequencing

After operator picks per-draft:

- **Draft C wire**: 1 PR to add `notif.mfa.factor_changed` catalog entry +
  hook helper + trigger-site call in `lib/services/mfa/mfa_removal_worker.dart`
  (and `mfa_enrollment_service.dart` if enrollment-side wire is picked).
  Risk: medium (auth-adjacent). ~250-500 LoC.
- **Draft D wire**: 1 PR to add the first-failure-of-outage detector
  (likely a new `vendor_sync_outage_state` table or a CTE on
  `connector_sync_log`) + hook + trigger from the polling tier. Risk:
  medium (new state surface). ~400-700 LoC.
- **Draft E wire**: 1 PR to add the per-vendor failed-signature counter +
  aggregator + email. Risk: medium-high (touches all 20+ verifier files).
  ~500-800 LoC. Operator may prefer to defer pending observed adversarial
  webhook activity.
- **Draft F wire** (preferred Path (a) or Path (b)): 1 PR adding the
  fanout dependency or direct-enqueue seam to the OAuth refresh worker.
  Risk: medium (Cloud Run worker bootstrap touch). ~400-600 LoC.
- **Draft G wire**: blocked on the TOS publish workflow shipping. Filed
  as a future slice — track alongside the publish workflow.

## Companion artifacts

- `lib/services/email/email_template_renderer.dart` — doc-string updates
  per id citing this doc.
- `docs/_audits/code_health/c_email_notification_scenario_inventory.md`
  remains the authoritative inventory and is consistent with this
  matrix (template-only flags match).

## Non-goals (explicit)

- C-2 does NOT modify the `EmailTemplateIds.all` list. Every template
  file under `tool/advisor_proxy/email_templates/` remains on disk and
  passes the renderer suite (every template renders with sample data).
- C-2 does NOT touch `advisor_proxy.dart` (the monolith; bleed-stop at
  19,900 ceiling).
- C-2 does NOT touch `lib/auth/permission_keys.dart` (frozen).
- C-2 does NOT add any migration.
- C-2 does NOT write any `audit_logs UPDATE` rows.

---

## Operator picks — 2026-05-13

Operator picked from the matrix in the format "keep 2fa, pos connection
and vendor connection only" (after the C-2 matrix landed via PR #617).
Translated to per-draft picks:

| Draft | Email | Operator pick | Follow-up slice |
|---|---|---|---|
| **C** | `mfa_factor_changed_notice` (2FA) | **WIRE** | `C-2-C` — worker picks sub-path (wire from removal only vs. wire from both + enrollment hook) at spawn time. |
| **D** | `vendor_sync_error_alert` (POS connection failing) | **WIRE** | `C-2-D` — requires the first-failure-of-outage detector (per-row email would spam on transients); no other sensible wire shape. |
| **E** | `vendor_webhook_signature_alert` | **DELETE** | `C-2-Del` (bundled with G) — delete template + renderer constant + matrix row. Rely on Cloud Logging alerts. |
| **F** | `vendor_connection_auto_disabled` | **WIRE** | `C-2-F` — worker pre-recommended **Path (b) ~400 LoC outbox enqueue** (lower scope than Path (a) ~600 LoC full fanout); confirm at spawn. |
| **G** | `tos_version_updated_notice` | **DELETE** | `C-2-Del` (bundled with E) — delete template + renderer constant + matrix row. Rely on in-app accept-screen gate. |

**Worker source for follow-ups:** parallel Claude lane session (or
operator may re-pick at spawn time). This orchestrator session **does
not spawn workers** for these follow-ups; we only record picks on
master.

**Plus orchestrator pre-approval** (operator's earlier "yes to all"):
**C-7a** prep migration approved — additive `ADD COLUMN IF NOT EXISTS
mfa_factors.recovery_codes_viewed_at timestamptz NULL` to unblock
Codex's C-7 ("Adaptive 2FA button") which is currently
data-contract-blocked. Mirrors the C-1a → C-1 pattern shipped earlier
2026-05-13. Pure additive expand; idempotent; no live data risk
("no business live yet" direction). New ledger row added.
