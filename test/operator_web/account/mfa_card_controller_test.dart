// Lane B9.3 - MFA card controller state-machine tests.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/account/mfa_card_controller.dart';
import 'package:forge_and_flow/operator_web/account/operator_web_account_actions.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_team_gateway_providers.dart';
import 'package:forge_and_flow/operator_web/services/web_security_gateway.dart';

void main() {
  group('MfaCardController', () {
    test(
      'walks NotEnrolled -> Enrolled -> RemovalRequested -> Removable',
      () async {
        var now = DateTime.utc(2026, 5, 6, 12);
        final gateway = _FakeSecurityGateway(now: () => now);
        final actions = _FakeAccountActions(gateway);
        final controller = MfaCardController(
          initialMfaEnrolled: false,
          actions: actions,
          now: () => now,
        );
        addTearDown(controller.dispose);

        await controller.refresh();
        expect(controller.state.stage, MfaCardStage.notEnrolled);
        expect(controller.state.primaryButtonLabel, 'Turn on 2FA');

        gateway.addFactor();
        await controller.markEnrollmentConfirmed();
        expect(controller.state.stage, MfaCardStage.enrolled);
        expect(controller.state.primaryButtonLabel, 'Manage methods');

        await controller.requestRemoval();
        expect(controller.state.stage, MfaCardStage.removalRequested);
        expect(controller.state.headline, contains('24h 0m'));
        expect(actions.stepUpLabels, contains('removing 2FA'));

        now = now.add(const Duration(hours: 24, minutes: 1));
        await controller.refresh();
        expect(controller.state.stage, MfaCardStage.removable);
        expect(controller.state.primaryButtonLabel, 'Turn off 2FA');
        expect(
          controller.state.primaryActionKey,
          'account_section_mfa_turn_off_final',
        );

        gateway.completeDueRemovals();
        await controller.turnOffAfterGrace();
        expect(controller.state.stage, MfaCardStage.notEnrolled);
        expect(actions.stepUpLabels, contains('turning off 2FA'));
      },
    );

    test(
      'cancel during the grace window requires step-up and returns enrolled',
      () async {
        final now = DateTime.utc(2026, 5, 6, 12);
        final gateway = _FakeSecurityGateway(now: () => now)..addFactor();
        final actions = _FakeAccountActions(gateway);
        final controller = MfaCardController(
          initialMfaEnrolled: true,
          actions: actions,
          now: () => now,
        );
        addTearDown(controller.dispose);

        await controller.refresh();
        await controller.requestRemoval();
        expect(controller.state.stage, MfaCardStage.removalRequested);

        await controller.cancelRemoval();
        expect(controller.state.stage, MfaCardStage.enrolled);
        expect(actions.stepUpLabels, contains('cancelling 2FA removal'));
      },
    );

    test(
      'local enrolled fallback has no server-backed removal action',
      () async {
        final controller = MfaCardController(
          initialMfaEnrolled: true,
          actions: _LocalOnlyAccountActions(),
        );
        addTearDown(controller.dispose);

        await controller.refresh();
        expect(controller.state.stage, MfaCardStage.enrolled);
        expect(controller.state.primaryFactor, isNull);
        expect(controller.state.canRequestRemoval, isFalse);

        await controller.requestRemoval();
        expect(controller.state.stage, MfaCardStage.enrolled);
        expect(
          controller.state.errorMessage,
          contains('server-confirmed authenticator'),
        );
      },
    );
  });
}

class _FakeAccountActions extends OperatorWebAccountActions
    implements
        OperatorWebSecurityGatewayProvider,
        OperatorWebAccountMfaFreshnessGate {
  _FakeAccountActions(this.securityGateway);

  @override
  final WebSecurityGateway securityGateway;

  final List<String> stepUpLabels = <String>[];

  @override
  Future<void> requireFreshMfaForAccountSecurity({
    required String actionLabel,
  }) async {
    stepUpLabels.add(actionLabel);
  }

  @override
  Future<MfaEnrollmentArtifact> beginAccountMfaEnrollment({
    required String email,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> changeAccountPassword({
    required String currentPassword,
    required String newPassword,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> confirmAccountMfaEnrollment({
    required String enrollmentId,
    required String oneTimeCode,
  }) {
    throw UnimplementedError();
  }
}

class _LocalOnlyAccountActions extends OperatorWebAccountActions {
  @override
  Future<MfaEnrollmentArtifact> beginAccountMfaEnrollment({
    required String email,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> changeAccountPassword({
    required String currentPassword,
    required String newPassword,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> confirmAccountMfaEnrollment({
    required String enrollmentId,
    required String oneTimeCode,
  }) {
    throw UnimplementedError();
  }
}

class _FakeSecurityGateway implements WebSecurityGateway {
  _FakeSecurityGateway({required DateTime Function() now}) : _now = now;

  final DateTime Function() _now;
  final List<WebSecurityMfaFactor> factors = <WebSecurityMfaFactor>[];
  final List<WebSecurityMfaRemoval> removals = <WebSecurityMfaRemoval>[];
  var _removalSeq = 0;

  void addFactor() {
    factors.add(
      WebSecurityMfaFactor(
        factorId: 'factor-1',
        factorType: 'totp',
        enrolledAt: _now(),
        issuerLabel: 'Forge & Flow',
      ),
    );
  }

  void completeDueRemovals() {
    final now = _now().toUtc();
    final dueFactorIds = removals
        .where((removal) => !removal.executeAfter.isAfter(now))
        .map((removal) => removal.factorId)
        .toSet();
    factors.removeWhere((factor) => dueFactorIds.contains(factor.factorId));
  }

  @override
  Future<WebSecurityFactorsListed> listFactors() async {
    return WebSecurityFactorsListed(
      factors: List<WebSecurityMfaFactor>.unmodifiable(factors),
      removalRequests: List<WebSecurityMfaRemoval>.unmodifiable(removals),
    );
  }

  @override
  Future<WebSecurityRevokeFactorResult> revokeFactor({
    required String factorId,
    required String idempotencyKey,
  }) async {
    _removalSeq += 1;
    final executeAfter = _now().toUtc().add(const Duration(hours: 24));
    final removal = WebSecurityMfaRemoval(
      requestId: 'removal-$_removalSeq',
      factorId: factorId,
      status: 'pending',
      executeAfter: executeAfter,
    );
    removals.add(removal);
    return WebSecurityRevokeFactorResult(
      revoked: false,
      requestId: removal.requestId,
      executeAfter: executeAfter,
    );
  }

  @override
  Future<WebSecurityCancelRemovalResult> cancelFactorRemoval({
    required String requestId,
    required String idempotencyKey,
  }) async {
    removals.removeWhere((removal) => removal.requestId == requestId);
    return const WebSecurityCancelRemovalResult(cancelled: true);
  }

  @override
  Future<WebSecurityTotpEnrollment> beginTotpEnrollment({
    required String userEmail,
    required String idempotencyKey,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<WebSecurityMfaFactor> confirmTotpEnrollment({
    required String factorId,
    required String oneTimeCode,
    required String idempotencyKey,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<WebSecurityLoginHistoryListed> listLoginHistory() {
    throw UnimplementedError();
  }

  @override
  Future<WebSecurityPasswordChangeResult> changePassword({
    required String currentPassword,
    required String newPassword,
    required String idempotencyKey,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<WebSecurityRecoveryRequestResult> requestMfaRecovery({
    required String email,
    String? reason,
    required String idempotencyKey,
  }) {
    throw UnimplementedError();
  }
}
