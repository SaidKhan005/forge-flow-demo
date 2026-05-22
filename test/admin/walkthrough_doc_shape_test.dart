// Phase 8 spine-bridge Lane .C — acceptance item J.
//
// Walkthrough doc shape pinned against the 7.58.UX.5 template. Reads
// docs/archive/_walkthroughs/8.spine-bridge.C.md from disk and asserts the
// canonical sections + route IDs + audit-row obligation are documented.
//
// NB: the walkthrough doc may not exist when this test runs locally;
// in that case all asserts fail loudly (no skip). Codex should land
// the walkthrough as part of the slice. Filed as expected behaviour
// per the lane prompt.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/widgets/plain_english_explainer_card.dart';

void main() {
  group('8.spine-bridge.C — walkthrough doc matches 7.58.UX.5 shape', () {
    test('docs/archive/_walkthroughs/8.spine-bridge.C.md exists and carries the '
        'expected sections + route IDs', () {
      final file = File('docs/archive/_walkthroughs/8.spine-bridge.C.md');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'walkthrough file docs/archive/_walkthroughs/8.spine-bridge.C.md '
            'must exist',
      );

      final raw = file.readAsStringSync();

      // Top-level heading.
      expect(
        RegExp(r'^# 8\.spine-bridge\.C', multiLine: true).hasMatch(raw),
        isTrue,
        reason: 'walkthrough must start with `# 8.spine-bridge.C` heading',
      );

      // Authority files exercised section.
      expect(
        raw.contains('## Authority files exercised'),
        isTrue,
        reason: 'walkthrough must include `## Authority files exercised`',
      );

      // Click path section (or equivalent).
      final hasClickPath = raw.contains('## Click path') ||
          raw.contains('## Click-path') ||
          raw.contains('## Walkthrough') ||
          raw.contains('## Steps');
      expect(
        hasClickPath,
        isTrue,
        reason: 'walkthrough must include a click-path / walkthrough / '
            'steps section',
      );

      // Tab 1 + Tab 2 admin route IDs are mentioned.
      expect(
        raw.contains("'data-accuracy'") || raw.contains('data-accuracy'),
        isTrue,
        reason: 'walkthrough must mention the Tab 1 admin route id '
            "(`'data-accuracy'`)",
      );
      expect(
        raw.contains("'polling-pricing'") || raw.contains('polling-pricing'),
        isTrue,
        reason: 'walkthrough must mention the Tab 2 admin route id '
            "(`'polling-pricing'`)",
      );

      // Explainer paragraph 1 prefix (first 60 chars) is in the
      // walkthrough — confirms the audit/contract/explainer cross-link.
      final p1Prefix =
          PlainEnglishExplainerCard.kExplainerParagraph1.substring(0, 60);
      expect(
        raw.contains(p1Prefix) ||
            raw.contains(PlainEnglishExplainerCard.kExplainerParagraph1),
        isTrue,
        reason: 'walkthrough must contain the first 60 chars of '
            'PlainEnglishExplainerCard.kExplainerParagraph1 '
            '(or the full paragraph)',
      );

      // Audit-row obligation mention.
      final hasAuditMention =
          raw.contains('audit_logs') || raw.contains('audit row');
      expect(
        hasAuditMention,
        isTrue,
        reason: 'walkthrough must reference `audit_logs` or `audit row` to '
            'document the audit-row obligation',
      );
    });
  });
}
