// Phase 10a.UX.0 — Sync-state badge.
//
// Renders the bridge connection state surfaced by
// `RealtimeSubscription.connectionState` (10a.0) as a small pill in the
// operator app bar. The badge is purely a consumer; the subscription
// lifecycle stays owned by 10a.0.
//
// State → pill mapping:
//   * connected     → green "Live"
//   * connecting    → amber "Connecting…"
//   * reconnecting  → amber "Reconnecting…"
//   * idle / no scope → hidden (SizedBox.shrink)
//
// The visible pill has a stable min-width so transitions between
// "Live" and "Reconnecting…" don't shift the surrounding actions.

import 'package:flutter/material.dart';

import '../services/realtime/realtime_subscription.dart';
import '../theme/app_theme.dart';

/// Inherited scope that exposes the bridge connection-state stream to
/// descendant widgets (today: [SyncStateBadge]). Production wiring
/// passes through `RealtimeSubscription.connectionState`; demo-mode
/// walkthroughs and widget tests can drive a controller directly so
/// state transitions are scriptable without a live socket.
///
/// When no scope is mounted (or the stream is `null`), the badge
/// renders hidden — the production-side wiring of the live
/// subscription into [AppShell] is the gating hook.
class RealtimeConnectionScope extends InheritedWidget {
  const RealtimeConnectionScope({
    super.key,
    required this.connectionStateStream,
    this.initialState = RealtimeConnectionState.idle,
    required super.child,
  });

  final Stream<RealtimeConnectionState>? connectionStateStream;
  final RealtimeConnectionState initialState;

  static Stream<RealtimeConnectionState>? streamOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<RealtimeConnectionScope>();
    return scope?.connectionStateStream;
  }

  static RealtimeConnectionState initialStateOf(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<RealtimeConnectionScope>();
    return scope?.initialState ?? RealtimeConnectionState.idle;
  }

  @override
  bool updateShouldNotify(RealtimeConnectionScope oldWidget) =>
      connectionStateStream != oldWidget.connectionStateStream ||
      initialState != oldWidget.initialState;
}

/// Pill that surfaces the realtime bridge connection state in the
/// operator app bar. Reads from the ambient
/// [RealtimeConnectionScope]; renders hidden when no scope or stream
/// is wired so the badge is invisible during the lead-in before the
/// subscription is mounted.
class SyncStateBadge extends StatelessWidget {
  const SyncStateBadge({super.key});

  /// Stable key on the visible pill container so widget tests can
  /// measure the pill's footprint without depending on Tooltip /
  /// Container hierarchy details.
  static const ValueKey<String> pillKey = ValueKey<String>(
    'sync_state_badge_pill',
  );

  @override
  Widget build(BuildContext context) {
    final stream = RealtimeConnectionScope.streamOf(context);
    final initial = RealtimeConnectionScope.initialStateOf(context);
    if (stream == null) {
      return const SizedBox.shrink();
    }
    return StreamBuilder<RealtimeConnectionState>(
      stream: stream,
      initialData: initial,
      builder: (context, snapshot) {
        final state = snapshot.data ?? initial;
        return _SyncStatePill(state: state);
      },
    );
  }
}

class _SyncStatePill extends StatelessWidget {
  const _SyncStatePill({required this.state});

  final RealtimeConnectionState state;

  /// Fixed width for the visible pill — chosen to accommodate the
  /// longest label ("Reconnecting…") without clipping while keeping
  /// the shorter labels ("Live", "Connecting…") centered. A fixed
  /// width avoids layout jitter on state change.
  static const double _pillWidth = 132;

  @override
  Widget build(BuildContext context) {
    final visual = _visualFor(state);
    if (visual == null) {
      return const SizedBox.shrink();
    }
    return Tooltip(
      message: visual.tooltip,
      child: SizedBox(
        key: SyncStateBadge.pillKey,
        width: _pillWidth,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: visual.background,
            border: Border.all(color: visual.border, width: 1),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: visual.dot,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  visual.label,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: TextStyle(
                    color: visual.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _PillVisual? _visualFor(RealtimeConnectionState state) =>
      syncStateBadgeVisualFor(state);
}

/// Visible-for-tests visual contract used by [SyncStateBadge].
///
/// Pins the colors / labels per state so a future regression that
/// (for example) re-skinned the connected pill to amber would fail
/// the widget tests instead of slipping through. Test code reaches
/// in via [syncStateBadgeVisualFor]; runtime code uses the private
/// `_visualFor` indirection.
@visibleForTesting
SyncStateBadgeVisual? syncStateBadgeVisualFor(RealtimeConnectionState state) {
  switch (state) {
    case RealtimeConnectionState.connected:
      return const SyncStateBadgeVisual(
        label: 'Live',
        tooltip: 'Realtime updates connected',
        dot: AppColors.positive,
        text: AppColors.positive,
        background: Color(0x26256B29), // positive @ 15%
        border: Color(0x66256B29), // positive @ 40%
      );
    case RealtimeConnectionState.connecting:
      return const SyncStateBadgeVisual(
        label: 'Connecting…',
        tooltip: 'Connecting to realtime channel',
        dot: AppColors.warning,
        text: AppColors.warning,
        background: AppColors.warningBadgeBg,
        border: Color(0x66997000), // warning @ 40%
      );
    case RealtimeConnectionState.reconnecting:
      return const SyncStateBadgeVisual(
        label: 'Reconnecting…',
        tooltip: 'Realtime channel dropped — reconnecting',
        dot: AppColors.warning,
        text: AppColors.warning,
        background: AppColors.warningBadgeBg,
        border: Color(0x66997000), // warning @ 40%
      );
    case RealtimeConnectionState.idle:
      return null;
  }
}

/// Visual descriptor for a sync-state pill. The colors and labels
/// are part of the slice's visible contract — tests assert them
/// directly so a regression on the green/amber mapping is caught
/// before it ships.
class SyncStateBadgeVisual {
  const SyncStateBadgeVisual({
    required this.label,
    required this.tooltip,
    required this.dot,
    required this.text,
    required this.background,
    required this.border,
  });

  final String label;
  final String tooltip;
  final Color dot;
  final Color text;
  final Color background;
  final Color border;
}

/// Internal alias used inside the widget so the build path keeps a
/// short type name; tests use the public [SyncStateBadgeVisual].
typedef _PillVisual = SyncStateBadgeVisual;
