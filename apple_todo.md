# Apple TODO

All Apple-side work that's been deferred. None of this blocks V1 launch
(V1 ships Android-only push). Pick this up whenever an Apple Developer
account exists.

Last updated: 2026-05-08.

## Prerequisites (one-time, gate everything else)

- [ ] **Apple Developer Program enrollment** — $99 USD/year per account.
      Sign up at https://developer.apple.com/programs/. Use the same
      email/Apple ID that owns `feflow.org`'s primary App Store
      identity to avoid future migration pain.
- [ ] **Apple device for testing** — any reasonably-current iPhone or
      iPad (last 4 generations). Required for push delivery proof and
      App Store submission walkthrough; emulator/simulator alone is
      not sufficient because APNs delivery requires real APNs.
- [ ] **macOS machine OR cloud Mac** — Xcode + Fastlane only run on
      macOS. Options: (a) borrow a Mac, (b) MacStadium / MacInCloud
      ($30-60/month), (c) buy a base-model Mac mini.

## Phase 1 — Push Notifications on iOS

The mobile push code, Firebase iOS app registrations, per-flavor
`GoogleService-Info-{ForgeFlow,Barrio}.plist` files, and Cloud Run +
IAM wiring are ALL in place on `forge-flow-production1` already (V1
push setup landed 2026-05-08). What's missing is purely Apple-side.

- [ ] **Create APNs Auth Key** in Apple Developer Console → Certificates,
      Identifiers & Profiles → Keys → "+". Select "Apple Push
      Notifications service (APNs)". Name `Forge & Flow APNs`.
      Download the `.p8` file (Apple only lets you download once).
      Note the **Key ID** (10-char) and your **Team ID** (10-char,
      under Membership).
- [ ] **Upload APNs Auth Key to Firebase** for `forge-flow-production1`:
      Firebase Console → Project Settings → Cloud Messaging →
      "Apple app configuration" → Upload. Repeat for both Forge Flow
      iOS app (`com.forgeflow.app`) and Barrio iOS app
      (`com.forgeflow.barrio`). Same `.p8` works for both — they're
      under the same Apple Team ID.
- [ ] **(Optional) Repeat for `forge-flow-staging`** if you want
      staging iOS push too. Use the same `.p8`. Staging proxy is
      currently blocked on a separate KMS schema issue but the iOS
      Firebase config side is independent.
- [ ] **Validate iOS push delivery** on a real iPhone:
  - Install Forge & Flow iOS build (TestFlight or developer-signed
    direct install).
  - Sign in with a prod operator account.
  - Accept the runtime notification permission prompt.
  - Watch the proxy log for `push_subscription_registered`.
  - Send a test message from Firebase Console → Cloud Messaging →
    "Send test message". Paste the FCM token from the proxy log.
  - Confirm device displays the notification within ~5 seconds
    (foreground: in-app banner; background: system tray).

## Phase 2 — App Store Submission

- [ ] **Create App Store Connect record** for Forge & Flow.
      App name, bundle ID `com.forgeflow.app`, primary language,
      bundle suffix (developer apps), pricing tier (Free).
- [ ] **Create App Store Connect record** for Barrio (separate listing,
      bundle ID `com.forgeflow.barrio`).
- [ ] **iOS Distribution Certificate** — Certificates, Identifiers &
      Profiles → Certificates → "+" → iOS Distribution. Download +
      install in macOS Keychain.
- [ ] **App Store Provisioning Profile** for both bundle IDs.
- [ ] **App Privacy** answers in App Store Connect — "Data Used to
      Track You" / "Data Linked to You" / "Data Not Linked to You".
      Forge & Flow collects: account info, business performance data,
      device identifiers (for push). All "linked to user" / "not used
      for tracking".
- [ ] **App icon assets** — 1024x1024 marketing icon plus the standard
      Apple icon size set. Source designs in `ios/Runner/Assets.xcassets/AppIcon.appiconset/`
      (verify present on master).
