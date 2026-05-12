# r4 — Email + Notification Testing Patterns

**Audience:** Post-Codex wave planners deciding how to deep-pressure-test every email + push scenario, including loopback flows (email arrives → click → land in app/console → action executed).
**Stack we are pressure-testing:** Flutter mobile (Android + iOS) + Flutter Web admin (F&F Ops Console) + Flutter Web operator (`app.forgeflow.app`) + Dart proxy (Cloud Run) + Firebase Auth (action links, MFA) + SendGrid (transactional, event webhook, optional Inbound Parse) + FCM (mobile push, optional APNs cert path).
**Pre-read context (planned, not yet on disk):** `docs/_decisions/post_codex_wave_decisions_2026-05-12.md` was referenced in the brief but is not committed; this brief is written from the existing surfaces below.

## Existing surfaces (so each pattern can be aimed precisely)

- Email send seam: `lib/services/email/email_provider.dart`, `lib/services/email/sendgrid_email_provider.dart`, `lib/services/email/email_template_renderer.dart`, `lib/services/email/email_outbox_dispatcher.dart` (3-strike retry, dead-letter on auth/bad-request/protocol/render).
- Email durable queue: `db/migrations/202605040200_phase_9_8_email_provider.sql` (`email_outbox`, `email_event`, `email_credentials`, `email_outbox_tick()` + `pg_cron`).
- Email admin route + walkthrough: `tool/advisor_proxy/admin_email_routes.dart`, `docs/_walkthroughs/9.8.email.md`, `docs/phases/phase_9_8/phase_9_8_email_provider_slice.md`.
- Notification durable model: `lib/domain/models/app_notification.dart`, `lib/domain/repositories/app_notification_repository.dart`, `lib/services/app_notification_service.dart`, `lib/screens/notifications_screen.dart`.
- Notification preferences: `lib/operator_web/screens/settings_notifications_screen.dart`, `lib/infrastructure/persistence/postgres/repositories/notification_preferences_repository.dart`, `tool/advisor_proxy/notification_preferences_routes.dart`, `db/migrations/202605070400_phase_8_notification_preferences.sql`.
- Notification fanout/hooks (event → outbox → email): `tool/advisor_proxy/email_dispatch/notification_event_fanout.dart`, `tool/advisor_proxy/email_dispatch/notification_event_hooks.dart`, `tool/advisor_proxy/email_dispatch/vendor_lifecycle_notification_dispatcher.dart`.
- Mobile push (FCM/APNs): `lib/services/mobile_push/mobile_push_notification_service.dart`, `tool/advisor_proxy/mobile_push_notifications.dart`, `db/migrations/202605060000_mobile_push_notifications.sql`, `docs/_execution/2026-05-06_mobile_push_notifications_plan.md`, `infrastructure/monitoring/alerts/fcm_delivery_failure_spike.yaml`.
- Firebase Auth action-link landing pages: `web/auth/action/index.html`, `lib/screens/auth/password_reset_deep_link_handler.dart`, `lib/services/auth/password_reset_deep_link_source.dart`, `lib/services/auth/firebase_admin_auth_client.dart`, `scripts/configure_firebase_auth_email_action_url.ps1`.
- Smoke + dispatcher tests already in tree: `test/services/email/sendgrid_email_provider_test.dart`, `test/services/email/notification_event_fanout_test.dart`, `test/services/app_notification_service_push_delivery_test.dart`, `test/mobile_push_notification_service_test.dart`, `test/web_auth_action_page_test.dart`.

The patterns below all bolt onto these seams; we do not need to invent new abstractions to pressure-test them.

---

## 1) Flutter notification testing on real Android / iOS devices

Native push interaction is the canonical gap in Flutter's `integration_test` package: it cannot drive permission dialogs, the OS notification shade, deep-link taps from a terminated app, or the lock-screen banner. Every option below addresses that gap differently.

### Pattern 1A — Patrol + Firebase Test Lab (recommended primary)

