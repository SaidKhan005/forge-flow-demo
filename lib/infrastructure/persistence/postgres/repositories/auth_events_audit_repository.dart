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
import '../postgres_executor.dart';
import '../tenant_context.dart';
import 'audit_logs_repository.dart';

/// Read projection of an `auth_events_audit` row used by the Phase
/// 9.UX.6 self-service Audit Log surface. Carries metadata an
/// operator can recognise (event_type / occurred_at / IP / user
/// agent) plus the JSONB payload so the UI can surface scope hints
/// (operator-wide grants, target user labels) without requiring a
/// second round trip.
class AuthEventListRow {
  const AuthEventListRow({
    required this.eventId,
    required this.eventType,
    required this.occurredAt,
    required this.payload,
    this.actorUserId,
    this.targetUserId,
    this.actorKind,
    this.actorDisplayName,
    this.actorEmail,
    this.actorRoleLabel,
    this.targetKind,
    this.targetId,
    this.adminReason,
    this.rowHash,
    this.businessDate,
    this.ip,
    this.userAgent,
    this.geoCountry,
    this.requestId,
  });

  final String eventId;
  final String eventType;
  final DateTime occurredAt;
  final Map<String, Object?> payload;
  final String? actorUserId;
  final String? targetUserId;
  final String? actorKind;
  final String? actorDisplayName;
  final String? actorEmail;
  final String? actorRoleLabel;
  final String? targetKind;
  final String? targetId;
  final String? adminReason;
  final String? rowHash;
  final DateTime? businessDate;
  final String? ip;
  final String? userAgent;
  final String? geoCountry;
  final String? requestId;
}

class AuthEventsAuditRepository extends OperatorScopedRepository {
  AuthEventsAuditRepository(
    super.tenantWrapper, {
    AuditLogsRepository auditLogsRepository = const AuditLogsRepository(),
    AuditLogsCutoverFlag cutoverFlag = const FixedAuditLogsCutoverFlag(true),
  }) : _auditLogsRepository = auditLogsRepository,
       _cutoverFlag = cutoverFlag;

  /// Phase 9.0Σ.f B.2 — fan-out target for the hash-chained
  /// `public.audit_logs` table. Every write that lands in
  /// `auth_events_audit` is mirrored here in the same transaction
  /// when the `audit_logs_cutover_enabled` feature flag resolves to
  /// `true`. The chain (`prev_row_hash`, `row_hash`) is computed by
  /// the BEFORE INSERT trigger server-side.
  final AuditLogsRepository _auditLogsRepository;

  /// Phase 9.0Σ.f B.2 — resolver for the `audit_logs_cutover_enabled`
  /// feature flag. Production wires
  /// `FeatureFlagsTableAuditLogsCutoverFlag` so flipping the seeded
  /// row to `false` immediately routes new writes back to the legacy
  /// `auth_events_audit`-only path. Default
  /// `FixedAuditLogsCutoverFlag(true)` keeps tests + scaffolds
  /// deterministic without DB I/O.
  final AuditLogsCutoverFlag _cutoverFlag;

