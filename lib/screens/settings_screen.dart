import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../data/shift_service.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundDeep,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        title: Text('Settings', style: AppTextStyles.display20()),
        leading: IconButton(
          icon: const Icon(Icons.close, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 8),

          // Demo data section
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Text('DEMO', style: AppTextStyles.mono8(color: AppColors.textMuted)),
          ),

          _SettingsTile(
            label: 'Load Demo Data',
            description: 'Reseed 9 closed shifts + 7-week history',
            onTap: () async {
              await ShiftService.instance.reseedDemo();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Demo data loaded.',
                      style: AppTextStyles.mono11(color: AppColors.textPrimary),
                    ),
                    backgroundColor: AppColors.backgroundMid,
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            },
          ),

          Container(height: 1, color: AppColors.borderSubtle),

          _SettingsTile(
            label: 'Clear All Data',
            description: 'Wipe shift records and week history',
            labelColor: AppColors.negative,
            onTap: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: AppColors.backgroundMid,
                  title: Text(
                    'Clear all data?',
                    style: AppTextStyles.mono14(color: AppColors.textPrimary),
                  ),
                  content: Text(
                    'This removes all shift records and week history. Cannot be undone.',
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: Text('Cancel',
                          style: AppTextStyles.mono11(
                              color: AppColors.textSecondary)),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: Text('Clear',
                          style: AppTextStyles.mono11(color: AppColors.negative)),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await ShiftService.instance.reseedDemo();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        'Data cleared.',
                        style: AppTextStyles.mono11(
                            color: AppColors.textPrimary),
                      ),
                      backgroundColor: AppColors.backgroundMid,
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              }
            },
          ),

          const SizedBox(height: 32),

          // Version
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Forge & Flow · v1.0.0 · Barrio Legado',
              style: AppTextStyles.mono8(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final String label;
  final String description;
  final Color? labelColor;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.label,
    required this.description,
    this.labelColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        color: AppColors.backgroundMid,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: AppTextStyles.mono12(
                        color: labelColor ?? AppColors.textPrimary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style:
                        AppTextStyles.body13(color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 18, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }
}
