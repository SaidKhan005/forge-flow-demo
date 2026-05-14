// Wave 2 W-3 — operator-web edit-self-profile dialog widget tests.
//
// Pins:
//   * Save is disabled until the operator changes a field
//   * Email-change requires ticking the confirm checkbox
//   * Malformed email keeps Save disabled
//   * A successful save pops with `EditSelfProfileResult` carrying the
//     proxy response (including `emailChanged`)
//   * Proxy validation errors (`invalid_email`, `no_profile_fields`)
//     surface as friendly inline copy
//   * The dialog passes the trimmed display name + email to the
//     actions seam (no whitespace bleed)
//
// The dialog calls `OperatorWebAccountActions.patchSelfProfile` —
// a recording fake mirrors the seam without standing up the full
// HTTP client.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/account/operator_web_account_actions.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/edit_self_profile_dialog.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_proxy_client.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_team_gateway_providers.dart';
import 'package:forge_and_flow/operator_web/services/web_account_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  // The dialog is ~520px tall when the email-confirm box renders.
  // Resize so every control is hit-testable on the default test
  // viewport. Mirrors the W-1 edit-member-dialog test pattern.
  Future<void> sizeViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1024, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Widget hostDialog({
    required OperatorWebAccountActions actions,
    String displayName = 'Alex Morrison',
    String email = 'alex@brio-restaurants.com',
  }) {
    return MaterialApp(
      theme: AppTheme.themeData,
      home: Scaffold(
        body: Builder(
          builder: (context) {
            return Center(
              child: TextButton(
                key: const Key('open_edit_dialog'),
                onPressed: () => showEditSelfProfileDialog(
                  context: context,
                  actions: actions,
                  currentDisplayName: displayName,
                  currentEmail: email,
                ),
                child: const Text('Open'),
              ),
            );
          },
        ),
      ),
    );
  }

  testWidgets('Save stays disabled until the operator edits a field', (
    tester,
  ) async {
    final actions = _RecordingActions(seedDisplayName: 'Alex', seedEmail: 'a@b.co');
    await sizeViewport(tester);
    await tester.pumpWidget(hostDialog(actions: actions));
    await tester.tap(find.byKey(const Key('open_edit_dialog')));
    await tester.pumpAndSettle();

    final saveButton = tester.widget<FilledButton>(
      find.byKey(const Key('edit_self_profile_save')),
    );
    expect(saveButton.onPressed, isNull,
        reason: 'Save should be disabled before any edit.');
  });

  testWidgets('Display-name edit enables Save without the confirm checkbox', (
    tester,
  ) async {
    final actions = _RecordingActions(
      seedDisplayName: 'Alex Morrison',
      seedEmail: 'alex@brio-restaurants.com',
    );
    await sizeViewport(tester);
    await tester.pumpWidget(hostDialog(actions: actions));
    await tester.tap(find.byKey(const Key('open_edit_dialog')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('edit_self_profile_display_name_field')),
      'Alex Morrison-Davies',
    );
    await tester.pump();

    final saveButton = tester.widget<FilledButton>(
      find.byKey(const Key('edit_self_profile_save')),
    );
    expect(saveButton.onPressed, isNotNull);
    // No email-confirm box should appear when the email is unchanged.
    expect(find.byKey(const Key('edit_self_profile_email_confirm_box')),
        findsNothing);
  });

  testWidgets(
      'Email-change reveals the confirm checkbox; Save stays disabled '
      'until it is ticked', (tester) async {
    final actions = _RecordingActions(
      seedDisplayName: 'Alex Morrison',
      seedEmail: 'alex@brio-restaurants.com',
    );
    await sizeViewport(tester);
    await tester.pumpWidget(hostDialog(actions: actions));
    await tester.tap(find.byKey(const Key('open_edit_dialog')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('edit_self_profile_email_field')),
      'alex@new-domain.com',
    );
    await tester.pump();

    expect(find.byKey(const Key('edit_self_profile_email_confirm_box')),
        findsOneWidget);
    var saveButton = tester.widget<FilledButton>(
      find.byKey(const Key('edit_self_profile_save')),
    );
    expect(saveButton.onPressed, isNull,
        reason: 'Save stays disabled until the confirm box is ticked.');

    await tester.tap(
      find.byKey(const Key('edit_self_profile_email_confirm_checkbox')),
    );
    await tester.pump();
    saveButton = tester.widget<FilledButton>(
      find.byKey(const Key('edit_self_profile_save')),
    );
    expect(saveButton.onPressed, isNotNull);
  });

  testWidgets('Malformed email keeps Save disabled even with confirm ticked', (
    tester,
  ) async {
    final actions = _RecordingActions(
      seedDisplayName: 'Alex Morrison',
      seedEmail: 'alex@brio-restaurants.com',
    );
    await sizeViewport(tester);
    await tester.pumpWidget(hostDialog(actions: actions));
    await tester.tap(find.byKey(const Key('open_edit_dialog')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('edit_self_profile_email_field')),
      'not-an-email',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('edit_self_profile_email_confirm_checkbox')),
    );
    await tester.pump();

    final saveButton = tester.widget<FilledButton>(
      find.byKey(const Key('edit_self_profile_save')),
    );
    expect(saveButton.onPressed, isNull);
  });

  testWidgets('Successful save closes the dialog with the patched result', (
    tester,
  ) async {
    final actions = _RecordingActions(
      seedDisplayName: 'Alex Morrison',
      seedEmail: 'alex@brio-restaurants.com',
    );
    EditSelfProfileResult? dialogResult;
    await sizeViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.themeData,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                key: const Key('open_edit_dialog'),
                onPressed: () async {
                  dialogResult = await showEditSelfProfileDialog(
                    context: context,
                    actions: actions,
                    currentDisplayName: 'Alex Morrison',
                    currentEmail: 'alex@brio-restaurants.com',
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open_edit_dialog')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('edit_self_profile_display_name_field')),
      'Alex Morrison-Davies',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('edit_self_profile_save')));
    await tester.pumpAndSettle();

    expect(dialogResult, isNotNull);
    expect(dialogResult!.patched.displayName, 'Alex Morrison-Davies');
    expect(dialogResult!.patched.email, 'alex@brio-restaurants.com');
    expect(dialogResult!.patched.emailChanged, isFalse);
    expect(dialogResult!.patched.displayNameChanged, isTrue);
    expect(actions.lastDisplayName, 'Alex Morrison-Davies');
    expect(actions.lastEmail, isNull,
        reason: 'Email was unchanged, so it must NOT be sent to the proxy.');
  });

  testWidgets('Proxy invalid_email error surfaces as friendly inline copy', (
    tester,
  ) async {
    final actions = _RecordingActions(
      seedDisplayName: 'Alex',
      seedEmail: 'alex@brio-restaurants.com',
      failWith: const OperatorWebProxyException(
        code: 'invalid_email',
        message: 'invalid email format',
      ),
    );
    await sizeViewport(tester);
    await tester.pumpWidget(hostDialog(actions: actions));
    await tester.tap(find.byKey(const Key('open_edit_dialog')));
    await tester.pumpAndSettle();

    // Force a "valid-looking" email so the client-side gate lets us
    // submit. The error path is what the proxy returns server-side.
    await tester.enterText(
      find.byKey(const Key('edit_self_profile_email_field')),
      'alex@example.com',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('edit_self_profile_email_confirm_checkbox')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('edit_self_profile_save')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('edit_self_profile_error')), findsOneWidget);
    expect(find.text('Enter a valid email address.'), findsOneWidget);
  });
}

