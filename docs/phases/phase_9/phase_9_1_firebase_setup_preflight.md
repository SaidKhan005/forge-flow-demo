# Phase 9.1 - Firebase Setup Preflight

**Status:** READY FOR 9.1 RUNTIME WIRING; PASSKEYS PARKED AS FUTURE FOLLOW-UP.
**Generated:** 2026-04-26.
**Slice type:** closeout-with-blockers / setup gate for `9.1` Firebase
Identity Platform setup + JWT verifier wiring.

This report supersedes the earlier name/path-only preflight. The live staging
Firebase setup has now been performed and local secrets have been consolidated
under the non-repo `$HOME/.forge_flow/` folder.

## Completed

| Item | State |
| --- | --- |
| Firebase staging project | PRESENT: `forge-flow-staging` |
| Project billing | ENABLED |
| Identity Platform tier | ENABLED: config subtype is `IDENTITY_PLATFORM` |
| Android app `com.forgeflow.app` | REGISTERED |
| Android app `com.forgeflow.barrio` | REGISTERED |
| iOS app `com.forgeflow.app` | REGISTERED |
| iOS app `com.forgeflow.barrio` | REGISTERED |
| Web admin app | REGISTERED as `Forge Flow Admin Web` |
| Authorized domains | `forge-flow-staging.firebaseapp.com`, `forge-flow-staging.web.app`, `admin.forgeflow.app`, `localhost` |
| Email/password sign-in | ENABLED with password required |
| Phone/SMS auth | DISABLED; SMS region policy is empty allowlist |
| TOTP MFA | ENABLED at project level, adjacent intervals `5` |
| Email action callback URI | CONFIGURED: `https://admin.forgeflow.app/__/auth/action` |
| Local Admin SDK JSON | PRESENT outside repo at `$HOME/.forge_flow/firebase-staging-adminsdk.json` |
| Unified local env loader | PRESENT outside repo at `$HOME/.forge_flow/forge_flow.secrets.ps1` |
| Admin SDK service account | PRESENT: `forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com` |
| Admin SDK service account role | `roles/identitytoolkit.admin` |
| Admin SDK service account smoke | PASSED: service account can read Identity Platform config |
| Cloud Run staging proxy | DEPLOYED as `forge-flow-staging-proxy`; prerequisite readiness passed on `/readyz` |
| Android public config | PRESENT at `android/app/src/forgeflow/google-services.json` and `android/app/src/barrio/google-services.json` |
| iOS public config | GENERATED at `ios/Runner/Firebase/GoogleService-Info-ForgeFlow.plist` and `ios/Runner/Firebase/GoogleService-Info-Barrio.plist`; Xcode project wiring still pending |
| Web public config | PRESENT at `web/firebase-config.js` |
| Repo Firebase alias | PRESENT in `.firebaserc` |
| Private key guardrail | `.gitignore` blocks Firebase Admin SDK/service-account JSON patterns |

## Remaining Gaps

| Item | State |
| --- | --- |
| Passkeys / WebAuthn | PARKED. Official Identity Platform docs/config expose TOTP MFA but no first-party passkey/WebAuthn provider surface. User decision 2026-04-26: launch Phase 9 with email/password + TOTP; passkeys are not a launch gate unless official Firebase / Identity Platform support appears before cutover. |
| Email templates | DECISION LOCKED. Use Firebase action links with branded Forge & Flow web pages. Firebase keeps secure action-code handling; Forge & Flow owns the visible invite/reset/verify pages and copy. Built-in Firebase subject/body customization is not a launch blocker. |
| `lib/firebase_options.dart` | MISSING. FlutterFire generation remains a runtime wiring task. |
| Android Gradle Firebase plugin | MISSING. Client build wiring remains a runtime wiring task. |
| iOS Xcode/Pod wiring | MISSING. Config files exist, but Xcode scheme/configuration wiring is pending and likely needs a macOS session. |
| JWT verifier runtime code | PRESENT (framework). `tool/advisor_proxy/advisor_proxy.dart` now ships `FirebaseProxyJwtVerifier`, `FirebaseSecureTokenJwksSource`, the `JwksKeySource` / `JwtRs256SignatureValidator` seams, and `ScaffoldFailingRs256SignatureValidator` (fail-closed default). `main.dart` swaps to the Firebase verifier when `FIREBASE_PROJECT_ID` is set; without it, the scaffold rejecter stays in place. |
| Production RS256 backend | RESOLVED in Phase 9 live-closeout tranche 1. `PointyCastleRs256SignatureValidator` is wired in `tool/advisor_proxy/main.dart` when `FIREBASE_PROJECT_ID` is present, and a live staging Firebase ID-token smoke passed against the securetoken JWKS. The scaffold rejecter remains the fail-closed default when Firebase config is absent. |

