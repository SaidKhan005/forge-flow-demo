# PR #502 Audit — B3 Role-Key Hybrid Identifier Sweep

**Slice:** B3 (Lane B — features)
**Owner:** Codex executor
**Branch:** `codex/b3-role-key-hybrid`
**Base:** `master` (no drift)
**Gate:** `operator` (auth-critical role identifier semantics)
**Size:** 880 additions / 428 deletions / 14 files / 1679 diff lines
**Chunking:** light variant (<20 files, <5K LoC; nonetheless deep spot-checks given auth-critical scope)

## Pattern B compliance

Both audit tables present in PR body ✓.

## Verdict

**approve-for-merge subject to operator approval** — Gate=operator per ledger; role-identifier contract changes require explicit operator green-light.

## Executor spot-checks

| Check | Outcome |
|---|---|
| Proxy `/v1/admin/auth/role-grants` POST requires `role_id` (slug-blocked) | ✓ — `advisor_proxy.dart:11625-11637` reads `body['role_id']`, returns 400 `missing_role_grant_fields` if absent; `role_key` is unread → effectively rejected for custom roles when no `role_id` is paired. (Note: audit-table language "rejects role_key" is loose — actual mechanism is "requires role_id, ignores role_key" — security property is equivalent for new clients.) |
| `RoleGrantCreateCommand` carries `roleId` not `roleKey` to repository | ✓ — `advisor_proxy.dart:11644-11651` |
| Repository `roleIdForVisibleKey` SQL path still operator-scoped-first then global seeded | ✓ — `roles_repository.dart:128-141` (compatibility path; comment at :252 documents that custom-role mutation callers now pass `role_id` directly so the operator-scoped branch is effectively dead for new mutations) |
| Admin members override dialog carries `roleId` separately from `roleKey` | ✓ — diff shows `members_admin_screen.dart` adding `roleId` field on choice records, screen calls `roleId: role.roleId, roleKey: role.roleKey` |
| Seeded-role compat preserved for global keys | ✓ — `_firstStringField(json, const <String>['role_id', 'id'])` + `kSeededRoleKeysForAdmin` fallback in screen |
| 173 targeted tests pass per worker output | ✓ — `flutter test [7 test files]` → `00:07 +173: All tests passed!` |
| Frozen-surface `lib/auth/permission_keys.dart` untouched | ✓ — not in diff |
| Demo carve-out untouched | ✓ — no `kDemoMode` edits |
| Schema/migration untouched | ✓ — no `db/migrations` files in diff |
| No `audit_logs` UPDATE | ✓ — only INSERT-side audit payload changes (`role_id` added alongside `role_key`) |

## Authority anchors verified

- `docs/_indices/WAVE_EXECUTION_LEDGER.md:54` — Gate=operator confirmed; B3 row.
- `docs/_execution/lane_b_features/03_execution_slices.md:78-86` — slice scope matches diff.
- CLAUDE.md "Agent-Led Slices" — auth-critical changes require explicit operator approval before merge.
- `docs/contracts/auth_permission_key_catalog.md:330` — frozen catalog unchanged (verified via worker citation; key catalog is intentionally untouched).

## Findings

**Minor observation (not blocking, not a finding requiring action):**

Worker self-audit and executor-audit tables both describe the proxy contract as "rejects `role_key`". The actual mechanism is "requires `role_id`; ignores `role_key`". Security property is equivalent for the threat model in scope (slug-based custom-role reassignment cannot land because new mutations require the UUID), but the language slightly overstates active rejection vs. passive disuse. Mention this so the operator knows the wording in the worker audit is loose, not the implementation.

**Batch isolation note from Codex** (preserved here for ledger context): "B3-F1 revealed a hidden role-grant overlap with B7.a's admin members tests/gateway surface. I am holding the clean B7.a branch until this PR merges or is closed so the session does not open overlapping PRs from the same batch." This is correct file-isolation discipline per Pattern B.

## Next action

Escalate to operator with merge recommendation. Once approved → orchestrator merges B3 + updates ledger + unblocks Codex's held B7.a branch.
