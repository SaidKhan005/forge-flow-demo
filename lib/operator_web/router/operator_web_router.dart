// Phase 11W.0 — Operator Web Console router.
//
// Watches the [OperatorWebAuthSource] state stream and renders the
// matching surface — onboarding click-path screens during the
// pre-completed stages, and the [WebAppShell] (with the post-V1
// placeholder Account / Vendor connections bodies) once
// [OnboardingStage.completed] lands.
//
// The router is render-only on the auth state. State transitions are
// driven by the auth source; the router does not push or pop routes
// directly. That keeps the route guard from drifting from the auth
// source — the auth source is the single source of truth for "where
// is this user in the onboarding click path right now."
//
// Browser URL: 11W.0 ships the magic-link landing parser only. The
// router reads `Uri.base.queryParameters['token']` once at startup so
// `/onboarding/welcome?token=...` lands the operator on the welcome
// screen with the token pre-filled. URL synchronization for the rest
// of the click path is intentionally deferred to a follow-up so this
// slice stays scoped — the Hard Promises forbid widening scope mid-
// slice.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_models.dart';
import '../../services/auth/auth_operations_gateway.dart';
import '../auth/operator_web_auth_source.dart';
import '../auth/operator_web_handoff_redeem_gateway.dart';
import '../account/operator_web_account_actions.dart';
import '../services/business_timing_gateway.dart';
import '../services/http_business_timing_read_gateway.dart';
import '../services/demo_security_gateway.dart';
import '../services/demo_team_audit_log_gateway.dart';
import '../services/demo_team_fixtures.dart';
import '../services/demo_team_hierarchy_gateway.dart';
import '../services/demo_team_roles_gateway.dart';
import '../services/demo_team_sessions_gateway.dart';
import '../services/demo_team_users_gateway.dart';
import '../services/operator_web_notification_preferences_gateway_provider.dart';
import '../services/operator_web_team_gateway_providers.dart';
import '../services/web_account_gateway.dart';
import '../services/web_business_timing_gateway.dart';
import '../services/web_security_gateway.dart';
import '../services/web_team_audit_log_gateway.dart';
import '../services/web_team_hierarchy_gateway.dart';
import '../services/web_team_roles_gateway.dart';
import '../services/web_team_sessions_gateway.dart';
import '../services/web_team_users_gateway.dart';
import '../screens/account_screen.dart';
import '../screens/audit_log_screen.dart';
// Per-Daypart Targets V1 / Slice 2 (Gap 35): the operator-web
// Benchmarks override surface was cut entirely. Mobile Baseline
// Manager star-shift selection is the only override path. No
// `benchmarks_screen.dart` import remains.
import '../screens/business_setup_screen.dart';
import '../screens/business_timing_editor_screen.dart';
import '../screens/my_account_screen.dart';
import '../screens/custom_role_editor_screen.dart';
import '../screens/data_accuracy_screen.dart';
import '../screens/hierarchy_screen.dart';
import '../screens/members_screen.dart';
import '../screens/mfa_enrollment_screen.dart';
import '../screens/password_setup_screen.dart';
import '../screens/permission_explainer_screen.dart';
import '../screens/roles_screen.dart';
import '../screens/sessions_screen.dart';
import '../screens/settings_notifications_screen.dart';
import '../screens/schedule_screen.dart';
import '../screens/sign_in_screen.dart';
import '../screens/tos_accept_screen.dart';
import '../screens/vendor_connections_screen.dart';
import '../screens/wage_authority_screen.dart';
import '../screens/welcome_screen.dart';
import '../widgets/web_app_shell.dart';
import '../../theme/app_theme.dart';

/// Stable nav ids for the post-onboarding shell. Tests and deep
/// links key off these.
///
/// `account` is the business-identity surface (business name, logo,
/// currency, locale, week-start, rollover hour). `my_account` is the
/// operator-user surface (Profile, MFA, Password, T&Cs).
const String kOperatorWebNavAccount = 'account';
const String kOperatorWebNavMyAccount = 'my_account';
const String kOperatorWebNavBusinessSetup = 'business_setup';
const String kOperatorWebNavBusinessTimingEditor = 'business_timing_editor';
// Per-Daypart Targets V1 / Slice 2 (Gap 35): operator-web Benchmarks
// override nav removed; no `kOperatorWebNavBenchmarks` constant.
const String kOperatorWebNavMembers = 'members';
const String kOperatorWebNavRoles = 'roles';
const String kOperatorWebNavLocations = 'locations';
const String kOperatorWebNavSessions = 'sessions';
const String kOperatorWebNavAuditLog = 'audit_log';
const String kOperatorWebNavVendorConnections = 'vendor_connections';
const String kOperatorWebNavDataAccuracy = 'data_accuracy';
const String kOperatorWebNavNotifications = 'notifications';
const String kOperatorWebNavWageAuthority = 'wage_authority';
const String kOperatorWebNavSchedule = 'schedule';

/// Sub-route names mounted under the Roles nav surface. The router
/// keeps a small state machine here rather than registering full
/// `MaterialPageRoute` entries because the operator-web shell is a
/// single-Navigator shell; the names mirror the parity-contract paths
/// so `/roles`, `/roles/explainer`, and `/roles/edit/:id` line up
/// with the URL bar once URL synchronization lands in a follow-up.
const String kOperatorWebRolesPath = '/roles';
const String kOperatorWebRolesExplainerPath = '/roles/explainer';
const String kOperatorWebRolesEditPath = '/roles/edit';

/// Default nav surface the shell lands on after onboarding completes.
const String kOperatorWebDefaultNavId = kOperatorWebNavAccount;

const Set<String> _kLegacySecurityPaths = <String>{
  '/security',
  '/sign-in-security',
  '/operator-web/security',
  '/operator-web/sign-in-security',
};

class _OperatorWebInitialRoute {
  const _OperatorWebInitialRoute({
    required this.navId,
    required this.scrollMyAccountSecurityOnFirstBuild,
  });

  final String navId;
  final bool scrollMyAccountSecurityOnFirstBuild;

  static _OperatorWebInitialRoute resolve({
    required String initialNavId,
    required Uri initialUri,
  }) {
    final normalizedPath = _normalizePath(initialUri.path);
    final fragment = initialUri.fragment.toLowerCase();
    if (_kLegacySecurityPaths.contains(normalizedPath) ||
        initialNavId == 'security' ||
        initialNavId == 'sign-in-security') {
      return const _OperatorWebInitialRoute(
        navId: kOperatorWebNavMyAccount,
        scrollMyAccountSecurityOnFirstBuild: true,
      );
    }
    if ((normalizedPath == '/my-account' ||
            normalizedPath == '/operator-web/my-account') &&
        fragment == 'security') {
      return const _OperatorWebInitialRoute(
        navId: kOperatorWebNavMyAccount,
        scrollMyAccountSecurityOnFirstBuild: true,
      );
    }
    return _OperatorWebInitialRoute(
      navId: initialNavId,
      scrollMyAccountSecurityOnFirstBuild: false,
    );
  }

  static String _normalizePath(String rawPath) {
    final path = rawPath.trim().toLowerCase();
    if (path.isEmpty) return '/';
    return path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
  }
}

class _OperatorWebHandoffLanding {
  const _OperatorWebHandoffLanding({required this.code, required this.navId});

  final String code;
  final String? navId;

  static _OperatorWebHandoffLanding? parse(Uri uri) {
    if (_OperatorWebInitialRoute._normalizePath(uri.path) != '/handoff') {
      return null;
    }
    final code = uri.queryParameters['code']?.trim();
    if (code == null || code.isEmpty) {
      return const _OperatorWebHandoffLanding(code: '', navId: null);
    }
    return _OperatorWebHandoffLanding(
      code: code,
      navId: _navIdFromRaw(uri.queryParameters['nav']),
    );
  }
}

class _OperatorWebHandoffRouteTarget {
  const _OperatorWebHandoffRouteTarget({
    required this.navId,
    this.scrollMyAccountSecurity = false,
    this.editBusinessTiming = false,
  });

