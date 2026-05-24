// X-G71 (cross-surface parity register, audit
// `docs/_audits/cross_surface_parity_v1/cross_surface_parity_audit_2026_05_16.md`
// section 0b, X-G71 row) - admin notification-preferences screen.
//
// The customer operator-web console has a full notification-preferences
// editor (`lib/operator_web/screens/settings_notifications_screen.dart`).
// The mobile app is a read-only inbox. The F&F-internal admin console
// had NO notification-preferences surface at all - a missing-surface
// parity gap. This screen closes that gap by mirroring the operator-web
// editor's UX (same preference fields, same save semantics, same
// plain-English copy tone) and wiring it to the SAME existing backend
// route through a new admin client gateway
// (`lib/admin/services/admin_notification_preferences_gateway.dart`).
//
// Backend route reuse: the gateway calls
// `GET/PUT /v1/operator/notification-preferences`. The proxy resolves
// the actor (operator / location / user) from the verified bearer
// token, never from the URL, and operates on "the actor's own row".
// So the admin caller targets themselves automatically. No new
// proxy/backend route - this mirrors the merged G4 admin self-MFA
// pattern and the W-3 admin self-account pattern (both reused existing
// `/v1/...` routes via an admin client gateway + the established
// `AdminConsoleServicesScope` DI).
//
// HP #11 scope-chrome: notification preferences are flat per-user
// (per-(operator, user, event, channel)), NOT hierarchy-scoped. This is
// the same carve-out the operator-web Notifications screen and the My
// Account screen rely on - a personal preference surface, not an
// org-config surface. No selected-scope / inherited-source / effective-
// value triple is rendered because there is no hierarchy to inherit
// through; this is documented inline so future parity passes don't
// flag it as missing inheritance.
//
// Role-gate divergence from operator-web (deliberate, documented): the
// operator-web screen hides catalog rows whose role gate is not
// satisfied by the operator's active roles (`operator_owner`,
// `operator_general_manager`, `location_manager`, `supervisor`, ...).
// The admin console actor carries F&F-internal
// roles only (`super_admin` / `ff_support`), which are NOT operator
// roles, so applying the operator role gate here would hide every
// admin-only / manager-only row (the gate would never match). The
// admin actor is F&F internal staff managing their OWN notification
// preferences across all event classes, so the admin screen renders
// the full catalog unfiltered. This is intentional surface parity
// (the admin sees at least as much as any operator), not a leak: the
// backend RLS policy on `notification_preferences` still scopes every
// write to the admin's own row.
//
// UX writing standard (`memory/project_ux_writing_standard.md` +
// CLAUDE.md no-em-dash UX lint law): every label, button, status,
// snackbar trains the user. Plain English. No engineering jargon. No
// em dash anywhere in operator-facing copy.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../domain/models/notification_event_catalog.dart';
import '../../theme/app_theme.dart';
import 'package:forge_and_flow/widgets/console/console_info_button.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';
import '../services/admin_notification_preferences_gateway.dart';

/// Wiring-readiness state for one catalog entry. Mirrors the
/// operator-web Notifications screen's three-state model so the admin
/// surface reads identically.
enum _NotifEventState {
  /// Emit + delivery fully wired. Toggle controls fanout.
  available,

  /// Catalog entry exists; emitter not yet shipped. Toggle disabled;
  /// the row reads honestly so the admin knows the surface is coming.
  comingSoon,

  /// Emit is wired and Forge & Flow sends regardless of preference
  /// (system-mandated). Toggle disabled; subcopy points to the audit
  /// log.
  backendOnly,
}

