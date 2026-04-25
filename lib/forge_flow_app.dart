import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/advisor_model_config_service.dart';
import 'services/business_date_authority_service.dart';
import 'services/shift_data_source.dart';
import 'state/active_target_profile_notifier.dart';
import 'state/app_refresh_coordinator.dart';
import 'state/app_runtime_invalidation_bus.dart';
import 'state/demand_forecast_context_notifier.dart';
import 'state/restaurant_scope_notifier.dart';
import 'state/schedule_distribution_weights_notifier.dart';
import 'state/shift_dashboard_notifier.dart';
import 'state/week_data_notifier.dart';
import 'infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import 'infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import 'infrastructure/persistence/sqlite/repositories/sqlite_week_record_repository.dart';
import 'screens/baseline_tracker.dart';
import 'screens/notifications_screen.dart';
import 'screens/schedule_builder.dart';
import 'screens/settings_screen.dart';
import 'screens/shift_dashboard.dart';
import 'screens/variance_report.dart';
import 'services/current_state_boundary_monitor.dart';
import 'theme/app_theme.dart';

/// Shared Forge & Flow runtime that can run standalone or inside Barrio.
class ForgeFlowApp extends StatelessWidget {
  const ForgeFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ForgeFlowScope(
      child: MaterialApp(
        title: 'Forge & Flow',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: const AppShell(),
      ),
    );
  }
}

class ForgeFlowScope extends StatelessWidget {
  final Widget child;

  const ForgeFlowScope({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<RestaurantScopeNotifier>(
          create: (_) => RestaurantScopeNotifier(),
        ),
        Provider<ShiftDataSource>(create: (_) => const LiveShiftDataSource()),
        ChangeNotifierProvider<ActiveTargetProfileNotifier>(
          create: (_) => ActiveTargetProfileNotifier(),
        ),
        ChangeNotifierProvider<WeekDataNotifier>(
          create: (ctx) => WeekDataNotifier(ctx.read<ShiftDataSource>()),
        ),
        ChangeNotifierProvider<ShiftDashboardNotifier>(
          create: (_) => ShiftDashboardNotifier(),
        ),
        // Phase 7.55i.1 — canonical demand forecast context from closed shifts.
        // Loads on creation; Schedule/Shift/Audit read .context for demand.
        ChangeNotifierProvider<DemandForecastContextNotifier>(
          create: (_) => DemandForecastContextNotifier(),
        ),
        // Phase 7.55e.4 — runtime distribution weights from closed shifts.
        // Loads on creation; Schedule reads .weights when building its notifier.
        ChangeNotifierProvider<ScheduleDistributionWeightsNotifier>(
          create: (_) {
            final notifier = ScheduleDistributionWeightsNotifier(
              scopeRepo: SqliteRestaurantScopeRepository.instance,
              weekRepo: SqliteWeekRecordRepository.instance,
              shiftRepo: SqliteShiftRecordRepository.instance,
            );
            notifier.load(); // fire-and-forget; Schedule uses fallback until ready
            return notifier;
          },
        ),
        // Phase 7.55p.4b — runtime invalidation bus.
        // Singleton ChangeNotifier that fires when ShiftService write
        // paths complete. Exposed here so ProxyProvider2 can react.
        ChangeNotifierProvider<AppRuntimeInvalidationBus>.value(
          value: AppRuntimeInvalidationBus.instance,
        ),
        // Phase 7.55p.4a+4b — central refresh / invalidation policy.
        // ProxyProvider2: when EITHER ActiveTargetProfileNotifier changes
        // OR the runtime invalidation bus fires, the coordinator refreshes
        // current-state surfaces (week, shift) through one shared rule.
        ProxyProvider2<ActiveTargetProfileNotifier,
            AppRuntimeInvalidationBus, AppRefreshCoordinator>(
          create: (ctx) => AppRefreshCoordinator(
            restaurantScope: ctx.read<RestaurantScopeNotifier>(),
            activeTarget: ctx.read<ActiveTargetProfileNotifier>(),
            weekData: ctx.read<WeekDataNotifier>(),
            shiftDashboard: ctx.read<ShiftDashboardNotifier>(),
            demandForecast: ctx.read<DemandForecastContextNotifier>(),
            scheduleWeights: ctx.read<ScheduleDistributionWeightsNotifier>(),
          ),
          update: (ctx, targetNotifier, bus, previous) {
            previous!.refreshCurrentStateSurfaces();
            return previous;
          },
        ),
      ],
      child: child,
    );
  }
}

