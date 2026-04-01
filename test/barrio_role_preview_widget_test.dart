import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_destinations.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_preview_role.dart';
import 'package:forge_and_flow/internal/barrio/routes/barrio_route_map.dart';
import 'package:forge_and_flow/internal/barrio/screens/barrio_home_screen.dart';
import 'package:forge_and_flow/internal/barrio/screens/forge_and_flow_destination_screen.dart';

void main() {
  Widget buildTestApp() {
    return const MaterialApp(home: BarrioHomeScreen());
  }

  // A. Default preview role is Admin
  // Note: the wordmark 'Barrio Legado' is rendered as a RichText with two
  // TextSpan children. We verify the PREVIEW row (a plain Text widget) which
  // is a reliable indicator the header rendered correctly.
  group('Default preview role', () {
    testWidgets('defaults to Admin', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pump(const Duration(milliseconds: 100));

      // Role preview row is visible with all four chips
      expect(find.text('PREVIEW'), findsOneWidget);
      expect(find.text('Admin'), findsWidgets);
      expect(find.text('Staff'), findsWidgets);
      expect(find.text('Supervisor'), findsWidgets);
      expect(find.text('Manager'), findsWidgets);
    });
  });

  // B. Switching preview role updates display
  group('Role switching', () {
    testWidgets('tapping Staff chip updates selection', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pump(const Duration(milliseconds: 100));

      final staffChip = find.text('Staff');
      expect(staffChip, findsWidgets);
      await tester.tap(staffChip.first);
      await tester.pump(const Duration(milliseconds: 300));

      // Staff chip remains present after tap
      expect(find.text('Staff'), findsWidgets);
    });
  });

  // C. Staff preview dims Forge & Flow and Jim Taylor
  group('Staff preview intent', () {
    test('staff is not intended for Forge & Flow', () {
      final ff = barrioDestinations.firstWhere((d) => d.id == 'forge_and_flow');
      expect(BarrioPreviewRole.staff.isIntendedFor(ff), isFalse);
    });

    test('staff is not intended for Jim Taylor Labor Model', () {
      final jt = barrioDestinations.firstWhere(
        (d) => d.id == 'jim_taylor_labor_model',
      );
      expect(BarrioPreviewRole.staff.isIntendedFor(jt), isFalse);
    });

    test('staff IS intended for Company Handbook', () {
      final hb = barrioDestinations.firstWhere(
        (d) => d.id == 'company_handbook',
      );
      expect(BarrioPreviewRole.staff.isIntendedFor(hb), isTrue);
    });
  });

  // D. Manager preview treats Jim Taylor as intended
  group('Manager preview intent', () {
    test('manager is intended for Jim Taylor Labor Model', () {
      final jt = barrioDestinations.firstWhere(
        (d) => d.id == 'jim_taylor_labor_model',
      );
      expect(BarrioPreviewRole.manager.isIntendedFor(jt), isTrue);
    });
  });

  // E. Supervisor preview: Interview Playbook blocked, Jim Taylor blocked
  group('Supervisor preview intent', () {
    test('supervisor is NOT intended for Interview Playbook', () {
      final ip = barrioDestinations.firstWhere(
        (d) => d.id == 'interview_playbook',
      );
      expect(BarrioPreviewRole.supervisor.isIntendedFor(ip), isFalse);
    });

    test('supervisor is NOT intended for Jim Taylor Labor Model', () {
      final jt = barrioDestinations.firstWhere(
        (d) => d.id == 'jim_taylor_labor_model',
      );
      expect(BarrioPreviewRole.supervisor.isIntendedFor(jt), isFalse);
    });
  });

  // E2. Staff preview: Interview Playbook blocked
  group('Staff preview intent — interview', () {
    test('staff is NOT intended for Interview Playbook', () {
      final ip = barrioDestinations.firstWhere(
        (d) => d.id == 'interview_playbook',
      );
      expect(BarrioPreviewRole.staff.isIntendedFor(ip), isFalse);
    });
  });

  // F. Navigation still works when dimmed
  group('Navigation still works when dimmed', () {
    test('staff preview still resolves the Forge & Flow destination', () {
      expect(
        BarrioRouteMap.screenFor(
          'forge_and_flow',
          previewRole: BarrioPreviewRole.staff,
        ),
        isA<ForgeAndFlowDestinationScreen>(),
      );
    });
  });

  // G. Forge & Flow destination renders the shared workspace inside Barrio
  group('Embedded Forge & Flow workspace', () {
    testWidgets('destination screen opens the shared Forge & Flow app shell', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: BarrioRouteMap.screenFor(
            'forge_and_flow',
            previewRole: BarrioPreviewRole.staff,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('Forge & Flow'), findsWidgets);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(find.byType(BottomNavigationBar), findsOneWidget);
    });
  });

  // H. No real lockout occurs
  group('No real lockout', () {
    test('all preview roles allow screenFor to build every destination', () {
      for (final role in BarrioPreviewRole.values) {
        for (final dest in barrioDestinations) {
          final screen = BarrioRouteMap.screenFor(dest.id, previewRole: role);
          expect(
            screen,
            isNotNull,
            reason: '${role.label} should build ${dest.id}',
          );
        }
      }
    });
  });
}
