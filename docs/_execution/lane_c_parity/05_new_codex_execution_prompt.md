# 05 - New Codex Execution Prompt (Lane C - Parity, Slice C-1)

Paste the prompt below into a fresh Codex worktree session to implement Slice **C-1 — SendGrid Event Webhook receiver**. This is the first execution slice per the sequencing in `03_execution_slices.md` because:

- It is independent (no Lane A or Lane B blockers).
- It unblocks every Wired email scenario's delivery-side observability.
- It is additive (no auth surface change, no demo-mode reader changes, idempotent inserts) — auto-merge eligible per CLAUDE.md "Agent-Led Slices."
- Per addendum B3 + C3 urgency: silent email-pipeline gaps are highest-priority for operator trust.

```text
Use the Forge & Flow repo workflow.

Objective:
Implement Slice C-1 of the Lane C parity wave: a SendGrid Event Webhook
receiver on the advisor proxy. Bundle this in a single PR that ends with
the contract "commit + push + open PR → STOP" (no merges, no tracker
writes, no contract amendments).

Source-of-truth docs (read before coding, in this order):
- CLAUDE.md (authority order; Hard Promises; agent-led-slices rules)
- docs/_decisions/post_codex_wave_decisions_2026-05-12.md
- docs/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md
  (esp. Block B B3 and Block C C3)
- docs/_execution/lane_c_parity/01_product_rule_and_ia.md
  (HP #10 operationalization: every email scenario is wired,
   deleted, or explicitly deferred)
- docs/_execution/lane_c_parity/02_plumbing_audit_matrix.md
  (gap E1: SendGrid event webhook receiver is missing)
- docs/_execution/lane_c_parity/03_execution_slices.md
  (Slice C-1 definition)
- docs/_audits/code_health/c_email_notification_scenario_inventory.md
  (every wired email scenario's delivery signal depends on the
   event webhook landing)
- docs/_research/post_codex/r4_email_notification_testing.md §5A
  (the canonical pattern for this receiver — SendGrid Event
   Webhook → `email_event` table)
- docs/contracts/slice_runtime_acceptance_contract.md
  (advisory pattern; reviewer-judgment, not CI-enforced)
- docs/CODEX_PROMPT_GENERATION_STANDARD.md

Hard rules:
1. Do NOT touch CLAUDE.md, PROJECT_TRACKER.md, MEMORY.md, or any
   docs/contracts/* file. If a contract gap is found, flag it in
   the PR description, do not amend.
2. Do NOT touch any of the 13 email template Markdown files. They
   are out of scope for this slice.
3. Do NOT modify the 4 notification fanout hook helpers
   (notification_event_hooks.dart). B3 already landed; this slice
   inherits that fix.
4. Do NOT register a new email template id; this slice is the
   inbound-event receiver, not an outbound-send change.
5. No --no-verify. No --no-gpg-sign. Local hooks run.
6. New code paths must respect the proxy's existing patterns:
   - idempotency via UNIQUE (handled at the email_event.event_id
     constraint that already exists in the migration)
   - structured logging through the existing log() seam
   - timeouts + bounded retries on the route
7. The proxy route is NOT counted against /readyz. Health stays
   cheap.

Worktree + branch:
- Worktree under .claude/worktrees/<lane-name> per the existing
  Codex parallel-lane convention.
- Branch: codex/c1-sendgrid-events-webhook (or worktree name).

Scope (exhaustive):
- NEW: tool/advisor_proxy/sendgrid_events_webhook.dart — the route
  handler.
- NEW: lib/services/email/sendgrid_event_payload.dart — typed
  payload parser (so the proxy and any future BigQuery / Cloud
  Logging consumer share one parser).
- EDIT: tool/advisor_proxy/main.dart — mount the route. Look for
  the existing admin_email_routes mount as the reference pattern
  (line ~814; verify at audit time).
- EDIT: tool/advisor_proxy/proxy_bootstrap.dart — wire the
  signature verifier dependency if production loads the pubkey
  through `email_credentials` rather than env var.
- NEW: test/proxy/sendgrid_events_webhook_test.dart — happy path,
  bad-signature reject, replayed-payload no-op, partial-batch
  insert with mixed event_ids.
- NEW: test/services/email/sendgrid_event_payload_test.dart —
  parser unit tests covering every event_type SendGrid documents
  (processed, delivered, open, click, bounce, deferred, dropped,
  spamreport, unsubscribe, group_unsubscribe, group_resubscribe).

Required route shape:
- POST /v1/webhooks/sendgrid/events
- Request: JSON array of event objects (SendGrid Event Webhook
  payload — see https://docs.sendgrid.com/for-developers/tracking-events/event)
- Signature header: X-Twilio-Email-Event-Webhook-Signature (ECDSA
  over `timestamp + body`)
- Timestamp header: X-Twilio-Email-Event-Webhook-Timestamp
- Auth: signature-only (no JWT). The signature IS the auth.
- Response: 204 No Content on success; 401 on bad signature;
  400 on malformed body.
- Side effect: one INSERT into email_event per event row,
  ON CONFLICT (event_id) DO NOTHING (or equivalent). The
  migration db/migrations/202605040200_phase_9_8_email_provider.sql
  already created the table; this slice does NOT touch migrations.

Required signature verifier:
- ECDSA P-256 over SHA-256
- Pubkey source: prefer env var `SENDGRID_EVENT_WEBHOOK_PUBKEY`
  (PEM); fall back to a row in `email_credentials` if present.
- Reject if timestamp drift > 5 minutes (clock skew tolerance) to
  prevent replay attacks.

Tests (all must pass with `flutter test`):
- Happy path: valid signature, valid 2-event batch, both rows
  inserted, response is 204.
- Bad signature: 401, zero rows inserted.
- Replayed payload: same `event_id` re-delivered, second call
  inserts 0 rows, response is still 204 (idempotent).
- Partial batch: 1 row has malformed JSON, route returns 400 and
  inserts ZERO rows from the batch (all-or-nothing transaction).
- Old timestamp: > 5-min drift → 401.
- Every documented event_type round-trips through the parser.

Out of scope (do NOT touch):
- The outbound email send seam (`email_outbox_dispatcher.dart`,
  `sendgrid_email_provider.dart`).
- The 13 email Markdown templates.
- The 4 notification hook helpers (`notification_event_hooks.dart`,
  `notification_event_fanout.dart`).
- The 9 EmailTemplateIds entries (no registration changes).
- The B3 silent-failure fix paths.
- Mobile push (FCM) routes and tests.
- The admin "Test connection" route (already wired at
  `admin_email_routes.dart:140`).

Lens audit (include in PR description):
Run Lens 5 (proxy / route / gateway contract), Lens 7 (lifecycle —
idempotency on replay), Lens 12 (tests / evidence), Lens 13
(observability — structured logging on bad signature). Attach the
table format from FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK §
"Required Output."

PR description must include:
1. Slice ID: lane_c_parity / C-1.
2. Source authority: addendum C3 + B3, c_email_notification_scenario_inventory §"Quick wire-status rollup" SendGrid Event Webhook gap.
3. Lens-audit table (above).
4. Test summary: list every test added; assert dart analyze clean
   on touched files; flutter test pass count.
5. Idempotency posture: how replay collisions are handled.
6. Health posture: route is NOT in /readyz.
7. Carry-over risks: signature key rotation procedure (operator
   adds the key in env var; route picks it up at next deploy);
   no DB migration in this slice.
8. Cross-lane handoff note: when C-1 lands, the Wired email
   scenarios (vendor-now-available, backfill complete / failed,
   audit anchor failure, password reset, invite) gain delivery
   evidence via `email_event` rows; this unblocks slice C-11
   pressure tests.

Final action:
- git add the new + edited files (explicit paths, NOT git add .)
- git commit with a HEREDOC message:

  Add SendGrid Event Webhook receiver for lane_c_parity slice C-1

  Wires the inbound delivery / open / click / bounce / dropped event
  stream from SendGrid into the existing `email_event` table.
  Required by every Wired email scenario to gain delivery-side
  observability per addendum C3. ECDSA signature verification on
  every request; idempotent inserts; not on /readyz.

  Authority: docs/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md
  C3 + B3; docs/_audits/code_health/c_email_notification_scenario_inventory.md
  "Quick wire-status rollup."

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>

- git push -u origin <branch>
- gh pr create with the title and body summarizing the above.
- STOP. Do not merge. Do not amend the demo-mode contract. Do not
  touch trackers. Wait for orchestrator audit.

Final report (post to the user in the chat thread after PR is up):
- PR URL
- Branch name
- Test commands run + pass count
- Lens-audit table
- Any cross-lane dependencies blocked / unblocked
- Any audit-doc-hygiene flags discovered (e.g., the stale
  c_email_notification_scenario_inventory wire-status rollup
  rows that B3 already updated)
- Decision stops, if any
```

