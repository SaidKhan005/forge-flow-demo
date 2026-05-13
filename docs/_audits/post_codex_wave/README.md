# Post-Codex Wave — Audit Doc Index

Table of contents for all per-PR audit docs + cross-cutting audits produced during the post-Codex wave.

Wave ledger: `docs/_indices/WAVE_EXECUTION_LEDGER.md` (canonical for slice state). This file is a navigation aid; refresh on each housekeeping pass.

Last refreshed: 2026-05-13 (bundle 30).

## Cross-cutting audits

| Date | Audit | Scope |
|---|---|---|
| 2026-05-13 | [`wave_completion_deep_audit_2026_05_13.md`](wave_completion_deep_audit_2026_05_13.md) | Background deep audit covering 21 merged slices; 5 P1 + 4 P2 + 2 P3 findings deposited per the ledger-first hygiene rule |
| 2026-05-13 | [`followups_doc_drift_cleanup_2026_05_13.md`](followups_doc_drift_cleanup_2026_05_13.md) | 3 mechanical fixes to `docs/POST_HARDENING_FOLLOWUPS.md` via PR #558 |
| 2026-05-13 | [`final_housekeeping_sweep_2026_05_13.md`](final_housekeeping_sweep_2026_05_13.md) | Bundle 26 staging sweep — `docs/_indices/` doc trim + `CLAUDE_HANDOFF_PROMPT.md` + `CODEX_HANDOFF_PROMPT.md` refinements + this README index created |

## Per-PR audits — chronological

Verdict legend: ✅ approve-for-merge · 🔐 approve-pending-operator · 🚧 send-back · 🔍 verdict-in-doc

### Pre-wave (retroactive + setup, PRs #473-495)

| PR | Slice | Verdict | Topic | Audit doc |
|---|---|---|---|---|
| #473 | B3 retroactive | 🔍 | Role-key hybrid identifier retroactive audit | [`pr_473_b3_retroactive_audit.md`](pr_473_b3_retroactive_audit.md) |
| #476 | B1+B2 | 🔍 | Proxy bug root-cause shipped (A1 precursor) | [`pr_476_b1_b2_audit.md`](pr_476_b1_b2_audit.md) |
| #481 | retroactive | 🔍 | Pre-wave retroactive audit | [`pr_481_retroactive_audit.md`](pr_481_retroactive_audit.md) |
| #482 | — | 🔍 | Pre-wave audit | [`pr_482_audit.md`](pr_482_audit.md) |
| #484 | — | 🔍 | Pre-wave audit | [`pr_484_audit.md`](pr_484_audit.md) |
| #488 | — | 🔍 | Pre-wave audit | [`pr_488_audit.md`](pr_488_audit.md) |
| #490 | — | 🔍 | Pre-wave audit | [`pr_490_audit.md`](pr_490_audit.md) |
| #495 | — | 🔍 | Pre-wave audit | [`pr_495_audit.md`](pr_495_audit.md) |
| — | rollup | 🔍 | PR A + PR B rollup audit | [`pr_b_pr_a_rollup_audit.md`](pr_b_pr_a_rollup_audit.md) |

### Lane A — Code Health (PRs #498-563)

