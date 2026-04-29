# Phase 9 B17 Staging Smoke + Cloud Armor Preview Tuning Result

Generated: 2026-04-29.
Status: B17 STAGING SMOKE PASSED; CLOUD ARMOR ENFORCEMENT NOT FLIPPED.

## Scope

- Deploy the current staging proxy with B17 role catalog CRUD.
- Smoke `GET/POST/PATCH/DELETE /v1/admin/auth/roles` through the staging edge.
- Review Cloud Armor preview evidence and tune preview-only false positives.
- Leave physical iOS device QA for the Apple device lane.

## Result

- Staging deploy succeeded: `forge-flow-staging-proxy-00018-ztq` serves 100%
  of traffic.
- HTTPS readiness passed on `https://staging-api.feflow.org/readyz`.
- B17 smoke passed through the staging edge:
  - Firebase smoke sign-in returned an ID token.
  - `GET /v1/admin/auth/roles?scope=custom` returned successfully.
  - `POST /v1/admin/auth/roles` created a temporary editable custom role.
  - `PATCH /v1/admin/auth/roles/{role_id}` updated it and returned
    `bumped_users=0`.
  - `DELETE /v1/admin/auth/roles/{role_id}` soft-deleted it.
  - Final custom-role listing confirmed the temporary role was no longer
    visible.
- No secrets, tokens, passwords, recovery codes, or DSNs were written to docs.

## Cloud Armor

Initial preview review found only about six hours of load-balancer data, not
the required 3-7 day evidence window.

B17 smoke exposed legitimate role CRUD false positives in the preview-only WAF
rule. The original rule was not enforced, so the requests still succeeded.
Observed noisy SQLi signatures on B17 role CRUD included:

- `owasp-crs-v030001-id942260-sqli`
- `owasp-crs-v030001-id942430-sqli`
- adjacent high-sensitivity anomaly signatures when sensitivity stayed at 4

The staging rule now uses SQLi/XSS sensitivity 2 with the B17 sensitivity-2
false positives opted out:

- `owasp-crs-v030001-id942260-sqli`
- `owasp-crs-v030001-id942430-sqli`

Post-tuning verification:

- Normal B17 list/create/patch/delete/cleanup produced zero Cloud Armor preview
  hits on `/v1/admin/auth/roles`.
- A controlled SQLi probe against `/readyz` still returned 200 because the rule
  is preview-only, and logged preview signature
  `owasp-crs-v030001-id942180-sqli`.

Decision: do not flip enforcement yet. Keep the policy preview-only until at
least 3 clean days of post-tuning preview logs are available and the user gives
explicit enforcement approval.

## GitHub / Apple

After GitHub CLI authentication, manual GitHub Actions run `25087331405`
completed successfully on `master`. All three automated Apple jobs passed:
macOS host tests, ForgeFlow iOS simulator build, and Barrio iOS simulator
build. Physical iOS QA remains human/device-gated.

## Verification

- `dart analyze` on B17 auth/proxy files: no issues found.
- Focused B17 tests:
  `flutter test test/proxy_auth_operations_gateway_test.dart
  test/proxy_auth_operations_route_test.dart test/role_admin_live_binding_test.dart
  --reporter compact`: 43/43 passed.
- `flutter analyze --fatal-infos`: no issues found.
- `dart run tool/rls_policy_lint.dart`: clean.
- `git diff --check`: passed, with only LF-to-CRLF warnings.
- Full `flutter test --reporter compact`: 2544/2544 passed.
