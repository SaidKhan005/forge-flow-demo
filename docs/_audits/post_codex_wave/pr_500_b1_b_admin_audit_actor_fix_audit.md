# PR #500 Audit — B1.b Admin Audit Actor Fix

**Slice:** B1.b (Lane B — features)
**Owner:** Claude lane executor
**Branch:** `claude/b1b-admin-audit-actor-fix`
**Base:** `master` (no drift)
**Gate:** `operator` (proxy-touching + audit-attribution)
**Size:** 78 additions / 2 deletions / 2 files (`tool/advisor_proxy/proxy_bootstrap.dart` + `test/advisor_proxy_bootstrap_test.dart`)
**Chunking:** light variant (single-literal flip)

## Pattern B compliance

Both audit tables present in PR body ✓.

## Verdict

**approve-for-merge subject to operator approval** — proxy-touching + audit-attribution change requires explicit operator green-light per CLAUDE.md.

## Executor spot-checks

| Check | Outcome |
|---|---|
| Single literal flip at `proxy_bootstrap.dart:3650` (`'user'` → `'forge_admin'`) | ✓ — confirmed in diff |
| Migration validates `forge_admin` in both check constraints | ✓ — `db/migrations/202605131000_admin_audit_log_actor_reason_contract.sql:18-21,40-46,73-77` (per worker citation; not re-read but worker citation matched contract intent) |
| `admin_reason` mandatory enforced upstream | ✓ — route guard at `advisor_proxy.dart:14111-14119` |
| Fan-out path is INSERT-only (no UPDATE on `audit_logs`) | ✓ — `insertSystemEvent` → INSERT INTO `auth_events_audit`; `_fanOutToAuditLogs` → `writeRow` (append-only) |
| Regression tests pin `actor_kind == 'forge_admin'` for `patchOperator` + `addLocation` | ✓ — `test/advisor_proxy_bootstrap_test.dart:360-421` |
| Cross-lane note re: peer bug at `proxy_bootstrap.dart:4015` | ✓ **CONFIRMED REAL** — read `:4013-4022`, pricing-tier admin gateway has identical `actorKind: 'user'` literal. Same bug pattern. Worker correctly deferred per "no drive-by fixes". |
| Frozen-surface (`lib/auth/**`) untouched | ✓ |
| Demo carve-out untouched | ✓ |

## Authority anchors verified

- CLAUDE.md "Proxy & API Conventions" actor taxonomy (`audit_logs.actor_kind` never NULL; `forge_admin` valid for F&F support / cross-operator).
- CLAUDE.md "Agent-Led Slices" — auth-critical, RLS-touching, schema-touching, **and proxy-touching** slices require explicit operator approval before merge.
- `docs/_audits/code_health/a1_proxy_bug_root_cause.md` — not directly cited but the slice is a forward-only attribution fix, not a re-implementation; acceptable.

## Findings

**Findings to operator** (not blocking this PR; informational):

1. **Peer bug `B1.c` candidate**: `tool/advisor_proxy/proxy_bootstrap.dart:4015` (pricing-tier admin gateway) carries the same `actorKind: 'user'` literal on what is also a super_admin-gated admin path. Recommend either:
   - (a) widen B1.b scope post-merge to include the fix in a follow-up PR, OR
   - (b) open a `B1.c` peer-fix slice in the wave ledger.

## Next action

Escalate to operator with merge recommendation. Operator approves → orchestrator merges + updates ledger. Operator declines or asks for changes → send back via orchestrator-fix doctrine.
