import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'theme/app_theme.dart';
import 'data/shift_data_source.dart';
import 'data/week_data_notifier.dart';
import 'data/baseline_manager_service.dart';
import 'data/meridian_data.dart';
import 'screens/shift_dashboard.dart';
import 'screens/variance_report.dart';
import 'screens/schedule_builder.dart';
import 'screens/baseline_tracker.dart';
import 'screens/settings_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  await BaselineManagerService.instance.primeManagerOverride();

  runApp(const ForgeFlowApp());
}

class ForgeFlowApp extends StatelessWidget {
  const ForgeFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<ShiftDataSource>(
          create: (_) => const LiveShiftDataSource(),
        ),
        ChangeNotifierProvider<WeekDataNotifier>(
          create: (ctx) => WeekDataNotifier(ctx.read<ShiftDataSource>()),
        ),
      ],
      child: MaterialApp(
        title: 'Barrio',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: const AppShell(),
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;

  void _navigateTo(int index) {
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      appBar: _selectedIndex == 0
          ? null
          : AppBar(
              backgroundColor: AppColors.backgroundDeep,
              elevation: 0,
              automaticallyImplyLeading: false,
              actions: [
                IconButton(
                  icon: const Icon(Icons.settings_outlined,
                      size: 20, color: AppColors.textMuted),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const SettingsScreen(),
                      fullscreenDialog: true,
                    ),
                  ),
                ),
              ],
            ),
      body: SafeArea(
        child: ValueListenableBuilder<int>(
          valueListenable: BaselineData.revision,
          builder: (context, revision, __) => IndexedStack(
            index: _selectedIndex,
            children: [
              // Tab 0 — Shift (has its own Scaffold with FAB; no global AppBar)
              KeyedSubtree(
                key: ValueKey('shift-$revision'),
                child: ShiftDashboard(
                  onVarianceTap: () => _navigateTo(1),
                ),
              ),
              // Tab 1 — Variance
              KeyedSubtree(
                key: ValueKey('variance-$revision'),
                child: const VarianceReport(),
              ),
              // Tab 2 — Schedule
              KeyedSubtree(
                key: ValueKey('schedule-$revision'),
                child: const ScheduleBuilder(),
              ),
              // Tab 3 — Baseline
              KeyedSubtree(
                key: ValueKey('baseline-$revision'),
                child: const BaselineTracker(),
              ),
            ],
          ),
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

  const _AppBottomNav({
    required this.selectedIndex,
    required this.onTap,
  });

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
              color: AppColors.tealPrimary.withValues(alpha: 0.15), width: 1),
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
