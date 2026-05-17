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
// satisfied by the operator's roles (`operator_owner`, `operator_admin`,
// `operator_manager`, ...). The admin console actor carries F&F-internal
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

const Map<_NotifEventState, String> _kStateSubcopy =
    <_NotifEventState, String>{
  _NotifEventState.available: '',
  _NotifEventState.comingSoon:
      "We'll turn this on once the team launches it. "
          "You can come back later to set how you'd like to be notified.",
  _NotifEventState.backendOnly:
      "Forge & Flow sends this no matter what. It's part of how we "
          "keep your data safe. Open the audit log to see recent activity.",
};

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
        _loadError = "We couldn't load your notification settings. "
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
    final explicit = _explicit[_PrefKey(
      eventKey: event.eventKey,
      channel: channel,
    )];
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
    return SingleChildScrollView(
      key: const Key('admin_notification_preferences_screen'),
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
          const SizedBox(height: 18),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.notifications_outlined,
              size: 22,
              color: AppColors.sunsetDark,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Notifications',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Pick how Forge & Flow lets you know about important events. '
          'These settings are just for your admin sign-in. You can change '
          'any of them any time.',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
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
    return Container(
      key: const Key('admin_notification_preferences_disconnected_note'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.borderSubtle.withValues(alpha: 0.40),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline,
            size: 16,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "You're seeing the default settings. Saving is turned off "
              'here until your account is connected. Your real settings '
              'are safe and unchanged.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_notification_preferences_error_banner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.10),
        border: Border.all(
          color: AppColors.negative.withValues(alpha: 0.45),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: AppColors.negative),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.negative),
            ),
          ),
        ],
      ),
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
  })? onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('admin_notification_preferences_category_${category.name}'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            kNotificationCategoryLabels[category] ?? category.name,
            style: AppTextStyles.mono15(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
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
  })? onToggle;

  @override
  Widget build(BuildContext context) {
    final state = _stateFor(event);
    final isAvailable = state == _NotifEventState.available;
    final subcopy = _kStateSubcopy[state] ?? '';
    return Row(
      key: Key('admin_notification_preferences_event_${event.eventKey}'),
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
                ],
              ),
              const SizedBox(height: 4),
              Text(
                event.description,
                style: AppTextStyles.body12(color: AppColors.textMuted),
              ),
              if (subcopy.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subcopy,
                  key: Key(
                    'admin_notification_preferences_subcopy_'
                    '${event.eventKey}',
                  ),
                  style:
                      AppTextStyles.body12(color: AppColors.textSecondary),
                ),
              ],
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
        style: AppTextStyles.mono10(color: fg)
            .copyWith(fontWeight: FontWeight.w700),
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
  })? onToggle;

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