| PR | Slice | Verdict | Topic | Audit doc |
|---|---|---|---|---|
| #498 | A6.1 | ✅ | Proxy health UI honesty pass (Codex) | [`pr_498_a6_1_proxy_health_ui_audit.md`](pr_498_a6_1_proxy_health_ui_audit.md) |
| #517 | A4.1 | ✅ | Performance audit pass (Claude) | [`pr_517_a4_1_performance_audit_pass_audit.md`](pr_517_a4_1_performance_audit_pass_audit.md) |
| #519 | A2.1 | ✅ | Dead-code sweep / placeholder widgets (Codex) | [`pr_519_a2_1_dead_placeholder_sweep_audit.md`](pr_519_a2_1_dead_placeholder_sweep_audit.md) |
| #522 | A11.1 | 🔐 | Session-record incomplete gauge (Claude) | [`pr_522_a11_1_session_record_gauge_audit.md`](pr_522_a11_1_session_record_gauge_audit.md) |
| #523 | A10.1 | ✅ | Test consolidation (`test/pressure/` rehome) (Claude) | [`pr_523_a10_1_test_consolidation_audit.md`](pr_523_a10_1_test_consolidation_audit.md) |
| #526 | A7.1 | ✅ | Frameworks cross-reference sweep (Claude) | [`pr_526_a7_1_frameworks_xref_sweep_audit.md`](pr_526_a7_1_frameworks_xref_sweep_audit.md) |
| #527 | A5+A8 | 🔐 | Schema versioning + audit_logs UPDATE lint (Codex) | [`pr_527_a5_a8_audit_log_guardrails_audit.md`](pr_527_a5_a8_audit_log_guardrails_audit.md) |
| #530 | A9.1 | 🔐 | `lib/data/` rehome (Codex) | [`pr_530_a9_1_lib_data_rehome_audit.md`](pr_530_a9_1_lib_data_rehome_audit.md) |
| #533 | A3.1 | 🔐 | Monolith seam map + bleed-stop lint (Claude) | [`pr_533_a3_1_monolith_seam_map_audit.md`](pr_533_a3_1_monolith_seam_map_audit.md) |
| #537 | A11.2 | 🔐 | Soak harness durable extensions (Claude) | [`pr_537_a11_2_soak_harness_extensions_audit.md`](pr_537_a11_2_soak_harness_extensions_audit.md) |
| #539 | doc hygiene | ✅ | 41-file archive sweep (orchestrator-spawned) | [`pr_539_doc_hygiene_trim_audit.md`](pr_539_doc_hygiene_trim_audit.md) |
| #540 | A2.2 | 🔐 | Email pipeline wire-or-delete (Codex) | [`pr_540_a2_2_email_wire_or_delete_audit.md`](pr_540_a2_2_email_wire_or_delete_audit.md) |
| #542 | Apple CI | 🔐 | Apple Platform Verification workflow gate | [`pr_542_apple_ci_gate_audit.md`](pr_542_apple_ci_gate_audit.md) |
| #552 | A4.2 | 🔐 | Performance fixes (R1/R2/R3) (Claude) | [`pr_552_a4_2_performance_fixes_audit.md`](pr_552_a4_2_performance_fixes_audit.md) |
| #563 | A3.2 | 🔐 | Bare-catch typing chunk 1 of 3 (Claude, salvaged) | [`pr_563_a3_2_bare_catch_typing_chunk_1_audit.md`](pr_563_a3_2_bare_catch_typing_chunk_1_audit.md) |
| #571 | A11.1.b | 🔐 | Session-record gauge consumer wiring (Claude, first post-loop-mode-restart) | [`pr_571_a11_1_b_session_record_gauge_consumer_audit.md`](pr_571_a11_1_b_session_record_gauge_consumer_audit.md) |
| #572 | A3.3 | 🔐 | Bare-catch typing chunk 2 of 3 (Claude, Option A continuation) | [`pr_572_a3_3_bare_catch_typing_chunk_2_audit.md`](pr_572_a3_3_bare_catch_typing_chunk_2_audit.md) |

### Lane B — Features (PRs #499-561)

