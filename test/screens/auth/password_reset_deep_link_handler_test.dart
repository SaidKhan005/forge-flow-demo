// Phase 9.UX.7 - PasswordResetDeepLinkHandler tests.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/screens/auth/password_reset_confirm_screen.dart';
import 'package:forge_and_flow/screens/auth/password_reset_deep_link_handler.dart';
import 'package:forge_and_flow/services/auth/password_reset_deep_link_source.dart';
import 'package:forge_and_flow/services/auth/password_reset_gateway.dart';

void main() {
  group('PasswordResetDeepLinkHandler.extractOobCode', () {
    test('returns oobCode for forgeflow://reset-password URI', () {
      final code = PasswordResetDeepLinkHandler.extractOobCode(
        Uri.parse('forgeflow://reset-password?oobCode=abc-123'),
      );
      expect(code, equals('abc-123'));
    });

    test('accepts mode=resetPassword query', () {
      final code = PasswordResetDeepLinkHandler.extractOobCode(
        Uri.parse(
          'forgeflow://reset-password?mode=resetPassword&oobCode=xyz',
        ),
      );
      expect(code, equals('xyz'));
    });

    test('rejects URIs from other schemes', () {
      final code = PasswordResetDeepLinkHandler.extractOobCode(
        Uri.parse('https://example.test/reset-password?oobCode=abc'),
      );
      expect(code, isNull);
    });

    test('rejects URIs with the wrong path / host', () {
      final code = PasswordResetDeepLinkHandler.extractOobCode(
        Uri.parse('forgeflow://sign-in?oobCode=abc'),
      );
      expect(code, isNull);
    });

    test('rejects URIs without oobCode', () {
      final code = PasswordResetDeepLinkHandler.extractOobCode(
        Uri.parse('forgeflow://reset-password'),
      );
      expect(code, isNull);
    });

    test('rejects mode that is not resetPassword', () {
      final code = PasswordResetDeepLinkHandler.extractOobCode(
        Uri.parse(
          'forgeflow://reset-password?mode=verifyEmail&oobCode=abc',
        ),
      );
      expect(code, isNull);
    });
  });

  group('PasswordResetDeepLinkHandler widget', () {
    testWidgets(
      'pushes PasswordResetConfirmScreen on a matching incoming URI',
      (tester) async {
        final source = InMemoryPasswordResetDeepLinkSource();
        addTearDown(source.close);
        const gateway = DemoPasswordResetGateway();

        await tester.pumpWidget(
          MaterialApp(
            home: PasswordResetDeepLinkHandler(
              source: source,
              gateway: gateway,
              child: const Scaffold(body: Text('login-shell')),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('login-shell'), findsOneWidget);
        expect(find.byType(PasswordResetConfirmScreen), findsNothing);

        source.emit(
          Uri.parse('forgeflow://reset-password?oobCode=link-oob'),
        );
        await tester.pumpAndSettle();

        expect(find.byType(PasswordResetConfirmScreen), findsOneWidget);
        final confirmScreen = tester.widget<PasswordResetConfirmScreen>(
          find.byType(PasswordResetConfirmScreen),
        );
        expect(confirmScreen.oobCode, equals('link-oob'));
      },
    );

    testWidgets(
      'pushes PasswordResetConfirmScreen on a cold-start initialLink',
      (tester) async {
        final source = InMemoryPasswordResetDeepLinkSource(
          initial: Uri.parse(
            'forgeflow://reset-password?oobCode=cold-oob',
          ),
        );
        addTearDown(source.close);
        const gateway = DemoPasswordResetGateway();

        await tester.pumpWidget(
          MaterialApp(
            home: PasswordResetDeepLinkHandler(
              source: source,
              gateway: gateway,
              child: const Scaffold(body: Text('login-shell')),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(PasswordResetConfirmScreen), findsOneWidget);
        final confirmScreen = tester.widget<PasswordResetConfirmScreen>(
          find.byType(PasswordResetConfirmScreen),
        );
        expect(confirmScreen.oobCode, equals('cold-oob'));
      },
    );

    testWidgets('ignores unrelated URIs', (tester) async {
      final source = InMemoryPasswordResetDeepLinkSource();
      addTearDown(source.close);
      const gateway = DemoPasswordResetGateway();

      await tester.pumpWidget(
        MaterialApp(
          home: PasswordResetDeepLinkHandler(
            source: source,
            gateway: gateway,
            child: const Scaffold(body: Text('login-shell')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      source.emit(Uri.parse('forgeflow://sign-in?oobCode=abc'));
      source.emit(Uri.parse('https://example.test/foo'));
      await tester.pumpAndSettle();

      expect(find.byType(PasswordResetConfirmScreen), findsNothing);
    });
  });
}
