// Phase 8 W2.B - Operator Web Notifications screen.
//
// Mounted at `kOperatorWebNavNotifications` in the operator-web shell.
// Renders the catalog of notification events
// (`lib/domain/models/notification_event_catalog.dart`) grouped by
// category. For every event the operator's role admits, every channel
// (push / email / inbox) renders as a toggle. Toggles flip optimistically
// and fire a PUT through the gateway with a fresh `Idempotency-Key`;
// failures roll the toggle back and surface a plain-English snackbar.
//
// Permission gate: per-row gate using
// `roleSatisfiesGate(...)` so the audit row is hidden for non-admin
// actors and the shift / star / plan rows are hidden for non-manager
// actors. UI defense + RLS backup: even if a hidden row leaked, the
// per-tenant + per-user RLS policy on `notification_preferences`
// keeps the write to the actor's own row.
//
// UX writing standard (`memory/project_ux_writing_standard.md`):
// every label, button, status, snackbar trains the operator. Plain
// English. No engineering jargon.
//
// Slice C-8 (catalog completeness): the screen renders every entry
// from `kNotificationCatalog` (no filtering by wiring readiness),
// stamping each with one of three plain-English state badges:
//
//   * "Available"    - emit + delivery wired; toggle controls fanout.
//   * "Coming soon"  - catalog entry exists but the emitter is not
//                      yet shipped (per audit matrix
//                      `docs/archive/_execution/lane_c_parity/02_plumbing_audit_matrix.md`
//                      section E4 and the FOLLOW-UP block at
//                      `tool/advisor_proxy/email_dispatch/notification_event_fanout.dart:737-757`).
//                      Toggles are disabled; the info button explains why.
//   * "Backend-only" - emit is wired and Forge & Flow sends regardless
//                      of operator preference (system-mandated; e.g.
//                      audit-chain integrity alerts). Toggles are disabled.
//
// Hierarchy carve-out (CLAUDE.md HP #11): notification preferences are
// per-(operator, user, event, channel), not hierarchy-scoped. This is
// the same carve-out the My Account screen relies on. It is a personal
// preference surface, not an org-config surface. Documented inline so
// future audit passes do not flag it as missing inheritance.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../domain/models/notification_event_catalog.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/operator_web_notification_preferences_gateway_provider.dart';
import 'package:forge_and_flow/widgets/console/console_info_button.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';
import '../../theme/app_theme.dart';

/// Wiring-readiness state for one catalog entry, as surfaced on the
/// operator-web Notifications screen. Plain-English labels live in
/// [_kStateLabel].
///
/// State assignment lives in [_kEventState] below (not in the catalog
/// itself - the catalog is the durable contract for the fanout worker
/// and stays free of UI-side wiring flags per slice C-8). When a
/// future hook ships, flip the matching map entry from `comingSoon` to
/// `available` in one place.
enum _NotifEventState {
  /// Emit + delivery fully wired. Toggle controls fanout.
  available,

  /// Catalog entry exists; emitter not yet shipped. Toggle disabled;
  /// row reads honestly so the operator knows the surface is coming.
  comingSoon,

  /// Emit is wired and Forge & Flow sends regardless of operator
  /// preference (system-mandated). Toggles are disabled and the info
  /// button explains why.
  backendOnly,
}

/// Per-event readiness map. Source of truth:
///   * Audit matrix E4 + O3 in
///     `docs/archive/_execution/lane_c_parity/02_plumbing_audit_matrix.md`.
///   * FOLLOW-UP comments at
///     `tool/advisor_proxy/email_dispatch/notification_event_fanout.dart:737-757`.
///   * Catalog comment on `notif.audit.anchor_failure` ("rare and
///     never blocks operations, but you should know") classifies it
///     as a system-mandated notification under the backend-only state.
///
/// When a hook ships and the audit matrix flips, update this map and
/// the existing tests will catch any drift.
const Map<String, _NotifEventState> _kEventState = <String, _NotifEventState>{
  'notif.backfill.complete': _NotifEventState.available,
  'notif.backfill.failed': _NotifEventState.available,
  'notif.vendor.now_available': _NotifEventState.available,
  'notif.audit.anchor_failure': _NotifEventState.backendOnly,
  'notif.shift.stale': _NotifEventState.comingSoon,
  'notif.star.override': _NotifEventState.comingSoon,
  'notif.plan.updated': _NotifEventState.comingSoon,
  // C-2-C wire: MFA factor removal email + inbox emit. The fanout
  // worker does not drive this event (single-recipient); the MFA
  // removal worker dispatches a direct email + audit row. Marked
  // `backendOnly` (label: "Always on") because the email goes to
  // the affected user regardless of preference toggles. A security
  // notification should not be opt-out-able from the operator-web
  // preferences screen.
  'notif.mfa.factor_changed': _NotifEventState.backendOnly,
};

