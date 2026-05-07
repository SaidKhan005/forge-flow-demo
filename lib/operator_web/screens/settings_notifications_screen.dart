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

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../domain/models/notification_event_catalog.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/operator_web_notification_preferences_gateway_provider.dart';
import '../../theme/app_theme.dart';

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
        _loadError = "We couldn't load your notification settings. "
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
      // No banner on success - toggle reflects the new state and the
      // operator already sees it. Plain-English banner only on error.
    } catch (_) {
      if (!mounted) return;
      // Roll back the optimistic flip.
      setState(() => _explicit[key] = currentlyEnabled);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          key: Key('settings_notifications_error_snackbar'),
          content: Text("Couldn't save - try again"),
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
    final visibleEvents = <NotificationCategory, List<NotificationCatalogEntry>>{};
    for (final entry in kNotificationCatalog) {
      if (!roleSatisfiesGate(entry.roleGate, widget.session.roles)) continue;
      visibleEvents.putIfAbsent(entry.category, () => <NotificationCatalogEntry>[]);
      visibleEvents[entry.category]!.add(entry);
    }
    return SingleChildScrollView(
      key: const Key('settings_notifications_screen'),
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(),
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
          'You can change any of these any time.',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('settings_notifications_error_banner'),
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

  /// Null when no gateway is wired (demo-without-mixin) - toggles
  /// render disabled.
  final Future<void> Function({
    required NotificationCatalogEntry event,
    required String channel,
    required bool currentlyEnabled,
  })? onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('settings_notifications_category_${category.name}'),
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
    return Row(
      key: Key('settings_notifications_event_${event.eventKey}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                event.title,
                style: AppTextStyles.mono14(
                  color: AppColors.textPrimary,
                  weight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                event.description,
                style: AppTextStyles.body12(color: AppColors.textMuted),
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
              onToggle: onToggle,
            ),
          ),
      ],
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
