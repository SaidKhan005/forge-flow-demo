// Advisor Chat screen — Slice D2 widget tests.
//
// Covers:
//   - Empty state renders example chips (tappable, prefill input).
//   - Submitting a question shows loading then answer + citations.
//   - Multi-turn: conversationId from first answer is carried into second ask.
//   - notSwitchedOn state renders its friendly fail-closed screen.
//   - notConfigured state renders its friendly fail-closed screen.
//   - usageCapReached renders cap state.
//   - serverError / networkError render inline retry-friendly messages.
//   - HP #6: no execute / apply / "do it" button exists anywhere.
//   - Reassurance line is always visible ("The advisor suggests. You decide and act.")
//   - No kDemoMode branch in the screen (HP #2): live vs demo differ only
//     in which [AdvisorAnswerGateway] implementation is passed in.
//
// UX no-em-dash law: the strings asserted below must contain no U+2014.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/advisor_chat_screen.dart';
import 'package:forge_and_flow/services/advisor/advisor_answer_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

// ── Fake gateway ──────────────────────────────────────────────────────────────

/// A simple in-memory gateway for widget tests. The caller controls
/// what the next `ask()` returns or throws.
class _FakeAdvisorAnswerGateway implements AdvisorAnswerGateway {
  _FakeAdvisorAnswerGateway({
    AdvisorAnswerResult? nextResult,
    AdvisorAnswerException? nextException,
    Duration delay = Duration.zero,
  }) : _nextResult = nextResult,
       _nextException = nextException,
       _delay = delay;

  AdvisorAnswerResult? _nextResult;
  AdvisorAnswerException? _nextException;
  final Duration _delay;

  /// Records every call so tests can assert multi-turn behavior.
  final List<({String question, String? conversationId})> calls =
      <({String question, String? conversationId})>[];