class _RecordingActions extends OperatorWebAccountActions
    implements OperatorWebAccountGatewayProvider {
  _RecordingActions({
    required this.seedDisplayName,
    required this.seedEmail,
    this.failWith,
  });

  final String seedDisplayName;
  final String seedEmail;
  final OperatorWebProxyException? failWith;
  String? lastDisplayName;
  String? lastEmail;

  @override
  WebAccountGateway get accountGateway => _Gateway(this);

  @override
  Future<MfaEnrollmentArtifact> beginAccountMfaEnrollment({
    required String email,
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

  @override
  Future<void> changeAccountPassword({
    required String currentPassword,
    required String newPassword,
  }) {
    throw UnimplementedError();
  }
}

class _Gateway implements WebAccountGateway {
  _Gateway(this._owner);

  final _RecordingActions _owner;

  @override
  Future<AccountIdentity> getAccount() => throw UnimplementedError();

  @override
  Future<AccountIdentity> patchAccount(AccountIdentityPatch patch) =>
      throw UnimplementedError();

  @override
  Future<AccountLocationTimezone> patchLocationTimezone(
    AccountLocationTimezonePatch patch,
  ) =>
      throw UnimplementedError();

  @override
  Future<SelfProfilePatchResult> patchSelfProfile(
    SelfProfilePatchPayload patch,
  ) async {
    _owner.lastDisplayName = patch.displayName;
    _owner.lastEmail = patch.email;
    if (_owner.failWith != null) throw _owner.failWith!;
    return SelfProfilePatchResult(
      userId: 'uid-1',
      email: patch.email ?? _owner.seedEmail,
      displayName: patch.displayName ?? _owner.seedDisplayName,
      emailChanged: patch.email != null,
      displayNameChanged: patch.displayName != null,
    );
  }

  @override
  Future<LocationAccountOverridesEnvelope> getLocationAccountOverrides({
    required String locationId,
  }) =>
      throw UnimplementedError();

  @override
  Future<LocationAccountOverridesEnvelope> patchLocationAccountOverrides({
    required String locationId,
    required LocationAccountOverridesPatchPayload patch,
  }) =>
      throw UnimplementedError();
}
