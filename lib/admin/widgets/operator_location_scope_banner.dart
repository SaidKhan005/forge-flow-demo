import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../admin_route_handoff.dart';

class OperatorLocationScopeBanner extends StatelessWidget {
  const OperatorLocationScopeBanner({
    super.key,
    required this.scope,
    required this.surfaceName,
    required this.onClear,
  });

  final AdminOperatorLocationScopeIntent scope;
  final String surfaceName;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_operator_location_scope_banner'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.peacock.withValues(alpha: 0.35),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final text = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                scope.displayLabel,
                style: AppTextStyles.body14(color: AppColors.textPrimary),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          );
          final button = OutlinedButton.icon(
            key: const Key('admin_operator_location_scope_clear'),
            style: AdminButtonStyles.secondary(
              foregroundColor: AppColors.peacockDark,
              borderColor: AppColors.peacock.withValues(alpha: 0.55),
              minWidth: 108,
              minHeight: 36,
            ),
            onPressed: onClear,
            icon: const Icon(Icons.filter_alt_off_outlined, size: 14),
            label: const Text('Show all'),
          );
          if (constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [text, const SizedBox(height: 10), button],
            );
          }
          return Row(
            children: [
              Expanded(child: text),
              const SizedBox(width: 12),
              button,
            ],
          );
        },
      ),
    );
  }
}
