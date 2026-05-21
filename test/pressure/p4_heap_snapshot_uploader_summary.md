# p4_heap_snapshot_uploader — HeapSnapshotUploader + Azure Blob target

**Runner:** `test/pressure/p4_heap_snapshot_uploader_test.dart`
(unit tests for `tool/pressure/p4_heap_snapshot_uploader.dart` +
`AzureBlobHeapSnapshotUploadTarget` wire shape)

**What it pressures:** the soak-run heap-snapshot capture-and-upload
seam used by `p4_soak_orchestrator` (Wave 2 Lane Q slice Q-1). Catches
regressions in the env-gated skip behavior, the concurrent-tick
guard, the structured-log shape consumers parse, and the Azure Blob
PUT wire (URI shape, headers, bearer scrubbing, status-code mapping).

**Status at f0bf2702:** PASS. Deterministic; uses stub
`HeapSnapshotCapturer` + `HeapSnapshotUploadTarget` doubles plus an
`AzureBlobHttpRequester` recording double.

## Inputs

- No env vars. Hermetic; scratch directory under
  `Directory.systemTemp` for synthetic snapshot bytes.
- Production target reads:
  - `AZURE_BLOB_HEAP_SNAPSHOTS_CONTAINER`
  - `AZURE_BLOB_HEAP_SNAPSHOTS_ENDPOINT`
  - `AZURE_AD_TENANT_ID`
  - `AZURE_AD_CLIENT_ID`
  All four must be set for `isConfigured == true`.

## What it asserts

- Happy path: trigger fires → capture + upload + ONE
  `soak.heap_snapshot.uploaded` log line carrying pod/run ids + size.
- Unconfigured target: emits ONE `soak.heap_snapshot.skipped` line
  with the env var that's missing; never invokes capture/upload.
- Trigger false: no capture, no upload, no log line.
- Capture failure: structured `soak.heap_snapshot.error` line with
  `stage: capture`; uploader does NOT throw or upload.
- Upload failure: structured error with `stage: upload`; upload count
  stays 0.
- Concurrent `tick()` calls: `_busy` guard collapses to exactly ONE
  in-flight upload.
- Azure target: PUT to `<endpoint>/<container>/heap-snapshots/<run>/<pod>/...`
  with bearer, `x-ms-version: 2021-12-02`, `x-ms-blob-type: BlockBlob`;
  non-2xx raises `HttpException` whose message NEVER contains the
  bearer token.
- Doctrine guard: the soak container name is NOT the audit-anchor
  immutable container (audit chain anchors stay separate from mutable
  developer-debug artifacts).

## How to read the output

- Healthy run: all unit tests pass; emitted JSON lines decode with the
  documented `metric`, `stage`, `pod_id`, `run_id`, `size_bytes` keys.
- Regression: any of the env-var keys above being treated as optional,
  bearer leaking into an error message, or the soak container being
  pointed at the audit-anchor container — all break compliance
  evidence guarantees.

## Related

- Authority: `docs/_audits/code_health/code_hardening_plan_2026_05_21.md`
  §2.4, backlog item #10
- Production code: `tool/pressure/p4_heap_snapshot_uploader.dart`,
  `tool/audit_anchor/azure_blob_client.dart`
- Consumer: `tool/pressure/p4_soak_orchestrator.dart`
- Last touched: see `git log -- test/pressure/p4_heap_snapshot_uploader_test.dart`
