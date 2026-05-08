# Firebase Console — Mobile Push Apply Runbook

Operator-driven. ~15 minute total operator time across the Firebase Console
+ Apple Developer + GCP Cloud Run consoles. No engineering involvement
required.

This runbook is the LAST step before the V1 push notification proof. The
code, migration, mobile runtime, proxy dispatcher, IAM-aware service-account
auth path, and per-flavor Firebase config files are all already on master.
What's missing is two env vars on the proxy Cloud Run revision, one IAM
binding, one APNs auth key upload, and one test push.

## Purpose

- Bring mobile push notifications live on `forge-flow-production1`.
- Unlock the V1 push proof checkbox (the only remaining engineering-side
  push gate beyond live-vendor proof and lawyer T&Cs).

## What this DOES NOT change

- No mobile core app logic changes.
- No new migration applies (the push migration shipped 2026-05-06 and
  is in the staging-verified set per
  `runbooks/phase_9_production1_migration_apply_runbook.md`).
- No new code on master.
- The V1 launch sequence does not change. This is independent of the
  trio sandbox proof and the Firebase Auth DNS switch.

## Preconditions (operator-side)

1. Operator has `Owner` or `Editor` role on the `forge-flow-production1`
   GCP project.
2. Operator has `App Manager` role on the `feflow.org` Apple Developer
   team (only needed for the iOS APNs auth key step).
3. The mobile push migration `db/migrations/202605060000_mobile_push_notifications.sql`
   is applied to production1. Verify with:
   ```
   psql ... -c "select push_token_id from public.mobile_push_tokens limit 1;"
   ```
   A clean `0 rows` response means the table exists and is empty (good).
   A `relation does not exist` error means the migration has not been
   applied — apply it via `runbooks/phase_9_production1_migration_apply_runbook.md`
   first.
4. The proxy Cloud Run revision is on a build that includes commit
   `02a8334f` or later (post-Doc-1 close). Verify by checking the
   deploy log for `firebase_project_id_loaded: false` (the value will
   flip to `true` after step 4 of this runbook).

## Pinned facts (verified on master 2026-05-08)

- iOS bundle ID (ForgeFlow flavor): `com.forgeflow.app`
- iOS bundle ID (Barrio flavor): `com.forgeflow.barrio`
- Android package (ForgeFlow flavor): `com.forgeflow.app`
- Android package (Barrio flavor): `com.forgeflow.barrio`
- iOS Firebase config files already in repo: `ios/Runner/Firebase/GoogleService-Info-ForgeFlow.plist`, `GoogleService-Info-Barrio.plist`
- Android Firebase config files already in repo: `android/app/src/forgeflow/google-services.json`, `src/barrio/google-services.json`
- Proxy env-var names this runbook touches:
  - `FIREBASE_PROJECT_ID` (required; non-secret; the GCP project the Firebase project belongs to)
  - `MOBILE_PUSH_TOKEN_ENVELOPE_KEY` (required; pgcrypto envelope key for token at-rest encryption)

## Steps

### 1. Confirm the Firebase project exists

- Open https://console.firebase.google.com/project/forge-flow-production1
- **You'll know it worked when** the Project Overview page loads with the
  project name `forge-flow-production1` in the header.
- If the project does not exist, create it as a Firebase project sitting
  on top of the `forge-flow-production1` GCP project. Do NOT create a new
  GCP project.

### 2. Confirm both apps are registered in Firebase

- Project Overview → Project Settings → General → "Your apps" section.
- Verify there is one Android app row with package `com.forgeflow.app`
  and one iOS app row with bundle `com.forgeflow.app`. Repeat for the
  Barrio variants if Barrio is being unlocked at the same time.
- If any app is missing, click "Add app", select the platform, paste the
  exact package/bundle from the pinned-facts list above, and accept the
  defaults. Skip the "Download config file" step here — the configs are
  already in the repo.
- **You'll know it worked when** the Apps list shows green checkmarks
  for each registered app.

### 3. Enable Firebase Cloud Messaging (FCM) HTTP v1 API

- Project Settings → Cloud Messaging tab.
- Confirm "Firebase Cloud Messaging API (V1)" is **Enabled**. If the
  panel says "Disabled" with a "Manage API in Google Cloud Console"
  button, click it, then click "Enable" on the GCP page.
- **You'll know it worked when** the Cloud Messaging tab shows the V1
  API as enabled.

### 4. Set the Cloud Run env vars

Open https://console.cloud.google.com/run for the `forge-flow-production1`
project. Find the proxy service (likely `forge-flow-proxy` or similar).

- Click "Edit & Deploy New Revision".
- Under "Variables & Secrets", add or update:
  - Name: `FIREBASE_PROJECT_ID`, Value: `forge-flow-production1`
  - Name: `MOBILE_PUSH_TOKEN_ENVELOPE_KEY`, Value: a 32+ character
    random string (generate with `openssl rand -base64 48` locally;
    keep it in your password manager — this is a long-lived envelope
    key for at-rest token encryption).
