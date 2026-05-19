# Post-Codex Wave — Live Audit Index

> Wave closed 2026-05-13. The per-PR audit docs (77 files) and per-bundle
> investigation reports retired to
> [`docs/archive/_audits/post_codex_wave_2026-05-13/`](../../archive/_audits/post_codex_wave_2026-05-13/)
> on 2026-05-13. The 12 files below remain live because they're
> institutional knowledge for the upcoming refactor phase (R-1 + R-2)
> and the Production1 apply queue.
>
> Wave ledger: [`docs/_indices/WAVE_EXECUTION_LEDGER.md`](../../_indices/WAVE_EXECUTION_LEDGER.md).
> Next-wave plan: [`docs/_indices/NEXT_WAVE_PLAN.md`](../../_indices/NEXT_WAVE_PLAN.md).

## Canonical closeout

| File | Scope |
|---|---|
| [`c_12_lane_c_closeout_audit.md`](c_12_lane_c_closeout_audit.md) | Master closeout for the wave: 9 dimensional audits synthesized, real-bug follow-ups named (B-1, B-2, W-1, W-2), operator action items enumerated, E2E summary, doc-drift fixes captured. The authoritative wave summary. |

## Dimensional wave audits (9)

Cross-cutting audits dispatched 2026-05-13 in parallel by the orchestrator
to catch gaps the per-PR audits missed.

| Dimension | File |
|---|---|
| Auth + RLS + permissions | [`wave_audit_auth_rls_permissions.md`](wave_audit_auth_rls_permissions.md) |
| Cross-slice integration | [`wave_audit_cross_slice_integration.md`](wave_audit_cross_slice_integration.md) |
| Demo mode + flavor parity | [`wave_audit_demo_mode_flavor.md`](wave_audit_demo_mode_flavor.md) |
| Doc drift | [`wave_audit_doc_drift.md`](wave_audit_doc_drift.md) |
| Honest disclosures | [`wave_audit_honest_disclosures.md`](wave_audit_honest_disclosures.md) |
| Migrations + schema | [`wave_audit_migrations_schema.md`](wave_audit_migrations_schema.md) |
| Operator-web + admin UX | [`wave_audit_operator_web_admin_ux.md`](wave_audit_operator_web_admin_ux.md) |
| Proxy + bleed-stop discipline | [`wave_audit_proxy_bleed_stop.md`](wave_audit_proxy_bleed_stop.md) |
| Test coverage | [`wave_audit_test_coverage.md`](wave_audit_test_coverage.md) |

## Wave completion deep audit

| File | Scope |
|---|---|
| [`wave_completion_deep_audit_2026_05_13.md`](wave_completion_deep_audit_2026_05_13.md) | Background deep audit covering 21 merged slices; 5 P1 + 4 P2 + 2 P3 findings. Still referenced by `docs/POST_HARDENING_FOLLOWUPS.md` (sections #4 and #129). |

## What's in the archive

84 files retired to `docs/archive/_audits/post_codex_wave_2026-05-13/`
on 2026-05-13 — see the archive's own README for the full index. Includes:

- 77 per-PR audit docs (`pr_NNN_<topic>_audit.md`)
- 1 smoke-run evidence text (`pr_476_smoke_run_evidence.txt`)
- 1 misc rollup audit (`pr_b_pr_a_rollup_audit.md`)
- 5 investigation / housekeeping artifacts
  (`c_1_ecdsa_pubkey_gap_investigation.md`,
   `final_housekeeping_sweep_2026_05_13.md`,
   `followups_doc_drift_cleanup_2026_05_13.md`,
   `orchestrator_bundle_33_b10_1_fallout.md`,
   `test_proxy_5_failures_investigation.md`)
- 1 draft closeout checklist (`wave_closeout_checklist_DRAFT.md`)