- **What it is.** Patrol (`pub.dev/packages/patrol`, LeanCode) wraps `flutter_test` + `integration_test` with a native-automation bridge that drives Android UI Automator and iOS XCUITest from Dart. It can open the notification shade, tap a specific banner, accept the `POST_NOTIFICATIONS` permission, and bring the app back from terminated. Patrol tests build to a normal AndroidTest APK / iOS XCTest bundle, so Firebase Test Lab runs them natively — no special FTL config beyond pointing at the test artifact.
- **Loopback fit.** Patrol's `nativeAutomator.openNotifications()` + `tapOnNotification(byText: ...)` is exactly the loopback handoff we need for the "FCM banner → tap → land on Notifications screen → mark read → bell badge drops" scenario.
- **Applicability to F&F.** Drops in next to existing `mobile_push_notification_service_test.dart`. We already build APKs for staging; Patrol adds a separate test artifact, not a runtime dependency.
- **Cost.** Patrol open-source. Firebase Test Lab: ~$1/device-hour for physical devices, free virtual-device tier (1 hr/day) — a 20-device matrix smoke (~5 min each) is ~$1.50/run. Real ceiling is engineer time to add Patrol harness (~3–5 day setup including CI wiring).

### Pattern 1B — Patrol + BrowserStack App Live / App Automate (alternative breadth)

- **What it is.** Same Patrol artifact, but pushed to BrowserStack's device cloud (2,000+ iOS, 2,500+ Android). Better for breadth-of-OS / breadth-of-vendor coverage; weaker than FTL for tight Firebase project binding (you still upload your own google-services config).
- **Applicability.** Useful when we need to prove APNs banners on a real iPhone with carrier networking before the App Store submission. FTL's iOS coverage is narrower.
- **Cost.** Automate Mobile starts $129/mo per parallel slot; a 5-parallel plan ~$650/mo. Per-minute billing not advertised; expect 2–3× FTL cost at equivalent breadth.

### Pattern 1C — AWS Device Farm / Sauce Labs (enterprise alternatives)

- **AWS Device Farm.** $0.17/device-minute or $250/mo per unlimited slot. CodePipeline / CodeBuild native — useful if F&F ever moves CI off GitHub Actions. Patrol runs but Device Farm's reporting on Flutter is thinner than FTL.
- **Sauce Labs.** Strong Espresso/XCUITest pedigree, but pricing is 2–3× BrowserStack at parity (rough quote: $80k–$120k/yr for 100 parallel sessions). Overkill for V1.

### Tradeoffs at a glance

| | Native automation? | Push banner tap? | Cost @ V1 scale | Flutter docs |
|---|---|---|---|---|
| `integration_test` only | No | No | Free | First-party but blind to OS |
| Patrol + FTL | Yes | Yes | ~$50–$200/mo + setup | Strong |
| Patrol + BrowserStack | Yes | Yes | ~$650/mo+ | Strong |
| AWS Device Farm | Yes (via Patrol) | Yes | Pay-per-minute, can spike | Adequate |
| Sauce Labs | Yes (via Patrol) | Yes | $$$$ | Adequate |

**Recommendation.** Patrol harness + Firebase Test Lab as the daily smoke, plus a BrowserStack monthly broad-matrix run before each app-store submission.

---

## 2) Firebase Auth action-link verification harness

Firebase Auth password reset, email verification, and email-link MFA all flow through the same OOB (Out-of-Band) code mechanism: Firebase generates a link of the shape `https://<authDomain>/__/auth/action?mode=resetPassword&oobCode=<code>&apiKey=...&continueUrl=...`, the user clicks, and the landing page calls `confirmPasswordReset(oobCode, newPassword)` / `applyActionCode(oobCode)`. The whole flow is testable end-to-end without a human inbox.

### Pattern 2A — Admin SDK link generation, no email send (recommended primary unit/integration)

