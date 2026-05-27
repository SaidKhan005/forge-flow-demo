# Deep Unrun-Lane Audit Report - 2026-05-27

Scope: second-pass audit across lanes that were not fully exhausted in the
first full-system pass. This report excludes the admin-console Knowledge Base
visual polish lane except where it affects shared advisor/runtime wiring.

Baseline:

- `origin/master` was at `ff416729` when this audit started.
- The audit plan is `docs/_audits/deep_unrun_lane_audit_2026_05_27_plan.md`.
- Read-only explorer lanes covered advisor/graph, operations/cutover, and
  vendor/live-proof/business-timing/Barrio boundaries.

Verification run:

- `dart run tool/migration_cutoff_lint.dart --strict-docs` - pass.
- `dart run tool/vendor_completeness_lint.dart` - pass for all
  non-documented vendors; 17 documented vendors skipped by lifecycle gate.
- `dart run tool/ux_em_dash_lint.dart` - pass.
- `dart analyze --fatal-infos` - pass.

## Remediation note - 2026-05-27

Operator direction after this report: leave Advisor/AI items for their lane
and fix the rest.

Fixed in the follow-up patch:

- Vendor-now-available generic fanout now suppresses generic email so the
  pending-row "Notify me" path is the only email source.
- Push proof now recognizes `patrol` as declared and fails non-zero with
  `push_delivery.not_implemented` when every prerequisite is present but the
  real two-device body is still missing.
- Production1 runtime docs now distinguish completed Cloud Run/Firebase/egress
  setup from still-blocked DNS/Auth/SendGrid/migration/traffic work.
- Launch migration queue references now point at the 76-file cutoff through
  `202605261200_phase_12_c3_typed_graph_vocabulary.sql`.
- 11A remaining-slice labels now match the phase body and stop calling
  cross-operator targeting "operator impersonation."
- Business Timing Live docs now reflect the landed projector/routes while
  keeping production apply and live proof gates explicit.
- Non-AI admin-pressure placeholder scenarios now assert real screens,
  dialogs, empty-state branches, and scoped navigation instead of only booting
  the shell.
- Business-account suspend/reactivate now require an operator-entered admin
  reason before the gateway write; the HTTP gateway sends that exact reason.
- Data Accuracy admin expectations now follow the tabbed Operator Web surface,
  and the manual covers row wraps instead of overflowing inside admin width.
- Admin route comments now describe fixture fallback gateways accurately: they
  are test/share-preview/local fallbacks, not production wiring.

Deferred by operator direction:

- Advisor live/demo gateway binding, prior-turn memory, CMK deploy secret, and
  activation-doc drift.
- Advisor/Tier-M/cutover gate wording until that lane completes.
- Graph candidate path/content cleanup.
- AI/corpus/pricing/observability admin-pressure placeholders.

## Findings

### P0 - Advisor chat surfaces do not call the live answer endpoint

The live `AdvisorAnswerGatewayLive` exists, but no production auth source binds
it.

Evidence:

- `lib/operator_web/screens/advisor_chat_nav.dart:46` falls back to
  `AdvisorAnswerGatewayDemo` unless the auth source implements
  `AdvisorAnswerGatewayProvider`.
- `lib/operator_web/auth/firebase_operator_web_auth_source.dart:27` implements
  many gateway providers but not `AdvisorAnswerGatewayProvider`.
- `lib/screens/advisor/advisor_mobile_chat_nav.dart:42` has the same provider
  seam and demo fallback.
- `lib/forge_flow_app.dart:1384` passes `resolveAdvisorMobileGateway(null)`, so
  the mobile Advisor tab always receives the demo gateway.
- `rg "AdvisorAnswerGatewayLive"` finds only the gateway class and tests, not a
  production binding.

Impact: Operator Web and mobile can show Advisor chat while returning canned
demo recommendations instead of calling `POST /v1/advisor/answer`.

Fix direction: bind `AdvisorAnswerGatewayLive` in the live Operator Web auth
source and pass a real provider/source into the mobile Advisor tab, or hide the
chat until live binding is present.

### P0 - Cutover gates contradict each other

The tracker says `cutover.0b` Tier-M is launch-blocking, but the cutover plan
still says `cutover.1` and `cutover.0b` are skipped for V1 because AI is paused.

Evidence:

- `PROJECT_TRACKER.md:117` and `PROJECT_TRACKER.md:215` say Tier-M is
  launch-blocking.
- `docs/phases/phase_production_cutover/phase_production_cutover_plan.md:243`
  starts the stale AI-paused note.