/// Per-event readiness map. Kept byte-identical to the operator-web
/// screen's `_kEventState` so the two surfaces never drift: when a
/// hook ships, both maps flip together.
const Map<String, _NotifEventState> _kEventState = <String, _NotifEventState>{
  'notif.backfill.complete': _NotifEventState.available,
  'notif.backfill.failed': _NotifEventState.available,
  'notif.vendor.now_available': _NotifEventState.available,
  'notif.audit.anchor_failure': _NotifEventState.backendOnly,
  'notif.shift.stale': _NotifEventState.comingSoon,
  'notif.star.override': _NotifEventState.comingSoon,
  'notif.plan.updated': _NotifEventState.comingSoon,
  'notif.mfa.factor_changed': _NotifEventState.backendOnly,
};

_NotifEventState _stateFor(NotificationCatalogEntry entry) =>
    _kEventState[entry.eventKey] ?? _NotifEventState.available;

const Map<_NotifEventState, String> _kStateLabel = <_NotifEventState, String>{
  _NotifEventState.available: 'Available',
  _NotifEventState.comingSoon: 'Coming soon',
  _NotifEventState.backendOnly: 'Always on',
};

/// Per-state detail copy shown inside the row's info button popover,
/// appended to the event description. Mirrors the operator-web
/// Notifications screen's `_kStateDetails` so the two surfaces read
/// the same.
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

/// Info-button body for one row: the event description, then the
/// state detail copy. Mirrors the operator-web `_infoBodyFor`.
String _infoBodyFor(NotificationCatalogEntry event, _NotifEventState state) {
  final status = _kStateDetails[state] ?? '';
  if (status.isEmpty) return event.description;
  return '${event.description}\n\n$status';
}

/// Admin notification-preferences screen. Pure render +
/// optimistic-toggle widget; all I/O flows through [gateway]. When
/// [gateway] is null the screen renders honest read-only state with a
/// plain-English note (mirrors the operator-web disconnect posture and
/// the sibling admin screens' null-gateway fallback).
class AdminNotificationPreferencesScreen extends StatefulWidget {
  const AdminNotificationPreferencesScreen({
    super.key,
    this.gateway,
    this.idempotencyKeyFactory,
  });

  /// Live gateway. Null renders honest read-only state with copy
  /// explaining the disconnect.
  final AdminNotificationPreferencesGateway? gateway;

  /// Test-injectable idempotency-key generator. Production wires in a
  /// UUID-v4-ish generator; tests inject a deterministic counter.
  final String Function()? idempotencyKeyFactory;

  @override
  State<AdminNotificationPreferencesScreen> createState() =>
      _AdminNotificationPreferencesScreenState();
}

