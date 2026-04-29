# Phase 9 Live Closeout Cloud / MFA / Platform Result

Status: STAGING MFA/RECOVERY/SECRET MANAGER/EDGE SMOKES PASSED; LOCAL
STABILITY GATES GREEN; GITHUB APPLE RUNNER PASSED.
Generated: 2026-04-28.

## Scope

Maintenance-only live-closeout work for the remaining Phase 9 gates:
Cloud Armor/reCAPTCHA, live Firebase MFA deploy smoke, iOS/macOS verification,
and stability/backlog capture. No Production1 mutation was performed.

## Shipped Locally

- Added `IdentityToolkitFirebaseMfaClient`, a Cloud Run-safe MFA adapter that
  uses Identity Toolkit REST instead of importing the Flutter-only
  `firebase_auth` SDK in the proxy runtime.
- Passed the already verified proxy `Authorization` ID token into MFA
  begin/confirm/withdraw commands. Tokens are request-body inputs only; they
  are not logged or returned in JSON bodies.
- Bound the production proxy bootstrap to the Identity Toolkit MFA adapter
  with `FIREBASE_WEB_API_KEY`.
- Added local adapter contract tests for:
  - `POST /v2/accounts/mfaEnrollment:start`
  - `POST /v2/accounts/mfaEnrollment:finalize`
  - `POST /v1/accounts:lookup`
  - safe provider-error mapping for invalid TOTP codes.
- Live provider verification found the TOTP endpoints accept the project API
  key plus the user's ID token. The earlier OAuth path returned safe
  credential errors, so the adapter was corrected to the verified API-key
  contract.

## Cloud Inventory And Edge Setup

2026-04-28 initial staging inventory used read-only `gcloud` commands only.

- Cloud Run service `forge-flow-staging-proxy` is still directly exposed at the
  `run.app` URL, latest ready revision
  `forge-flow-staging-proxy-00013-zx8`, with ingress `all` and unauthenticated
  invoker access enabled.
- No global backend services are present in `forge-flow-staging`.
- No Cloud Armor security policies are present in `forge-flow-staging`.
- reCAPTCHA Enterprise API is disabled for `forge-flow-staging`, so key
  inventory cannot be listed yet.

Conclusion: Cloud Armor cannot be attached to the current direct Cloud Run
entrypoint. B16 requires an explicit infrastructure decision and approval for a
staging HTTPS load balancer/serverless NEG/backend service/security policy
path, plus reCAPTCHA Enterprise API enablement, key/domain selection, and token
verification rollout.

After explicit approval, the staging-only edge bootstrap was created:

- Reserved global IP `ff-staging-proxy-ip`: `34.54.204.29`.
- Created serverless NEG `ff-staging-proxy-neg` in `northamerica-northeast2`
  for `forge-flow-staging-proxy`.
- Created global backend service `ff-staging-proxy-backend`, URL map, HTTP and
  HTTPS proxies, forwarding rules, and managed certificate
  `ff-staging-proxy-cert` for `staging-api.feflow.org`.
- Attached Cloud Armor policy `ff-staging-proxy-armor` with a preview-only
  preconfigured WAF rule for `sqli-stable` / `xss-stable`.
- Enabled backend logging at sample rate 1.0.
- Enabled reCAPTCHA Enterprise and created staging score key
  `6LeBDc8sAAAAAO7QL0_qelJwl-f4QmCEktP-qlM4` for
  `staging-api.feflow.org`, WAF session-token integration.
- Forced HTTP edge smoke to `http://staging-api.feflow.org/readyz` via
  `34.54.204.29` returned 200 with `{"status":"ok"}`.
- Cloud Armor preview-log review passed after controlled staging-only probes:
  both probe requests returned 200, while Cloud Logging recorded
  `previewSecurityPolicy` priority 1000 with configured `DENY`, outcome
  `DENY`, and `preview: true`. Matched preconfigured expressions included
  `owasp-crs-v030001-id942180-sqli` and
  `owasp-crs-v030001-id942431-sqli`.

Porkbun DNS was updated and public resolvers now return
`staging-api.feflow.org A 34.54.204.29`. HTTP `/readyz` passes on the real
hostname. The managed certificate is now `ACTIVE`, and HTTPS `/readyz` passes
on the real hostname.

## Platform Verification

- Windows-side static iOS check found both flavor Firebase plists under
  `ios/Runner/Firebase/`, flavor xcconfigs, and the Xcode copy phase that
  selects the plist by bundle identifier.
- There is no `macos/` platform directory in this repo.
- Added `.github/workflows/apple-platform-verify.yml` so GitHub can run the
  macOS/iOS gate without local Apple hardware. The workflow uses a macOS runner,
  runs focused auth/MFA tests, builds macOS only if a `macos/` project exists,
  and builds both Forge Flow and Barrio iOS simulator flavors.
- First GitHub run failed both iOS simulator jobs because `firebase_auth`
  requires iOS 15.0 while the repo had no committed Podfile and Flutter
  generated a 13.0 CocoaPods target.
