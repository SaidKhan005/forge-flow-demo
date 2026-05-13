# PR #537 Audit — A11.2 Soak Harness Durable Extensions

**Slice:** A11.2 (Lane A — code health)
**Owner:** Claude lane executor
**Branch:** `claude/a11-2-soak-harness-durable-extensions`
**Base:** `master`
**Gate:** `operator` per ledger + explicit operator-decision item flagged in PR body (GCS vs Azure backend choice)
**Size:** 1876 additions / 5 deletions / 6 files
**Chunking:** light variant (6 files, all in `tool/pressure/` + `test/pressure/`, file-disjoint from any open PR)
**Dependency:** A11.1 merged ✓

## Pattern B compliance

PR body includes the 14-lens self-audit with key verdicts cited inline. Lens N/A markers carry rationale (Lenses 1, 2, 4, 5, 9, 10 marked N/A appropriately for tool/test-only changes). Lens 8 explicitly flags an operator-decision item (env vars). Acceptable Pattern B compliance.

## Verdict

**approve-pending-operator** — escalating per Gate=operator + explicit GCS/Azure backend decision item.

## Executor spot-checks

| Check | Outcome |
|---|---|
| **Storage-agnostic interface design** — `HeapSnapshotUploadTarget` abstraction allows GCS/Azure swap without rewriting polling/triggering/error-handling | ✓ — verified in diff: `HeapSnapshotUploadTarget` is an interface (`isConfigured` getter + `upload({bytes, contentType, timestamp})` method). `GcsHeapSnapshotUploadTarget` is one concrete impl. Future `AzureBlobHeapSnapshotUploadTarget` slots in identically. The test file's `_StubUploadTarget` implementing the same interface is proof the abstraction is decoupled |
| **3 new harness files** in `tool/pressure/` | ✓ — `p4_fd_watcher.dart` (189 LoC), `p4_heap_snapshot_uploader.dart` (398 LoC), and `p3c_oauth_refresh_storm.dart` extended (+301/-5) |
| **3 new test files** in `test/pressure/`, 31 new tests pass | ✓ — `p4_fd_watcher_test.dart` (244 LoC), `p4_heap_snapshot_uploader_test.dart` (376 LoC), `p3c_oauth_refresh_storm_cli_test.dart` (373 LoC). Tests cover happy path + cross-platform no-op + threshold/trigger conditions + capture-failure recovery + unknown-flag rejection via subprocess |
| **Zero new pubspec deps** | ✓ — disclosed in PR body Lens 14. Uses `dart:async`, `dart:convert`, `dart:io`, `dart:developer`, `dart:math` + existing direct dep `crypto` + dev-dep `flutter_test` |
| **CLI flag validation** — `--ttl-dist`, `--vendor-mix`, `--jitter` reject unknown values with stderr | ✓ — `p3c_oauth_refresh_storm_cli_test.dart` includes subprocess-spawn tests using `Process.run` with `runInShell` for Windows compatibility |
| **Cross-platform FD-watcher no-op** on Windows/macOS | ✓ — worker disclosed Windows demo output: `{"ts":"...","metric":"soak.fd_count","value":null,"platform":"windows","note":"fd_watcher: /proc/self/fd not available; watcher is a no-op on this platform"}` — emits one note line, `isPolling=false`, no throw |
| **Uploader inert when env vars unset** — emits one `"skipped"` log line at start, harness keeps running | ✓ — design verified in `HeapSnapshotUploader._isUploadTargetConfigured` gate; test `upload throws when called while unconfigured` confirms the boundary; harness honors it |
| **HP #7 (server-side keys) compliance** — `GCS_BEARER_TOKEN` read from env, never embedded | ✓ — disclosed in PR body Lens 7 |
| **Time discipline** — all `ts` fields are `DateTime.now().toUtc().toIso8601String()`, injected `clock` callback for test determinism | ✓ — disclosed in PR body Lens 6 |
| **Pre-existing closure-registry failures unchanged** (per `KNOWN_FAILING_TESTS.md` from A10.1) | ✓ — worker disclosed they're NOT regressed |
| **File-disjoint from open PRs** (when authored: #526 docs, #533 CI lint) | ✓ — diff scope: 6 files all in `tool/pressure/` or `test/pressure/`. Zero overlap with proxy code, CI workflows, contract docs |
| **No tracker / ledger / runbook touch** | ✓ — disclosed in PR body. The cloud-side prerequisites (`runbooks/cloud_run_env_vars.md` update) explicitly deferred to orchestrator |
| **Pre-push hooks clean, no `--no-verify`** | ✓ — disclosed |

## Operator-decision item: GCS vs Azure Blob backend

**Worker flagged this in the PR body**: the slice doc specifies GCS for heap-snapshot upload, but F&F's existing immutable-storage pattern is **Azure Blob** (`tool/audit_anchor/azure_blob_client.dart`).

**Worker's choice**: implement the slice doc's GCS spec (raw GCS REST PUT via `dart:io HttpClient` + bearer-token auth), but **build the upload path behind a storage-agnostic interface** so a future slice can swap backends without rewriting polling/triggering/error-handling.

**The decision the operator needs to make**: keep GCS now, swap to Azure now, or defer.

**Orchestrator analysis**:
- **Option A (keep GCS)**: matches the slice doc verbatim. Costs ~zero rework if a future slice does swap. Inconsistent with F&F's Azure-Blob pattern.
- **Option B (swap to Azure now)**: requires building `AzureBlobHeapSnapshotUploadTarget` analog of the existing `azure_blob_client.dart` pattern (well-trodden ground). Aligns with F&F's audit-anchor pattern + workload-identity-federation flow. ~1-2 hour follow-up.
- **Option C (defer)**: merge as-is, decide later when soak runs actually need uploads. Zero immediate work.

**Storage-agnostic interface stands regardless** — it's the load-bearing architectural artifact. The backend choice is hot-swappable.

## Recommendation

**approve-for-merge** with Option C (defer the backend decision). Reasons:
- The uploader is INERT today (env vars unset) — no production behavior changes either way
- The abstraction is sound; the backend choice is reversible
- The slice already passes its 14-lens self-audit and 31/31 new tests
- A follow-up slice can swap to Azure Blob when soak runs actually need uploads, with clear authority anchor in `tool/audit_anchor/azure_blob_client.dart`

If approved, I will merge + update the ledger (A11.2 → merged) + open a tracker note for the deferred GCS-vs-Azure decision under `docs/POST_HARDENING_FOLLOWUPS.md`.

## Authority anchors verified

- `docs/_execution/lane_a_code_health/03_execution_slices.md` "Slice A11.2 — Soak Harness Durable Extensions" (scope matches diff)
- R3 §3 + §4 quick-wins (cross-referenced from `runbooks/cloud_run_env_vars.md`)
- A11.1 (PR #522) — gauge plumbing this slice extends; still live on master

## Findings

None blocking. One operator-decision item (GCS vs Azure backend choice — orchestrator recommends Option C/defer).

## Status

Awaiting operator approval + backend-decision answer.