- `docs/phases/phase_production_cutover/phase_production_cutover_plan.md:252`
  says `cutover.1` is skipped for V1.
- `docs/phases/phase_production_cutover/phase_production_cutover_plan.md:258`
  says `cutover.0b` is skipped for V1.
- `PROJECT_TRACKER.md:162` says the Advisor Knowledge Activation carve-out is
  active and no longer frozen.

Impact: launch can be blocked by a gate one doc says to skip, or skip a gate the
tracker says is required.

Fix direction: pick one authority for Advisor/Tier-M launch gates, then update
the cutover plan, tracker, and go-live runbooks together.

### P0 - Production1 migration queue is stale in launch docs

The authoritative follow-up doc now says 76 pending Production1 migrations
through the C3 typed graph vocabulary migration. Other launch docs still say 75
through the Plans and Limits windows migration.

Evidence:

- `docs/POST_HARDENING_FOLLOWUPS.md:34` says 76 migrations pending.
- `docs/POST_HARDENING_FOLLOWUPS.md:122` includes
  `202605261200_phase_12_c3_typed_graph_vocabulary.sql`.
- `PROJECT_TRACKER.md:105` still says 75 migrations through
  `202605251020_plans_and_limits_scoped_contract_windows.sql`.
- `runbooks/v1_operator_launch_punchlist_runbook.md:111` repeats the stale 75
  migration count.
- `docs/phases/phase_production_cutover/phase_production_cutover_plan.md:333`
  is older still and refers to one pending batch.

Impact: an operator can apply the wrong migration set or audit the wrong cutoff.

Fix direction: make `docs/POST_HARDENING_FOLLOWUPS.md` the single queue
authority and update every launch/cutover reference to the 76-file cutoff.

### P0 - Production runtime readiness docs disagree

One cutover doc says Production1 still lacks Cloud Run, Secret Manager, static
egress, DNS, Firebase apps/configs, and traffic. The V1 launch runbook says most
of that setup was completed on 2026-05-06.

Evidence:

- `docs/phases/phase_production_cutover/phase_production_cutover_plan.md:4`
  says production runtime setup has not happened.
- `runbooks/v1_operator_launch_punchlist_runbook.md:17` says Production1 APIs,
  Firebase apps/configs, Secret Manager, static egress, Azure firewall, and
  Cloud Run services completed.
- `PROJECT_TRACKER.md:104` still lists the Firebase Auth action-domain switch
  as open.

Impact: `cutover.0` cannot get a clean go/no-go because the docs disagree about
what exists.

Fix direction: split "completed runtime setup" from "still blocked DNS/Auth
switch/SendGrid/migrations" in the production cutover plan and tracker.

### P1 - Advisor multi-turn memory is not sent from clients

The server accepts `prior_turns` and uses it as the actual model memory. The
client and chat screens only carry `conversation_id`.

Evidence:

- `tool/advisor_proxy/advisor_answer_route_group_part.dart:233` parses
  `prior_turns`.
- `tool/advisor_proxy/advisor_agentic_answer_part.dart:211` prepends
  `priorTurns` to the model messages.
- `lib/services/advisor/advisor_answer_gateway.dart:313` sends `question` and
  optional `conversation_id`, but no `prior_turns`.
- `lib/operator_web/screens/advisor_chat_screen.dart:133` passes only
  `conversationId`.
- `lib/screens/advisor/advisor_mobile_chat_screen.dart:109` passes only
  `conversationId`.
- `docs/phases/advisor_knowledge_activation/advisor_knowledge_activation_plan.md:120`
  promises `prior_turns` from the client.

Impact: follow-up questions look threaded in the UI but reach the model without
prior user/assistant text.

Fix direction: add a bounded client-side prior-turn payload builder, send it in
`AdvisorAnswerGatewayLive`, and keep the existing server caps.

### P1 - Advisor go-live secret is not in the staging deploy secret map

The runbook says `ADVISOR_CONVERSATION_CMK` must be mapped for the proxy, and
the proxy knows the optional secret name, but the normal staging deploy script
does not include it.

Evidence:

- `runbooks/advisor_answer_go_live_runbook.md:120` says to map
  `ADVISOR_CONVERSATION_CMK`.
- `tool/advisor_proxy/advisor_proxy.dart:549` defines the secret name.
- `tool/advisor_proxy/advisor_proxy.dart:681` lists it as an optional loaded
  secret.
- `scripts/deploy_staging_proxy.ps1:286` builds the secret suffix map without
  `ADVISOR_CONVERSATION_CMK`.

