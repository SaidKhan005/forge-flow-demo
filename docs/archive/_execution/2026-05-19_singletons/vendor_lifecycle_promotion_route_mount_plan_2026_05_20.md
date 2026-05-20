# Vendor Lifecycle Promotion Route Mount Plan - 2026-05-20

## Plain English Summary

- Operators can already ask to be notified when a vendor becomes ready.
- The server already has the route that sends those notifications.
- The gap: the live server was not actually mounting that route.
- The second gap: the route's email dispatcher only had test fakes, not production database bindings.
- This fix keeps the route server-only. It does not add a new Admin UI button.

## Scope

- Mount `POST /v1/admin/vendors/:vendor_id/lifecycle-promotion-notification` in `tool/advisor_proxy/main.dart`.
- Wire the dispatcher to Postgres reads from `vendor_lifecycle_notification`.
- Wire email enqueue into `email_outbox` with retry-safe dedupe.
- Claim each pending notification row and enqueue its email in one database transaction, so two admin calls with different retry keys cannot send the same notification twice.
- Reuse the existing admin idempotency table through a route-specific adapter.
- Add focused tests proving main.dart mounts the route and bootstrap exposes the production bindings.

## Non-Goals

- No new visible Admin console control.
- No vendor lifecycle state mutation here. The live-rollout adapter remains responsible for changing lifecycle state.
- No schema change.
- No graph refresh.

## Safety Checks

- Keep the main checkout on `master`.
- Work only inside `.codex_worktrees/vendor-lifecycle-route-mount`.
- Preserve role gating: only `super_admin` can trigger the promotion notification route.
- Preserve idempotency: same key and same body replays; same key with a different body fails closed.
- Preserve duplicate-send safety: a pending row must be marked claimed before the email insert commits, and the mark plus insert must roll back together on failure.
- Run focused route/bootstrap tests, analyzer, UX copy lint, postgres import lint, diff check, pre-merge gate, and landed verification.

## Audit Notes Found During Execution

- Fixed: concurrent promotion calls could previously double-insert the same email if they used different `Idempotency-Key` values.
- Watch item: the initial "which operators have pending rows for this vendor" query is vendor-filtered, while the table's required index leads with `operator_id`. A vendor-leading index was not added because the repo's RLS-ready index rule requires operator-leading indexes for operator-scoped tables. This route is rare and server-admin-triggered, so the current shape is acceptable unless live volume proves otherwise.
- Watch item: the main route mount test follows the repo's existing source-wiring test pattern. A full live request through `main.dart` would need production bootstrap env and database pools, so the runtime HTTP proof stays at the router level.
