# Wave Audit — Cross-Slice Integration

**Master tip:** `63b67753`
**Auditor:** read-only agent (8 of 8)
**Dimension:** Cross-slice integration — boundaries between L_A1 / L_A2 / B6 / B8 / B8.b / C-6, C-1a / C-1 / C-2-F / C-2-C / C-2-D / C-2-D-binding, C-7a / C-7, and B11.1 / B11.2 / B11.2.b / C-5
**Method:** Read-only source trace at master tip `63b67753` using `git show 63b67753:<path>` (worktree HEAD `63ec00d6` pre-dates B6/B8.b/C-7/C-2-D-binding merges)

---

## Verdict

**Approve-with-observations.** The four multi-slice chains compose correctly at the seams. Every integration point (predicates, idempotency keys, audit actions, template variables, transaction boundaries, cross-tenant `withSystem` reasons) lines up. No security-relevant gap. Three honest-disclosure findings worth surfacing for the closeout:

1. **F1 — INFO:** L_A1's three new repository methods (`getOrgUnitTreeForOperator`, `getDescendantLocations`, `getNodeForLocation`) have **no production callers** in `lib/` or `tool/` at master tip. The downstream consumers (B6, B8, C-6, B8.b) either (a) reimplement the ltree predicate inline, or (b) build the inheritance tree client-side from existing `WebTeamHierarchyGateway` data. L_A1's widget half (`InheritanceTree`) IS consumed by all 5 downstream UI surfaces.

2. **F2 — INFO:** L_A2's `InheritanceDescendantCache` is shipped + tested + has no production caller. The only mention of `InheritanceDescendantCache` outside its own source + tests is a comment block in `tool/advisor_proxy/audit_log_hierarchy_routes.dart:181-188` explaining why the route deliberately does NOT consult it. The L_A2-disclosed "no call-site wiring" forward-looking gap is therefore still open.

3. **F3 — INFO:** Audit doc at `pr_629_c_2_c_mfa_factor_changed_wire_audit.md:34` says the new audit action is `system.mfa_factor_changed_notice_audit`. The actual code emits `eventType: 'mfa_factor_changed_email_enqueued'` (`lib/services/mfa/mfa_factor_changed_notice_dispatcher.dart:241`). Cosmetic doc drift; the action remains distinct from the other two dispatchers in the wave.

The B11.2.b clock-skew (B9.2) fix is genuinely closed (boundary tests pin +0/+30/+59/+60/+61s at `web_account_gateway.dart:88`). C-5's mobile handoff redemption flow uses B11.1's body-only redeem contract correctly. C-1's `ON CONFLICT (provider_event_id) WHERE provider_event_id IS NOT NULL DO NOTHING` matches C-1a's partial UNIQUE INDEX predicate byte-for-byte. All three email-pipeline dispatchers (C-2-F, C-2-C, C-2-D) supply every `{{variable}}` referenced by their templates. The C-2-D production binding correctly threads the outage observer through `runCli` → `buildWorkerRuntime` → `IntegrationSyncWorkerLoop`. Every new cross-tenant lookup uses `withSystem(reason:)` with a stable reason string.

---

## Hierarchy chain (L_A1 → L_A2 → B6 / B8 / C-6 / B8.b)

### Verdict: APPROVED, with two non-blocking observations on consumer wiring

### What I traced

| Slice | Surface | File evidence |
|---|---|---|
| L_A1 widget | `lib/widgets/inheritance_tree.dart` — `InheritanceTree(rootNode, annotationBuilder, onNodeTap, …)` | `git show 63b67753:lib/widgets/inheritance_tree.dart` (320 LoC, pure visualization) |
| L_A1 repository methods | `lib/infrastructure/persistence/postgres/repositories/org_units_repository.dart:890,950,1022` | `getOrgUnitTreeForOperator`, `getDescendantLocations`, `getNodeForLocation` |
| L_A1 selector preserved | `lib/operator_web/widgets/org_unit_tree_view.dart` — untouched, still the selector | `git show 63b67753:lib/operator_web/widgets/org_unit_tree_view.dart:25-50` |
| L_A2 cache | `lib/services/hierarchy/inheritance_descendant_cache.dart` — keyed on `(operatorId, scopeOrgUnitId?)`, default `enabled: false` | `:64-93` (key class), `:124-151` (ctor with `enabled = false`) |
| B6 resolver | `lib/services/baseline/benchmark_override_resolver.dart` — pure in-memory matcher; receives `ancestorOrgUnitIdsNearestFirst` from caller | `git show 63b67753:lib/services/baseline/benchmark_override_resolver.dart` |
| B6 screen | `lib/operator_web/screens/benchmarks_screen.dart:329-340` — calls `_resolver.resolve(...)` with `(node.metadata['ancestor_ids_nearest'] as List<String>?) ?? const <String>[]` |  |
| B6 tree builder | `lib/operator_web/screens/benchmarks_screen.dart:397-475` — builds `InheritanceTreeNode` locally from `TeamOrgUnitEntry`/`TeamOrgLocationEntry` (existing `WebTeamHierarchyGateway` shape) |  |
| B8 admin reader | `lib/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart:435-535` — `AuditLogsReader.listByHierarchy` extends `OperatorScopedRepository`, runs via `withTenant`, reimplements the ltree predicate inline |  |
| B8 admin route | `tool/advisor_proxy/audit_log_hierarchy_routes.dart` — `AuditLogHierarchyRouter.tryHandle` (sibling-file) calls `gateway.listByHierarchy(...)` which delegates to `AuditLogsReader` |  |
| C-6 operator-web hierarchy screen | `lib/operator_web/screens/hierarchy_screen.dart:425,500` — wraps `InheritanceTree(...)` in `_OperatorWebHierarchyInheritanceTree` adapter; builds the tree locally from `WebTeamHierarchyGateway` |  |
| C-6 admin roles tab | `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart:1428` — same adoption pattern |  |
| B8.b operator-web parity | `lib/operator_web/screens/audit_log_hierarchy_filter_pane.dart:372` — `InheritanceTree(rootNode: rootNode, onNodeTap: _onNodeTap, annotationBuilder: …)` |  |
| B8.b proxy route | `tool/advisor_proxy/operator_web_audit_log_hierarchy_routes.dart:215-249` — `OperatorWebRepositoryAuditLogHierarchyGateway` binds the **same** `AuditLogsReader.listByHierarchy` shared with admin |  |