/// Resolves the readiness state for a catalog entry. Defaults to
/// `available` when the event is missing from `_kEventState` so a
/// newly added catalog entry renders as a working toggle while a
/// follow-up annotates the matrix.
_NotifEventState _stateFor(NotificationCatalogEntry entry) =>
    _kEventState[entry.eventKey] ?? _NotifEventState.available;

/// Plain-English badge labels per state. UX writing standard: no
/// jargon, train the operator inline.
const Map<_NotifEventState, String> _kStateLabel = <_NotifEventState, String>{
  _NotifEventState.available: 'Available',
  _NotifEventState.comingSoon: 'Coming soon',
  _NotifEventState.backendOnly: 'Always on',
};

const Map<_NotifEventState, String> _kStateDetails = <_NotifEventState, String>{
  _NotifEventState.available:
      'These alerts are wired now. Your switches decide how Forge & Flow '
      'contacts you.',
  _NotifEventState.comingSoon:
      'The alert is in the catalog, but the sending hook is not live yet. '
      'We show it here so you can see what is planned without pretending '
      'the switch can save a real preference today.',
  _NotifEventState.backendOnly:
      'Forge & Flow sends this required alert even when personal '
      'preferences are off. Security and integrity alerts protect your '
      'account and business records.',
};

String _infoBodyFor(NotificationCatalogEntry event, _NotifEventState state) {
  final status = _kStateDetails[state] ?? '';
  if (status.isEmpty) return event.description;
  return '${event.description}\n\n$status';
}

/// Operator Web Notifications screen. Pure render +
/// optimistic-toggle widget; all I/O flows through [gateway].
class SettingsNotificationsScreen extends StatefulWidget {
  const SettingsNotificationsScreen({
    super.key,
    required this.session,
    this.gateway,
    this.idempotencyKeyFactory,
  });

  final OperatorWebSession session;

  /// Live gateway. When null the screen renders honest read-only
  /// state with snackbar copy explaining the disconnect.
  final WebNotificationPreferencesGateway? gateway;

  /// Test-injectable idempotency-key generator. Production wires in
  /// a UUID-v4 generator; tests inject a deterministic counter.
  final String Function()? idempotencyKeyFactory;

  @override
  State<SettingsNotificationsScreen> createState() =>
      _SettingsNotificationsScreenState();
}

