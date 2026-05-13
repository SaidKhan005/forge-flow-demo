# Post-Codex Wave — Audit Doc Index

Table of contents for all per-PR audit docs + cross-cutting audits produced during the post-Codex wave.

Wave ledger: `docs/_indices/WAVE_EXECUTION_LEDGER.md` (canonical for slice state). This file is a navigation aid; refresh on each housekeeping pass.

Last refreshed: 2026-05-13 (bundle 45 + closeout-checklist-lean; master tip `76648daf`).

## Cross-cutting audits

| Date | Audit | Scope |
|---|---|---|
| 2026-05-13 | [`wave_completion_deep_audit_2026_05_13.md`](wave_completion_deep_audit_2026_05_13.md) | Background deep audit covering 21 merged slices; 5 P1 + 4 P2 + 2 P3 findings deposited per the ledger-first hygiene rule |
| 2026-05-13 | [`followups_doc_drift_cleanup_2026_05_13.md`](followups_doc_drift_cleanup_2026_05_13.md) | 3 mechanical fixes to `docs/POST_HARDENING_FOLLOWUPS.md` via PR #558 |
| 2026-05-13 | [`final_housekeeping_sweep_2026_05_13.md`](final_housekeeping_sweep_2026_05_13.md) | Bundle 26 staging sweep — `docs/_indices/` doc trim + `CLAUDE_HANDOFF_PROMPT.md` + `CODEX_HANDOFF_PROMPT.md` refinements + this README index created |
| 2026-05-13 | [`orchestrator_bundle_33_b10_1_fallout.md`](orchestrator_bundle_33_b10_1_fallout.md) | B10.1 fallout cleanup per A3.4 worker disclosures — bleed-stop ceiling raised 19,071 → 19,600; B10.1 carry-forward bare-catch typed at line 14109 |
| 2026-05-13 | [`wave_closeout_checklist_DRAFT.md`](wave_closeout_checklist_DRAFT.md) | DRAFT — operator-approved closeout sequence launchpad (visual-test surface map + HP audit + migration apply queue + sign-off chain); merged to master 2026-05-13 via PR #597 and leaned to current state via PR #613 |
| 2026-05-13 | [`test_proxy_5_failures_investigation.md`](test_proxy_5_failures_investigation.md) | Investigation report reframing B2.3's "5 test failures in test/proxy/" disclosure — actual picture was 2 stale snapshots / 3 cases / 2 files (Bundle 33-style inflation pattern); fix shipped via PR #610 |
| 2026-05-13 | [`c_1_ecdsa_pubkey_gap_investigation.md`](c_1_ecdsa_pubkey_gap_investigation.md) | Investigation report confirming env-var-first interpretation for C-1's SendGrid Event Webhook pubkey (no `email_credentials.sendgrid_event_webhook_pubkey_pem` column needed for V1); C-1b queued conditionally if rotation becomes P0 post-launch |

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

### Lane A — Code Health (PRs #498-581)

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
| #581 | A3.4 | 🔐 | Bare-catch typing chunk 3 of 3 — A3.x cluster CLOSED (Claude) | [`pr_581_a3_4_bare_catch_typing_chunk_3_audit.md`](pr_581_a3_4_bare_catch_typing_chunk_3_audit.md) |
| #588 | housekeeping | ✅ | admin_cors_bootstrap_test sentinel-UUID snapshot fix (Claude sub-agent; closes Bundle 33 deferral) | [`pr_588_admin_cors_bootstrap_test_fix_audit.md`](pr_588_admin_cors_bootstrap_test_fix_audit.md) |

### Lane B — Features (PRs #499-594)

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
| #584 | B2.1 | 🔐 | Default Role catalog schema + publish + production wiring (Claude; send-back cycle on production sink) | [`pr_584_b2_1_default_role_catalog_audit.md`](pr_584_b2_1_default_role_catalog_audit.md) |
| #586 | B11.2.b | 🔐 | RFC 9470 step-up wiring + production binding + client adapters + B9.2 clock-skew fix (Claude; **auth-critical, 20 sensitive routes**) | [`pr_586_b11_2_b_step_up_wiring_audit.md`](pr_586_b11_2_b_step_up_wiring_audit.md) |
| #590 | B2.2 | 🔐 | Default Role catalog admin editor + operator-web Default badge (Claude; UI-only on top of B2.1; 2 honest gaps → B2.3/B2.4) | [`pr_590_b2_2_default_role_catalog_admin_editor_audit.md`](pr_590_b2_2_default_role_catalog_admin_editor_audit.md) |
| #594 | B10.2 | 🔐 | Vendor applicability admin editor + operator-web wage authority binding (Codex; UI + binding on top of B10.1) | [`pr_594_b10_2_vendor_applicability_admin_audit.md`](pr_594_b10_2_vendor_applicability_admin_audit.md) |
| #603 | B2.3 | 🔐 | Default Role catalog blast-radius endpoint — `GET /v1/admin/auth/role-catalogs/blast-radius` returns `{operator_count, location_count, user_count}` (Claude; closes B2.2 Gap 1; single-CTE pattern immune to concurrent operator-flip drift) | [`pr_603_b2_3_blast_radius_endpoint_audit.md`](pr_603_b2_3_blast_radius_endpoint_audit.md) |
| #609 | B2.4 | ✅ | Per-role `catalog_published_at` projection on operator-web roles screen (Claude; closes B2.2 Gap 2 — B2.x family complete; "Updated by F&F on Mon D, YYYY" annotation live) | [`pr_609_b2_4_catalog_published_at_projection_audit.md`](pr_609_b2_4_catalog_published_at_projection_audit.md) |

