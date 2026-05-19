import 'package:flutter/material.dart';
import 'dart:convert';

import 'package:provider/provider.dart';

import '../auth/auth_session.dart';
import '../auth/permission_keys.dart';
import '../models/app_data_status.dart';
import '../services/app_data_status_service.dart';
import '../services/auth/account_info_gateway.dart';
import '../services/auth/auth_operations_gateway.dart';
import '../services/auth/handoff_code_gateway.dart';
import '../services/auth/password_change_gateway.dart';
import '../services/manual_covers_write_service.dart';
import '../services/mfa/mfa_operations_gateway.dart';
import '../services/shift_service.dart';
import '../services/sync/sync_proxy_client.dart';
import '../state/app_refresh_coordinator.dart';
import '../state/auth_session_notifier.dart';
import '../state/permission_context.dart';
import '../state/restaurant_scope_notifier.dart';
import '../services/team/team_scope_visibility_policy.dart';
import '../theme/app_theme.dart';
import '../widgets/operator_brand_mark.dart';
import '../widgets/sticky_section_delegate.dart';
import 'settings/settings_active_sessions_section.dart';
import 'settings/settings_covers_setup_section.dart';
import 'settings/settings_data_sections.dart';
import 'settings/settings_integrations_section.dart';
import 'settings/settings_mfa_section.dart';
import 'settings/settings_pointer_row.dart';
import 'settings/settings_timing_authority_section.dart';
import 'settings/settings_wage_authority_section.dart';

/// W3.A (amended 2026-05-17, operator-directed) â€” mobile Settings is a
/// 3-tab mirror of the operator web console, read-only EXCEPT the
/// Account tab's "Two-factor sign-in" and "Account" sections, which run
/// interactively on mobile (native sign-out + 2FA enroll/QR); see the
/// section-level comments in the Account tab build below. `kDemoMode`
/// toggles demo-only rows (Data reset + Demo date) without changing the
/// production layout. Defined as a top-level const so widget tests can
/// flip it via `--dart-define`.
//
// kDemoMode carve-out #3 (blessed 2026-05-08): the two demo-only
// management sections gated below ("Data reset" at line 374, "Demo
// date" at line 383) have no production analogue. A "Demo date" picker
// in prod would let an operator move the restaurant clock backward and
// corrupt closed truth; a "Data reset" button in prod would bypass the
// audit-anchored data-deletion path. Hiding them is the lower-risk
// choice. See docs/contracts/demo_mode_contract.md "Carve-out #3".
const bool _kDemoMode = bool.fromEnvironment('kDemoMode');

class SettingsScreen extends StatefulWidget {
  /// Optional injected status for testability. When null, loads from service.
  final AppDataStatus? initialStatus;

  /// Optional injected mock replay date for testability.
  final String? initialMockDate;

  /// Team Settings actor snapshot. Production passes this once the
  /// Phase 9 permission snapshot bridge carries role + location scope.
  /// Null means the admin tabs stay visible to everyone (legacy /
  /// demo / unauth flows).
  final TeamScopeActor? teamActor;

  final AccountInfoGateway? accountInfoGateway;
  final PasswordChangeGateway? passwordChangeGateway;
  final MfaOperationsGateway? mfaOperationsGateway;
  final MfaActorContext? mfaActor;
  final HandoffCodeGateway? handoffCodeGateway;

  /// Phase 9.UX.5 â€” self-service Active Sessions surface in the
  /// Account tab. Production passes the proxy-backed gateway; demo /
  /// preview shells set [allowDemoActiveSessionsFallback] so the
  /// walkthrough click path completes without a backend.
  final AuthOperationsGateway? authOperationsGateway;
  final ActiveSessionsActor? activeSessionsActor;
  final bool allowDemoActiveSessionsFallback;

  /// Demo / preview shells wire no [accountInfoGateway]. When true,
  /// the Account section renders the honest session-derived card
  /// instead of collapsing to nothing, so the demo Account tab shows
  /// the real signed-in identity. Mirrors
  /// [allowDemoActiveSessionsFallback]; threaded from
  /// `forge_flow_app.dart` `_openSettings`.
  final bool allowDemoAccountInfoFallback;

