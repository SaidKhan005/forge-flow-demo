import 'package:flutter/material.dart';

import 'admin_action_controls.dart';

const Key kAdminPreviousScreenBackButtonKey = Key(
  'admin_previous_screen_back_button',
);

class AdminPreviousScreenBackButton extends StatelessWidget {
  const AdminPreviousScreenBackButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (onPressed == null) return const SizedBox.shrink();
    return AdminIconAction(
      key: kAdminPreviousScreenBackButtonKey,
      icon: Icons.arrow_back,
      tooltip: 'Back',
      onPressed: onPressed,
    );
  }
}
