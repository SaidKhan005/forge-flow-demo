import 'package:flutter/material.dart';

import '../admin_button_styles.dart';

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
          style: AdminButtonStyles.secondary(
            minWidth: 36,
            minHeight: 36,
            padding: EdgeInsets.zero,
          ),
          child: const Icon(Icons.arrow_back, size: 18),
        ),
      ),
    );
  }
}
