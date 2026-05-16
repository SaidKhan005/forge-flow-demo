// Wave 2 AC-1 - shared human-readable labels for the canonical
// `actor_kind` enum strings that flow out of `public.audit_logs` and
// `public.auth_events_audit`.
//
// Background.
//
// Audit-log rows persist `actor_kind` as a raw enum string. The proxy
// writes one of several wire values depending on the call path:
//
//   * `user`              - self-service operator team member (also
//                            normalized to `team_member` on the operator-web
//                            surface enum).
//   * `team_member`       - operator-web alias for `user`. Self-service
//                            paths clamp to this value.
//   * `service`           - non-human writer (backfill workers,
//                            vendor connectors, OAuth refresh jobs).
//                            Mirrors the SQL CHECK constraint allowed set
//                            from migration
//                            `202605071800_actor_kind_constraint_consolidation.sql`.
//   * `service_principal` - aliased wire value used by `sp:`-prefixed
//                            JWTs and `lib/operator_web/services/`
//                            gateways. Same human meaning as `service`.
//   * `forge_admin`       - F&F admin break-glass writes. Always paired
//                            with `admin_reason`.
//   * `ff_support`        - F&F support-tier admin writes (subset of
//                            forge_admin used by the data-accuracy
//                            override path).
//   * `system`            - F&F platform automation that isn't tied to
//                            a service principal row (e.g. partman
//                            cleanups, anchor durability writes).
//
// Two audit-log surfaces (admin + operator-web hierarchy) historically
// rendered these raw enum strings into the row body. CLAUDE.md "UX
// Writing Standard" forbids raw enums on operator-facing copy and the
// Phase 2 inventory tagged the gap as AC-1. This catalog mirrors the
// per-key label pattern that
// `lib/auth/permission_key_metadata.dart` uses for R-1L / R-2L, so
// every audit-log surface lights up off the same map.
//
// Mirror discipline (this slice is reader-only — no schema change):
//
//   1. `db/migrations/202605071800_actor_kind_constraint_consolidation.sql`
//      pins the wire-side allowed set (`'user'`, `'service'`).
//   2. `tool/advisor_proxy/proxy_bootstrap.dart` (and siblings under
//      `tool/advisor_proxy/`) write the surface-extended set
//      (`forge_admin`, `service_principal`, `team_member`,
//      `system`, `ff_support`) through the audit emitter.
//   3. This file maps every observed wire value to a UX label.
//   4. `lib/admin/services/audited_support_actions_admin_gateway.dart`
//      retains its enum-side `AuditActorKind.displayLabel` mirror for
//      the F&F admin filter UI (multi-select chips), which is the
//      writer-driven label seam.
//
// HP discipline. HP #2 (kDemoMode is a writer-side switch). This
// catalog is a static map evaluated at render time; demo and prod
// surfaces render the same labels.

/// Shared catalog of operator-facing labels for the `actor_kind`
/// audit-log column. Every wire enum string the proxy persists must
/// resolve to a plain-English label; unknown values fall through to
/// the raw string so a newly added enum still renders without crashing
/// the row.
class ActorKindLabelCatalog {
  const ActorKindLabelCatalog._();

  /// Locked map of `actor_kind` wire values to UX labels.
  ///
  /// Keys MUST stay lower-snake-case so [labelFor] can normalize input
  /// before the lookup. New values added to the SQL CHECK constraint
  /// (or to the proxy emitter surface set) need a row here AND a
  /// matching update to `docs/contracts/auth_permission_key_catalog.md`
  /// if the catalog ever widens past the audit-log surface.
  static const Map<String, String> byKind = <String, String>{
    'user': 'Team member',
    'team_member': 'Team member',
    'service': 'Service account',
    'service_principal': 'Service account',
    'forge_admin': 'F&F admin',
    'ff_support': 'F&F support',
    'system': 'F&F platform',
  };

  /// Returns the UX label for [kind]. Null / blank values return
  /// `'Unknown actor'`; unknown enum strings return [kind] verbatim
  /// (defensive default — a fresh wire value should still render the
  /// row without a stack trace).
  static String labelFor(String? kind) {
    if (kind == null) return 'Unknown actor';
    final trimmed = kind.trim();
    if (trimmed.isEmpty) return 'Unknown actor';
    final normalized = trimmed.toLowerCase();
    return byKind[normalized] ?? trimmed;
  }
}
