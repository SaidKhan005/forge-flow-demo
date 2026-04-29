// Phase 7.55o.4 — Settings shared UI primitives.
//
// Card surfaces, section row dividers, action rows, and the row-tone
// enum shared by every Settings section. Extracted from the pre-split
// settings_screen.dart. Visual behaviour is unchanged.

import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

class SettingsCard extends StatelessWidget {
  final List<Widget> children;
  // Optional accent stripe color along the left edge. Used by status card.
  final Color? accentColor;
  const SettingsCard({super.key, required this.children, this.accentColor});

  @override
  Widget build(BuildContext context) {
    final accent = accentColor;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.backgroundMid, AppColors.cardGlow],
          ),
          border: Border.all(color: AppColors.borderSubtle, width: 1),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (accent != null) Container(width: 3, color: accent),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SettingsRowDivider extends StatelessWidget {
  const SettingsRowDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14),
      height: 1,
      color: AppColors.borderSubtle.withValues(alpha: 0.6),
    );
  }
}

enum SettingsRowTone { neutral, danger, admin }

class SettingsActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;
  final SettingsRowTone tone;
  final String? trailingBadge;

  const SettingsActionRow({
    super.key,
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
    this.tone = SettingsRowTone.neutral,
    this.trailingBadge,
  });

  Color get _accentColor {
    switch (tone) {
      case SettingsRowTone.danger:
        return AppColors.negative;
      case SettingsRowTone.admin:
        return AppColors.sunset;
      case SettingsRowTone.neutral:
        return AppColors.textPrimary;
    }
  }

  Color get _iconBgColor {
    switch (tone) {
      case SettingsRowTone.danger:
        return AppColors.negative.withValues(alpha: 0.12);
      case SettingsRowTone.admin:
        return AppColors.sunset.withValues(alpha: 0.12);
      case SettingsRowTone.neutral:
        return AppColors.borderSubtle.withValues(alpha: 0.4);
    }
  }

  Color get _iconBorderColor {
    switch (tone) {
      case SettingsRowTone.danger:
        return AppColors.negative.withValues(alpha: 0.5);
      case SettingsRowTone.admin:
        return AppColors.sunset.withValues(alpha: 0.5);
      case SettingsRowTone.neutral:
        return AppColors.borderSubtle;
    }
  }

  Color get _iconFgColor {
    switch (tone) {
      case SettingsRowTone.danger:
        return AppColors.negative;
      case SettingsRowTone.admin:
        return AppColors.sunset;
      case SettingsRowTone.neutral:
        return AppColors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Leading icon tile
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _iconBgColor,
                border: Border.all(color: _iconBorderColor, width: 1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(icon, size: 18, color: _iconFgColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.mono12(
                            color: _accentColor,
                            weight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (trailingBadge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.sunset.withValues(alpha: 0.15),
                            border: Border.all(
                              color: AppColors.sunset.withValues(alpha: 0.5),
                              width: 1,
                            ),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            trailingBadge!,
                            style: AppTextStyles.mono7(color: AppColors.sunset),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.body13(color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 18, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}
