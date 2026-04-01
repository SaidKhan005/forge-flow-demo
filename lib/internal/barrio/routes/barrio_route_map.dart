import 'package:flutter/material.dart';
import 'barrio_destinations.dart';
import 'barrio_preview_role.dart';
import '../screens/barrio_home_screen.dart';
import '../screens/forge_and_flow_destination_screen.dart';
import '../screens/company_handbook_screen.dart';
import '../screens/interview_playbook_screen.dart';
import '../screens/jim_taylor_model_screen.dart';
import '../screens/preston_lee_model_coming_soon_screen.dart';
import '../screens/supervisor_content_screen_placeholder.dart';

/// Typed route map for the Barrio internal shell.
///
/// Every Barrio destination has exactly one route entry here.
/// The shell reads this map to navigate -- no stringly-typed
/// route switching is embedded in widgets.
///
/// This is a private internal route map. It is not registered
/// in the public Forge & Flow `MaterialApp` route table.
class BarrioRouteMap {
  BarrioRouteMap._();

  /// The home route -- the Barrio shell root.
  static const String home = '/barrio';

  /// Route path for each destination, keyed by destination id.
  static const Map<String, String> destinationPaths = {
    'forge_and_flow': '/barrio/forge-and-flow',
    'company_handbook': '/barrio/company-handbook',
    'interview_playbook': '/barrio/interview-playbook',
    'jim_taylor_labor_model': '/barrio/jim-taylor-labor-model',
    'preston_lee_model': '/barrio/preston-lee-model',
    'supervisor_content': '/barrio/supervisor-content',
  };

  /// Returns the route path for a [BarrioDestination] by its id.
  static String pathFor(BarrioDestination destination) {
    return destinationPaths[destination.id] ?? home;
  }

  /// Builds the destination screen widget for a given destination id.
  ///
  /// [previewRole] defaults to [BarrioPreviewRole.admin] so direct
  /// construction in tests remains safe.
  static Widget screenFor(
    String destinationId, {
    BarrioPreviewRole previewRole = BarrioPreviewRole.admin,
  }) {
    switch (destinationId) {
      case 'forge_and_flow':
        return ForgeAndFlowDestinationScreen(previewRole: previewRole);
      case 'company_handbook':
        return CompanyHandbookScreen(previewRole: previewRole);
      case 'interview_playbook':
        return InterviewPlaybookScreen(previewRole: previewRole);
      case 'jim_taylor_labor_model':
        return JimTaylorModelScreen(previewRole: previewRole);
      case 'preston_lee_model':
        return PrestonLeeModelComingSoonScreen(previewRole: previewRole);
      case 'supervisor_content':
        return SupervisorContentScreenPlaceholder(previewRole: previewRole);
      default:
        return const BarrioHomeScreen();
    }
  }

  /// Pushes the destination screen for [destination] onto the navigator.
  static void navigateTo(
    BuildContext context,
    BarrioDestination destination, {
    BarrioPreviewRole previewRole = BarrioPreviewRole.admin,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            screenFor(destination.id, previewRole: previewRole),
      ),
    );
  }
}
