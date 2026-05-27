# Post-Hardening Follow-ups

Updated: 2026-05-27 (post-audit remediation wave landed: 9 lanes
merged across PRs [#417](https://github.com/SaidKhan005/forge-flow-demo/pull/417)–
[#426](https://github.com/SaidKhan005/forge-flow-demo/pull/426). 4 of
5 P1 audit-addition items closed; the AI-frozen `advisor_proxy.dart`
placeholder strings remain on the freeze-thaw checklist. P2
broader-bare-catch pattern partially closed for 3 files (`tool/advisor_proxy/advisor_proxy.dart`'s
16 sites still open). 2026-05-08 multi-agent deep-dive sweep added 7
new findings in the "Audit additions — 2026-05-08" section;
postgres-repo coverage line corrected from "18 of 29 / 10 covered"
to actual "27 of 47 / 20 covered"; admin hierarchy lane excluded —
separate team). Prior update 2026-05-07 (Phase 8 plug-and-play V1 closeout —
resolved operator-self-service / backfill-factory / OAuth-refresh-closures /
location-integrations-list / test-connection / api-key paste / route
alignment / binder split / analyzer sweep gaps archived to
`docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-07_phase_8_plug_and_play.md`).
Earlier closeouts: `docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-02.md`
and the 2026-05-07 closeout addendum at the bottom of this file.
Origin: 2026-05-02 deep audit.

## P0 — Webhook signature ordering (2026-05-09 security triage)

Forged-signature webhook POSTs to `/v1/webhooks/{vendor}/{operator}/{location}`
trigger a Postgres SELECT (`vendor_credentials` lookup for the signing secret)
BEFORE any HMAC verification, then leak the raw `Exception.toString()` +
first stack frame in the response body via the
`tool/advisor_proxy/admin_integrations_routes.dart:248` catch-all. Confirmed
schema-info disclosure + DOS amplification on connection pool. Fix slice
proposal + 9-leak-site inventory: `docs/archive/_execution/2026-05-09_security_finding_webhook_signature_ordering.md`.

## P0 — Production1 Migration Apply Gap

**76 migrations pending Production1 apply** (chronological). The queue now
runs through
`202605261200_phase_12_c3_typed_graph_vocabulary.sql`;
staging/preview apply evidence must stay attached to the runbook before any
Production1 apply. This full P0 table is the authoritative apply inventory;
the two first-connect / 11W.7 rows called out in the launch punchlist are the
operator-decision subset, not the complete queue.

| Migration | Origin | Staging |
|---|---|---|
| `202605031430_phase_11A_5_debug_proxy_requests_forge_admin_grant.sql` | 11A.5 Debug Console SELECT grant | applied + Browser Use verified 2026-05-03 |
| `202605041930_phase_11A_operator_location_admin_forge_admin_grants.sql` | 11A operator/location admin DML | applied + Browser Use verified 2026-05-04 |
| `202605060000_mobile_push_notifications.sql` | Mobile FCM/APNs + delivery sidecar | code-ready; needs staging apply + connected-device proof |
| `202605060000_phase_business_timing_live_schema.sql` | `business_timing_profiles` + `open_shift_snapshots` | code-ready |
| `202605061100_phase_11A_14_admin_users_reset_mfa_factors_key.sql` | 11A.14 audited support actions | code-ready (additive seed + grants) |
| `202605061500_hardening_phase_8_email_index_leading_column_rekey.sql` | 5-index `operator_id` rekey | code-ready (`CONCURRENTLY`) |
| `202605061600_phase_11W_5_team_audit_log_export_key.sql` | 11W.5 `team.audit_log.export` key + grants | code-ready |
| `202605061700_hardening_audit_anchor_daily_schedule.sql` | Wave B3 daily pg_cron tick `forge_audit_anchor_daily` 02:00 UTC (NOTIFY-only kickoff) | code-ready |
| `202605061700_phase_8_timing_provenance_shift_records.sql` | Phase 8 timing provenance keys for closed/live shift rows | code-ready |
| `202605061701_phase_8_data_accuracy_service_period_settings.sql` | Wave B1 keyed Data Accuracy child table | code-ready |
| `202605061800_phase_8_first_connection_backfill_jobs.sql` | Phase 8 first-connection durable backfill jobs | code-ready — **operator decision pending** |
| `202605070000_phase_11W_7_operator_account_fields.sql` | 11W.7 / Wave A2 operator-web Account editor write-fields | code-ready — **operator decision pending** |
| `202605070100_password_history_salt_pepper.sql` | Code Health M2 password-history salt/pepper | code-ready |
| `202605070200_audit_anchor_advisory_lock_infra.sql` | Code Health M3 audit-anchor advisory lock + Azure breadcrumbs | code-ready |
| `202605070400_phase_8_notification_preferences.sql` | Phase 8 W2.B per-actor notification preferences (synthetic UUID PK + `UNIQUE NULLS NOT DISTINCT` on 6-tuple, per-user RLS, operator-leading indexes) | code-ready |
| `202605080000_phase_8_timing_provenance_fk_posture.sql` | V1.B Phase 8 timing-provenance FK flip to `ON DELETE SET NULL` | code-ready |
| `202605080100_admin_idempotency_expires_at.sql` | Code Health M1 admin idempotency TTL | code-ready |
| `202605080100_phase_8_weekly_plan_server_truth.sql` | Phase 8 weekly-plan server truth (forecast contexts + snapshots) | code-ready |
| `202605080200_phase_8_wage_role_rows_server_truth.sql` | Phase 8 wage-role row server truth | code-ready |
| `202605080300_phase_8_data_accuracy_walk_in_settings.sql` | Phase 8 walk-in handling additive fields | code-ready |
| `202605080400_phase_8_connector_oauth_state.sql` | Phase 8 connector OAuth CSRF/PKCE state table | code-ready |
| `202605080500_permission_cache_invalidation_channel.sql` | Auth permission cache invalidation NOTIFY channel | code-ready |
| `202605080600_ops_debt_vendor_credentials_webhook_signing_secret.sql` | Webhook signing secret column separate from OAuth bearer ciphertext | code-ready |
| `202605080600_phase_8_demo_pending_counter_persisted.sql` | Persist demo-mode pending insert counters across pods | code-ready |
| `202605080600_phase_8_idempotency_location_id_rekey.sql` | A1 idempotency rekey: add location_id, switch to vendor_modified_at >= guard | code-ready |
| `202605080700_audit_anchor_cron_unpause.sql` | Audit-anchor cron unpause / scheduling follow-up | code-ready |
| `202605080800_auth_permission_version.sql` | Auth permission-version invalidation column/index | code-ready |
| `202605080900_oauth_refresh_advisory_lock.sql` | OAuth refresh advisory-lock registry row | code-ready |
| `202605081000_outbox_notify_channel_split.sql` | Split outbox NOTIFY channels for bounded consumers | code-ready |
| `202605081100_partman_maintenance_hourly_cron.sql` | Register hourly pg_partman audit-log maintenance cron | code-ready |
| `202605081300_seed_kms_rollout_flags_default_disabled.sql` | Seed default-disabled KMS rollout feature flags after sentinel-operator change | code-ready |
| `202605082000_user_pii_erasure_requests.sql` | Durable admin PII-erasure request ledger with 24h reversal window | code-ready |
| `202605082100_phase_10a_3_retention_sweep_in_db_followup.sql` | Register bounded event-outbox retention sweep in Azure split-DB cron topology | code-ready |
| `202605082200_admin_hierarchy_lifecycle.sql` | Admin hierarchy suspend/delete lifecycle columns and permission gates | code-ready |
| `202605121200_admin_hierarchy_scoped_data_polling.sql` | Admin hierarchy scoped Data Accuracy and Polling Setup overrides/effective views | code-ready |
| `202605131000_admin_audit_log_actor_reason_contract.sql` | Admin audit-log actor-kind aliases plus required forge_admin admin_reason | code-ready |
| `202605131010_admin_audit_logs_business_date.sql` | Admin audit-log restaurant-local business_date projection | code-ready |
| `202605131020_admin_hierarchy_lifecycle_access_hardening.sql` | Admin hierarchy lifecycle access refresh, active uniqueness, and direct target guards | code-ready |
| `202605131030_b11_1_auth_handoff_codes.sql` | Lane B B11.1 mobile→web handoff code mint/redeem (operator-scoped, RLS, 60s TTL, addendum A1 — replaces JWT-in-URL) | code-ready |
| `202605131400_b11_2_auth_step_up_challenges.sql` | Lane B B11.2 RFC 9470 step-up challenge ledger (operator-scoped, RLS, 5-minute TTL, route+user binding for replay protection) | code-ready |
| `202605131500_b10_1_vendor_applicability.sql` | Lane B B10.1 vendor applicability temporal table (global defaults + operator overrides, RLS via app_current_operator, JSONB schema guarded in app code) | code-ready |
| `202605131500_b5_b_catalog_tri_mirror.sql` | Lane B B5.b account/timing permission catalog tri-mirror (`account.configure`, `business_timing.configure`) plus owner/admin grants | code-ready |
| `202605131600_b2_1_default_role_catalog_versions.sql` | Lane B B2.1 Default Role catalog versions table + `operators.default_role_catalog_version_id` pointer (global F&F-wide catalog, no RLS) | code-ready |
| `202605131700_c_1a_email_event_provider_id.sql` | Lane C C-1a `email_event.provider_event_id` column + partial UNIQUE INDEX `WHERE provider_event_id IS NOT NULL` (additive expand; backs C-1 receiver's `ON CONFLICT DO NOTHING` for SendGrid event dedupe; no RLS change) | code-ready |
| `202605131800_c_7a_recovery_codes_viewed_at.sql` | Lane C C-7a `mfa_factors.recovery_codes_viewed_at timestamptz NULL` (additive expand; unblocks Codex's C-7 Adaptive 2FA button compute over `(session.mfaEnrolled, factor_count, recovery_codes_viewed_at)`; no new index, no RLS change) | code-ready |
| `202605131900_c_2_d_vendor_sync_outage_state.sql` | Lane C C-2-D `vendor_sync_outage_state` per-(operator_id, location_id, connection_id) state surface for the first-failure-of-outage detector that gates the `vendor_sync_error_alert` email (one row per outage window; cleared on next `poll_success`; per-tenant RLS mirroring `connector_sync_log`) | code-ready |
| `202605140000_w_3_self_profile_perm_key.sql` | Wave 2 W-3 `team.users.self_update` permission key + baseline grants to every seeded operator role and super_admin. Backs the new `PATCH /v1/auth/self/profile` self-service profile editor on operator-web and admin My Account surfaces. | code-ready |
| `202605142100_phase_R_1L_roles_schema_rewrite.sql` | Wave 2 R-1L Roles schema rewrite: `permission_keys.product_label` + `category_label` + `scope_kind` (CHECK `org_wide`/`location_scoped`/`either`) + `implies text[]` columns added NULLABLE with inline backfill; defers NOT-NULL flip to R-1L-FU follow-up per expand-contract discipline. Backfill mirrors `lib/services/auth/custom_role_validator.dart`'s `kOrgWidePermissionKeys` + `kViewRequiredForWrite` + `kTeamUsersWriteKeys`. Runtime mirror at `lib/auth/permission_key_metadata.dart` is NOT-NULL-at-source via `tool/permission_key_lint.dart` METADATA pass. Resolver imply walk in `lib/auth/permission_resolution.dart`. | code-ready |
| `202605150000_phase_r2l_default_role_catalog_v2.sql` | Wave 2 R-2L Default Role Catalog v2 redesign: adds `permission_keys.human_label` NULLABLE with inline backfill, seeds 7 v2 role rows (general_manager / location_manager / supervisor / finance_analyst / auditor_compliance / training_lead / team_admin) + Owner v2 wording refresh, auto-migrates v1 user_roles (`operator_manager` -> `operator_general_manager`; `operator_supervisor` / `operator_staff` -> `supervisor` with location fan-out), soft-deletes v1 retired roles, emits `auth.role.seeded_catalog_v2_published` audit rows. Defers NOT-NULL flip on `human_label` to R-1L-FU follow-up. Runtime mirror at `lib/auth/permission_key_metadata.dart` is NOT-NULL-at-source via `tool/permission_key_lint.dart` HUMAN_LABEL_INVALID pass. | code-ready |
| `202605150100_phase_r_followup_not_null_flip.sql` | Wave 2 R-1L-FU + R-2L-FU contract migration: flips `permission_keys.product_label` + `category_label` + `scope_kind` + `human_label` from NULLABLE to NOT NULL after R-1L + R-2L inline backfills hydrated every row, and re-asserts `implies text[]` default of `'{}'::text[]` + NOT NULL. Defensive pre-flight DO block raises with the offending row count if any of the five columns is still NULL before the flip (never silently tightens). Idempotent: each `SET NOT NULL` no-ops on already-tight columns. Runtime mirror at `lib/auth/permission_key_metadata.dart` is NOT-NULL-at-source via `tool/permission_key_lint.dart` METADATA + HUMAN_LABEL_INVALID passes, so the inline backfills are guaranteed to find a non-NULL value in every row before this flip applies. | code-ready |
| `202605150200_phase_u_fu_hp11_account_per_location_overrides.sql` | Wave 2 U-FU-hp11-account per-location override schema for the three AccountScreen settings (region, business-day rollover, identity contact email + phone). Adds `public.location_account_overrides` keyed by `(operator_id, location_id)` with NULL columns inheriting the business defaults from `public.operators`. RLS via `app_current_operator()` wrapper + operator-leading B-tree index per HP #4. Reuses the existing operator_owner role gate: no new permission key. Business display name stays operator-wide (single business name doctrine); the location-scoped Identity card edits contact email + phone only. | code-ready |
| `202605150300_phase_rp_9_default_catalog_edit_permission_key.sql` | Wave 2 RP-9 `team.roles.default_catalog.view` + `team.roles.default_catalog.edit` permission keys + baseline grants (F&F super_admin write; super_admin + ff_support read). Promotes the role-tier gate on `default_role_catalog_admin_screen.dart` + `tool/advisor_proxy/admin_default_role_catalog_routes.dart` to a granular permission key registered in the catalog. F&F-internal admin scope — NOT widened to operator-tier roles. | code-ready |
| `202605150400_per_daypart_v1_drop_close_authority.sql` | Per-Daypart V1 Slice 1.5 deprecation step on `public.business_timing_profiles`: drops the `business_timing_profiles_local_close_required_check` cross-column CHECK and drops the NOT NULL constraint on `close_authority`. Operator decision 2026-05-15: close-authority is now auto-derived per shift from the per-vendor `CloseAuthorityCapability` lookup (`lib/services/integration/close_authority_capability.dart`) + `business_day_start_local_time` fallback. Full column drop deferred to a follow-up Postgres-only slice that also refactors `BusinessTimingProfilesRepository`'s `closeAuthority` / `localCloseFallbackTime` write surface. | code-ready |
| `202605160000_per_daypart_v1_per_period_target_persistence.sql` | Per-Daypart V1 Slice 1 per-period data layer foundation. Adds `target_cycle_dayparts` (per-(cycle, service_period) locked CPLH/SPLH/PPA + OPZ + cover_count for cover-weighted whole-day pool rollup) and `weekly_plan_snapshot_day_dayparts` (per-(snapshot, business_date, service_period) demand-derived values + theoretical FOH/BOH dollars at lock time). Adds `weekly_plan_snapshots.wage_at_lock_time_json` (JSONB stamp — Design Rule 8: audit checks compare locked dollars against this column, not current wages). Adds 5 per-shift per-period target stamp columns on `shift_records` so closed truth retains its period band stamp per Promise 2. Both new tables are operator-scoped + RLS-policy-protected with the four sanctioned wrapper functions; B-tree indexes lead with `(operator_id, location_id)` per `hardening_rls_and_repository_pattern_contract.md`. | code-ready |
| `202605161500_per_daypart_v1_deprecate_locations_rollover_hour.sql` | Per-Daypart V1 Slice 7b option (b) deprecation note on `public.locations.business_day_rollover_hour`. `COMMENT ON COLUMN` only — no DDL or data change, fully backward compatible. Documents that vendor sinks now resolve the business-day cutoff via the canonical `business_timing_profiles.business_day_start_local_time` chain (operator → org_unit → location inheritance per HP #11, sub-hour aware). The SQL trigger `phase_8_set_business_date()` still reads the column as a defense-in-depth backup (sub-decision b1). The drop migration is deferred to a follow-up after a deprecation cycle. | code-ready |
| `202605161501_per_daypart_v1_s0_verdict_persistence.sql` | Per-Daypart V1 Slice S0 per-period verdict persistence foundation. Adds two additive, nullable, no-default TEXT columns (`verdict`, `verdict_reason`) to the existing per-period child table `public.target_cycle_dayparts`. Back-compat: pre-S0 rows (and rows the future selection algorithm leaves unscored) read back NULL; Design Rule 2 — callers never substitute 0/empty. No algorithm, seeder, widget, or copy change. RLS posture unchanged (inherits the table's existing `(operator_id, location_id)` per-tenant-location policy). | code-ready |
| `202605170000_per_daypart_v1_r5_covers_source_keyed_backfill.sql` | Per-Daypart V1 R5 covers-source de-hardcode. Data-preserving backfill of legacy `covers_source_{lunch,dinner,late_night}` into the keyed `public.data_accuracy_service_period_settings` table (sentinel `effective_at_business_date` reproducing the legacy always-applies semantics, `ON CONFLICT DO NOTHING` so an operator-set keyed row is never clobbered, operator_id/location_id copied for per-tenant isolation, the keyed table's existing wrapper-only RLS preserved). Legacy 3 columns marked DEPRECATED via `COMMENT ON COLUMN`; no read path uses them post-R5. Hard column drop deferred to follow-up R7 (after proxy bootstrap SQL + `effective_data_accuracy_settings_v` view + HP #11 hierarchy surface are migrated). Additive + comment-only; no down migration. | code-ready |
| `202605170100_per_daypart_v1_r7a_covers_source_per_period_hierarchy.sql` | Per-Daypart V1 R7a per-period covers-source hierarchy. ADDITIVE: `public.effective_data_accuracy_settings_v` gains a `covers_source_per_service_period` jsonb output (resolved most-specific-scope-wins from the keyed `data_accuracy_service_period_settings` effective rows, HP #11 operator/org_unit/location precedence preserved), and `public.data_accuracy_scoped_overrides` gains a nullable `covers_source_per_service_period` jsonb column. Existing 3 scalar view outputs byte-unchanged; no column dropped or altered; RLS/timestamptz/operator-leading-index compliant; idempotent; no down migration. Sets up R7b (proxy onto the jsonb) and R7d (final legacy-column drop). | code-ready |
| `202605170200_per_daypart_v1_r7d_drop_legacy_covers_columns.sql` | Per-Daypart V1 R7d FINAL covers-source de-hardcode step (schema-destructive). Atomic `begin; create or replace view public.effective_data_accuracy_settings_v` (R7a body minus the 3 legacy scalar outputs) then `alter table ... drop column if exists` the 3 legacy `covers_source_{lunch,dinner,late_night}` columns on `public.data_accuracy_settings` and the 3 legacy scalar columns on `public.data_accuracy_scoped_overrides`; `commit;`. No `cascade`, view never dropped. Safe because R5 backfilled into the keyed table, R7a added the per-period jsonb (view + scoped-overrides), R7b moved the proxy off legacy-column SQL, R7c removed dead legacy-column Dart; pre-drop grep proved zero remaining SQL/view-scalar readers. Idempotent (`drop column if exists`); no down migration (destructive, rationale in header). Production-safe: all prior covers-source migrations Production1-pending, no live data. | code-ready |
| `202605190900_per_daypart_v1_r7e_data_accuracy_provenance.sql` | Per-Daypart V1 R7e Data Accuracy provenance. Additive `create or replace view` appends source metadata to `public.effective_data_accuracy_settings_v` for per-service-period covers source, wage source, and walk-in handling mode while preserving existing value columns and HP #11 precedence. No table shape change, no policy/index change, no down migration. Enables Admin/Operator Web to show honest inherited-source labels from server truth instead of guessing in Flutter. | code-ready |
| `202605191000_per_daypart_v1_r7f_data_accuracy_precedence_fix.sql` | Per-Daypart V1 R7f Data Accuracy precedence and source parity. `create or replace view` repairs `public.effective_data_accuracy_settings_v` so keyed service-period rows are base defaults, while business, org-unit, and location scoped overrides win above them per HP #11. Source metadata follows the same winning scope. No table shape change, no policy/index change, no down migration. | code-ready |
| `202605191830_canonical_fact_projection_retry_jobs.sql` | Canonical fact projection retry ledger. Adds `public.canonical_fact_projection_retry_jobs` so post-commit projection failures can be replayed from saved projector input without re-running vendor writes. Tenant-scoped RLS, operator-leading indexes, bounded retry state, and JSON payload checks. Schema-touching and requires explicit operator approval before merge/apply. | code-ready |
| `202605191845_data_accuracy_cover_facts_nullable_covers.sql` | Data Accuracy covers truth. Drops default/not-null from `public.cover_facts.covers` so NULL means the POS did not expose cover count and zero means a cover-capable POS sent zero. | code-ready |
| `202605191900_canonical_fact_projection_retry_evidence.sql` | Projection retry evidence hardening. Adds explicit pre-input/post-input failure stage metadata, immutable original location/connection ids, and FK posture that nulls live pointers instead of deleting terminal retry evidence during hard-delete cleanup. Schema-touching and requires explicit operator approval before merge/apply. | code-ready |
| `202605192200_data_accuracy_reset_delete_grants.sql` | Data Accuracy reset grant. Grants DELETE on `public.data_accuracy_service_period_settings` to `service_role` and `forge_admin` so explicit service-period resets can remove a local override and let inherited settings win again. | code-ready |
| `202605200900_brand_org_unit_type.sql` | Operator hierarchy Brand layer. Allows `org_units.unit_type = brand` so Brand is a real hierarchy layer rather than a UI label only. | code-ready |
| `202605201000_org_unit_account_overrides.sql` | Org-unit account overrides. Adds contact/currency/locale/timezone overrides for Brand, Region, District, and Location group scopes, inherited by child locations. | code-ready |
| `202605201100_operator_account_contact_fields.sql` | Operator account contact defaults. Adds real Business-level contact email and phone columns so lower scopes inherit from the Business row instead of a missing server field. | code-ready |
| `202605230900_phase_slice_e_admin_hierarchy_keys.sql` | Slice E admin.hierarchy.* keys. Additive seed of five DORMANT permission-key catalog rows (`admin.hierarchy.create/move/rename/suspend/delete`), granted to `super_admin` + `ff_support`; suspend + delete carry `requires_mfa = true`. For a later F&F "Business accounts" admin hierarchy-mutation gate; no consumer wired yet. | code-ready |
| `202605240900_b10_1_vendor_applicability_location_scope.sql` | B10.1 vendor_applicability location scope. Adds a nullable `location_id` (CHECK: location requires operator; composite FK to `locations`), location-leading current/history indexes (operator_id still leads), and re-asserts the operator-keyed RLS policy unchanged. Foundation only: read precedence becomes location > operator > global; proxy/admin/operator-web/worker unchanged. | code-ready |
| `202605240900_plans_and_limits_phase0_subscription_tier_check.sql` | Plans & Limits V1 Phase 0 subscription_tier CHECK. Backfills legacy `operators.subscription_tier = 'launch'` to `'pilot'`, relaxes the column default to `'pilot'`, and adds a CHECK pinning the column to the six operator-approved tiers (pilot/starter/premium/elite/pro/enterprise). | code-ready |
| `202605241000_advisor_conversation_log_request_correlation_and_retention.sql` | P1a Support logs telemetry groundwork. Adds a NULLABLE `request_id` uuid correlation key (advisory join onto `proxy_requests.request_id`, intentionally no FK) + operator-leading `(operator_id, location_id, request_id)` join index to `advisor_conversation_log`, and makes retention real: cluster-wide `advisor_conversation_log_purge_expired()` (SECURITY DEFINER, forge_admin EXECUTE only, `FOR UPDATE SKIP LOCKED`) scheduled daily 03:15 UTC via pg_cron. NEVER purges `legal_hold` or `retention_class='permanent'` rows. Schema + RLS-adjacent; gated on operator approval. | code-ready |
| `202605241500_create_proxy_request_stats.sql` | P1a' Support logs telemetry storage. Creates `public.proxy_request_stats` (stats-only per-AI-request telemetry: tokens / cost / latency / outcome / provider+model ids + `actor_user_id` uuid + advisory `request_id` correlation to `proxy_requests`; NO message content, NO `business_date`). Operator-scoped fact table (composite `locations` FK, wrapper-based per-tenant RLS, operator-leading indexes); cluster-wide `proxy_request_stats_purge_expired()` (SECURITY DEFINER, forge_admin EXECUTE only, `FOR UPDATE SKIP LOCKED`) scheduled daily 03:30 UTC via pg_cron for 30-day retention. Schema + RLS; gated on operator approval. | code-ready |
| `202605241600_plans_and_limits_phase4_operator_trial_mode.sql` | Plans & Limits V1 Phase 4a Pilot free-trial flag. Adds `trial_mode boolean not null default false` + `trial_expires_at timestamptz` to the tenant-root `public.operators` table, plus a CHECK that an expiry exists iff `trial_mode` is true. Per-operator trial FLAG (NOT a `demo_*` table, NOT a second demo mode — HP #2); inherits the existing operators RLS (no new policy). Set by the start-pilot path; cleared by the conversion path when real POS/labor data connects. Schema; gated on operator approval. | code-ready |
| `202605241700_plans_and_limits_phase5a_feature_entitlements.sql` | Plans & Limits V1 Phase 5a feature-entitlements foundation. Creates GLOBAL `public.feature_entitlements` (composite PK `(tier_key, feature_slug)`, CHECK pinning `tier_key` to the six tiers, `enabled boolean default false`, `updated_at` TIMESTAMPTZ, `updated_by`). No `operator_id` / RLS (admin-pool BYPASSRLS posture, exactly like `pricing_plan_catalog`); REVOKE public + GRANT SELECT service_role + full DML forge_admin. Records WHICH FEATURES EACH PLAN INCLUDES (slugs: advisor / lms / scoreboard / staff_coach / sops / workflows). Idempotent seed of the cumulative ladder (advisor on for pilot + every paid tier; lms+scoreboard premium and up; staff_coach+sops elite and up; workflows pro and up; enterprise all on) via `on conflict do nothing`. FOUNDATION ONLY: records the matrix, does not gate the app yet (deferred Phase 5d). Schema; gated on operator approval. | code-ready |

| `202605251000_plans_and_limits_scoped_contract_overrides.sql` | Plans & Limits V1 scoped custom contract foundation. Creates operator-scoped `public.pricing_contract_overrides` for Enterprise/custom commercial terms at business, org-unit, or location scope. Lower scopes override higher scopes; missing lower scopes inherit from the nearest ancestor or the global pricing catalog. Stores monthly, seat-ramp, onboarding, advisor-cap, label, note, billing-owner, and effective-date fields. RLS-enabled with `app_current_operator()` tenant policy, operator-leading indexes, service/forge admin grants, and an updated-at trigger. Schema + RLS + proxy-writing surface; gated on operator approval. | code-ready |
| `202605251020_plans_and_limits_scoped_contract_windows.sql` | Plans & Limits V1 scoped custom contract windows. Replaces all-time target uniqueness with non-overlapping effective-date windows so a future-dated custom contract can be scheduled without overwriting the current active contract. Adds the target-window index plus overlap trigger. Schema + RLS-adjacent follow-up; gated on operator approval. | code-ready |
| `202605261200_phase_12_c3_typed_graph_vocabulary.sql` | Phase 12 / G2 C3 typed graph vocabulary. Adds `public.graph_node_kinds` + `public.graph_edge_types` global lookup tables seeding the C3-approved node kinds (Concept, SOP, Policy, Metric, Formula, Risk, Word_To_Know, Coaching_Move, Role, Workflow, Document, Chunk, Procedure) and edge types (CONTAINS, CAUSES, INFORMS, RELATES_TO, DEPENDS_ON, GOVERNS, MITIGATES, TEACHES, DEFINES, MEASURES, CALCULATES, REDUCES_RISK_OF, REQUIRES, PART_OF, NEAR). Also adds `graph_nodes_unknown_kinds` + `graph_edges_unknown_types` validation views for C4 FK preparation. Global (no operator_id / RLS); GRANT SELECT to authenticated, full DML to service_role + forge_admin. **OP-GATED — hold for explicit operator approval before apply.** | code-ready |

**Action:** apply all 76 in next Production1 event per
`runbooks/phase_9_production1_migration_apply_runbook.md`. Until applied
+ verified, the corresponding feature is **staging-ready only**.

## P1 — B11.1 Idempotency-Store Convention (deep-audit follow-up)

**Origin:** Wave completion deep audit 2026-05-13
(`docs/archive/_audits/post_codex_wave/wave_completion_deep_audit_2026_05_13.md` finding #4).
B11.1 (PR #512, merged 2026-05-12) introduced `handoff_codes` — operator-scoped
mint/redeem ledger with 60s TTL. The deep audit flagged that the
**idempotency-store convention is not yet codified**: subsequent slices
(B11.2's `auth_step_up_challenges`, future `handoff_code`-shaped tables) have
mirrored the idiom by hand, with no shared abstraction, no lint enforcing
the shape (PK+operator_id+TTL+consumed_at+RLS+operator-leading indexes),
and no convention doc.

**Why this is a followup, not a slice yet:** no current slice in the ledger
touches the surface. The convention is best codified the next time a slice
adds a third idempotency-store table (or sooner if drift becomes apparent).
A new lint enforcing the shape can ship alongside that slice.

**Scope when a slice picks this up:**
1. Doc the convention in `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
   (or a new contract doc) — shape: `(opaque_id text PK, operator_id uuid, ...)`
   + RLS via `app_current_operator()` wrapper + operator-leading B-tree
   indexes + TTL CHECK + base64-url id shape CHECK + idempotent DDL.
2. Add a lint at `tool/idempotency_store_convention_lint.dart` that scans
   `db/migrations/*.sql` for tables matching the shape and fails CI when
   any of the 6 invariants are missing.
3. Optionally extract a shared Dart abstraction (`IdempotencyStoreGateway<T>`)
   that future stores bind to (mirror `OperatorScopedRepository<T>` pattern).

**Lock until then:** new idempotency-store tables landing before this slice
must mirror the B11.1 / B11.2 idiom by hand; orchestrator audit must spot-check
the 6 invariants against the migration on every such slice.

## P1 — Doc-Drift + Nits Batch (deep-audit P2/P3 holding line)

**Origin:** Wave completion deep audit 2026-05-13. The audit's P2 doc-drift
items (4) and P3 nits (2) do not warrant their own ledger rows; they get
fixed opportunistically when someone is next in the relevant file.

**Reference:** `docs/archive/_audits/post_codex_wave/wave_completion_deep_audit_2026_05_13.md`
sections P2 + P3 (full enumeration with file:line + suggested action per
item). Pick up alongside any unrelated slice that touches those files.

## P1 — Soak Heap-Snapshot Uploader: swap GCS → Azure Blob (A11.2 follow-up)

**Origin:** A11.2 (PR #537, merged 2026-05-13 at `8463d56b`) added a
storage-agnostic `HeapSnapshotUploadTarget` interface plus a concrete
`GcsHeapSnapshotUploadTarget` implementation (raw GCS REST PUT via
`dart:io HttpClient` + bearer-token auth). The slice doc specified GCS;
F&F's only other cloud-storage client is Azure Blob
(`tool/audit_anchor/azure_blob_client.dart`).

**Operator decision (2026-05-13):** F&F will not run two cloud-storage
backends. The GCS implementation must be **replaced** with an Azure Blob
implementation before any soak run actually uses uploads.

**Binding constraint:** the GCS env vars (`GCS_BUCKET_HEAP_SNAPSHOTS`,
`GCS_BEARER_TOKEN`) MUST stay unset on every host until this swap lands.
The uploader is inert when unconfigured (one "skipped" log line at start);
that inert state is the safety guarantee until the Azure swap ships.

**Follow-up slice scope:**
- Add `AzureBlobHeapSnapshotUploadTarget implements HeapSnapshotUploadTarget`
  modeled on `tool/audit_anchor/azure_blob_client.dart` (workload-identity-
  federation flow analogous to the audit-anchor pattern).
- Switch the default binding in `tool/pressure/p4_heap_snapshot_uploader.dart`
  from `GcsHeapSnapshotUploadTarget` to `AzureBlobHeapSnapshotUploadTarget`.
- **Delete** `GcsHeapSnapshotUploadTarget` and the GCS env-var references —
  no two-backend codebase. The storage-agnostic interface stays as the
  load-bearing artifact.
- Update tests (the existing `_StubUploadTarget` in
  `test/pressure/p4_heap_snapshot_uploader_test.dart` already implements
  the interface — should keep passing without change).
- Add the new env vars (`AZURE_BLOB_HEAP_SNAPSHOTS_CONTAINER`, etc.) to
  `runbooks/cloud_run_env_vars.md` once the workload-identity flow is wired.

**Authority anchors:**
- `tool/audit_anchor/azure_blob_client.dart` (the canonical F&F Azure
  Blob pattern to mirror)
- `docs/archive/_audits/post_codex_wave_2026-05-13/pr_537_a11_2_soak_harness_extensions_audit.md`
  (audit doc that flagged the decision)
- This entry.

**Not blocking:** A11.2's other deliverables (fd watcher, p3c CLI flags)
are independent of this swap and stay live on master.

## ~~P1~~ RESOLVED — C-1 SendGrid Webhook: outbox-status flip on terminal events (PR #611 follow-up)

**Status: RESOLVED in PR `claude/sendgrid-outbox-status-flip` (2026-05-20).**
`EmailEventRepository.insertProviderEvent` now flips
`email_outbox.status` to the terminal kind (`bounced` / `complaint`)
in the same `runAsSystem` transaction as the `email_event` INSERT,
guarded against overwriting `{bounced, complaint, failed}` and
against duplicate-event re-runs. The historical scope notes below
are preserved for audit context.

**Origin:** 2026-05-19 review of a rescued earlier SendGrid implementation
(rescue branch `rescue/wt-snapshot/master-sendgrid-webhook-20260519-054323`)
against the landed Lane C C-1 + C-1a stack (PRs
[#599](https://github.com/SaidKhan005/forge-flow-demo/pull/599) +
[#611](https://github.com/SaidKhan005/forge-flow-demo/pull/611)). The
compare-against-origin pass confirmed every rescued file is superseded,
but surfaced one delta the landed implementation does NOT cover.

**The gap.** `lib/services/email/email_outbox_dispatcher.dart` lines 8-15
contracts that bounce/complaint transitions are owned by the SendGrid
webhook handler:

> The `bounced` / `complaint` transitions are owned by the SendGrid
> webhook handler — the dispatcher itself only advances pending →
> sending → sent / failed.

But the landed webhook receiver does NOT perform that flip. Greps across
`tool/advisor_proxy/sendgrid_events_webhook.dart` and
`lib/infrastructure/persistence/postgres/repositories/email_event_repository.dart`
find zero `UPDATE email_outbox SET status` writes; the receiver only
INSERTs into `email_event` with `ON CONFLICT DO NOTHING`. No NOTIFY-based
listener picks up the slack (the existing NOTIFY channels cover
`event_outbox` and permission-cache, not the email outbox). On origin
today, a `bounce` or `complaint` SendGrid event creates an `email_event`
row but leaves `email_outbox.status` at `'sent'` indefinitely.

**Why this is follow-up, not a PR #611 regression.** The PR #611 audit
(`docs/archive/_audits/post_codex_wave_2026-05-13/pr_611_c_1_sendgrid_events_webhook_audit.md`)
scoped explicitly to parse + verify + INSERT. The outbox-flip was
implicitly deferred. Operator-facing queries that need delivery state
can join `email_outbox` to `email_event` today; the denormalized status
column is just stale.

**Why P1 not P0.** No live SendGrid traffic in production yet (Phase 9.8
staging-only). Staging soak surfaces the divergence before launch.

**Follow-up slice scope (when picked up):**
1. Add a method on `EmailEventRepository` that updates the matching
   `email_outbox` row's status to the terminal kind (`bounced` /
   `complaint`), guarded against overwriting an already-terminal state
   (prevents flapping when SendGrid emits both `bounce` and a later
   `dropped` for the same email).
2. Call it from `sendgrid_events_webhook.dart` after the
   `EmailEventInsertResult.inserted` path, only for terminal event
   kinds, and only when the FK to `email_outbox.email_id` resolves.
   `duplicate` results skip the flip (idempotent on replays).
3. Wrap both writes in the same `runAsSystem` admin-pool transaction so
   an event row never lands without its corresponding outbox flip.
4. Tests: terminal kind flips status; non-terminal kinds (`delivered`,
   `open`) leave status untouched; duplicate event does not re-flip;
   already-terminal `email_outbox.status` (e.g. `failed`) is not
   overwritten.

**Authority anchors:**
- `lib/services/email/email_outbox_dispatcher.dart:8-15` — the contract
  that the webhook owns bounce/complaint transitions.
- `tool/advisor_proxy/sendgrid_events_webhook.dart` — the landed receiver
  that does not flip.
- `lib/infrastructure/persistence/postgres/repositories/email_event_repository.dart`
  — the natural home for the new method, mirroring its existing
  `runAsSystem` discipline.
- `docs/archive/_audits/post_codex_wave_2026-05-13/pr_611_c_1_sendgrid_events_webhook_audit.md`
  — PR audit that scoped to receiver-only.
- Rescue branch `rescue/wt-snapshot/master-sendgrid-webhook-20260519-054323`
  — a superseded earlier implementation containing an in-line example
  of the flip pattern; useful only as a sketch, its architecture is
  incompatible with the landed `OperatorScopedRepository` discipline.

**Not blocking:** the C-1 + C-1a receiver path is correct as-is for the
events-as-audit-log use case. Defer until staging exercises the bounce
flow or an operator-facing query needs the denormalized status to be
accurate.

## P1 — Live Admin Operational Gates

The staging admin smoke surfaced live actions that code cannot complete
without operator-held secrets and action-time approval. Resolved graph
candidate packaging and staging audit-anchor remediation are archived in
`docs/archive/_execution/2026-05-03_runtime_acceptance_and_perf_carry_forward.md`.

- Provider credentials / KMS rollout: use
  `runbooks/admin_provider_credentials_kms_rollout_runbook.md`.
- Admin browser QA: use the static-build path in
  `runbooks/admin_console_browser_qa_runbook.md`; treat debug web-server
  bootstrap failures as dev-workflow noise unless the static build also
  fails.

## P1 — Business Timing / Live Shift Architecture Follow-ups

Open items from the 2026-05-06 audit:

- Add keyed per-service-period Data Accuracy settings before enabling a
  fourth or non-canonical service period key for an operator. (Schema
  ships in `202605061701_…`; consumer code lane open.)
- Persist/use stable timing profile and service-period keys for
  bucketed live and closed facts so label changes do not rewrite
  history.
- Treat Operator Web as the normal timing editor and F&F Operations
  Console as audited support override only.

### Phase 8 timing-provenance — only one open thread

Lane 0 + 1 + 2 + 3 + 4 + 5 + the closed-row proxy gap (V1.A) + FK
posture flip (V1.B) all merged 2026-05-06/-07. The single remaining
follow-up:

- **Drop the version-equals-profile CHECKs before any future Phase 8R
  divergence.** Lane 0 added
  `shift_records_timing_version_profile_match_check` and
  `open_shift_snapshots_timing_version_profile_match_check`
  (`version_id IS NOT DISTINCT FROM profile_id`, both `NOT VALID`) as
  the V1 enforcement of decision A. When Phase 8R introduces a real
  `business_timing_profile_versions` table and code starts writing a
  divergent `version_id`, both CHECKs must be dropped first; otherwise
  the first divergent INSERT fails. Refs:
  `db/migrations/202605061700_phase_8_timing_provenance_shift_records.sql:51-66,
  113-129`.

## P2 — Test Coverage Gaps Remaining

| Surface | LOC | Test files | Coverage |
|---|---|---|---|
| `lib/admin/services/operator_location_admin_gateway.dart` | 311 | 1 (added L4) | partial; gateway tests landed PR #53 |
| `lib/admin/services/pricing_tier_admin_gateway.dart` | 311 | 1 (added L4) | partial; gateway tests landed PR #53 |
| `lib/admin/services/integration_admin_gateway.dart` | 311 | 1 (added L4) | partial; gateway tests landed PR #53 |
| 27 of 47 postgres repositories | varies | 20 covered (43%) | partial; chip away during routine slices. Audit recount 2026-05-08 — prior tracker line said "18 of 29 / 10 covered"; current census is 47 repos / 20 with `*_test.dart`. Highest-LOC uncovered: `weekly_plan_snapshot_repository.dart` (1038), `business_timing_profiles_repository.dart` (947), `target_cycle_repository.dart` (775), `corpus_repository.dart` (738), `forecast_context_repository.dart` (690), `graph_repository.dart` (684), `active_target_profile_repository.dart` (675), `auth_events_audit_repository.dart` (633), `selected_star_shift_repository.dart` (616), `user_pii_erasure_repository.dart` (656). |

## P3 — Verified-keep API surfaces (verified 2026-05-06, Wave B4)

The 2026-05-02 audit flagged these as "unused public classes." The
2026-05-06 verification sweep (Wave B4) found each is the return type
of a unit-tested method on a sibling class in the same file — none
deletable in isolation:

- `AuditLogExportResult` — return type of `AuditLogCsvExport.export(...)`.
- `MfaOverrideChange` — value type of `MfaPolicyEditorState.diff()`.
- `MatrixCellChange` — element type of
  `RolePermissionMatrixController.diff()`.
- `CorpusCloudLoadResult` — return type of
  `AdvisorCorpusAdminService.attemptCloudLoad(...)`.

**Status:** keep all four. Re-evaluate only if the sibling method
(`export`, `diff`, `attemptCloudLoad`) is itself removed in a wider
lane.

## P3 — Cross-surface hierarchy/parity gaps (audit 2026-05-16)

Surfaced by a deep cross-surface hierarchy audit (web console / admin
console / mobile). Documented here as **known, accepted, not blocking
V1**. Mobile single-location flatness from the same audit was promoted
to a contract rule (`docs/contracts/mobile_core_business_scope_contract.md`
Hard Rule 9) and is NOT a follow-up. Org-unit rename/delete absence and
`unit_type` invisibility are tracked separately. The two below are
orphans with no active slice:

- **A5 — Org-unit mutation permission-gate asymmetry (accepted, document
  only).** Operator-web gates org-unit create/move on the named RBAC key
  `team.roles.assign` (`lib/operator_web/screens/hierarchy_screen.dart`
  `kHierarchyAssignPermissionKey`). The admin console gates the same
  mutations on an `actorIsForgeAdmin` boolean (Firebase super-admin /
  ff_support claim) rather than a matching `admin.*` permission key;
  `roles_hierarchy_sessions_admin_gateway.dart` `createOrgUnit` calls
  `_requireEditable(actorIsForgeAdmin, ...)` + `_requireAdminReason(...)`
  with no permission-key check. The parity contract
  (`docs/contracts/team_roles_hierarchy_console_parity_contract.md`)
  describes the admin side only as the `admin.users.create` "analog"
  and names no concrete key. **Status:** accepted for V1 — the admin
  surface is already behind the admin-app auth gate (super_admin /
  ff_support only) + `admin_reason`, so this is a governance/consistency
  gap, not an access-control hole. Revisit if non-super-admin F&F staff
  ever need scoped hierarchy-edit rights, or when the parity contract is
  next amended (give the admin analog a real `admin.*` key then).

- **A7 — Operator-web exposes no data-freshness / sync-health signal
  (accepted, document only).** Confirmed 2026-05-16: operator-web has no
  "data current / stale / last synced / feed broken" indicator. Mobile's
  `lib/services/app_data_status_service.dart` (DEMO/CURRENT/STALE/
  BACKFILL-FAILED) is not consumed anywhere in `lib/operator_web/**`;
  `web_app_shell.dart` has no status pill. The closest surfaces are not
  freshness signals: the polling-tier status card
  (`lib/operator_web/widgets/polling_tier_status_card.dart`) shows tier/
  cadence/pricing, the backfill progress panel
  (`vendor_connections_backfill_progress_panel.dart`) only covers the
  one-time 60-day initial import then goes silent, and the Schedule
  "Locked at" timestamp is plan-commitment metadata, not sync health.
  **Status:** accepted for V1. If closed later, the cheapest path is to
  have operator-web consume `AppDataStatusService` and render a header
  badge mirroring the mobile pattern, or a "last synced at X" on the
  dashboard. No contract requires this surface today.

- **B2 — Wage Authority is location-scoped only; hierarchy/inherited
  wages deliberately NOT done (accepted, document only).** Operator
  decision 2026-05-16: do NOT pursue business/region-scoped wage rows
  for now. There is no small-footprint version — `wage_role_rows` has
  no scope columns, so any fix inherently requires a schema migration +
  an RLS-policy rewrite (operator+location → operator-only, the
  benchmark_overrides posture). Operator judged that "touches too
  much." A complete, audited implementation was built and rejected at
  the merge gate (closed PR #836, branch retained on
  `claude/gap-b2-wage-role-rows-hierarchy-scope` if appetite returns).
  Multi-location operators continue to set wages per location. This is
  now a deliberate choice, not a gap — same posture as B4/B5. The
  in-UI `HierarchyScopeNotice` `backendOnlyExplainer` on
  `lib/operator_web/screens/wage_authority_screen.dart` was corrected
  2026-05-16 (this branch): the prior "region/brand wage floors are
  coming in a later wave" wording (PR #659) promised future delivery,
  which now misrepresents a decided won't-do. The corrected copy
  states wage rows are set per location **by design** with no
  region/brand floor to inherit — no future-delivery promise. That
  corrected copy is the honest operator-facing disclosure. Do NOT
  re-flag in hierarchy/parity audits. Reopening requires explicit
  operator approval (schema + RLS-touching).

  **2026-05-20 supersession:** this location-only B2 note is no longer
  current for the active branch. Wage rows now carry hierarchy scope,
  Operator Web can save business/org-unit/location wage rows, and the
  continuation pass closed the live-read source-field and shadowed-row
  display gaps. Do not use the older "location-only by design" wording
  as audit authority for current Wage Authority code.

- **B1 — Forecast / weekly-plan / data-accuracy settings are
  location-scoped only; hierarchy/inherited values deliberately NOT
  done (accepted, document only).** Operator decision 2026-05-16: the
  four settings tables `weekly_plan_snapshots`, `forecast_contexts`,
  `data_accuracy_settings`, and `data_accuracy_service_period_settings`
  will NOT gain business/region/brand inheritance. Same posture as B2
  (wage): there is no small-footprint version — these are
  per-(operator, location) fact tables with no scope columns, so any
  fix inherently requires a schema migration + an RLS-policy rewrite
  (the same operator+location → operator-only shape B2 would need).
  Multi-location operators configure forecasts, locked plans, and
  data-accuracy settings per location by design — a forecast is built
  from a single restaurant's own history and traffic, so it is
  store-specific and there is nothing meaningful to inherit from a
  region or brand. This is a deliberate choice, not a gap — same
  posture as B2/B4/B5. The in-UI `HierarchyScopeNotice`
  `backendOnlyExplainer` copy on
  `lib/operator_web/screens/schedule_screen.dart` (and the embedded
  wage section on `data_accuracy_screen.dart`, which reuses
  `wage_authority_screen.dart`'s notice) was corrected 2026-05-16
  (this branch) to state "set per location by design" with no
  future-delivery promise — see the B2 bullet above for the wage
  surface and the matching schedule-surface fix. Do NOT re-flag in
  hierarchy/parity audits. Reopening requires explicit operator
  approval (schema + RLS-touching, same gate as B2).

## Code Health Residuals (post-Wave 5, 2026-05-08)

Consolidated from the 2026-05-06 audit's open residuals after five
remediation waves closed 52 of 64 findings. Historical context:
`docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md`.

### P1 — Audit anchor cron unpause

Operational change in Cloud Scheduler; not code. Worker code shipped
Wave 1 ([#254](https://github.com/SaidKhan005/forge-flow-demo/pull/254))
and the schema landed Wave 0
([#210](https://github.com/SaidKhan005/forge-flow-demo/pull/210)).
Action: flip the `audit-anchor-daily` cron from paused to active.
Compliance posture; the tamper-evidence story has an unbounded window
without it. The companion migration
`202605080700_audit_anchor_cron_unpause.sql` is already queued in the
P0 Production1 list above.

### P2 — `backfill_dispatch.dart:368` bare `catch (_)`

Same shape as the LB3 fix that closed Wave 5
([#364](https://github.com/SaidKhan005/forge-flow-demo/pull/364)) but
outside that lane's audit-cite scope. Apply the same pattern: typed
`on TimeoutException` / `on Exception` / `on Object` arms with a
structured-log reporter. Evidence:
`tool/integration_sync_worker/backfill_dispatch.dart:368`. Silent
failures in the backfill-dispatch loop until fixed.

### P2 — Two widget contract violations

Both are architecture-contract violations per CLAUDE.md "Architecture
Guardrails" (`Widgets do not own source-truth or service-period
bucketing`). No runtime failure today; contract decay if left.

- `lib/screens/shift_dashboard.dart:35-41` — widget owns timezone
  bootstrap (`_ensureTzInitialized`) plus service-period bucketing
  (`_servicePeriodSlivers`). Action: move timezone init into a
  service-layer initializer.
- `lib/screens/settings/settings_wage_authority_section.dart:52,57,73,76`
  — widget calls `SqliteRestaurantScopeRepository.instance` and
  `SqliteWageRoleRowRepository.instance` directly (`getActiveRestaurantId`
  at `:52`, `getRows` at `:57`, `upsertRow` at `:73`, `deleteRow` at
  `:76`). Action: route through a service that owns the SQLite calls.

### P2 — No common worker base

Every worker re-implements the claim loop, error catch, log, alert,
and metric emission. Action: extract a `WorkerBase` abstract class or
`WorkerLoopMixin` so new workers inherit the discipline rather than
copy/paste it. Reduces drift across `tool/integration_sync_worker/`,
`tool/audit_anchor/`, and the OAuth refresh worker.

### P2 — Two-slot key vs counter-store granularity mismatch

`usage_logs` keys are broader than the runtime counter-store
`(operator_id, location_id, tier_id, minute_bucket)` UNIQUE shape.
Two restaurants on the same operator can fight over the same
rate-limit bucket. Evidence:
`tool/advisor_proxy/advisor_proxy.dart:2418` (interface) and
`lib/infrastructure/persistence/postgres/advisor_proxy_usage_counter_store.dart:57`
(concrete store). Rate-limit fairness; not breaking anything today.

### P3 — `admin_routes.dart` and `advisor_proxy.dart` monolith debt

Structural; needs route-by-route migration plans for each. Reviewer-
time multiplier rather than a runtime bug.

- `lib/admin/admin_routes.dart` — 2,204 lines (audit cited ~1,906;
  +298 net since 2026-05-06).
- `tool/advisor_proxy/advisor_proxy.dart` — 18,871 lines (per A3.1 measurement 2026-05-13; audit cited 14,500; +4,371 net since 2026-05-06; bleed-stop ceiling 19,071 with 200-line headroom now in force via `tool/advisor_proxy_size_lint.dart`). Debt is reaccumulating faster than CODE_HEALTH lanes can clear it, but the A3.1 ratchet now prevents further routine growth.

Each warrants its own phase doc when the proxy split is sequenced.

### P3 — Duplicated abstractions

- Three adapter interfaces with identical method shapes.
- ~12 proxy gateways re-implementing `_postJson + idempotency-key`.
- Four trigger functions with the same body.

Architectural; needs collapsing as the proxy monolith is split rather
than as standalone lanes.

### P3 — SQLite repos as process-global singletons

Operator-switch leak partially closed by LB1's
`DatabaseHelper.forScope` factory; full repo-level scope-keying
remains a follow-up if a future incident exposes the gap. Latent; no
active incident.

### P3 — `vector_index_health` CLI placeholder

`tool/vector_index_health/main.dart:62` passes `activeVectors: 0`
(documented as `'CLI placeholder snapshot — no live DB query was
issued'`). The production reader at
`tool/advisor_proxy/health_producers/vector_producers.dart`
(`vectorActiveCountPerCorpusProducer`) queries Postgres correctly.
Action: replace the CLI placeholder with a Postgres-backed query, or
document the CLI as a non-production tool more loudly.

## Closeout — items closed since 2026-05-02 (kept for cross-reference)

Most items from the 2026-05-02 audit closed via the CODE_HEALTH
remediation wave (16 PRs) and the V1 closure dispatch (V1.A / V1.B).
Highlights:

- FK posture on closed `shift_records` → `ON DELETE SET NULL` (V1.B,
  migration `202605080000_…`). Closed historical truth survives
  profile mutation.
- Closed-row proxy timing-provenance gap (V1.A) — closed shift_records
  proxy SELECT/mapper now emits the timing triplet so mobile sync
  consumes Lane 2's resolver.
- Same-second prefix collision on three `202605061700_` migrations —
  resolved 2026-05-06 by renumbering data-accuracy entry to `…1701_…`.
- Phase 8 spine-bridge live wire-in dormancy (aggregator + projector
  unwired) — resolved by `8.first-connect-backfill-wire-in`
  (`canonical_fact_post_commit_projector.dart`).

Test parcels for MFA, postgres repo batch 1/batch 2, and the Phase 11b
retrieval assumption are archived to
`docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-02.md`.

## Audit additions — 2026-05-08 deep-dive sweep

A multi-agent audit on 2026-05-08 covered: time/RLS/Postgres-import
guardrails, demo-mode purity, widget-architecture guardrails,
placeholder/silent-error patterns, Phase 8 vendor closeout reality,
postgres-repo test coverage, worker abstraction, idempotency-pattern
coverage, and `OperatorScopedRepository<T>` primary-defense coverage.
Admin hierarchy lane was excluded (separate team).

Findings below are NEW or refine prior items. Confirmed-clean lanes
(time guardrails, raw `package:postgres` import lint, RLS wrapper
function presence, all 17 Phase 8 vendor adapters at literal
`lifecycle: VendorLifecycle.documented`) are not re-listed.

### P1 — `audit_logs_repository.dart` bypasses `OperatorScopedRepository` ✅ FIXED 2026-05-08 ([#424](https://github.com/SaidKhan005/forge-flow-demo/pull/424))

`lib/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart`
was a stateless writer that took `operatorId` as a caller-supplied
parameter — primary-defense bypass for the operator-scoped
`audit_logs` table.

Resolution: chose **Option B (defense-in-depth)** rather than
extending `OperatorScopedRepository`, because the writer's
atomic-with-business-write contract requires it to run inside the
caller's transaction (extending the base would have forced its own
`withTenant` wrapper and broken the same-commit-boundary semantics).
`writeRow` now reads `current_setting('app.operator_id', true)` from
the executor BEFORE binding any insert SQL and throws
`AuditLogsTenantMismatchError` when the parameter disagrees with the
GUC. When the GUC is unset (the `runAsSystem` admin path, where
`forge_admin BYPASSRLS` is the gate), the parameter is accepted —
preserving `auth_events_audit_repository.insertSystemEvent` and
`invited_user_activation_repository` paths that already use
`withSystem`. Verified all 10 caller sites already pass the matching
operator id; signature unchanged. Coverage:
`test/infrastructure/persistence/postgres/repositories/audit_logs_repository_test.dart`
(happy path, mismatch throws before insert, GUC-unset accepts param).

### P1 — 4 admin integration routes missing idempotency guard ✅ FIXED 2026-05-08

`tool/advisor_proxy/admin_integrations_routes.dart` writes did not
extract `Idempotency-Key` or consult the cross-tenant
`admin_request_idempotency` ledger despite the file header claiming
they did. Affected (now fixed):

- `POST /v1/admin/integrations/oauth/{vendor}/start`
- `POST /v1/admin/integrations/{vendor}/connect-key`
- `POST /v1/admin/integrations/{vendor}/test-connection`
- `POST /v1/admin/integrations/{vendor}/disconnect`

Resolution: `Phase80IntegrationRoutes` now accepts an optional
`AdminRequestIdempotencyStore` (wired in production via
`phase_8_production_binder.dart` from `productionBindings
.adminRequestIdempotencyStore`). Each of the 4 write routes now:
missing key → 400 `missing_idempotency_key`; duplicate key →
cached replay; new key → reserve → run → cache. Body-hash mismatch
on the same key → 409 `idempotency_key_conflict`. Coverage:
`test/tool/advisor_proxy/admin_integrations_idempotency_test.dart`.

### P1 — `advisor_proxy.dart:9105-9106` hardcoded prompt placeholders ⏸️ DEFERRED (AI freeze)

Moved to phase_11b plan freeze-thaw checklist (2026-05-08). See
`docs/archive/phases/phase_11b/phase_11b_advisor_ux_plan.md` "Freeze-thaw
pre-conditions (must close before unfreezing 11b)".

### P1 — Demo-mode banner promised by architecture but never wired ✅ FIXED 2026-05-08 ([#426](https://github.com/SaidKhan005/forge-flow-demo/pull/426) — slice `8.demo-mode-banner`)

`lib/services/integration/demo_mode_state.dart:12-15` (the file header)
explicitly promises: *"Operator-app UX: the demo-mode banner reads
runtime state from this surface, not from a config flag. Once the
operator's first vendor connection backfills successfully, the banner
clears without a redeploy."*

Reality: zero widgets in `lib/screens/` or `lib/widgets/` read `isDemo`
or `is_demo` at runtime. The Postgres `demo_mode_state` row + the
`DemoModeFlipPolicy` flip path are fully wired on the **write** side
(every Phase 8 vendor sink calls `flipToLive(...)` after first
backfill commit), but the **read** side ends at the gateway interface.
No UI consumes it.

Operator impact: an onboarded operator who hasn't connected a POS yet
has no on-screen indication they're looking at demo data. The
build-time `kDemoMode` badge (Carve-out #2) is irrelevant in a
production build, so the runtime "you're in demo" signal is invisible
to a real operator.

Action — slice `8.demo-mode-banner`:
- New `DemoModeBanner` widget (`lib/widgets/` or
  `lib/integrations/ui/`). Subscribes to active (operator, location,
  category) and reads `DemoModeStateGateway.readOrCreateDefault(...)`
  for each of the three categories (POS, Labor, Reservation).
- Renders one banner per category that's still `is_demo = true`
  (e.g. "Demo POS data — connect a POS to go live") with a CTA that
  deep-links to the vendor-connections screen.
- Auto-clears via the realtime spine when `DemoModeFlipPolicy` flips
  the row (Phase 10a infrastructure already broadcasts the change).
- AppShell mount point so it appears across the operator app, not just
  one screen.
- Walkthrough doc per HP #10.

This is a runtime-state read, not a `kDemoMode` carve-out; no contract
change needed.

Resolution: shipped via PR #426 with `lib/widgets/demo_mode_banner.dart`,
`lib/state/demo_mode_state_notifier.dart`, AppShell mount in
`lib/forge_flow_app.dart` (banner stack above the IndexedStack tab
body), `Provider<SyncProxyClient?>` exposure in
`lib/forge_flow_bootstrap.dart`, walkthrough at
`docs/archive/_walkthroughs/8.demo-mode-banner.md`, and 5 widget tests at
`test/widgets/demo_mode_banner_test.dart`. Two follow-ups punted:
(1) mobile-side vendor-connections route doesn't exist yet, so the
banner is informational-only; (2) the realtime invalidation path
uses a permissive `integrations.*` / `first_backfill.*` topic-prefix
match — tightening to a dedicated `demo_mode_state.flipped` topic
when the proxy starts publishing it would remove the redundant proxy
round-trip on unrelated integrations events.

### P1 — Two new widget→repo direct-call violations ✅ FIXED 2026-05-08 ([#419](https://github.com/SaidKhan005/forge-flow-demo/pull/419))

Both violate the CLAUDE.md "Architecture Guardrails" rule that widgets
do not own source-truth or service-period bucketing.

- `lib/screens/notifications_screen.dart:12,36-37` — widget imports
  `SqliteRestaurantScopeRepository` and calls
  `SqliteRestaurantScopeRepository.instance.getActiveRestaurantId()`
  inline.
- `lib/screens/schedule/schedule_forecast_notifier.dart:19,210-211` —
  notifier (widget-tree `ChangeNotifier`) does the same.

Action: route both through a service that owns the SQLite call. Same
shape as the known `settings_wage_authority_section.dart` violation in
the P2 list above.

Resolution: created `lib/services/restaurant_scope_service.dart` (thin
singleton wrapper with `overrideRepositoryForTest` / `resetForTest`
seams matching the `AppNotificationService` pattern). Updated both
widget files to use `RestaurantScopeService.instance.getActiveRestaurantId()`
and dropped the direct `SqliteRestaurantScopeRepository` imports.
Coverage: `test/services/restaurant_scope_service_test.dart`. The
P2 `settings_wage_authority_section.dart` follow-up uses the same
shape — defer to a separate slice.

### P2 — Undocumented `kDemoMode` reader-side carve-out ✅ FIXED 2026-05-08 ([#417](https://github.com/SaidKhan005/forge-flow-demo/pull/417) — option 1, blessed as Carve-out #3)

`lib/screens/settings_screen.dart:31,374,383` adds a third reader-side
`kDemoMode` branch (Data reset + Demo date sections gated on
`_kDemoMode`). The file has a local comment at lines 27-30 explaining
the design, but CLAUDE.md and `docs/contracts/demo_mode_contract.md`
list only two carve-outs (login button + data-status badge) — this one
is undocumented.

Action: pick one of:
1. Add this as Carve-out #3 in CLAUDE.md "Demo Mode" section and the
   contract doc, with the same `// kDemoMode carve-out: <reason>`
   marker the contract requires.
2. Refactor the two demo sections to render unconditionally and
   no-op when `DemoScope.restaurantId` is not the active scope.

HP #2 strict reading: option 2 is preferred; option 1 acknowledges the
existing UX intent.

**Resolution:** Option 1 chosen. `lib/screens/settings_screen.dart:31,374,383` carve-out is now documented as Carve-out #3 in `docs/contracts/demo_mode_contract.md` and in CLAUDE.md "Demo Mode" section (operator sign-off 2026-05-08). The two demo-only management sections (Data reset + Demo date) stay gated on `_kDemoMode` because they have no production analogue — rendering disabled UI in prod was assessed as higher risk than the documented carve-out.

### P2 — `audit_logs_repository.dart:368` style bare catches in advisor proxy ✅ PARTIAL ([#420](https://github.com/SaidKhan005/forge-flow-demo/pull/420) — 3 of 4 files closed; advisor_proxy 16 sites still open)

11 bare catches converted via PR #420 across `auth_session_notifier.dart`,
`tenant_transaction.dart`, and `package_postgres_executor.dart`.

**Still open:** the 16 bare catches in `tool/advisor_proxy/advisor_proxy.dart`.
Moved to `docs/phases/proxy_split/proxy_split_plan.md` "Pre-Split
Cleanup" (2026-05-08) — the monolith is too risky for a one-shot
agent and the split phase is the natural home.

### P3 — `docs/_execution/` retirement window opened 2026-05-12 ✅ FIRST SWEEP COMPLETE

**`docs/_execution/` retirement window opens 2026-05-12.** The bulk of
the 2026-05-03/-04/-05/-06 closeouts cross the 7-day-since-phase-close
threshold (per CLAUDE.md "Phase Doc Hygiene") on 2026-05-12. Sweep
candidates: ~25-30 files including the Phase 8 / 8R / 8.S / 10a / 11A
foundation / 11W proofs. Action: review each file, confirm the
underlying phase is closed, retire to `docs/archive/_execution/` or
`docs/archive/phases/` as appropriate.

**Resolution (2026-05-13):** First-pass sweep landed via PR #539 → `d1c2e167` (41 archive files deleted: 3 in `archive/internal/`, 38 in `archive/_execution/`, all closed-PR proofs / one-off snapshots / "CLOSED" dispatch plans, zero-reference verified per orchestrator sub-agent's per-file grep). Git history preserves all deleted content. Remaining `docs/_execution/` candidates (any still-active sprint plans that have since closed) get swept opportunistically as their phase docs retire.

### P3 — `lib/admin/admin_routes.dart` placeholder route flags

Lines `7, 90, 118, 147, 151, 166` track `.placeholder` boolean and
skip route-surface rendering when true. These mark Phase 11A
not-yet-shipped routes. No bug today; they correctly degrade. Flag
for clearing as Phase 11A.8/.9/.10 land.

### Confirmed-clean (re-verified 2026-05-08)

- All 17 Phase 8 vendor adapters carry literal
  `lifecycle: VendorLifecycle.documented` in their
  `@IntegrationAdapter()` annotation. OAuth refresh closures wired
  for the 11 OAuth vendors; the 6 non-OAuth (ADP/mTLS, Tock/static
  key, Push/bearer, OpenTable/internal, SevenRooms/transport,
  Agendrix/static key) intentionally have no closure. Test coverage:
  4-6 unit tests per vendor.
- No operator-scoped Postgres fact table uses
  `TIMESTAMP WITHOUT TIME ZONE`.
- No `package:postgres` imports outside
  `lib/infrastructure/persistence/postgres/` or `tool/advisor_proxy/`.
- All RLS policies (post-`202604280001`) route through the four
  wrapper functions `app_current_operator()`,
  `app_current_location()`, `app_current_actor_user()`,
  `app_acting_as_operator()` (all `STABLE LEAKPROOF PARALLEL SAFE`).
- `tool/rls_policy_lint.dart` exists (251 LOC) with allowlist; the
  prior contract note implying it was missing is stale.
- `proxy_requests.idempotency_key` UNIQUE constraint present at
  `db/migrations/202604250005_advisor_cloud_foundation.sql:198`.
- No new `demo_*` SQLite or Postgres tables (only the documented
  `demo_mode_state` Postgres table).
- Operator-web `UnsupportedError` calls in
  `firebase_operator_web_auth_source.dart` /
  `operator_web_auth_source.dart` are intentional (password reset
  flows are handled by Firebase action links by design), NOT gaps.

## Wave bugs surfaced 2026-05-13 by local apply (P1 — would block Production1)

Surfaced while applying the wave's 125 migrations against a fresh local
Postgres for happy-state demo validation (see
[`runbooks/local_full_stack_setup_runbook.md`](../runbooks/local_full_stack_setup_runbook.md)).
Both are CI-dark-era misses — CI was gated to `workflow_dispatch` only since
2026-05-12, so neither was caught at PR time. Each would fail on staging or
Production1 with the same error.

### W-1 — Legacy fact tables referenced but never created

**Migrations affected** (5):

- `db/migrations/202605061700_phase_8_timing_provenance_shift_records.sql`
  (`shift_records`)
- `db/migrations/202605061701_phase_8_data_accuracy_service_period_settings.sql`
  (`shift_records`)
- `db/migrations/202605080000_phase_8_timing_provenance_fk_posture.sql`
  (`shift_records`)
- `db/migrations/202605080600_phase_8_idempotency_location_id_rekey.sql`
  (`shift_records`, `cover_facts`, `labor_punches`, `reservation_facts`)

**Failure mode:** `ERROR: relation "public.shift_records" does not exist`
(and the same shape for the other three tables) when the migration runs
`ALTER TABLE` or `CREATE INDEX`.

**Root cause:** Phase 8 framework writes vendor data into the existing SQLite
fact tables per HP #1 (`Phase 8 = pure transport swap — vendor connectors
write existing SQLite tables only; cleanup is 7.57/7.58/7.61`). The Phase 8
Postgres migrations were authored assuming Postgres-side counterparts exist,
but no migration ever runs `CREATE TABLE public.shift_records` (or the
three sibling tables). They're SQLite-only today.

**Fix path:**

1. A new Phase 8 base-schema migration must `CREATE TABLE public.shift_records (...)`,
   `public.cover_facts (...)`, `public.labor_punches (...)`,
   `public.reservation_facts (...)` BEFORE any subsequent migration alters
   them. Schema should match the columns SQLite uses today (at minimum:
   `operator_id uuid not null`, `location_id uuid not null`, `vendor_id text`,
   `vendor_entity_id text`, `business_date date`, plus the fact-specific
   columns).
2. Lex-order: the new migration must sort before
   `202605061700_phase_8_timing_provenance_shift_records.sql`. Suggested name:
   `db/migrations/202605061650_phase_8_legacy_fact_tables_postgres_create.sql`.
3. Operator-gate: schema-touching, so the slice prompt MUST be
   `[operator-approval-required]`.

**Local workaround in place:** minimal stubs (no fact-shape columns; just
the columns the migrations reference) — see step 6 of the local setup
runbook. The stubs let migrations succeed; they stay empty because demo
writes go to SQLite per HP #1.

### W-2 — `partman_maintenance_hourly_cron.sql` dollar-quote nesting

**Migration:** `db/migrations/202605081100_partman_maintenance_hourly_cron.sql`

**Failure mode:** `psql: ERROR: syntax error at or near "select" ...
LINE 16: '$$select public.run_maintenance(p_analyze := true)$$, ...`

**Root cause:** the migration wraps a `raise notice` block inside `do $$ ...
$$;`. The notice text contains `$$select public.run_maintenance(p_analyze := true)$$`
inside a single-quoted string. PostgreSQL's dollar-quote lexer does NOT
respect single-quote string boundaries — it sees the inner `$$` and
terminates the outer `do $$` block early. The rest of the body becomes
top-level statements that fail to parse.

**Fix path:** change the outer block delimiter to a unique tag, e.g.:

```sql
do $partman$
declare ...
begin
  ...
end
$partman$;
```

Single-character edit (line 50 + line 106 of the migration). No
behavioral change.

**Local workaround in place:** `sed` patch into a temp file at apply
time — see step 8 of the local setup runbook.

**Impact:** the unpatched migration will fail the very first time it
runs on staging or Production1 (already in the pending apply queue per
`runbooks/phase_9_production1_migration_apply_runbook.md`). Must be
fixed in-tree before the Production1 apply.

## Advisory-lock posture — reconciled 2026-05-13

Captured 2026-05-13 closing the C-12 wave closeout audit's finding O-5
(`docs/archive/_audits/post_codex_wave/c_12_lane_c_closeout_audit.md`) and the
Migrations + Schema dimension's finding 5
(`docs/archive/_audits/post_codex_wave/wave_audit_migrations_schema.md`).

**The finding:** V1 lean-cut #2 (project memory, locked 2026-05-03) listed
"OAuth refresh advisory lock" under *"What got pulled back"* with the trim
verdict *"Drop. One cron instance + low frequency = zero contention at V1
scale."* But two wave-scope migrations restored advisory-lock infrastructure:

- `db/migrations/202605070200_audit_anchor_advisory_lock_infra.sql`
- `db/migrations/202605080900_oauth_refresh_advisory_lock.sql`

And `lib/services/integration/oauth_refresh_cron.dart` carries the comment
*"pg_advisory_lock is now RESTORED per J4 race fix"*. The audit asked: memory
needs updating OR migrations need reverting.

**Reconciliation chosen — migrations stay, memory updated.** The J4
race-condition investigation (referenced in `oauth_refresh_cron.dart`) found
that some vendor token endpoints (Squarespace, certain Clover environments)
auto-revoke the earlier token when a second refresh fires before the first
commits. Two Cloud Run pods hitting the same near-expiry window can race; the
advisory lock serialises concurrent refresh per `(operator_id, vendor_id)`.
Transaction-scoped — releases on commit / rollback. The lean-cut's "one cron
instance" assumption did not survive contact with multi-pod Cloud Run deploys.
The audit-anchor advisory-lock infra is the same root cause shape (multi-pod
serialisation) for the daily anchor publisher.

**Memory doc updated** at `~/.claude/projects/.../memory/project_v1_lean_cut_2_2026_05_03.md`
(user-private, outside the repo). The lean-cut #2 entry now carries an
inline *"RESTORED 2026-05-13"* annotation pointing at a new
*"What got restored (after closer review)"* table that names both
restorations + their authority anchors (the migration files + the code
comment in `oauth_refresh_cron.dart`).

**No further code action.** Both migrations stay in the apply queue for
Production1; the runtime comment in `oauth_refresh_cron.dart` is the
authoritative rationale; the lean-cut principle ("don't reach for advisory
locks speculatively") still holds for new code — these two restorations
have concrete contention evidence + migration-resident rationale.

## Refactor phase scope (queued from 2026-05-13 post-Codex wave closeout)

Captured 2026-05-13 from the C-12 wave closeout audit
(`docs/archive/_audits/post_codex_wave/c_12_lane_c_closeout_audit.md`). Both
items are governance-level decisions plus extraction work that the
post-Codex wave touched but did not resolve. The operator scoped them
into an upcoming refactor phase rather than a standalone slice; this
section is the holding pen until that phase opens.

### R-1 — Operator-web ceiling lint + `my_account_screen.dart` decomposition

**Source:** `wave_audit_operator_web_admin_ux.md` finding F-OW-1; closeout
M-2.

`lib/operator_web/screens/my_account_screen.dart` reached 2,051 LoC during
the wave (PR #624 set a soft ceiling of 1,665; C-7 PR #636 then added to it
without enforcement). The ceiling exists only in a per-PR audit doc, not in
any lint or governance doc, and the screen is becoming the operator-web
equivalent of `advisor_proxy.dart` — a god-screen accumulating MFA,
sessions, profile, and security panes that are conceptually separate.

Refactor phase work:

1. Codify the operator-web ceiling in `tool/operator_web_size_lint.dart`,
   mirroring `tool/advisor_proxy_size_lint.dart` shape (single max-lines
   constant per target file, fails build above ceiling).
2. Decompose `my_account_screen.dart` into sibling files
   (`my_account_security_pane.dart`, `my_account_mfa_pane.dart`,
   `my_account_sessions_pane.dart`, `my_account_profile_pane.dart`).
3. Keep the parent screen as a thin tab-host that mounts the panes.

Out of scope: any behavior change. Pure structural extraction + lint
codification.

### R-2 — `advisor_proxy.dart` bleed-stop discipline + helper extraction

**Source:** `wave_audit_proxy_bleed_stop.md` finding W-1; closeout M-3.

The post-Codex wave raised `kAdvisorProxyMaxLines` three times
(19,071 → 19,600 → 19,700 → 19,900) in five hours of wall time, a
cumulative +941 LoC growth on the monolith. The lint's authoritative
docstring at `tool/advisor_proxy_size_lint.dart:64-80` says explicitly
*"the monolith MUST shrink, not grow"* — the wave ratcheted the wrong
way three times. CI was dark, so each raise landed unchallenged.

The proximate cause of three of those raises (B10.1, B2.1, C-4) is the
**hybrid sibling pattern** where the router class lives in a sibling
file but the dispatcher block at `routeRequest` still carries 60-120
lines of local-state setup (`_resolveOperatorContextOrWrite`,
`_readJsonBody`, `_writeJson`, `_maybeWriteDependencyTimeout`,
`_logProxyUnhandled`, `authGuard`, `businessScopeGateway`). The
helpers are file-local to `advisor_proxy.dart`, so dispatcher blocks
cannot move out without first promoting those helpers to sibling
status.

Refactor phase work:

1. Promote the request-envelope helpers to a new
   `tool/advisor_proxy/route_helpers.dart` sibling — exported, file-
   private elements lifted as module-private with explicit `@visibleForTesting`
   where tests already depend on them.
2. Migrate the wave's three hybrid dispatchers (B2.1, B11.2, C-4) to
   the Pattern A pre-check shape (`router.tryHandle(HttpRequest)`
   returning `Future<bool>`), moving their dispatcher blocks fully
   out of `routeRequest`.
3. Lower `kAdvisorProxyMaxLines` to match the new monolith size with
   ~200 lines of forward headroom (re-instate ratchet discipline).
4. Codify in CLAUDE.md or a doctrine doc: **ceiling raises require
   explicit operator approval like auth-critical / RLS-touching /
   schema-touching / proxy-touching slices.** Without operator gate,
   the doctrine's "must shrink" intent has no enforcement.

Out of scope: route-logic changes; per-route auth posture changes; any
new routes. Pure structural extraction + discipline restoration.

### R-3 — Bundle: refactor phase opens after both above are scoped

Sequencing note: R-1 and R-2 are independent (operator-web vs proxy)
but both compete for "structural extraction without behavior change"
attention. The refactor phase doc (TBD location) will sequence them
when it opens. Operator gate on the phase opening.

## Closeout — Phase 8 plug-and-play V1 onboarding (2026-05-07)

End-to-end V1 plug-and-play onboarding for all 17 vendors landed via
9 PRs (#280 to #301). Full per-PR resolution notes archived to
`docs/archive/POST_HARDENING_FOLLOWUPS_RESOLVED_2026-05-07_phase_8_plug_and_play.md`.

Operations work remaining (P0 above, plus Cloud Run env + partner
portal redirect URI registration) gates each vendor's `*.live.sandbox`
slice firing; engineering closure is unblocked.

## Pressure-preview-v1 sprint findings (2026-05-09)

The `pressure.preview.v1` sprint (Phases 1-3, PRs #428-#452) drove
verbatim vendor payload corpora through every infrastructure layer
against the preview proxy and recorded findings to feed the Phase 6
Postgres test backfill that closes the P2 coverage gap above.

Top-line severity counts: **1 P0** (schema-info leak via webhook
signature-verifier ordering bug — separate triage branch
`claude/8.gap-1.missing-webhook-signature-verifiers`), **5 P1**
(Square/LSK silent timestamp coercion; Humanity time-off-as-shift;
ADP/OpenTable/SevenRooms missing OAuth refresh closures; Humanity
inverse closure mismatch; preview-env Postgres pool exhaustion),
**6 P2** (auth-mode doc mismatches × 4; preview-env vendor-capability
registry gap × 6 vendors; preview-env schema gaps), **~25 P3** (vendor
partner-portal sourcing-gap escalation list).

Phase 6 first-wave order: `connector_backfill_job_repository.dart` (extend
existing test with Phase 3B contracts), `provider_credentials_repository.dart`
(extend with Phase 3C contracts), `weekly_plan_snapshot_repository.dart`
(new test grounded in Phase 1 fixtures), `business_timing_profiles_repository.dart`
(new test pinning rollover-hour + IANA contract every adapter depends on).

Full findings: `docs/archive/_execution/2026-05-08_pressure_preview_findings.md`.

### Closeout status (2026-05-09 end-of-day)

P0 — webhook signature ordering + leak: **closed** (PR #456 — signing-
secret cache + 9 leak sites sanitized).

P1 — Square + LSK silent timestamp coercion: **closed** (PR #464 —
strict-Z parser refuses missing-offset inputs).

P1 — Humanity time-off-as-shift: **closed** (PR #464 —
`HumanityShiftDto.tryFromMap` returns null on `type=time_off`).

P1 — ADP / OpenTable refresh closures: **closed** (PR #465 — both
wired via `grant_type=refresh_token` against the per-tenant
`client_id` / `client_secret` already on metadata).

P1 — Humanity inverse closure mismatch: **closed** (PR #455 — closure
removed; adapter `keyPaste` declaration agrees with the worker's no-
closure registry entry).

P1 — SevenRooms refresh wiring: **closed by THIS PR** — bridge now
persists `client_secret` + `venue_id` on metadata,
`makeSevenRoomsOauthRefreshClosure` wires the `client_credentials`
grant to `POST /2_2/auth`; registry moves from 12-wired/5-unsupported
to 13-wired/4-unsupported. Legacy rows (pre-2026-05-09 persistence)
surface a reconnect prompt via the standard `missing_credential`
path. Detail in `docs/integrations/sevenrooms/oauth_shape.md`
"Refresh handling" section.

P1 — preview-env Postgres pool exhaustion: **closed** by commit
`7c85e5a4` (PF4 A4.2 hardening — `POSTGRES_POOL_MAX_CONNECTIONS=20`,
documented in `runbooks/cloud_run_env_vars.md`). Historical
breadcrumb + future-tuning steps in
`runbooks/preview_env_infra_findings_runbook.md` Finding 1.

P2 — auth-mode doc mismatches (Oracle Simphony, ADP, OpenTable,
SevenRooms, Agendrix): **closed** (PR #455 — `oauth_shape.md` sweep
for all five vendors).

P2 — preview-env vendor-capability registry gap (6 vendors return
`unknownVendor`): **open** — needs the 6 vendor app-credential
bundles provisioned into preview Secret Manager and a Cloud Run
revision redeploy so the proxy binder picks them up. Operator-led.
Full spec — required env var names, provisioning sequence,
verification — in `runbooks/preview_env_infra_findings_runbook.md`
Finding 2.

P2 — preview-env schema gaps (`relation "public.vendor_credentials"
does not exist`, `column op.rollover_hour does not exist`): **open**
— part of the "P0 — Production1 Migration Apply Gap" queue above;
applying those migrations to preview also closes this finding.
Operator-led. Migration filenames, downstream consumers, and
verification gates in
`runbooks/preview_env_infra_findings_runbook.md` Finding 3.

P3 — vendor partner-portal sourcing escalation list (~25 items):
**open** by design — requires vendor partner-program access; tracked
per-vendor in the partner-portal escalation rows of the archived
findings doc.

Engineering side of the sprint is closed. Remaining open items are
all operator-led (preview Cloud Run config + pending migration apply
+ partner-portal escalations).


## End-to-end pressure audit (2026-05-19) — follow-ups

Spawned by `docs/_audits/code_health/end_to_end_pressure_audit_2026_05_19.md`.
Findings A and B were landed by the same audit author in the same
session (see commits on `claude/audit-fix-waves` → upstream PR).
The remaining findings are queued here, in no particular order,
each with the audit-finding letter referenced so the audit doc
remains the single source of truth.

### ~~P2~~ RESOLVED — Audit Finding E: SevenRooms credential bridge metadata persistence

**Status:** RESOLVED in PR #1067 (2026-05-19).

Root cause turned out to be a test-code bug, not a vendor/OAuth-refresh
issue. The test walks every bound parameter for the 3 identifier
substrings and was falling through to `jsonEncode` on non-String
values; one of those values was a `DateTime` (e.g. `expires_at`), which
`jsonEncode` cannot serialize ("Converting object to an encodable
object failed: Instance of 'DateTime'"). Replaced with `value.toString()`
which handles DateTime, Map, primitives uniformly.

**File:** `test/integrations/reservation/sevenrooms_credential_bridge_test.dart`
**Verify (now green):** `flutter test test/integrations/reservation/sevenrooms_credential_bridge_test.dart` → 3/3 ✅.

### ~~P3~~ RESOLVED — Audit Finding F: Advisor proxy /healthz contract drift

**Status:** RESOLVED in PR #1067 (2026-05-19).

Root cause turned out to be a test-harness setup gap, not a `/healthz`
contract drift. `TestWidgetsFlutterBinding` overrides `HttpOverrides.global`
so every `HttpClient()` request returns HTTP 400 with no real network
call — the test's in-process `HttpServer` was never being hit. Added a
`_withRealHttpClient` helper that temporarily nulls `HttpOverrides.global`
for the duration of the test body and restores it in `finally`
(`HttpOverrides.runZoned` + `HttpClient(context:)` recurses infinitely;
nulling the global is the stable pattern). The production `/healthz`
shape, status mapping, and path-prefix behaviour are all unchanged.

**File:** `test/services/advisor/advisor_model_config_service_test.dart`
**Verify (now green):** `flutter test test/services/advisor/advisor_model_config_service_test.dart` → 6/6 ✅.

### ~~P2~~ RESOLVED — Audit Finding C re-diagnosed (multi-location demo seed)

**Status:** RESOLVED in PR #1067 (2026-05-19). Operator decision:
re-pin tests to 5.

Confirmed intentional via git history: R6 ("Choose Star Shifts: 4-period
demo operator", PR #929) added `demo_restaurant_four_period` — the
"Barrio Legado: Four-Period" proof restaurant — which is intentionally
NOT a `DemoScope.locations` member (per-location replay/operational
loops iterate `DemoScope.locations` and skip it) but IS written into
the standard `restaurant_locations` table. The R6 author flagged this
would break "≥3 hard-asserted location-set tests".

Re-pin shape: tests counting rows in `restaurant_locations` (or the
scope-drawer that reads it) bumped from 4 → 5 with the four_period id
in the expected set. Tests counting `DemoScope.locations` stay at 4
(four_period sits outside the §2c hierarchy). For per-table writer
isolation: `shift_records` expected to include four_period (R6 seeds
shift-level rows for the proof), `week_records` expected NOT to
(R6 doesn't emit weekly rollups).

**Files (now green):**
- `test/per_daypart_v1_demo_slice_a_hierarchy_test.dart`
- `test/per_daypart_v1_demo_seed_per_location_data_test.dart`
- `test/state/restaurant_scope_notifier_test.dart`

Note: `per_daypart_v1_demo_seed_perloc_current_week_open_shift_test.dart`
was in the audit's original Finding C file list, but on re-check its
remaining failure is a date-arithmetic issue (`2026-W21` vs `2026-W20`),
not a count mismatch — see Finding D below for the actual class.

**Verify (now green):** `flutter test test/per_daypart_v1_demo_slice_a_hierarchy_test.dart test/per_daypart_v1_demo_seed_per_location_data_test.dart test/state/restaurant_scope_notifier_test.dart` → 30/30 ✅.

### ~~P2~~ RESOLVED — Audit Finding D re-diagnosed (NOT mock-replay drift)

**Status:** RESOLVED in PR #1070 (2026-05-20).

On per-test investigation, all 6 turned out to be test-side updates
needed to track 3 distinct production contract evolutions — no
production code changes required.

**Root causes (not "+1 day" as the audit guessed):**

1. **`ClosedTruthEligibility` is now the authority for planning
   math.** Production filters the latest-closed lookup AND the 60d/21d
   baseline cover windows through this filter — `appLocalCutoffFallback`
   shifts whose `businessDate` is not strictly less than
   `currentOperationalBusinessDate` are excluded as not-yet-finalized.
   Anchor lands at `latestClosed - 1` and the same exclusion drops
   today's covers from the baseline sum. The audit's "latestClosed + 1
   day" theory was the inverse of the real shape.
2. **Deterministic target-profile-version ids + `ConflictAlgorithm.ignore`.**
   `closeShift` re-targets the existing version row instead of minting
   a new one when a cycle already exists; the version-row-count-strictly-
   increased precondition is no longer reachable.
3. **Locked weekly snapshot is the shift dashboard's plan source.**
   `getShiftDashboard` reads from `getExistingCurrentLockedWeeklyPlan`
   (snapshot frozen at week start), NOT the live recomputed plan.

**Per-test fixes:**

- `business_date_authority_service_test.dart` (B) and
  `demand_forecast_context_service_test.dart` (B): clear
  `mock_replay_state` AND `open_shift_snapshots` so the planning anchor
  takes the simple "no operational date → latestClosed" short-circuit
  (the eligibility-filter path is covered by dedicated tests).
- `demand_forecast_context_service_test.dart` (C, E): mirror
  `ClosedTruthEligibility.filter` when computing the expected baseline
  cover total so test and production count the same set.
- `history_teaching_analyzer_test.dart`: late-night service-period
  applicability narrowed to Fri-Sat only (Slice 1.5); Fri Late Night
  dropped out of the runner-up tie. Re-pinned the second
  benchmarkDaypart to `Mon Dinner` (new alphabetical tie winner) and
  updated the header narrative.
- `metadata_timestamp_normalization_test.dart`: stale "row count
  growth" assertion rewritten to verify UTC `created_at` on the
  specific version row the closed shift locked onto (strictly stronger
  guarantee than "some new row appeared").
- `schedule_plan_read_service_test.dart` (E): asserts agreement with
  the locked weekly plan, not the live one.
- `target_state_alignment_test.dart` (E): added `_satLunch` +
  `_sunLunch` close inputs (the 16-of-16 weekly completion gate needs
  all 7 projected slots closed, not 5), and cleared
  `open_shift_snapshots` so the eligibility filter passes the W13
  closes through to the upsert.

**Verify (now green):** 117/117 across the 6 files.

### ~~P2~~ RESOLVED (partial) — Audit Finding G investigated; split into 3 classes

**Status:** RESOLVED in PR #1067 (2026-05-19) for the actually-leaky
files. The audit framed all 5 files as one class ("test-state pollution
requires per-file teardown"); investigation showed three distinct
failure classes that do NOT all share a fix.

**Class 1 — Real within-file pollution (FIXED):**

- `test/restaurant_timing_config_repository_test.dart`: sibling tests
  `saveTimingConfig` with mutated `applicableDays` (e.g. lunch
  `[1,2,3,4,5]`). `reseedDemo()` uses `ConflictAlgorithm.ignore`, so
  the canonical demo values never came back. Fix: setUp now
  `delete('restaurant_timing_configs')` before reseed.
- `test/target_cycle_service_test.dart`: `BaselineData` has
  process-static state (`recommendationSignals`, `_runtimeRecords`)
  and group-A's setUp wipes `target_cycles` while group-P expects
  `getOrCreateActiveCycle` to write fresh signals. Fix: top-level
  setUp now clears both `BaselineData` statics + always runs
  `clearCycleBackedState()` (now extended to include
  `target_cycle_dayparts`).

Both now green under `flutter test --test-randomize-ordering-seed=12345`
→ 98/98 ✅.

**Class 2 — Parallel-mode concurrency artifact (NOT pollution):**

- `test/screens/variance/variance_learn_tab_depth_test.dart`: passes
  in isolation (7/7), passes alongside any single Finding G file in
  default parallel mode, passes under `flutter test --concurrency=1`
  with all 5 files. Only fails when all 5 files run together under
  default parallel concurrency. This is a Flutter test runner
  scheduling artifact, not singleton state leaking — no per-file
  teardown will fix it.

**Class 3 — Real isolated failure (Finding D territory):**

- `test/per_daypart_v1_demo_seed_perloc_current_week_open_shift_test.dart`:
  fails in isolation with `Expected '2026-W21' / Actual '2026-W20'` —
  off-by-one week in the cold-boot today injection. Belongs with
  Finding D's date-arithmetic cluster, not Finding G.

**Class 4 — Passes in all observed orderings:**

- `test/shift_service_close_shift_test.dart`: not actually flaky under
  any combination tested in this round.

**Owner for the remaining real perloc failure:** per-daypart V1 /
business-date lane (see Finding D); not test-infrastructure.

### ~~P2~~ RESOLVED — Audit Finding A residual (7 spine smoke scenarios)

**Status:** RESOLVED in PR #1076 (2026-05-20). Operator product call
2026-05-20: "manual override wins" — confirmed already the actual
production behaviour at Stage 1 of the 4-way wage resolver.

All 7 scenarios were test-side updates needed to track the same
contract evolutions Finding D revealed, plus one SQL-matcher drift.
No production code changes.

**1 plumbing fix unblocks 2 scenarios:**

- `_SmokeFakeTransaction.query` matcher widened from
  `'from data_accuracy_settings'` to `'data_accuracy_settings'`.
  Production queries `from public.effective_data_accuracy_settings_v`
  now; the substring match split on `public.` + `effective_` and
  never hit the seeded fixture row. Result: the aggregator fell back
  to its default `wage_source = vendor` and the manual_mix +
  operator-manual-entry-per-daypart scenarios both failed silently.

**Per-daypart V1 Slice 1.5 production-shape re-pins (4 scenarios):**

- Humanity per-position + 7shifts perEmployeeWithDollars: BOH dollars
  pro-rate by per-period overlap. The cook's 5h shift (18:00-23:00
  local) only overlaps dinner (17:00-22:00 local) for 4h. Expected
  re-pinned from `5 × rate` to `4 × rate` ($96, not $120).
- Trio chain BOH hours/dollars: same root cause — re-pinned 6 → 5h
  and `6 × $20` → `5 × $20` = $100.
- Trio chain invalidation count: relaxed strict `== 1` to
  `greaterThanOrEqualTo(1)`. The bus now legitimately fires multiple
  times per sync (shift_record writes + timing-config sync +
  wage-role-rows + first-backfill-status per the spine-bridge.3
  contract). Preserves the "writes cause invalidation" guarantee
  without over-pinning the aux-pull count.

**Test-side path-selection gap (2 scenarios):**

- Pattern A Square + Libro + walk-in-count and Tock without seated_at:
  a non-null `walkInOverride` parameter alone does NOT switch the
  covers-resolver path; the operator's effective
  `covers_source_per_service_period` setting must name Pattern A.
  Added the `data_accuracy_settings` row that names
  `reservation_plus_walkin` for dinner in both tests.

**Test isolation hygiene:**

- Added a scope-limited `db.delete('shift_records', where:
  restaurant_id + week_id)` at the top of the trio test. The SQLite
  DB is a process singleton (file-backed via `sqflite_common_ffi`);
  rapid local re-runs in the same shell otherwise accumulate prior
  2026-W18 rows that break the test's `hasLength(1)` read-back. The
  delete is scoped to the trio's specific (restaurant, week) pair so
  the demo seed's historical weeks are untouched.

**Verify (now green):** `flutter test test/_execution/spine_bridge_v2_smoke_test.dart`
→ 14/14 ✅. Random ordering also passes.

## P2 — Code-hardening pressure-coverage v2: DB-backed concurrency (2026-05-21)

Spawned by `docs/_audits/code_health/code_hardening_plan_2026_05_21.md`
§2.3 + backlog item #3. Wave 2 (PRs #1143 + #1144) landed the
**in-memory** pressure for seven previously-unaudited seams (auth
lockout window math, RLS wrapper migration-shape posture, idempotency
key semantics, operator-scoped isolation posture, audit-chain hash
tamper-evidence, webhook signature failure handling, cold-boot timing).

Operator decision 2026-05-20: ship only pressure that genuinely runs
today; the reserved `fail('not yet implemented')` DB stubs were
stripped. The wave-2 pressure-test `_summary.md` files point here for
the deferred portion.

**Deferred to a single infra-gated slice (needs a live Postgres test
environment — same blocker as the 64 env-gated `rls_isolation_p2`
tests):**

- `p3d_rls_multi_tenant_concurrent_reads` — the 4 RLS wrapper functions
  (`app_current_operator()` etc.) under rapid concurrent tenant-context
  flips against real rows (today: migration-shape posture only).
- `p3d_idempotency_store_concurrent_retry` — `proxy_requests`,
  `handoff_codes`, `auth_step_up_challenges`, `mobile_push_outbox`
  UNIQUE-constraint behaviour under N=100 concurrent same-key retries.
- `p3d_operator_scoped_isolation_under_concurrency` —
  `OperatorScopedRepository.withTenant` isolation under 50+ concurrent
  operators writing the same table.
- `p3d_audit_chain_hash_storm` — N=1000 concurrent `audit_logs` INSERTs
  against a real partition, asserting `verifyChain` output post-storm
  (today: in-memory hasher tamper-evidence is fully proven).

**Lock until then:** the env-gate hooks in each test file (e.g.
`FF_RUN_PRESSURE_P3D_RLS`) are removed for now; the future slice
re-introduces them wired to a live Postgres harness. Until that
environment exists, the DB-concurrency invariants are covered only by
the existing single-threaded repository + `rls_isolation_p2` suites,
not under pressure.

**Authority:** `docs/_audits/code_health/code_hardening_plan_2026_05_21.md`
§2.3 + §2.4 (tooling gaps) + this entry.

## P3 — CLOSED 2026-05-26 - Remove orphaned `AuditLogHierarchyFilterPane` widget (operator-web)

Status: closed by the 2026-05-26 full-system audit fix pass. The orphaned
widget file was removed and the stale `audit_log_screen.dart` comment now
points to the shell-owned scope selector.

Surfaced by the full-suite test-health audit (2026-05-22). The
operator-web audit-log scope UX was reworked so the screen reads the
selected scope from the **Operator Web shell's top dropdown** "instead
of rendering a second hierarchy picker inside the page"
(`lib/operator_web/screens/audit_log_screen.dart:138-141`). That rework
(commits `2a4a6254` "Operator Web Wave 5 audit log UX consistency" /
`25d6415b` "simplify operator scope UX") **unwired** the standalone
in-page picker but left the widget file behind.

**Removed dead code (operator-web — Codex lane):**

- `lib/operator_web/screens/audit_log_hierarchy_filter_pane.dart`
  (~693 lines).
- Stale doc comment at `audit_log_screen.dart:123-124` now points to the
  shell-owned scope selector instead of the removed in-page picker.

**Already done (this audit, test-only, PR `claude/fix-stale-operator-web-tests`):**
The widget's only test, `test/operator_web/screens/
audit_log_hierarchy_filter_pane_test.dart` (5 cases that pinned the
unwired pane), was **deleted** — it could never pass again without
resurrecting dead code. The live screen keeps coverage via
`audit_log_screen_test.dart` + `audit_log_integrity_badge_test.dart`.

**Residual risk (low):** the shell dropdown + main list (filters, actor
labels, run) appear to fully replace the pane's capabilities, but this
audit did not exhaustively prove every pane affordance migrated. Confirm
during widget removal. If a capability is missing, this becomes a
re-wire (regression) rather than a delete.

**Authority:** test-health audit 2026-05-22 + this entry.