class _SettingsNotificationsScreenState
    extends State<SettingsNotificationsScreen> {
  /// In-memory map of `(eventKey, channel)` -> enabled preference. The
  /// scope is always `operator` for V1; per-location overrides are a
  /// follow-up. Absence means "no row stored" -> use the catalog
  /// default.
  final Map<_PrefKey, bool> _explicit = <_PrefKey, bool>{};

  /// True while the initial gateway list call is in flight.
  bool _loading = true;
  String? _loadError;

  /// Test/production idempotency-key generator. Falls back to a
  /// monotonically incrementing counter prefixed with timestamp when
  /// the host did not inject one.
  late int _idemCounter;

  @override
  void initState() {
    super.initState();
    _idemCounter = 0;
    unawaited(_loadInitial());
  }

  Future<void> _loadInitial() async {
    final gateway = widget.gateway;
    if (gateway == null) {
      // No gateway wired (demo-without-mixin path). Render with
      // catalog defaults and disable toggles below.
      setState(() => _loading = false);
      return;
    }
    try {
      final rows = await gateway.listPreferences();
      if (!mounted) return;
      setState(() {
        _explicit
          ..clear()
          ..addEntries(<MapEntry<_PrefKey, bool>>[
            for (final p in rows)
              MapEntry(
                _PrefKey(eventKey: p.eventKey, channel: p.channel),
                p.enabled,
              ),
          ]);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError =
            "We couldn't load your notification settings. "
            "Pull to refresh, or try again in a minute.";
      });
    }
  }

  String _newIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idemCounter += 1;
    final ts = DateTime.now().microsecondsSinceEpoch;
    final r = Random().nextInt(0xffffff);
    return 'web-notif-$ts-$_idemCounter-$r';
  }

  bool _resolveEnabled(NotificationCatalogEntry event, String channel) {
    final explicit =
        _explicit[_PrefKey(eventKey: event.eventKey, channel: channel)];
    if (explicit != null) return explicit;
    return event.defaultChannels.contains(channel);
  }

  Future<void> _toggle({
    required NotificationCatalogEntry event,
    required String channel,
    required bool currentlyEnabled,
  }) async {
    final gateway = widget.gateway;
    if (gateway == null) return;
    // Coming-soon and backend-only rows render disabled switches; this
    // guard is a defense-in-depth so a stray tap never persists a
    // preference row that the fanout will ignore (coming soon) or
    // override (backend-only).
    if (_stateFor(event) != _NotifEventState.available) return;
    final next = !currentlyEnabled;
    final key = _PrefKey(eventKey: event.eventKey, channel: channel);
    setState(() => _explicit[key] = next);
    try {
      await gateway.upsertPreference(
        eventKey: event.eventKey,
        channel: channel,
        scopeKind: 'operator',
        scopeId: null,
        enabled: next,
        idempotencyKey: _newIdempotencyKey(),
      );
      if (!mounted) return;
      // No banner on success. The toggle reflects the new state and the
      // operator already sees it. Plain-English banner only on error.
    } catch (_) {
      if (!mounted) return;
      // Roll back the optimistic flip.
      setState(() => _explicit[key] = currentlyEnabled);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          key: Key('settings_notifications_error_snackbar'),
          content: Text("Couldn't save. Try again."),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        key: Key('settings_notifications_loading'),
        child: CircularProgressIndicator(),
      );
    }
    final visibleEvents =
        <NotificationCategory, List<NotificationCatalogEntry>>{};
    for (final entry in kNotificationCatalog) {
      if (!roleSatisfiesGate(entry.roleGate, widget.session.roles)) continue;
      visibleEvents.putIfAbsent(
        entry.category,
        () => <NotificationCatalogEntry>[],
      );
      visibleEvents[entry.category]!.add(entry);
    }
    return OperatorWebScreenBody(
      scrollKey: const Key('settings_notifications_screen'),
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Header(),
          if (_loadError != null) ...[
            const SizedBox(height: 12),
            OperatorWebBanner(
              key: const Key('settings_notifications_error_banner'),
              tone: OperatorWebBannerTone.error,
              message: _loadError!,
            ),
          ],
          const SizedBox(height: 16),
          for (final category in NotificationCategory.values)
            if (visibleEvents.containsKey(category)) ...[
              _CategorySection(
                category: category,
                events: visibleEvents[category]!,
                resolveEnabled: _resolveEnabled,
                onToggle: widget.gateway == null ? null : _toggle,
              ),
              const SizedBox(height: 14),
            ],
        ],
      ),
    );
  }
}

class _PrefKey {
  const _PrefKey({required this.eventKey, required this.channel});

  final String eventKey;
  final String channel;

  @override
  bool operator ==(Object other) =>
      other is _PrefKey &&
      other.eventKey == eventKey &&
      other.channel == channel;