- **Mechanism.** Firebase Admin SDK exposes `generatePasswordResetLink(email, actionCodeSettings)` and `generateEmailVerificationLink(email, ...)`. These return the fully-formed action URL *without* sending an email — Firebase doesn't even need SendGrid in the loop.
- **Harness shape.** Test starts an ephemeral Firebase Auth user (or reuses a fixture user), calls the Admin SDK to mint a link, parses `oobCode` from the URL, then either: (a) hits our own `web/auth/action/index.html` headlessly via Playwright with the fresh `oobCode` query param, or (b) calls `confirmPasswordReset(oobCode, newPassword)` directly against the Firebase Auth REST API. Either way we assert the user can sign in with the new password afterwards and that the `auth_events_audit` row landed.
- **Applicability.** Already isomorphic to `lib/services/auth/firebase_admin_auth_client.dart`. The same Admin SDK we use to invite users can mint reset links. No new infra.
- **Cost.** Free (within Firebase Auth quotas). Engineer time: ~1 day to wire a Dart test that exercises `generatePasswordResetLink` + asserts the landing page accepts the code.

### Pattern 2B — Firebase Local Emulator Suite for fast iteration

- **Mechanism.** The Firebase Auth emulator (`firebase emulators:start --only auth`) accepts the same Admin SDK calls and prints the generated link to stdout. `oobCode` is parsed off the local URL `http://127.0.0.1:9099/emulator/action?...`. Tests run fully offline.
- **Loopback fit.** Excellent for CI: no quota cost, no risk of bouncing real domains, parallelizable.
- **Caveat.** Emulator does not enforce reCAPTCHA Enterprise; our `recaptcha_v3_verifier.dart` path must be stubbed in emulator mode.
- **Cost.** Free.

### Pattern 2C — Real email path with Mailosaur capture (loopback E2E)

- **Mechanism.** Configure Firebase Auth's "Customize action URL" + "From address" to route through our SendGrid sending domain. Send the reset email to a Mailosaur address (one per test). Playwright then `messages.get()` the email, extracts `message.html.links[0].href`, navigates a real browser to the action URL, fills the new password form, asserts redirect to `app.forgeflow.app/login`.
- **When to use.** Production-cutover gate, not every-commit gate. Catches problems Pattern 2A/2B can't: template rendering, link wrapping by SendGrid, CSP issues on `web/auth/action/index.html`.
- **Cost.** Mailosaur pricing (see §5). One real-mailbox round-trip per E2E run.

### MFA-specific note

Firebase Auth multi-factor verification uses SMS (Twilio) or TOTP, not email links — so the action-link harness above does not cover MFA challenge codes. For MFA loopback, use Twilio's test credentials (free; deterministic codes) or Mailosaur's SMS module ($) if we extend to email-OTP. The 2FA-with-Playwright Mailosaur pattern is well-documented and maps directly to our `mfa_test.dart`.

---

## 3) Bell-badge invalidation cross-device

Today the bell badge in `lib/screens/notifications_screen.dart` reads from `SqliteAppNotificationRepository`, which is hydrated by FCM payloads + a periodic refresh against the proxy. The question is: when user marks read on device A, how fast does device B's bell drop? Three architectural options, each with a test pattern.

### Pattern 3A — FCM data-only fanout to user-scoped topic (status quo direction)

- **Mechanism.** Mark-read mutation hits proxy → proxy writes `app_notifications.read_at` + enqueues a silent FCM `data` payload (no `notification` block, `content_available: true`) to user-scoped topic `user_<uuid>_notifications`. Each device receives, applies the read state to its local SQLite cache, recomputes badge.
- **Latency.** FCM topics are throughput-optimized, not latency-optimized — Google's own docs warn against topics for fast small-fanout cases. Empirically: median ~5–15 s, p95 30–60 s on cellular; iOS background data messages can be coalesced by APNs.
- **Test pattern.** Two Patrol-driven devices, mark read on A, poll device B's bell with `nativeAutomator` and assert badge transitions within a tolerance (e.g., 30 s). For unit-level: assert `MobilePushNotificationService.onSilentDataMessage` clears the relevant row.
- **Cost.** Free. Already on the FCM bill we pay.