  final String navId;
  final bool scrollMyAccountSecurity;
  final bool editBusinessTiming;
}

Uri _safeBaseUri() {
  try {
    return Uri.base;
  } catch (_) {
    return Uri(path: '/');
  }
}

_OperatorWebHandoffRouteTarget _handoffTargetFromPath(
  String? targetPath, {
  String? fallbackNavId,
}) {
  final parsed = targetPath == null ? null : Uri.tryParse(targetPath.trim());
  final rawPath = parsed?.path ?? targetPath ?? '';
  final normalizedPath = _OperatorWebInitialRoute._normalizePath(rawPath);
  final fragment = (parsed?.fragment ?? '').toLowerCase();
  if (normalizedPath == '/security' ||
      normalizedPath == '/sign-in-security' ||
      (normalizedPath == '/my-account' && fragment == 'security')) {
    return const _OperatorWebHandoffRouteTarget(
      navId: kOperatorWebNavMyAccount,
      scrollMyAccountSecurity: true,
    );
  }
  if (normalizedPath == '/business-timing' ||
      normalizedPath == '/business-timing-editor') {
    return const _OperatorWebHandoffRouteTarget(
      navId: kOperatorWebNavBusinessSetup,
      editBusinessTiming: true,
    );
  }
  final fromPath = _navIdFromRaw(normalizedPath.replaceFirst('/', ''));
  final navId = fromPath ?? fallbackNavId ?? kOperatorWebDefaultNavId;
  return _OperatorWebHandoffRouteTarget(navId: navId);
}

String? _navIdFromRaw(String? raw) {
  final normalized = raw?.trim().toLowerCase().replaceAll('-', '_');
  return switch (normalized) {
    'account' => kOperatorWebNavAccount,
    'my_account' => kOperatorWebNavMyAccount,
    'business_setup' => kOperatorWebNavBusinessSetup,
    'business_timing_editor' => kOperatorWebNavBusinessSetup,
    // 'benchmarks' route dropped — operator-web override surface cut
    // (Per-Daypart Targets V1 / Slice 2, Gap 35).
    'members' => kOperatorWebNavMembers,
    'roles' => kOperatorWebNavRoles,
    'locations' => kOperatorWebNavLocations,
    'sessions' => kOperatorWebNavSessions,
    'audit_log' => kOperatorWebNavAuditLog,
    'vendor_connections' => kOperatorWebNavVendorConnections,
    'data_accuracy' => kOperatorWebNavDataAccuracy,
    'notifications' => kOperatorWebNavNotifications,
    // Wave 2 S-2 (`debug.md:220`, OW-13c) folded Wage Authority under
    // the Data Accuracy page. Map any stored `wage_authority` nav id
    // (deep links, bookmarks, prior handoff target paths) to
    // `kOperatorWebNavDataAccuracy` so existing entry points keep
    // landing on the wage section without 404ing.
    'wage_authority' => kOperatorWebNavDataAccuracy,
    'schedule' => kOperatorWebNavSchedule,
    'security' || 'sign_in_security' => kOperatorWebNavMyAccount,
    _ => null,
  };
}

/// Top-level router widget for the operator-web console. Drop in
/// under a `MaterialApp` with the brand theme.
class OperatorWebRouter extends StatefulWidget {
  const OperatorWebRouter({
    super.key,
    required this.source,
    this.initialMagicLinkToken,
    this.initialNavId = kOperatorWebDefaultNavId,
    this.initialUri,
  });

  /// Auth source the router watches.
  final OperatorWebAuthSource source;

  /// Optional magic-link token surfaced on the welcome screen. The
  /// live entrypoint parses `Uri.base` and passes the result here;
  /// tests pass fixtures directly so the assertion does not depend
  /// on `Uri.base`.
  final String? initialMagicLinkToken;

  /// Initial post-onboarding nav surface. Tests pass
  /// `kOperatorWebNavVendorConnections` to land directly on the
  /// vendor-connections placeholder.
  final String initialNavId;

  /// Optional browser URI test seam. Production reads [Uri.base].
  final Uri? initialUri;

  @override
  State<OperatorWebRouter> createState() => _OperatorWebRouterState();
}

class _OperatorWebRouterState extends State<OperatorWebRouter> {
  late OperatorWebAuthState _state;
  late StreamSubscription<OperatorWebAuthState> _subscription;
  late String _selectedNavId;
  bool _busy = false;
  bool _scrollMyAccountSecurityOnFirstBuild = false;
  late final _OperatorWebHandoffLanding? _handoffLanding;
  bool _handoffRedeemStarted = false;
  bool _handoffRedeemComplete = false;
  String? _handoffRedeemError;

  /// Sub-route name within the Roles surface. `null` means the list
  /// view (`/roles`); other values mirror the parity-contract paths
  /// `/roles/explainer` and `/roles/edit/:id`.
  String? _rolesSubRoute;

  /// Role being edited at `/roles/edit/:id`. `null` when the editor
  /// is mounted in create mode (`/roles/edit/new`).
  TeamRoleCatalogEntry? _rolesEditTarget;

  /// Bumps to force a fresh Roles list state when the editor returns.
  /// Drives a `ValueKey` on [RolesScreen] so the list reloads from
  /// the gateway after a create / patch / delete.
  int _rolesListSeq = 0;

  /// True when the Business setup nav slot should render the editor
  /// instead of the read view. Set by tapping the Edit button on the
  /// read view; cleared by the editor's back button.
  bool _editingBusinessTiming = false;

  List<OperatorWebManagementScopeOption> _managementScopeOptions =
      const <OperatorWebManagementScopeOption>[];
  String? _selectedManagementScopeKey;
  String? _managementScopeSessionKey;
  bool _managementScopeLoading = false;
  String? _managementScopeError;
  int _managementScopeGeneration = 0;

  /// Count of vendor connections in `status == error` for the current
  /// location scope. Drives the red attention chip on the Vendor
  /// integrations nav item so an operator who is not on the
  /// integrations screen still sees that a connection broke.
  /// `0` when no location scope is active or the gateway has not
  /// resolved yet.
  int _vendorOutageCount = 0;

  /// Key (`operatorId|locationId`) the current [_vendorOutageCount]
  /// reflects. Used to skip a refetch when the scope hasn't changed
  /// and to force one when it has.
  String? _vendorOutageCountKey;

  /// In-flight guard so a rebuild storm cannot stack overlapping
  /// fetches against the gateway.
  bool _vendorOutageFetching = false;

  @override
  void initState() {
    super.initState();
    _state = widget.source.current;
    final initialUri = widget.initialUri ?? _safeBaseUri();
    _handoffLanding = _OperatorWebHandoffLanding.parse(initialUri);
    final initialNavId = _handoffLanding?.navId ?? widget.initialNavId;
    final initialRoute = _OperatorWebInitialRoute.resolve(
      initialNavId: initialNavId,
      initialUri: initialUri,
    );
    _selectedNavId = initialRoute.navId;
    _scrollMyAccountSecurityOnFirstBuild =
        initialRoute.scrollMyAccountSecurityOnFirstBuild;
    _subscription = widget.source.stream.listen((next) {
      if (!mounted) return;
      setState(() => _state = next);
      _syncManagementScopesForState(next);
      _maybeStartHandoffRedeem();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncManagementScopesForState(_state);
      _maybeStartHandoffRedeem();
    });
  }