Impact: a standard redeploy can leave `/v1/advisor/answer` fail-closed with
`503 advisor_answer_encryption_unavailable` after the secret exists.

Fix direction: add the CMK suffix mapping to the deploy script and update the
go-live runbook to require verifying the loaded startup log.

### P1 - Vendor-now-available can double-send email

The dispatcher invokes the generic notification fanout and then still enqueues
the legacy per-row `vendor_now_available` emails. The catalog default for this
event includes email.

Evidence:

- `tool/advisor_proxy/email_dispatch/vendor_lifecycle_notification_dispatcher.dart:335`
  invokes the multi-channel fanout.
- `lib/domain/models/notification_event_catalog.dart:119` defaults
  `notif.vendor.now_available` to `push` and `email`.
- `tool/advisor_proxy/email_dispatch/notification_event_fanout.dart:466`
  dispatches the email channel.
- `tool/advisor_proxy/email_dispatch/vendor_lifecycle_notification_dispatcher.dart:391`
  still enqueues one email per pending `vendor_lifecycle_notification` row.
- `docs/phases/phase_8_live_rollout/phase_8_live_rollout_plan.md:315` expects
  N pending rows to trigger N email rows.

Impact: one vendor promotion can send preference-based emails plus the
explicit Notify-me emails.

Fix direction: make the generic fanout push/inbox-only for this event, or make
the legacy row path the sole email source.

### P1 - Push proof tooling is stale and cannot prove delivery

Patrol is now in `pubspec.yaml`, but the push proof script still hard-codes
Patrol as absent and exits 0 for both skipped and ready-but-unimplemented
states.

Evidence:

- `pubspec.yaml:111` declares `patrol`.
- `tool/pressure/p5_push_delivery_proof.dart:180` says Patrol is intentionally
  absent.
- `tool/pressure/p5_push_delivery_proof.dart:205` exits 0 on skipped proof.
- `tool/pressure/p5_push_delivery_proof.dart:231` still emits
  `push_delivery.skipped` in the ready branch.
- `test/pressure/p5_push_delivery_proof_test.dart:205` pins the stale
  "does NOT yet declare patrol" expectation.
- `PROJECT_TRACKER.md:135` and `PROJECT_TRACKER.md:136` still mark physical
  connected-device and push proof pending.

Impact: CI/operator evidence can look green while no connected-device push proof
ran.

Fix direction: update the dependency detector, make the ready branch run the
real proof or fail loudly, and change the pinning test.

### P1 - 11A remaining-slice names drift

The tracker and plan header say remaining work is support audit,
cross-operator reads, and user impersonation. The body of the same 11A plan
names different slices.

Evidence:

- `PROJECT_TRACKER.md:128` lists `11A.8` support audit, `11A.9`
  cross-operator reads, `11A.10` operator impersonation.
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md:5`
  repeats that remaining set.
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md:593`
  says `11A.8` is API version management.
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md:596`
  says `11A.9` is audit log review.
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md:600`
  says `11A.10` is status page management.
- `lib/admin/admin_routes.dart:226` through `lib/admin/admin_routes.dart:238`
  shows cross-operator Members, Roles/Hierarchy/Sessions, and Audit routes
  already exist as later parity slices.

Impact: future prompts can reopen or rename the wrong 11A work.

Fix direction: split "old 11A.8-10 polish backlog" from "support/cross-operator
parity follow-ups" and update tracker labels.

### P1 - Impersonation wording needs a product/security gate

Phase 9 says true operator-user impersonation is separate, rare, visible, and
separately audited. Current admin routes are cross-operator targeting, not true
user impersonation, while a visible impersonation banner already exists.

Evidence:

- `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md:79` says
  F&F internal access is not operator impersonation by default.
- `lib/widgets/impersonation_banner.dart:1` describes a true impersonation
  banner.
- `PROJECT_TRACKER.md:128` uses "Operator impersonation" as a remaining 11A
  item.

Impact: a future "11A.10 impersonation" prompt can accidentally build the wrong
thing or skip required visibility/audit rules.

Fix direction: require an explicit product/security decision before generating
any true impersonation implementation prompt.

### P2 - Advisor activation docs are stale against landed code

The plan still frames D1-D3 as planned even though Operator Web and mobile chat
screens, nav entries, and tests exist.

Evidence:

- `docs/phases/advisor_knowledge_activation/advisor_knowledge_activation_plan.md:120`
  through `:122` list D1-D3 as planned work.
- `lib/operator_web/screens/advisor_chat_screen.dart:1` is the Operator Web
  chat screen.
- `lib/operator_web/router/operator_web_router.dart:1503` registers the nav
  item.
