import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/forge_flow_app.dart';
import 'package:forge_and_flow/services/auth_login_service.dart';
import 'package:forge_and_flow/services/secure_session_storage.dart';
import 'package:forge_and_flow/state/auth_session_notifier.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ForgeFlowApp());
    expect(find.byType(ForgeFlowApp), findsOneWidget);
  });

  testWidgets('Firebase-auth app starts behind login gate', (tester) async {
    final notifier = AuthSessionNotifier(
      loginService: const ScaffoldFailingAuthLoginService(),
      storage: InMemorySecureSessionStorage(),
    );
    notifier.debugSetState(const AuthSessionUnauthenticated());

    await tester.pumpWidget(
      ChangeNotifierProvider<AuthSessionNotifier>.value(
        value: notifier,
        child: const ForgeFlowApp(requireAuth: true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('login_email_field')), findsOneWidget);
    expect(
      find.byKey(const Key('login_forgot_password_button')),
      findsOneWidget,
    );
    expect(find.byType(AppShell), findsNothing);

    await tester.tap(find.byKey(const Key('login_forgot_password_button')));
    await tester.pump();

    expect(
      find.text('Enter your email to reset your password.'),
      findsOneWidget,
    );
  });
}