class AppShell extends StatefulWidget {
  final bool embeddedInBarrio;

  /// Test-only: override business-date resolution for the boundary
  /// monitor. When provided, the monitor uses this resolver instead
  /// of [BusinessDateAuthorityService].
  @visibleForTesting
  final Future<String?> Function(DateTime)? testBusinessDateResolver;

  const AppShell({
    super.key,
    this.embeddedInBarrio = false,
    this.testBusinessDateResolver,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _selectedIndex = 0;

  /// Tracks whether the app has been backgrounded at least once.
  /// Prevents the cold-start `resumed` callback from triggering a
  /// duplicate refresh — notifiers already load in their constructors.
  bool _hasBeenBackgrounded = false;

  /// Phase 7.55n.10: foreground-only business-date boundary monitor.
  /// Detects boundary changes while the app stays open and routes
  /// refresh through the shared coordinator seam.
  CurrentStateBoundaryMonitor? _boundaryMonitor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Initialize boundary monitor after first frame when providers
    // are available in the widget tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initBoundaryMonitor();
    });
  }

  /// Creates and starts the boundary monitor.
  ///
  /// Uses [widget.testBusinessDateResolver] when provided (tests),
  /// otherwise falls back to production
  /// [BusinessDateAuthorityService.resolveBusinessDate].
  void _initBoundaryMonitor() {
    if (!mounted) return;
    _boundaryMonitor = CurrentStateBoundaryMonitor(
      resolveBusinessDate: widget.testBusinessDateResolver ??
          BusinessDateAuthorityService.instance.resolveBusinessDate,
      onBoundaryChanged: () {
        if (mounted) {
          context
              .read<AppRefreshCoordinator>()
              .refreshCurrentStateSurfaces();
        }
      },
    );
    _boundaryMonitor!.start();
  }

  @override
  void dispose() {
    _boundaryMonitor?.stop();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Phase 7.55n.9 + 7.55n.9a + 7.55n.10: revalidate current-state
  /// surfaces on app resume after real backgrounding, and manage the
  /// boundary monitor lifecycle.
  ///
  /// Routes through the shared [AppRefreshCoordinator] seam so the
  /// definition of "current-state surfaces" stays centralized.
  ///
  /// Guard logic:
  /// - `_hasBeenBackgrounded` is set to `true` on `paused`
  /// - `resumed` only refreshes when the flag is `true` (real background)
  /// - the flag is reset to `false` on each `resumed` so a later
  ///   `inactive -> resumed` (e.g., phone call overlay) does not
  ///   false-positive
  ///
  /// Boundary monitor lifecycle:
  /// - stopped on `paused` (no checking while backgrounded)
  /// - re-seeded and restarted on `resumed` after real backgrounding;
  ///   the re-seed picks up the current business date so the monitor
  ///   does not duplicate the refresh already handled by the resume
  ///   path (7.55n.9)
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _hasBeenBackgrounded) {
      _hasBeenBackgrounded = false;
      context.read<AppRefreshCoordinator>().refreshCurrentStateSurfaces();
      // Re-seed and restart boundary monitor after resume refresh.
      // The re-seed picks up the current business date so the monitor
      // does not detect a "change" that the resume path already handled.
      _boundaryMonitor?.start();
    } else if (state == AppLifecycleState.resumed) {
      // resumed without prior paused — no-op (cold start or inactive)
    }
    if (state == AppLifecycleState.paused) {
      _hasBeenBackgrounded = true;
      _boundaryMonitor?.stop();
    }
  }

  void _navigateTo(int index) {
    setState(() => _selectedIndex = index);
  }

  void _openSettings(BuildContext context) {
    // In debug builds, wire the ADVISOR MODELS dev section by passing a
    // live `AdvisorModelConfigService`. In release the section stays
    // hidden because `SettingsScreen` only renders it when both
    // `kDebugMode` and a service instance are present.
    final advisorConfig = kDebugMode ? AdvisorModelConfigService() : null;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          advisorModelConfigService: advisorConfig,
        ),
        fullscreenDialog: true,
      ),
    );
  }

  void _openNotifications(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const NotificationsScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // App-shell rebuild now driven by persisted active-target authority,
    // not BaselineData.revision.
    final revision = context.watch<ActiveTargetProfileNotifier>().revision;

    final embeddedAppBar = AppBar(
      backgroundColor: AppColors.backgroundDeep,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      title: const Text('Forge & Flow'),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, size: 20),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      actions: [
        IconButton(
          icon: const Icon(
            Icons.notifications_none_outlined,
            size: 20,
            color: AppColors.textMuted,
          ),
          onPressed: () => _openNotifications(context),
        ),
        IconButton(
          icon: const Icon(
            Icons.settings_outlined,
            size: 20,
            color: AppColors.textMuted,
          ),
          onPressed: () => _openSettings(context),
        ),
      ],
    );

    // Premium app shell header — icons live in their own pill buttons so
    // they read as actionable, separated by a soft border line at the
    // bottom from the underlying screen content.
    final standaloneAppBar = PreferredSize(
      preferredSize: const Size.fromHeight(56),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.backgroundDeep,
              AppColors.backgroundDeep.withValues(alpha: 0.85),
            ],
          ),
          border: Border(
            bottom: BorderSide(
              color: AppColors.borderSubtle.withValues(alpha: 0.6),
              width: 1,
            ),
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
            child: Row(
              children: [
                const Spacer(),
                _AppShellIconButton(
                  icon: Icons.notifications_none_outlined,
                  tooltip: 'Notifications',
                  onTap: () => _openNotifications(context),
                ),
                const SizedBox(width: 8),
                _AppShellIconButton(
                  icon: Icons.settings_outlined,
                  tooltip: 'Settings',
                  onTap: () => _openSettings(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Scaffold(
        backgroundColor: AppColors.backgroundDeep,
        appBar: widget.embeddedInBarrio ? embeddedAppBar : standaloneAppBar,
        body: SafeArea(
          top: !widget.embeddedInBarrio,
          child: IndexedStack(
            index: _selectedIndex,
            children: [
              KeyedSubtree(
                key: ValueKey('shift-$revision'),
                child: ShiftDashboard(onVarianceTap: () => _navigateTo(1)),
              ),
              KeyedSubtree(
                key: ValueKey('variance-$revision'),
                child: const VarianceReport(),
              ),
              KeyedSubtree(
                key: ValueKey('schedule-$revision'),
                child: const ScheduleBuilder(),
              ),
              KeyedSubtree(
                key: ValueKey('baseline-$revision'),
                child: const BaselineTracker(),
              ),
            ],
          ),
        ),
        bottomNavigationBar: _AppBottomNav(
          selectedIndex: _selectedIndex,
          onTap: _navigateTo,
        ),
    );
  }
}

class _AppBottomNav extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onTap;

  const _AppBottomNav({required this.selectedIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: AppColors.borderSubtle,
            width: 1,
          ),
        ),
      ),
      child: BottomNavigationBar(
        currentIndex: selectedIndex,
        onTap: onTap,
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
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.show_chart, size: 22),
            label: 'Shift',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bar_chart, size: 22),
            label: 'Variance',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.calendar_today, size: 22),
            label: 'Plan',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history, size: 22),
            label: 'Benchmark',
          ),
        ],
      ),
    );
  }
}

// ─── App shell icon button ───────────────────────────────────────────────
// Pill-style icon button used in the standalone app bar so settings and
// notifications read as their own affordances rather than tiny hint icons.

class _AppShellIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _AppShellIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.backgroundMid.withValues(alpha: 0.7),
            border: Border.all(
              color: AppColors.borderSubtle.withValues(alpha: 0.7),
              width: 1,
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(icon, size: 18, color: AppColors.textSecondary),
        ),
      ),
    );
  }
}
