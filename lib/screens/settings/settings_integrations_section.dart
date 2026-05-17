// Wave 2 MP-1 — Mobile Settings Integrations section.
//
// Owns the per-category integration status rows (POS, Reservation,
// Labor) the mobile Integrations tab renders alongside the master
// `SettingsDemoLiveSwitch` and the operator-console deep-link.
//
// Read-only by design. The mobile Settings tab is a mirror of the
// operator-web console — connection management (connect, disconnect,
// re-test, OAuth handoff) lives on operator-web. Mobile only shows
// "what is the current state of this category for this location"
// and a pointer to the operator console for any change.
//
// HP #2 (CLAUDE.md): this widget does NOT branch on the build-time
// `kDemoMode` flag. The per-category status pill is driven entirely
// by the runtime `demo_mode_state` rows surfaced via
// [DemoModeStateNotifier]. Demo and prod resolve through the same
// code path; the only difference is which writer populated the row
// (`MockReplayDataSourceProvider` vs the vendor sinks).
//
// Why not introduce a dedicated vendor-status provider here:
// the slice contract for MP-1 forbids adding new vendor status
// providers — the existing `DemoModeStateNotifier` is the only
// per-(operator, location, category) state surface the mobile shell
// currently subscribes to. The richer "connected / polling-stale /
// error / no-vendor" matrix the eventual ops-portal screen renders
// is out of scope for this slice and lives on operator-web (the
// "Manage integrations on operator console" pointer below opens that
// surface via the existing B11.1 handoff-code flow).
//
// Authority:
//   * docs/contracts/demo_mode_contract.md "Per-(O, L, C) runtime state"
//   * docs/_execution/lane_b_features/01_product_rule_and_ia.md
//     "Redemption-Code Handoff (B11)" + addendum A1 — short opaque
//     codes only, no JWT in URL parameters.
//   * lib/state/demo_mode_state_notifier.dart — the snapshot source.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth/handoff_code_gateway.dart';
import '../../services/integration/demo_mode_state.dart';
import '../../services/integration/integration_adapter_common.dart';
import '../../state/demo_mode_state_notifier.dart';
import '../../theme/app_theme.dart';
import 'settings_demo_live_switch.dart';
import 'settings_pointer_row.dart';
import 'settings_shared_widgets.dart';

/// The full Integrations tab body. Owns:
///   * Per-category status rows (POS, Reservation, Labor) reading
///     [DemoModeStateNotifier].
///   * The mounted master `SettingsDemoLiveSwitch` (the C-4 surface;
///     verbatim mount — MP-1 only moves the widget into this section).
///   * A "Manage integrations on operator console" pointer row that
///     uses the existing B11.1 `HandoffCodeGateway` mint + opaque-code
///     handoff URL (NO JWT or long-lived credential in the URL).
class SettingsIntegrationsSection extends StatelessWidget {
  const SettingsIntegrationsSection({
    super.key,
    this.handoffCodeGateway,
    this.launchExternalUrl,
    this.copyToClipboard,
  });

  /// Gateway used by the deep-link pointer row. Reuses the same
  /// `HandoffCodeGateway` already plumbed through other Settings
  /// pointer rows (e.g. "Manage Account on Ops Web"); production
  /// passes the proxy-backed implementation, tests pass a fake.
  final HandoffCodeGateway? handoffCodeGateway;

  /// Test seam for `url_launcher`. Production leaves this null and
  /// `SettingsPointerRow` falls back to the real launcher.
  final Future<bool> Function(Uri url)? launchExternalUrl;

  /// Test seam for clipboard writes. Production leaves this null and
  /// `SettingsPointerRow` falls back to the real clipboard.
  final Future<void> Function(String value)? copyToClipboard;

  /// Stable opWebPath the pointer row resolves into
  /// `https://app.forgeflow.app/<opWebPath>`. Mirror of the
  /// operator-web router's `kOperatorWebNavVendorConnections`
  /// landing path.
  static const String _opWebPath = 'vendor-connections';

  /// Stable nav id the proxy embeds in the handoff URL's `nav`
  /// parameter so operator-web lands on the Vendor Connections
  /// surface after redeem. Mirror of `kOperatorWebNavVendorConnections`
  /// in `lib/operator_web/router/operator_web_router.dart`.
  static const String _navId = 'vendor_connections';

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('settings_integrations_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const _CategoryStatusList(),
        const SizedBox(height: 12),
        const SettingsDemoLiveSwitch(),
        SettingsPointerRow(
          key: const Key('settings_integrations_console_pointer'),
          label: 'Manage integrations on operator console',
          opWebPath: _opWebPath,
          navId: _navId,
          handoffCodeGateway: handoffCodeGateway,
          launchExternalUrl: launchExternalUrl,
          copyToClipboard: copyToClipboard,
        ),
      ],
    );
  }
}

/// Per-category status list (POS, Reservation, Labor). Reads
/// [DemoModeStateNotifier] and renders one row per category. When the
/// notifier is unavailable (e.g. unauth shells or tests without the
/// provider mounted) the list collapses to a neutral "status
/// unavailable" placeholder.
class _CategoryStatusList extends StatelessWidget {
  const _CategoryStatusList();

  /// Stable display order — matches the mobile demo banner and the
  /// operator-web Vendor Connections category cards.
  static const List<IntegrationCategory> _categories = <IntegrationCategory>[
    IntegrationCategory.pos,
    IntegrationCategory.reservation,
    IntegrationCategory.labor,
  ];

