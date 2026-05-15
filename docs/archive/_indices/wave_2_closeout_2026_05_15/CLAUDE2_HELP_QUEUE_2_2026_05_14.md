# Claude2 Help Queue #2 — 2026-05-14 (post-rate-limit)

Claude #2 is rate-limited until ~1 hour from this push. This doc parks three more self-contained slices ready for them to pick up the moment they're back. Main lane keeps working in parallel.

## Status at this push

- **Help PR #1 status:**
  - Slice 2 (DEBUG_MD_IMPLEMENTATION_STATUS sync) — **merged** as PR #693.
  - Slice 1 (W-5-mobile-FU mobile dashboard header logo) — status unknown at this push; check `gh pr list --state open --search "claude2"` on return. If still open, finish that one first before picking up below.
- **Main lane: 22 main slices + follow-ups merged. 4 active main-lane workers** (W-3 profile self-service, R-1L Roles schema, MO-2-FU covers aggregator, Q-2a email soak harness).
- **Master tip:** `14b72714` (PR #693 — DEBUG_MD sync merge).

## Workflow (same as every prior Claude #2 slice)

1. Branch: `claude2/<slice-name>` off current `origin/master`.
2. Step 0: `pwsh scripts/install_git_hooks.ps1` — fresh worktrees inherit the stale heavy hook that stalls `git push`. ALWAYS run first.
3. Implement scope; no broadening.
4. Self-audit Pattern B (14 lenses, file:line citations).
5. Tests + `dart analyze --fatal-infos` clean.
6. Commit + push + open PR. Base = `master`. PR body MUST include the Pattern B self-audit table + an empty reviewer slot.
7. STOP. Orchestrator audits + merges. No tracker edits.

## Slice 3 — Q-2b: Patrol harness for in-app notification surface

### Origin

`docs/_indices/WAVE_2_LEDGER.md` Lane Q row Q-2. Operator split Q-2 into a/b/c on 2026-05-14. Q-2a (email soak via Mailosaur + SendGrid) is in flight on the main lane. Q-2b is the in-app notification half.

### What ships

End-to-end in-app notification testing via Patrol (mobile UI testing framework). Specifically:

1. **Patrol dev dependency.** Add `patrol` to `pubspec.yaml` dev_dependencies if not present (verify with `grep patrol pubspec.yaml`). Configure the Patrol CLI runner.
2. **Test harness directory.** New `integration_test/in_app_notifications/` directory.
3. **Per-notification-path coverage.** At minimum cover:
   - Invite-pending → invite-claimed transition badge.
   - Audit-anchor failure alert pill on the data accuracy screen.
   - First-connect backfill complete celebration tile.
   - Vendor disconnect warning tile.
4. **Harness driver.** New file `tool/in_app_notification_soak/in_app_notification_soak_orchestrator.dart` that mirrors `tool/pressure/p4_soak_orchestrator.dart`'s shape but drives Patrol tests instead of HTTP soak.
5. **Per-test deterministic seed.** Each Patrol test seeds the SQLite state it needs (or hits a demo-mode seed endpoint), launches the app, asserts the notification surface renders correctly within a latency budget.

### Authority anchors

- `tool/pressure/p4_soak_orchestrator.dart` — Q-1's soak orchestrator. Mirror its shape.
- `lib/widgets/notification_*` — wherever in-app notification widgets live. Grep `notification` in `lib/widgets/` and `lib/screens/`.
- `lib/services/notification_*` — notification dispatcher.
- `docs/contracts/notification_routing_contract.md` (if it exists) — current routing posture.

### Constraints

- Patrol is a test-only dependency. No production code path changes.
- HP #2 — works whether `kDemoMode=true` or `kDemoMode=false`. Demo mode is the natural seed for the harness.
- DO NOT raise `kAdvisorProxyMaxLines`.
- DO NOT widen permission gates.
- DO NOT touch trackers/ledger/audit docs.
- If Patrol turns out to require platform-specific setup (Android SDK config, iOS provisioning), document the setup in the PR body but ship the test framework regardless — the per-platform run can be triggered later.

### Verification

- `dart analyze --fatal-infos integration_test/in_app_notifications/ tool/in_app_notification_soak/` — clean
- `flutter test integration_test/in_app_notifications/` — at least one Patrol test runs cleanly under demo mode
- `dart run tool/advisor_proxy_size_lint.dart` — must stay at ceiling or below

### Commit + PR

- Commit: `Wave 2 Q-2b: Patrol harness for in-app notification surface`
- Branch: `claude2/q-2b-patrol-in-app-notifications`
- PR title: `Wave 2 Q-2b: Patrol harness for in-app notification surface`
- Base: `master`.

---

## Slice 4 — Q-2c: Firebase Test Lab integration for mobile push delivery

### Origin

`docs/_indices/WAVE_2_LEDGER.md` Lane Q row Q-2. The third Q-2 sub-slice. Drives mobile push round-trip testing on real devices via Firebase Test Lab.

### What ships

1. **Test Lab config.** New `tool/firebase_test_lab/` directory with the gcloud invocation script + matrix config (Android API levels, iOS versions).
2. **APK / IPA fixtures.** Document how to build the demo-mode APK for Test Lab (`flutter build apk --release --flavor forgeflow --dart-define=kDemoMode=true`). Don't ship the binary; ship the build invocation + the Test Lab config.
3. **Push round-trip test.** A new integration test (Flutter or Patrol) that:
   - Receives a known push notification at app cold-start.
   - Asserts the notification badge / banner renders.
   - Asserts the tap-handler routes to the correct screen.
4. **Webhook for Test Lab completion.** A small new endpoint or local listener that records the Test Lab matrix result so the harness driver can poll for completion. Probably ships as a sibling proxy file under `tool/advisor_proxy/firebase_test_lab_webhook_routes.dart` (do NOT touch `advisor_proxy.dart`).
5. **Soak orchestrator integration.** Add a Q-2c step to the test harness driver: trigger a push → spawn Test Lab matrix → poll for matrix results → assert delivery.

### Authority anchors

- `lib/services/push/` — wherever push notification handling lives. Grep `firebase_messaging` in `lib/`.
- `lib/main_forgeflow.dart` — confirms push handler wiring.
- `tool/audit_anchor/azure_blob_client.dart` — credential pattern (Workload Identity Federation) — Test Lab uses Google credentials but the secret-store pattern is similar.

### Constraints

- Test-time-only. No production push handler changes.
- Real-device runs require an active Firebase Test Lab project — when unset (no `FIREBASE_TEST_LAB_PROJECT_ID` env), the harness skips with a clear message.
- HP #2 — demo mode parity.
- DO NOT touch trackers / ledger / audit docs.

### Verification

- `dart analyze --fatal-infos tool/firebase_test_lab/` — clean
- `flutter test test/tool/firebase_test_lab/` — orchestrator tests pass (mock Test Lab matrix results)
- Documentation: PR body includes the gcloud invocation + expected matrix config so the orchestrator can verify wire shape

### Commit + PR

- Commit: `Wave 2 Q-2c: Firebase Test Lab integration for mobile push delivery`
- Branch: `claude2/q-2c-firebase-test-lab-push`
- PR title: `Wave 2 Q-2c: Firebase Test Lab integration for mobile push delivery`
- Base: `master`.

---

## Slice 5 — W-6-backend: proxy handler for PATCH /v1/operator/location-timezone

### Origin

W-6 (PR #682, merged) shipped the operator-web Account screen's Location timezone section + frontend wire contract. The proxy backend handler was explicitly parked. This slice closes that.

### What ships

1. **Proxy route.** `PATCH /v1/operator/location-timezone` accepting `{location_id, iana_timezone, reason}`. Operator-scoped, idempotent.
2. **Sibling file.** New `tool/advisor_proxy/operator_location_timezone_routes.dart` (do NOT touch `advisor_proxy.dart` — it's at ceiling). Mirror W-5's `business_logo_upload_routes.dart` pattern.
3. **Repository extension.** Add `LocationsRepository.updateLocationTimezone(operatorId, locationId, ianaTimezone, adminReason)` if it doesn't exist (check `lib/infrastructure/persistence/postgres/repositories/locations_repository.dart`).
4. **Permission gate.** Use the existing operator-admin / operator-owner write gate. Do NOT introduce a new permission key. Verify with `grep -rE "team\\.locations" lib/auth tool/advisor_proxy/`.
5. **Audit row.** Emit `operator_location_timezone_updated` with `previous_tz` + `new_tz` + reason.
6. **Idempotency.** Standard `OperatorWriteIdempotencyCache` path. Mirror W-5's idempotency posture.
7. **Validation.** Server-side validates IANA timezone using `package:timezone` or a pinned list of supported timezones (consult `lib/operator_web/screens/account_screen.dart` for the 14-option shortlist).
8. **Demo gateway parity.** HP #2 — the demo path must also work. Verify `lib/operator_web/services/demo_*account*.dart` (or wherever the demo account gateway lives) responds correctly.

### Authority anchors

- `lib/operator_web/screens/account_screen.dart` — W-6's frontend.
- `lib/operator_web/services/web_account_gateway.dart` — W-6's gateway with the wire contract pinned.
- `tool/advisor_proxy/business_logo_upload_routes.dart` — sibling-file pattern from W-5.
- `tool/advisor_proxy/operator_routes.dart` — extending `OperatorWriteRouter` with the new dispatch.
- `tool/advisor_proxy/proxy_bootstrap.dart` — production wiring.
- `lib/infrastructure/persistence/postgres/repositories/locations_repository.dart` — extending the repo.

### Constraints

- Proxy-touching — but operator has standing autonomy on proxy slices for this wave.
- HP #4 — operator-scoped read + write. RLS already in place on `locations` table.
- DO NOT raise `kAdvisorProxyMaxLines`. Sibling-file pattern.
- DO NOT widen permission gates.
- DO NOT touch trackers / ledger / audit docs.
- Time guardrails — IANA timezone is a TEXT column; verify the migration that added it (`db/migrations/202605070000_phase_11W_7_operator_account_fields.sql` per W-6's notes).

### Verification

- `dart analyze --fatal-infos lib/ tool/advisor_proxy/` — clean
- `flutter test test/proxy/operator_location_timezone_routes_test.dart` — new tests (happy path, validation failure, 403 wrong-permission, idempotency replay)
- `flutter test test/proxy/` — full proxy suite green
- `dart run tool/advisor_proxy_size_lint.dart` — must stay at ceiling or below
- `flutter test test/operator_web/services/web_account_gateway_test.dart` — W-6's existing gateway tests still pass (they exercised the wire shape against a mock; now they hit a real route)

### Commit + PR

- Commit: `Wave 2 W-6-backend: proxy handler for PATCH /v1/operator/location-timezone`
- Branch: `claude2/w-6-backend-location-timezone`
- PR title: `Wave 2 W-6-backend: proxy handler for PATCH /v1/operator/location-timezone`
- Base: `master`.

---

## Worker contract (recap)

- Branch → implement → self-audit → commit + push → open PR → STOP.
- No merge. No amend. No `--no-verify`. No tracker edits.
- Pattern B audit table in every PR body, with file:line citations.
- Orchestrator audits + merges.

## Pick order (suggestion)

1. **Q-2b** first — mobile UX testing, perfect fit for Claude #2's lane skills, no schema impact.
2. **W-6-backend** second — small well-defined backend slice with the wire contract already pinned. Lower risk than Q-2c's cloud-device matrix.
3. **Q-2c** third — Firebase Test Lab matrix needs the most external infrastructure setup; pick this when you have time to dig in.

But the slices are independent — pick any order.
