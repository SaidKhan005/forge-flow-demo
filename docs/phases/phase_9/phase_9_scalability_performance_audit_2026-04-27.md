# Phase 9 Scalability Performance Audit - 2026-04-27

Status: DOCUMENT AUDIT - architecture pressure test if implemented as presented.

Scope: this audit assumes the Phase 9 scalability decisions have been
implemented exactly as written in
`phase_9_scalability_decisions_2026-04-27.md`, including the vendor friction
guardrail, scale pressure-test guardrails, and performance-at-scale gates.

This is not a current-code audit. It is a performance audit of the proposed
plumbing if built as specified.

---

## Executive Verdict

Result: CONDITIONAL PASS.

The architecture is credible for scale if the guardrails are implemented
literally. It is not automatically scale-proof just because the schema and
health panels exist.

The design avoids the worst early traps:

- It keeps vendors simple.
- It keeps RLS as the launch isolation model.
- It avoids synchronous rollups.
- It makes graph/vector/search rebuildable projections.
- It separates real-time usage enforcement from delayed reporting rollups.
- It makes high-volume health visible in the F&F dev/admin UX.

The remaining risk is operational throughput:

- high-volume append tables
- worker backlogs
- cross-operator admin queries
- vendor backfills
- audit hash-chain writes
- rollup recomputation
- provider rate limits
- vector/graph growth

If these are implemented naively, the architecture will slow down or jam. If
they are implemented with partitioning, worker leasing, bounded scans,
rate-limit isolation, and load tests, the architecture can survive realistic
restaurant SaaS scale.

---

## Audit Standard

Each subsystem is judged as:

- **Pass:** design is sound and low risk if implemented normally.
- **Conditional pass:** design is sound only if the named gates are implemented.
- **Fail:** design creates a likely scale bottleneck or contradiction.

No subsystem receives a final production pass until it has synthetic Tier-M
proof or live-like load evidence for its hot path.

---

## Target Load Profiles To Prove

The implementation should test at least three synthetic profiles.

### Profile S - normal launch operator

- 1 to 5 locations
- 25 to 150 staff
- 1 POS connection
- 1 labor connection
- optional reservation connection
- daily reporting and advisor usage

This validates normal restaurant performance.

### Profile M - multi-location operator

- 25 to 75 locations
- 500 to 2,000 staff
- multiple vendor connections
- hierarchy rollups across region/district/location
- frequent dashboard and advisor use

This validates the first real scale wall.

### Profile Tier-M - large holding company

- 250 to 500 locations
- 5,000 to 25,000 staff
- multi-brand hierarchy
- heavy POS/labor/reservation/invoice ingest
- high audit volume
- high advisor/reporting volume
- F&F internal admin/debug usage

This validates whether the architecture survives the operator size it was
designed for.

Exact numbers can be tuned later, but the system must be tested with one
operator large enough to make bad query plans, unbounded tables, and worker
backlogs obvious.

---

## Hot Path Inventory

These are the performance-sensitive paths introduced or affected by the Phase 9
scalability decisions:

1. Login/session writes and auth audit rows.
2. Role/permission evaluation and RLS policy checks.
3. Operator hierarchy lookups and effective-location cache reads.
4. Vendor account connection and vendor-location mapping.
5. Vendor ingest, webhook handling, polling, and historical backfill.
6. Raw vendor import to canonical fact writes.
7. `event_outbox` publication to Pub/Sub.
8. Usage ledger/counter writes and cap checks.
9. Rollup job processing and report reads.
10. Audit log writes, hash-chain anchoring, archive, and query.
11. Advisor query routing, retrieval, model calls, and conversation logging.
12. Advisor learned-insight candidate creation and corpus promotion.
13. Vector search and reindexing.
14. AGE graph projection and traversal.
15. F&F dev/admin health, debug, and cross-operator views.

---

## Subsystem Audit

### 1. Shared Postgres + RLS

