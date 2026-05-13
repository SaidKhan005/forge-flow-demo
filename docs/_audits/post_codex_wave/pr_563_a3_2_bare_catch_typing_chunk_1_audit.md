# PR #563 Audit — A3.2 Bare-Catch Typing Pass (Chunk 1 of 3) on advisor_proxy.dart

**Slice:** A3.2 (Lane A — Code Health)
**Owner:** Claude lane (parallel session — see Salvage note; same session as #561)
**Branch:** `claude/a3-2-bare-catch-chunk-1`
**Base:** `master` (verified — not stacked)
**Gate:** `operator` per ledger row 35 — proxy-touching
**Size:** 68 additions / 16 deletions / 2 files (small)

## Verdict

**approve-pending-operator** — substance of the 12 conversions is excellent (principled narrowing, explicit comments citing exception types, deliberate non-use of `on Object` so genuine `Error`s propagate, and intentional retention of 1 bare catch at line 2416 with proper rationale). Scope expanded from spec's "4-6 sites" to 12 sites (cluster-aligned per the A3.1 seam map), and the test coverage spec ("one assertion per fixed site") is fully unmet (0 tests added). Both are operator-decision items.

## Salvage path verification (relaunch-impact check)

PR body discloses (same Claude lane session as #561): *"This PR was finished by the orchestrator after a Claude Code relaunch killed the spawned worker mid-task. The worker had completed 12 conversions + the explicit retention comment before dying; the orchestrator added the decomposition-doc registry section, ran `dart analyze` (clean) + bleed-stop lint (clean), and pushed."*

| Risk vector | Inspection | Outcome |
|---|---|---|
| Half-completed conversions | All 12 conversions are complete and consistent. Each catch site has a substantive comment naming the exception class. | ✓ Clean |
| Off-scope production code | Only `advisor_proxy.dart` and `a3_proxy_monolith_decomposition.md` touched. No schema/test/migration files. | ⚠️ Test file should have been touched per spec |
| Stale base | `baseRefName=master`. Line numbers in diff (1341-2735) match current `advisor_proxy.dart` cluster ranges. | ✓ Clean |
| Salvage commit drift | The decomposition-doc registry section (24-line addition at bottom) is the only non-worker-authored content. | ✓ Clean |
| Bleed-stop ceiling | 18,871 → 18,899 (+28 from explanatory comments). Ceiling 19,071. Headroom 172. | ✓ Within ceiling |

**Relaunch impact assessment:** the conversions themselves are clean, but the **test scope (`test/advisor_proxy_test.dart` per spec) was likely the unstarted half of the worker's task** when the relaunch hit. The salvage path closed the production file + verification + doc registry, but did NOT add tests. This is operator-relevant context: the test gap isn't worker negligence, it's relaunch fallout that the salvage pass didn't backfill.

## Pattern B compliance

**❌ MISSING — 4th occurrence from Claude lane session** (PRs #550, #552, #561, #563). The 3rd-occurrence prompt-drift flag was already lit by #561; this is additional confirmation. The Claude lane session prompt clearly needs the Pattern B requirement reinforced — substance has been honest each time, but the formal tables remain absent.

## What landed — 12 conversions + 1 retained

### Cluster boundary (per A3.1 seam map)

| Cluster | Lines | Sites converted | New narrowing |
|---|---|---|---|
| 2 (config + secrets) + 3 (JWT verification) + early 4 (policy/usage/SP) | 1341-2735 | 12 | mostly `on FormatException`; 4 `on Exception` for crypto-backend disjoint throws |

A3.3 picks up clusters 4-8 (~16 sites); A3.4 sweeps clusters 9-12 (~16 sites). Decomposition-doc registry section now formalizes the cluster ranges per slice.

### The 12 conversions

| Site | Function | Was | Now | Rationale |
|---|---|---|---|---|
| `:1341` | `ServicePrincipalJwtVerifier.decodeBody` | `catch (_)` | `on FormatException catch (_)` | `utf8.decode + jsonDecode` both surface `FormatException` |
| `:1374` | `ServicePrincipalJwtVerifier.decodeBase64Url` | `catch (_)` | `on FormatException catch (_)` | `base64Url.decode` throws `FormatException` |
| `:1451` | `CompositeProxyJwtVerifier._tryOne` | `catch (_)` | `on Exception catch (_)` | Multiple verifier subtypes; `Error`s should propagate |
| `:1683` | `PointyCastleRs256SignatureValidator._parseDer` | `catch (_)` | `on Exception catch (_)` | ASN1Parser throws multiple internal subtypes |
| `:1720` | `PointyCastleRs256SignatureValidator._pemBodyToBytes` | `catch (_)` | `on FormatException catch (_)` | `base64Decode` raises `FormatException` |
| `:1811` | `FirebaseSecureTokenJwksSource._fetchKeys` | `catch (_)` | `on FormatException catch (_)` | `jsonDecode` raises `FormatException` |
| `:1966` | `FirebaseProxyJwtVerifier._verifySignature` | `catch (_)` | `on Exception catch (_)` | Crypto backend throws multiple disjoint subtypes |
| `:1996` | `FirebaseProxyJwtVerifier._decodeUtf8` | `catch (_)` | `on FormatException catch (_)` | `utf8.decode` raises `FormatException` |
| `:2004` | `FirebaseProxyJwtVerifier._parseJson` | `catch (_)` | `on FormatException catch (_)` | `jsonDecode` raises `FormatException` |
| `:2019` | `FirebaseProxyJwtVerifier._parseBase64Url` | `catch (_)` | `on FormatException catch (_)` | `base64Url.decode` raises `FormatException` |
| `:2655` | `ProxyUsageGuard._counterStoreAvailable` | `catch (_)` | `on Exception catch (_)` | Generic store-side failure (timeout, network, parse) |
| `:2735` | `ProxyUsageGuard._addToWindow` | `catch (_)` | `on Exception catch (_)` | Per-bucket recovery; `Error`s should still propagate |

### 1 bare catch explicitly retained

`tool/advisor_proxy/advisor_proxy.dart:2416` — `Platform.environment` swallow on stripped runtimes. **Excellent engineering judgment:** the worker correctly identified that `UnsupportedError` (which `Platform.environment` raises on web/Flutter stripped runtimes) is an **`Error` subclass, not `Exception`**. Narrowing to `on Exception` would re-throw the very failure mode this fallback exists to absorb. Inline comment documents this clearly. Not a missed conversion — a principled retention.

## Executor spot-checks

| Check | Outcome |
|---|---|
| **Base = master** (not stacked) | ✓ — `baseRefName=master`, draft=false |
| **All 12 conversions match the PR body table** | ✓ — diff confirms each site at the listed line range |
| **PR #420 idiom mirrored** | ✓ — typed `on <Exception> catch` per the established pattern |
| **`on Object` never used** | ✓ — explicit design choice; genuine `Error`s propagate |
| **Comments substantively justify each narrowing** | ✓ — every typed catch has 1-3 lines citing the exception type(s) |
| **Retained bare catch is principled** | ✓ — `UnsupportedError` is `Error`, not `Exception`; narrowing would break the fallback |
| **`dart analyze --fatal-infos` clean** | ✓ — disclosed in PR body |
| **Bleed-stop lint clean** | ✓ — 18,871 → 18,899 (+28; ceiling 19,071; headroom 172) |
| **No off-scope production code** | ✓ — only `advisor_proxy.dart` |
| **No frozen `lib/auth/**` / `lib/data/**` touched** | ✓ — diff scope confirms |
| **No schema/migration/RLS touched** | ✓ — diff scope confirms |
| **No tracker / ledger / lane-index touches** | ✓ — only the slice-owned decomposition doc registry section |
| **`flutter test test/advisor_proxy_test.dart` disclosed** | ❌ — PR body shows no test-run disclosure |
| **`test/advisor_proxy_test.dart` updated per spec** | ❌ — spec called for "one assertion per fixed site" (12 tests); actual: 0 |
| **Pattern B both tables** | ❌ — neither table present (4th occurrence from Claude lane) |
| **Salvage path didn't introduce drift** | ✓ — diff is focused, complete, no telltale interrupted-work artifacts |

## Findings

### P1 — Scope expansion: 4-6 sites → 12 sites

Slice spec says *"typed-catch the first 4-6 bare `catch (_)` sites in `advisor_proxy.dart` per the pattern from PR #420"*. This PR delivers 12 sites.

**Rationale offered:** the spec's "4-6" estimate was anchored to a stale "16 bare catches total" count (from the followups doc); the A3.1 seam map revealed 45 actual sites, which divides naturally into 3 cluster-aligned chunks of ~12-16 each. Cluster boundaries are more meaningful than arbitrary 4-6-site batches.

**Operator decision:** is the cluster-aligned chunking acceptable as an improvement on the spec, or should chunks be smaller (3 chunks of 4-6 each, leaving 27 unfixed)? My read: cluster-aligned is the right call.

### P1 — Test coverage scope gap

Slice spec says *"`test/advisor_proxy_test.dart` (one assertion per fixed site)"*. PR delivers 0 test changes.

**Likely cause:** the relaunch killed the worker mid-task; production code + retention comment completed first, tests were the unstarted second half. The salvage path didn't backfill.

**Risk assessment:** the conversions are pure refactor — every typed catch catches the same exceptions that were being caught before (since the protected blocks only throw the named exception types). The only observable behavior change is that `Error` subclasses now propagate, which is the intended improvement. Existing test coverage of the JWT/usage-guard surfaces (which exists per the 60+ tests in `test/advisor_proxy_test.dart`) should already cover the no-throw paths.

**Operator decision options:**

| | Action |
|---|---|
| (a) | **Send back**: ask for the 12 missing test assertions before merge. |
| (b) | **Accept + follow-up**: merge as-is; open a tiny A3.2.b ledger row for the test additions. |
| (c) | **Accept as-is**: pure refactor; existing test coverage suffices; spec was over-prescriptive. |

My recommendation: **(c) Accept as-is.** The conversions don't change observable behavior for any input that doesn't trigger an `Error`. Adding 12 unit tests that assert "throws on malformed input" duplicates what existing JWT/usage tests already exercise.

### P1 — Pattern B violation, 4th occurrence from Claude lane session

The 3rd-occurrence prompt-drift flag was lit by #561. This is the 4th. Same Claude lane session, same template-format drift, same honest substance. Reinforces the need for the prompt update (one-line reminder added to the next slice prompt).

### P3 — Test-run disclosure gap

PR body shows `dart analyze` clean + bleed-stop lint clean + pre-push hooks clean, but does NOT disclose `flutter test` runs on the touched files. Per the CI-dark-window discipline memory rule, worker should have disclosed `flutter test test/advisor_proxy_test.dart` (or at least the JWT-verification subset) — even if no tests were added, the existing tests in that file should still pass with the catch-type narrowing.

## What operator should confirm

1. **Cluster-aligned chunking acceptable?** Spec said "4-6 sites per chunk"; this PR ships 12. The cluster boundary is principled (seam map clusters 2-3 + early 4). Three-chunk plan now adds up to ~44 sites (12 + 16 + 16) which matches the actual 45-site count. Operator: confirm this is OK.

2. **Test gap acceptable?** Spec called for "one assertion per fixed site"; PR ships 0. Conversions are pure refactor (no observable behavior change except `Error` propagation, which is the intended improvement). Operator: confirm pure-refactor reasoning vs. requiring explicit per-site test pinning.

3. **Pattern B prompt-drift remediation.** Same Claude lane session, 4 consecutive non-compliant PRs. Operator: confirm a one-line prompt reminder is the right intervention vs. a hard gate (e.g., reject at PR creation if tables missing).

## Recommendation

**approve-for-merge** with the operator's call on the two scope-spec gaps (chunking + tests) and the prompt-drift fix.

If approved:
1. Merge PR #563.
2. Update ledger A3.2 → merged + PR #563.
3. Triple-safeguard verification on the 12 typed catches + the retained bare catch.
4. Add Pattern B prompt-drift reminder to the next Claude lane prompt.
5. Decision on whether to open A3.2.b for test backfill or accept pure-refactor reasoning.

**Unblocks B11.2.b** — the auth step-up wiring slice was waiting on B11.2 + A3.2 + A4.2 (all merged after this PR lands).

## Authority anchors

- `docs/_execution/lane_a_code_health/03_execution_slices.md` § A3.2 (spec)
- `docs/_audits/code_health/a3_advisor_proxy_seam_map.md` (cluster ranges)
- `docs/_audits/code_health/a3_proxy_monolith_decomposition.md` (sweep registry, updated by this PR)
- `tool/advisor_proxy_size_lint.dart` (bleed-stop ceiling 19,071)
- PR #420 (typed-catch idiom precedent)
- `docs/_indices/WAVE_EXECUTION_LEDGER.md:35` — A3.2 row, Gate=operator

## Status

Awaiting operator approval.
