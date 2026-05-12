# A0 — B1+B2 Post-Merge Verification Probe

**Slice:** A0 (Lane A — code health; orchestrator-owned)
**Authority:** `docs/_execution/lane_a_code_health/03_execution_slices.md` "Slice A0".
**Verifier:** orchestrator (this Claude session).
**Date:** 2026-05-12.
**Master tip at verification:** `f1034d0a32cce022ce914f4015b90069fc494baa`.
**Result:** **PASS** — B1 + B2 hot-fix is live on master and emitting as designed. Slice A0 acceptance met. Downstream Lane A slices (A2.1, A3.1, A4.1, A7.1, A10.1, A11.1) are unblocked.

## File fingerprints on `origin/master`

| Path | Blob SHA-1 | Lines |
|---|---|---|
| `tool/advisor_proxy/main.dart` | `e99e2c5c10f5b45e784ed47bfd864b3c845f5689` | 2183 |
| `tool/advisor_proxy/advisor_proxy.dart` | `33990009336163546b6ba33eb2d7935141f54895` | 18631 |
| `lib/services/auth/firebase_auth_login_service.dart` | `8ef7d1ebc2df01247811fdbfdc81a0e2e835c346` | 281 |
| `tool/pressure/p4_session_soak.dart` | `ede89a7e824909fa9999cdee50741fdbcb3b3446` | 611 |
| `tool/pressure/p4_operator_day_soak.dart` | `6f52104b2d2d4a0f90571b4a9e6665df7f8c8c61` | 596 |
| `tool/pressure/p4_session_record_predicate.dart` | `936c00f59ea81c60071c1b1e3cf3b6a430c474c9` | 195 |
| `test/pressure/p4_session_record_predicate_test.dart` | `fb0c4d60407b8d8fd70da8c8c1419e0d1f60399b` | 192 |
| `test/advisor_proxy_test.dart` | `1b9eb652d64f8a57d0fc25b09d7163c475d94d47` | 7693 |
| `tool/advisor_proxy/health_producers/infra_producers.dart` | `93b8eea023a10452bf8bc15073ac7878981d6b3d` | 382 |

## B2 runZonedGuarded — live on master

`tool/advisor_proxy/main.dart:84-95` carries the B2 serve-loop wrapping:

> Line 84: `// B2 — wrap the whole serve loop in runZonedGuarded so any uncaught`
> Line 90: `// The completer is what main awaits — runZonedGuarded is a`
> Line 95: `runZonedGuarded<void>(`

## B1 proxy contract — live on master

`tool/advisor_proxy/advisor_proxy.dart`:

- `:2179` — `final isGlobalAdmin = _hasGlobalAdminRole(claims.roles);`
- `:2189` — `'proxy.auth.scope_missing_rejected'` (warn-level structured log)
- `:2206` — `'proxy.auth.scope_missing_accepted_global_admin'` (info-level)
- `:2258` — `static bool _hasGlobalAdminRole(List<String> roles) { … }` (carve-out for `ff_support` / `super_admin`)

## B1 client-side follow-up — live on master

`lib/services/auth/proxy_auth_session_ledger_writer.dart` carries `_globalAdminRoles`, role-aware `_recordFromLoginResponse`, and `_validateLoginScopeEcho` (the follow-up commit `e26e53af` from PR #476 re-audit).

## Scope-less contract tests — PASS

```
flutter test test/advisor_proxy_test.dart --plain-name "scope-less"
00:00 +0: ProxyRequestGuard.requireOperatorContext B1 — accepts scope-less ff_support tokens with empty operator and location strings
00:00 +1: ProxyRequestGuard.requireOperatorContext B1 — accepts scope-less super_admin tokens with empty operator and location strings
00:00 +2: ProxyRequestGuard.requireOperatorContext B1 — non-admin scope-less tokens still 403 with structured log context (unchanged contract for tenant-scoped users)
00:00 +3: All tests passed!
```

Structured-log shells captured during the run:

- `proxy.auth.scope_missing_accepted_global_admin` fired for both `ff_support` and `super_admin` user paths with `claim_shape: global_admin`.
- `proxy.auth.scope_missing_rejected` fired for `advisor.read` (non-admin) with `status_code: 403`, `claim_shape: tenant_scoped`.

## Soak harness `--dry-run` — clean

```
dart run tool/pressure/p4_session_soak.dart --dry-run
…
Ops: 5  concurrency: 5  duration: 60s
| Total requests | 120 |
| 2xx | 0 |
| 5xx | 0 |
| network errors | 120 |   ← expected: no proxy running locally
| incomplete 200 records | 0 |
Findings: 0
```

Binary loaded, ran the configured ops/concurrency/duration matrix, wrote `findings.jsonl` / `summary.md` / `raw.jsonl` to `test/load/pressure/`. 0 incomplete-200 records (correct because no 200s were issued).

## Production session-record gauge — not yet wired (deferred to A11.2 as designed)

Grep on `origin/master` for `forge_admin_session_count_active` / `forgeAdminSessionCountActive` / `session_count_active.*gauge` returns **no matches**. This matches the slice plan's expectation: the gauge wiring is Slice A11.2, not A0.

## Acceptance

All 4 acceptance items met:

- [x] file fingerprints / line-count snapshots showing `runZonedGuarded` + scope-less branch live;
- [x] `dart test test/advisor_proxy_test.dart` passes for the scope-less contract case (`--plain-name "scope-less"` — 3/3 pass);
- [x] `dart run tool/pressure/p4_session_soak.dart --dry-run` smoke runs cleanly;
- [x] production gauge from R3 §2 is **not yet** wired — confirmed via grep; deferred to Slice A11.2 as designed.

## Downstream unblocking

With A0 merged, the following Lane A slices become eligible for executor pickup:

| Slice | Owner | Gate | Notes |
|---|---|---|---|
| A2.1 | Codex | auto | Dead-code sweep |
| A2.2 | Codex | operator | Email pipeline wire-or-delete |
| A3.1 | Claude | operator | Monolith seam-map + bleed-stop lint |
| A4.1 | Claude | auto | Performance audit pass |
| A5+A8 | Codex | operator | Schema versioning |
| A7.1 | Claude | auto | Frameworks cross-reference sweep |
| A9.1 | Codex | operator | `lib/data` rehome |
| A10.1 | Claude | auto | Test consolidation pass |
| A11.1 | Claude | operator | Production session-record gauge (this is where the R3 §2 gauge lands) |

No other downstream effect — A0 is purely a verification probe.