Rating: conditional pass.

What works:

- Shared-schema Postgres with RLS is reasonable for launch.
- `operator_id` leading indexes, `SET LOCAL`, and leakproof wrapper functions
  are the right performance discipline.
- RLS avoids premature DB-per-tenant complexity.

What can break:

- Cross-operator F&F admin queries can accidentally scan every tenant.
- Queries that join fact tables without tenant-leading indexes can fall off a
  cliff.
- RLS policies can hide planner issues until data volume grows.

Required gates:

- Every operator-scoped hot table has tenant-leading indexes.
- CI blocks non-tenant-leading indexes on operator-scoped fact tables unless
  explicitly exempted.
- Tier-M EXPLAIN plans are captured for dashboard reads, advisor tools, admin
  debug views, rollup reads, and permission checks.
- F&F admin list/search views use bounded filters, keyset pagination, summary
  tables, or read models.

Verdict:

The approach is valid. The danger is not RLS itself; the danger is letting
admin/debug/reporting queries bypass the tenant-leading discipline.

### 2. Org Hierarchy And `ltree`

Rating: pass with limits.

What works:

- Depth cap of 6 is sane.
- `ltree` is a good fit for subtree access checks and hierarchy reporting.
- `user_effective_locations` cache protects hot UI paths.

What can break:

- Moving a large subtree can update many paths.
- Reparenting can invalidate rollups, effective-location caches, and historical
  reporting assumptions.

Required gates:

- Large reparent operations run as bounded/asynchronous jobs.
- Hierarchy changes write audit rows.
- Historical reports keep the hierarchy version or `org_unit_path` active at
  the time.
- Cache invalidation is scoped to affected users/locations, not global.

Verdict:

Good architecture if hierarchy edits are treated as administrative jobs, not
casual hot-path updates.

### 3. Vendor Integration Mapping

Rating: conditional pass.

What works:

- Account-first vendor connection keeps operator/vendor friction low.
- Mapping vendor locations/resources to F&F locations internally is the right
  model.
- It supports one vendor account with many vendor locations.

What can break:

- Import workers can waste time resolving mappings row by row.
- Unmapped vendor locations can create repeated failures.
- Weak uniqueness rules can map one vendor resource to multiple F&F locations.

Required gates:

- Unique indexes on vendor mapping keys, such as
  `(operator_id, vendor_id, vendor_location_id)` or connection-scoped variants.
- Cached mapping lookup in ingest workers.
- Unmapped records go to quarantine with Vendor Integration Health alerts.
- Mapping changes are audited and trigger bounded recomputation where needed.

Verdict:

The model scales if mapping is indexed and unresolved mappings stop retrying
expensively.

### 4. Vendor Ingestion And Backfill

Rating: conditional pass.

What works:

- Keeping Phase 8 vendor integration simple is correct.
- Internal sync cursors and health state can absorb vendor weirdness.
- Read-only inbound finance lowers risk.

What can break:

- One noisy vendor connection can consume worker capacity.
- Historical backfill can starve live incremental updates.
- Vendor token refresh failures can cascade if not isolated.
- Polling APIs can hit rate limits quickly across many locations.

Required gates:

- Per connection sync cursor.
- Per connection retry/backoff state.
- Per vendor/operator rate-limit state.
- Separate queues or priorities for live sync and backfill.
- Token refresh isolation.
- Dead-letter/quarantine for malformed payloads.
- Vendor Integration Health shows lag, error class, next retry, and affected
  product surfaces.

Verdict:

The design can scale, but only if ingestion is treated like a multi-tenant
worker system, not a set of simple cron jobs.

### 5. Event Outbox And Pub/Sub Bridge

Rating: conditional pass.

What works:

- `event_outbox` as durable truth is the right call.
- `NOTIFY` as a wake-up signal only avoids relying on an unsafe queue.
- Pub/Sub is appropriate for downstream fanout.

