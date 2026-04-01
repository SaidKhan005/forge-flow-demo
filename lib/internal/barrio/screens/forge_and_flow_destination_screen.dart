import 'package:flutter/material.dart';
import '../../../forge_flow_app.dart' show AppShell, ForgeFlowScope;
import '../routes/barrio_preview_role.dart';

/// Barrio shell destination screen for the Forge & Flow entry point.
class ForgeAndFlowDestinationScreen extends StatelessWidget {
  final BarrioPreviewRole previewRole;

  const ForgeAndFlowDestinationScreen({
    super.key,
    this.previewRole = BarrioPreviewRole.admin,
  });

  @override
  Widget build(BuildContext context) {
    return const ForgeFlowScope(child: AppShell(embeddedInBarrio: true));
  }
}
