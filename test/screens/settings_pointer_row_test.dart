import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/screens/settings/settings_pointer_row.dart';
import 'package:forge_and_flow/services/auth/handoff_code_client.dart';
import 'package:forge_and_flow/services/auth/handoff_code_gateway.dart';

void main() {
  testWidgets('renders an OutlinedButton.icon for the operator-web deflection', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        SettingsPointerRow(
          label: 'Manage Account on Ops Web',
          opWebPath: 'my-account',
          navId: 'my_account',
          handoffCodeGateway: _FakeHandoffGateway(
            link: Uri.parse(
              'https://app.forgeflow.app/handoff?code=abc&nav=my_account',
            ),
          ),
        ),
      ),
    );

    // FU-mobile-settings-pointer-buttons: the row now renders as a
    // real button rather than tappable text with a leading icon.
    // `OutlinedButton.icon` returns a private `_OutlinedButtonWithIcon`
    // subtype, so we match by `is OutlinedButton` via predicate rather
    // than `find.byType(OutlinedButton)` (which is exact-type only).
    final buttonFinder = find.byWidgetPredicate((w) => w is OutlinedButton);
    expect(buttonFinder, findsOneWidget);
    expect(find.text('Manage Account on Ops Web'), findsOneWidget);
    // The helper URL line is still rendered for context.
    expect(find.text('https://app.forgeflow.app/my-account'), findsOneWidget);

    final button = tester.widget<OutlinedButton>(buttonFinder);
    expect(button.onPressed, isNotNull);
  });

  testWidgets('renders a disabled OutlinedButton when opWebPath is empty', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const SettingsPointerRow(
          label: 'Manage future thing',
          opWebPath: '',
        ),
      ),
    );

    final buttonFinder = find.byWidgetPredicate((w) => w is OutlinedButton);
    expect(buttonFinder, findsOneWidget);
    final button = tester.widget<OutlinedButton>(buttonFinder);
    expect(button.onPressed, isNull);
    expect(find.text('Manage future thing (coming soon)'), findsOneWidget);
  });

  testWidgets('mints and launches Operator Web handoff URL', (tester) async {
    final gateway = _FakeHandoffGateway(
      link: Uri.parse(
        'https://app.forgeflow.app/handoff?code=abc&nav=my_account',
      ),
    );
    final launched = <Uri>[];

    await tester.pumpWidget(
      _wrap(
        SettingsPointerRow(
          label: 'Manage Account on Ops Web',
          opWebPath: 'my-account',
          navId: 'my_account',
          handoffCodeGateway: gateway,
          launchExternalUrl: (url) async {
            launched.add(url);
            return true;
          },
        ),
      ),
    );

    await tester.tap(find.text('Manage Account on Ops Web'));
    await tester.pump();

    expect(gateway.targets.single.navId, 'my_account');
    expect(gateway.targets.single.targetPath, '/my-account');
    expect(
      launched.single,
      Uri.parse('https://app.forgeflow.app/handoff?code=abc&nav=my_account'),
    );
    expect(find.text('Opening Operator Web'), findsOneWidget);
  });

  testWidgets('falls back to clipboard when proxy is unavailable', (
    tester,
  ) async {
    final copied = <String>[];

    await tester.pumpWidget(
      _wrap(
        SettingsPointerRow(
          label: 'Manage Wage on Ops Web',
          opWebPath: 'wage-authority',
          navId: 'wage_authority',
          handoffCodeGateway: _FakeHandoffGateway(
            error: const HandoffCodeMintRejected(
              code: 'auth_handoff_unavailable',
              message: 'handoff unavailable',
              statusCode: 503,
            ),
          ),
          copyToClipboard: (value) async => copied.add(value),
        ),
      ),
    );

    await tester.tap(find.text('Manage Wage on Ops Web'));
    await tester.pump();

    expect(copied, <String>['https://app.forgeflow.app/wage-authority']);
    expect(
      find.text('Operator Web link copied - open in browser'),
      findsOneWidget,
    );
  });
}

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );
}

class _FakeHandoffGateway implements HandoffCodeGateway {
  _FakeHandoffGateway({this.link, this.error});

  final Uri? link;
  final Object? error;
  final List<HandoffDeepLinkTarget> targets = <HandoffDeepLinkTarget>[];

  @override
  Future<HandoffDeepLink> createDeepLink({
    required HandoffDeepLinkTarget target,
  }) async {
    targets.add(target);
    final thrown = error;
    if (thrown != null) throw thrown;
    return HandoffDeepLink(url: link!, expiresIn: const Duration(seconds: 60));
  }
}
