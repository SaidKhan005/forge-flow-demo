// Phase 11W.0 — OperatorWebInitFailedBody widget tests.
//
// Acceptance criteria:
//   A. Title "We couldn't reach Forge & Flow" is visible.
//   B. "Email support" button is visible and tappable.
//   C. Technical details are NOT initially visible.
//   D. Tapping "Show technical details" reveals the error message.
//   E. The raw --dart-define=… instruction does NOT appear in the
//      operator-visible primary body (only behind the disclosure).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/widgets/init_failed_app.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: Center(child: child)),
      );

  Future<void> sizeViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  final syntheticError = StateError(
    'OPERATOR_WEB_PROXY_BASE_URI is required when '
    'OPERATOR_WEB_DEMO_AUTH is false. Pass '
    '--dart-define=OPERATOR_WEB_PROXY_BASE_URI=https://proxy.forgeflow.app '
    'or set OPERATOR_WEB_DEMO_AUTH=true for the local-dev walkthrough.',
  );

  group('OperatorWebInitFailedBody', () {
    testWidgets(
      'A — title is visible',
      (tester) async {
        await sizeViewport(tester);

        await tester.pumpWidget(
          wrap(
            OperatorWebInitFailedBody(
              error: syntheticError,
              stack: StackTrace.current,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('init_failed_title')),
          findsOneWidget,
        );
        expect(
          find.text('We couldn’t reach Forge & Flow'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'B — Email support button is visible and tappable',
      (tester) async {
        await sizeViewport(tester);

        var tapped = false;

        await tester.pumpWidget(
          wrap(
            OperatorWebInitFailedBody(
              error: syntheticError,
              stack: StackTrace.current,
              onEmailSupport: () => tapped = true,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final button = find.byKey(
          const Key('init_failed_email_support_button'),
        );
        expect(button, findsOneWidget);

        await tester.tap(button);
        await tester.pumpAndSettle();

        expect(tapped, isTrue);
      },
    );

    testWidgets(
      'C — technical details are NOT visible before expansion',
      (tester) async {
        await sizeViewport(tester);

        await tester.pumpWidget(
          wrap(
            OperatorWebInitFailedBody(
              error: syntheticError,
              stack: StackTrace.current,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // The error message widget exists in the tree but is hidden
        // inside a collapsed ExpansionTile; find.text on the
        // error-type key should find nothing rendered.
        expect(
          find.byKey(const Key('init_failed_error_message')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'D — tapping "Show technical details" reveals the error message',
      (tester) async {
        await sizeViewport(tester);

        await tester.pumpWidget(
          wrap(
            OperatorWebInitFailedBody(
              error: syntheticError,
              stack: StackTrace.current,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Tap the ExpansionTile header.
        await tester.tap(
          find.byKey(const Key('init_failed_technical_details_tile')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('init_failed_error_message')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'E — --dart-define instruction is absent from primary operator body',
      (tester) async {
        await sizeViewport(tester);

        await tester.pumpWidget(
          wrap(
            OperatorWebInitFailedBody(
              error: syntheticError,
              stack: StackTrace.current,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // The primary body text (init_failed_body key) must not contain
        // developer-facing instruction text.
        final bodyWidget = tester.widget<Text>(
          find.byKey(const Key('init_failed_body')),
        );
        final bodyText = bodyWidget.data ?? '';
        expect(bodyText, isNot(contains('--dart-define')));
      },
    );
  });

  group('OperatorWebInitFailedApp', () {
    testWidgets(
      'full app wrapper mounts without error',
      (tester) async {
        await sizeViewport(tester);

        await tester.pumpWidget(
          OperatorWebInitFailedApp(
            error: syntheticError,
            stack: StackTrace.current,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('init_failed_title')),
          findsOneWidget,
        );
      },
    );
  });
}
