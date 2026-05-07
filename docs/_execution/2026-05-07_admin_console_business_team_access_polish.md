# Admin Console Business, Team, and Access Polish Verification

Date: 2026-05-07 Newfoundland time  
Worktree: `.codex_worktrees/admin-console-performance-ux-polish`  
Branch: `codex/admin-console-performance-ux-polish`

## Source and Preview

- Base observed before this pass: `origin/master` `cb8afb80`
- Deployed source commit: `40e04629`
- Rebased follow-up branch source commit: `63a9ca53`
- Admin URL: https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app
- Proxy URL: https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app
- Admin revision: `forge-flow-preview-backend-surface-additions-admin-00026-5d9`, 100% traffic
- Proxy revision: `forge-flow-preview-backend-surface-additions-proxy-00071-jmv`, 100% traffic
- Database mode: staging secrets through `forge-flow-staging-`; successful live writes were not submitted.
- Share URL from deploy: https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app?cache_bust=preview-backend-surface-additions-20260507014212
- Browser Use URL: https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app/?cache_bust=admin-ops-ux-fresh-40e04629-20260507T0418Z

## Research Inputs

- GOV.UK tabs guidance: https://design-system.service.gov.uk/components/tabs/
- MOJ filter component guidance: https://design-patterns.service.justice.gov.uk/components/filter/
- Material data table guidance: https://m1.material.io/components/data-tables.html

The implementation kept tabs for related, repeat-use admin work, made labels clearer, put the most common work first, added visible filter affordances where lists need narrowing, and used a simple edit dialog for Team display names.

## Framework Results

### UX Adjustment Framework

- Operations entrypoint is now `Business accounts`, with setup-oriented account/location grouping.
- Business account and location cards use consistent action rows: relationship/navigation first, edit/status second, diagnostics/logs third.
- Team is now `Team & roles`; Roles policy is reachable from Team and Access without forcing users to understand implementation ownership.
- Access is now `Access & hierarchy`, with `Role policy`, `Location hierarchy`, and `Active sessions` tabs plus a filter-card pattern.
- Audit & Support now leads with investigation/audit context, then the support action panel.
- Team, Access, Audit & Support, Business accounts, Data Accuracy, and Polling/Pricing now share clearer filter affordances.
- Team users can update display name through an admin-only audited flow with admin reason and idempotency.

### Performance Framework

- Release admin build completed against the preview proxy.
- Enforced performance probe passed: `build/perf_gate/admin-console-performance-ux-polish-40e04629.json`
  - `admin_index_c1` p95 650.8 ms
  - `admin_index_c4` p95 251.5 ms
  - `admin_mainjs_gzip_c4` p95 1068.4 ms, 1,156,022 bytes
  - `proxy_readyz_c1` p95 254.2 ms
  - `proxy_readyz_c4` p95 225.1 ms
- No route introduced automatic expensive diagnostics or new polling loops.

### Mobile Web Console E2E Framework

- Browser Use opened the deployed preview with fresh cache bust.
- Page title observed before Flutter shell completion: `Forge & Flow - Operations Console`.
- Page title after Flutter shell completion: `Forge & Flow Admin Console`.
- Browser Use route-click pass reported zero console warnings/errors for Business accounts, Data Accuracy, Polling and Pricing, Team and roles, Access and hierarchy, Audit and support, Pricing, Corpus, Health, Observability, Debug, Vendor connections, and Feature flags.
- Browser Use limitation: in-app screenshot capture timed out on `Page.captureScreenshot`, and the release Flutter DOM exposed only the accessibility bootstrap button. Route-click and console-log evidence was captured, but visual screenshots were not available from Browser Use in this run.

## Route and Runtime Evidence

- Deploy script verified proxy `/readyz`: 200.
- Deploy script verified admin CORS preflight: 204.
- Deploy script verified admin-auth CORS preflight: 204.
- Manual `OPTIONS /v1/admin/auth/users`: 204 with admin origin, `GET, POST, PATCH, DELETE, OPTIONS`.
- Manual `OPTIONS /v1/admin/auth/users/test-user`: 204 with admin origin, `GET, POST, PATCH, DELETE, OPTIONS`.
- Shared staging secret mode means live smoke stayed read-only; successful write behavior is covered by local widget, gateway, proxy, and repository tests.

## Bugs Found and Fixed

- Team display name had no admin-console write path. Added UI, gateway, proxy, repository method, audit reason, idempotency, and tests.
- Live admin proxy only partially matched admin Team action aliases. Added routed support for display-name PATCH, deactivate/suspend aliasing, reset-MFA aliasing, force-logout target user handling, and updated user payloads.
- Business accounts and locations were action-heavy but not flow-oriented. Re-grouped actions into relationship, edit/status, and diagnostics rows.
- Access/roles/hierarchy/session naming was implementation-oriented. Reframed around Team role policy, Location hierarchy, and Active sessions.
- Longer grouped location action rows pushed existing test taps offscreen. Updated tests to scroll target actions into view.

## Intentionally Gated or Unsurfaced

- No new UI was invented for backend functionality that is not routed.
- Successful preview writes were not submitted because this preview uses `forge-flow-staging-` secrets. Mutating paths remain gated by admin role checks, disabled states, confirmation/reason flows, idempotency keys, and tests.
- Mobile push status/test surfaces were not changed in this pass.

## Tests and Builds

- `flutter test test/admin --concurrency=1`
- `flutter test test/proxy_auth_operations_gateway_test.dart test/proxy_auth_operations_route_test.dart test/proxy_auth_operations_route_grants_test.dart test/user_lifecycle_live_binding_test.dart`
- `flutter analyze` passed before the rebase. After rebasing onto `origin/master` `489538ae`, it is blocked by inherited latest-master analyzer issues outside this admin patch: invalid fake overrides in MFA tests, missing idempotency-store methods in `tool/advisor_proxy/proxy_bootstrap.dart`, and unrelated lint warnings/infos in auth/tool tests. The proxy compile blocker was fixed in `63a9ca53`; the remaining analyzer issues pre-exist this admin diff.
- `flutter build web --release --target=lib/main_admin.dart --dart-define=ADMIN_PROXY_BASE_URI=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --pwa-strategy=none`
- `dart run tool/perf_gate/staging_console_probe.dart --run --enforce-budgets --admin-url=https://forge-flow-preview-backend-surface-additions-admi-rf7nosnoka-pd.a.run.app --proxy-url=https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app --admin-revision=forge-flow-preview-backend-surface-additions-admin-00026-5d9 --proxy-revision=forge-flow-preview-backend-surface-additions-proxy-00071-jmv --label=admin-console-performance-ux-polish-40e04629 --write-json=build/perf_gate/admin-console-performance-ux-polish-40e04629.json`

## Residual Risks

- Browser Use visual screenshots were blocked by in-app browser screenshot timeout, so this note records console/route-click evidence rather than image evidence.
- The preview is runtime-isolated but data-shared with staging secrets; successful live mutation proof should use a data-isolated preview or a specific approved target action.
- The branch was rebased onto latest `origin/master` after PR 243 was found merged. A redeploy from the rebased source built the proxy image but Cloud Run rejected the new revision because `forge-flow-staging-admin@forge-flow-staging.iam.gserviceaccount.com` lacks `secretmanager.versions.access` on `forge-flow-staging-pgcrypto-envelope-key`. I did not grant IAM without explicit approval. Live traffic remained on admin `00026-5d9` and proxy `00071-jmv`.