  const SettingsScreen({
    super.key,
    this.initialStatus,
    this.initialMockDate,
    this.teamActor,
    this.accountInfoGateway,
    this.passwordChangeGateway,
    this.mfaOperationsGateway,
    this.mfaActor,
    this.handoffCodeGateway,
    this.authOperationsGateway,
    this.activeSessionsActor,
    this.allowDemoActiveSessionsFallback = false,
    this.allowDemoAccountInfoFallback = false,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppDataStatus? _status;
  String? _mockReplayDate;
  int _manualRefreshGeneration = 0;
  bool _manualRefreshing = false;
  bool _routeSawAuthenticatedSession = false;
  bool _authDismissScheduled = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialStatus != null) {
      _status = widget.initialStatus;
    } else {
      _loadStatus();
    }
    if (widget.initialMockDate != null) {
      _mockReplayDate = widget.initialMockDate;
    } else {
      _loadMockDate();
    }
  }

  Future<void> _loadStatus() async {
    final status = await AppDataStatusService.instance.evaluate();
    if (mounted) setState(() => _status = status);
  }

  Future<void> _loadMockDate() async {
    final date = await ShiftService.instance.getMockReplayBusinessDate();
    if (mounted) setState(() => _mockReplayDate = date);
  }

  /// Full refresh after actions that do NOT fire the runtime invalidation
  /// bus (e.g., wage changes). Target cascade handles current-state.
  Future<void> _refreshAppState() async {
    // Use State.mounted, not context.mounted: reading `State.context`
    // on a defunct State throws "defunct". The State `mounted` getter
    // is the non-throwing guard when the caller awaited a long write
    // and this widget unmounted/rebuilt in the interim.
    if (!mounted) return;
    try {
      context.read<AppRefreshCoordinator>().refreshAll();
    } catch (_) {
      // Coordinator may not be in scope during widget tests.
    }
    await _loadStatus();
    await _loadMockDate();
  }

  Future<void> _handlePullToRefresh() async {
    if (_manualRefreshing) return;
    setState(() {
      _manualRefreshing = true;
      _manualRefreshGeneration += 1;
    });
    try {
      await _refreshAppState();
    } finally {
      if (mounted) setState(() => _manualRefreshing = false);
    }
  }

  /// Refresh after writes that fire the runtime invalidation bus.
  /// The bus already refreshed current-state surfaces (week, shift).
  /// This refreshes supporting surfaces and local labels only.
  Future<void> _refreshAfterWrite() async {
    // Use State.mounted, not context.mounted: the data-action closures
    // in settings_data_sections.dart `await` a long write (reseed /
    // date-advance / clear) and then call back here. If this widget
    // unmounted during that await, reading `State.context` would throw
    // "defunct" (the captured crash at this line). `State.mounted` is
    // the non-throwing guard; an unmounted callback becomes a clean
    // no-op. `_loadStatus`/`_loadMockDate` re-check `mounted` before
    // their own `setState`, so the post-await path stays safe too.
    if (!mounted) return;
    try {
      context.read<AppRefreshCoordinator>().refreshAfterWrite();
    } catch (_) {
      // Coordinator may not be in scope during widget tests.
    }
    await _loadStatus();
    await _loadMockDate();
  }