## Secret Layout

Canonical local secret folder:

- `$HOME/.forge_flow/forge_flow.secrets.ps1`
- `$HOME/.forge_flow/firebase-staging-adminsdk.json`

Removed old local locations:

- `.env.local`
- `$HOME/.forge_flow.staging.ps1`
- `$HOME/.forge_flow.production1.ps1`
- `$HOME/.forge_flow.firebase.staging.ps1`
- `$HOME/.forge_flow.firebase.staging.json`

The unified loader reports these env names as present without printing values:

- `POSTGRES_URL`
- `POSTGRES_ADMIN_URL`
- `POSTGRES_PRODUCTION_ADMIN_URL`
- `FIREBASE_PROJECT_ID`
- `GOOGLE_APPLICATION_CREDENTIALS`
- `ANTHROPIC_API_KEY`
- `VOYAGE_API_KEY`

## Live Calls In This Setup

Live Firebase/GCP setup calls were made for the staging project, including
Identity Platform setup, app registration, service-account/role setup, and an
Admin SDK config-read smoke.

No Anthropic, Voyage, Azure Postgres schema mutation, or operator-data load is
part of this report.

## Files That Must Never Be Committed

- Firebase Admin SDK private key JSON.
- Any other service-account JSON downloaded from Firebase/GCP.
- Cloud Run service-account workload-identity tokens.
- Any `.env` or PowerShell loader containing live secrets.
- Any full DSN, token, password, private key, or provider API key.

Public Firebase client config files (`google-services.json`,
`GoogleService-Info.plist`, `web/firebase-config.js`) are intentionally public
Firebase client configuration and may be committed after review. They are not
Admin SDK material.

## Decisions Locked For 9.1 Runtime Wiring

1. Passkeys: launch Phase 9 with email/password + TOTP. Passkeys are future
   follow-up only unless official Firebase / Identity Platform support appears
   before cutover. Do not build custom WebAuthn in the 9.1 runtime wiring
   slice.
2. Auth emails: use Firebase action links with branded Forge & Flow web pages.
   Firebase keeps secure action-code handling; Forge & Flow owns the page UX.
3. iOS wiring: Xcode scheme verification may be deferred to a macOS session
   while Windows work proceeds for proxy/runtime wiring.

## Official Source Basis

- Identity Platform authentication concepts list email/password, phone,
  federated providers, OIDC/SAML, and custom auth integration; no first-party
  WebAuthn/passkey provider is listed:
  `https://cloud.google.com/identity-platform/docs/concepts-authentication`.
- Identity Platform TOTP MFA is documented as a supported MFA factor:
  `https://cloud.google.com/identity-platform/docs/admin/enabling-totp-mfa`.
- Firebase custom email action handlers are the documented path for branded
  action-code pages:
  `https://firebase.google.com/docs/auth/custom-email-handler`.
- Firebase Admin SDK email action links are the documented path when the app
  generates links for custom email/page flows:
  `https://firebase.google.com/docs/auth/admin/email-action-links`.

## Next Runtime Wiring Targets

These are not done by this preflight:

- `tool/advisor_proxy/advisor_proxy.dart` - DONE for the verifier
  framework and production RS256 backend:
  `FirebaseProxyJwtVerifier`, `JwksKeySource`,
  `JwtRs256SignatureValidator`, `FirebaseSecureTokenJwksSource`, and
  `PointyCastleRs256SignatureValidator` ship behind the existing
  `ProxyJwtVerifier` seam.
- `tool/advisor_proxy/main.dart` - DONE: swaps the scaffold rejecter
  for `FirebaseProxyJwtVerifier` with the pointycastle validator when
  `FIREBASE_PROJECT_ID` is set.
- Auth event logging into `auth_events_audit` - PENDING (Phase 9.3).
- Tenant-context resolution: `firebase_uid -> users -> operator/location/status` - PENDING (Phase 9.2).
- FlutterFire/Gradle/iOS wiring for client apps - PENDING (Phase 9.3).

## Local Verification

- Unified loader: Postgres, Firebase, Anthropic, and Voyage env names present
  (name-only output).
- `scripts/postgres_staging_preflight.ps1`: passes with name-only output.
- Firebase Admin SDK JSON: present outside repo and usable for the staging
  config-read smoke.
- No operational references to the old scattered secret files remain outside
  this report's removed-locations note.

## Sequencing Note

`9.1` identity-provider setup and JWT verification are complete for the current
launch path. The database half is ready (`9.0` is applied on staging and
Production1), and the identity-provider setup is usable for email/password +
TOTP + JWT verification. Passkeys are not a current launch gate while Firebase /
Identity Platform lacks an official supported path.