### Lane C — Cross-Surface Parity

| PR | Slice | Verdict | Topic | Audit doc |
|---|---|---|---|---|
| #499 | C-8 | 🔐 | Notification preferences catalog completeness (Claude) | [`pr_499_c_8_notification_catalog_completeness_audit.md`](pr_499_c_8_notification_catalog_completeness_audit.md) |
| #556 | C-10 | ✅ | Admin parity copy (Codex) | [`pr_556_c10_admin_parity_copy_audit.md`](pr_556_c10_admin_parity_copy_audit.md) |
| #579 | C-3 | ✅ | Sign-in-security → My Account fold (Codex; -1196 LoC net delete) | [`pr_579_c_3_sign_in_security_to_my_account_audit.md`](pr_579_c_3_sign_in_security_to_my_account_audit.md) |
| #580 | C-9 | 🔐 | Mobile inbox catalog rendering — `eventKey` resolution preferred over legacy `type` (Codex) | [`pr_580_c_9_mobile_inbox_catalog_audit.md`](pr_580_c_9_mobile_inbox_catalog_audit.md) |
| #592 | C-4 | 🔐 | Master Demo → Live switch + 4th HP #2 reader-side carve-out (Codex; doctrine expansion specced by ledger row 81) | [`pr_592_c_4_demo_live_master_switch_audit.md`](pr_592_c_4_demo_live_master_switch_audit.md) |
| #599 | C-1a | 🔐 | Email event provider_event_id prep migration — `ADD COLUMN provider_event_id text` + partial UNIQUE INDEX `WHERE provider_event_id IS NOT NULL` (Claude; unblocks C-1; pure additive expand) | [`pr_599_c_1a_email_event_provider_id_audit.md`](pr_599_c_1a_email_event_provider_id_audit.md) |
| #600 | C-5 | 🔐 | Mobile pointer deep-link redemption — mobile mints B11.1 handoff codes, operator-web `/handoff` route redeems via body-only POST; addendum A1 satisfied; defense-in-depth ID token requirement (Codex) | [`pr_600_c_5_mobile_handoff_deeplink_audit.md`](pr_600_c_5_mobile_handoff_deeplink_audit.md) |
| #611 | C-1 | ✅ | SendGrid Event Webhook receiver — pre-decode ECDSA P-256 verify + ON CONFLICT idempotency + env-var-only pubkey + 503 retry posture; `advisor_proxy.dart` UNTOUCHED via main.dart pre-check mount (Claude; unblocks C-2) | [`pr_611_c_1_sendgrid_events_webhook_audit.md`](pr_611_c_1_sendgrid_events_webhook_audit.md) |

### Lane L — Hierarchy Foundations (added 2026-05-13 per operator's B8 Path A pick)

| PR | Slice | Verdict | Topic | Audit doc |
|---|---|---|---|---|
| #608 | L_A1 | 🔐 | Inheritance Tree primitive — `InheritanceTreeNode` value class + shared `InheritanceTree` visualization widget + 3 read methods on `OrgUnitsRepository` (Claude; operator-approved Option 1 — no migration; existing ltree+GIST is the denormalization L_A2 caches off; unblocks B6/B8/C-6) | [`pr_608_l_a1_inheritance_tree_primitive_audit.md`](pr_608_l_a1_inheritance_tree_primitive_audit.md) |

### Housekeeping fixes (test-only / cross-lane closures)

| PR | Topic | Verdict | Audit doc |
|---|---|---|---|
| #604 | B11.2.b test fake wall-clock fix — `_RecordingStepUpGateway` was comparing seeded `expiresAt` to real-clock UTC while the test gate ran on injected clock; pure time-bomb pattern, production code unchanged | ✅ | [`pr_604_b11_2_b_test_fake_clock_fix_audit.md`](pr_604_b11_2_b_test_fake_clock_fix_audit.md) |
| #610 | test/proxy stale-snapshot fix — 2 fixes / 3 cases (B1 sign-in `c3f1ce0d` contract + A3.3 `bb88f82b` typed catch); reframes B2.3's "5 test failures" disclosure (Bundle 33-style inflation) | ✅ | [`pr_610_test_proxy_stale_snapshot_fix_audit.md`](pr_610_test_proxy_stale_snapshot_fix_audit.md) |

## Conventions

- File naming: `pr_<n>_<slug>_audit.md` (per-PR audits) · `pr_<n>_<slug>_followup.md` (orchestrator follow-up commits) · `<topic>_<date>.md` (cross-cutting audits not bound to a single PR).
- Verdict legend in this README is a shorthand. The audit doc itself carries the full verdict + spot-checks + findings.
- New audit doc → add a row here on the next housekeeping pass.
- Pre-wave entries are kept for historical traceability; consult the wave ledger change-log for the active picture.