  @override
  int get hashCode => Object.hash(eventKey, channel);
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return OperatorWebScreenHeader(
      icon: Icons.notifications_outlined,
      title: 'Notifications',
      collapseBelowWidth: 0,
      actions: <Widget>[
        OperatorWebInfoButton(
          key: const Key('settings_notifications_header_info'),
          title: 'Notifications',
          tooltip: 'About notifications',
          width: 360,
          body: Text(
            'Pick how Forge & Flow contacts your signed-in account. These '
            'choices do not change settings for the whole business or for a '
            'location.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

class _CategorySection extends StatelessWidget {
  const _CategorySection({
    required this.category,
    required this.events,
    required this.resolveEnabled,
    required this.onToggle,
  });

  final NotificationCategory category;
  final List<NotificationCatalogEntry> events;
  final bool Function(NotificationCatalogEntry, String) resolveEnabled;

  /// Null when no gateway is wired (demo-without-mixin) - toggles
  /// render disabled.
  final Future<void> Function({
    required NotificationCatalogEntry event,
    required String channel,
    required bool currentlyEnabled,
  })?
  onToggle;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      key: Key('settings_notifications_category_${category.name}'),
      title: kNotificationCategoryLabels[category] ?? category.name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < events.length; i++) ...[
            _EventRow(
              event: events[i],
              resolveEnabled: resolveEnabled,
              onToggle: onToggle,
            ),
            if (i != events.length - 1)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Divider(height: 1, color: AppColors.borderSubtle),
              ),
          ],
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.event,
    required this.resolveEnabled,
    required this.onToggle,
  });

  final NotificationCatalogEntry event;
  final bool Function(NotificationCatalogEntry, String) resolveEnabled;
  final Future<void> Function({
    required NotificationCatalogEntry event,
    required String channel,
    required bool currentlyEnabled,
  })?
  onToggle;

  @override
  Widget build(BuildContext context) {
    final state = _stateFor(event);
    final isAvailable = state == _NotifEventState.available;
    return Row(
      key: Key('settings_notifications_event_${event.eventKey}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      event.title,
                      style: AppTextStyles.mono14(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StateBadge(eventKey: event.eventKey, state: state),
                  const SizedBox(width: 4),
                  OperatorWebInfoButton(
                    key: Key(
                      'settings_notifications_state_info_${event.eventKey}',
                    ),
                    title: _kStateLabel[state] ?? 'Notification status',
                    tooltip: 'Notification status',
                    body: Text(
                      _infoBodyFor(event, state),
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        for (final channel in kNotificationChannelOrder)
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: _ChannelToggle(
              event: event,
              channel: channel,
              enabled: resolveEnabled(event, channel),
              onToggle: isAvailable ? onToggle : null,
            ),
          ),
      ],
    );
  }
}

/// Plain-English state badge for one catalog row. Three variants:
/// "Available" (success-tinted), "Coming soon" (warning-tinted),
/// "Always on" (subtle/muted).
class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.eventKey, required this.state});

  final String eventKey;
  final _NotifEventState state;

  @override
  Widget build(BuildContext context) {
    final label = _kStateLabel[state] ?? '';
    final (Color bg, Color fg) = switch (state) {
      _NotifEventState.available => (
        AppColors.sunsetDark.withValues(alpha: 0.10),
        AppColors.sunsetDark,
      ),
      _NotifEventState.comingSoon => (
        AppColors.warningBadgeBg,
        AppColors.warning,
      ),
      _NotifEventState.backendOnly => (
        AppColors.borderSubtle.withValues(alpha: 0.55),
        AppColors.textSecondary,
      ),
    };
    return Container(
      key: Key('settings_notifications_state_badge_$eventKey'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono10(
          color: fg,
        ).copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _ChannelToggle extends StatelessWidget {
  const _ChannelToggle({
    required this.event,
    required this.channel,
    required this.enabled,
    required this.onToggle,
  });

  final NotificationCatalogEntry event;
  final String channel;
  final bool enabled;
  final Future<void> Function({
    required NotificationCatalogEntry event,
    required String channel,
    required bool currentlyEnabled,
  })?
  onToggle;

  @override
  Widget build(BuildContext context) {
    final label = kNotificationChannelLabels[channel] ?? channel;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: AppTextStyles.mono10(color: AppColors.textMuted)),
        const SizedBox(height: 4),
        Switch(
          key: Key('settings_notifications_toggle_${event.eventKey}_$channel'),
          value: enabled,
          onChanged: onToggle == null
              ? null
              : (_) => onToggle!(
                  event: event,
                  channel: channel,
                  currentlyEnabled: enabled,
                ),
          activeThumbColor: AppColors.sunsetDark,
        ),
      ],
    );
  }
}
