// integration_test/admin_pressure/ai_corpus/scenario_ai_cor_01_version_list_renders.dart
//
// Lane C — AI/Cor-01: the Knowledge base (corpus) route mounts with two
// tabs ("Knowledge" + "Connections") and the Knowledge tab surfaces
// the version-list / current-bundle body. The corpus screen tags itself
// with Key('admin_corpus_screen')
// (lib/admin/screens/corpus_admin_screen.dart:303); the tab bar is
// Key('admin_corpus_tab_bar') (:328) with Knowledge tab key
// 'admin_corpus_versions_tab' (:335) and Connections tab key
// 'admin_corpus_graph_candidates_tab' (:339).
//
// In share-preview the gateway returns a seeded bundle so the Knowledge
// tab body renders either the grouped chunk view (Key
// 'admin_corpus_grouped_view_current', :488) or — if seed is empty —
// the empty state (Key 'admin_corpus_empty', :469). We accept either
// state plus the loading / load-error states; the contract is "screen
// mounts and the Knowledge tab body produces a recognised state", not
// "fixture has at least N chunks".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';

import '../_harness.dart';

void main() {
  bootstrapBinding();

  testWidgets(
    'AI/Cor-01: Knowledge base route mounts; Knowledge tab body settles '
    'into a recognised state (chunks, empty, or load error)',
    (tester) async {
      final tap = FlutterErrorTap.install();
      addTearDown(tap.restore);

      await launchAdminSharePreview(tester);
      await expectAdminShellMounted(tester);
      await tapAdminNav(tester, kAdminCorpusRouteId);

      // Corpus screen mounted.
      expect(
        find.byKey(const Key('admin_corpus_screen')),
        findsOneWidget,
        reason: 'Corpus (Knowledge base) screen did not mount.',
      );

      // Tab bar present with both tabs.
      expect(
        find.byKey(const Key('admin_corpus_tab_bar')),
        findsOneWidget,
        reason: 'Corpus tab bar missing.',
      );
      expect(
        find.byKey(const Key('admin_corpus_versions_tab')),
        findsOneWidget,
        reason: 'Knowledge tab (versions tab) missing from corpus tab bar.',
      );
      expect(
        find.byKey(const Key('admin_corpus_graph_candidates_tab')),
        findsOneWidget,
        reason:
            'Connections tab (graph candidates tab) missing from corpus '
            'tab bar.',
      );

      // The Knowledge tab body should settle into one of these states.
      const knowledgeStates = <Key>[
        Key('admin_corpus_loading'),
        Key('admin_corpus_load_error'),
        Key('admin_corpus_empty'),
        Key('admin_corpus_grouped_view_current'),
      ];
      var matched = false;
      for (final key in knowledgeStates) {
        if (find.byKey(key).evaluate().isNotEmpty) {
          matched = true;
          break;
        }
      }
      expect(
        matched,
        isTrue,
        reason:
            'Knowledge tab body did not settle into any recognised state '
            '(loading / load error / empty / grouped view). The screen '
            'mounted but the body is in an unknown state.',
      );

      // No overflows.
      expect(
        tap.overflowErrors,
        isEmpty,
        reason:
            'Corpus screen overflowed: '
            '${tap.overflowErrors.map((e) => e.exception).join(', ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
