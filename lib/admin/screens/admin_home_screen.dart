// Phase 11A.0 — Admin Home screen.
//
// Empty branded landing surface for the Operations Console. Renders
// inside the [AdminShell] body region; carries no logic of its own —
// 11A.1+ slices will replace the body with the live admin home
// (operator count, recent activity, etc.).

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

class AdminHomeScreen extends StatelessWidget {
  const AdminHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const Key('admin_home_scroll'),
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Operations console',
            style: AppTextStyles.display28(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 6),
          Text(
            'A private workspace for managing customers, plans, advisor content, connected services, and support checks.',
            style: AppTextStyles.body15(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 24),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                key: const Key('admin_home_card'),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [AppColors.backgroundSurface, AppColors.cardGlow],
                  ),
                  border: Border.all(color: AppColors.borderSubtle, width: 1),
                ),
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          height: 8,
                          width: 8,
                          decoration: const BoxDecoration(
                            color: AppColors.peacock,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Admin workspace ready',
                          style: AppTextStyles.mono11(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Welcome to the Forge & Flow admin workspace.',
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Use the left navigation to set up customers and locations, manage plans and limits, publish advisor knowledge, rotate service keys, inspect support logs, and run system checks.',
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
