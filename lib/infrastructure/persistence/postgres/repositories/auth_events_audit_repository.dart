// Phase 9 live-closeout B20 - AuthEventsAuditRepository.
//
// Append-only writer for `auth_events_audit`. The 9.0 schema:
//
//   event_id uuid pk default gen_random_uuid()
//   actor_user_id uuid null
//   actor_kind text not null default 'user'
//   actor_service_principal_id uuid null
//   target_user_id uuid null
//   operator_id uuid null
//   location_id uuid null
//   event_type text not null
//   event_payload jsonb default '{}'
//   ip inet null
//   user_agent text null
//   geo_country char(2) null
//   request_id uuid null
//   occurred_at timestamptz default now()
//   schema_version int default 1
//
// `auth_events_audit` is append-only at the grant shape:
// `202604260001_auth_rls_service_role_grants.sql` GRANTs INSERT and
// SELECT to both `service_role` and `forge_admin`, then explicitly
// REVOKEs UPDATE and DELETE from both. SET LOCAL ROLE forge_admin
// bypasses RLS but does NOT bypass table privileges, so the proxy
// runtime physically cannot UPDATE these rows even with the admin
// role.
//
// Audit-fix 2026-04-27: the previous draft of this repository
// exposed `redactForUser` as a normal admin call, which would have
// errored at runtime under the locked grant shape. GDPR Art. 17
// erasure of audit-log fields is real, but it must run as an
// explicit, narrow break-glass DBA path (temporary GRANT UPDATE,
// run the SQL, REVOKE UPDATE) documented in
// `runbooks/gdpr_erasure_runbook.md`. `redactForUser` therefore
// throws a [StateError] pointing at the runbook so the operational
// story stays honest and the append-only posture stays intact.
//
// The proxy uses this repository alongside the existing
// `BruteForceTelemetrySink` (Phase 9.5) — telemetry sink writes
// the same table; the repository surface here is the
// lifecycle-event-specific writer that the user-lifecycle services
// depend on.

import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

class AuthEventsAuditRepository extends OperatorScopedRepository {
  AuthEventsAuditRepository(super.tenantWrapper);

  /// INSERT a single audit row. Returns the freshly generated
  /// `event_id`. Caller passes whichever combination of actor /
  /// target / operator / location it has — the schema permits any of
  /// them to be null (e.g. system-issued events have no actor).
  Future<String> insertEvent({
    required String operatorId,
    required String locationId,
    required String eventType,
    String? actorUserId,
    String actorKind = 'user',
    String? actorServicePrincipalId,
    String? targetUserId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'insert into auth_events_audit ('
        'actor_user_id, actor_kind, actor_service_principal_id, '
        'target_user_id, operator_id, location_id, '
        'event_type, event_payload, ip, user_agent, '
        'geo_country, request_id) '
        'values (@actor_user_id::uuid, @actor_kind, '
        '@actor_service_principal_id::uuid, @target_user_id::uuid, '
        '@operator_id::uuid, @location_id::uuid, @event_type, '
        '@payload::jsonb, @ip::inet, @user_agent, @geo_country, '
        '@request_id::uuid) '
        'returning event_id::text as event_id',
        parameters: <String, Object?>{
          'actor_user_id': actorUserId,
          'actor_kind': actorKind,
          'actor_service_principal_id': actorServicePrincipalId,
          'target_user_id': targetUserId,
          'operator_id': operatorId,
          'location_id': locationId,
          'event_type': eventType,
          'payload': jsonEncode(payload),
          'ip': ip,
          'user_agent': userAgent,
          'geo_country': geoCountry,
          'request_id': requestId,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'auth_events_audit insert returned no rows — RLS may have '
          'blocked the row even though SET LOCAL ran',
        );
      }
      final id = rows.single['event_id'];
      if (id is! String || id.isEmpty) {
        throw StateError(
          'auth_events_audit insert returned a malformed event_id',
        );
      }
      return id;
    });
  }

  /// GDPR redaction of `auth_events_audit` rows targeting [userId].
  ///
  /// **Fails closed by design.** `auth_events_audit` is append-only at
  /// the grant shape: UPDATE and DELETE are revoked from both
  /// `service_role` and `forge_admin`. The proxy runtime physically
  /// cannot UPDATE these rows. GDPR Art. 17 erasure of audit fields
  /// is a real operational need, but it must run as an explicit DBA
  /// break-glass path (temporary GRANT UPDATE → run redaction SQL →
  /// REVOKE UPDATE) so the append-only audit guarantee stays intact
  /// for the runtime path.
  ///
  /// The break-glass procedure (the exact SQL the DBA runs, the
  /// GRANT/REVOKE wrapper, the audit row that records the
  /// redaction, the verification queries) lives in
  /// `runbooks/gdpr_erasure_runbook.md`. This method throws so any
  /// proxy code that mistakenly tries to call it surfaces a clear
  /// "use the runbook" error rather than silently failing at the
  /// database layer.
  ///
  /// The runtime app-side redaction (`users.email`, profile fields,
  /// `auth_sessions.ip`, `password_history` clear, etc.) goes
  /// through `UsersRepository.redactPii`, `AuthSessionsRepository`,
  /// `PasswordHistoryRepository.clearForUser` — all on tables that
  /// have UPDATE / DELETE privileges in the locked grant shape.
  Future<int> redactForUser({
    required String userId,
    required String adminReason,
  }) async {
    // Async body so the StateError surfaces as a Future error
    // (matching async caller expectations) rather than a synchronous
    // throw at call-construction time. The proxy gets a clean
    // awaitable rejection in either case.
    throw StateError(
      'auth_events_audit is append-only at the grant shape '
      '(202604260001_auth_rls_service_role_grants.sql REVOKEs UPDATE '
      'from both service_role and forge_admin). GDPR Art. 17 '
      'redaction of audit-log fields requires the break-glass DBA '
      'path documented in runbooks/gdpr_erasure_runbook.md '
      '("Break-glass: redacting audit log fields"). The runtime '
      'erasure flow handles users.* / auth_sessions.* / '
      'password_history through their own repositories.',
    );
  }

  /// SQL the DBA executes during the break-glass redaction (kept
  /// here so the runbook and code agree byte-for-byte). Not run by
  /// the proxy runtime; copied into the runbook for the DBA.
  ///
  /// Single-source-of-truth for the operational SQL: when the
  /// runbook + code disagree, the disagreement is visible in code
  /// review. The runbook test asserts the runbook quotes this
  /// statement verbatim.
  static const String breakGlassRedactionSql =
      'update auth_events_audit '
      'set ip = null, user_agent = null, '
      "event_payload = (event_payload - 'email' - 'first_name' "
      "- 'last_name' - 'display_name' - 'avatar_url') "
      'where target_user_id = @user_id::uuid '
      'or actor_user_id = @user_id::uuid';
}
