// Phase 8 spine-bridge Lane .C — acceptance item C.
//
// Pins PlainEnglishExplainerCard.kExplainerParagraph1 + paragraph2
// against the verbatim text in
// docs/contracts/data_accuracy_settings_contract.md. Any future drift
// in either direction surfaces here before merge. Whitespace is
// collapsed (runs of whitespace -> single space) before comparison so
// markdown line wrapping vs Dart string concatenation is not flagged.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/screens/polling_and_pricing_admin_screen.dart';
import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/admin/widgets/plain_english_explainer_card.dart';
import 'package:forge_and_flow/domain/models/forge_flow_polling_tier_assignment.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

String _normalise(String raw) =>
    raw.replaceAll(RegExp(r'\s+'), ' ').trim();

({String paragraph1, String paragraph2}) _extractContractParagraphs(
  String contractMd,
) {
  final lines = contractMd.split('\n');
  // Find the heading line "Plain-English explainer card".
  var startIdx = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].contains('Plain-English explainer card')) {
      startIdx = i;
      break;
    }
  }
  if (startIdx < 0) {
    fail('Could not locate "Plain-English explainer card" heading in '
        'data_accuracy_settings_contract.md');
  }
  // Walk forward; collect blockquote lines into paragraph buckets.
  // Empty `>` line separates paragraphs. Stop at the first non-blockquote,
  // non-blank line (typically `**Card 1: ...`).
  final paragraphs = <List<String>>[<String>[]];
  for (var i = startIdx + 1; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimRight();
    if (trimmed.startsWith('>')) {
      // Strip the leading `>` and one optional space.
      var content = trimmed.substring(1);
      if (content.startsWith(' ')) content = content.substring(1);
      if (content.trim().isEmpty) {
        // Blockquote separator -> new paragraph.
        if (paragraphs.last.isNotEmpty) {
          paragraphs.add(<String>[]);
        }
      } else {
        paragraphs.last.add(content);
      }
    } else if (trimmed.trim().isEmpty) {
      // Blank line outside the blockquote -> if we already collected
      // content, we're past the blockquote.
      if (paragraphs.first.isNotEmpty) break;
    } else {
      // Non-blockquote, non-empty content -> end of explainer.
      if (paragraphs.first.isNotEmpty) break;
    }
  }
  // Drop any trailing empty paragraph bucket.
  while (paragraphs.isNotEmpty && paragraphs.last.isEmpty) {
    paragraphs.removeLast();
  }
  expect(
    paragraphs.length,
    greaterThanOrEqualTo(2),
    reason: 'expected at least two paragraphs in the explainer blockquote, '
        'got ${paragraphs.length}',
  );
  return (
    paragraph1: paragraphs[0].join(' '),
    paragraph2: paragraphs[1].join(' '),
  );
}

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  group('8.spine-bridge.C — Tab 2 explainer card text matches contract '
      'verbatim', () {
    test('PlainEnglishExplainerCard constants match the contract '
        'blockquote', () {
      final file = File('docs/contracts/data_accuracy_settings_contract.md');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'tests must run from repository root; expected '
            'docs/contracts/data_accuracy_settings_contract.md to exist',
      );
      final raw = file.readAsStringSync();
      final extracted = _extractContractParagraphs(raw);

      expect(
        _normalise(PlainEnglishExplainerCard.kExplainerParagraph1),
        equals(_normalise(extracted.paragraph1)),
        reason: 'paragraph 1 of the explainer card text must match the '
            'contract blockquote (whitespace-normalised)',
      );
      expect(
        _normalise(PlainEnglishExplainerCard.kExplainerParagraph2),
        equals(_normalise(extracted.paragraph2)),
        reason: 'paragraph 2 of the explainer card text must match the '
            'contract blockquote (whitespace-normalised)',
      );
    });

    testWidgets('card renders both paragraphs', (tester) async {
      await tester.pumpWidget(wrap(const PlainEnglishExplainerCard()));
      await tester.pumpAndSettle();
      expect(
        find.text(PlainEnglishExplainerCard.kExplainerParagraph1),
        findsOneWidget,
      );
      expect(
        find.text(PlainEnglishExplainerCard.kExplainerParagraph2),
        findsOneWidget,
      );
    });

    testWidgets(
        'PlainEnglishExplainerCard renders ABOVE TierDefinitionsCard on Tab 2 '
        '(contract: "always visible at top")', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = InMemoryDataAccuracyAdminGateway(
        operatorLocations: const <OperatorLocationRef>[
          OperatorLocationRef(
            operatorId: 'op-1',
            businessName: 'Demo Diner Co.',
            locationId: 'loc-1a',
            locationName: 'Toronto Yorkville',
          ),
        ],
        initialTierDefinitions: <PollingTierKey, TierDefinition>{
          PollingTierKey.standard: kDemoStandardTierDefinition(),
          PollingTierKey.premium: kDemoPremiumTierDefinition(),
          PollingTierKey.custom: kDemoCustomTierDefinition(),
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.themeData,
          home: Scaffold(
            body: PollingAndPricingAdminScreen(
              gateway: gateway,
              actorUserId: 'demo-super-admin',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final explainerY = tester
          .getTopLeft(
            find.byKey(const Key('admin_data_accuracy_explainer_card')),
          )
          .dy;
      final definitionsY = tester
          .getTopLeft(find.byKey(const Key('admin_tier_definitions_card')))
          .dy;
      expect(
        explainerY,
        lessThan(definitionsY),
        reason: 'PlainEnglishExplainerCard must render ABOVE '
            'TierDefinitionsCard so the contract requirement '
            '"always visible at top" is structurally enforced.',
      );
    });
  });
}