  @override
  Widget build(BuildContext context) {
    final restaurant = context.watch<RestaurantScopeNotifier?>()?.restaurant;
    final authNotifier = context.watch<AuthSessionNotifier?>();
    if (_dismissRouteAfterSignOut(authNotifier)) {
      return const SizedBox.shrink();
    }
    final session = authNotifier?.session;
    final showAccount = session != null;
    final syncProxyClient = _syncProxyClientFromContext(context);
    final manualCoversWriteActions = _manualCoversWriteActionsFor(
      session: session,
      syncProxyClient: syncProxyClient,
    );
    // MO-1 — read the production permission snapshot (when wired by
    // AuthPermissionContextBridge). `listen: true` so a session-driven
    // re-load of the snapshot re-runs the Data tab gate without
    // requiring the user to re-enter Settings.
    PermissionContext? permissionContext;
    try {
      permissionContext = Provider.of<PermissionContext>(context, listen: true);
    } on ProviderNotFoundException {
      permissionContext = null;
    }
    // W3.A â€” Team / Diagnostics / Advisor tabs are gone. The Operator
    // Web console owns Team management + advisor admin. Mobile mirrors
    // the read-only essentials in 3 tabs.
    final effectiveTeamActor = widget.teamActor;
    // Non-admin signed-in users see only the Account tab. Admin tier
    // (operator_owner / operator_general_manager / super_admin / ff_support)
    // sees the rest. The gate is opt-in: a null teamActor (e.g.
    // demo / unauth flows or pre-Phase-9 test setups) keeps admin
    // tabs visible. Once the Phase 9 permission snapshot bridge
    // populates teamActor in production, non-admin roles will
    // collapse to Account-only automatically.
    final showAdminTabs =
        !showAccount ||
        effectiveTeamActor == null ||
        _isAdminTier(effectiveTeamActor);
    // The Data-alignment diagnostics section is reached only from
    // inside the Data tab, which `_shouldShowDataTab` already F&F-gates
    // (super_admin / ff_support, or a null-actor demo / unauth shell).
    // Mirror that resolution here — a null actor keeps the section
    // visible, matching `showAdminTabs` / `_shouldShowDataTab`'s
    // documented null-actor-open posture for legacy demo / unauth
    // shells. The previous `effectiveTeamActor != null` clause made
    // this one section null-actor-CLOSED, so it silently vanished from
    // the demo shell even though its container tab still rendered.
    // Operator-tier actors (non-null, non-FF) are still excluded by
    // `_shouldShowDataTab`, so they never reach this branch.
    final showFFSupport =
        effectiveTeamActor == null || _isFFAccount(effectiveTeamActor);
    // MO-1 (Wave 2) — the Data tab carries F&F-internal diagnostic
    // surfaces (Sync status, Demo→Live switch, data freshness, demo
    // reset, data alignment). Per debug.md:260 the tab is privileged
    // to seeded F&F admin users only (super_admin / ff_support), not
    // operator-tier admins.
    //
    // Server-snapshot first: when a [PermissionContext] is wired
    // (production auth bridge), gate on `admin.debug_console.view` —
    // the closest existing catalog key restricted to super_admin and
    // ff_support (see db/migrations/202604250008 lines 975-996). When
    // no snapshot is in scope (demo / unauth / pre-Phase-9 tests),
    // fall back to the role-based [_isFFAccount] helper. A null
    // teamActor (legacy demo / unauth shells) keeps the tab visible
    // so demo-mode walkthroughs still reach the Demo→Live switch.
    //
    // TODO(mo-1): consider adding a dedicated `mobile.data_tab.view`
    // or `forgeflow.data_diagnostics.view` permission key in a
    // follow-up slice; reusing `admin.debug_console.view` is a
    // conservative match (no new keys per slice scope), but a
    // dedicated key would carry clearer intent.
    final showDataTab = _shouldShowDataTab(
      permissionContext: permissionContext,
      teamActor: effectiveTeamActor,
      showAccount: showAccount,
    );
    // U-7 (debug.md:304) — Settings tab order is Setup, Integrations
    // (MP-1, gated by `showAdminTabs`), Data (F&F admins only), Account.
    // The MP-1 Integrations tab landed in the post-U-7 rebase (this PR);
    // it slots between Setup and Data as the operator-gated mobile
    // integrations surface and is the canonical home for the C-4
    // Demo→Live master switch (no longer mounted under Setup).
    final tabs = <_SettingsTabSpec>[
      if (showAdminTabs) _authoritySettingsTab,
      // MP-1 (Wave 2) — Integrations is its own top-level tab. Hosts
      // per-(O, L, C) status from `demo_mode_state`, the operator
      // master Demo→Live switch (formerly mounted under Setup as
      // "Demo vs live data" per MO-1-FU; the long-term home is here),
      // and a B11.1 short-opaque-code handoff link to operator-web's
      // Vendor Connections screen. Gated by `showAdminTabs` so every
      // operator admin (owner / general manager / super_admin / ff_support)
      // reaches it; the Data tab keeps its tighter F&F gate.
      if (showAdminTabs) _integrationsSettingsTab,
      if (showDataTab) _dataSettingsTab,
      if (showAccount) _accountSettingsTab,
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        backgroundColor: AppColors.backgroundDeep,
        appBar: AppBar(
          backgroundColor: AppColors.backgroundDeep,
          foregroundColor: AppColors.textPrimary,
          elevation: 0,
          titleSpacing: 4,
          title: Row(
            children: [
              // Wave 2 W-5-mobile-FU — render the operator's uploaded
              // logo from the session, falling back to the F&F splash
              // when the operator has not uploaded one. Reuses the
              // same `OperatorBrandMark` widget the mobile shell +
              // Notifications header use so the brand-mark is
              // consistent across post-login surfaces. Widget tests
              // mount this screen without an AuthSessionNotifier
              // provider (settings_screen_collapse_test.dart), so the
              // lookup tolerates a missing provider and renders the
              // splash fallback in that case.
              Builder(
                builder: (context) {
                  String? logoUrl;
                  try {
                    logoUrl = Provider.of<AuthSessionNotifier>(
                      context,
                    ).session?.logoUrl;
                  } on ProviderNotFoundException {
                    logoUrl = null;
                  }
                  return OperatorBrandMark(logoUrl: logoUrl);
                },
              ),
              const SizedBox(width: 12),
              Text('Settings', style: AppTextStyles.display20()),
            ],
          ),
          leading: IconButton(
            icon: const Icon(Icons.close, size: 28),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: TabBarView(
          children: [
            // U-7 (debug.md:304) — TabBarView children mirror the
            // bottom-nav `tabs` order. Post-MP-1 that is:
            // Setup, Integrations, Data, Account.
            if (showAdminTabs)
              _SettingsTabScrollView(
                tabId: 'authority',
                onRefresh: _handlePullToRefresh,
                slivers: [
                  if (restaurant == null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 24,
                        ),
                        child: _SettingsEmptyNotice(
                          icon: Icons.storefront_outlined,
                          title: 'No restaurant selected',
                          description:
                              'Pick a restaurant before reviewing business timing and wage settings.',
                        ),
                      ),
                    ),
                  if (restaurant != null) ...[
                    // Wave 2 MO-2 — Covers Setup is the first item on
                    // the Setup tab per debug.md:287-289. Manual entry
                    // is the primary path when the active POS does
                    // not expose covers (Square / Clover) and a
                    // manual entry otherwise. Signed-in live paths write
                    // through the canonical proxy first, then mirror
                    // locally for recent-entry display. Demo / unauth
                    // widget paths keep the local fallback.
                    _settingsSection(
                      title: 'Covers setup',
                      child: SettingsCoversSetupSection(
                        restaurantId: restaurant.restaurantId,
                        scopeLabel: restaurant.displayName,
                        writer: manualCoversWriteActions?.save,
                        clearer: manualCoversWriteActions?.clear,
                        onAfterSave: _refreshAfterWrite,
                      ),
                    ),
                    // U-7 MO-3a/MO-3b — description ("Review when business
                    // days...") dropped per debug.md:264. Business-day-start
                    // and shift-close-rule consolidation lives inside
                    // TimingAuthoritySection.
                    _settingsSection(
                      title: 'Business timing',
                      child: TimingAuthoritySection(
                        restaurantId: restaurant.restaurantId,
                        scopeLabel: restaurant.displayName,
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: SettingsPointerRow(
                          label: 'Manage Timing on Ops Web',
                          opWebPath: 'business-setup',
                          navId: 'business_setup',
                          handoffCodeGateway: widget.handoffCodeGateway,
                        ),
                      ),
                    ),
                  ],
                  // U-7 MO-4a — subtitle "Review the wage mix..." dropped
                  // per debug.md:268.
                  _settingsSection(
                    title: 'Wage setup',
                    child: WageAuthoritySection(
                      onChanged: _refreshAppState,
                      viewOnly: true,
                      scopeLabel: restaurant?.displayName,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SettingsPointerRow(
                        label: 'Manage Wage on Ops Web',
                        opWebPath: 'wage-authority',
                        navId: 'wage_authority',
                        handoffCodeGateway: widget.handoffCodeGateway,
                      ),
                    ),
                  ),
                  // MO-1-FU (Wave 2) — the operator master Demo→Live
                  // switch was briefly mounted here under "Demo vs live
                  // data" because MO-1 (PR #661) had gated the Data
                  // tab to F&F admin users only. MP-1 (Wave 2) gives
                  // the switch a permanent home: the new top-level
                  // Integrations tab (`_integrationsSettingsTab`),
                  // alongside per-category integration status and the
                  // operator-console deep-link. The widget itself is
                  // unchanged — only its mount point moves.
                ],
              ),
            if (showAdminTabs)
              _SettingsTabScrollView(
                tabId: 'integrations',
                onRefresh: _handlePullToRefresh,
                slivers: [
                  // MP-1 (Wave 2) — Integrations tab body. Per-category
                  // status (POS / Reservation / Labor) from the same
                  // `demo_mode_state` source the demo banner uses, the
                  // C-4 master Demo→Live switch mounted verbatim, and
                  // a B11.1 short-opaque-code handoff link to the
                  // operator console's Vendor Connections screen. All
                  // connection management (connect / disconnect /
                  // OAuth) stays on operator-web — mobile is
                  // read-only.
                  _settingsSection(
                    title: 'Integrations',
                    child: SettingsIntegrationsSection(
                      handoffCodeGateway: widget.handoffCodeGateway,
                    ),
                  ),
                ],
              ),
            if (showDataTab)
              _SettingsTabScrollView(
                tabId: 'data',
                onRefresh: _handlePullToRefresh,
                slivers: [
                  _settingsSection(
                    title: 'Sync status',
                    child: SettingsDataStatusSection(status: _status),
                  ),
                  // Phase 10a.UX.1 â€” per-table last-sync timestamps
                  // surfacing the realtime push channel from the
                  // operator's perspective. Renders "Never" until the
                  // shell-mounted RealtimeSubscription delivers a
                  // shared-state frame for the table.
                  _settingsSection(
                    title: 'Latest updates',
                    child: const SettingsDataFreshnessSection(),
                  ),
                  if (_kDemoMode)
                    _settingsSection(
                      title: 'Data reset',
                      child: SettingsDataManagementSection(
                        onAfterWrite: _refreshAfterWrite,
                      ),
                    ),
                  if (_kDemoMode)
                    _settingsSection(
                      title: 'Demo date',
                      child: SettingsMockReplaySection(
                        mockReplayDate: () => _mockReplayDate,
                        onAfterWrite: _refreshAfterWrite,
                      ),
                    ),
                  if (showFFSupport)
                    _settingsSection(
                      title: 'Data alignment',
                      child: const SettingsAuditSection(),
                    ),
                ],
              ),
            if (showAccount)
              _SettingsTabScrollView(
                tabId: 'account',
                onRefresh: _handlePullToRefresh,
                slivers: [
                  // Mobile-native two-factor (operator-directed
                  // 2026-05-17): reverses the Wave 2 W3.A "read-only
                  // mirror + Manage on Ops Web pointer" posture for this
                  // section. The enrollment flow (dynamic enroll/remove
                  // button + QR code + 6-digit verify) and removal now
                  // run inline on mobile. The production auth runtime
                  // (`firebase_auth_runtime_bindings.dart`) wires a real
                  // `mfaOperationsGateway`; demo/preview shells fall back
                  // to `DemoMfaOperationsGateway` so the walkthrough
                  // shows a working QR (mirrors the active-sessions
                  // `allowDemoGatewayFallback` posture below).
                  _settingsSection(
                    title: 'Two-factor sign-in',
                    child: SettingsMfaSection(
                      gateway: widget.mfaOperationsGateway,
                      actor:
                          widget.mfaActor ??
                          _mfaActorForSession(
                            session,
                            restaurant?.restaurantId,
                          ),
                      refreshGeneration: _manualRefreshGeneration,
                      allowDemoGatewayFallback:
                          widget.mfaOperationsGateway == null,
                      viewOnly: false,
                    ),
                  ),
                  // Mobile-native Account actions (operator-directed
                  // 2026-05-17): reverses Wave 2 W3.A read-only for this
                  // section so the full actions card (Change password,
                  // Sign out on this device, Sign out of all devices)
                  // runs inline on mobile instead of deep-linking to
                  // Operator Web. Sign-out drives `AuthSessionNotifier`,
                  // which works in demo and production alike.
                  _settingsSection(
                    title: 'Account',
                    child: SettingsAccountSection(
                      accountInfoGateway: widget.accountInfoGateway,
                      passwordChangeGateway: widget.passwordChangeGateway,
                      allowDemoAccountInfoFallback:
                          widget.allowDemoAccountInfoFallback,
                      refreshGeneration: _manualRefreshGeneration,
                      viewOnly: false,
                    ),
                  ),
                  // U-7 MO-7c — subtitle "See where your account..."
                  // dropped per debug.md:299. The section's own header
                  // already explains the surface.
                  _settingsSection(
                    title: 'Active sessions',
                    child: SettingsActiveSessionsSection(
                      gateway: widget.authOperationsGateway,
                      actor:
                          widget.activeSessionsActor ??
                          _activeSessionsActorForSession(
                            session,
                            authNotifier?.activeSessionId,
                          ),
                      allowDemoGatewayFallback:
                          widget.allowDemoActiveSessionsFallback,
                      refreshGeneration: _manualRefreshGeneration,
                      viewOnly: true,
                    ),
                  ),
                ],
              ),
          ],
        ),
        bottomNavigationBar: tabs.length >= 2
            ? _SettingsBottomNav(tabs: tabs)
            : null,
      ),
    );
  }

  bool _dismissRouteAfterSignOut(AuthSessionNotifier? authNotifier) {
    final state = authNotifier?.state;
    if (state is AuthSessionAuthenticated) {
      _routeSawAuthenticatedSession = true;
      _authDismissScheduled = false;
      return false;
    }
    if (!_routeSawAuthenticatedSession ||
        state is! AuthSessionUnauthenticated ||
        _authDismissScheduled) {
      return _authDismissScheduled;
    }
    _authDismissScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (navigator.canPop()) {
        navigator.pop();
      }
    });
    return true;
  }
}