- Click "Deploy".
- **You'll know it worked when** the new revision boots and the deploy
  log shows `firebase_project_id_loaded: true` (search for that exact
  string).

### 5. Grant the Cloud Run service account FCM publish permission

The proxy uses the Cloud Run metadata server for auth — meaning whichever
service account the Cloud Run service runs as, that account needs FCM send
permission. NO key file to download or upload.

- Cloud Run service detail page → "Security" tab → note the service
  account email (e.g., `forge-flow-proxy@forge-flow-production1.iam.gserviceaccount.com`).
- Open https://console.firebase.google.com/project/forge-flow-production1/settings/iam
- Confirm that service account has the `Firebase Admin SDK Administrator
  Service Agent` role OR specifically the `cloudmessaging.messages.create`
  permission (a custom role works too).
- If not, add it: "Add member", paste the service account email, choose
  the role above.
- **You'll know it worked when** the IAM table shows the service account
  with the FCM send permission.

### 6. Generate and upload the iOS APNs auth key (iOS push only)

If V1 is Android-only at launch, **skip this step** — Android push works
without APNs.

- Open https://developer.apple.com/account → Certificates, Identifiers &
  Profiles → Keys → click "+".
- Select "Apple Push Notifications service (APNs)". Name it
  `Forge & Flow APNs`. Click Continue → Register.
- Download the `.p8` file. **Save it somewhere private** — Apple only
  lets you download once.
- Note the **Key ID** (10-char string) and your **Team ID** (10-char
  string under Membership).
- Back in Firebase Console → Project Settings → Cloud Messaging tab →
  "Apple app configuration" section → click "Upload" next to "APNs
  Authentication Key".
- Upload the `.p8`, paste the Key ID, paste the Team ID. Click Upload.
- **You'll know it worked when** the Apple app configuration row shows
  the uploaded key with its Key ID.
- Repeat for Barrio if needed.

### 7. Smoke test from the Firebase Console

- On a test device (real Android phone, real iPhone, or Android emulator
  with Google Play services), install the latest staging or production
  build of the Forge & Flow app.
- Sign in with a test operator account.
- Accept the runtime notification permission prompt.
- The app's first foreground render registers an FCM token; the proxy
  logs `push_subscription_registered` with the encrypted token hash.
- In Firebase Console → Cloud Messaging → "Send your first message"
  (or "New campaign" → "Notifications").
- Title: `V1 push proof`. Body: `Test from Firebase Console`. Click
  "Send test message". Paste the FCM token from the proxy log. Click
  "Test".
- **You'll know it worked when** the device displays the notification
  within ~5 seconds (foreground: in-app banner via `flutter_local_notifications`;
  background: system tray).

### 8. (Optional) Repeat for production if step 7 was on staging

If you ran step 7 against `forge-flow-staging`, repeat steps 4–7 against
`forge-flow-production1`. Use a fresh `MOBILE_PUSH_TOKEN_ENVELOPE_KEY` —
do not reuse staging keys in production.

## Rollback

If push notifications are causing issues:

- Cloud Run revision: remove `FIREBASE_PROJECT_ID` from the env vars and
  redeploy. The proxy will boot with `firebase_project_id_loaded: false`
  and skip the FCM dispatcher entirely. Mobile clients still register
  FCM tokens (the registration route does not depend on the dispatcher);
  no server → device pushes get dispatched.
- For a deeper rollback, deploy the previous proxy revision (the one
  that was running before step 4).
- Mobile app changes are not needed for rollback — the mobile runtime
  no-ops gracefully when the server is unavailable.

## Evidence to record

For the V1 launch evidence pack:

- Firebase project ID + Cloud Run revision SHA + deploy timestamp.
- Cloud Run service account email + the IAM role granted.
- APNs Key ID (NOT the `.p8` contents).
- One screenshot of a successful test push received on the device
  (no PII visible).
- One Cloud Logging snapshot showing `push_subscription_registered`
  followed by `mobile_push.dispatch.success`.

## What this runbook does NOT cover

- Sending pushes to operator devices automatically based on app events
  (covered separately by `tool/advisor_proxy/email_dispatch/notification_event_fanout.dart`
  — already wired; turns on when a `mobile_push_outbox` row is created
  by an event handler).
- Quiet hours / per-user push preference UX (already exists in
  operator-web Settings → Notifications).
- iOS Critical Alert entitlement (V1 does not use Critical Alerts).

## Cross-references

- `docs/_execution/2026-05-07_mobile_push_preflight_proof.md` — the
  code/config preflight (already done; this runbook closes the
  remaining operator-side gates).
- `docs/_execution/2026-05-06_mobile_push_notifications_plan.md` — the
  source plan.
- `runbooks/phase_9_production1_migration_apply_runbook.md` — apply
  the push migration to production1 if step 3 of preconditions fails.
- `runbooks/cloud_run_env_vars.md` — full env-var inventory.
- `runbooks/admin_provider_credentials_kms_rollout_runbook.md` — pattern
  reference for operator-driven runbooks (this one follows the same
  structure).