  @override
  Widget build(BuildContext context) {
    DemoModeStateNotifier? notifier;
    try {
      notifier = context.watch<DemoModeStateNotifier?>();
    } on ProviderNotFoundException {
      notifier = null;
    }
    final snapshot = notifier?.snapshot ?? DemoModeStateSnapshot.empty;
    final hasScope =
        snapshot.operatorId.isNotEmpty && snapshot.locationId.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final category in _categories)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _CategoryStatusRow(
              key: Key(
                'settings_integrations_status_${_categoryKey(category)}',
              ),
              category: category,
              status: _statusFor(
                category: category,
                snapshot: snapshot,
                hasScope: hasScope,
              ),
              hasError: snapshot.errorMessage != null,
            ),
          ),
      ],
    );
  }

  static _CategoryStatus _statusFor({
    required IntegrationCategory category,
    required DemoModeStateSnapshot snapshot,
    required bool hasScope,
  }) {
    if (!hasScope) return _CategoryStatus.unscoped;
    final record = _recordFor(snapshot.records, category);
    if (record == null) return _CategoryStatus.unknown;
    return record.isDemo ? _CategoryStatus.demo : _CategoryStatus.live;
  }

  static DemoModeRecord? _recordFor(
    List<DemoModeRecord> records,
    IntegrationCategory category,
  ) {
    for (final record in records) {
      if (record.category == category) return record;
    }
    return null;
  }
}

/// One status pill row for a single category. Read-only display.
class _CategoryStatusRow extends StatelessWidget {
  const _CategoryStatusRow({
    super.key,
    required this.category,
    required this.status,
    required this.hasError,
  });

  final IntegrationCategory category;
  final _CategoryStatus status;

  /// True when the active snapshot carries a non-null `errorMessage`
  /// (i.e. the most-recent `fetchDemoModeStates` round failed). The
  /// row appends a one-line "couldn't refresh status" hint instead of
  /// hiding the row entirely, so the operator still sees the
  /// last-known good state.
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      accentColor: status.accentColor,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: status.accentColor.withValues(alpha: 0.12),
                  border: Border.all(
                    color: status.accentColor.withValues(alpha: 0.5),
                  ),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Icon(
                  _iconFor(category),
                  size: 18,
                  color: status.accentColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _labelFor(category),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.mono12(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      hasError
                          ? '${status.description(category)} '
                                'Couldn’t refresh status. '
                                'Showing last-known.'
                          : status.description(category),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body13(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Container(
                key: Key(
                  'settings_integrations_status_pill_${_categoryKey(category)}',
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: status.accentColor.withValues(alpha: 0.15),
                  border: Border.all(
                    color: status.accentColor.withValues(alpha: 0.5),
                    width: 1,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text(
                  status.pillLabel,
                  style: AppTextStyles.mono11(color: status.accentColor),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static IconData _iconFor(IntegrationCategory category) {
    switch (category) {
      case IntegrationCategory.pos:
        return Icons.point_of_sale_outlined;
      case IntegrationCategory.reservation:
        return Icons.event_seat_outlined;
      case IntegrationCategory.labor:
        return Icons.badge_outlined;
    }
  }

  static String _labelFor(IntegrationCategory category) {
    switch (category) {
      case IntegrationCategory.pos:
        return 'POS';
      case IntegrationCategory.reservation:
        return 'Reservations';
      case IntegrationCategory.labor:
        return 'Labor';
    }
  }
}

/// Logical status the row renders. Bounded to what the existing
/// `demo_mode_state` row carries — richer "polling-stale / error /
/// no-vendor" reporting is out of scope for MP-1 per the slice
/// contract.
enum _CategoryStatus {
  /// No active (operator, location) scope — e.g. unauth or demo shell
  /// without a restaurant selected.
  unscoped,

  /// Scope is active but the `demo_mode_state` row has not been
  /// observed yet (notifier returned no record for this category).
  unknown,

  /// Row exists and `is_demo = true`.
  demo,

  /// Row exists and `is_demo = false`.
  live,
}

extension _CategoryStatusUi on _CategoryStatus {
  String get pillLabel {
    switch (this) {
      case _CategoryStatus.unscoped:
        return 'No location';
      case _CategoryStatus.unknown:
        return 'Unknown';
      case _CategoryStatus.demo:
        return 'Demo';
      case _CategoryStatus.live:
        return 'Live';
    }
  }

  Color get accentColor {
    switch (this) {
      case _CategoryStatus.unscoped:
      case _CategoryStatus.unknown:
        return AppColors.textMuted;
      case _CategoryStatus.demo:
        return AppColors.sunset;
      case _CategoryStatus.live:
        return AppColors.positive;
    }
  }

  String description(IntegrationCategory category) {
    switch (this) {
      case _CategoryStatus.unscoped:
        return 'Sign in and pick a location to see this category’s '
            'status.';
      case _CategoryStatus.unknown:
        return 'Status not yet loaded. Pull to refresh.';
      case _CategoryStatus.demo:
        switch (category) {
          case IntegrationCategory.pos:
            return 'Showing demo POS data. Connect a POS on the operator '
                'console to go live.';
          case IntegrationCategory.reservation:
            return 'Showing demo reservation data. Connect a reservation '
                'system on the operator console to go live.';
          case IntegrationCategory.labor:
            return 'Showing demo labor data. Connect a labor system on the '
                'operator console to go live.';
        }
      case _CategoryStatus.live:
        switch (category) {
          case IntegrationCategory.pos:
            return 'Connected to a live POS for this location.';
          case IntegrationCategory.reservation:
            return 'Connected to a live reservation system for this location.';
          case IntegrationCategory.labor:
            return 'Connected to a live labor system for this location.';
        }
    }
  }
}

String _categoryKey(IntegrationCategory category) {
  switch (category) {
    case IntegrationCategory.pos:
      return 'pos';
    case IntegrationCategory.reservation:
      return 'reservation';
    case IntegrationCategory.labor:
      return 'labor';
  }
}
