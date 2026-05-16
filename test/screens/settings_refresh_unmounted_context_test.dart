// Regression: Settings data-action `_refreshAfterWrite` crashed with
// "This widget has been unmounted, so the State no longer has a
// context (… defunct)" when a data-action closure
// (SettingsMockReplaySection / SettingsDataManagementSection) awaited a
// long write (reseed / date-advance / clear), the Settings screen
// unmounted during that await, and the closure then called back into
// the State.
//
// Root cause: `_SettingsScreenState._refreshAfterWrite` guarded with
// `if (!context.mounted) return;`. Reading `State.context` on a defunct
// State *throws* before `.mounted` is ever evaluated, so the guard
// itself was the crashing line (settings_screen.dart:165). The fix
// uses the non-throwing `State.mounted` getter, and the awaiting
// closures in settings_data_sections.dart short-circuit on
// `BuildContext.mounted` (the safe Element.mounted) after their write
// so the post-write path becomes a clean no-op.
//
// ShiftService is a non-injectable singleton owned by a sibling worker
// (W6); its real `reseedDemo` also hits a separate, out-of-scope seed
// PK-collision defect. The real closure therefore can't be driven
// deterministically here. These tests instead reproduce the exact
// two-layer lifecycle shape of the fixed files — a StatelessWidget
// section closure (mirrors SettingsMockReplaySection) that awaits a
// long write then calls back into a parent State method (mirrors
// `_refreshAfterWrite`) — and lock the guard contract the fix depends
// on:
//   1. `State.mounted` is the non-throwing guard inside the State
//      method — an async callback whose State unmounted mid-await
//      becomes a clean no-op (was: `State.context` threw "defunct");
//   2. `BuildContext.mounted` in the section closure short-circuits
//      safely after the await so the post-write path is a no-op;
//   3. when the State stays mounted the post-await refresh still runs
//      (no behaviour regression).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors `_SettingsScreenState`: holds the async method modelled on
/// the fixed `_refreshAfterWrite` (guard with the non-throwing
/// `State.mounted`, then touch `context`).
class _Host extends StatefulWidget {
  const _Host({super.key, required this.gate, required this.onRefreshRan});

  /// Stand-in for `await ShiftService.instance.reseedDemo()`.
  final Future<void> gate;

  /// Fires only if the post-guard refresh body actually executed.
  final VoidCallback onRefreshRan;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  Future<void> refreshAfterWrite() async {
    // The fix: State.mounted, not context.mounted. Reading
    // `State.context` on a defunct State throws "defunct".
    if (!mounted) return;
    context.findRenderObject(); // would throw if reached unmounted
    widget.onRefreshRan();
  }

  @override
  Widget build(BuildContext context) {
    // The data-action closure lives in a StatelessWidget section, just
    // like SettingsMockReplaySection — its `context` is the section's
    // Element, whose `.mounted` is the safe non-throwing getter.
    return _Section(gate: widget.gate, onAfterWrite: refreshAfterWrite);
  }
}

/// Mirrors `SettingsMockReplaySection`: a StatelessWidget whose action
/// closure awaits a long write then calls back into the parent State.
class _Section extends StatelessWidget {
  const _Section({required this.gate, required this.onAfterWrite});

  final Future<void> gate;
  final Future<void> Function() onAfterWrite;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: TextButton(
          onPressed: () async {
            await gate; // the long write the closure awaits
            // The guard added in settings_data_sections.dart.
            if (!context.mounted) return;
            await onAfterWrite();
          },
          child: const Text('run'),
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    'data-action callback is a clean no-op when Settings unmounts '
    'mid-write (no "defunct" exception)',
    (tester) async {
      final gate = Completer<void>();
      var refreshRan = false;

      await tester.pumpWidget(
        _Host(gate: gate.future, onRefreshRan: () => refreshRan = true),
      );

      // Start the data-action closure; it parks on the awaited write.
      await tester.tap(find.text('run'));
      await tester.pump();

      // Settings screen unmounts/rebuilds while the write is in flight
      // (the captured real-world sequence).
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

      // The long write finally completes and the closure resumes.
      gate.complete();
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'unmounted-State access must be a no-op, not a throw',
      );
      expect(
        refreshRan,
        isFalse,
        reason: 'post-write refresh must not run after unmount',
      );
    },
  );

  testWidgets(
    'when Settings stays mounted the post-write refresh still runs '
    '(no behaviour regression)',
    (tester) async {
      final gate = Completer<void>();
      var refreshRan = false;

      await tester.pumpWidget(
        _Host(gate: gate.future, onRefreshRan: () => refreshRan = true),
      );

      await tester.tap(find.text('run'));
      await tester.pump();

      gate.complete();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        refreshRan,
        isTrue,
        reason: 'mounted path must still execute the refresh',
      );
    },
  );

  testWidgets(
    'root cause: reading State.context on a defunct State throws '
    '"defunct" while State.mounted is the safe guard',
    (tester) async {
      final key = GlobalKey<_HostState>();
      await tester.pumpWidget(
        _Host(
          key: key,
          gate: Future<void>.value(),
          onRefreshRan: () {},
        ),
      );

      final state = key.currentState!;
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

      // `State.mounted` is false and does NOT throw — the chosen guard.
      expect(state.mounted, isFalse);

      // Reading `State.context` (what `context.mounted` does first)
      // throws the exact "defunct" error from the crash report.
      expect(
        () => state.context,
        throwsA(
          isA<FlutterError>().having(
            (e) => e.message,
            'message',
            contains('defunct'),
          ),
        ),
      );
    },
  );
}
