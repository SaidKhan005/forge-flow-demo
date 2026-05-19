# 03 - Execution Slices (Lane C - Parity)

## Parallelization Rule

Start with the C-Emails wire-or-delete decisions (per addendum C3 + B3 urgency) because they have no cross-lane dependency and the inventory artifact is already authoritative. C-Mobile redemption-flow slices depend on Lane B B11. C-OpsWeb Inheritance Tree slices depend on Lane A's shared component.

Each slice is one worktree, one PR. Per CLAUDE.md "Agent-Led Slices": commit + push + open PR → STOP. No auto-merge for auth-touching slices (3, 4, 5 listed below); explicit operator approval is required before merge.

## Slice C-1 — SendGrid Event Webhook receiver

Ownership:
- `tool/advisor_proxy/sendgrid_events_webhook.dart` (new)
- `tool/advisor_proxy/main.dart` (mount the router)
- `test/proxy/sendgrid_events_webhook_test.dart` (new)
- `lib/services/email/sendgrid_event_payload.dart` (new — typed parsing, no client dependency)

Tasks:
- New proxy POST route at `/v1/webhooks/sendgrid/events`.
- ECDSA `X-Twilio-Email-Event-Webhook-Signature` verification — pubkey loaded from env or `email_credentials` row.
- Parse batched event array; insert one `email_event` row per event with `event_id` uniqueness.
- Idempotent re-delivery: ON CONFLICT DO NOTHING via the existing UNIQUE index.
- Tests: happy path, bad signature reject, replayed payload no-op, partial-batch handling.

Dependencies: none. This slice can ship first.

Risk: low (additive, no auth surface change, idempotent inserts). Auto-merge eligible.

Size: ~250 LoC route + parser + 6-8 tests.

## Slice C-2 — Wire-or-delete decisions for 6 template-only emails

Ownership:
- `tool/advisor_proxy/email_templates/*.md` (delete OR keep)
- `lib/services/email/email_template_renderer.dart` (remove ids OR document deferral)
- For wired-path templates: the matching emitter file (worker / cron / hook)

Tasks:
- One PR per decided template. Operator decides wire OR delete per template; this slice produces the **draft PRs** for each decision so the operator only has to approve.
- Draft A: delete `operator_admin_invite.md` + `operator_invite_first_admin.md` + their id entries (per addendum B4 resolution path 1).
- Draft B: alternatively, wire the SendGrid invite emails and stop sending the Firebase reset email as invite-bootstrap (per addendum B4 resolution path 2).
- Draft C: wire `mfa_factor_changed_notice` emitter from the MFA enrollment / removal worker.
- Draft D: wire `vendor_sync_error_alert` emitter from the polling tier worker.
- Draft E: wire `vendor_webhook_signature_alert` emitter from the inbound webhook signature verifier.
- Draft F: wire `vendor_connection_auto_disabled` emitter from `lib/services/integration/oauth_refresh_cron.dart` after the 3rd failure.
- Draft G: wire `tos_version_updated_notice` emitter from the `tos_versions` insert path.

Dependencies: Slice C-1 (without the event webhook, the wired emails have no delivery signal).

Risk: medium for wire paths (touches workers and cron). Low for delete paths. Operator-led decision; no auto-merge until each template's wire-or-delete is approved.

Size: 50-200 LoC per template. 7 small PRs in this slice cluster.

## Slice C-3 — Sign-in-security → My Account redirect (decision #7)