/// Tabs other than Account are only visible to admin-tier roles.
/// Operator owners, operator_general_manager, super_admin, and ff_support
/// qualify. Retired v1 roles and null actors do not.
bool _isAdminTier(TeamScopeActor? actor) {
  if (actor == null) return false;
  return actor.actorRoles.contains('operator_owner') ||
      actor.actorRoles.contains('operator_general_manager') ||
      actor.actorRoles.contains('super_admin') ||
      actor.actorRoles.contains('ff_support');
}

/// W3.A â€” F&F support gate. The Data alignment section in the Data tab
/// surfaces canonical-fact diagnostics that only super_admin /
/// ff_support actors should see. Operators (owner / general manager / etc.)
/// stay out â€” the section is removed from their Data tab.
bool _isFFAccount(TeamScopeActor? actor) {
  if (actor == null) return false;
  return actor.actorRoles.contains('super_admin') ||
      actor.actorRoles.contains('ff_support');
}

SyncProxyClient? _syncProxyClientFromContext(BuildContext context) {
  try {
    return Provider.of<SyncProxyClient?>(context, listen: false);
  } on ProviderNotFoundException {
    return null;
  }
}

_ManualCoversWriteActions? _manualCoversWriteActionsFor({
  required AuthSession? session,
  required SyncProxyClient? syncProxyClient,
}) {
  if (session == null) return null;
  if (syncProxyClient is! ManualCoversWriteClient) {
    Future<void> throwUnavailable(_) async {
      throw const ManualCoversWriteException(
        code: 'manual_covers_proxy_unavailable',
        message:
            'Manual covers need a live Forge & Flow connection before saving.',
      );
    }

    return _ManualCoversWriteActions(
      save: throwUnavailable,
      clear: throwUnavailable,
    );
  }
  final writer = AuthSessionManualCoversWriter(
    client: syncProxyClient as ManualCoversWriteClient,
    authSessionProvider: () => session,
  );
  return _ManualCoversWriteActions(save: writer.save, clear: writer.clear);
}