### Pattern 3B — Device-token fanout (lower latency than topic)

- **Mechanism.** Maintain `mobile_push_tokens` (we already do — `MobilePushTokensRepository`). On mark-read, proxy fans out one FCM `send` per active token for that user. Bypasses topic-throughput throttle.
- **Latency.** Typically 1–5 s for online devices. Documented Google guidance: "For fast, secure delivery to single devices or small groups, target messages to registration tokens instead of topics."
- **Test pattern.** Stub `MobilePushOutboxRepository` in unit, assert N pushes enqueued for N active tokens. Real-device Patrol test: same as 3A but with sub-5-s assertion.
- **Cost.** Slightly more FCM API calls per mark-read; well within free tier.

### Pattern 3C — Server-sent events / WebSocket from proxy (Web only)

- **Mechanism.** For `app.forgeflow.app` and the F&F Ops Console (Flutter Web), there is no FCM-equivalent reliable background channel. Open an SSE or WebSocket from the Flutter Web client to a proxy `/v1/operator/notifications/stream` route; proxy listens to a Postgres LISTEN/NOTIFY on the same `app_notification.created` / `app_notification.read` channel that the mobile outbox listener (`outbox_notification_listener.dart`) uses.
- **Latency.** Sub-second once connection is up.
- **Test pattern.** Playwright opens two browser contexts (= two operator sessions); mark read in context A; assert badge in context B updates within 2 s. Server-side: existing `outbox_notification_listener.dart` test pattern can be extended with a fake SSE consumer.
- **Cost.** One extra Cloud Run instance keeping SSE connections warm. For a few hundred concurrent operator sessions: ~$30–80/mo.

### Pattern 3D — Polling fallback (already partially present)

- **Mechanism.** Periodic `GET /v1/operator/notifications?since=<ts>` from each client. Latency = polling interval (today: ~30 s on visible app).
- **Test pattern.** Trivial — fake the clock, assert poll fires, assert badge updates. Test value: regression coverage for the fallback when FCM/SSE is down.

**Recommendation.** Pattern 3B for mobile + Pattern 3C for the two Flutter Web surfaces. Pattern 3D as the floor. Patrol two-device test pinned at ≤5 s for 3B and Playwright two-context test pinned at ≤2 s for 3C, both as nightly gates not per-commit (real-device timing is flaky on shared CI).

---

## 4) Push delivery proof harnesses

"Proof that a push reached the device" is genuinely hard because FCM's 200 OK only means "FCM accepted the message," not "the device displayed it." The harness needs to combine three signals.

### Pattern 4A — FCM `delivery_receipt_requested` + BigQuery export (server-side proof)

- **Mechanism.** Set `apns.headers.apns-priority=10` and the FCM v1 `delivery_receipt_requested: true` flag on outbound sends. Enable FCM → BigQuery export for the project. Per Google's "Understanding message delivery" docs, receipts populate the BigQuery table when the SDK is 18.0.1+ on Android. The proxy reads back the receipt and writes it to a new `mobile_push_receipt` column (or onto `event_outbox`).
- **Caveat.** BigQuery export is the path for delivery telemetry; receipts surface there, not via FCM HTTP response.
- **Applicability.** Wire into `mobile_push_outbox_repository.dart` — we already track `attempt_count` + `last_error`; add a `delivered_at` from BigQuery polling.
- **Cost.** BigQuery storage: pennies. Query cost on a per-receipt-poll job: <$5/mo at V1 volumes.

### Pattern 4B — App-level read-receipt ack (client-confirmed proof)