| PR | Slice | Verdict | Topic | Audit doc |
|---|---|---|---|---|
| #500 | B1.b | 🔐 | Admin audit actor fix — `forge_admin` label (Claude) | [`pr_500_b1_b_admin_audit_actor_fix_audit.md`](pr_500_b1_b_admin_audit_actor_fix_audit.md) |
| #501 | B1.a | 🔐 | Inheritance notice propagation (Claude) | [`pr_501_b1_a_inheritance_notice_propagation_audit.md`](pr_501_b1_a_inheritance_notice_propagation_audit.md) |
| #501 follow-up | B1.a copy fix | ✅ | Option 1 copy follow-up by orchestrator | [`pr_501_b1_a_copy_fix_followup.md`](pr_501_b1_a_copy_fix_followup.md) |
| #502 | B3 | 🔐 | Role-key hybrid identifier (Codex) | [`pr_502_b3_role_key_hybrid_audit.md`](pr_502_b3_role_key_hybrid_audit.md) |
| #507 | B7.a | 🔐 | Invite hierarchy-scope fix (Codex) | [`pr_507_b7_a_invite_scope_fix_audit.md`](pr_507_b7_a_invite_scope_fix_audit.md) |
| #507 follow-up | B7.a consumer label | ✅ | Option A consumer-label follow-up by orchestrator | [`pr_507_b7_a_consumer_label_followup.md`](pr_507_b7_a_consumer_label_followup.md) |
| #510 | B9.1 | ✅ | `/sign-in-security` 301 redirect (Codex) | [`pr_510_b9_1_sign_in_security_redirect_audit.md`](pr_510_b9_1_sign_in_security_redirect_audit.md) |
| #512 | B11.1 | 🔐 | `handoff_codes` table + endpoints (Claude) | [`pr_512_b11_1_handoff_codes_audit.md`](pr_512_b11_1_handoff_codes_audit.md) |
| #513 | B4 | ✅ | Two-product role editor (Codex) | [`pr_513_b4_two_product_role_editor_audit.md`](pr_513_b4_two_product_role_editor_audit.md) |
| #547 | B9.2 | 🔐 | My Account 4-card IA + active sessions (Codex) | [`pr_547_b9_2_my_account_active_sessions_audit.md`](pr_547_b9_2_my_account_active_sessions_audit.md) |
| #550 | B11.2 | 🔐 | RFC 9470 step-up scaffold (Claude) | [`pr_550_b11_2_step_up_challenge_audit.md`](pr_550_b11_2_step_up_challenge_audit.md) |
| #557 | B5 | 🔐 | Admin access-control sweep (Codex) | [`pr_557_b5_admin_access_control_audit.md`](pr_557_b5_admin_access_control_audit.md) |
| #561 | B1.c | 🔐 | Admin gateway actorKind peer-bug sweep (Claude, salvaged) | [`pr_561_b1_c_actorkind_peer_bug_sweep_audit.md`](pr_561_b1_c_actorkind_peer_bug_sweep_audit.md) |
| #568 | B9.3 | ✅ | Adaptive 2FA card 4-state machine + clock-skew (Codex) | [`pr_568_b9_3_adaptive_2fa_card_audit.md`](pr_568_b9_3_adaptive_2fa_card_audit.md) |
| #573 | B5.b | 🔐 | Catalog tri-mirror amendment (Codex, B5 Option A deferred half) | [`pr_573_b5_b_catalog_tri_mirror_audit.md`](pr_573_b5_b_catalog_tri_mirror_audit.md) |
| #576 | B10.1 | 🔐 | Vendor applicability plumbing (Codex, schema + RLS + admin/operator routes) | [`pr_576_b10_1_vendor_applicability_audit.md`](pr_576_b10_1_vendor_applicability_audit.md) |

### Lane C — Cross-Surface Parity

| PR | Slice | Verdict | Topic | Audit doc |
|---|---|---|---|---|
| #499 | C-8 | 🔐 | Notification preferences catalog completeness (Claude) | [`pr_499_c_8_notification_catalog_completeness_audit.md`](pr_499_c_8_notification_catalog_completeness_audit.md) |
| #556 | C-10 | ✅ | Admin parity copy (Codex) | [`pr_556_c10_admin_parity_copy_audit.md`](pr_556_c10_admin_parity_copy_audit.md) |

## Conventions

- File naming: `pr_<n>_<slug>_audit.md` (per-PR audits) · `pr_<n>_<slug>_followup.md` (orchestrator follow-up commits) · `<topic>_<date>.md` (cross-cutting audits not bound to a single PR).
- Verdict legend in this README is a shorthand. The audit doc itself carries the full verdict + spot-checks + findings.
- New audit doc → add a row here on the next housekeeping pass.
- Pre-wave entries are kept for historical traceability; consult the wave ledger change-log for the active picture.