class _ManualCoversWriteActions {
  const _ManualCoversWriteActions({required this.save, required this.clear});

  final ManualCoverEntryWriter save;
  final ManualCoverEntryClearer clear;
}

/// MO-1 (Wave 2) â€” gate for the mobile Settings Data tab.
///
/// Per debug.md:260 the tab is restricted to seeded F&F admin users
/// (super_admin / ff_support). Operators (owner / manager /
/// supervisor / staff) do not see the tab.
///
/// Resolution order:
///  1. When the user is unauthenticated (`!showAccount`), keep the
///     tab visible. The screen still mounts in the demo / unauth
///     walkthrough so the demo-mode operator can reach the
///     Demo→Live switch and Data reset.
///  2. When a [PermissionContext] is wired (production auth bridge),
///     prefer the server-snapshot answer: `admin.debug_console.view`
///     is granted to super_admin + ff_support only in the seeded
///     role-permission rows (see db/migrations/202604250008 around
///     line 990).
///  3. Otherwise fall back to the role-based [_isFFAccount] helper.
///  4. A null [teamActor] with no [PermissionContext] keeps the tab
///     visible so legacy demo / unauth / pre-Phase-9 test shells
///     stay functional (mirrors `showAdminTabs`â€™s null-actor open
///     posture).
bool _shouldShowDataTab({
  required PermissionContext? permissionContext,
  required TeamScopeActor? teamActor,
  required bool showAccount,
}) {
  // Unauth / demo walkthrough: keep the demo Demo→Live + reset rows
  // reachable. Same posture as `showAdminTabs`.
  if (!showAccount) return true;
  if (permissionContext != null) {
    // Server-snapshot resolves the truth. F&F admins return true;
    // operator-tier and below return false (catalog grants
    // `admin.debug_console.view` to super_admin + ff_support only).
    return permissionContext.hasPermission(
      PermissionKeys.adminDebugConsoleView,
    );
  }
  // No snapshot in the tree (widget tests / demo shells / Barrio
  // embeds without the bridge). Defer to the role-based helper. A
  // null actor opens the tab — mirrors `showAdminTabs` for
  // backward compatibility with pre-Phase-9 test setups.
  if (teamActor == null) return true;
  return _isFFAccount(teamActor);
}

