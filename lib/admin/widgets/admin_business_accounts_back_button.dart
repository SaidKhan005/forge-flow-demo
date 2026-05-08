import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

const Key kAdminBusinessAccountsBackButtonKey = Key(
  'admin_business_accounts_back_button',
);

class AdminBusinessAccountsBackButton extends StatelessWidget {
  const AdminBusinessAccountsBackButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (onPressed == null) return const SizedBox.shrink();
    return Tooltip(
      message: 'Back to Business accounts',
      child: SizedBox.square(
        dimension: 36,
        child: OutlinedButton(
          key: kAdminBusinessAccountsBackButtonKey,
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            padding: EdgeInsets.zero,
            foregroundColor: AppColors.textPrimary,
            side: const BorderSide(color: AppColors.borderSubtle, width: 1),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          child: const Icon(Icons.arrow_back, size: 18),
        ),
      ),
    );
  }
}