What can break:

- A single unpartitioned outbox table will grow hot.
- Workers can double-process rows without leasing/idempotency.
- Poison messages can retry forever.

Required gates:

- Partition outbox by time and/or shard.
- Workers claim rows with leases.
- Every event has an idempotency key.
- Retry count and next-attempt timestamp are stored.
- Dead-letter status exists.
- Delivery timestamp and Pub/Sub acknowledgement are recorded.
- Retention cleanup removes old delivered rows safely.
- Event Bridge Health shows lag, undelivered rows, dead letters, worker count,
  and affected functionality.

Verdict:

Good pattern. It fails only if implemented as "a table workers poll" without
queue mechanics.

### 6. Usage Cap Enforcement

Rating: conditional pass.

What works:

- Two-slot cap key is flexible.
- Separating billing owner from scoped usage is correct.
- Rollups are correctly not the enforcement source.

What can break:

- Scanning `usage_logs` on every usage check will fail.
- Updating one global counter row can create contention for large operators.
- Cap inheritance can become expensive if resolved dynamically on every call.

Required gates:

- Atomic real-time counters or ledger buckets.
- Cap resolution cache keyed by operator/scope/usage class.
- Contention tests for hot AI/workflow usage.
- Idempotency for retried usage events.
- Dashboard rollups read summaries, not the enforcement hot path.

Verdict:

The decision is right. The implementation must avoid log scans and hot global
rows.

### 7. Rollups

Rating: conditional pass.

What works:

- Physical rollup tables are right for operator-facing reporting.
- Incremental batch avoids write-time contention.
- Bounded recomputation is the correct late-data strategy.

What can break:

- Dimension explosion can create too many rows.
- Large backfills can keep rollups stale for hours.
- UPSERT-heavy jobs can create hot rows if all updates hit one root rollup.
- `pg_cron` alone does not give worker sharding.

Required gates:

- Cardinality budget for each rollup dimension.
- Rollup tables partitioned by operator/period where needed.
- Worker leasing for rollup jobs.
- Separate hot/cold refresh cadence.
- Bounded recomputation windows.
- Staging/promote rebuild pattern for large rebuilds.
- Rollup Health alerts for lag, failure, retries, stale reports, and row-count
  anomalies.

Verdict:

The architecture is strong, but scale depends on worker design and dimension
discipline.

### 8. Audit Logs And Hash Chaining

Rating: conditional pass.

What works:

- Append-only audit logs are required.
- Hash chaining plus immutable daily anchors gives tamper evidence.
- Seven-year retention is practical if partitioned.

What can break:

- One global hash chain serializes every write.
- JSON payload indexes can bloat.
- Seven-year hot retention can bury queries if partitions are not managed.

Required gates:

- Hash chain scope is bounded, for example operator/day or table/day.
- Audit tables are partitioned.
- Hot indexes cover operator, actor, target, event type, and time.
- JSON indexing is limited to known audit query needs.
- Archive/drop flow verifies hash anchors before purging.
- Legal hold blocks partition deletion.

Verdict:

Correct security design, but it needs partitioned hash chains to avoid a
performance trap.

### 9. Advisor Conversation Logging

Rating: conditional pass.

What works:

- Deterministic replay metadata is needed.
- Raw encrypted payloads are separated from queryable hashes/metadata.
- Logs protect both F&F and operators in disputes.

What can break:

- Advisor logs can grow faster than normal audit logs.
- Decrypting raw content for ordinary searches would be too slow and too
  risky.
- Retention/legal-hold interactions can get expensive if not partitioned.

Required gates:

- Partition by time and operator.
- Keep raw encrypted payloads off hot query paths.
- Query by metadata/hashes/chunk IDs/model IDs.
- Redaction ledger handles raw payload removal without breaking metadata.
- Advisor Conversation Health shows write failures, lag, volume, and retention
  status.

Verdict:

The design is valid if raw content is not part of normal query paths.

### 10. Advisor Learned Insights

Rating: conditional pass.

What works:

- Model remains stateless.
- F&F-owned approved memory is better than silent model memory.
- Human approval protects quality and privacy.

What can break:

- Candidate volume can become noisy.
- Search can slow if every candidate is treated like hot corpus.
- Operator-specific lessons can leak if scoping is weak.

Required gates:

- Candidate table is partitioned or at least indexed by operator/status/topic.
- Hybrid search is scoped before retrieval.
- Promotion pipeline uses the existing corpus path.
- Approved lessons store scope and provenance.
- Sensitive redaction reviews linked candidates and promoted chunks.

Verdict:

Good architecture if it is treated as reviewed corpus workflow, not automatic
memory.

### 11. AI Provider Calls

Rating: conditional pass.

What works:

- Anthropic primary with no silent fallback is safer.
- Provider abstraction keeps future fallback possible.
- Conversation logs capture provider/model identity.

What can break:

- Provider rate limits can become the actual bottleneck.
- Retry storms can multiply cost.
- Large prompts can crush latency and spend.

Required gates:

- Per operator/model/query-class concurrency limits.
- Circuit breakers.
- Retry with backoff and bounded attempts.
- Token/cost caps.
- Prompt-cache TTL assertions.
- Graceful temporary-unavailable responses.
- Provider Health tracks latency, error rate, throttle rate, cache hit rate,
  and cost.

Verdict:

Database scale is not enough. The AI proxy must be a rate-limited control
plane.

### 12. Vector Search

Rating: conditional pass.

What works:

- HNSW at launch and DiskANN later is reasonable.
- Provider-versioned embeddings avoid lock-in.
- Canonical chunk text remains source truth.

What can break:

- Filtered vector search may degrade before raw vector count hits 10M.
- Reindexing can exceed maintenance windows.
- Parallel provider indexes can double storage and build time.

Required gates:

- Vector indexes scoped by corpus/provider/model/lang.
- Filtered-search benchmarks included, not only unfiltered recall.
- DiskANN shadow index can build side-by-side.
- Canary routing validates recall and latency before cutover.
- Vector Index Health tracks count, index type, build status, recall, latency,
  timeout, growth, and recommended action.

Verdict:

Good if filtered search is benchmarked. Raw vector count alone is not enough.

### 13. Graph / AGE

Rating: conditional pass.

What works:

- AGE as a projection is acceptable.
- Canonical Postgres graph tables preserve escape hatches.
- Tripwires at 3M/4M edges are useful.

What can break:

- High-degree nodes can hurt before total edge count looks scary.
- Direct AGE queries spread through app code make future Neo4j migration hard.
- Projection drift can corrupt advisor answers.

Required gates:

- Graph queries go through a provider interface.
- Projection jobs are deterministic.
- High-degree nodes, traversal latency, timeout rate, and failed traversals are
  monitored.
- Red tripwire actions are non-destructive.
- Canonical `graph_nodes` / `graph_edges` can rebuild AGE.

Verdict:

Valid if AGE is never treated as source truth.

### 14. F&F Dev/Admin Health UX

Rating: conditional pass.

What works:

- Making health visible in product UX is a strong operating model.
- Plain-language alerts reduce support load.
- Actionable health states are better than raw logs.

What can break:

- Alert noise can make the panel useless.
- Cross-operator health pages can become expensive queries.
- Missing actions turn health UX into decoration.

Required gates:

- Alerts are deduplicated and severity-ranked.
- Health pages use summary/read models.
- Every alert has owner, impact, affected functionality, next action, and
  runbook/action link.
- Large exports or historical health reviews run as jobs.

Verdict:

The UX idea is excellent. The performance risk is cross-operator health pages
scanning raw operational tables.

### 15. Internal Admin Access

Rating: conditional pass.

What works:

- F&F-controlled internal admin access matches the operational reality.
- Dynamic roles are better than hidden JWT bypass.
- `target_operator_id` context keeps actions attributable.

What can break:

- Broad internal access can create expensive cross-tenant queries.
- Debug views can expose raw high-volume logs.
- Destructive actions can create support incidents.

Required gates:

- Read/write/destructive/billing/privacy/integration-secret permissions are
  separated.
- Admin list views are paginated and filtered.
- Large queries become export jobs.
- Dangerous actions require confirmation and audit.
- Admin query paths have their own benchmarks.

Verdict:

Operationally necessary, but must be treated as a privileged product surface
with strict performance boundaries.

### 16. Multi-region Readiness

Rating: conditional pass.

What works:

- Region metadata now avoids a total future rewrite.
- Single launch region keeps initial complexity sane.

What can break:

- Jobs, exports, audit anchors, vendor webhooks, and support tools can quietly
  assume one region.
- Future region split is still a real migration project.

Required gates:

- Region context is accepted by jobs, backups, exports, audit anchors, vendor
  connection routing, and support tooling.
- No silent cross-region customer-data replication.
- Future region endpoints are explicitly productized when needed.

Verdict:

Good future-proofing, not a solved multi-region system.

---

## Bottleneck Ranking

Most likely to fail first if implemented lazily:

1. Cross-operator admin/debug queries.
2. Unpartitioned audit/event/advisor log tables.
3. Rollup worker backlog.
4. Vendor backfill starving live sync.
5. Provider rate limits and retry storms.
6. Filtered vector search degradation.
7. AGE high-degree node traversals.
8. Usage cap contention on hot counters.
9. Alert noise in Dev/Admin Health.
10. Large hierarchy reparent operations.

---

## Prelaunch Performance Test Matrix

These tests should run before production launch.

| Area | Test | Pass Condition |
| --- | --- | --- |
| RLS | Tier-M operator dashboard/report queries with RLS enabled | Plans use tenant-leading indexes and bounded scans |
| Admin | Cross-operator admin list/search/debug views | Pagination/keyset/read models prevent whole-table scans |
| Audit | Sustained audit writes plus hash-chain anchoring | No global serialization bottleneck; anchors verify |
| Outbox | Burst events, worker crash, retry, dead-letter | No lost events; no duplicate side effects |
| Usage | High-concurrency usage cap checks | Atomic counters/ledger avoid double-spend and hot-row collapse |
| Vendor mapping | Millions of vendor rows mapped to F&F locations | Indexed lookups; unmapped rows quarantine quickly |
| Vendor backfill | Large historical import while live sync runs | Live sync remains within freshness target |
| Rollups | Late data and bounded recomputation | Stale windows are bounded; unrelated reports continue |
| Advisor logs | High advisor turn volume | Metadata query remains fast; raw encrypted content stays cold |
| AI providers | Rate-limit and 5xx simulation | Backoff/circuit breaker prevents retry storm |
| Vector | Filtered retrieval benchmark | Recall/latency thresholds hold under scoped filters |
| Graph | High-degree and deep traversal benchmark | Tripwires fire before user-visible failures |
| Health UX | Simulated red/yellow alerts | Deduped, scoped, actionable alerts with owner/runbook |
| Region hooks | Run jobs/exports with explicit region context | No hidden one-region assumptions in interfaces |

---

## Final Finding

If implemented as presented, the design is not reckless. It is a serious,
scale-aware architecture.

But it is not self-validating. The success condition is disciplined
implementation:

- partition high-volume tables
- shard worker jobs
- benchmark RLS and report queries
- isolate vendor failures
- keep graph/vector/search rebuildable
- enforce usage caps in real time
- make health alerts actionable
- prevent cross-operator admin scans

The vendor integration experience can remain simple. The internal plumbing can
survive scale. But only if the load-test gates are treated as launch blockers,
not polish.