- **Mechanism.** On FCM `onMessage` / `onMessageOpenedApp`, the Flutter app immediately fires `POST /v1/mobile/push/ack` with `{notification_id, received_at, displayed: true}`. Proxy stores the ack on `app_notification.delivered_at`. This is the "real" delivery proof — we know the user's device actually rendered it.
- **Caveat.** Doesn't fire if the user never opens the notification shade (silent-data messages excepted). Best paired with 4A.
- **Test pattern.** Unit: `MobilePushNotificationService` test verifying ack POST shape. E2E: Patrol test that asserts ack lands in the proxy within N seconds of the FCM send.
- **Cost.** One extra proxy route + one DB column. Minimal.

### Pattern 4C — Synthetic canary device (continuous proof)

- **Mechanism.** A dedicated physical or emulated device on a CI box (or rented BrowserStack persistent device) logged into a `canary@forgeflow.app` operator. A cron worker enqueues one canary push per minute through the real production path; the canary app acks back. Alert (already partially in place: `infrastructure/monitoring/alerts/fcm_delivery_failure_spike.yaml`) fires when ack-rate drops.
- **Cost.** One BrowserStack persistent device slot (~$25–40/mo) or a Pixel-on-a-desk in the office ($0 capex if reused). Best-in-class signal for FCM regional outages.

**Recommendation.** Combine 4A + 4B as the production-default; add 4C before V1 launch as the synthetic SLO probe.

---

## 5) Email send-receive verification with SendGrid

Two parallel channels. The **send-side** is SendGrid's Event Webhook, which streams delivered/opened/clicked/bounced/dropped/spam events back to us. The **receive-side** is either SendGrid Inbound Parse or an ephemeral-inbox provider (Mailosaur / Mailtrap / Mailpit).

### Pattern 5A — SendGrid Event Webhook → `email_event` (send-side; already partially built)

- **Mechanism.** SendGrid POSTs JSON batches to a webhook URL we own (e.g., `https://proxy.forgeflow.app/v1/webhooks/sendgrid/events`). Events: `processed`, `delivered`, `open`, `click`, `bounce`, `deferred`, `dropped`, `spamreport`, `unsubscribe`, `group_unsubscribe`, `group_resubscribe`. ECDSA signature header (`X-Twilio-Email-Event-Webhook-Signature`) cryptographically proves origin.
- **Applicability.** Migration `202605040200_phase_9_8_email_provider.sql` already includes the `email_event` table. The webhook receiver route is the wiring still to land.
- **Test verification.** SendGrid Event Webhook UI has a "Test Your Integration" button that fires a fake POST for selected event types — perfect for happy-path smoke. For pressure tests, replay captured payloads (a Hooklistener / ngrok recording of real production events) against the proxy in CI.
- **Cost.** Free (included with any SendGrid plan).

### Pattern 5B — Ephemeral inbox capture (receive-side, recommended primary E2E)

- **Mailosaur.** Purpose-built for E2E. Unique inbox per test, REST + SDK to fetch latest message, automatic link extraction (`message.html.links`), CI/CD integrations for Playwright / Cypress / Selenium. Free trial, then ~$90/mo entry; enterprise tiers higher.
- **Mailtrap.** Sandbox inbox for staging (no email leaves SendGrid sandbox); separately a real-sending product. Sandbox is sufficient for content/template QA; for loopback (real click → real landing page) Mailtrap requires the higher-tier sandbox or its sending arm. Pricing tiers ranging from free → ~$85/mo business.
- **Mailpit.** Open-source self-hosted Docker container. Captures SMTP locally — no internet dep. SpamAssassin scoring, link verification, REST API, POP3. Free. Limitation: no cloud webhook delivery — only works for local-dev / CI inside the same network. Cannot replace Mailosaur for verifying real SendGrid → real internet → inbox flows.

**Recommendation.** Mailpit for local-dev `firebase emulators` work + CI happy-path. Mailosaur for the loopback / pre-prod gate that proves SendGrid → real DNS → action link → landing page.

