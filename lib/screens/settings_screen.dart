import 'package:flutter/material.dart';
import 'dart:convert';

import 'package:provider/provider.dart';

import '../auth/auth_session.dart';
import '../models/app_data_status.dart';
import '../services/app_data_status_service.dart';
import '../services/auth/account_info_gateway.dart';
import '../services/auth/auth_operations_gateway.dart';
import '../services/auth/handoff_code_gateway.dart';
import '../services/auth/password_change_gateway.dart';
import '../services/mfa/mfa_operations_gateway.dart';
import '../services/shift_service.dart';
import '../state/app_refresh_coordinator.dart';
import '../state/auth_session_notifier.dart';
import '../state/restaurant_scope_notifier.dart';
import '../services/team/team_scope_visibility_policy.dart';
import '../theme/app_theme.dart';
import '../widgets/sticky_section_delegate.dart';
import 'settings/settings_active_sessions_section.dart';
import 'settings/settings_data_sections.dart';
import 'settings/settings_demo_live_switch.dart';
import 'settings/settings_mfa_section.dart';
import 'settings/settings_pointer_row.dart';
import 'settings/settings_timing_authority_section.dart';
import 'settings/settings_wage_authority_section.dart';

/// W3.A â€” mobile Settings is a 3-tab read-only mirror of the operator
/// web console. `kDemoMode` toggles demo-only rows (Data reset + Demo
/// date) without changing the production layout. Defined as a top-
/// level const so widget tests can flip it via `--dart-define`.
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
    if (!context.mounted) return;
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
    if (!context.mounted) return;
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
    // W3.A â€” Team / Diagnostics / Advisor tabs are gone. The Operator
    // Web console owns Team management + advisor admin. Mobile mirrors
    // the read-only essentials in 3 tabs.
    final effectiveTeamActor = widget.teamActor;
    // Non-admin signed-in users see only the Account tab. Admin tier
    // (operator_owner / operator_manager / super_admin / ff_support)
    // sees the rest. The gate is opt-in: a null teamActor (e.g.
    // demo / unauth flows or pre-Phase-9 test setups) keeps admin
    // tabs visible. Once the Phase 9 permission snapshot bridge
    // populates teamActor in production, non-admin roles will
    // collapse to Account-only automatically.
    final showAdminTabs =
        !showAccount ||
        effectiveTeamActor == null ||
        _isAdminTier(effectiveTeamActor);
    final showFFSupport =
        effectiveTeamActor != null && _isFFAccount(effectiveTeamActor);
    // U-7 (debug.md:304) — Settings tab order is Setup, Data (F&F admins),
    // Account. A future MP-1 Integrations tab will slot between Setup and
    // Data once the operator-gated mobile integrations surface is built;
    // until then the slot is omitted, not stubbed.
    final tabs = <_SettingsTabSpec>[
      if (showAdminTabs) _authoritySettingsTab,
      if (showAdminTabs) _dataSettingsTab,
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
              ClipOval(
                child: Image.asset(
                  'assets/images/forge_flow_splash_icon.png',
                  width: 36,
                  height: 36,
                  fit: BoxFit.cover,
                ),
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
            // bottom-nav `tabs` order: Setup, Data, Account.
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
                    // U-7 MO-3a/MO-3b — description ("Review when business
                    // days...") dropped per debug.md:264. Business-day-start
                    // and shift-close-rule consolidation lives inside
                    // TimingAuthoritySection.
                    _settingsSection(
                      title: 'Business timing',
                      child: TimingAuthoritySection(
                        restaurantId: restaurant.restaurantId,
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
                ],
              ),
            if (showAdminTabs)
              _SettingsTabScrollView(
                tabId: 'data',
                onRefresh: _handlePullToRefresh,
                slivers: [
                  _settingsSection(
                    title: 'Sync status',
                    description:
                        'See whether this device has the local data it needs.',
                    child: SettingsDataStatusSection(status: _status),
                  ),
                  _settingsSection(
                    title: 'Integrations',
                    description:
                        'Switch this location from demo facts to live vendor facts.',
                    child: const SettingsDemoLiveSwitch(),
                  ),
                  // Phase 10a.UX.1 â€” per-table last-sync timestamps
                  // surfacing the realtime push channel from the
                  // operator's perspective. Renders "Never" until the
                  // shell-mounted RealtimeSubscription delivers a
                  // shared-state frame for the table.
                  _settingsSection(
                    title: 'Latest updates',
                    description:
                        'Shows when shared restaurant data last updated on this device.',
                    child: const SettingsDataFreshnessSection(),
                  ),
                  if (_kDemoMode)
                    _settingsSection(
                      title: 'Data reset',
                      description:
                          'Use carefully when clearing local demo or operational data.',
                      child: SettingsDataManagementSection(
                        onAfterWrite: _refreshAfterWrite,
                      ),
                    ),
                  if (_kDemoMode)
                    _settingsSection(
                      title: 'Demo date',
                      description:
                          'Move the demo restaurant through sample business days.',
                      child: SettingsMockReplaySection(
                        mockReplayDate: () => _mockReplayDate,
                        onAfterWrite: _refreshAfterWrite,
                      ),
                    ),
                  if (showFFSupport)
                    _settingsSection(
                      title: 'Data alignment',
                      description:
                          'F&F support diagnostics for canonical fact alignment.',
                      child: const SettingsAuditSection(),
                    ),
                ],
              ),
            if (showAccount)
              _SettingsTabScrollView(
                tabId: 'account',
                onRefresh: _handlePullToRefresh,
                slivers: [
                  // U-7 MO-5d — subtitle "Review the authenticator..."
                  // dropped per debug.md:295.
                  _settingsSection(
                    title: 'Two-factor security',
                    child: SettingsMfaSection(
                      gateway: widget.mfaOperationsGateway,
                      actor:
                          widget.mfaActor ??
                          _mfaActorForSession(
                            session,
                            restaurant?.restaurantId,
                          ),
                      refreshGeneration: _manualRefreshGeneration,
                      viewOnly: true,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SettingsPointerRow(
                        label: 'Manage two-factor security on Ops Web',
                        opWebPath: 'my-account#security',
                        navId: 'my_account',
                        handoffCodeGateway: widget.handoffCodeGateway,
                      ),
                    ),
                  ),
                  // U-7 MO-6b — subtitle "Review your sign-in details."
                  // dropped per debug.md:295.
                  _settingsSection(
                    title: 'Account',
                    child: SettingsAccountSection(
                      accountInfoGateway: widget.accountInfoGateway,
                      passwordChangeGateway: widget.passwordChangeGateway,
                      refreshGeneration: _manualRefreshGeneration,
                      viewOnly: true,
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SettingsPointerRow(
                        label: 'Manage Account on Ops Web',
                        opWebPath: 'my-account',
                        navId: 'my_account',
                        handoffCodeGateway: widget.handoffCodeGateway,
                      ),
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
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SettingsPointerRow(
                        label: 'Manage active sessions on Ops Web',
                        opWebPath: 'sessions',
                        navId: 'sessions',
                        handoffCodeGateway: widget.handoffCodeGateway,
                      ),
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
/// Operator owners, operator managers, super_admin, and ff_support
/// qualify. operator_supervisor / operator_staff / null actors do not.
bool _isAdminTier(TeamScopeActor? actor) {
  if (actor == null) return false;
  return actor.actorRoles.contains('operator_owner') ||
      actor.actorRoles.contains('operator_manager') ||
      actor.actorRoles.contains('super_admin') ||
      actor.actorRoles.contains('ff_support');
}

/// W3.A â€” F&F support gate. The Data alignment section in the Data tab
/// surfaces canonical-fact diagnostics that only super_admin /
/// ff_support actors should see. Operators (owner / manager / etc.)
/// stay out â€” the section is removed from their Data tab.
bool _isFFAccount(TeamScopeActor? actor) {
  if (actor == null) return false;
  return actor.actorRoles.contains('super_admin') ||
      actor.actorRoles.contains('ff_support');
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
            selectedLabelStyle: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
            unselectedLabelStyle: const TextStyle(
              fontSize: 10,
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
