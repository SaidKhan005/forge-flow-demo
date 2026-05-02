# Hardening — Admin CORS & Request Limits Contract

Updated: 2026-05-02
Owner: HARD-C (security headers sprint)
Status: Active authority

## Why This Exists

Five admin route helpers in `tool/advisor_proxy/advisor_proxy.dart` set
`Access-Control-Allow-Origin: *` on routes that mutate operator data,
integration credentials, pricing caps, corpus state, and feature flags. A
JWT leak from any source would let an attacker-controlled origin issue
cross-site mutations from a victim browser. This contract pins the allow
list, centralizes the CORS helper, and adds explicit request-size handling.

Handoff between:

- `tool/advisor_proxy/advisor_proxy.dart` — CORS helpers at lines
  9997, 10013, 10031, 10048, 10065 plus `routeRequest`.
- `tool/advisor_proxy/proxy_bootstrap.dart` — config plumbing for
  allow-list source.
- `tool/advisor_proxy/feature_flags_repository.dart` — runtime
  allow-list when the feature-flag source is chosen (see Allow-List Source).

Disagreement rule: this contract wins. Any CORS reflection logic that
drifts from this spec is a bug, not a separate contract.

## In Scope

| Item | In | Out |
|------|-----|-----|
| Pin admin CORS allow-list to F&F app origin(s) | yes | non-admin route CORS (already correct) |
| Centralize CORS helper into one function | yes | rewriting handler-level logic |
| Add request body size cap with 413 response | yes | streaming uploads (none today) |
| Add `Access-Control-Allow-Headers` for `Idempotency-Key` | yes | new headers beyond what handlers consume |
| Reject preflight from unknown origin with 403 | yes | logging unknown-origin metrics (defer to HARD-G) |

## Allow-List Source

Source of truth (in priority order):

1. `ADMIN_CORS_ALLOWED_ORIGINS` env var: comma-separated absolute origins
   (`https://admin.forgeandflow.app,https://admin-staging.forgeandflow.app`).
   Required in production.
2. Feature flag `admin_cors_origins_extra` (read via
   `feature_flags_repository.dart`): comma-separated supplemental origins.
   Used for ephemeral preview deploys.
3. `localhost:*` in `dev` and `staging` `PROXY_ENVIRONMENT` only.

If neither source resolves to a non-empty list in `prod`, startup fails
closed with exit code 78 and stderr line
`startup_failure: admin_cors_allowlist_missing_in_prod`.

## Required CORS Behavior

New helper `respondAdminCorsPreflight(HttpRequest, allowList)` must:

- Read `Origin` request header.
- If header absent or origin is not in the resolved allow list → respond
  HTTP **403** with `{"error":"cors_origin_not_allowed"}`. Do **not**
  echo the disallowed origin in any response header.
- If origin matches → respond **204** with these exact headers:

| Header | Value |
|--------|-------|
| `Access-Control-Allow-Origin` | the matched origin (echoed exactly, never `*`) |
| `Vary` | `Origin` |
| `Access-Control-Allow-Methods` | `GET, POST, PATCH, OPTIONS` (route-trimmed where appropriate) |
| `Access-Control-Allow-Headers` | `Authorization, Content-Type, Idempotency-Key` |
| `Access-Control-Max-Age` | `600` |
| `Access-Control-Allow-Credentials` | omit (do not set; admin uses Bearer tokens, not cookies) |

All five existing admin CORS helper sites (lines ~9997, 10013, 10031,
10048, 10065) must be replaced by a single call to the new helper.

For non-preflight admin responses, every handler that emits a CORS-bearing
response uses the same helper to set `Access-Control-Allow-Origin: <origin>`
and `Vary: Origin`.

## Request Size Limit

Add to `routeRequest` (or earliest pre-handler hook):

- Read `Content-Length` header on `POST` / `PATCH` / `PUT`.
- If absent or `> 1_000_000` (1 MB) → respond HTTP **413** with
  `{"error":"request_too_large","limit_bytes":1000000}`.
- If `Transfer-Encoding: chunked` and stream exceeds 1 MB while reading →
  abort and respond 413 (best-effort; current admin paths do not stream).

Routes carved out (no body-size cap): none today. Corpus uploads use a
multi-step preview/commit flow whose individual writes stay <1 MB; future
streaming uploads can opt out by listing here.

## Out of Scope

- Per-tenant CORS allow lists.
- CSRF tokens (admin auth uses Bearer; not cookie-based).
- HSTS / CSP / X-Frame-Options — owned by Cloud Run / load balancer or
  Phase 11A.7 frontend; not in this contract.
- Rate limiting per origin (Phase 12).

## Test Surface

- Unit tests for `respondAdminCorsPreflight`:
  - allowed origin → 204 with echoed origin (not `*`)
  - disallowed origin → 403 with no `Access-Control-Allow-Origin` header
  - missing `Origin` → 403
  - allow list resolution covers env, feature flag, dev fallback
- Route tests for each of the five admin surfaces (operator/location,
  integrations, pricing, corpus, feature-flags) confirming `*` is gone
  and origin-pinning works.
- Request-size tests:
  - `Content-Length: 1_000_001` → 413
  - missing `Content-Length` on POST → 413
  - `Content-Length: 500_000` → handler runs
- Bootstrap test: `prod` mode with empty allow list → exit 78.
- `dart analyze --fatal-infos`.

## Codex Acceptance

- [ ] No remaining `Access-Control-Allow-Origin: *` on admin routes
      (`Grep "Access-Control-Allow-Origin: \*" tool/advisor_proxy/` returns zero hits).
- [ ] `respondAdminCorsPreflight` (or equivalent named helper) is the only
      origin-decision site.
- [ ] All five admin helpers route through the new function.
- [ ] `routeRequest` rejects oversized bodies with 413.
- [ ] `prod` startup with empty allow list exits 78.
- [ ] Idempotency-Key header is in `Access-Control-Allow-Headers`.
- [ ] All listed tests pass; `dart analyze --fatal-infos` clean.