### Pattern 5C — SendGrid Inbound Parse (test-mailbox you control end-to-end)

- **Mechanism.** Configure DNS MX records on a subdomain you own (e.g., `inbox.testing.forgeflow.app`) to point at `mx.sendgrid.net`. Set Inbound Parse hostname + webhook URL. Every email to `<anything>@inbox.testing.forgeflow.app` is POSTed as multipart/form-data to the webhook (headers, text, html, attachments, envelope). Park the parsed message in a `test_inbox` table; CI polls `GET /v1/test-inbox/latest?to=<addr>`.
- **Applicability.** Replaces Mailosaur with $0 marginal cost and total data control, at the price of building the auto-mailbox service ourselves (~3 day build; a known reference is `github.com/PowelAS/auto-mailbox`).
- **Cost.** Effectively free (SendGrid Inbound Parse is included). Engineer time to operate the service is the real cost.

**Recommendation.** Mailosaur for V1 (~$90/mo buys speed-to-coverage; the inbox-per-test pattern is exactly the loopback shape we need). Revisit SendGrid Inbound Parse self-host if testing volume exceeds Mailosaur's mid-tier limits.

---

## 6) Test data isolation per operator

The pain we want to avoid: two parallel CI lanes both invite "Said" via two different operators, both invites land in the same `qa@forgeflow.app` Gmail, tests race and flake. Three approaches, increasing in isolation strength.

### Pattern 6A — Mailbox-per-test (recommended primary)

- **Mechanism.** Each test generates a unique inbox address. With Mailosaur: every server has unlimited unique inboxes (`anything.<serverId>@mailosaur.net` or your own verified domain). With SendGrid Inbound Parse: `<random-uuid>@inbox.testing.forgeflow.app`. Each operator under test gets a fresh email per invite test; no crosstalk possible.
- **Applicability.** Drops in next to existing `invited_user_activation_ledger_writer.dart` + `members_admin_screen.dart`.
- **Cost.** Mailosaur tier (above), or $0 with Inbound Parse self-host.

### Pattern 6B — Test-only operator IDs scoped on a dedicated DB

- **Mechanism.** A separate `forgeflow_test_*` Postgres database (or schema), seeded with `test_operator_001..N`. Each parallel CI lane reserves an ID via a CI mutex (or a `pg_advisory_lock` pattern keyed off the lane name). All FCM tokens / SendGrid `custom_args.operator_id` carry that ID. RLS prevents bleed.
- **Applicability.** Aligns with HP #4 (per-operator isolation) and our existing `OperatorScopedRepository<T>` primary defense. The Phase 9 scalability decisions already mandate `pg_partman` per-operator/day partitioning, which gives us a free reset boundary.
- **Cost.** One additional small Flexible Server (~$50/mo) or a schema-isolated tier-down of an existing instance (free).

### Pattern 6C — Per-operator email subdomain (strongest, most expensive)