ActiveSessionsActor _activeSessionsActorForSession(
  AuthSession session,
  String? activeSessionId,
) {
  return ActiveSessionsActor(
    actorUserId: session.userId,
    operatorId: session.operatorId,
    locationId: session.locationId,
    currentSessionId: activeSessionId,
  );
}

MfaActorContext _mfaActorForSession(
  AuthSession session,
  String? notificationRestaurantId,
) {
  return MfaActorContext(
    actorUserId: session.userId,
    operatorId: session.operatorId,
    locationId: session.locationId,
    userEmail: _mfaEmailForSession(session),
    authorizationIdToken: session.firebaseIdToken,
    notificationRestaurantId: notificationRestaurantId,
  );
}

String _mfaEmailForSession(AuthSession session) {
  final token = session.firebaseIdToken;
  final parts = token.split('.');
  if (parts.length < 2) return session.userId;
  try {
    final payload = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    final json = jsonDecode(payload);
    if (json is Map) {
      final email = json['email'];
      if (email is String && email.trim().isNotEmpty) return email.trim();
    }
  } catch (_) {
    // Token verification happens server-side. This local decode is only for
    // the authenticator app label, so malformed payloads fall back quietly.
  }
  return session.userId;
}

const _SettingsTabSpec _accountSettingsTab = _SettingsTabSpec(
  id: 'account',
  label: 'Account',
  icon: Icons.person_outline,
);

