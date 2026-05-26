// Advisor Mobile Chat screen -- Slice D2 widget tests.
//
// Covers:
//   - Empty state shows example chips.
//   - Tapping a chip prefills the input.
//   - Ask -> loading indicator -> answer + citations.
//   - Multi-turn: conversationId from first answer carried into second ask.
//   - notSwitchedOn renders full-screen off-state (no composer).
//   - usageCapReached renders full-screen cap-state (no composer).
//   - notConfigured renders inline error (composer still present).
//   - serverError renders inline retry message (composer still present).
//   - networkError renders inline retry message (composer still present).
//   - HP #6: no execute / apply / command button anywhere.
//   - HP #6: reassurance line always visible.
//   - HP #2: demo and live-fake gateways both follow the same UI code path.
//   - No em dash in any operator-facing string.
//
// UX no-em-dash law: strings asserted below contain no U+2014.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/screens/advisor/advisor_mobile_chat_screen.dart';
import 'package:forge_and_flow/services/advisor/advisor_answer_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

// ---- Fake gateway -------------------------------------------------------

/// Controllable in-memory gateway for widget tests.
class _FakeAdvisorAnswerGateway implements AdvisorAnswerGateway {
  _FakeAdvisorAnswerGateway({
    AdvisorAnswerResult? nextResult,
    AdvisorAnswerException? nextException,
  }) : _nextResult = nextResult,
       _nextException = nextException;

  AdvisorAnswerResult? _nextResult;
  AdvisorAnswerException? _nextException;

  /// Records every call so tests can assert multi-turn behavior.
  final List<({String question, String? conversationId})> calls =
      <({String question, String? conversationId})>[];

  void enqueueResult(AdvisorAnswerResult result) {
    _nextResult = result;
    _nextException = null;
  }

  void enqueueException(AdvisorAnswerException exception) {
    _nextException = exception;
    _nextResult = null;
  }

  @override
  Future<AdvisorAnswerResult> ask({
    required String question,
    String? conversationId,
  }) async {
    calls.add((question: question, conversationId: conversationId));
    final exc = _nextException;
    if (exc != null) {
      _nextException = null;
      throw exc;
    }
    final result = _nextResult;
    if (result != null) {
      _nextResult = null;
      return result;
    }
    // Default canned answer when no override is set.
    return const AdvisorAnswerResult(
      answer:
          'You could consider trimming the early prep block on slower mornings.',
      citations: <AdvisorCitation>[
        AdvisorCitation(
          sourceId: 'target_cycle:demo',
          toolName: 'get_active_targets',
          title: 'Active target cycle',
        ),
      ],
      conversationId: 'conv-mobile-test-001',
      turnIndex: 1,
    );
  }
}

/// Controlled gateway that blocks until the completer resolves.
class _ControlledGateway implements AdvisorAnswerGateway {
  _ControlledGateway(this._completer);
  final Completer<AdvisorAnswerResult> _completer;

  @override
  Future<AdvisorAnswerResult> ask({
    required String question,
    String? conversationId,
  }) =>
      _completer.future;
}

// ---- Helpers ----------------------------------------------------------------

Widget _wrap(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppTheme.themeData,
  home: Scaffold(body: child),
);

Widget _screen(AdvisorAnswerGateway gateway) =>
    _wrap(AdvisorMobileChatScreen(gateway: gateway));