class _AdminNotificationPreferencesScreenState
    extends State<AdminNotificationPreferencesScreen> {
  /// In-memory map of `(eventKey, channel)` -> enabled preference. The
  /// scope is always `operator` for V1. Absence means "no row stored"
  /// -> use the catalog default.
  final Map<_PrefKey, bool> _explicit = <_PrefKey, bool>{};

  /// Stable idempotency key per `(eventKey, channel)`. Minted once on
  /// the first toggle of a row and reused across retries so a retry
  /// replays the same response instead of writing twice. G60/G70 bug
  /// class: never mint a fresh key per attempt.
  final Map<_PrefKey, String> _idemKeys = <_PrefKey, String>{};

  bool _loading = true;
  String? _loadError;
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
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError =
            "We couldn't load your notification settings. "
            'Refresh the page, or try again in a minute.';
      });
    }
  }

  /// Returns the stable idempotency key for [key], minting one on
  /// first use. The same key is reused for every retry of the same
  /// logical toggle.
  String _idempotencyKeyFor(_PrefKey key) {
    return _idemKeys.putIfAbsent(key, () {
      final factory = widget.idempotencyKeyFactory;
      if (factory != null) return factory();
      _idemCounter += 1;
      final ts = DateTime.now().microsecondsSinceEpoch;
      final r = Random().nextInt(0xffffff);
      return 'admin-notif-$ts-$_idemCounter-$r';
    });
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
        idempotencyKey: _idempotencyKeyFor(key),
      );
      if (!mounted) return;
      // No banner on success. The toggle reflects the new state and
      // the admin already sees it. Plain-English banner only on error.
    } catch (_) {
      if (!mounted) return;
      // Roll back the optimistic flip. Keep the minted idempotency key
      // so the next attempt replays the same request.
      setState(() => _explicit[key] = currentlyEnabled);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          key: Key('admin_notification_preferences_error_snackbar'),
          content: Text("Couldn't save. Try again."),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        key: Key('admin_notification_preferences_loading'),
        child: CircularProgressIndicator(),
      );
    }
    final disconnected = widget.gateway == null;
    final visibleEvents =
        <NotificationCategory, List<NotificationCatalogEntry>>{};
    // Render the FULL catalog. See the role-gate divergence note in
    // the file header: the admin actor has no operator role, so
    // applying the operator role gate would hide every gated row.
    for (final entry in kNotificationCatalog) {
      visibleEvents.putIfAbsent(
        entry.category,
        () => <NotificationCatalogEntry>[],
      );
      visibleEvents[entry.category]!.add(entry);
    }
    return OperatorWebScreenBody(
      scrollKey: const Key('admin_notification_preferences_screen'),
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Header(),
          if (disconnected) ...[
            const SizedBox(height: 12),
            const _DisconnectedNote(),
          ],
          if (_loadError != null) ...[
            const SizedBox(height: 12),
            _ErrorBanner(message: _loadError!),
          ],
          const SizedBox(height: 16),
          for (final category in NotificationCategory.values)
            if (visibleEvents.containsKey(category)) ...[
              _CategorySection(
                category: category,
                events: visibleEvents[category]!,
                resolveEnabled: _resolveEnabled,
                onToggle: disconnected ? null : _toggle,
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
          key: const Key('admin_notification_preferences_header_info'),
          title: 'Notifications',
          tooltip: 'About notifications',
          width: 360,
          body: Text(
            'Pick how Forge & Flow lets you know about important events. '
            'These settings are just for your admin sign-in. You can change '
            'any of them any time.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

/// Honest read-only note when no gateway is wired (demo /
/// share-preview without a backend, or a wiring gap). Mirrors the
/// operator-web disconnect posture and the sibling admin screens'
/// null-gateway fallback: the catalog still renders with defaults so
/// the admin can see what exists, but every toggle is disabled.
class _DisconnectedNote extends StatelessWidget {
  const _DisconnectedNote();

  @override
  Widget build(BuildContext context) {
    return const OperatorWebBanner(
      key: Key('admin_notification_preferences_disconnected_note'),
      tone: OperatorWebBannerTone.neutral,
      message:
          "You're seeing the default settings. Saving is turned off "
          'here until your account is connected. Your real settings '
          'are safe and unchanged.',
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return OperatorWebBanner(
      key: const Key('admin_notification_preferences_error_banner'),
      tone: OperatorWebBannerTone.error,
      message: message,
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

  /// Null when no gateway is wired - toggles render disabled.
  final Future<void> Function({
    required NotificationCatalogEntry event,
    required String channel,
    required bool currentlyEnabled,
  })?
  onToggle;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      key: Key('admin_notification_preferences_category_${category.name}'),
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
    // Match the operator-web row: title + state badge + an info "i"
    // button whose popover carries the description and the state
    // detail. No inline description / subcopy text.
    return Row(
      key: Key('admin_notification_preferences_event_${event.eventKey}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Row(
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
                  'admin_notification_preferences_state_info_${event.eventKey}',
                ),
                title: _kStateLabel[state] ?? 'Notification status',
                tooltip: 'Notification status',
                body: Text(
                  _infoBodyFor(event, state),
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
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
      key: Key('admin_notification_preferences_state_badge_$eventKey'),
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
          key: Key(
            'admin_notification_preferences_toggle_'
            '${event.eventKey}_$channel',
          ),
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