const _SettingsTabSpec _authoritySettingsTab = _SettingsTabSpec(
  id: 'authority',
  label: 'Setup',
  icon: Icons.tune_rounded,
);

/// MP-1 (Wave 2) — top-level Integrations tab. Renders per-category
/// integration status, the operator master Demo→Live switch (the C-4
/// surface; widget mounted verbatim), and a B11.1 deep-link to the
/// operator console's Vendor Connections screen. Gated by
/// `showAdminTabs`, so every operator admin role reaches it.
const _SettingsTabSpec _integrationsSettingsTab = _SettingsTabSpec(
  id: 'integrations',
  label: 'Integrations',
  icon: Icons.cable_rounded,
);

const _SettingsTabSpec _dataSettingsTab = _SettingsTabSpec(
  id: 'data',
  label: 'Data',
  icon: Icons.storage_rounded,
);

class _SettingsTabSpec {
  final String id;
  final String label;
  final IconData icon;

  const _SettingsTabSpec({
    required this.id,
    required this.label,
    required this.icon,
  });
}

class _SettingsBottomNav extends StatelessWidget {
  final List<_SettingsTabSpec> tabs;

  const _SettingsBottomNav({required this.tabs});

  @override
  Widget build(BuildContext context) {
    final controller = DefaultTabController.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Container(
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: AppColors.borderSubtle, width: 1),
            ),
          ),
          child: BottomNavigationBar(
            currentIndex: controller.index,
            onTap: controller.animateTo,
            backgroundColor: AppColors.backgroundDeep,
            selectedItemColor: AppColors.sunsetDark,
            unselectedItemColor: AppColors.textMuted,
            type: BottomNavigationBarType.fixed,
            elevation: 0,
            // Match the app-wide bottom-nav label size (app_theme.dart
            // BottomNavigationBarThemeData = 12) so the settings tab bar
            // reads consistently with the main shell tab bar.
            selectedLabelStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
            unselectedLabelStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              letterSpacing: 0.5,
            ),
            items: [
              for (final tab in tabs)
                BottomNavigationBarItem(
                  icon: KeyedSubtree(
                    key: Key('settings_tab_${tab.id}'),
                    child: Icon(tab.icon, size: 22),
                  ),
                  label: tab.label,
                ),
            ],
          ),
        );
      },
    );
  }
}

class _SettingsTabScrollView extends StatelessWidget {
  final String tabId;
  final List<Widget> slivers;
  final Future<void> Function()? onRefresh;

  const _SettingsTabScrollView({
    required this.tabId,
    required this.slivers,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator.adaptive(
      onRefresh: onRefresh ?? () async {},
      child: CustomScrollView(
        key: PageStorageKey<String>('settings_${tabId}_scroll'),
        cacheExtent: 9999,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: slivers,
      ),
    );
  }
}

Widget _settingsSection({
  required String title,
  String? description,
  required Widget child,
}) {
  return SliverMainAxisGroup(
    slivers: [
      SliverPersistentHeader(
        pinned: true,
        delegate: StickySectionDelegate(title),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (description != null && description.trim().isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    description,
                    style: AppTextStyles.body12(color: AppColors.textMuted),
                  ),
                ),
              ],
              child,
            ],
          ),
        ),
      ),
    ],
  );
}

class _SettingsEmptyNotice extends StatelessWidget {
  const _SettingsEmptyNotice({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.sunset.withValues(alpha: 0.10),
              border: Border.all(
                color: AppColors.sunset.withValues(alpha: 0.4),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: AppColors.sunsetDark),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTextStyles.body14(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: AppTextStyles.body13(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
