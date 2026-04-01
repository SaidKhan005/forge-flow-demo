import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'data/active_target_profile_notifier.dart';
import 'data/restaurant_scope_notifier.dart';
import 'data/shift_dashboard_notifier.dart';
import 'data/shift_data_source.dart';
import 'data/week_data_notifier.dart';
import 'screens/baseline_tracker.dart';
import 'screens/schedule_builder.dart';
import 'screens/settings_screen.dart';
import 'screens/shift_dashboard.dart';
import 'screens/variance_report.dart';
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
        ChangeNotifierProxyProvider<
          ActiveTargetProfileNotifier,
          WeekDataNotifier
        >(
          create: (ctx) => WeekDataNotifier(ctx.read<ShiftDataSource>()),
          update: (ctx, targetNotifier, previous) {
            previous!.refresh();
            return previous;
          },
        ),
        ChangeNotifierProxyProvider<
          ActiveTargetProfileNotifier,
          ShiftDashboardNotifier
        >(
          create: (_) => ShiftDashboardNotifier(),
          update: (ctx, targetNotifier, previous) {
            previous!.refresh();
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

  const AppShell({super.key, this.embeddedInBarrio = false});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;

  void _navigateTo(int index) {
    setState(() => _selectedIndex = index);
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const SettingsScreen(),
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
            Icons.settings_outlined,
            size: 20,
            color: AppColors.textMuted,
          ),
          onPressed: () => _openSettings(context),
        ),
      ],
    );

    final standaloneAppBar = _selectedIndex == 0
        ? null
        : AppBar(
            backgroundColor: AppColors.backgroundDeep,
            elevation: 0,
            automaticallyImplyLeading: false,
            actions: [
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
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.shimmer, AppColors.backgroundDeep],
        ),
        border: Border(
          top: BorderSide(
            color: AppColors.tealPrimary.withValues(alpha: 0.15),
            width: 1,
          ),
        ),
      ),
      child: BottomNavigationBar(
        currentIndex: selectedIndex,
        onTap: onTap,
        backgroundColor: AppColors.backgroundDeep,
        selectedItemColor: AppColors.tealPrimary,
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
            label: 'Schedule',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history, size: 22),
            label: 'Baseline',
          ),
        ],
      ),
    );
  }
}