Future<void> _sizeViewport(WidgetTester tester) async {
  // Emulate a ~390pt wide mobile screen at 1x DPR (logical pixels = physical
  // pixels) so the widget tree has comfortable layout room. Real devices have
  // 3x DPR, but widget tests don't need the DPR to match reality -- they need
  // the logical pixel size to exercise the mobile-narrow layout without
  // triggering overflow on the test runner's virtual display.
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

// ---- Tests ------------------------------------------------------------------

void main() {
  group('AdvisorMobileChatScreen', () {
    // ---- Empty state --------------------------------------------------------

    testWidgets('shows example chips in empty state', (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway();
      await tester.pumpWidget(_screen(gateway));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Why was labor over target on Saturday'),
        findsOneWidget,
      );
      expect(
        find.textContaining('How does this week compare'),
        findsOneWidget,
      );
      expect(
        find.textContaining('What is driving my cost per labor hour'),
        findsOneWidget,
      );
    });

    testWidgets('tapping example chip prefills the input field', (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway();
      await tester.pumpWidget(_screen(gateway));
      await tester.pumpAndSettle();

      await tester.tap(
        find.textContaining('How does this week compare'),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      final input = tester.widget<TextField>(
        find.byKey(const Key('advisor_mobile_chat_input')),
      );
      expect(input.controller?.text, contains('How does this week compare'));
    });

    // ---- Loading state ------------------------------------------------------

    testWidgets('shows loading indicator while waiting', (tester) async {
      await _sizeViewport(tester);
      final completer = Completer<AdvisorAnswerResult>();
      final gateway = _ControlledGateway(completer);
      await tester.pumpWidget(_screen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_mobile_chat_input')),
        'Why is labor over budget?',
      );
      await tester.tap(find.byKey(const Key('advisor_mobile_chat_send_button')));
      await tester.pump();

      // Loading indicator visible.
      expect(
        find.byKey(const Key('advisor_mobile_chat_loading_indicator')),
        findsOneWidget,
      );

      // Resolve the gateway.
      completer.complete(
        const AdvisorAnswerResult(
          answer: 'Here is what I see.',
          citations: <AdvisorCitation>[],
          conversationId: 'conv-load-mobile',
          turnIndex: 1,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('advisor_mobile_chat_loading_indicator')),
        findsNothing,
      );
      expect(find.text('Here is what I see.'), findsOneWidget);
    });

    // ---- Answer + citations -------------------------------------------------

    testWidgets('shows ADVISOR label, serif lead, answer, and citation toggle',
        (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway(
        nextResult: const AdvisorAnswerResult(
          answer: 'You could consider trimming the prep block.',
          citations: <AdvisorCitation>[
            AdvisorCitation(
              sourceId: 'target_cycle:test',
              toolName: 'get_active_targets',
              title: 'Active target cycle',
              snippet: 'Target CPLH 8.0',
            ),
          ],
          conversationId: 'conv-mobile-001',
          turnIndex: 1,
        ),
      );
      await tester.pumpWidget(_screen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_mobile_chat_input')),
        'How am I doing on labor?',
      );
      await tester.tap(find.byKey(const Key('advisor_mobile_chat_send_button')));
      await tester.pumpAndSettle();

      // ADVISOR label (uppercase, peacock).
      expect(
        find.byKey(const Key('advisor_mobile_chat_advisor_label')),
        findsOneWidget,
      );
      // Serif lead line.
      expect(find.text('Here is what I would consider'), findsOneWidget);
      // Answer body.
      expect(
        find.text('You could consider trimming the prep block.'),
        findsOneWidget,
      );
      // Citation toggle visible.
      expect(find.text('Where this comes from'), findsOneWidget);
    });

    testWidgets('citations expand on tap', (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway(
        nextResult: const AdvisorAnswerResult(
          answer: 'An answer with a citation.',
          citations: <AdvisorCitation>[
            AdvisorCitation(
              sourceId: 'target_cycle:demo',
              toolName: 'get_active_targets',
              title: 'Active target cycle',
              snippet: 'Target CPLH 8.0',
            ),
          ],
          conversationId: 'conv-cite-mobile',
          turnIndex: 1,
        ),
      );
      await tester.pumpWidget(_screen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_mobile_chat_input')),
        'Show a citation.',
      );
      await tester.tap(find.byKey(const Key('advisor_mobile_chat_send_button')));
      await tester.pumpAndSettle();

      // Citation title hidden (collapsed by default).
      expect(find.text('Active target cycle'), findsNothing);

      // Tap the toggle.
      await tester.tap(find.text('Where this comes from'));
      await tester.pumpAndSettle();

      // Now visible.
      expect(find.text('Active target cycle'), findsOneWidget);
    });

    // ---- Multi-turn ---------------------------------------------------------

    testWidgets(
        'multi-turn: carries conversationId from first answer into second ask',
        (tester) async {
      await _sizeViewport(tester);
      const firstConvId = 'conv-mobile-multi-001';
      final gateway = _FakeAdvisorAnswerGateway(
        nextResult: const AdvisorAnswerResult(
          answer: 'First mobile answer.',
          citations: <AdvisorCitation>[],
          conversationId: firstConvId,
          turnIndex: 1,
        ),
      );
      await tester.pumpWidget(_screen(gateway));
      await tester.pumpAndSettle();

      // First turn.
      await tester.enterText(
        find.byKey(const Key('advisor_mobile_chat_input')),
        'First mobile question.',
      );
      await tester.tap(find.byKey(const Key('advisor_mobile_chat_send_button')));
      await tester.pumpAndSettle();

      expect(gateway.calls.length, 1);
      // First call has no conversationId (fresh conversation).
      expect(gateway.calls.first.conversationId, isNull);

      // Queue second answer.
      gateway.enqueueResult(const AdvisorAnswerResult(
        answer: 'Second mobile answer.',
        citations: <AdvisorCitation>[],
        conversationId: firstConvId,
        turnIndex: 3,
      ));

      // Second turn.
      await tester.enterText(
        find.byKey(const Key('advisor_mobile_chat_input')),
        'Second mobile question.',
      );
      await tester.tap(find.byKey(const Key('advisor_mobile_chat_send_button')));
      await tester.pumpAndSettle();

      expect(gateway.calls.length, 2);
      // conversationId from first result threaded into second ask.
      expect(gateway.calls[1].conversationId, firstConvId);

      expect(find.text('First mobile answer.'), findsOneWidget);
      expect(find.text('Second mobile answer.'), findsOneWidget);
    });

    // ---- Fail-closed states -------------------------------------------------

    testWidgets('notSwitchedOn: full-screen off-state, no composer', (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway(
        nextException: const AdvisorAnswerException(
          AdvisorAnswerStatus.notSwitchedOn,
        ),
      );
      await tester.pumpWidget(_screen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_mobile_chat_input')),
        'Anything.',
      );
      await tester.tap(find.byKey(const Key('advisor_mobile_chat_send_button')));
      await tester.pumpAndSettle();

      expect(find.textContaining("isn't switched on yet"), findsWidgets);
      // Composer is gone (full-screen state replaced the chat UI).
      expect(
        find.byKey(const Key('advisor_mobile_chat_composer')),
        findsNothing,
      );
    });

    testWidgets('usageCapReached: full-screen cap-state, no composer',
        (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway(
        nextException: const AdvisorAnswerException(
          AdvisorAnswerStatus.usageCapReached,
        ),
      );
      await tester.pumpWidget(_screen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_mobile_chat_input')),
        'Anything.',
      );
      await tester.tap(find.byKey(const Key('advisor_mobile_chat_send_button')));
      await tester.pumpAndSettle();

      expect(find.textContaining("this month's advisor questions"), findsWidgets);
      expect(
        find.byKey(const Key('advisor_mobile_chat_composer')),
        findsNothing,
      );
    });

    testWidgets('notConfigured: inline error, composer still present',
        (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway(
        nextException: const AdvisorAnswerException(
          AdvisorAnswerStatus.notConfigured,
        ),
      );
      await tester.pumpWidget(_screen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_mobile_chat_input')),
        'Anything.',
      );
      await tester.tap(find.byKey(const Key('advisor_mobile_chat_send_button')));
      await tester.pumpAndSettle();

      // Inline error: composer stays visible.
      expect(
        find.byKey(const Key('advisor_mobile_chat_composer')),
        findsOneWidget,
      );
      expect(
        find.textContaining('being set up and cannot answer just yet'),
        findsOneWidget,
      );
    });

    testWidgets('serverError: inline retry message, composer still present',
        (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway(
        nextException: const AdvisorAnswerException(
          AdvisorAnswerStatus.serverError,
        ),
      );
      await tester.pumpWidget(_screen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_mobile_chat_input')),
        'Anything.',
      );
      await tester.tap(find.byKey(const Key('advisor_mobile_chat_send_button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('advisor_mobile_chat_composer')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Something went wrong on our side'),
        findsOneWidget,
      );
    });

    testWidgets('networkError: inline retry message, composer still present',
        (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway(
        nextException: const AdvisorAnswerException(
          AdvisorAnswerStatus.networkError,
        ),
      );
      await tester.pumpWidget(_screen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_mobile_chat_input')),
        'Anything.',
      );
      await tester.tap(find.byKey(const Key('advisor_mobile_chat_send_button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('advisor_mobile_chat_composer')),
        findsOneWidget,
      );
      expect(
        find.textContaining("couldn't reach the advisor"),
        findsOneWidget,
      );
    });

    // ---- HP #6: no execute / apply / command button -------------------------

    testWidgets('HP #6: no execute, apply, or command button anywhere',
        (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway(
        nextResult: const AdvisorAnswerResult(
          answer: 'Here is what I would consider.',
          citations: <AdvisorCitation>[],
          conversationId: 'conv-hp6-mobile',
          turnIndex: 1,
        ),
      );
      await tester.pumpWidget(_screen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_mobile_chat_input')),
        'Test question.',
      );
      await tester.tap(find.byKey(const Key('advisor_mobile_chat_send_button')));
      await tester.pumpAndSettle();

      // No ElevatedButton, TextButton, or OutlinedButton labeled
      // Execute / Apply / Do it -- HP #6.
      expect(find.widgetWithText(ElevatedButton, 'Execute'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Apply'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Do it'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Execute'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Apply'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Execute'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Apply'), findsNothing);
    });

    // ---- HP #6: reassurance line always visible -----------------------------

    testWidgets('HP #6: reassurance line always visible', (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway();
      await tester.pumpWidget(_screen(gateway));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('advisor_mobile_chat_reassurance_line')),
        findsOneWidget,
      );
      final text = tester.widget<Text>(
        find.byKey(const Key('advisor_mobile_chat_reassurance_line')),
      );
      expect(text.data, contains('The advisor suggests'));
      expect(text.data, contains('You decide and act'));
      // No em dash (U+2014) in reassurance copy.
      expect(text.data, isNot(contains('\u2014')));
    });

    // ---- HP #2: same UI code path for demo and live -------------------------

    testWidgets('HP #2: demo and live-fake gateways follow the same UI path',
        (tester) async {
      await _sizeViewport(tester);

      // Demo gateway.
      final demoGateway = AdvisorAnswerGatewayDemo();
      await tester.pumpWidget(_screen(demoGateway));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Why was labor over target'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('advisor_mobile_chat_reassurance_line')),
        findsOneWidget,
      );

      // Live-flavored fake gateway (same UI path).
      final liveGateway = _FakeAdvisorAnswerGateway();
      await tester.pumpWidget(_screen(liveGateway));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Why was labor over target'),
        findsOneWidget,
      );
    });

    // ---- No em dash in any operator-facing string ---------------------------

    testWidgets('no em dash (U+2014) in any operator-facing rendered text',
        (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway(
        nextResult: const AdvisorAnswerResult(
          answer: 'An answer without em dashes.',
          citations: <AdvisorCitation>[
            AdvisorCitation(
              sourceId: 'target_cycle:demo',
              toolName: 'get_active_targets',
              title: 'Active target cycle',
              snippet: 'Snippet text',
            ),
          ],
          conversationId: 'conv-emdash-mobile',
          turnIndex: 1,
        ),
      );
      await tester.pumpWidget(_screen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_mobile_chat_input')),
        'Any question.',
      );
      await tester.tap(find.byKey(const Key('advisor_mobile_chat_send_button')));
      await tester.pumpAndSettle();

      final texts = tester.widgetList<Text>(find.byType(Text));
      for (final text in texts) {
        final data = text.data ?? '';
        expect(
          data,
          // U+2014 EM DASH -- using unicode escape to comply with
          // ASCII-only source rule (scanner bans literal multi-byte chars).
          isNot(contains('\u2014')),
          reason: 'Em dash found in operator-facing text: "$data"',
        );
      }
    });
  });
}