  @override
  void didUpdateWidget(covariant OperatorWebRouter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _subscription.cancel();
      _state = widget.source.current;
      _subscription = widget.source.stream.listen((next) {
        if (!mounted) return;
        setState(() => _state = next);
        _syncManagementScopesForState(next);
        _maybeStartHandoffRedeem();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _syncManagementScopesForState(_state);
        _maybeStartHandoffRedeem();
      });
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  void _maybeStartHandoffRedeem() {
    final landing = _handoffLanding;
    if (landing == null ||
        _handoffRedeemStarted ||
        _handoffRedeemComplete ||
        landing.code.isEmpty ||
        _state is! OperatorWebCompleted) {
      return;
    }
    final gateway = _handoffRedeemGateway;
    if (gateway == null) {
      setState(() {
        _handoffRedeemStarted = true;
        _handoffRedeemError =
            'Handoff is unavailable in this Operator Web build.';
      });
      return;
    }
    setState(() {
      _handoffRedeemStarted = true;
      _handoffRedeemError = null;
    });
    unawaited(_redeemHandoff(landing, gateway));
  }

  Future<void> _redeemHandoff(
    _OperatorWebHandoffLanding landing,
    OperatorWebHandoffRedeemGateway gateway,
  ) async {
    try {
      final redeemed = await gateway.redeemHandoffCode(code: landing.code);
      if (!mounted) return;
      final target = _handoffTargetFromPath(
        redeemed.targetPath,
        fallbackNavId: landing.navId,
      );
      setState(() {
        _selectedNavId = target.navId;
        _scrollMyAccountSecurityOnFirstBuild = target.scrollMyAccountSecurity;
        _editingBusinessTiming = target.editBusinessTiming;
        _handoffRedeemComplete = true;
        _handoffRedeemError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _handoffRedeemError = _handoffRedeemErrorText(error);
      });
    }
  }

  String _handoffRedeemErrorText(Object error) {
    if (error is OperatorWebHandoffRedeemRejected) {
      if (error.code == 'handoff_code_unusable') {
        return 'This handoff link has expired or was already used.';
      }
      if (error.code == 'wrong_operator') {
        return 'This handoff link belongs to a different business.';
      }
      if (error.code == 'no_id_token' || error.statusCode == 401) {
        return 'Sign in again to complete the handoff.';
      }
      return error.message;
    }
    return 'Could not complete the handoff. Please try again.';
  }

  Future<T> _withBusy<T>(Future<T> Function() task) async {
    setState(() => _busy = true);
    try {
      return await task();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _selectNav(String id) {
    if (id == _selectedNavId) {
      // Re-tap on Roles returns to the list view from a sub-route.
      if (id == kOperatorWebNavRoles && _rolesSubRoute != null) {
        setState(() {
          _rolesSubRoute = null;
          _rolesEditTarget = null;
        });
      }
      return;
    }
    setState(() {
      _selectedNavId = id;
      _scrollMyAccountSecurityOnFirstBuild = false;
      // Switching to a different top-level nav exits any roles
      // sub-route.
      if (id != kOperatorWebNavRoles) {
        _rolesSubRoute = null;
        _rolesEditTarget = null;
      }
      // Switching away from Business setup exits the timing editor
      // sub-view so the read view is what the operator sees on
      // re-enter.
      if (id != kOperatorWebNavBusinessSetup) {
        _editingBusinessTiming = false;
      }
    });
  }

  void _selectManagementScope(String key) {
    if (_selectedManagementScopeKey == key) return;
    setState(() {
      _selectedManagementScopeKey = key;
      // Changing scope while editing timing would make the write target
      // ambiguous, so return to the read view first.
      _editingBusinessTiming = false;
      // Wave 2 OW-4 — the Locations nav row only renders at business /
      // org-unit scope. If the operator drops into location scope while
      // standing on the Locations route, the body would mount but the
      // nav row would vanish, leaving an orphaned selection. Snap back
      // to the default nav so selection and visibility stay in sync.
      if (_selectedNavId == kOperatorWebNavLocations) {
        final picked = _scopeByKey(key);
        if (picked != null &&
            picked.kind == OperatorWebManagementScopeKind.location) {
          _selectedNavId = kOperatorWebDefaultNavId;
          _rolesSubRoute = null;
          _rolesEditTarget = null;
        }
      }
    });
  }

  OperatorWebManagementScopeOption? _scopeByKey(String key) {
    for (final option in _managementScopeOptions) {
      if (option.key == key) return option;
    }
    return null;
  }

  void _syncManagementScopesForState(OperatorWebAuthState state) {
    if (state is! OperatorWebCompleted) {
      if (_managementScopeOptions.isEmpty &&
          _managementScopeSessionKey == null &&
          !_managementScopeLoading) {
        return;
      }
      setState(() {
        _managementScopeOptions = const <OperatorWebManagementScopeOption>[];
        _selectedManagementScopeKey = null;
        _managementScopeSessionKey = null;
        _managementScopeLoading = false;
        _managementScopeError = null;
      });
      return;
    }
    final session = state.session;
    final sessionKey =
        '${session.uid}|${session.operatorId}|${session.primaryLocationId ?? ''}';
    if (_managementScopeSessionKey == sessionKey &&
        (_managementScopeOptions.isNotEmpty || _managementScopeLoading)) {
      return;
    }
    final fallback = _fallbackManagementScopeOptions(session);
    final generation = ++_managementScopeGeneration;
    _managementScopeSessionKey = sessionKey;
    setState(() {
      _managementScopeOptions = fallback;
      _selectedManagementScopeKey = _defaultManagementScopeKey(
        session,
        fallback,
      );
      _managementScopeLoading = true;
      _managementScopeError = null;
    });
    final gateway = _teamHierarchyGateway;
    unawaited(_loadManagementScopes(session, gateway, generation));
  }

  /// Refresh [_vendorOutageCount] from the connections gateway for the
  /// supplied (operatorId, locationId). Idempotent and best-effort — a
  /// gateway throw leaves the previous count in place and is swallowed
  /// (the dot is a hint, not a critical surface). Called from
  /// [_buildPostOnboardingShell] via a post-frame callback when the
  /// location scope changes; production triggers it once per scope
  /// switch.
  Future<void> _refreshVendorOutageCount({
    required String operatorId,
    required String locationId,
  }) async {
    if (_vendorOutageFetching) return;
    final key = '$operatorId|$locationId';
    final gateway = _vendorConnectionsGateway;
    if (gateway == null) return;
    _vendorOutageFetching = true;
    try {
      final bundle = await gateway.loadBundle(
        operatorId: operatorId,
        locationId: locationId,
      );
      if (!mounted) return;
      final errorRows = <VendorConnectionRow?>[
        bundle.posConnection,
        bundle.laborConnection,
        bundle.reservationConnection,
      ].where((row) => row?.status == VendorConnectionStatus.error).length;
      setState(() {
        _vendorOutageCount = errorRows;
        _vendorOutageCountKey = key;
      });
    } catch (_) {
      // Best-effort hint surface — leave the prior count and key in
      // place so a transient gateway error doesn't clear the dot.
      if (!mounted) return;
      _vendorOutageCountKey = key;
    } finally {
      _vendorOutageFetching = false;
    }
  }

  Future<void> _loadManagementScopes(
    OperatorWebSession session,
    WebTeamHierarchyGateway gateway,
    int generation,
  ) async {
    try {
      final result = await gateway.listOrgHierarchy(
        TeamOrgHierarchyListCommand(
          actorUserId: session.uid,
          operatorId: session.operatorId,
          locationId: session.primaryLocationId ?? '',
        ),
      );
      if (!mounted || generation != _managementScopeGeneration) return;
      final options = _managementScopeOptionsFromHierarchy(session, result);
      setState(() {
        _managementScopeOptions = options;
        if (!_hasManagementScopeKey(options, _selectedManagementScopeKey)) {
          _selectedManagementScopeKey = _defaultManagementScopeKey(
            session,
            options,
          );
        }
        _managementScopeLoading = false;
        _managementScopeError = null;
      });
    } catch (_) {
      if (!mounted || generation != _managementScopeGeneration) return;
      final fallback = _fallbackManagementScopeOptions(session);
      setState(() {
        _managementScopeOptions = fallback;
        if (!_hasManagementScopeKey(fallback, _selectedManagementScopeKey)) {
          _selectedManagementScopeKey = _defaultManagementScopeKey(
            session,
            fallback,
          );
        }
        _managementScopeLoading = false;
        _managementScopeError = 'Could not load the full location hierarchy.';
      });
    }
  }

  List<OperatorWebManagementScopeOption> _fallbackManagementScopeOptions(
    OperatorWebSession session,
  ) {
    final options = <OperatorWebManagementScopeOption>[
      _operatorScopeOption(session),
    ];
    final primaryLocationId = session.primaryLocationId;
    if (primaryLocationId != null && primaryLocationId.trim().isNotEmpty) {
      options.add(
        _locationScopeOption(
          locationId: primaryLocationId,
          label: session.primaryLocationName,
        ),
      );
    }
    return List<OperatorWebManagementScopeOption>.unmodifiable(options);
  }

  List<OperatorWebManagementScopeOption> _managementScopeOptionsFromHierarchy(
    OperatorWebSession session,
    TeamOrgHierarchyListed hierarchy,
  ) {
    final options = <OperatorWebManagementScopeOption>[
      _operatorScopeOption(session),
    ];
    final seenKeys = <String>{options.first.key};
    final orgUnits = hierarchy.orgUnits
        .where((unit) => unit.unitType != 'corp')
        .toList(growable: false);
    for (final unit in orgUnits) {
      final key = _scopeKey(
        OperatorWebManagementScopeKind.orgUnit,
        unit.orgUnitId,
      );
      if (!seenKeys.add(key)) continue;
      options.add(
        OperatorWebManagementScopeOption(
          key: key,
          kind: OperatorWebManagementScopeKind.orgUnit,
          id: unit.orgUnitId,
          label: unit.label,
          helper: _orgUnitHelper(unit.unitType),
          parentOrgUnitId: unit.parentOrgUnitId,
        ),
      );
    }
    for (final location in hierarchy.locations) {
      final key = _scopeKey(
        OperatorWebManagementScopeKind.location,
        location.locationId,
      );
      if (!seenKeys.add(key)) continue;
      options.add(
        _locationScopeOption(
          locationId: location.locationId,
          label: location.label,
          parentOrgUnitId: location.parentOrgUnitId,
        ),
      );
    }
    final primaryLocationId = session.primaryLocationId;
    final primaryKey = _scopeKey(
      OperatorWebManagementScopeKind.location,
      primaryLocationId ?? '',
    );
    if (!seenKeys.contains(primaryKey) &&
        primaryLocationId != null &&
        primaryLocationId.trim().isNotEmpty) {
      options.add(
        _locationScopeOption(
          locationId: primaryLocationId,
          label: session.primaryLocationName,
        ),
      );
    }
    return List<OperatorWebManagementScopeOption>.unmodifiable(options);
  }

  OperatorWebManagementScopeOption _operatorScopeOption(
    OperatorWebSession session,
  ) {
    return OperatorWebManagementScopeOption(
      key: _scopeKey(
        OperatorWebManagementScopeKind.operator,
        session.operatorId,
      ),
      kind: OperatorWebManagementScopeKind.operator,
      id: session.operatorId,
      label: 'All locations',
      helper: 'Business-wide',
    );
  }

  OperatorWebManagementScopeOption _locationScopeOption({
    required String locationId,
    required String label,
    String? parentOrgUnitId,
  }) {
    return OperatorWebManagementScopeOption(
      key: _scopeKey(OperatorWebManagementScopeKind.location, locationId),
      kind: OperatorWebManagementScopeKind.location,
      id: locationId,
      label: label.trim().isEmpty ? 'Unnamed location' : label.trim(),
      helper: 'Location',
      parentOrgUnitId: parentOrgUnitId,
    );
  }

  String _defaultManagementScopeKey(
    OperatorWebSession session,
    List<OperatorWebManagementScopeOption> options,
  ) {
    final primaryLocationId = session.primaryLocationId;
    if (primaryLocationId != null && primaryLocationId.trim().isNotEmpty) {
      final primaryKey = _scopeKey(
        OperatorWebManagementScopeKind.location,
        primaryLocationId,
      );
      if (_hasManagementScopeKey(options, primaryKey)) return primaryKey;
    }
    final firstLocation = options.where(
      (option) => option.kind == OperatorWebManagementScopeKind.location,
    );
    if (firstLocation.isNotEmpty) return firstLocation.first.key;
    return options.first.key;
  }

  bool _hasManagementScopeKey(
    List<OperatorWebManagementScopeOption> options,
    String? key,
  ) {
    if (key == null) return false;
    return options.any((option) => option.key == key);
  }

  OperatorWebManagementScopeOption _selectedManagementScope(
    OperatorWebSession session,
  ) {
    final selected = _selectedManagementScopeKey;
    if (selected != null) {
      for (final option in _managementScopeOptions) {
        if (option.key == selected) return option;
      }
    }
    final fallback = _fallbackManagementScopeOptions(session);
    return fallback.firstWhere(
      (option) => option.kind == OperatorWebManagementScopeKind.location,
      orElse: () => fallback.first,
    );
  }

  List<DemoTeamLocationFixture> _locationFixturesForMembers(
    OperatorWebSession session,
  ) {
    final locations = _managementScopeOptions
        .where(
          (option) => option.kind == OperatorWebManagementScopeKind.location,
        )
        .map(
          (option) => DemoTeamLocationFixture(
            locationId: option.id,
            name: option.label,
            orgUnitId: option.parentOrgUnitId ?? '',
          ),
        )
        .toList(growable: false);
    if (locations.isNotEmpty) {
      return List<DemoTeamLocationFixture>.unmodifiable(locations);
    }
    return <DemoTeamLocationFixture>[
      DemoTeamLocationFixture(
        locationId: session.primaryLocationId ?? '',
        name: session.primaryLocationName,
        orgUnitId: '',
      ),
    ];
  }

  static String _scopeKey(OperatorWebManagementScopeKind kind, String id) =>
      '${kind.name}:${id.trim()}';

  static String _orgUnitHelper(String unitType) {
    switch (unitType) {
      case 'region':
        return 'Region';
      case 'district':
        return 'District';
      case 'location_group':
        return 'Location group';
      default:
        return 'Group';
    }
  }

  void _openRolesExplainer() {
    setState(() {
      _selectedNavId = kOperatorWebNavRoles;
      _rolesSubRoute = kOperatorWebRolesExplainerPath;
      _rolesEditTarget = null;
    });
  }

  void _openRolesEditor(TeamRoleCatalogEntry? target) {
    setState(() {
      _selectedNavId = kOperatorWebNavRoles;
      _rolesSubRoute = kOperatorWebRolesEditPath;
      _rolesEditTarget = target;
    });
  }

  void _closeRolesSubRoute({bool reload = false}) {
    setState(() {
      _rolesSubRoute = null;
      _rolesEditTarget = null;
      if (reload) _rolesListSeq += 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return switch (state) {
      OperatorWebLoading() => const _LoadingSplash(),
      OperatorWebSignedOut() => _buildWelcome(state.lastErrorMessage),
      OperatorWebNeedsToken() => _buildWelcome(state.lastErrorMessage),
      OperatorWebNeedsSignIn(:final lastErrorMessage, :final lastInfoMessage) =>
        OperatorWebSignInScreen(
          onSignIn: ({required String email, required String password}) async {
            await _withBusy(
              () => widget.source.signInWithEmailPassword(
                email: email,
                password: password,
              ),
            );
          },
          onRequestPasswordReset: ({required String email}) async {
            await _withBusy(
              () => widget.source.requestPasswordReset(email: email),
            );
          },
          errorMessage: lastErrorMessage,
          infoMessage: lastInfoMessage,
          submitting: _busy,
        ),
      OperatorWebSignInMfaChallenge(
        :final email,
        :final factorIds,
        :final lastErrorMessage,
      ) =>
        OperatorWebSignInMfaChallengeScreen(
          email: email,
          factorIds: factorIds,
          onConfirm: ({required String oneTimeCode, String? factorId}) async {
            await _withBusy(
              () => widget.source.completeSignInMfaChallenge(
                oneTimeCode: oneTimeCode,
                factorId: factorId,
              ),
            );
          },
          errorMessage: lastErrorMessage,
          submitting: _busy,
        ),
      OperatorWebSettingPassword(:final lastErrorMessage) =>
        PasswordSetupScreen(
          onSubmitPassword:
              ({required String password, required String confirmation}) async {
                await _withBusy(
                  () => widget.source.submitPassword(
                    password: password,
                    confirmation: confirmation,
                  ),
                );
              },
          errorMessage: lastErrorMessage,
          submitting: _busy,
        ),
      OperatorWebEnrollingMfa(:final session, :final lastErrorMessage) =>
        MfaEnrollmentScreen(
          operatorEmail: session.email,
          onBeginEnrollment:
              ({required MfaFactorType factorType, String? phoneNumber}) async {
                return _withBusy(
                  () => widget.source.beginMfaEnrollment(
                    factorType: factorType,
                    phoneNumber: phoneNumber,
                  ),
                );
              },
          onConfirmEnrollment:
              ({
                required String enrollmentId,
                required String oneTimeCode,
              }) async {
                await _withBusy(
                  () => widget.source.confirmMfaEnrollment(
                    enrollmentId: enrollmentId,
                    oneTimeCode: oneTimeCode,
                  ),
                );
              },
          errorMessage: lastErrorMessage,
          submitting: _busy,
        ),
      OperatorWebAcceptingTos(
        :final session,
        :final tosVersion,
        :final tosBodyMarkdown,
        :final lastErrorMessage,
      ) =>
        TosAcceptScreen(
          session: session,
          tosVersion: tosVersion,
          tosBodyMarkdown: tosBodyMarkdown,
          onAccept: ({required String versionId, required String scope}) async {
            await _withBusy(
              () => widget.source.acceptTos(versionId: versionId, scope: scope),
            );
          },
          errorMessage: lastErrorMessage,
          submitting: _busy,
        ),
      OperatorWebForbidden(:final session) => _ForbiddenScreen(
        session: session,
        onSignOut: widget.source.signOut,
      ),
      OperatorWebCompleted(:final session) =>
        _handoffLanding != null && !_handoffRedeemComplete
            ? _HandoffLandingSurface(
                errorMessage: _handoffLanding.code.isEmpty
                    ? 'This handoff link is missing its code.'
                    : _handoffRedeemError,
                onSignOut: widget.source.signOut,
              )
            : _buildPostOnboardingShell(session),
    };
  }

  Widget _buildWelcome(String? error) {
    return WelcomeScreen(
      initialToken: widget.initialMagicLinkToken,
      errorMessage: error,
      submitting: _busy,
      onSubmitToken: (token) async {
        await _withBusy(() => widget.source.verifyMagicLinkToken(token));
      },
    );
  }

  Widget _buildPostOnboardingShell(OperatorWebSession session) {
    final managementScope = _selectedManagementScope(session);
    final locationScope =
        managementScope.kind == OperatorWebManagementScopeKind.location
        ? managementScope
        : null;
    // Wave 2 OW-4 — the Locations nav row mounts the per-operator
    // hierarchy CRUD (`HierarchyScreen`: add / rename / move org
    // units, attach locations as leaves). That surface only makes
    // sense at business or org-unit scope, where the operator can
    // see and edit the whole tree. At location scope the operator is
    // already inside a single leaf — there is no child to manage and
    // no sibling tree to render, so the row is hidden to keep the
    // side nav scope-honest per HP #11 (scope-conditional surfaces).
    // The `kOperatorWebNavLocations` constant + deep-link route stay
    // resolvable for handoff/back-compat; `_selectNav` snaps an
    // already-selected Locations route back to the default nav when
    // the operator drops into location scope.
    final isLocationScope = locationScope != null;

    // Vendor outage attention chip — refresh the count when the
    // location scope changes (or first becomes active). The fetch is
    // post-framed so we don't mutate state inside build; the chip
    // shows the previous count until the new one resolves. Clearing
    // the count when location scope goes away keeps the chip from
    // stale-rendering at business / org-unit scope where the Vendor
    // integrations row already shows a "Choose a location" body.
    final outageKey = locationScope == null
        ? null
        : '${session.operatorId}|${locationScope.id}';
    if (locationScope == null && _vendorOutageCount > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _vendorOutageCount = 0;
          _vendorOutageCountKey = null;
        });
      });
    } else if (locationScope != null && _vendorOutageCountKey != outageKey) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_refreshVendorOutageCount(
          operatorId: session.operatorId,
          locationId: locationScope.id,
        ));
      });
    }

    final navItems = <OperatorWebNavItem>[
      const OperatorWebNavItem(
        id: kOperatorWebNavSchedule,
        title: 'Schedule',
        icon: Icons.calendar_today_outlined,
        group: 'Operations',
      ),
      const OperatorWebNavItem(
        id: kOperatorWebNavAccount,
        title: 'Business account',
        icon: Icons.business_outlined,
        group: 'Business',
      ),
      const OperatorWebNavItem(
        id: kOperatorWebNavBusinessSetup,
        title: 'Business setup',
        icon: Icons.storefront_outlined,
        group: 'Business',
      ),
      // Per-Daypart Targets V1 / Slice 2 (Gap 35): the Benchmarks
      // override nav item was removed. Mobile Baseline Manager
      // star-shift selection is the only override path.
      if (!isLocationScope)
        const OperatorWebNavItem(
          id: kOperatorWebNavLocations,
          title: 'Locations',
          icon: Icons.account_tree_outlined,
          group: 'Business',
        ),
      const OperatorWebNavItem(
        id: kOperatorWebNavMyAccount,
        title: 'My account',
        icon: Icons.person_outline,
        group: 'People',
      ),
      const OperatorWebNavItem(
        id: kOperatorWebNavMembers,
        title: 'Team members',
        icon: Icons.group_outlined,
        group: 'People',
      ),
      const OperatorWebNavItem(
        id: kOperatorWebNavRoles,
        title: 'Roles & permissions',
        icon: Icons.admin_panel_settings_outlined,
        group: 'Access',
      ),
      const OperatorWebNavItem(
        id: kOperatorWebNavSessions,
        title: 'Active sessions',
        icon: Icons.devices_outlined,
        group: 'Access',
      ),
      const OperatorWebNavItem(
        id: kOperatorWebNavAuditLog,
        title: 'Audit log',
        icon: Icons.fact_check_outlined,
        group: 'Access',
      ),
      OperatorWebNavItem(
        id: kOperatorWebNavVendorConnections,
        title: 'Vendor integrations',
        icon: Icons.cable_outlined,
        group: 'Data & integrations',
        // Red chip when ≥1 connection on the current location is in
        // `status == error`. Only fires under location scope (the
        // Vendor integrations screen itself only mounts there); the
        // post-frame fetch above keeps the count fresh on scope switch.
        alertCount: locationScope == null ? 0 : _vendorOutageCount,
        alertTooltip: _vendorOutageCount == 0
            ? null
            : '${_vendorOutageCount} vendor ${_vendorOutageCount == 1 ? "connection is" : "connections are"} '
                'in an error state. Open Vendor integrations to reconnect.',
      ),
      const OperatorWebNavItem(
        id: kOperatorWebNavDataAccuracy,
        title: 'Data accuracy',
        icon: Icons.tune_outlined,
        group: 'Data & integrations',
      ),
      // Wave 2 S-2 (`debug.md:220`, OW-13c) — the standalone Wage
      // authority nav row is gone; the surface now folds under Data
      // accuracy. Deep links and the `kOperatorWebNavWageAuthority`
      // constant still resolve (via `_navIdFromRaw`) but redirect to
      // the Data accuracy page.
      const OperatorWebNavItem(
        id: kOperatorWebNavNotifications,
        title: 'Notifications',
        icon: Icons.notifications_outlined,
        group: 'People & access',
      ),
    ];
    final Widget body;
    switch (_selectedNavId) {
      case kOperatorWebNavMyAccount:
        body = MyAccountScreen(
          session: session,
          actions: _accountActions,
          securityGateway: _securityGateway,
          scrollToSecurityOnFirstBuild: _scrollMyAccountSecurityOnFirstBuild,
        );
        break;
      case kOperatorWebNavBusinessSetup:
        if (locationScope == null) {
          body = _RequiresLocationScopeSurface(
            key: const Key('operator_web_business_setup_requires_location'),
            icon: Icons.storefront_outlined,
            title: 'Choose a location',
            body:
                'Business setup reviews timing rules for one location at a '
                'time. Use Managing to pick a location before editing timing.',
            selectedScopeLabel: managementScope.label,
          );
        } else if (_editingBusinessTiming) {
          body = BusinessTimingEditorScreen(
            session: session,
            locationId: locationScope.id,
            locationName: locationScope.label,
            gateway: _webBusinessTimingGateway,
            existingProfile: _resolvedExistingTimingProfile(locationScope.id),
            onClose: () => setState(() => _editingBusinessTiming = false),
          );
        } else {
          body = BusinessSetupScreen(
            session: session,
            locationId: locationScope.id,
            locationName: locationScope.label,
            gateway: _businessTimingGateway,
            onEditTiming: _webBusinessTimingGateway != null
                ? () => setState(() => _editingBusinessTiming = true)
                : null,
          );
        }
        break;
      // Per-Daypart Targets V1 / Slice 2 (Gap 35): no Benchmarks
      // override route — surface cut entirely.
      case kOperatorWebNavMembers:
        body = MembersScreen(
          session: session,
          gateway: _teamUsersGateway,
          locationOptions: _locationFixturesForMembers(session),
        );
        break;
      case kOperatorWebNavRoles:
        body = _buildRolesBody(session);
        break;
      case kOperatorWebNavLocations:
        // Wave 2 OW-4 — the Locations nav row is hidden at location
        // scope; the route is only reachable via deep link from a
        // location-scoped session. Render a fail-soft surface that
        // points the operator at the scope picker so the route never
        // ends up rendering a CRUD-of-locations body inside a single
        // leaf scope.
        body = isLocationScope
            ? _RequiresBusinessScopeSurface(
                key: const Key('operator_web_locations_requires_business'),
                icon: Icons.account_tree_outlined,
                title: 'Switch to business scope',
                body:
                    'The Locations page edits your business-wide '
                    'hierarchy. Use Managing to pick All locations or a '
                    'region to add, rename, or move locations.',
                selectedScopeLabel: managementScope.label,
              )
            : HierarchyScreen(
                session: session,
                gateway: _teamHierarchyGateway,
              );
        break;
      case kOperatorWebNavSessions:
        body = SessionsScreen(
          session: session,
          gateway: _teamSessionsGateway,
          currentSessionId: _currentSessionId,
          onSignOut: widget.source.signOut,
        );
        break;
      case kOperatorWebNavAuditLog:
        body = AuditLogScreen(
          session: session,
          gateway: _teamAuditLogGateway,
          hierarchyGateway: _auditLogHierarchyGateway,
          teamHierarchyGateway: _teamHierarchyGateway,
        );
        break;
      case kOperatorWebNavVendorConnections:
        body = locationScope == null
            ? _RequiresLocationScopeSurface(
                key: const Key(
                  'operator_web_vendor_connections_requires_location',
                ),
                icon: Icons.cable_outlined,
                title: 'Choose a location',
                body:
                    'Vendor integrations are set up per location. Use '
                    'Managing to pick the location whose integrations you '
                    'want to manage.',
                selectedScopeLabel: managementScope.label,
              )
            : VendorConnectionsScreen(
                session: session,
                locationId: locationScope.id,
                locationName: locationScope.label,
                gateway: _vendorConnectionsGateway,
              );
        break;
      case kOperatorWebNavDataAccuracy:
        body = locationScope == null
            ? _RequiresLocationScopeSurface(
                key: const Key('operator_web_data_accuracy_requires_location'),
                icon: Icons.tune_outlined,
                title: 'Choose a location',
                body:
                    'Data accuracy rules are saved per location. Use '
                    'Managing to pick the location whose numbers you want '
                    'to configure.',
                selectedScopeLabel: managementScope.label,
              )
            : DataAccuracyScreen(
                session: session,
                locationId: locationScope.id,
                locationName: locationScope.label,
                dataAccuracyGateway: _dataAccuracyGateway,
                vendorApplicabilityGateway: _vendorApplicabilityGateway,
                // Wave 2 S-2 (`debug.md:220`, OW-13c) — the Wage
                // Authority section now mounts inside Data Accuracy.
                // Re-use the same gateway resolution the standalone
                // Wage Authority case below uses so the embedded
                // section saves through the live proxy when wired and
                // the in-memory demo gateway otherwise.
                wageAuthorityGateway:
                    _wageAuthorityGateway ??
                    (_routerOwnedDemoWageAuthorityGateway ??=
                        OperatorWebDemoWageAuthorityGateway()),
              );
        break;
      case kOperatorWebNavWageAuthority:
        body = locationScope == null
            ? _RequiresLocationScopeSurface(
                key: const Key('operator_web_wage_authority_requires_location'),
                icon: Icons.payments_outlined,
                title: 'Choose a location',
                body:
                    'Wage rows are saved per location. Use Managing to pick the '
                    'location whose wage mix you want to manage.',
                selectedScopeLabel: managementScope.label,
              )
            : WageAuthorityScreen(
                session: session,
                locationId: locationScope.id,
                locationName: locationScope.label,
                gateway:
                    _wageAuthorityGateway ??
                    (_routerOwnedDemoWageAuthorityGateway ??=
                        OperatorWebDemoWageAuthorityGateway()),
              );
        break;
      case kOperatorWebNavNotifications:
        body = SettingsNotificationsScreen(
          session: session,
          gateway: _notificationPreferencesGateway,
        );
        break;
      case kOperatorWebNavSchedule:
        body = locationScope == null
            ? _RequiresLocationScopeSurface(
                key: const Key('operator_web_schedule_requires_location'),
                icon: Icons.calendar_today_outlined,
                title: 'Choose a location',
                body:
                    'Forge & Flow locks one weekly plan per location. Use '
                    'Managing to pick the location whose schedule you want '
                    'to see.',
                selectedScopeLabel: managementScope.label,
              )
            : ScheduleScreen(
                session: session,
                locationId: locationScope.id,
                locationName: locationScope.label,
                gateway:
                    _scheduleGateway ??
                    (_routerOwnedDemoScheduleGateway ??=
                        OperatorWebDemoScheduleGateway(
                          seed: demoScheduleSnapshotFor(
                            operatorId: session.operatorId,
                            locationId: locationScope.id,
                            restaurantId: locationScope.id,
                          ),
                        )),
              );
        break;
      default:
        body = AccountScreen(
          session: session,
          gateway: _webAccountGateway,
          // Wave 2 U-FU-hp11-account — forward the shell's current
          // Managing scope so the screen can render the HP #11
          // Selected scope / Inherited from / Effective value triple
          // per card. At non-business scopes the screen reads the
          // business default + disables edits (no schema overrides
          // on file yet for region / business day / identity).
          selectedScope: managementScope,
        );
    }
    return WebAppShell(
      session: session,
      navItems: navItems,
      selectedNavId: _selectedNavId,
      onSelectNav: _selectNav,
      body: body,
      managementScopeOptions: _managementScopeOptions,
      selectedManagementScopeKey: _selectedManagementScopeKey,
      managementScopeLoading: _managementScopeLoading,
      managementScopeError: _managementScopeError,
      onSelectManagementScope: _selectManagementScope,
      onSignOut: () {
        widget.source.signOut();
      },
    );
  }

  Widget _buildRolesBody(OperatorWebSession session) {
    switch (_rolesSubRoute) {
      case kOperatorWebRolesExplainerPath:
        return PermissionExplainerScreen(
          key: const Key('operator_web_roles_explainer_route'),
          onClose: () => _closeRolesSubRoute(),
        );
      case kOperatorWebRolesEditPath:
        return CustomRoleEditorScreen(
          key: ValueKey(
            'operator_web_roles_editor_'
            '${_rolesEditTarget?.roleId ?? "new"}',
          ),
          session: session,
          gateway: _teamRolesGateway,
          existing: _rolesEditTarget,
          onSaved: (_) => _closeRolesSubRoute(reload: true),
          onClose: () => _closeRolesSubRoute(),
        );
      default:
        return RolesScreen(
          key: ValueKey('operator_web_roles_list_$_rolesListSeq'),
          session: session,
          gateway: _teamRolesGateway,
          onOpenExplainer: _openRolesExplainer,
          onOpenEditor: _openRolesEditor,
        );
    }
  }

  OperatorWebAccountActions? get _accountActions =>
      widget.source is OperatorWebAccountActions
      ? widget.source as OperatorWebAccountActions
      : null;

  WebAccountGateway? get _webAccountGateway =>
      widget.source is OperatorWebAccountGatewayProvider
      ? (widget.source as OperatorWebAccountGatewayProvider).accountGateway
      : null;

  OperatorWebHandoffRedeemGateway? get _handoffRedeemGateway =>
      widget.source is OperatorWebHandoffRedeemGatewayProvider
      ? (widget.source as OperatorWebHandoffRedeemGatewayProvider)
            .handoffRedeemGateway
      : null;

  WebBusinessTimingGateway? get _webBusinessTimingGateway =>
      widget.source is OperatorWebBusinessTimingWriteGatewayProvider
      ? (widget.source as OperatorWebBusinessTimingWriteGatewayProvider)
            .businessTimingWriteGateway
      : null;

  OperatorWebDataAccuracyGateway? get _dataAccuracyGateway =>
      widget.source is OperatorWebDataAccuracyGatewayProvider
      ? (widget.source as OperatorWebDataAccuracyGatewayProvider)
            .dataAccuracyGateway
      : null;

  WebVendorApplicabilityGateway? get _vendorApplicabilityGateway =>
      widget.source is OperatorWebVendorApplicabilityGatewayProvider
      ? (widget.source as OperatorWebVendorApplicabilityGatewayProvider)
            .vendorApplicabilityGateway
      : null;

  // Per-Daypart Targets V1 / Slice 2 (Gap 35): the `_benchmarksGateway`
  // getter was removed along with the operator-web Benchmarks override
  // surface. Mobile Baseline Manager star-shift selection is the only
  // override path.

  /// Lane B B8.b — operator-web hierarchy-filtered audit-log gateway.
  /// Live wiring mixes [OperatorWebAuditLogHierarchyGatewayProvider]
  /// onto the auth source (small follow-up); demo / unmixed sources
  /// fall back to [InMemoryWebAuditLogHierarchyGateway] so the pane
  /// renders deterministically during the walkthrough. The screen
  /// gates the pane on BOTH this gateway AND `_teamHierarchyGateway`
  /// being non-null, so this getter is the only required wire site.
  WebAuditLogHierarchyGateway get _auditLogHierarchyGateway {
    final source = widget.source;
    if (source is OperatorWebAuditLogHierarchyGatewayProvider) {
      return (source as OperatorWebAuditLogHierarchyGatewayProvider)
          .auditLogHierarchyGateway;
    }
    return _routerOwnedDemoAuditLogHierarchyGateway ??=
        InMemoryWebAuditLogHierarchyGateway();
  }

  /// Resolver for the Vendor connections screen gateway. Lifts
  /// gateway resolution off the router so the screen mount stays
  /// thin and the wiring is testable in isolation. See
  /// `services/operator_web_vendor_connections_resolver.dart`.
  static const OperatorWebVendorConnectionsResolver _vendorConnectionsResolver =
      OperatorWebVendorConnectionsResolver();

  /// Live HTTP gateway when the auth source surfaces one; otherwise
  /// the seeded demo fallback (Slice E) so the demo / walkthrough
  /// build renders mixed per-(operator, location, category) vendor
  /// state instead of an empty catalog. Production live builds always
  /// resolve the HTTP gateway, so the `?? demoFallback()` arm is
  /// demo-only — no production behavior change.
  VendorConnectionsGateway? get _vendorConnectionsGateway =>
      _vendorConnectionsResolver.resolve(widget.source) ??
      _vendorConnectionsResolver.demoFallback();

  WebTeamUsersGateway get _teamUsersGateway {
    final source = widget.source;
    if (source is OperatorWebTeamUsersGatewayProvider) {
      return (source as OperatorWebTeamUsersGatewayProvider).teamUsersGateway;
    }
    // Live source without a gateway mixin still gets a working
    // surface for the slice walkthrough; the `11W.1.live` follow-up
    // mixes the live HTTP gateway in via
    // `OperatorWebTeamUsersGatewayProvider`.
    return _routerOwnedDemoGateway ??= DemoWebTeamUsersGateway();
  }

  BusinessTimingGateway get _businessTimingGateway {
    final source = widget.source;
    if (source is OperatorWebBusinessTimingGatewayProvider) {
      return (source as OperatorWebBusinessTimingGatewayProvider)
          .businessTimingGateway;
    }
    return _routerOwnedTimingGateway ??= const DemoBusinessTimingGateway();
  }

  /// Doc 1 timing web/admin live parity (2026-05-08): when the live
  /// read gateway has already loaded the operator's profile list, hand
  /// the resolved profile (location override if present, otherwise the
  /// operator default) to the editor so it edits in place instead of
  /// defaulting to a brand-new profile. Returns `null` when no profiles
  /// exist yet so the editor can still mount in create mode.
  BusinessTimingProfileWriteResult? _resolvedExistingTimingProfile(
    String locationId,
  ) {
    final gateway = _businessTimingGateway;
    if (gateway is HttpBusinessTimingReadGateway) {
      return gateway.selectProfileForLocation(locationId);
    }
    return null;
  }

  WebTeamRolesGateway get _teamRolesGateway {
    final source = widget.source;
    if (source is OperatorWebTeamRolesGatewayProvider) {
      return (source as OperatorWebTeamRolesGatewayProvider).teamRolesGateway;
    }
    // Live source without a gateway mixin still gets a working
    // surface for the slice walkthrough; the `11W.2.live` follow-up
    // mixes the live HTTP gateway in via
    // `OperatorWebTeamRolesGatewayProvider`.
    return _routerOwnedDemoRolesGateway ??= DemoWebTeamRolesGateway();
  }

  DemoWebTeamUsersGateway? _routerOwnedDemoGateway;
  BusinessTimingGateway? _routerOwnedTimingGateway;
  DemoWebTeamRolesGateway? _routerOwnedDemoRolesGateway;
  // _routerOwnedDemoBenchmarksGateway removed — operator-web Benchmarks
  // override surface cut (Per-Daypart Targets V1 / Slice 2, Gap 35).
  InMemoryWebAuditLogHierarchyGateway?
      _routerOwnedDemoAuditLogHierarchyGateway;

  WebTeamHierarchyGateway get _teamHierarchyGateway {
    final source = widget.source;
    if (source is OperatorWebTeamHierarchyGatewayProvider) {
      return (source as OperatorWebTeamHierarchyGatewayProvider)
          .teamHierarchyGateway;
    }
    // Live source without a gateway mixin still gets a working
    // surface for the slice walkthrough; the `11W.3.live` follow-up
    // mixes the live HTTP gateway in via
    // `OperatorWebTeamHierarchyGatewayProvider`.
    return _routerOwnedDemoHierarchyGateway ??= DemoWebTeamHierarchyGateway();
  }

  DemoWebTeamHierarchyGateway? _routerOwnedDemoHierarchyGateway;

  WebTeamSessionsGateway get _teamSessionsGateway {
    final source = widget.source;
    if (source is OperatorWebTeamSessionsGatewayProvider) {
      return (source as OperatorWebTeamSessionsGatewayProvider)
          .teamSessionsGateway;
    }
    // Live source without a gateway mixin still gets a working
    // surface for the slice walkthrough; the `11W.4.live` follow-up
    // mixes the live HTTP gateway in via
    // `OperatorWebTeamSessionsGatewayProvider`.
    return _routerOwnedSessionsGateway ??= DemoWebTeamSessionsGateway();
  }

  DemoWebTeamSessionsGateway? _routerOwnedSessionsGateway;

  WebTeamAuditLogGateway get _teamAuditLogGateway {
    final source = widget.source;
    if (source is OperatorWebTeamAuditLogGatewayProvider) {
      return (source as OperatorWebTeamAuditLogGatewayProvider)
          .teamAuditLogGateway;
    }
    // Live source without a gateway mixin still gets a working
    // surface for the slice walkthrough; the `11W.5.live` follow-up
    // mixes the live HTTP gateway in via
    // `OperatorWebTeamAuditLogGatewayProvider`.
    return _routerOwnedAuditLogGateway ??= DemoWebTeamAuditLogGateway();
  }

  DemoWebTeamAuditLogGateway? _routerOwnedAuditLogGateway;

  WebSecurityGateway get _securityGateway {
    final source = widget.source;
    if (source is OperatorWebSecurityGatewayProvider) {
      return (source as OperatorWebSecurityGatewayProvider).securityGateway;
    }
    // Live source without a gateway mixin still gets a working
    // surface for the slice walkthrough; the `11W.6.live` follow-up
    // mixes the live HTTP gateway in via
    // `OperatorWebSecurityGatewayProvider`.
    return _routerOwnedSecurityGateway ??= DemoWebSecurityGateway();
  }

  DemoWebSecurityGateway? _routerOwnedSecurityGateway;

  /// Phase 8 W2.B - per-actor notification preferences gateway.
  /// Returns the live gateway when the auth source mixes in the
  /// provider; otherwise falls back to the in-memory demo gateway so
  /// the screen renders + toggles end-to-end without a live proxy.
  WebNotificationPreferencesGateway? get _notificationPreferencesGateway {
    final source = widget.source;
    if (source is OperatorWebNotificationPreferencesGatewayProvider) {
      return (source as OperatorWebNotificationPreferencesGatewayProvider)
          .notificationPreferencesGateway;
    }
    return _routerOwnedNotificationPreferencesGateway ??=
        DemoWebNotificationPreferencesGateway();
  }

  DemoWebNotificationPreferencesGateway?
  _routerOwnedNotificationPreferencesGateway;

  /// Phase 8 W5.A.2 - Wage authority screen gateway. Live wiring (the
  /// Firebase source plus the proxy) implements the provider mixin;
  /// demo / fixture sources fall back to the in-memory demo gateway
  /// owned by the router so the walkthrough renders + edits end-to-end
  /// without a live proxy.
  OperatorWebWageAuthorityGateway? get _wageAuthorityGateway {
    final source = widget.source;
    if (source is OperatorWebWageAuthorityGatewayProvider) {
      return (source as OperatorWebWageAuthorityGatewayProvider)
          .wageAuthorityGateway;
    }
    return null;
  }

  OperatorWebDemoWageAuthorityGateway? _routerOwnedDemoWageAuthorityGateway;

  /// Phase 8 W5.B - Schedule screen gateway. Live wiring (Firebase
  /// source + proxy) implements the provider mixin; demo / fixture
  /// sources fall back to the in-memory demo gateway owned by the
  /// router so the walkthrough renders without a live proxy.
  OperatorWebScheduleGateway? get _scheduleGateway {
    final source = widget.source;
    if (source is OperatorWebScheduleGatewayProvider) {
      return (source as OperatorWebScheduleGatewayProvider).scheduleGateway;
    }
    return null;
  }

  OperatorWebDemoScheduleGateway? _routerOwnedDemoScheduleGateway;

  String? get _currentSessionId {
    final source = widget.source;
    if (source is OperatorWebTeamSessionsGatewayProvider) {
      return (source as OperatorWebTeamSessionsGatewayProvider)
          .currentSessionId;
    }
    return null;
  }
}

