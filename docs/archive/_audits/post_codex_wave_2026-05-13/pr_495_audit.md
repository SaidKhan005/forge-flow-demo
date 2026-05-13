# PR #495 Audit — Fix live admin password reset flow

**Verdict: approve-for-merge**
**Light playbook** (6 files / 423 diff lines / +224/-31 — well under heavy-playbook threshold).

**Audited HEAD**: `9f81d471725f4e149bba9aeccbd41a466b2aac68`
**Master HEAD at audit time**: `7b31d683` (closure PR #494 merged)
**Base**: `master` ✓ (no base drift)

## PR's stated scope

1. Union Firebase auth action origins, including `FORGE_FLOW_AUTH_ACTION_URL`, into the proxy CORS allow-list during staging/preview deploys.
2. Keep current production deploy safeguards while replaying the live admin password reset fixes on top of master.
3. Update password reset action page copy / tests.
4. Add auth password reset CORS coverage tests.

## Per-chunk findings

### Chunk 1 — staging deploy CORS (`scripts/deploy_staging_proxy.ps1` +24)

| Finding | file:line | Authority anchor | Status |
|---|---|---|---|
| New `Get-UriOrigin` helper safely parses a URL env-var value; returns `$null` on blank, non-absolute, or parse errors | `scripts/deploy_staging_proxy.ps1:186-202` | None needed (defensive) | PASS |
| Reads `FORGE_FLOW_AUTH_ACTION_URL` env var, extracts origin, unions into `$firebaseActionCorsOrigins` **only if non-empty** | `scripts/deploy_staging_proxy.ps1:476-481` | CLAUDE.md "Proxy & API Conventions" — CORS allow-list discipline | PASS |
| Production deploy path NOT modified — script is `deploy_staging_proxy.ps1`, scoped to staging | (file path) | PR-stated scope #2 | PASS |

### Chunk 2 — Firebase auth action page (`web/auth/action/index.html` +61/-8)

| Finding | file:line | Authority anchor | Status |
|---|---|---|---|
| Default return URL changed from `forgeflow://sign-in` deep link to operator-web URL with iOS deep-link first + 800ms fallback to operator-web | `web/auth/action/index.html:305-309, 265-283` | None needed (UX) | PASS |
| New error-code mappings: `password_pwned`, `password_reused`, `password_policy_failed`, `hibp_unavailable`, `password_history_unavailable`, `password_reset_expired`, generic 422 fallback | `web/auth/action/index.html:334-380` | None needed (UX copy) | PASS |
| Network-failure message tightened: "...could not be reached. Request a new reset link and try again." | `web/auth/action/index.html:409` | None needed (UX copy) | PASS |
| `loadFirebaseConfig()` flow now extracts `firebaseConfig.operatorWebUrl` with `window.FORGE_FLOW_OPERATOR_WEB_URL` fallback then hardcoded staging URL | `web/auth/action/index.html:388-391` | See drift observation below | PASS (with drift) |

### Chunk 3 — staging firebase config (`web/firebase-config.js` +1)

| Finding | file:line | Authority anchor | Status |
|---|---|---|---|
| Adds `"operatorWebUrl": "https://forge-flow-operator-web-rf7nosnoka-pd.a.run.app/"` to the staging Firebase config | `web/firebase-config.js:10` | None needed (staging-only) | PASS |

### Chunk 4 — tests (3 files, +138/-23)

| Finding | file:line | Authority anchor | Status |
|---|---|---|---|
| Deploy contract test pins the new `Get-UriOrigin` function, `FORGE_FLOW_AUTH_ACTION_URL` env-var read, and the union step | `test/deploy_staging_proxy_contract_test.dart:320-336` | PR-stated scope #1 | PASS |
| New `auth password reset CORS` group: 3 tests covering (a) operator-web origin preflight allow on `/v1/auth/password-reset/request`, (b) Firebase action origin preflight allow on `/v1/auth/password-reset/confirm`, (c) unlisted-origin → 403 `cors_origin_not_allowed` | `test/proxy/admin_cors_routes_test.dart:534-616` | CLAUDE.md "Every proxy write is idempotent" + parity contract `:55` (Idempotency-Key) | PASS |
| `_expectAllowed` helper extended to accept an `origin` named arg — tightens existing CORS assertions to bind to specific origins | `test/proxy/admin_cors_routes_test.dart:107-114` | None needed (test cleanup) | PASS |
| Web auth action page tests pin: `operatorWebUrl` in config, operator-web URL in html, new error codes (`password_pwned`, `password_reused`, `password_policy_failed`), generic 422 copy, network-failure copy | `test/web_auth_action_page_test.dart:28-78` | None needed | PASS |

### Chunk 5 — cross-cutting / operator-approval gates

| Gate | Status | Reason |
|---|---|---|
| **Auth** | PASS | No permission-key catalog changes; no role-grant semantics; password-reset flow change is UI/copy + error-code mapping only |
| **Proxy contract (CORS)** | PASS | Staging deploy script gains an env-var-gated allow-list addition (`Get-UriOrigin` returns null on blank/invalid); production deploy script unchanged; new CORS tests cover both allow + reject paths; `cors_origin_not_allowed` 403 enforced |
| **Audit log / hash chain** | N/A | None touched |
| **RLS / migration** | N/A | None touched |
| **KMS / billing / vendor-live** | N/A | None touched |

## Drift observation (out-of-scope, follow-up suggested)

`web/auth/action/index.html:305-309` defines the JS fallback:

```javascript
let defaultReturnUrl =
  window.FORGE_FLOW_OPERATOR_WEB_URL ||
  "https://forge-flow-operator-web-rf7nosnoka-pd.a.run.app/";
```

The hardcoded fallback is the **staging** operator-web Cloud Run URL. `web/firebase-config.production1.js` does NOT define `operatorWebUrl`, mirroring its existing pattern of NOT defining `proxyBaseUri` (production1 also relies on a `window.FORGE_FLOW_*` env-injection pattern for these values). A production1 deploy that does NOT inject `window.FORGE_FLOW_OPERATOR_WEB_URL` (or add `operatorWebUrl` to `firebase-config.production1.js`) would route password-reset return-URL to the staging Cloud Run origin.

**Why this is non-blocking for PR #495:**

- PR-stated scope explicitly says staging + "keeps current production deploy safeguards" (production deploy script not touched).
- Same pattern already exists for `proxyBaseUri`: production1 must inject via env or override config at deploy time. This PR simply propagates that same shape for `operatorWebUrl`.
- The drift is a production1 deploy concern, not a code-correctness concern at the PR level.

**Recommendation:**

- Add to `docs/POST_HARDENING_FOLLOWUPS.md` BEFORE any production1 password-reset event: ensure either (a) `firebase-config.production1.js` gets an `operatorWebUrl` entry pointing at the production operator-web Cloud Run URL, or (b) the production1 deploy pipeline injects `window.FORGE_FLOW_OPERATOR_WEB_URL`.
- Not blocking this PR's merge — flagged as a tracked follow-up.

## Final verdict + reasoning

**approve-for-merge.** The PR is tightly scoped to staging-side CORS + password-reset UX, with comprehensive test coverage on both the deploy contract and the proxy CORS contract. Operator-approval gates check clean (proxy contract change is env-gated, additive only, with test coverage; production deploy script untouched).

The one drift observation (hardcoded staging operator-web URL as JS fallback) is a production1 deploy concern that mirrors the existing `proxyBaseUri` pattern, not a code-correctness issue at this PR's scope. Tracked as a follow-up suggestion for `docs/POST_HARDENING_FOLLOWUPS.md`.

Per the 2026-05-13 auto-merge doctrine, this PR is eligible for auto-merge.
