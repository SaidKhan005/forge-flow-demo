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
import '../../services/auth/auth_operations_gateway.dart';
import '../auth/operator_web_auth_source.dart';
import '../account/operator_web_account_actions.dart';
import '../services/demo_team_audit_log_gateway.dart';
import '../services/demo_team_hierarchy_gateway.dart';
import '../services/demo_team_roles_gateway.dart';
import '../services/demo_team_sessions_gateway.dart';
import '../services/demo_team_users_gateway.dart';
import '../services/operator_web_vendor_connections_gateway.dart';
import '../services/web_team_audit_log_gateway.dart';
import '../services/web_team_hierarchy_gateway.dart';
import '../services/web_team_roles_gateway.dart';
import '../services/web_team_sessions_gateway.dart';
import '../services/web_team_users_gateway.dart';
import '../screens/account_screen.dart';
import '../screens/audit_log_screen.dart';
import '../screens/custom_role_editor_screen.dart';
import '../screens/data_accuracy_screen.dart';
import '../screens/hierarchy_screen.dart';
import '../screens/members_screen.dart';
import '../screens/mfa_enrollment_screen.dart';
import '../screens/password_setup_screen.dart';
import '../screens/permission_explainer_screen.dart';
import '../screens/roles_screen.dart';
import '../screens/sessions_screen.dart';
import '../screens/sign_in_screen.dart';
import '../screens/tos_accept_screen.dart';
import '../screens/vendor_connections_screen.dart';
import '../screens/welcome_screen.dart';
import '../widgets/web_app_shell.dart';
import '../../theme/app_theme.dart';

/// Stable nav ids for the post-onboarding shell. Tests and deep
/// links key off these.
const String kOperatorWebNavAccount = 'account';
const String kOperatorWebNavMembers = 'members';
const String kOperatorWebNavRoles = 'roles';
const String kOperatorWebNavLocations = 'locations';
const String kOperatorWebNavSessions = 'sessions';
const String kOperatorWebNavAuditLog = 'audit_log';
const String kOperatorWebNavVendorConnections = 'vendor_connections';
const String kOperatorWebNavDataAccuracy = 'data_accuracy';

/// Sub-route names mounted under the Roles nav surface. The router
/// keeps a small state machine here rather than registering full
/// `MaterialPageRoute` entries because the operator-web shell is a
/// single-Navigator shell; the names mirror the parity-contract paths
/// so `/roles`, `/roles/explainer`, and `/roles/edit/:id` line up
/// with the URL bar once URL synchronization lands in a follow-up.
const String kOperatorWebRolesPath = '/roles';
const String kOperatorWebRolesExplainerPath = '/roles/explainer';
const String kOperatorWebRolesEditPath = '/roles/edit';

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply a [WebTeamUsersGateway] for the Members surface. Demo
/// auth source mixes this in with [DemoWebTeamUsersGateway];
/// `11W.1.live` will mix it in on the live source with the
/// `package:http` impl.
abstract class OperatorWebTeamUsersGatewayProvider {
  WebTeamUsersGateway get teamUsersGateway;
}

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply a [WebTeamRolesGateway] for the Roles surface. Demo
/// auth source mixes this in with [DemoWebTeamRolesGateway];
/// `11W.2.live` will mix it in on the live source with the
/// `package:http` impl.
abstract class OperatorWebTeamRolesGatewayProvider {
  WebTeamRolesGateway get teamRolesGateway;
}

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply a [WebTeamHierarchyGateway] for the `/locations`
/// surface. Demo auth source mixes this in with
/// [DemoWebTeamHierarchyGateway]; `11W.3.live` will mix it in on the
/// live source with the `package:http` impl.
abstract class OperatorWebTeamHierarchyGatewayProvider {
  WebTeamHierarchyGateway get teamHierarchyGateway;
}

/// Sentinel the operator-web shell stamps on the auth source when it
/// can supply a [WebTeamSessionsGateway] for the Sessions surface.
/// Demo auth source mixes this in with [DemoWebTeamSessionsGateway];
/// `11W.4.live` will mix it in on the live source with the
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
/// Demo auth source mixes this in with [DemoWebTeamAuditLogGateway];
/// `11W.5.live` will mix it in on the live source with the
/// `package:http` impl.
abstract class OperatorWebTeamAuditLogGatewayProvider {
  WebTeamAuditLogGateway get teamAuditLogGateway;
}