class _RequiresLocationScopeSurface extends StatelessWidget {
  const _RequiresLocationScopeSurface({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.selectedScopeLabel,
  });

  final IconData icon;
  final String title;
  final String body;
  final String selectedScopeLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 22, color: AppColors.sunsetDark),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                body,
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: AppColors.cardGlow,
                  border: Border.all(color: AppColors.borderSubtle, width: 1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.account_tree_outlined,
                      size: 16,
                      color: AppColors.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Currently managing: $selectedScopeLabel',
                        style: AppTextStyles.body13(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wave 2 OW-4 — fail-soft surface for routes that only render at
/// business / org-unit scope. Mirrors [_RequiresLocationScopeSurface]
/// but inverts the prompt: it tells the operator to widen the scope
/// picker rather than narrow it. Currently used by the Locations
/// route, which the side nav hides at location scope but which deep
/// links can still resolve.
class _RequiresBusinessScopeSurface extends StatelessWidget {
  const _RequiresBusinessScopeSurface({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.selectedScopeLabel,
  });

  final IconData icon;
  final String title;
  final String body;
  final String selectedScopeLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 22, color: AppColors.sunsetDark),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                body,
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: AppColors.cardGlow,
                  border: Border.all(color: AppColors.borderSubtle, width: 1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.account_tree_outlined,
                      size: 16,
                      color: AppColors.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Currently managing: $selectedScopeLabel',
                        style: AppTextStyles.body13(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingSplash extends StatelessWidget {
  const _LoadingSplash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      body: Center(
        child: SizedBox(
          width: 36,
          height: 36,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sunsetDark,
          ),
        ),
      ),
    );
  }
}

class _HandoffLandingSurface extends StatelessWidget {
  const _HandoffLandingSurface({
    required this.errorMessage,
    required this.onSignOut,
  });

  final String? errorMessage;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    final error = errorMessage;
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Container(
                key: const Key('operator_web_handoff_landing_surface'),
                decoration: BoxDecoration(
                  color: AppColors.backgroundSurface,
                  border: Border.all(color: AppColors.borderSubtle, width: 1),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(
                          error == null
                              ? Icons.open_in_new_rounded
                              : Icons.link_off_rounded,
                          size: 18,
                          color: error == null
                              ? AppColors.sunsetDark
                              : AppColors.negative,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            error == null
                                ? 'Opening Operator Web'
                                : 'Handoff link unavailable',
                            style: AppTextStyles.mono15(
                              color: AppColors.textPrimary,
                              weight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    if (error == null)
                      Row(
                        children: [
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Redeeming the one-time handoff code.',
                              style: AppTextStyles.body13(
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      )
                    else ...[
                      Text(
                        error,
                        style: AppTextStyles.body13(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        height: 42,
                        child: OutlinedButton(
                          key: const Key('operator_web_handoff_signout'),
                          onPressed: () => onSignOut(),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.sunsetDark,
                            side: const BorderSide(
                              color: AppColors.sunsetDark,
                              width: 1,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          child: const Text('Sign out'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ForbiddenScreen extends StatelessWidget {
  const _ForbiddenScreen({required this.session, required this.onSignOut});

  final OperatorWebSession session;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ClipRRect(
                key: const Key('operator_web_forbidden_card'),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.backgroundSurface,
                    border: Border.all(color: AppColors.borderSubtle, width: 1),
                  ),
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.lock_outline,
                            size: 18,
                            color: AppColors.negative,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Operator web access not available',
                              style: AppTextStyles.mono15(
                                color: AppColors.textPrimary,
                                weight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Signed in as '
                        '${session.email.isEmpty ? session.uid : session.email}, '
                        'but the Forge & Flow Operator Web Console is for '
                        'operator owners, operator admins, and location '
                        'managers. Floor staff and other roles can keep '
                        'using the Forge & Flow mobile app — most '
                        'day-to-day actions live there.',
                        style: AppTextStyles.body13(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        height: 42,
                        child: OutlinedButton(
                          key: const Key('operator_web_forbidden_signout'),
                          onPressed: () => onSignOut(),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.sunsetDark,
                            side: const BorderSide(
                              color: AppColors.sunsetDark,
                              width: 1,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          child: const Text('Sign out'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
