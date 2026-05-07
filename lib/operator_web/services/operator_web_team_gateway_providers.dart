// Phase 11W - Operator Web team-surface gateway provider seams.
//
// These abstract sentinels let the router (and any other consumer) read a
// gateway off the active [OperatorWebAuthSource] without coupling to the
// concrete demo-vs-live source class. Demo and live auth sources mix the
// matching provider in so the router pulls the gateway via `is`-typecheck.
//
// They live under `services/` (not `router/`) because they describe a
// service-layer seam — the router is a render-only consumer and must not
// own service interfaces. Keeping them here also lets the live auth source
// (`firebase_operator_web_auth_source.dart`) implement these without
// importing the router (which would invert the layer ordering).
//
// Keep this file dependency-light: only the gateway interfaces these
// providers expose. Concrete demo/live impls import from elsewhere.
import 'business_timing_gateway.dart';
import 'operator_web_data_accuracy_gateway.dart';
import 'web_account_gateway.dart';
import 'web_business_timing_gateway.dart';
import 'web_security_gateway.dart';
import 'web_team_audit_log_gateway.dart';
import 'web_team_hierarchy_gateway.dart';
import 'web_team_roles_gateway.dart';
import 'web_team_sessions_gateway.dart';
import 'web_team_users_gateway.dart';

/// Re-export for the Phase 11W.8 / Wave A3 vendor-connections mount.
/// Auth sources mix this provider in to surface the live HTTP gateway
/// to [OperatorWebVendorConnectionsResolver]; demo sources omit the
/// mixin and the resolver returns null so the shared widget falls
/// back to its in-memory catalog. The provider class itself lives
/// next to the live HTTP gateway implementation; the re-export keeps
/// this file the single registration index for operator-web gateway
/// providers.
export 'operator_web_vendor_connections_gateway.dart'
    show OperatorWebVendorConnectionsGatewayProvider;
export 'operator_web_vendor_connections_resolver.dart'
    show OperatorWebVendorConnectionsResolver;

export 'operator_web_data_accuracy_gateway.dart'
    show
        OperatorWebDataAccuracyGateway,
        OperatorWebHttpDataAccuracyGateway;

/// Operator Web W4.B - re-export the chain anchor gateway provider so
/// router/auth-source wiring sees one canonical sentinel surface.
export 'operator_web_audit_chain_anchors_gateway_provider.dart'
    show
        OperatorWebAuditChainAnchorsGateway,
        OperatorWebAuditChainAnchorsGatewayDemo,
        OperatorWebAuditChainAnchorsGatewayLive,
        OperatorWebAuditChainAnchorsGatewayProvider,
        OperatorWebAuditChainAnchorSnapshot,
        OperatorWebAuditChainAnchorStatus;

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply a [WebTeamUsersGateway] for the Members surface. Demo
/// auth source mixes this in with `DemoWebTeamUsersGateway`;
/// `11W.1.live` mixes it in on the live source with the
/// `package:http` impl.
abstract class OperatorWebTeamUsersGatewayProvider {
  WebTeamUsersGateway get teamUsersGateway;
}

/// Optional source-owned timing gateway. Live wiring can mix this into
/// the Firebase source once backend timing routes are ready; the router
/// otherwise uses the read-only demo gateway.
abstract class OperatorWebBusinessTimingGatewayProvider {
  BusinessTimingGateway get businessTimingGateway;
}

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply a [WebAccountGateway] for the business-identity editor.
/// Live wiring (the live Firebase source plus the proxy) implements
/// this; demo / fixture sources may leave it absent so the screen
/// renders honest read-only state.
abstract class OperatorWebAccountGatewayProvider {
  WebAccountGateway get accountGateway;
}

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply a [WebBusinessTimingGateway] for the timing editor.
/// Live wiring (the live Firebase source plus the proxy) implements
/// this; demo / fixture sources may leave it absent so the editor
/// renders the validation surface without a save target.
abstract class OperatorWebBusinessTimingWriteGatewayProvider {
  WebBusinessTimingGateway get businessTimingWriteGateway;
}

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply a live data accuracy gateway. Demo sources omit it and
/// the screen keeps its fixture/in-memory behavior.
abstract class OperatorWebDataAccuracyGatewayProvider {
  OperatorWebDataAccuracyGateway get dataAccuracyGateway;
}

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply a [WebTeamRolesGateway] for the Roles surface. Demo
/// auth source mixes this in with `DemoWebTeamRolesGateway`;
/// `11W.2.live` mixes it in on the live source with the
/// `package:http` impl.
abstract class OperatorWebTeamRolesGatewayProvider {
  WebTeamRolesGateway get teamRolesGateway;
}

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply a [WebTeamHierarchyGateway] for the `/locations`
/// surface. Demo auth source mixes this in with
/// `DemoWebTeamHierarchyGateway`; `11W.3.live` mixes it in on the
/// live source with the `package:http` impl.
abstract class OperatorWebTeamHierarchyGatewayProvider {
  WebTeamHierarchyGateway get teamHierarchyGateway;
}

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply a [WebTeamSessionsGateway] for the Sessions surface.
/// Demo auth source mixes this in with `DemoWebTeamSessionsGateway`;
/// `11W.4.live` mixes it in on the live source with the
/// `package:http` impl. The provider also surfaces the actor's
/// current session id so the screen can mark `(this session)` and
/// short-circuit a self-revoke into `signOut()`.
abstract class OperatorWebTeamSessionsGatewayProvider {
  WebTeamSessionsGateway get teamSessionsGateway;

  /// Stable id of the row representing the current operator-web
  /// session. Null when the auth source has not surfaced one yet
  /// (early bootstrap); the screen falls back to no chip + no
  /// short-circuit in that case.
  String? get currentSessionId;
}

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply a [WebTeamAuditLogGateway] for the `/audit-log` surface.
/// Demo auth source mixes this in with `DemoWebTeamAuditLogGateway`;
/// `11W.5.live` mixes it in on the live source with the
/// `package:http` impl.
abstract class OperatorWebTeamAuditLogGatewayProvider {
  WebTeamAuditLogGateway get teamAuditLogGateway;
}

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply a [WebSecurityGateway] for the Security surface. Demo
/// auth source mixes this in with `DemoWebSecurityGateway`;
/// `11W.6.live` mixes it in on the live source with the
/// `package:http` impl.
abstract class OperatorWebSecurityGatewayProvider {
  WebSecurityGateway get securityGateway;
}