- **Mechanism.** Each test operator gets a real sending subdomain (`acme.mail.forgeflow.app`, `barrio.mail.forgeflow.app`, ...). SendGrid Domain Authentication on every subdomain. Inbound Parse on the matching `inbox.acme.testing.forgeflow.app`. Cross-operator emails can't even hit the same DNS, much less the same inbox.
- **Applicability.** Useful if we ever sell white-labeled domains to operators (project tracker has hooks for this but it's not in V1 lean cut). Premature for the post-Codex wave.
- **Cost.** DNS setup per operator (cheap, but operational chore). SendGrid charges per authenticated domain on some plans.

**Recommendation.** Pattern 6A as the operational default. Pattern 6B already implied by HP #4 — just make sure CI lanes never share an operator ID. Pattern 6C deferred.

---

## 7) Loopback scenarios (email → click → app/console → action)

This is the integration the brief hinges on. Three concrete shapes, in increasing fidelity.

### Pattern 7A — Playwright + Mailosaur (recommended primary for Flutter Web)

- **Shape.**
  1. Playwright drives `app.forgeflow.app` to "Forgot password," types `unique-uuid.<server>@mailosaur.net`, submits.
  2. Test awaits `mailosaur.messages.get(serverId, {sentTo: addr})` — Mailosaur SDK waits + parses.
  3. Test reads `message.html.links[0].href` (Firebase Auth action URL).
  4. Playwright navigates a new page to the action URL → lands on `web/auth/action/index.html`.
  5. Playwright fills new password, submits, asserts redirect to `/login`.
  6. Playwright signs in with the new password, asserts the operator console loads.
  7. (Optional) Test asserts `auth_events_audit` row landed via a backend probe.
- **Applicability.** Already aligned with how `web_auth_action_page_test.dart` exercises the landing page; the gap is the inbox round-trip, which Mailosaur + Playwright closes cleanly.
- **Cost.** Mailosaur + Playwright runner time. Suitable for nightly + pre-deploy gates.

### Pattern 7B — Patrol + Mailosaur (loopback into mobile app)

- **Shape.** Same first steps as 7A. Step 4 instead opens the action URL via Patrol's mobile deep-link entry, which exercises `lib/screens/auth/password_reset_deep_link_handler.dart` + `password_reset_deep_link_source.dart`. Assert app navigates to `PasswordResetConfirmScreen` and the audit row lands.
- **Applicability.** Covers the universal-link / app-link path that Flutter Web tests can't hit. Critical for the mobile-first operator flows.
- **Cost.** Patrol harness time (covered in §1) + Mailosaur (covered in §5).

### Pattern 7C — Notification-tap loopback (FCM banner → action)

- **Shape.**
  1. Test enqueues a notification via the proxy (e.g., "Vendor connection auto-disabled").
  2. `app_notification_service.dart` writes the durable row + fans out an FCM push.
  3. Patrol on device A awaits the banner, taps it, asserts navigation to the Notifications screen with the row highlighted.
  4. Test marks read, asserts proxy round-trip, asserts device B (second Patrol session) sees the badge drop within the §3B SLO.
- **Applicability.** Exercises the entire fanout path (`notification_event_fanout.dart` + `notification_event_hooks.dart`) in one go.
- **Cost.** Patrol + two FTL device slots per run (~$2 per run on cellular-equivalent devices).

### Patterns to deprioritize at V1

- **Selenium / WebDriver IO classic stacks.** Workable but our wave is Flutter-heavy; Playwright > Selenium for the Web surfaces, Patrol > anything for mobile. Avoid stack sprawl.
- **Cypress.** Mailosaur supports it, but Cypress can't open a new tab / new origin cleanly, which the Firebase action URL flow requires (it redirects through `*.firebaseapp.com`). Use Playwright.

---

## Wave budget summary (rough order-of-magnitude, monthly)

| Capability | Tool | $ / mo | Setup days |
|---|---|---|---|
| Native mobile automation | Patrol (OSS) | 0 | 3–5 |
| Device matrix daily | Firebase Test Lab | 50–200 | 1 |
| Device matrix breadth | BrowserStack Automate (optional) | 650+ | 1 |
| Action-link harness | Admin SDK + Auth emulator | 0 | 1–2 |
| Ephemeral inbox | Mailosaur | ~90 | 1 |
| Local SMTP capture | Mailpit (OSS) | 0 | 0.5 |
| SendGrid Event Webhook | Built-in | 0 | 1 (route landing) |
| FCM delivery receipts | BigQuery export + poller | <10 | 1–2 |
| Synthetic canary device | BrowserStack persistent (or owned hw) | 25–40 (or 0) | 1 |
| Total before canary | | ~$200/mo + ~10 eng days | |

This buys: every email + push send proven on real devices + real inboxes + real DNS, every action link verified end-to-end without humans, bell badge cross-device SLO measured continuously, and per-operator isolation guaranteed by inbox-per-test plus per-operator-ID scoping.

---

## Sources

- [BrowserStack — push notification test tools](https://www.browserstack.com/guide/push-notifications-test-tools)
- [Firebase — Integration testing Flutter with Test Lab](https://firebase.google.com/docs/test-lab/flutter/integration-testing-with-flutter)
- [Patrol — Flutter native automation](https://patrol.leancode.co/)
- [Patrol on pub.dev](https://pub.dev/packages/patrol)
- [Firebase — Generating email action links (Admin SDK)](https://firebase.google.com/docs/auth/admin/email-action-links)
- [Firebase — Authenticate with email link (Android)](https://firebase.google.com/docs/auth/android/email-link-auth)
- [Firebase — Custom email action handlers](https://firebase.google.com/docs/auth/custom-email-handler)
- [Firebase — Understanding FCM message delivery](https://firebase.google.com/docs/cloud-messaging/understand-delivery)
- [Firebase — FCM topic messaging](https://firebase.google.com/docs/cloud-messaging/android/topic-messaging)
- [Firebase — Receive messages in Flutter](https://firebase.google.com/docs/cloud-messaging/flutter/receive)
- [Firebase — Firestore real-time queries at scale](https://firebase.google.com/docs/firestore/real-time_queries_at_scale)
- [Firebase blog — Understanding FCM delivery rates on Android](https://firebase.blog/posts/2024/07/understand-fcm-delivery-rates/)
- [SendGrid — Event Webhook reference](https://docs.sendgrid.com/for-developers/tracking-events/event)
- [SendGrid — Inbound Parse Webhook overview](https://www.twilio.com/docs/sendgrid/for-developers/parsing-email/setting-up-the-inbound-parse-webhook)
- [SendGrid — Inbound Parse Webhook payload](https://www.twilio.com/docs/sendgrid/for-developers/parsing-email/inbound-email)
- [SendGrid — Test Event Notification Settings](https://docs.sendgrid.com/api-reference/webhooks/test-event-notification-settings)
- [Mailosaur — Playwright email testing](https://mailosaur.com/docs/frameworks-and-tools/playwright/email-testing)
- [Mailosaur — Automate email verification with Playwright](https://mailosaur.com/blog/playwright-email-verification)
- [Mailosaur — Setting up 2FA testing with Playwright](https://mailosaur.com/blog/automate-2fa-mfa-testing-playwright)
- [Mailosaur vs Mailtrap comparison](https://mailosaur.com/blog/mailosaur-vs-mailtrap)
- [Mailpit review 2026 — local email testing champion](https://medium.com/@doobie-droid/mailpit-review-2026-the-undisputed-champion-of-local-email-testing-faf9ddf522c7)
- [Mailtrap alternatives 2026](https://www.sender.net/blog/mailtrap-alternatives/)
- [MailSlurp — Firebase passwordless auth E2E example](https://www.mailslurp.com/examples/android-test-firebase-passwordless-auth-link/)
- [PowelAS auto-mailbox — SendGrid Inbound Parse test mailbox reference](https://github.com/PowelAS/auto-mailbox)
- [Sentia blog — receiving emails in E2E testing](https://www.sentiatechblog.com/a-better-way-of-receiving-emails-within-end-to-end-testing)
- [Multi-tenancy testing — TestGrid overview](https://testgrid.io/blog/multi-tenancy/)
- [Redis — Data isolation in multi-tenant SaaS](https://redis.io/blog/data-isolation-multi-tenant-saas/)
- [AWS Device Farm pricing](https://www.g2.com/products/aws-device-farm/pricing)
- [BrowserStack vs Sauce Labs 2026 pricing analysis](https://getautonoma.com/blog/browserstack-vs-saucelabs-2026)
- [Mailosaur pricing on G2](https://www.g2.com/products/mailosaur/pricing)
- [Codegenes — FCM message log + delivery debugging](https://www.codegenes.net/blog/firebase-cloud-messaging-message-log/)
