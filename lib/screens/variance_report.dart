// Phase 7.13 — Variance Coaching Layout Cleanup.
// Phase 7.55o.2 — this file is now the Variance route shell and
// tab dispatch only. Tab bodies live in `screens/variance/` alongside
// shared helpers.

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/app_screen_header.dart';
import 'variance/variance_history_tab.dart';
import 'variance/variance_learn_tab.dart';
import 'variance/variance_this_week_tab.dart';

class VarianceReport extends StatelessWidget {
  const VarianceReport({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: FadingHeaderShell(
        header: AppScreenHeader(
          title: 'Variance',
          bottom: Container(
            margin: AppSpacing.screenH,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: AppColors.sunset.withValues(alpha: 0.2),
                  width: 1,
                ),
              ),
            ),
            child: TabBar(
              isScrollable: false,
              labelStyle: AppTextStyles.mono12(color: AppColors.sunsetDark),
              unselectedLabelStyle: AppTextStyles.mono12(
                color: AppColors.textMuted,
              ),
              indicatorColor: AppColors.sunset,
              indicatorWeight: 3,
              labelColor: AppColors.sunsetDark,
              unselectedLabelColor: AppColors.textMuted,
              dividerColor: Colors.transparent,
              tabs: const [
                Tab(text: 'This Week'),
                Tab(text: 'History'),
                Tab(text: 'Learn'),
              ],
            ),
          ),
        ),
        child: const TabBarView(
          children: [ThisWeekTab(), HistoryTab(), LearnTab()],
        ),
      ),
    );
  }
}