  /// INSERT a single audit row. Returns the freshly generated
  /// `event_id`. Caller passes whichever combination of actor /
  /// target / operator / location it has — the schema permits any of
  /// them to be null (e.g. system-issued events have no actor).
  ///
  /// [actorKind] is required. Per the CLAUDE.md hard promise
  /// "audit_logs.actor_kind never NULL", every caller must classify
  /// the actor explicitly so worker / service-principal driven rows
  /// cannot silently inherit a `'user'` default and mis-tag the
  /// audit row. New callers should use `'team_member'`,
  /// `'forge_admin'`, or `'service_principal'` (paired with
  /// [actorServicePrincipalId] from the SP JWT context). Legacy
  /// `'user'` and `'service'` aliases remain accepted here and are
  /// normalized before the hash-chained `audit_logs` fan-out. The
  /// shape assertion below pins the SP invariant: a non-null
  /// [actorServicePrincipalId] requires a service-principal actor.
  Future<String> insertEvent({
    required String operatorId,
    required String locationId,
    required String eventType,
    required String actorKind,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    String? targetKind,
    String? targetId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    String? adminReason,
  }) {
    _assertActorKindShape(
      actorKind: actorKind,
      actorServicePrincipalId: actorServicePrincipalId,
    );
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
      await _fanOutToAuditLogs(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        eventType: eventType,
        actorUserId: actorUserId,
        actorKind: actorKind,
        actorServicePrincipalId: actorServicePrincipalId,
        targetUserId: targetUserId,
        targetKind: targetKind,
        targetId: targetId,
        payload: payload,
        adminReason: adminReason,
      );
      return id;
    });
  }

  /// Enforces the CLAUDE.md hard promise that
  /// `audit_logs.actor_kind` is never NULL and never silently
  /// mis-tagged. New writes use canonical kinds `'team_member'`,
  /// `'forge_admin'`, and `'service_principal'`; `'user'` and
  /// `'service'` are accepted only as legacy aliases. A non-null
  /// [actorServicePrincipalId] requires a service-principal actor so
  /// worker / SP-driven rows cannot land under the legacy `'user'`
  /// default. The fan-out path normalizes aliases before writing the
  /// hash-chained `public.audit_logs` row.
  static void _assertActorKindShape({
    required String actorKind,
    required String? actorServicePrincipalId,
  }) {
    const allowed = <String>{
      'user',
      'team_member',
      'forge_admin',
      'service_principal',
      'service',
      'system',
    };
    if (!allowed.contains(actorKind)) {
      throw ArgumentError.value(
        actorKind,
        'actorKind',
        "actor_kind must be one of "
            "'team_member' / 'forge_admin' / 'service_principal' "
            "or legacy 'user' / 'service' / 'system' - "
            'audit_logs.actor_kind is non-NULL by contract.',
      );
    }
    final hasSp =
        actorServicePrincipalId != null && actorServicePrincipalId.isNotEmpty;
    if (hasSp && actorKind != 'service_principal' && actorKind != 'service') {
      throw ArgumentError.value(
        actorKind,
        'actorKind',
        "actorServicePrincipalId is set but actorKind is "
            "'$actorKind' — service-principal-driven audit rows must "
            "pass actorKind: 'service_principal'.",
      );
    }
    if (!hasSp &&
        (actorKind == 'service_principal' || actorKind == 'service')) {
      throw ArgumentError.value(
        actorKind,
        'actorKind',
        "actorKind '$actorKind' requires actorServicePrincipalId "
            "from the SP JWT context.",
      );
    }
  }

  /// Phase 9.0Σ.f B.2 — fan-out into `public.audit_logs` (hash-chained
  /// SOC 2 / forensic audit log). No-op in any of these cases:
  ///
  ///   * cutover flag is off (rollback path);
  ///   * `operator_id` is null — `audit_logs` requires
  ///     `operator_id NOT NULL` because the chain is scoped per
  ///     `(operator_id, chain_date)`;
  ///   * `actor_kind` is not in (`'user'`, `'service'`) — the
  ///     `audit_logs` CHECK enumerates exactly those two values, so
  ///     legacy `actorKind: 'system'` callers (worker / reset
  ///     boundaries that have no human / SP attribution) cannot be
  ///     attributed in the chain. Skipping preserves the gateway's
  ///     control flow (the `auth_events_audit` write still happens —
  ///     `auth_events_audit` schema permits any text `actor_kind`).
  ///   * the actor identifier slot for the kind is empty —
  ///     `audit_logs_actor_shape_check` requires user→`actor_user_id`,
  ///     service→`actor_principal_id`, and the constraint is
  ///     non-negotiable. A missing identifier means the legacy row was
  ///     a system / no-actor probe; we keep the legacy posture and
  ///     skip the chain row instead of failing the gateway.
  Future<void> _fanOutToAuditLogs(
    PostgresExecutor exec, {
    required String? operatorId,
    required String? locationId,
    required String eventType,
    required String? actorUserId,
    required String actorKind,
    required String? actorServicePrincipalId,
    required String? targetUserId,
    required String? targetKind,
    required String? targetId,
    required Map<String, Object?> payload,
    String? adminReason,
  }) async {
    if (operatorId == null) return;
    // Canonical audit-log labels are stricter than the legacy
    // auth_events_audit labels. Keep accepting old producer labels,
    // but write the contract labels into the hash chain.
    final chainActorKind = switch (actorKind) {
      'user' || 'team_member' => 'team_member',
      'forge_admin' => 'forge_admin',
      'service_principal' || 'service' => 'service_principal',
      _ => null,
    };
    if (chainActorKind == null) return;
    final mappedActorUserId =
        chainActorKind == 'team_member' || chainActorKind == 'forge_admin'
        ? actorUserId
        : null;
    final mappedActorPrincipalId =
        chainActorKind == 'service_principal' &&
            actorServicePrincipalId != null &&
            actorServicePrincipalId.isNotEmpty
        ? 'sp:$actorServicePrincipalId'
        : null;
    if (chainActorKind == 'team_member' &&
        (mappedActorUserId == null || mappedActorUserId.isEmpty)) {
      return;
    }
    if (chainActorKind == 'forge_admin' &&
        (mappedActorUserId == null || mappedActorUserId.isEmpty)) {
      return;
    }
    if (chainActorKind == 'service_principal' &&
        mappedActorPrincipalId == null) {
      return;
    }
    if (!await _cutoverFlag.isEnabled(exec)) return;
    final effectiveAdminReason =
        adminReason ?? _stringFromPayload(payload['admin_reason']);
    if (chainActorKind == 'forge_admin' &&
        (effectiveAdminReason == null || effectiveAdminReason.isEmpty)) {
      throw ArgumentError.value(
        effectiveAdminReason,
        'adminReason',
        'forge_admin audit_logs rows require admin_reason',
      );
    }
    final effectiveTargetKind =
        targetKind ?? (targetUserId != null ? 'user' : null);
    final effectiveTargetId = targetId ?? targetUserId;
    await _auditLogsRepository.writeRow(
      exec,
      operatorId: operatorId,
      locationId: locationId,
      actorKind: chainActorKind,
      actorUserId: mappedActorUserId,
      actorPrincipalId: mappedActorPrincipalId,
      targetKind: effectiveTargetKind,
      targetId: effectiveTargetId,
      action: eventType,
      payload: payload,
      adminReason: chainActorKind == 'forge_admin'
          ? effectiveAdminReason
          : null,
    );
  }

  static String? _stringFromPayload(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// INSERT a single system-scope audit row.
  ///
  /// F&F global admin surfaces can legitimately operate before a tenant scope
  /// exists (for example, listing all operators or onboarding a new operator).
  /// The table schema allows nullable `operator_id` / `location_id`; this
  /// helper uses the audited system transaction path instead of manufacturing a
  /// fake [TenantContext].
  Future<String> insertSystemEvent({
    required String eventType,
    required String actorKind,
    String? operatorId,
    String? locationId,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    String? targetKind,
    String? targetId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    required String adminReason,
  }) {
    _assertActorKindShape(
      actorKind: actorKind,
      actorServicePrincipalId: actorServicePrincipalId,
    );
    return withSystem<String>((exec) async {
      return insertSystemEventOn(
        exec,
        eventType: eventType,
        operatorId: operatorId,
        locationId: locationId,
        actorUserId: actorUserId,
        actorKind: actorKind,
        actorServicePrincipalId: actorServicePrincipalId,
        targetUserId: targetUserId,
        targetKind: targetKind,
        targetId: targetId,
        payload: payload,
        ip: ip,
        userAgent: userAgent,
        geoCountry: geoCountry,
        requestId: requestId,
        adminReason: adminReason,
      );
    }, reason: adminReason);
  }

  /// Same as [insertSystemEvent] but runs on a caller-supplied
  /// [PostgresExecutor] instead of opening its own `withSystem`
  /// transaction. Use this when the audit row must commit atomically
  /// with another mutation in the same transaction (HARD-D
  /// `feature_flags` toggle, future admin-write paths). The
  /// fan-out into `audit_logs` runs inside the same `exec` so the
  /// hash-chained audit row is bound to the same commit boundary.
  Future<String> insertSystemEventOn(
    PostgresExecutor exec, {
    required String eventType,
    required String actorKind,
    String? operatorId,
    String? locationId,
    String? actorUserId,
    String? actorServicePrincipalId,
    String? targetUserId,
    String? targetKind,
    String? targetId,
    Map<String, Object?> payload = const <String, Object?>{},
    String? ip,
    String? userAgent,
    String? geoCountry,
    String? requestId,
    String? adminReason,
  }) async {
    _assertActorKindShape(
      actorKind: actorKind,
      actorServicePrincipalId: actorServicePrincipalId,
    );
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
      throw StateError('auth_events_audit system insert returned no rows');
    }
    final id = rows.single['event_id'];
    if (id is! String || id.isEmpty) {
      throw StateError(
        'auth_events_audit system insert returned a malformed event_id',
      );
    }
    await _fanOutToAuditLogs(
      exec,
      operatorId: operatorId,
      locationId: locationId,
      eventType: eventType,
      actorUserId: actorUserId,
      actorKind: actorKind,
      actorServicePrincipalId: actorServicePrincipalId,
      targetUserId: targetUserId,
      targetKind: targetKind,
      targetId: targetId,
      payload: payload,
      adminReason: adminReason,
    );
    return id;
  }

  /// Phase 9.UX.6 — self-service Audit Log read projection.
  ///
  /// Returns the actor's own audit events (rows where they are either
  /// the `actor_user_id` or the `target_user_id`), newest first.
  /// The query shape is the *primary* defense: it pins both
  /// `operator_id` and `user_id`, so a future admin-pool binding or a
  /// miswired tenant wrapper cannot accidentally widen same-user
  /// reads across operators. The live `auth_events_audit` RLS policy
  /// is tenant-only (not per-user), so the `user_id` clause carries
  /// the per-user defense alone.
  ///
  /// Pagination is server-side via `LIMIT` + `OFFSET`; callers fetch
  /// one extra row to detect `has_more` without a separate count.
  ///
  /// [eventTypePatterns] are case-sensitive `LIKE` patterns OR'd
  /// together (e.g. `['%password%']`); pass an empty list to skip
  /// kind-filtering. The proxy projects [AuthEventKind] into the
  /// matching pattern set via [AuthEventLabels.sqlPatternsFor].
  ///
  /// [from] and [to] bound the `occurred_at` window. Both are
  /// optional so callers can pass an open range; the proxy clamps
  /// per-request bounds before delegating.
  Future<List<AuthEventListRow>> listForUser({
    required String operatorId,
    required String locationId,
    required String userId,
    required int limit,
    required int offset,
    List<String> eventTypePatterns = const <String>[],
    DateTime? from,
    DateTime? to,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
    );
    final params = <String, Object?>{
      'operator_id': operatorId,
      'user_id': userId,
      'limit': limit,
      'offset': offset,
    };
    final patternClauses = <String>[];
    for (var i = 0; i < eventTypePatterns.length; i++) {
      final key = 'pattern_$i';
      patternClauses.add('a.event_type like @$key');
      params[key] = eventTypePatterns[i];
    }
    final patternFilter = patternClauses.isEmpty
        ? ''
        : 'and (${patternClauses.join(' or ')}) ';
    String dateFilter = '';
    if (from != null) {
      dateFilter += 'and a.occurred_at >= @from ';
      params['from'] = from.toUtc();
    }
    if (to != null) {
      dateFilter += 'and a.occurred_at <= @to ';
      params['to'] = to.toUtc();
    }
    return withTenant<List<AuthEventListRow>>(ctx, (exec) async {
      final rows = await exec.query(
        'select a.event_id::text as event_id, '
        'a.event_type, a.event_payload, a.occurred_at, '
        'a.actor_user_id::text as actor_user_id, '
        'a.target_user_id::text as target_user_id, '
        'a.actor_kind, '
        "coalesce(nullif(actor.display_name, ''), "
        "nullif(trim(concat_ws(' ', actor.first_name, actor.last_name)), ''), "
        'actor.email) as actor_display_name, '
        'actor.email as actor_email, '
        'actor_role.display_name as actor_role_label, '
        'host(a.ip) as ip, a.user_agent, a.geo_country, '
        'a.request_id::text as request_id '
        'from auth_events_audit a '
        'left join users actor on actor.user_id = a.actor_user_id '
        'and actor.operator_id = a.operator_id '
        'left join roles actor_role on actor_role.role_id = '
        'actor.primary_role_id '
        'where a.operator_id = @operator_id::uuid '
        'and (a.actor_user_id = @user_id::uuid '
        'or a.target_user_id = @user_id::uuid) '
        '$patternFilter'
        '$dateFilter'
        'order by a.occurred_at desc '
        'limit @limit offset @offset',
        parameters: params,
      );
      return rows.map(_projectAuditRow).toList(growable: false);
    });
  }

  /// F&F admin Audit Log read projection.
  ///
  /// Unlike the self-service Audit Log above, this reads from the
  /// hash-chained `audit_logs` ledger for the selected operator. The admin
  /// route is permission-gated before it reaches this method and the query
  /// runs through the explicit system path so `forge_admin` BYPASSRLS is
  /// visible in the transaction audit marker.
  Future<List<AuthEventListRow>> listAuditLogsForAdmin({
    required String operatorId,
    required String locationId,
    required int limit,
    required int offset,
    List<String> actionPatterns = const <String>[],
    DateTime? from,
    DateTime? to,
  }) {
    final params = <String, Object?>{
      'operator_id': operatorId,
      'limit': limit,
      'offset': offset,
    };
    final patternClauses = <String>[];
    for (var i = 0; i < actionPatterns.length; i++) {
      final key = 'pattern_$i';
      patternClauses.add('al.action like @$key');
      params[key] = actionPatterns[i];
    }
    final patternFilter = patternClauses.isEmpty
        ? ''
        : 'and (${patternClauses.join(' or ')}) ';
    String dateFilter = '';
    if (from != null) {
      dateFilter += 'and al.occurred_at >= @from ';
      params['from'] = from.toUtc();
    }
    if (to != null) {
      dateFilter += 'and al.occurred_at <= @to ';
      params['to'] = to.toUtc();
    }
    return withSystem<List<AuthEventListRow>>((exec) async {
      final rows = await exec.query(
        'select al.id::text as event_id, '
        'al.action as event_type, al.payload as event_payload, '
        'al.occurred_at, al.actor_user_id::text as actor_user_id, '
        "case when al.target_kind = 'user' "
        'then al.target_id else null end as target_user_id, '
        'al.actor_kind, al.target_kind, al.target_id, al.admin_reason, '
        'coalesce(al.business_date, al.chain_date)::text as business_date, '
        "encode(al.row_hash, 'hex') as row_hash, "
        "coalesce(nullif(actor.display_name, ''), "
        "nullif(trim(concat_ws(' ', actor.first_name, actor.last_name)), ''), "
        'actor.email) as actor_display_name, '
        'actor.email as actor_email, '
        'actor_role.display_name as actor_role_label, '
        'null::text as ip, null::text as user_agent, '
        'null::text as geo_country, null::text as request_id '
        'from public.audit_logs al '
        'left join public.users actor on actor.user_id = al.actor_user_id '
        'and actor.operator_id = al.operator_id '
        'left join public.roles actor_role on actor_role.role_id = '
        'actor.primary_role_id '
        'where al.operator_id = @operator_id::uuid '
        '$patternFilter'
        '$dateFilter'
        'order by al.occurred_at desc, al.id desc '
        'limit @limit offset @offset',
        parameters: params,
      );
      return rows.map(_projectAuditRow).toList(growable: false);
    }, reason: 'admin.auth.audit_log.read');
  }

  static AuthEventListRow _projectAuditRow(Map<String, Object?> row) {
    DateTime asDateTime(Object? value) {
      if (value is DateTime) return value.toUtc();
      if (value is String) return DateTime.parse(value).toUtc();
      throw StateError('auth_events_audit row missing occurred_at');
    }

    DateTime? asOptionalDate(Object? value) {
      if (value is DateTime) {
        return DateTime.utc(value.year, value.month, value.day);
      }
      if (value is String && value.isNotEmpty) {
        final parsed = DateTime.tryParse(value);
        if (parsed == null) return null;
        return DateTime.utc(parsed.year, parsed.month, parsed.day);
      }
      return null;
    }

    String? asOptionalString(Object? value) {
      if (value is! String) return null;
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    final eventId = row['event_id'];
    final eventType = row['event_type'];
    if (eventId is! String || eventId.isEmpty) {
      throw StateError('auth_events_audit row missing event_id');
    }
    if (eventType is! String || eventType.isEmpty) {
      throw StateError('auth_events_audit row missing event_type');
    }
    final payloadRaw = row['event_payload'];
    Map<String, Object?> payload = const <String, Object?>{};
    if (payloadRaw is Map) {
      payload = Map<String, Object?>.from(payloadRaw);
    } else if (payloadRaw is String && payloadRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(payloadRaw);
        if (decoded is Map) {
          payload = Map<String, Object?>.from(decoded);
        }
      } on FormatException {
        // Treat malformed payloads as empty so a corrupt row never
        // crashes the listing.
      }
    }
    return AuthEventListRow(
      eventId: eventId,
      eventType: eventType,
      occurredAt: asDateTime(row['occurred_at']),
      payload: Map<String, Object?>.unmodifiable(payload),
      actorUserId: asOptionalString(row['actor_user_id']),
      targetUserId: asOptionalString(row['target_user_id']),
      actorKind: asOptionalString(row['actor_kind']),
      actorDisplayName: asOptionalString(row['actor_display_name']),
      actorEmail: asOptionalString(row['actor_email']),
      actorRoleLabel: asOptionalString(row['actor_role_label']),
      targetKind: asOptionalString(row['target_kind']),
      targetId: asOptionalString(row['target_id']),
      adminReason: asOptionalString(row['admin_reason']),
      rowHash: asOptionalString(row['row_hash']),
      businessDate: asOptionalDate(row['business_date']),
      ip: asOptionalString(row['ip']),
      userAgent: asOptionalString(row['user_agent']),
      geoCountry: asOptionalString(row['geo_country']),
      requestId: asOptionalString(row['request_id']),
    );
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
