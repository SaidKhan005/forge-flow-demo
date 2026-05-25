import 'package:flutter/material.dart';

import 'admin_action_controls.dart';

const Key kAdminBusinessAccountsBackButtonKey = Key(
  'admin_business_accounts_back_button',
);

class AdminBusinessAccountsBackButton extends StatelessWidget {
  const AdminBusinessAccountsBackButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (onPressed == null) return const SizedBox.shrink();
    return AdminIconAction(
      key: kAdminBusinessAccountsBackButtonKey,
      icon: Icons.arrow_back,
      tooltip: 'Back to Business accounts',
      onPressed: onPressed,
    );
  }
}