### Visualization-not-selector contract (L_A1)

The widget at `lib/widgets/inheritance_tree.dart:1-25` is explicit: "VISUALIZATION (not a selector)." Confirmed:

- B6's screen passes `onNodeTap: _onSelectNode` to capture selection state internally, but the widget itself remains read-only.
- B8 admin route doesn't even use the widget — it's a server-side ltree predicate.
- C-6 + B8.b mount the widget as a tree view; selection / mutation lives in adjacent selectors (operator-web `org_unit_tree_view.dart` for mutate; the hierarchy_filter_pane's own state for filtering).
- The pre-existing `org_unit_tree_view.dart` selector is UNCHANGED on master (`git ls-tree 63b67753 lib/operator_web/widgets/org_unit_tree_view.dart` = same blob as pre-L_A1).

**Contract holds.** ✓

### L_A1 repository methods: who's calling them?

Searched `git grep -n "getOrgUnitTreeForOperator\|getNodeForLocation\|getDescendantLocations\b" 63b67753 -- 'lib/' 'tool/'`:

- `getOrgUnitTreeForOperator` — definition only at `lib/infrastructure/persistence/postgres/repositories/org_units_repository.dart:890`; widget docstring reference at `lib/widgets/inheritance_tree.dart:50`. **Zero production callers.**
- `getDescendantLocations` — definition at `:950`; cache wraps it at `lib/services/hierarchy/inheritance_descendant_cache.dart:192,218`; comment-only at `lib/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart:19`. **Zero direct production callers** (the cache wrapper IS code, but the cache itself has zero callers, see F2).
- `getNodeForLocation` — definition at `:1022`; docstring references only. **Zero production callers.**

**B8 reuses the SHAPE not the METHOD.** `audit_logs_repository.dart:494-502` reimplements the ltree predicate inline as a subquery in the SQL FROM clause:

```sql
join public.locations l
  on l.location_id = al.location_id
 and l.deleted_at is null
 and l.org_unit_path <@ (
     select path from public.org_units
      where id = @org_unit_id::uuid
        and deleted_at is null
 )
```

This is identical in shape to L_A1's `getDescendantLocations` SQL (verified by inspection), but B8 inlines it because the audit-log read needs to do the join-and-filter in a single tenant transaction with the audit ltree predicate; calling `getDescendantLocations` separately would force two `withTenant` round-trips and lose the join optimizer's ability to push the predicate into `audit_logs`. The audit at `pr_624_b8_audit_log_hierarchy_filter_audit.md` documents this as an architectural choice; the comment at `audit_log_hierarchy_routes.dart:181-188` reaffirms it.

**B6 doesn't use any of L_A1's methods at all.** The resolver (`lib/services/baseline/benchmark_override_resolver.dart`) is a pure in-memory matcher: callers pre-load the candidate set + ancestor chain, then `resolve(...)` walks them locally. The B6 operator-web screen builds the inheritance tree client-side from `WebTeamHierarchyGateway` (which existed pre-L_A1). The resolver could be called with ancestor lists from any source, including L_A1's tree — but in practice, the only caller is `BenchmarksScreen` which uses its own local tree builder.

**Finding F1 (INFO):** L_A1's repository half is reachable through tests only at master tip. The widget half (`InheritanceTree`) is well-consumed (5 surfaces). The repository methods' value at V1 is foundational — they pre-pave for a future slice that wants server-side tree assembly without duplicating the `_assembleTree` static helper. No bug; honest disclosure.

### L_A2 cache: who's opting in?

Searched `git grep -l "InheritanceDescendantCache" 63b67753 -- 'lib/' 'tool/'`:

```
lib/services/hierarchy/inheritance_descendant_cache.dart       (definition)
tool/advisor_proxy/audit_log_hierarchy_routes.dart             (comment-only)
```

The single reference outside the cache file itself is at `audit_log_hierarchy_routes.dart:181-188` — a 7-line architectural-choice note explaining why the route does NOT thread the cache through. **Zero production instantiations.** Cross-tenant key shape preserved (`InheritanceDescendantCacheKey` line 64-93: `(operatorId, scopeOrgUnitId)`); since nobody calls it, the key shape only matters for tests.

**Finding F2 (INFO):** L_A2's disclosed "no call-site wiring" forward-looking gap remains open at wave close. No production consumer calls `getDescendantLocationsCached`. No production code calls `invalidate()` (verified by `git grep -n "\.invalidate\b" 63b67753 -- 'lib/' 'tool/'` → only `rollup.invalidate.*` topic strings, no cache invalidation). The cache is a primitive shipped for a future slice's opt-in. Default-off posture preserved (`InheritanceDescendantCache({…, bool enabled = false, …})` at `:124-126`).

This is acceptable per L_A2's design — the cache was deliberately shipped default-OFF — but the closeout doc should note that the "benefit" of L_A2 (latency optimization on the common scope-fan-out path) is not yet realized in production.

### B8.b parity: same reader, different gateway

`tool/advisor_proxy/operator_web_audit_log_hierarchy_routes.dart:215-249` wraps `AuditLogsReader` (the same `extends OperatorScopedRepository` class used by B8) in `OperatorWebRepositoryAuditLogHierarchyGateway`. The route differs in:

- Auth posture (operator-side JWT instead of `super_admin/ff_support`)
- Permission gate (`team.audit_log.view` instead of role-set)
- No `admin_reason` header requirement (the JWT identifies the actor)

But the **read path through `listByHierarchy` is identical**, so the ltree predicate, the RLS clamp, and the per-tenant transaction discipline are shared between admin (B8) and operator-web (B8.b). One bug fix in the reader benefits both surfaces. ✓

### Hierarchy mutation → cache invalidation gap

L_A2's docstring at `:241-243` explicitly disclosed: "Callers MUST invoke this after any write that changes the descendant set of a scope — for V1 this means moves/suspends/deletes on `org_units` or `locations`. B6/B8 wire the call sites when they ship; L_A2 provides the seam."

Search for actual invalidate() callers: none. B6 doesn't mutate the hierarchy (it writes `benchmark_overrides`, not `org_units`). B8 + B8.b are read-only. The org_units mutation lifecycle lives in the operator-web hierarchy screen (`hierarchy_screen.dart`) + the admin roles screen (`roles_hierarchy_sessions_admin_screen.dart`), and neither of those touches `InheritanceDescendantCache.invalidate()`. Since the cache has zero callers, this is moot — stale reads cannot happen because there are no reads. But if a future slice DOES wire `getDescendantLocationsCached`, the invalidation gap will become live.

**Acceptable at V1.** TTL-based self-heal (60s default at `:53`) gives a single-pod safety net; multi-pod will need explicit invalidation or shorter TTL.

---

## Email pipeline chain (C-1a → C-1 → C-2-* → C-2-D-binding)

### Verdict: APPROVED. The chain is correct end-to-end.

### Dedupe predicate match (C-1a ↔ C-1)

**C-1a migration** (`db/migrations/202605131700_c_1a_email_event_provider_id.sql:137-139`):

```sql
create unique index if not exists email_event_provider_event_id_unique
  on public.email_event (provider_event_id)
  where provider_event_id is not null;
```

**C-1 INSERT** (`lib/infrastructure/persistence/postgres/repositories/email_event_repository.dart:145-164`):

```sql
insert into public.email_event (
  provider_event_id, event_kind, event_payload,
  occurred_at, received_at, provider_message_id
) values (
  @provider_event_id, @event_kind, @event_payload::jsonb,
  @occurred_at::timestamptz, @received_at::timestamptz,
  @provider_message_id
)
on conflict (provider_event_id)
  where provider_event_id is not null
do nothing
returning event_id::text as event_id
```

**Byte-for-byte match on `WHERE provider_event_id IS NOT NULL`.** The repository's docstring at `:34-52` documents the predicate-must-match rule explicitly, citing Postgres docs §7.8. ✓

### Three dispatchers share the email_outbox shape

Each dispatcher INSERTs into `public.email_outbox` with the same column set; minor differences are intentional:

| Dispatcher | File | INSERT columns | Has `user_id`? | Idempotency-key strategy |
|---|---|---|---|---|
| C-2-F | `tool/oauth_refresh_worker/vendor_connection_auto_disabled_dispatcher.dart:271-292` | `operator_id, recipient_email, recipient_display_name, template_id, template_data, scheduled_for, status, attempt_count` | NO (operator-level system notice) | SELECT-then-INSERT collapse on `template_data->>'idempotency_key'` |
| C-2-C | `lib/services/mfa/mfa_factor_changed_notice_dispatcher.dart:95-113` | `operator_id, user_id, recipient_email, recipient_display_name, template_id, template_data, scheduled_for, status, attempt_count` | YES (1:1 user-targeted) | Worker's `markCompletedInTransaction > 0` short-circuit |
| C-2-D | `tool/integration_sync_worker/vendor_sync_outage_email_bindings.dart:259-280` | `operator_id, recipient_email, recipient_display_name, template_id, template_data, scheduled_for, status, attempt_count` | NO (operator-level admin notice) | Detector's `vendor_sync_outage_state.notified_at IS NOT NULL` guard |

**No column mismatch.** `user_id` presence-vs-absence is correct: MFA-factor-changed targets the specific user whose factor was removed; the other two target the operator's admin contact.

### Template-variable consistency

| Template (`.md` file) | Variables referenced | Dispatcher template_data | Match |
|---|---|---|---|
| `vendor_connection_auto_disabled.md` | `vendorName`, `recipientName`, `disabledAtHumanReadable`, `strikeCount`, `lastErrorSummary`, `integrationConsoleUrl` | `vendor_connection_auto_disabled_dispatcher.dart:477-485` supplies all 6 + `businessName` (extra) | ✓ |
| `mfa_factor_changed_notice.md` | `recipientName`, `occurredAtHumanReadable`, `changeDescription`, `accountSecurityUrl` | `mfa_factor_changed_notice_dispatcher.dart:218-226` supplies all 4 | ✓ |
| `vendor_sync_error_alert.md` | `vendorName`, `recipientName`, `firstFailureHumanReadable`, `errorSummary`, `integrationConsoleUrl`, `escalationWindowHumanReadable` | `vendor_sync_error_alert_dispatcher.dart:267-290` supplies all 6 + `businessName` (extra) + `outageWindowIdempotencyKey` (internal) | ✓ |

The renderer (`lib/services/email/email_template_renderer.dart`) throws `MissingTemplateVariableError` if a `{{var}}` is referenced but missing from `template_data`. **No dispatcher can ship a row that the renderer will reject.** ✓

### C-2-D outage observer wiring (production reachability)

This was the trickiest link. The detector + dispatcher landed in PR #631 (C-2-D); the production binding landed in PR #633 (C-2-D-binding). I confirmed the binding actually fires from the polling tier:

1. **Cloud Run boot path** — `tool/integration_sync_worker/main.dart:1431` → `runCli(args)` → `runCli(...)` constructs `WorkerRuntimeConfig.fromEnvironment(...)` → `buildWorkerRuntime(config: …, observerTelemetrySink: stderrSink)` (`:1395-1399`).
2. **`buildWorkerRuntime`** (`:1288-1320`) constructs `outageStateRepository`, `outageAdminEmailLookup`, `outageVendorIdLookup`, composes them into `VendorSyncOutageEmailBindings`, and builds the observer closure via `buildVendorSyncOutageObserver(...)`. Returns `WorkerRuntime(outageObserver: outageObserver, …)`.
3. **`runCli` daemon branch** (`:1462-1474`) constructs `IntegrationSyncWorkerLoop(…, outageObserver: outageObserver)`. The loop's `_outageObserver` field is read at `:1131` and threaded into `runSyncWorkerOnce(outageObserver: _outageObserver)`.
4. **`runSyncWorkerOnce`** (`:789-808`) constructs `_CountingCanonicalSink(canonicalSink, tally, outageObserver: outageObserver, errSink: stderrSink)`.
5. **`_CountingCanonicalSink.appendSyncLog`** (`:1000-1054`) calls `await observer(...)` AFTER delegating the sync-log write. Errors are caught and logged as `vendor_sync_outage_observer_error` so the polling tier is never poisoned.
6. **The observer closure** invokes `VendorSyncOutageDetector.observe(...)` → reads connector_sync_log + state row → decides → calls the enqueue seam (which writes to `email_outbox` + `audit_logs`).

Boot log emits `vendor_sync_outage_observer_wired: true` in production (`:1416-1419`) so a deploy review can confirm reachability. ✓

### Audit row action distinctness

| Slice | Action string | File:line |
|---|---|---|
| C-2-F | `vendor_credential_auto_disabled_email_enqueue` | `vendor_connection_auto_disabled_dispatcher.dart:199-200` |
| C-2-C | `mfa_factor_changed_email_enqueued` (not the `system.mfa_factor_changed_notice_audit` claimed in the audit doc) | `mfa_factor_changed_notice_dispatcher.dart:241` |
| C-2-D | `vendor.sync_outage.alerted` | `vendor_sync_error_alert_dispatcher.dart:227` |

All three distinct. ✓ (See F3 for the C-2-C audit-doc drift.)

### Idempotency-key shape distinctness

| Slice | Key shape | Where |
|---|---|---|
| C-2-F | `auto_disable:<operatorId>:<credentialId>:<minute-truncated ISO>` | `vendor_connection_auto_disabled_dispatcher.dart:550-551` |
| C-2-C | `notif.mfa.factor_changed:<userId>:<factorId>:<removedAtIso>` | `mfa_factor_changed_notice_dispatcher.dart:212-213` |
| C-2-D | `vendor_sync_outage:<operatorId>:<connectionId>:<outageStartedAtIso>` | `vendor_sync_error_alert_dispatcher.dart:327-329` |

**Distinct namespace prefixes** (`auto_disable:` vs `notif.mfa.factor_changed:` vs `vendor_sync_outage:`) make collision impossible even if the rest of the key shape overlapped. ✓

### Outage detector's "single observation = no email" race

The detector at `_handleFailure` (`vendor_sync_outage_detector.dart:376-496`) reads recent sync-log entries, computes the streak, then upserts `vendor_sync_outage_state`. The detector is fed from `_CountingCanonicalSink.appendSyncLog` AFTER the per-tick log row is written, so the row that just landed IS visible to the detector's `fetchRecentSyncLogEntries` lookback read. If the lookback read happens before the row commits (lookback uses the same tenant transaction in production via the bindings file), the streak might count zero — but the detector handles that case at `:404-410` (returns `noOp`; next observation picks it up). ✓

---

## Adaptive 2FA chain (C-7a → C-7)

### Verdict: APPROVED. Column type matches, label state covered, route uses replay short-circuit.

### Column type alignment

**C-7a migration** (`db/migrations/202605131800_c_7a_recovery_codes_viewed_at.sql:111-112`):

```sql
alter table public.mfa_factors
  add column if not exists recovery_codes_viewed_at timestamptz;
```

**C-7 read** (`lib/infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart:51,446`):

```dart
final DateTime? recoveryCodesViewedAt;
...
recoveryCodesViewedAt: row['recovery_codes_viewed_at'] as DateTime?,
```

**C-7 write** (`:322-328`):

```sql
update public.mfa_factors
   set recovery_codes_viewed_at = @viewed_at::timestamptz,
       updated_at = now()
 where ...
returning recovery_codes_viewed_at
```

**Type alignment perfect.** `timestamptz NULL` ↔ `DateTime?`. ✓

### Label state coverage

The `MfaCardController._stateFor` switch in `lib/operator_web/account/mfa_card_controller.dart:302-405` produces a `MfaCardState` for every value of the input triple `(MfaCardStage, factorCount, recoveryCodesViewedAt)`:

| Stage | factorCount | recoveryCodesViewedAt | Primary label |
|---|---|---|---|
| `notEnrolled` | — | — | `Enable two-factor sign-in` |
| `enrolled` | any | `null` | `View recovery codes` |
| `enrolled` | 1 | non-null | `Add another method` |
| `enrolled` | ≥2 | non-null | `Manage two-factor sign-in` |
| `removalRequested` | any | any | `Manage two-factor sign-in` |
| `removable` | any | any | (separate "Two-step verification can turn off now" copy) |

Every combination of the prompt-named triple (`session.mfaEnrolled` + `factor_count` + `recovery_codes_viewed_at`) hits a label. The `removalRequested` and `removable` stages are driven by orthogonal state (pending removal row), not by the triple. ✓

### Route idempotency

`tool/advisor_proxy/advisor_proxy.dart:11128-11176`:

- Reads `Idempotency-Key` header (400 if missing or > 200 chars)
- Calls `authIdempotencyCache.runOrReplay(route: authMfaRecoveryCodesViewedPath, key: idempotencyKey, compute: …)`
- Inside `compute`: calls `mfaOperationsGateway.markRecoveryCodesViewed(...)` which writes the audit row + updates the column

`runOrReplay` returns the cached response on retry, so a replayed call returns the original `recovery_codes_viewed_at` timestamp (not a fresh `now()`). Pinned by test `proxy_auth_operations_route_test.dart:1615` (worker disclosed). ✓

### Audit action

`lib/services/mfa/mfa_operations_gateway.dart:599-609`:

```dart
await _auditRepository.insertEvent(
  ...
  eventType: 'auth.mfa_recovery_codes_viewed',
  payload: <String, Object?>{
    'factor_id': factorId,
    'viewed_at': result.viewedAt.toUtc().toIso8601String(),
    'idempotency_key_present': true,
  },
);
```

Action matches the orchestrator's claim verbatim. ✓ Code values never serialized to audit (only the timestamp + factor_id surface). ✓

---

## Auth chain (B11.1 → B11.2 → B11.2.b → C-5)

### Verdict: APPROVED. C-5 redeems via body-only POST; B9.2 clock-skew gap genuinely closed.

### C-5 mobile handoff uses B11.1 correctly

`lib/operator_web/auth/operator_web_handoff_redeem_gateway.dart:64-88`:

```dart
final token = await _idTokenProvider();
if (token == null || token.trim().isEmpty) {
  throw const OperatorWebHandoffRedeemRejected(code: 'no_id_token', …);
}
response = await _client.postJson(
  redeemPath,                              // '/v1/auth/handoff/redeem'
  idToken: token,
  body: <String, Object?>{'code': code},   // code in JSON body, NOT URL
);
```

**CLAUDE.md addendum A1 satisfied:**

- No JWT in URL — `idToken: token` goes in Authorization header via `_client.postJson`.
- No step-up challenge ID in URL — C-5 doesn't touch step-up; the redeem is a separate primitive.
- Handoff CODE in URL `https://app.forgeflow.app/handoff?code=...&nav=...` IS by design (B11.1's purpose — the short-TTL opaque code is the bridge primitive, and the URL-form is necessary for the cross-domain handoff). Defense-in-depth: the web redeem ALSO requires a current ID token (`no_id_token` 401), so the handoff code alone is insufficient.

The pre-merge audit (`pr_512_b11_1_handoff_codes_audit.md:29`) explicitly tested that the redeem route IGNORES `code` in URL query param (only body's `code` is read by the route handler). C-5 sends `code` in body via `_client.postJson(body: {'code': code})`, matching that contract. ✓

### B11.2.b clock-skew fix (B9.2 closure)

`pr_586_b11_2_b_step_up_wiring_audit.md:93` documents the boundary tests at `web_account_gateway.dart:88` with `freshMfaClockSkewWindow = Duration(seconds: 60)`:

- +0s accept ✓
- +30s accept ✓
- +59s accept (boundary) ✓
- +60s accept (inclusive) ✓
- +61s reject ✓

RFC 7519 §4.1.4 leeway. The B9.2 P1 finding (clock-skew gap) is **genuinely closed** — the fix is bundled into B11.2.b as scope 4 (the auth-critical wave). ✓

### B11.2.b auth-posture change scope (20 routes)

The audit at `pr_586_b11_2_b_step_up_wiring_audit.md:81` independently verified 20 sensitive `StepUpRouteSpec` instances. C-5's redeem route (`/v1/auth/handoff/redeem`) is NOT in the sensitive list — B11.1's redeem requires a current ID token already, and stepping up the redeem itself would create a chicken-and-egg loop (a user redeeming from mobile-to-web likely just minted the code in a fresh session). ✓

### Mobile C-5 + step-up cross-lane finding

`pr_586` notes that mobile (C-Mobile) will surface step-up 401 challenges as generic auth failures until it wires its own `StepUpChallengeReauthHook` adapter. **Server-side enforcement is universal** — the 20 sensitive routes reject stale bearers regardless of platform. C-5's mobile handoff isn't on the sensitive list, so mobile users hitting C-5 don't see this surface; mobile users hitting any of the 20 sensitive routes (e.g. password change) get a 401 they can't recover from without a re-sign-in. Documented future work; not a regression. ✓

---

## Cross-tenant isolation invariant (HP #4)

### Verdict: APPROVED. Every new cache/lookup/read added in the wave preserves cross-tenant isolation.

| Surface | Cross-tenant defense | File:line evidence |
|---|---|---|
| `InheritanceDescendantCacheKey` includes `operator_id` | Yes — record `(operatorId, scopeOrgUnitId)` | `lib/services/hierarchy/inheritance_descendant_cache.dart:64-93`; cross-tenant test pinned in `test/services/hierarchy/inheritance_descendant_cache_test.dart` |
| `PostgresAutoDisabledRecipientResolver` uses `withSystem(reason:)` | Yes — `kLookupReason = 'oauth_refresh_worker.auto_disabled_recipient_lookup'` | `tool/oauth_refresh_worker/vendor_connection_auto_disabled_dispatcher.dart:346-352, 377-380` |
| `PostgresVendorSyncOutageAdminEmailLookup` uses `withSystem(reason:)` | Yes — `kLookupReason = 'integration_sync_worker.outage_alert_recipient_lookup'` | `tool/integration_sync_worker/vendor_sync_outage_email_bindings.dart:192-227` |
| `findUserContactSystem` (C-2-C admin-pool read) respects scope | Yes — `requireOperatorId` predicate added to WHERE | `lib/infrastructure/persistence/postgres/repositories/users_repository.dart:823-874`; caller passes `requireOperatorId: request.operatorId` at `lib/services/mfa/mfa_removal_worker.dart:214` |
| `AuditLogsReader.listByHierarchy` rides `withTenant` | Yes — `TenantContext(operatorId, locationId)` passed to `withTenant` at `:449-457`. RLS policy on `audit_logs` clamps to `app_current_operator()` | `lib/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart:435-535` |
| B6's `BenchmarkOverridesRepository` extends `OperatorScopedRepository` | Yes — every R/W path rides `withTenant` | `lib/infrastructure/persistence/postgres/repositories/benchmark_overrides_repository.dart` (per `pr_634_b6_benchmark_overrides_decompose_audit.md:24`) |
| C-2-D's outbox + audit writes ride `withTenant` | Yes — `PostgresVendorSyncErrorAlertOutboxWriter` and `PostgresVendorSyncErrorAlertAuditWriter` both `extends OperatorScopedRepository` and use `withTenant` | `tool/integration_sync_worker/vendor_sync_outage_email_bindings.dart:236-329` |
| C-2-F's outbox + audit writes ride `withTenant` | Yes — `PostgresAutoDisabledEmailEnqueueRepository extends OperatorScopedRepository`; `withTenant<String?>(ctx, …)` | `tool/oauth_refresh_worker/vendor_connection_auto_disabled_dispatcher.dart:182-330` |
| C-7 repository write rides `withTenant` | Yes — `MfaFactorsRepository.markRecoveryCodesViewed` uses `withTenant` (per `pr_636_c_7_adaptive_2fa_button_audit.md:62`) | `lib/infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart:307+` |

**HP #4 holds across the wave.** Every cross-tenant lookup uses `withSystem(reason: <stable-string>)` so log search can correlate the read with its trigger; every per-tenant write rides `withTenant` so RLS engages via `SET LOCAL app.operator_id`.

### Minor honesty note

`AuditLogsReader.listByHierarchy` (`:467-470, :512-530`) builds its SQL without an explicit `al.operator_id = @operator_id` predicate. Defense relies entirely on RLS via `SET LOCAL`. The docstring at `:386-396` claims "the parameter is supplied as defense in depth," but in practice the `operatorId` parameter is consumed only as the `TenantContext.operatorId` that drives `SET LOCAL`. There's no redundant SQL predicate — the RLS clamp is the single defense. This is **functionally correct** (RLS is enforced before any row escape) but the docstring overstates the defense-in-depth posture. Not a bug; minor doc drift. Worth surfacing for the doc-drift wave audit.

---

## Findings

### F1 — INFO: L_A1 repository methods have zero production callers

**Severity:** Informational
**File evidence:**
- `lib/infrastructure/persistence/postgres/repositories/org_units_repository.dart:890,950,1022` (definitions)
- `git grep -n "getOrgUnitTreeForOperator\|getNodeForLocation\|getDescendantLocations\b" 63b67753 -- 'lib/' 'tool/'` returns only the definitions + 1 wrap (cache) + comment-only refs

**Discussion:** B6 reimplements the in-memory tree-walk; B8 reimplements the ltree predicate inline; C-6 and B8.b build the tree client-side from `WebTeamHierarchyGateway`. L_A1's widget half (`InheritanceTree`) IS consumed by 5 production surfaces. The repository methods are foundational primitives waiting for a future slice that wants server-side tree assembly with RLS.

### F2 — INFO: L_A2 cache has zero production consumers

**Severity:** Informational
**File evidence:**
- `lib/services/hierarchy/inheritance_descendant_cache.dart` (definition)
- `tool/advisor_proxy/audit_log_hierarchy_routes.dart:181-188` (comment-only reference explaining why B8 does NOT use it)
- `git grep -l "InheritanceDescendantCache" 63b67753 -- 'lib/' 'tool/'` returns 2 files: the cache definition and one comment-only reference

**Discussion:** L_A2 shipped default-OFF and self-documented as "performance projection." The disclosed "no call-site wiring" forward-looking gap is still open at wave close. No production code calls `getDescendantLocationsCached(...)` or `invalidate(...)`. Acceptable per design; closeout should note that the perf-projection benefit is unrealized in production.

### F3 — INFO: C-2-C audit-doc drift on audit row action

**Severity:** Cosmetic (doc only)
**File evidence:**
- `docs/_audits/post_codex_wave/pr_629_c_2_c_mfa_factor_changed_wire_audit.md:34` claims action is `system.mfa_factor_changed_notice_audit`
- `lib/services/mfa/mfa_factor_changed_notice_dispatcher.dart:241` actually emits `eventType: 'mfa_factor_changed_email_enqueued'`

**Discussion:** The orchestrator prompt also references `system.mfa_factor_changed_notice_audit`. Real action is `mfa_factor_changed_email_enqueued`. Still distinct from C-2-F's `vendor_credential_auto_disabled_email_enqueue` and C-2-D's `vendor.sync_outage.alerted`. No collision risk; pure doc drift.

### F4 — INFO: `AuditLogsReader.listByHierarchy` defense-in-depth claim is slightly overstated

**Severity:** Cosmetic (doc only)
**File evidence:**
- `lib/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart:386-396` docstring claims `operator_id` parameter is "supplied as defense in depth"
- Actual SQL at `:512-530` has no explicit `al.operator_id = @operator_id` predicate; defense is entirely via RLS through `SET LOCAL`

**Discussion:** The function is still correct — the `operatorId` parameter binds the `TenantContext` which `withTenant` uses to `SET LOCAL app.operator_id`, and the RLS policy enforces the clamp before any row leaves the database. But the docstring implies a redundant SQL predicate that doesn't exist. Reword as "the parameter binds `SET LOCAL` which RLS reads" rather than "defense in depth."

### No security findings

I looked specifically for:
- Cache keys missing `operator_id` → none found
- Cross-tenant `withSystem` reads without `reason:` → none found
- ltree predicates that could match across tenants → none found (RLS on `org_units` clamps the subquery)
- Idempotency-key shapes that could collide across dispatchers → none found (distinct namespace prefixes)
- Race windows between row writes and observer reads → none found (`appendSyncLog` writes then triggers; outage detector handles "row not yet visible" branch as `noOp`)
- C-5 `code` in URL where a JWT would be — by design (B11.1 primitive; defense-in-depth via mandatory ID token on redeem)
- B11.2.b 20 sensitive routes excluding any that should be on the list — handoff redeem correctly excluded (ID token already required)

No security gap surfaced.

---

## Aggregate observations

1. **The wave's cross-slice contract discipline is unusually high.** Three multi-slice chains (hierarchy, email pipeline, auth) all compose at their seams without surprises. Every "this should match that" check (predicate shape, column type, audit action, idempotency-key namespace, transaction boundary) passes. This is the dividend of the per-slice Pattern B audit discipline — each slice's audit doc spelled out the contract it inherited from upstream, so downstream slices could verify against a stable target.

2. **L_A1 + L_A2 over-deliver on primitives.** Both slices shipped widget + repository + cache primitives that are not yet consumed by their downstream slices. The widget half of L_A1 IS consumed (5 surfaces); the repository half + the cache half are reachable through tests only. This is documented as deliberate (L_A2's "no call-site wiring" disclosure) — V1 ships the seam, future slices opt in. Acceptable; future closeout sweeps should track whether the primitives are getting used.

3. **C-2-D's "single email per outage" semantics rely on a load-bearing flag in a state table.** `vendor_sync_outage_state.notified_at IS NOT NULL` is the idempotency guard; if a row is deleted (on `poll_success`) and then a new streak starts, a fresh email fires. The state row + email enqueue + audit write all commit in one tenant transaction so a crash rolls them all back. **This is the right shape for V1.** The only risk surface is if a future slice modifies the state table directly without going through the detector — but the detector is the only writer (mod tests), and the state table has no admin UI.

4. **The email_outbox shape is now finalized for V1.** Three dispatchers writing concurrently with three distinct (action, idempotency-key-namespace, user_id-presence) shapes prove the table can carry the system-notice + user-targeted-notice diversity without requiring a new column or table. If a future dispatcher needs to ship, the playbook is set.

5. **Auth-critical work is the most disciplined in the wave.** B11.1 → B11.2 → B11.2.b → C-5 + C-7a + C-7 all shipped explicit Pattern-B audits with addendum A1 verification, dedicated security tests (e.g. B11.2.b's URL-param prohibition test at `b11_2_b_step_up_wiring_test.dart:343`), and operator-approval gates. The clock-skew gap (B9.2 P1 finding) was closed in scope-4 of B11.2.b with five boundary tests.

6. **The C-2-D production binding (PR #633) is the highest-risk single integration in the wave** — it threads an out-of-band observer through a polling-tier worker, with the email-enqueue + audit-row + state-row writes all riding the polling tick's tenant transaction. I traced the call graph manually (six hops from `runCli` → observer → detector → dispatcher → outbox writer + audit writer) and every hop preserves the per-tenant transaction discipline. The boot log `vendor_sync_outage_observer_wired: true` is a nice operator-facing tell for deploy review.

---

## Recommendations

1. **Track F1 + F2 in the wave closeout.** Both findings are honest disclosures, not bugs. The closeout doc should note that L_A1's three repository methods + L_A2's cache are unrealized primitives at V1 launch. A line in `docs/POST_HARDENING_FOLLOWUPS.md` or a row in the closeout checklist would prevent the primitives from being forgotten.

2. **Fix F3 + F4 doc drift in the doc-drift wave audit (#3).** Both are one-line edits:
   - `pr_629_c_2_c_mfa_factor_changed_wire_audit.md:34` change `system.mfa_factor_changed_notice_audit` → `mfa_factor_changed_email_enqueued`
   - `audit_logs_repository.dart:386-396` reword the "defense in depth" claim

3. **If a future slice wants to use the L_A2 cache:** the wiring point is `tool/advisor_proxy/audit_log_hierarchy_routes.dart` (B8) or `lib/services/baseline/benchmark_override_resolver.dart` (B6). The cache's `getDescendantLocationsCached` API is a drop-in for `OrgUnitsRepository.getDescendantLocations`. The slice MUST also wire `invalidate()` from the org_units mutation paths in `hierarchy_screen.dart` + `roles_hierarchy_sessions_admin_screen.dart`, otherwise multi-pod deployments will serve stale reads for up to the 60s TTL window.

4. **Monitor `vendor_sync_outage_observer_wired: false` in production logs.** It should always be `true` on the daemon-mode path; `false` would indicate a deploy with overrides that bypassed `buildWorkerRuntime`. Cloud Run boot logs are queryable via the existing telemetry.

5. **No action needed on the email pipeline:** the C-1a / C-1 dedupe predicate match is byte-for-byte; the three dispatchers don't collide; the C-2-D observer is reachable in production. The chain is launch-ready.

6. **No action needed on the auth chain:** B11.1 → B11.2 → B11.2.b → C-5 compose correctly; B9.2 clock-skew is closed; the 20 sensitive routes carry the step-up gate; mobile C-5 redemption uses body-only POST.

---

## Authority anchors

- `CLAUDE.md` "Authority Order" + "Hard Promises #4" (per-operator isolation non-negotiable)
- `docs/contracts/core_app_architecture.md` (Tier-2 canonical Phase 7.55 architecture)
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` (RLS-ready schema + `OperatorScopedRepository` + `withTenant` / `withSystem` discipline)
- `docs/contracts/phase_7_55_time_boundary_contract.md` (TIMESTAMPTZ on operator-scoped tables)
- Per-slice PR audits at `docs/_audits/post_codex_wave/`:
  - `pr_608_l_a1_inheritance_tree_primitive_audit.md` — L_A1
  - `pr_616_l_a2_inheritance_descendant_cache_audit.md` — L_A2
  - `pr_624_b8_audit_log_hierarchy_filter_audit.md` — B8 admin
  - `pr_622_c_6_inheritance_tree_consumers_audit.md` — C-6
  - `pr_634_b6_benchmark_overrides_decompose_audit.md` — B6 (supersedes #630)
  - `pr_599_c_1a_email_event_provider_id_audit.md` — C-1a
  - `pr_611_c_1_sendgrid_events_webhook_audit.md` — C-1
  - `pr_617_c_2_wire_or_delete_decision_matrix_audit.md` — C-2 decision matrix
  - `pr_627_c_2_del_template_deletes_audit.md` — C-2-Del
  - `pr_628_c_2_f_vendor_connection_auto_disabled_wire_audit.md` — C-2-F
  - `pr_629_c_2_c_mfa_factor_changed_wire_audit.md` — C-2-C
  - `pr_631_c_2_d_vendor_sync_outage_detector_wire_audit.md` — C-2-D
  - `pr_633_c_2_d_production_binding_audit.md` — C-2-D-binding
  - `pr_626_c_7a_recovery_codes_viewed_at_prep_audit.md` — C-7a
  - `pr_636_c_7_adaptive_2fa_button_audit.md` — C-7
  - `pr_512_b11_1_handoff_codes_audit.md` — B11.1
  - `pr_550_b11_2_step_up_challenge_audit.md` — B11.2 scaffold
  - `pr_586_b11_2_b_step_up_wiring_audit.md` — B11.2.b
  - `pr_600_c_5_mobile_handoff_deeplink_audit.md` — C-5
- Source files traced at master tip `63b67753`:
  - `lib/widgets/inheritance_tree.dart`
  - `lib/domain/models/inheritance_tree_node.dart`
  - `lib/infrastructure/persistence/postgres/repositories/org_units_repository.dart`
  - `lib/services/hierarchy/inheritance_descendant_cache.dart`
  - `lib/services/baseline/benchmark_override_resolver.dart`
  - `lib/operator_web/screens/benchmarks_screen.dart`
  - `lib/operator_web/screens/hierarchy_screen.dart`
  - `lib/operator_web/screens/audit_log_hierarchy_filter_pane.dart`
  - `lib/admin/screens/audit_log_admin_screen.dart`
  - `lib/admin/screens/roles_hierarchy_sessions_admin_screen.dart`
  - `lib/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart`
  - `lib/infrastructure/persistence/postgres/repositories/email_event_repository.dart`
  - `lib/infrastructure/persistence/postgres/repositories/mfa_factors_repository.dart`
  - `lib/infrastructure/persistence/postgres/repositories/users_repository.dart`
  - `lib/services/email/vendor_sync_error_alert_dispatcher.dart`
  - `lib/services/vendor_sync/vendor_sync_outage_detector.dart`
  - `lib/services/mfa/mfa_factor_changed_notice_dispatcher.dart`
  - `lib/services/mfa/mfa_removal_worker.dart`
  - `lib/services/mfa/mfa_operations_gateway.dart`
  - `lib/operator_web/account/mfa_card_controller.dart`
  - `lib/operator_web/auth/operator_web_handoff_redeem_gateway.dart`
  - `tool/advisor_proxy/audit_log_hierarchy_routes.dart`
  - `tool/advisor_proxy/operator_web_audit_log_hierarchy_routes.dart`
  - `tool/advisor_proxy/email_templates/vendor_connection_auto_disabled.md`
  - `tool/advisor_proxy/email_templates/mfa_factor_changed_notice.md`
  - `tool/advisor_proxy/email_templates/vendor_sync_error_alert.md`
  - `tool/advisor_proxy/sendgrid_events_webhook.dart`
  - `tool/advisor_proxy/advisor_proxy.dart` (lines 7264-7268 + 11096-11176)
  - `tool/oauth_refresh_worker/vendor_connection_auto_disabled_dispatcher.dart`
  - `tool/integration_sync_worker/main.dart`
  - `tool/integration_sync_worker/vendor_sync_outage_email_bindings.dart`
  - `db/migrations/202605131700_c_1a_email_event_provider_id.sql`
  - `db/migrations/202605131800_c_7a_recovery_codes_viewed_at.sql`
  - `db/migrations/202605131900_c_2_d_vendor_sync_outage_state.sql`
