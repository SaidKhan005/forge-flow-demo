# Worker Projection Binding Plan

## What We Found

- Webhook imports now project canonical facts after they commit.
- The recurring sync worker and first-connect backfill worker still build adapter taps without projector wiring.
- That means poll/backfill writes can save raw canonical facts, then skip the post-commit projection step.
- The fix must reuse the same projector wiring as the webhook binder so the three ingestion paths stay aligned.
- Mobile Covers Setup still guessed source-detail text when server provenance metadata was absent.

## Fix Plan

- Move the shared production projector wiring into a small helper the proxy and workers can all use.
- Keep the proxy binder behavior unchanged.
- Pass the shared projector triple into both worker factory builders.
- Add tests that prove both worker boot paths create real projection taps.
- Hide mobile Covers source detail text unless real server source metadata exists.
- Run focused analyzer, focused tests, hygiene checks, pre-merge gate, then merge and verify landed.

## Guardrails

- Work only in `codex/worker-projection-binding`; keep the shared checkout on `master`.
- Do not change adapter business logic or projection formulas.
- Do not add migrations.
- Keep the change scoped to wiring plus tests.