  void enqueueResult(AdvisorAnswerResult result) => _nextResult = result;
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
    if (_delay > Duration.zero) await Future<void>.delayed(_delay);
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
          'Based on your numbers, you could consider trimming the early prep '
          'block on slower mornings. The call is yours.',
      citations: <AdvisorCitation>[
        AdvisorCitation(
          sourceId: 'target_cycle:demo',
          toolName: 'get_active_targets',
          title: 'Active target cycle',
        ),
      ],
      conversationId: 'conv-test-001',
      turnIndex: 1,
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

OperatorWebSession get _demoSession => const OperatorWebSession(
  uid: 'test-owner',
  email: 'owner@test.forgeflow',
  displayName: 'Test Owner',
  operatorId: 'test-operator',
  businessName: 'Test Restaurant',
  primaryLocationId: 'test-location',
  primaryLocationName: 'Test Main Street',
  roles: <String>['operator_owner'],
);

Widget _wrap(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppTheme.themeData,
  home: Scaffold(body: child),
);

Future<void> _sizeViewport(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<Widget> _chatScreen(AdvisorAnswerGateway gateway) async {
  return _wrap(
    AdvisorChatScreen(
      session: _demoSession,
      gateway: gateway,
    ),
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('AdvisorChatScreen', () {
    // ── Empty state ────────────────────────────────────────────────────────────

    testWidgets('shows example chips in empty state', (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway();
      await tester.pumpWidget(await _chatScreen(gateway));
      await tester.pumpAndSettle();

      // Three example chips are visible.
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
      await tester.pumpWidget(await _chatScreen(gateway));
      await tester.pumpAndSettle();

      await tester.tap(
        find.textContaining('How does this week compare'),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      final input = tester.widget<TextField>(
        find.byKey(const Key('advisor_chat_input')),
      );
      expect(
        input.controller?.text,
        contains('How does this week compare'),
      );
    });

    // ── Loading state ──────────────────────────────────────────────────────────

    testWidgets('shows loading indicator while waiting', (tester) async {
      await _sizeViewport(tester);
      // Gateway that never resolves during this frame so we can assert the
      // in-flight state.
      final completer = Completer<AdvisorAnswerResult>();
      final gateway = _FakeAdvisorAnswerGateway();
      gateway.enqueueResult(const AdvisorAnswerResult(
        answer: 'test answer',
        citations: <AdvisorCitation>[],
        conversationId: 'conv-load-test',
        turnIndex: 1,
      ));
      // We override ask() to use the completer so the test controls when it resolves.
      final controlledGateway = _ControlledAdvisorGateway(completer);
      await tester.pumpWidget(await _chatScreen(controlledGateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_chat_input')),
        'Why is labor over budget?',
      );
      await tester.tap(find.byKey(const Key('advisor_chat_send_button')));
      await tester.pump(); // trigger the async submit

      // Loading indicator should appear.
      expect(find.byKey(const Key('advisor_chat_loading_indicator')), findsOneWidget);

      // Resolve the gateway.
      completer.complete(
        const AdvisorAnswerResult(
          answer: 'Here is what I see.',
          citations: <AdvisorCitation>[],
          conversationId: 'conv-load-test',
          turnIndex: 1,
        ),
      );
      await tester.pumpAndSettle();

      // Loading indicator gone; answer visible.
      expect(
        find.byKey(const Key('advisor_chat_loading_indicator')),
        findsNothing,
      );
      expect(find.text('Here is what I see.'), findsOneWidget);
    });

    // ── Answer + citations ────────────────────────────────────────────────────

    testWidgets('shows ADVISOR label, lead text, answer, and citations after ask',
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
          conversationId: 'conv-001',
          turnIndex: 1,
        ),
      );
      await tester.pumpWidget(await _chatScreen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_chat_input')),
        'How am I doing on labor?',
      );
      await tester.tap(find.byKey(const Key('advisor_chat_send_button')));
      await tester.pumpAndSettle();

      // ADVISOR label (uppercase)
      expect(find.byKey(const Key('advisor_chat_advisor_label')), findsOneWidget);
      // Serif lead
      expect(find.text('Here is what I would consider'), findsOneWidget);
      // Answer text
      expect(find.text('You could consider trimming the prep block.'), findsOneWidget);
      // "Where this comes from" toggle
      expect(find.text('Where this comes from'), findsOneWidget);
    });

    testWidgets('citations expand on tap', (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway(
        nextResult: const AdvisorAnswerResult(
          answer: 'An answer with citations.',
          citations: <AdvisorCitation>[
            AdvisorCitation(
              sourceId: 'target_cycle:demo',
              toolName: 'get_active_targets',
              title: 'Active target cycle',
              snippet: 'Target CPLH 8.0',
            ),
          ],
          conversationId: 'conv-cite',
          turnIndex: 1,
        ),
      );
      await tester.pumpWidget(await _chatScreen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_chat_input')),
        'Show me a citation.',
      );
      await tester.tap(find.byKey(const Key('advisor_chat_send_button')));
      await tester.pumpAndSettle();

      // Citation title not yet visible (collapsed).
      expect(find.text('Active target cycle'), findsNothing);

      // Tap the toggle.
      await tester.tap(find.text('Where this comes from'));
      await tester.pumpAndSettle();

      // Now visible.
      expect(find.text('Active target cycle'), findsOneWidget);
    });

    // ── Multi-turn ────────────────────────────────────────────────────────────

    testWidgets('multi-turn: carries conversationId from first answer into second ask',
        (tester) async {
      await _sizeViewport(tester);
      const firstConvId = 'conv-multi-001';
      final gateway = _FakeAdvisorAnswerGateway(
        nextResult: const AdvisorAnswerResult(
          answer: 'First answer.',
          citations: <AdvisorCitation>[],
          conversationId: firstConvId,
          turnIndex: 1,
        ),
      );
      await tester.pumpWidget(await _chatScreen(gateway));
      await tester.pumpAndSettle();

      // First turn.
      await tester.enterText(
        find.byKey(const Key('advisor_chat_input')),
        'First question.',
      );
      await tester.tap(find.byKey(const Key('advisor_chat_send_button')));
      await tester.pumpAndSettle();

      expect(gateway.calls.length, 1);
      expect(gateway.calls.first.conversationId, isNull);

      // Queue second answer.
      gateway.enqueueResult(const AdvisorAnswerResult(
        answer: 'Second answer.',
        citations: <AdvisorCitation>[],
        conversationId: firstConvId,
        turnIndex: 3,
      ));

      // Second turn.
      await tester.enterText(
        find.byKey(const Key('advisor_chat_input')),
        'Second question.',
      );
      await tester.tap(find.byKey(const Key('advisor_chat_send_button')));
      await tester.pumpAndSettle();

      expect(gateway.calls.length, 2);
      // The conversationId from the first result is threaded into the second ask.
      expect(gateway.calls[1].conversationId, firstConvId);

      expect(find.text('First answer.'), findsOneWidget);
      expect(find.text('Second answer.'), findsOneWidget);
    });

    // ── Fail-closed states ────────────────────────────────────────────────────

    testWidgets('notSwitchedOn shows friendly off-state message', (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway(
        nextException: const AdvisorAnswerException(
          AdvisorAnswerStatus.notSwitchedOn,
        ),
      );
      await tester.pumpWidget(await _chatScreen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_chat_input')),
        'Anything.',
      );
      await tester.tap(find.byKey(const Key('advisor_chat_send_button')));
      await tester.pumpAndSettle();

      expect(find.textContaining("isn't switched on yet"), findsWidgets);
      // Composer should no longer be present (screen replaced by off-state).
      expect(find.byKey(const Key('advisor_chat_composer')), findsNothing);
    });

    testWidgets('notConfigured shows friendly inline message (not full-screen replace)',
        (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway(
        nextException: const AdvisorAnswerException(
          AdvisorAnswerStatus.notConfigured,
        ),
      );
      await tester.pumpWidget(await _chatScreen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_chat_input')),
        'Anything.',
      );
      await tester.tap(find.byKey(const Key('advisor_chat_send_button')));
      await tester.pumpAndSettle();

      // notConfigured renders as an inline error turn; the composer stays.
      expect(find.byKey(const Key('advisor_chat_composer')), findsOneWidget);
      expect(
        find.textContaining('being set up and cannot answer just yet'),
        findsOneWidget,
      );
    });

    testWidgets('usageCapReached shows cap-state message', (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway(
        nextException: const AdvisorAnswerException(
          AdvisorAnswerStatus.usageCapReached,
        ),
      );
      await tester.pumpWidget(await _chatScreen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_chat_input')),
        'Anything.',
      );
      await tester.tap(find.byKey(const Key('advisor_chat_send_button')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining("this month's advisor questions"),
        findsWidgets,
      );
    });

    testWidgets('serverError shows inline retry-friendly message', (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway(
        nextException: const AdvisorAnswerException(
          AdvisorAnswerStatus.serverError,
        ),
      );
      await tester.pumpWidget(await _chatScreen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_chat_input')),
        'Anything.',
      );
      await tester.tap(find.byKey(const Key('advisor_chat_send_button')));
      await tester.pumpAndSettle();

      // serverError is an inline error, not a full-screen replacement.
      expect(find.byKey(const Key('advisor_chat_composer')), findsOneWidget);
      expect(find.textContaining('Something went wrong on our side'), findsOneWidget);
    });

    testWidgets('networkError shows inline retry-friendly message', (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway(
        nextException: const AdvisorAnswerException(
          AdvisorAnswerStatus.networkError,
        ),
      );
      await tester.pumpWidget(await _chatScreen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_chat_input')),
        'Anything.',
      );
      await tester.tap(find.byKey(const Key('advisor_chat_send_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('advisor_chat_composer')), findsOneWidget);
      expect(find.textContaining("couldn't reach the advisor"), findsOneWidget);
    });

    // ── HP #6: no execute / apply / command button ────────────────────────────

    testWidgets('HP #6: no execute or apply button exists anywhere', (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway(
        nextResult: const AdvisorAnswerResult(
          answer: 'Here is what I would consider.',
          citations: <AdvisorCitation>[],
          conversationId: 'conv-hp6',
          turnIndex: 1,
        ),
      );
      await tester.pumpWidget(await _chatScreen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_chat_input')),
        'Test question.',
      );
      await tester.tap(find.byKey(const Key('advisor_chat_send_button')));
      await tester.pumpAndSettle();

      // No button with text "Execute", "Apply", "Do it", or similar.
      expect(find.widgetWithText(ElevatedButton, 'Execute'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Apply'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Do it'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Execute'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Apply'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Execute'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Apply'), findsNothing);
    });

    // ── Reassurance line ──────────────────────────────────────────────────────

    testWidgets('reassurance line is always visible', (tester) async {
      await _sizeViewport(tester);
      final gateway = _FakeAdvisorAnswerGateway();
      await tester.pumpWidget(await _chatScreen(gateway));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('advisor_chat_reassurance_line')),
        findsOneWidget,
      );
      final text = tester.widget<Text>(
        find.byKey(const Key('advisor_chat_reassurance_line')),
      );
      expect(text.data, contains('The advisor suggests'));
      expect(text.data, contains('You decide and act'));
      // No em dash in reassurance copy.
      expect(text.data, isNot(contains('—')));
    });

    // ── No kDemoMode branch ───────────────────────────────────────────────────

    testWidgets(
        'HP #2: demo and live gateways both render the same UI path',
        (tester) async {
      await _sizeViewport(tester);

      // Demo gateway.
      final demoGateway = AdvisorAnswerGatewayDemo();
      await tester.pumpWidget(
        _wrap(
          AdvisorChatScreen(session: _demoSession, gateway: demoGateway),
        ),
      );
      await tester.pumpAndSettle();

      // Both render the empty-state chips — same code path.
      expect(find.textContaining('Why was labor over target'), findsOneWidget);
      expect(
        find.byKey(const Key('advisor_chat_reassurance_line')),
        findsOneWidget,
      );

      // Live-flavored fake gateway (same UI).
      final liveGateway = _FakeAdvisorAnswerGateway();
      await tester.pumpWidget(
        _wrap(
          AdvisorChatScreen(session: _demoSession, gateway: liveGateway),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Why was labor over target'), findsOneWidget);
    });

    // ── No em dash in any operator-facing literal ─────────────────────────────

    testWidgets('no em dash in operator-facing copy', (tester) async {
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
          conversationId: 'conv-emdash',
          turnIndex: 1,
        ),
      );
      await tester.pumpWidget(await _chatScreen(gateway));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('advisor_chat_input')),
        'Any question.',
      );
      await tester.tap(find.byKey(const Key('advisor_chat_send_button')));
      await tester.pumpAndSettle();

      // Collect all Text widget data rendered and assert no em dash.
      final texts = tester.widgetList<Text>(find.byType(Text));
      for (final text in texts) {
        final data = text.data ?? '';
        expect(
          data,
          isNot(contains('—')),
          reason: 'Em dash found in operator-facing text: "$data"',
        );
      }
    });
  });
}

// ── Controlled gateway (for async loading test) ───────────────────────────────

class _ControlledAdvisorGateway implements AdvisorAnswerGateway {
  _ControlledAdvisorGateway(this._completer);
  final Completer<AdvisorAnswerResult> _completer;

  @override
  Future<AdvisorAnswerResult> ask({
    required String question,
    String? conversationId,
  }) => _completer.future;
}
