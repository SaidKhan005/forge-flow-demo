import 'package:flutter/material.dart';
import '../routes/barrio_preview_role.dart';
import '../widgets/barrio_access_intent_banner.dart';
import '../widgets/barrio_destination_scaffold.dart';

/// Placeholder destination screen for supervisor-specific content.
class SupervisorContentScreenPlaceholder extends StatelessWidget {
  final BarrioPreviewRole previewRole;

  const SupervisorContentScreenPlaceholder({
    super.key,
    this.previewRole = BarrioPreviewRole.admin,
  });

  static const _audiences = ['Supervisor', 'Manager', 'Admin'];

  @override
  Widget build(BuildContext context) {
    return BarrioDestinationScaffold(
      title: 'Supervisor Content',
      subtitle: 'Supervisor-specific material',
      icon: Icons.supervisor_account,
      audienceLabels: _audiences,
      bodyText:
          'This area is reserved for supervisor-specific operational '
          'material and learning content.\n\n'
          'Exact content will be defined when supervisor material '
          'is ready.',
      footer: BarrioAccessIntentBanner(
        previewRole: previewRole,
        intendedAudiences: _audiences,
      ),
    );
  }
}