/// Default nav surface the shell lands on after onboarding completes.
const String kOperatorWebDefaultNavId = kOperatorWebNavAccount;

/// Top-level router widget for the operator-web console. Drop in
/// under a `MaterialApp` with the brand theme.
class OperatorWebRouter extends StatefulWidget {
  const OperatorWebRouter({
    super.key,
    required this.source,
    this.initialMagicLinkToken,
    this.initialNavId = kOperatorWebDefaultNavId,
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

  @override
  State<OperatorWebRouter> createState() => _OperatorWebRouterState();
}

class _OperatorWebRouterState extends State<OperatorWebRouter> {
  late OperatorWebAuthState _state;
  late StreamSubscription<OperatorWebAuthState> _subscription;
  late String _selectedNavId;
  bool _busy = false;

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

  @override
  void initState() {
    super.initState();
    _state = widget.source.current;
    _selectedNavId = widget.initialNavId;
    _subscription = widget.source.stream.listen((next) {
      if (!mounted) return;
      setState(() => _state = next);
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
      });
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
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
      // Switching to a different top-level nav exits any roles
      // sub-route.
      if (id != kOperatorWebNavRoles) {
        _rolesSubRoute = null;
        _rolesEditTarget = null;
      }
    });
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
      OperatorWebCompleted(:final session) => _buildPostOnboardingShell(
        session,
      ),
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
    final navItems = const <OperatorWebNavItem>[
      OperatorWebNavItem(
        id: kOperatorWebNavAccount,
        title: 'Account',
        icon: Icons.business_outlined,
      ),
      OperatorWebNavItem(
        id: kOperatorWebNavMembers,
        title: 'Members',
        icon: Icons.group_outlined,
      ),
      OperatorWebNavItem(
        id: kOperatorWebNavRoles,
        title: 'Roles',
        icon: Icons.shield_outlined,
      ),
      OperatorWebNavItem(
        id: kOperatorWebNavLocations,
        title: 'Locations',
        icon: Icons.account_tree_outlined,
      ),
      OperatorWebNavItem(
        id: kOperatorWebNavSessions,
        title: 'Sessions',
        icon: Icons.devices_outlined,
      ),
      OperatorWebNavItem(
        id: kOperatorWebNavAuditLog,
        title: 'Audit log',
        icon: Icons.fact_check_outlined,
      ),
      OperatorWebNavItem(
        id: kOperatorWebNavVendorConnections,
        title: 'Vendor connections',
        icon: Icons.cable_outlined,
      ),
      OperatorWebNavItem(
        id: kOperatorWebNavDataAccuracy,
        title: 'Data accuracy',
        icon: Icons.tune_outlined,
      ),
    ];
    final Widget body;
    switch (_selectedNavId) {
      case kOperatorWebNavMembers:
        body = MembersScreen(
          session: session,
          gateway: _teamUsersGateway,
        );
        break;
      case kOperatorWebNavRoles:
        body = _buildRolesBody(session);
        break;
      case kOperatorWebNavLocations:
        body = HierarchyScreen(
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
        );
        break;
      case kOperatorWebNavVendorConnections:
        body = VendorConnectionsScreen(
          session: session,
          locationId: session.primaryLocationId,
          gateway: _vendorConnectionsGateway,
        );
        break;
      case kOperatorWebNavDataAccuracy:
        body = DataAccuracyScreen(
          session: session,
          locationId: session.primaryLocationId,
        );
        break;
      default:
        body = AccountScreen(session: session, actions: _accountActions);
    }
    return WebAppShell(
      session: session,
      navItems: navItems,
      selectedNavId: _selectedNavId,
      onSelectNav: _selectNav,
      body: body,
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

  VendorConnectionsGateway? get _vendorConnectionsGateway =>
      widget.source is OperatorWebVendorConnectionsGatewayProvider
      ? (widget.source as OperatorWebVendorConnectionsGatewayProvider)
            .vendorConnectionsGateway
      : null;

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
  DemoWebTeamRolesGateway? _routerOwnedDemoRolesGateway;

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

  String? get _currentSessionId {
    final source = widget.source;
    if (source is OperatorWebTeamSessionsGatewayProvider) {
      return (source as OperatorWebTeamSessionsGatewayProvider)
          .currentSessionId;
    }
    return null;
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
