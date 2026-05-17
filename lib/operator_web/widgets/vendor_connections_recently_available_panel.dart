// Phase 11W.8 follow-up — Vendor Connections "Recently available"
// panel.
//
// Operator-web-only chrome that sits at the top of the Vendor
// Connections screen, ABOVE the existing W2.D backfill progress panel.
// Mirrors the email fan-out shipped by `8.0.lifecycle`: when a vendor
// promotes to `production_credentialed`, the dispatcher fans out an
// email AND stamps `vendor_lifecycle_notification.notified_at`. This
// panel reads that stamp through the operator-scoped proxy route so
// the operator sees the same news in the console — no waiting for the
// email to arrive.
//
// Plain-English states (UX writing standard):
//
//   * loading      — spinner with "Checking for new vendors…" body.
//   * empty        — panel hidden when no vendors flipped recently.
//   * error        — honest "Could not load…" body with the proxy's
//                    error message and a Retry button.
//   * has-vendors  — one row per vendor, sorted newest first; each
//                    row shows the display name, "Newly available"
//                    label, relative timestamp ("3 days ago" /
//                    "yesterday" / "today"), and a "Connect" CTA.
//
// The "Connect" CTA fires an injected callback the screen wires to
// scroll-into-view + an open-flow nudge. The panel itself owns no
// connection state — it is a read-only news surface.

import 'package:flutter/material.dart';

import '../services/operator_web_vendor_lifecycle_recently_available_gateway.dart';
import '../../theme/app_theme.dart';

/// Panel state machine — drives the rendered surface based on the
/// gateway response (or absence of gateway).
enum _RecentlyAvailableState {
  /// No gateway wired. Panel hides itself entirely so the demo + early-
  /// wiring path renders nothing instead of faking promotions.
  notWired,
  loading,
  empty,
  hasVendors,
  failed,
}

/// Recently-available vendors panel. The operator-web Vendor
/// Connections screen mounts one of these at the top of its scroll
/// view; the panel reads the new
/// `vendor-lifecycle/recently-available` proxy route and renders one
/// row per vendor that recently flipped to
/// `production_credentialed`.
class VendorConnectionsRecentlyAvailablePanel extends StatefulWidget {
  const VendorConnectionsRecentlyAvailablePanel({
    super.key,
    required this.gateway,
    this.onConnectRequested,
    this.now,
  });

  /// Live operator-web gateway. Null in demo mode and during early
  /// wiring; the panel hides itself entirely in that case.
  final OperatorWebVendorLifecycleRecentlyAvailableGateway? gateway;

  /// Callback fired when the operator taps "Connect" on a row. The
  /// screen wires this to its existing connect-flow nudge (scroll the
  /// embedded `VendorConnectionsWidget` into view + flash the matching
  /// category section). When null, the row still renders the CTA but
  /// taps are no-ops.
  final void Function(OperatorWebRecentlyAvailableVendor vendor)?
      onConnectRequested;

  /// Test-only injection for the relative-timestamp formatter. Defaults
  /// to `DateTime.now`.
  final DateTime Function()? now;

  @override
  State<VendorConnectionsRecentlyAvailablePanel> createState() =>
      _VendorConnectionsRecentlyAvailablePanelState();
}