- Pinned the iOS platform floor to 15.0 in `ios/Podfile`,
  `ios/Runner.xcodeproj/project.pbxproj`, and
  `ios/Flutter/AppFrameworkInfo.plist`; added
  `test/ios_platform_contract_test.dart`.
- GitHub run `25078391954` passed: macOS host tests, ForgeFlow iOS simulator
  build, and Barrio iOS simulator build all succeeded on branch
  `codex/apple-platform-verify-20260428` at commit `b928940`.

## Live MFA / Deploy Smoke

- Direct staging Identity Toolkit TOTP smoke passed with cleanup:
  start, finalize, lookup, and withdraw all completed against the dedicated
  smoke user. No token, secret, TOTP code, or recovery code value was printed.
- Staging proxy deploys completed:
  - `forge-flow-staging-proxy-00014-vsq`: first Identity Toolkit binding.
  - `forge-flow-staging-proxy-00015-bpg`: safe diagnostic revision.
  - `forge-flow-staging-proxy-00016-g57`: corrected API-key MFA adapter,
    serving 100% traffic.
  - `forge-flow-staging-proxy-00017-pcz`: Secret Manager-backed proxy runtime
    config, serving 100% traffic.
- Deployed revision `forge-flow-staging-proxy-00016-g57` smoke passed:
  password sign-in, proxy permission snapshot, and `POST
  /v1/auth/mfa/totp/begin` response shape. The permission snapshot returned 80
  permissions with `team.users.view=allow` and `team.users.invite=allow`.
- Deployed revision `forge-flow-staging-proxy-00017-pcz` disposable-user smoke
  passed: Firebase signup, custom claims, password sign-in, proxy TOTP begin,
  TOTP confirm, recovery-code consume, durable `recovery_code_attempts` ledger
  verification, Firebase cleanup, and Postgres cleanup. No token, secret, TOTP,
  recovery-code, or password value was printed.

## Security Maintenance Finding

- Read-only Cloud Run service inspection showed sensitive runtime values were
  stored as direct environment values. No values were copied into docs.
- `scripts/deploy_staging_proxy.ps1` now enables Secret Manager, syncs the
  staging proxy secret names, grants the Cloud Run service account secret
  access, and deploys secret-backed env refs for API keys and Postgres URLs.
- Revision `forge-flow-staging-proxy-00017-pcz` was verified to expose only
  secret refs for those sensitive values. `FIREBASE_PROJECT_ID` remains a plain
  non-secret env var.

## Verification

- `dart format` over the touched MFA/proxy/test files completed.
- `dart analyze lib/services/mfa ... tool/advisor_proxy/advisor_proxy.dart`:
  no issues found.
- `flutter test test/identity_toolkit_firebase_mfa_client_test.dart
  test/mfa_live_binding_test.dart test/mfa_operations_gateway_test.dart
  test/proxy_auth_operations_route_test.dart
  test/proxy_mfa_operations_gateway_test.dart
  test/advisor_proxy_bootstrap_test.dart`: 40/40 passed.
- Additional corrected-adapter gates:
  `dart analyze lib/services/mfa/identity_toolkit_firebase_mfa_client.dart
  tool/advisor_proxy/proxy_bootstrap.dart tool/advisor_proxy/advisor_proxy.dart
  test/identity_toolkit_firebase_mfa_client_test.dart
  test/advisor_proxy_bootstrap_test.dart test/proxy_auth_operations_route_test.dart`
  reported no issues, and `flutter test
  test/identity_toolkit_firebase_mfa_client_test.dart
  test/advisor_proxy_bootstrap_test.dart test/proxy_auth_operations_route_test.dart`
  passed 12/12.
- Staging migration verification confirmed `recovery_code_attempts` exists with
  RLS and grants, and `auth_events_audit` has `actor_kind` plus
  `actor_service_principal_id`.
- Latest disposable staging MFA/recovery smoke passed on
  `forge-flow-staging-proxy-00017-pcz`.
- Latest Cloud Run `/readyz` returned 200 after Secret Manager deploy; forced
  HTTP edge `/readyz` returned 200 through `34.54.204.29`.
- Latest managed certificate status is `ACTIVE`; HTTPS `/readyz` returns 200 on
  `staging-api.feflow.org`.
- Cloud Armor preview probes returned 200 but logged preview DENY matches at
  priority 1000, confirming non-enforcing WAF visibility.
- GitHub Apple run `25078391954` passed all three jobs.
- Final local closeout gates:
  `dart run tool/rls_policy_lint.dart` clean,
  `flutter analyze --fatal-infos` clean, focused auth/MFA/edge tests passed
  41/41, `test/ios_platform_contract_test.dart` passed 2/2, and full
  `flutter test` passed 2324/2324.
- `git diff --check` reported only CRLF normalization warnings.

## Remaining

- Keep Cloud Armor WAF in preview until there is enough normal traffic to judge
  false positives.
- Production1 remains locked until explicit approval.