- [ ] **Screenshots** — at minimum: 6.7" iPhone, 12.9" iPad. Standard
      flow: Shift, Plan, Variance, Benchmark, Settings. Take from
      production1-pointing build with realistic demo data.
- [ ] **Privacy Policy URL** + **Support URL** + **Marketing URL**.
      Likely `https://feflow.org/privacy`, `/support`, `/`.
- [ ] **Age rating questionnaire** in App Store Connect.
- [ ] **Build with Xcode** + `Archive` + Upload to App Store Connect.
      Or use Codemagic / Bitrise / GitHub Actions macOS runner with
      Fastlane Match.
- [ ] **TestFlight** the build internally first. Once happy, submit
      for App Review.
- [ ] **App Review** typically takes 24-72 hours. Common rejection
      reasons for restaurant tools: missing demo account credentials
      in review notes, missing privacy disclosure, missing third-party
      vendor mention.

## Phase 3 — iOS-specific Code Concerns

These are flagged in the codebase but are no-ops without Apple:

- [ ] **iOS Critical Alert entitlement** — Forge & Flow does NOT use
      Critical Alerts. Confirm `ios/Runner/Runner.entitlements` does
      not include `com.apple.developer.usernotifications.critical-alerts`.
- [ ] **Background fetch / processing** — verify
      `ios/Runner/Info.plist` `UIBackgroundModes` is set correctly
      for: `remote-notification` (push), and any other modes the app
      needs. Should already be in repo; just verify.
- [ ] **App Tracking Transparency (ATT)** — Forge & Flow doesn't
      track across other apps/websites, so ATT prompt should NOT
      appear. Verify `NSUserTrackingUsageDescription` is absent from
      `Info.plist`.
- [ ] **Privacy Manifest (`PrivacyInfo.xcprivacy`)** — Apple now
      requires this file declaring all third-party SDKs and their
      privacy use. Must list Firebase, any analytics SDKs, etc.
      Check current presence in `ios/Runner/`.

## Phase 4 — Optional Apple Things (post-launch)

- [ ] **Sign In with Apple** support if you want to offer it as an
      alternative login. Required by App Review if you offer Google
      / Facebook sign-in (and not just email/password).
- [ ] **iCloud sync** for any operator preferences — almost
      certainly NOT needed; mobile is a cache, not durable owner.
- [ ] **Universal Links** for `feflow.org` deep linking. Useful for
      email-action flows. Requires `apple-app-site-association` JSON
      hosted at `https://feflow.org/.well-known/apple-app-site-association`.
- [ ] **Apple Vision Pro** support — not in scope; Forge & Flow is
      explicitly a phone/tablet floor-manager tool.

## Notes

- **Don't pay $99 until ready to ship iOS.** Apple Developer Program
  starts billing the day you enroll. If iOS is 6 months out, wait.
- **Same `.p8` works across all projects.** Generate once at the
  Apple Team level; upload to every Firebase project (staging + prod
  + any future env) under both bundle IDs (ForgeFlow + Barrio).
- **iOS pushes are silent if Firebase Mgmt API isn't enabled.** It
  is enabled on production1 already (verified 2026-05-08). For
  staging it's also enabled. Future projects will need it enabled.
- **Code is Android-first today.** When iOS push lands, no code
  changes are expected — the existing
  `lib/services/mobile_push/firebase_mobile_push_runtime.dart` is
  platform-agnostic and the iOS Firebase plugin handles APNs
  delivery transparently.

## Cross-references

- `runbooks/firebase_console_push_apply_runbook.md` — operator runbook
  for the Firebase Console + Cloud Run + IAM steps. Step 6 there
  covers the APNs upload at a higher level; this doc is the deeper
  Apple-side queue.
- `docs/_execution/2026-05-05_v1_launch_punchlist.md` — V1 launch
  status. iOS push is recorded as deferred there as of 2026-05-08.
