// Phase 2 closure - demo-fidelity scenario bundle tests.
//
// Pins the contract for the `OPERATOR_WEB_DEMO_SCENARIO` switch
// (OW-4 + U-1 + OW-8c + RP-15 demo enabler):
//
//   1. `resolveOperatorWebDemoScenario` normalizes whitespace / case
//      and falls back to `owner-location` for empty / unknown values
//      (fail-soft per slice spec).
//   2. The demo session constants for each scenario carry the right
//      identity shape — null `primaryLocationId` for the OW-4 inverse
//      `owner-business`, `mfaEnrolled: true` for OW-8c `mfa-enrolled`,
//      and the existing manager session for `manager-once`.
//   3. `DemoOperatorWebAuthSource` honors the
//      `emitNeedsSignInOnSignOut` knob so the U-1 scenario
//      (`signed-out-live`) lands sign-out on `OperatorWebNeedsSignIn`
//      (the live LoginScreen) instead of the magic-link Welcome.
//   4. `DemoWebSecurityGateway.seedPendingFactorRemoval` populates
//      the gateway's pending-removal slot so the OW-8c
//      `MfaCardStage.removalRequested` walkthrough renders on first
//      paint (the `mfa-pending-removal` scenario).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/demo/operator_web_demo_scenario.dart';
import 'package:forge_and_flow/operator_web/services/demo_security_gateway.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';

void main() {
  group('resolveOperatorWebDemoScenario', () {
    test('empty value falls back to owner-location', () {
      expect(resolveOperatorWebDemoScenario(''), 'owner-location');
      expect(resolveOperatorWebDemoScenario('   '), 'owner-location');
    });

    test('unknown value falls back to owner-location', () {
      expect(
        resolveOperatorWebDemoScenario('not-a-real-scenario'),
        'owner-location',
      );
    });

    test('normalizes whitespace and case', () {
      expect(
        resolveOperatorWebDemoScenario('  MFA-ENROLLED  '),
        'mfa-enrolled',
      );
      expect(
        resolveOperatorWebDemoScenario('Owner-Business'),
        'owner-business',
      );
    });

    test('every published scenario token is accepted', () {
      // Pins the published catalog so a deletion / typo in
      // `kOperatorWebDemoScenarios` would surface here rather than
      // silently fall back to `owner-location`.
      const tokens = <String>{
        'owner-location',
        'owner-location-completed',
        'owner-business',
        'manager-once',
        'mfa-enrolled',
        'mfa-pending-removal',
        'signed-out-live',
      };
      expect(kOperatorWebDemoScenarios, tokens);
      expect(
        kOperatorWebDemoScenarioDefault,
        'owner-location',
      );
      for (final token in tokens) {
        expect(
          resolveOperatorWebDemoScenario(token),
          token,
          reason: 'Expected $token to resolve to itself',
        );
      }
    });
  });

  group('Demo scenario session fixtures', () {
    test('owner-business carries a null primaryLocationId (OW-4 inverse)', () {
      const session = kDemoOperatorWebBusinessSession;
      expect(session.primaryLocationId, isNull);
      expect(session.roles, contains('operator_owner'));
      // The Locations nav row keys off `isLocationScope`; a null
      // primary location forces the management scope to default to
      // the operator (business) scope so the row appears.
      expect(session.primaryLocationName, 'Demo Restaurant Group');
    });

    test('owner-location default carries a pinned primaryLocationId', () {
      expect(kDemoOperatorWebSession.primaryLocationId, 'demo-location');
      expect(kDemoOperatorWebSession.mfaEnrolled, isFalse);
    });

    test('mfa-enrolled session flags mfaEnrolled=true (OW-8c)', () {
      const session = kDemoOperatorWebMfaEnrolledSession;
      expect(session.mfaEnrolled, isTrue);
      expect(session.primaryLocationId, 'demo-location');
    });

    test('manager-once session is the existing LocationManager session', () {
      const session = kDemoOperatorWebLocationManagerSession;
      expect(session.roles, contains('location_manager'));
      expect(session.primaryLocationId, 'demo-location');
    });
  });

  group('DemoOperatorWebAuthSource.signOut', () {
    test(
        'default sign-out emits OperatorWebSignedOut (Welcome / NeedsToken landing)',
        () async {
      final source = DemoOperatorWebAuthSource(
        initial: const OperatorWebCompleted(session: kDemoOperatorWebSession),
      );
      addTearDown(source.dispose);
      await source.signOut();
      expect(source.current, isA<OperatorWebSignedOut>());
    });

    test(
        'emitNeedsSignInOnSignOut routes sign-out to OperatorWebNeedsSignIn '
        '(U-1 signed-out-live)', () async {
      final source = DemoOperatorWebAuthSource(
        initial: const OperatorWebCompleted(session: kDemoOperatorWebSession),
        emitNeedsSignInOnSignOut: true,
      );
      addTearDown(source.dispose);
      await source.signOut();
      expect(source.current, isA<OperatorWebNeedsSignIn>());
    });
  });

  group('DemoWebSecurityGateway.seedPendingFactorRemoval', () {
    test('drops a pending removal row matching the seeded factor', () async {
      final gateway = DemoWebSecurityGateway();
      final requestId = gateway.seedPendingFactorRemoval(
        factorId: kDemoSecurityExistingFactorId,
        delay: const Duration(hours: 18),
      );
      expect(requestId, isNotNull);

      final listed = await gateway.listFactors();
      expect(listed.removalRequests, isNotEmpty);
      final removal = listed.removalRequests.first;
      expect(removal.factorId, kDemoSecurityExistingFactorId);
      expect(removal.status, 'pending');
    });

    test('no-ops when the factor id is unknown', () {
      final gateway = DemoWebSecurityGateway();
      final requestId = gateway.seedPendingFactorRemoval(
        factorId: 'not-a-real-factor',
      );
      expect(requestId, isNull);
    });
  });
}