Ownership:
- `lib/operator_web/router/operator_web_router.dart` (remove `kOperatorWebNavSecurity` nav item; add `/security` + `/sign-in-security` → `/my-account` redirect logic)
- `lib/operator_web/screens/my_account_screen.dart` (merge MFA + Password + Login history sections from the deleted `SecurityScreen`)
- `lib/operator_web/screens/security_screen.dart` (DELETE)
- `test/operator_web/router/sign_in_security_redirect_test.dart` (new)
- `test/operator_web/screens/my_account_screen_test.dart` (extend)
- Email template copy migration (NOT in this slice — follow-up per addendum decision #7's "low-priority cleanup")

Tasks:
- Move the Login history section's gateway wiring from `SecurityScreen` into a new `MyAccountScreen` subsection.
- Add a redirect handler to the router that intercepts `/security` and `/sign-in-security` deep links and re-routes to `/my-account` with the security subsection scrolled into view.
- Update nav items: drop "Sign-in security" under "Access" group; the MFA + Password + Login history affordances live entirely under "My account."

Dependencies: none.

Risk: medium (auth-adjacent — the MFA + password change buttons are MFA-pinned). Operator approval required before merge per CLAUDE.md "auth-critical slices."

Size: ~400 LoC moved + ~200 LoC test + 2 hour merge prep.

## Slice C-4 — Master Demo→Live switch (decision #6)

Ownership:
- New proxy route at `tool/advisor_proxy/demo_mode_master_switch_routes.dart`: `POST /v1/operators/.../demo-mode-master-switch`.
- New mobile widget in `lib/screens/settings/settings_data_sections.dart` or a new `lib/screens/settings/settings_demo_live_switch.dart`.
- Repository extension at `lib/infrastructure/persistence/postgres/repositories/demo_mode_state_repository.dart` (or wherever the per-row flip lives today) for the batch flip.
- `docs/contracts/demo_mode_contract.md` — append the master switch as a 4th carve-out under the existing reader-side carve-outs list. **Lane C drafts the update; operator approves before contract write.**
- Tests: proxy + repository + widget.

Tasks:
- Build the master switch UI in mobile Settings → Integrations near the existing `DemoModeBanner` consumer.
- Switch state = computed from `DemoModeStateNotifier.snapshot.hasDemoCategories`.
- Flip Demo→Live: call the new proxy route, which iterates rows and flips `is_demo = true → false` for every matching `(operator_id, location_id, category)` row. Returns 200 with the new snapshot.
- Flip Live→Demo: client refuses with a SnackBar; server rejects with 409 + "live data has arrived" detail.
- Auto-flip-on-first-backfill behavior (`DemoModeFlipPolicy.evaluateFlip`) is untouched.
- HP #2 compliance test: no `kDemoMode` branch added; no new `demo_*` SQLite table; no new reader-side carve-out beyond the documented UI fold.

Dependencies: none. Demo-mode contract update is Lane C-authored but operator-approved before commit.

Risk: low for the UI; medium for the proxy route (RLS-touching). Operator approval required before merge per CLAUDE.md "RLS-touching slices."

Size: ~500 LoC route + repo + widget + 8-10 tests.

## Slice C-5 — Mobile pointer rows do deep-link redemption (decisions #5 + A1)

Ownership:
- `lib/screens/settings/settings_pointer_row.dart` (replace clipboard with `url_launcher` deep-link)
- `lib/services/auth/handoff_code_gateway.dart` (NEW — consumer of Lane B B11's redemption endpoint)
- `lib/screens/settings/settings_data_sections.dart` + sibling Settings sections (replace pointer rows with "Manage on Operator Web" deep-link buttons per the ownership map)
- `lib/operator_web/router/operator_web_router.dart` (NEW `/handoff?code=...&nav=...` landing handler)
- Tests on both sides.

Tasks:
- Mobile side: build the gateway that calls the proxy redemption endpoint, awaits an opaque short-TTL code, and opens `https://app.forgeflow.app/handoff?code=...&nav=<nav-id>` via `url_launcher`. Fall back to clipboard on offline / proxy 5xx.
- Operator-web side: parse the `code` query param on landing, POST to the proxy to redeem (Lane B B11's endpoint), receive the operator-web session JWT + nav target, route accordingly.
- Sensitive-target list (account edits, MFA enroll, role mutations) requires fresh-MFA step-up via RFC 9470 — Lane B B11's endpoint returns the step-up challenge when the target is sensitive; operator-web shows the challenge UI.

Dependencies: **Lane B B11 must land first.** This slice cannot ship until the redemption endpoint exists. Coordinate via the wave plan's lane-B status check.

Risk: high (cross-surface auth flow). Operator approval required before merge per CLAUDE.md "auth-critical slices."

Size: ~700 LoC across mobile + ops-web + tests. Big slice — consider splitting once Lane B B11 lands and the endpoint contract is concrete.

## Slice C-6 — Inheritance Tree shared component consumer

Ownership:
- `lib/operator_web/screens/members_screen.dart` (swap scope picker tree)
- `lib/operator_web/screens/hierarchy_screen.dart` (swap tree view)
- `lib/operator_web/screens/wage_authority_screen.dart` (swap blended wage mix display tree)
- `lib/operator_web/screens/roles_screen.dart` + `lib/operator_web/screens/custom_role_editor_screen.dart` (swap role inheritance tree)
- `lib/admin/screens/operator_location_admin_screen.dart` + `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart` (matching admin consumers)

Tasks:
- Replace each consumer's current ad-hoc tree widget with the shared component from Lane A.
- Preserve every existing consumer's keys, copy, and click handlers.
- Tests update key references.

Dependencies: **Lane A must land the shared Inheritance Tree component first.**

Risk: low (presentational refactor).

Size: ~6 PRs, one per consumer, ~150 LoC each.

## Slice C-7 — Adaptive 2FA button (R1 pattern, decision C1)

Ownership:
- `lib/operator_web/screens/my_account_screen.dart` (button label adapts to state)
- `lib/auth/permission_keys.dart` if a new key is needed (likely not — adaptive label is a presentation concern)
- Test: `test/operator_web/screens/my_account_screen_test.dart` (extend)

Tasks:
- Compute button state from `(session.mfaEnrolled, factor_count, recovery_codes_viewed_at)`.
- Render one of: "Enable two-factor sign-in" / "Add another method" / "View recovery codes" / "Manage two-factor sign-in" per R1 pattern.
- Tooltip + sub-copy adapt to match.

Dependencies: none. C-3 (sign-in-security redirect) should land first because the buttons live in My Account.

Risk: low (label change). Operator approval not required.

Size: ~80 LoC + 4 tests.

## Slice C-8 — Notification preferences catalog completeness

Ownership:
- `lib/operator_web/screens/settings_notifications_screen.dart`
- `lib/domain/models/notification_event_catalog.dart` (no edits — just render every entry)
- `test/operator_web/screens/settings_notifications_screen_test.dart`

Tasks:
- Render every catalog entry, including the 3 future entries, with appropriate state ("Available" / "Coming soon" / "Backend-only").
- Toggle persists per (operator, user, event) row through the existing `NotificationPreferencesRepository`.

Dependencies: none.

Risk: low.

Size: ~200 LoC + tests.

## Slice C-9 — Mobile in-app inbox renders every catalog event

Ownership:
- `lib/screens/notifications_screen.dart` (extend rendering for new catalog event types)
- `lib/services/app_notification_service.dart` (no new emit methods — `emitPushDelivery` already accepts arbitrary data)
- Tests.

Tasks:
- Audit `app_notifications` rows for unrendered event types in the inbox screen.
- Add tile copy per catalog entry.
- Bell-badge math regression: rapid-emit + mark-read race.

Dependencies: none.

Risk: low.

Size: ~150 LoC + tests.

## Slice C-10 — Admin parity copy + read-only-mostly tile labels

Ownership:
- `lib/admin/admin_routes.dart` (re-word subtitles + badges for read-only tiles)
- `lib/admin/screens/per_location_data_accuracy_screen.dart` (clarify read-only intent)
- `lib/admin/screens/polling_and_pricing_admin_screen.dart` (clarify admin-only intent)
- `lib/admin/screens/integration_admin_screen.dart` (clarify global-health intent)
- Tests for copy presence.

Tasks:
- Per the ownership map in `01_product_rule_and_ia.md`, every admin tile that is **cross-surface** with operator-web (data accuracy, polling/pricing, integrations) gets a UI banner that says "Operator edits live on Operator Web; this view is for F&F support."
- Admin-only tiles (Pricing, Corpus, AI Metrics, Health, Feature Flags, Debug) get a banner that says "This surface is for F&F admins only — operators cannot see it."

Dependencies: none.

Risk: very low (copy only).

Size: ~100 LoC.

## Slice C-11 — Pressure-test the inventory under preview

Ownership:
- `tool/pressure/p5_email_scenario_loopback.dart` (new) — Mailosaur loopback per R4 §7A.
- `tool/pressure/p5_push_delivery_proof.dart` (new) — Patrol harness per R4 §4B + §7C.
- Test evidence captured in `docs/_execution/lane_c_parity/lane_c_evidence_<date>.md` (lane evidence file, NOT a closure doc).

Tasks:
- Pressure-test every wired email scenario from the inventory against a Mailosaur address. Capture before/after evidence.
- Patrol two-device test for bell-badge invalidation per R4 §3B (mark-read SLO ≤ 5s).
- Playwright loopback for Firebase Auth action-link per R4 §7A.

Dependencies: C-1 (event webhook), C-2 (wire-or-delete decisions landed), C-5 (deep-link handoff), Lane B B11.

Risk: low (test-only).

Size: ~800 LoC harness + 2 day setup per the R4 budget summary.

## Slice C-12 — Final lane-C integration + audit

Tasks:
- Verify every gap in `02_plumbing_audit_matrix.md` is closed or documented as intentional.
- Run the Mobile / Web Console E2E framework across every changed surface.
- Run the Performance Framework on operator-web and mobile.
- Final audit: compare code against every row in the ownership map in `01_product_rule_and_ia.md`.

Dependencies: C-1 through C-11 landed.

Risk: low.

Size: 1-2 days of audit + evidence capture.

## Sequencing summary

```
Lane B B11 (redemption endpoint)
                 │
                 ▼
         ┌───────────────┐
         │  C-1 webhook  │ ← independent
         └───────┬───────┘
                 │
         ┌───────▼───────┐
         │  C-2 wire-or  │ ← per-template, operator-led
         │     -delete   │
         └───────┬───────┘
                 │
       ┌─────────┴─────────┬─────────┐
       │                   │         │
 ┌─────▼─────┐       ┌─────▼─────┐  ▼
 │ C-3       │       │ C-4 demo   │ ...
 │ sign-in→  │       │ master     │
 │ MyAccount │       │ switch     │
 └─────┬─────┘       └────────────┘
       │
 ┌─────▼─────┐   (after Lane B B11)
 │ C-5 deep- │
 │ link handoff │
 └─────┬─────┘
       │
       ▼
 (parallel: C-6 Inheritance, C-7 adaptive 2FA, C-8 prefs, C-9 inbox, C-10 admin copy)
       │
 ┌─────▼─────┐
 │ C-11 pressure-test │
 └─────┬─────┘
       │
 ┌─────▼─────┐
 │ C-12 audit │
 └────────────┘
```

C-1 + C-2 are the "wire-or-delete" pre-reqs Phase per addendum C3+B3.
C-3 + C-4 are the parity-defining slices and the highest-visibility V1 cuts.
C-5 is gated on Lane B and ships last among the auth-touching slices.
C-6 through C-10 are quality-of-implementation slices that can parallelize once the gating decisions land.
C-11 + C-12 are evidence + closeout.