class _VendorConnectionsRecentlyAvailablePanelState
    extends State<VendorConnectionsRecentlyAvailablePanel> {
  _RecentlyAvailableState _state = _RecentlyAvailableState.loading;
  String? _errorMessage;
  List<OperatorWebRecentlyAvailableVendor> _vendors =
      const <OperatorWebRecentlyAvailableVendor>[];
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(
    covariant VendorConnectionsRecentlyAvailablePanel oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final gateway = widget.gateway;
    if (gateway == null) {
      setState(() {
        _state = _RecentlyAvailableState.notWired;
        _vendors = const <OperatorWebRecentlyAvailableVendor>[];
        _errorMessage = null;
      });
      return;
    }
    final generation = ++_loadGeneration;
    setState(() {
      _state = _RecentlyAvailableState.loading;
      _errorMessage = null;
    });
    try {
      final bundle = await gateway.loadRecentlyAvailable();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _vendors = bundle.vendors;
        _state = bundle.vendors.isEmpty
            ? _RecentlyAvailableState.empty
            : _RecentlyAvailableState.hasVendors;
      });
    } on OperatorWebVendorLifecycleRecentlyAvailableError catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _state = _RecentlyAvailableState.failed;
        _errorMessage = error.message;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _state = _RecentlyAvailableState.failed;
        _errorMessage =
            'Could not check for newly available vendors. Please retry.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_state) {
      case _RecentlyAvailableState.notWired:
      case _RecentlyAvailableState.empty:
        return const SizedBox.shrink(
          key: Key('vendor_connections_recently_available_hidden'),
        );
      case _RecentlyAvailableState.loading:
        return _PanelShell(
          key: const Key('vendor_connections_recently_available_loading'),
          child: const SizedBox(
            height: 64,
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        );
      case _RecentlyAvailableState.failed:
        return _PanelShell(
          key: const Key('vendor_connections_recently_available_failed'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Could not check for newly available vendors',
                style: AppTextStyles.body14(
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _errorMessage ?? 'Please retry in a moment.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: const Key(
                    'vendor_connections_recently_available_retry',
                  ),
                  onPressed: _refresh,
                  child: const Text('Retry'),
                ),
              ),
            ],
          ),
        );
      case _RecentlyAvailableState.hasVendors:
        return _PanelShell(
          key: const Key('vendor_connections_recently_available_panel'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.fiber_new_outlined,
                    size: 18,
                    color: AppColors.sunsetDark,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Recently available',
                    style: AppTextStyles.body14(
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'New connectors are now available. Connect them to '
                'start syncing data.',
                key: const Key(
                  'vendor_connections_recently_available_subtitle',
                ),
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              for (final vendor in _vendors)
                Padding(
                  key: Key(
                    'vendor_connections_recently_available_row_${vendor.vendorId}',
                  ),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _RecentlyAvailableRow(
                    vendor: vendor,
                    relativeTime: _formatRelativeTime(
                      vendor.promotedAt,
                      now: (widget.now ?? DateTime.now)().toUtc(),
                    ),
                    onConnect: widget.onConnectRequested == null
                        ? null
                        : () => widget.onConnectRequested!(vendor),
                  ),
                ),
            ],
          ),
        );
    }
  }
}

/// Plain-English relative timestamp. Returns "today", "yesterday", or
/// "N days ago" for promotions inside the 14-day window. Anything
/// older falls back to a date string.
@visibleForTesting
String formatRecentlyAvailableRelativeTime(
  DateTime promotedAt, {
  required DateTime now,
}) {
  return _formatRelativeTime(promotedAt, now: now);
}

String _formatRelativeTime(DateTime promotedAt, {required DateTime now}) {
  final promotedUtc = promotedAt.toUtc();
  final nowUtc = now.toUtc();
  final promotedDate = DateTime.utc(
    promotedUtc.year,
    promotedUtc.month,
    promotedUtc.day,
  );
  final nowDate = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day);
  final dayDelta = nowDate.difference(promotedDate).inDays;
  if (dayDelta <= 0) return 'today';
  if (dayDelta == 1) return 'yesterday';
  if (dayDelta < 14) return '$dayDelta days ago';
  // Beyond the default window — surface an absolute date so the
  // operator never sees a stale "13 days ago" pill that lies about
  // freshness.
  final mm = promotedDate.month.toString().padLeft(2, '0');
  final dd = promotedDate.day.toString().padLeft(2, '0');
  return '${promotedDate.year}-$mm-$dd';
}

class _PanelShell extends StatelessWidget {
  const _PanelShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }
}

class _RecentlyAvailableRow extends StatelessWidget {
  const _RecentlyAvailableRow({
    required this.vendor,
    required this.relativeTime,
    required this.onConnect,
  });

  final OperatorWebRecentlyAvailableVendor vendor;
  final String relativeTime;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  vendor.vendorDisplayName,
                  key: Key(
                    'vendor_connections_recently_available_row_name_${vendor.vendorId}',
                  ),
                  style: AppTextStyles.body14(
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.cardGlow,
                        border: Border.all(
                          color: AppColors.borderSubtle,
                          width: 1,
                        ),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        'Newly available',
                        style: AppTextStyles.mono11(
                          color: AppColors.sunsetDark,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      relativeTime,
                      key: Key(
                        'vendor_connections_recently_available_row_time_${vendor.vendorId}',
                      ),
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.tonal(
            key: Key(
              'vendor_connections_recently_available_row_connect_${vendor.vendorId}',
            ),
            onPressed: onConnect,
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }
}