- `lib/operator_web/router/operator_web_router.dart:2002` routes to the chat
  body.
- `lib/screens/advisor/advisor_mobile_chat_screen.dart:1` is the mobile chat
  screen.

Impact: follow-up work can repeat shipped UI instead of fixing the live binding
and memory gaps above.

Fix direction: mark D1-D3 as landed with caveats for live gateway binding and
prior-turn memory.

### P2 - Graph candidate metadata includes worktree-prefixed source paths

The staged graph candidate files contain `source_file` values beginning with
`wt/`, while the artifact README says source metadata should stay repo-relative.

Evidence:

- `tool/advisor_proxy/graphify_candidates/README.md:14` says the manifest must
  keep repo-relative paths only.
- `tool/advisor_proxy/graphify_candidates/candidates/graphify_node_candidates.jsonl:1`
  has `source_file:"wt/docs/..."`.
- `tool/advisor_proxy/graphify_candidates/candidates/graphify_edge_candidates.jsonl:1`
  has `source_file:"wt/docs/..."`.

Impact: admin review/debug metadata can expose local worktree-ish paths and
weaken the artifact packaging contract.

Fix direction: regenerate or sanitize staged candidates so every `source_file`
is repo-relative.

### P2 - Business-timing-live plan is stale against landed code

The plan says live producer/proxy write paths are still gated and lists the
projector/routes as not completed, but the code now contains the projector and
operator/admin write routes.

Evidence:

- `docs/phases/phase_business_timing_live/business_timing_live_plan.md:3` says
  foundation and UI shell are merged while live producer/proxy write paths are
  gated.
- `docs/phases/phase_business_timing_live/business_timing_live_plan.md:210`
  lists `OpenShiftSnapshotProjector`, production proxy reads, and audited
  write endpoints as not completed.
- `lib/services/integration/open_shift_snapshot_projector.dart:141` defines
  the projector.
- `tool/advisor_proxy/phase_8_projector_wiring.dart:49` wires it.
- `tool/advisor_proxy/operator_routes.dart:10` documents operator business
  timing profile routes.
- `tool/advisor_proxy/admin_business_timing_routes.dart:11` documents admin
  business timing profile routes.

Impact: future work may rebuild already landed routes instead of focusing on
remaining hierarchy/settings gaps and production apply gates.

Fix direction: refresh the plan with landed code, remaining risks, and explicit
production-apply blockers.

### P2 - Admin pressure harness still has many reachability stubs

The admin pressure suite still contains many scenarios that only boot the
share-preview shell and carry `TODO(admin-pressure)` assertions.

Evidence:

- `integration_test/admin_pressure/ai_corpus/scenario_ai_cor_01_version_list_renders.dart:19`
  is a stub.
- `integration_test/admin_pressure/ops_access/scenario_ops_acc_01_three_tabs_present.dart:19`
  is a stub.
- `integration_test/admin_pressure/sysmon_debug/scenario_sysmon_debug_01_log_list_renders.dart:19`
  is a stub.
- `integration_test/admin_pressure/README.md:122` documents this stub pattern.
- Broad scan found many more `TODO(admin-pressure)` scenario files.

Impact: the suite is useful as route reachability coverage, but not enough as
deep admin acceptance proof.

Fix direction: convert the highest-risk admin pressure stubs into real
assertions by surface: support logs, access, AI/corpus, business accounts, and
data accuracy.

## Non-findings / boundary checks

- The proxy image packaging copies `tool/advisor_proxy/graphify_candidates` to
  `/app/graphify-out`, and the staged candidate JSONL files are present.
- No active accidental `lib/internal/barrio/**` imports were found outside the
  Barrio app entry/test surfaces. The remaining Barrio risk is content scope in
  the graph candidate bundle, which is operator-decision-gated.
- Migration cutoff lint agrees with the current authoritative cutoff.
- Analyzer and focused guardrails are clean.

## Suggested Fix Order

1. Fix Advisor live gateway binding on Operator Web and mobile.
2. Fix Advisor client `prior_turns` memory.
3. Add `ADVISOR_CONVERSATION_CMK` to proxy deploy secret mapping.
4. Resolve cutover/Tier-M and Production1 docs contradictions.
5. Update migration queue references to 76 through
   `202605261200_phase_12_c3_typed_graph_vocabulary.sql`.
6. Fix vendor-now-available duplicate email fanout.
7. Fix or hard-fail the push proof harness.
8. Clean up 11A naming and impersonation product/security language.
9. Sanitize graph candidate source paths.
10. Refresh stale advisor, business-timing, and admin-pressure docs.