## Slice C-1 — Why this slice goes first

1. **Independent** — no Lane A / Lane B / other Lane C slice blocks it.
2. **High-priority per addendum** — B3 + C3 both flagged email-pipeline silent gaps as the top operator-trust risk.
3. **Unlocks pressure testing** — once delivery events land in `email_event`, every other wired email scenario can be pressure-tested end-to-end against SendGrid → real DNS → real inbox per R4 §5B Mailosaur + §5A event webhook.
4. **Auto-merge eligible** — additive, no auth surface change, no schema change (migration already shipped), idempotent.
5. **Operator confidence** — a working webhook is operator-visible evidence that the email pipeline observability gap is closed. The next slice (C-2 wire-or-delete decisions) is operator-led; C-1 lands without operator input, then operator decides C-2 with full delivery-event observability available.

## After Slice C-1 lands

The orchestrator dispatches the C-2 wire-or-delete drafts (one PR per template decision), then proceeds to C-3 (sign-in-security redirect) and C-4 (master Demo→Live switch) in parallel since they touch independent code surfaces. C-5 (deep-link redemption) waits on Lane B B11 per the sequencing in `03_execution_slices.md`.

## Cross-references

- `01_product_rule_and_ia.md` — HP #10 operationalization, ownership map.
- `02_plumbing_audit_matrix.md` E1 — SendGrid event webhook gap citation.
- `03_execution_slices.md` Slice C-1 — full slice definition.
- `04_verification_deploy_and_e2e.md` — pressure-test matrix dependency.
- `docs/_research/post_codex/r4_email_notification_testing.md` §5A — the pattern reference.
- `db/migrations/202605040200_phase_9_8_email_provider.sql` — the `email_event` schema this slice writes into.
- `tool/advisor_proxy/admin_email_routes.dart` — reference for proxy route mounting pattern (lines around 140 per the inventory).
