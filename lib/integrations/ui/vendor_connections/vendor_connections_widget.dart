// Phase 8.0 — Shared Vendor Connections widget tree.
//
// Host-shell-agnostic. The same widget code mounts in:
//
//   * F&F Operations Console (Phase 11A) via
//     `lib/admin/screens/vendor_connections/vendor_connections_admin_mount.dart`.
//   * Operator Web Console (Phase 11W) via
//     `lib/operator_web/screens/vendor_connections_operator_mount.dart`
//     (lands in 11W.8).
//
// The widget reads (operator_id, location_id) from host context. RLS
// + repository scoping in the gateway enforces what the host context
// is allowed to see; this widget renders whatever the gateway
// returns.
//
// UX writing standard (per
// `docs/phases/phase_8/vendor_connections_admin_surface.md`): every
// button has a 1-line "what this is" header + 1–2 sentence "what
// happens when you click" explainer; status badges have tooltips
// with remediation; error messages explain what / why / what to do
// next; empty states explain context and suggest the next step;
// confirmations explain consequences as bullets.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../admin/admin_human_labels.dart';
import '../../../theme/app_theme.dart';
import 'in_memory_vendor_connections_gateway.dart';
import 'vendor_connections_gateway.dart';
import 'vendor_connections_models.dart';

/// Default in-memory gateway used when the host shell does not wire
/// a production gateway. Keeps walkthrough + widget tests
/// reproducible without a Cloud Run dependency.
final VendorConnectionsGateway _defaultDemoGateway =
    InMemoryVendorConnectionsGateway();

/// Dual-surface root widget. Mount this with [operatorId] +
/// [locationId] resolved by the host shell — F&F Ops Console reads
/// from the operator picker; Operator Web Console reads from the
/// signed-in user's session.
class VendorConnectionsWidget extends StatefulWidget {
  const VendorConnectionsWidget({
    super.key,
    required this.operatorId,
    required this.locationId,
    this.locationNameOverride,
    this.gateway,
    this.canMutate = true,
    this.onConnectFlowStarted,
  });

  final String operatorId;
  final String locationId;
  final String? locationNameOverride;

  /// Production wires the HTTP gateway; demo + tests fall back to
  /// [_defaultDemoGateway].
  final VendorConnectionsGateway? gateway;

  /// `false` for `ff_support` (read-only in F&F Ops Console). Hides
  /// connect / test / disconnect buttons but still renders status.
  final bool canMutate;

  /// Optional host hook for OAuth/key-paste redirects. Web hosts can
  /// navigate the browser; test/demo hosts can leave it null and keep
  /// the in-memory flow on-page.
  final Future<void> Function(VendorConnectFlowStart flow)?
  onConnectFlowStarted;

  @override
  State<VendorConnectionsWidget> createState() =>
      _VendorConnectionsWidgetState();
}

class _VendorConnectionsWidgetState extends State<VendorConnectionsWidget> {
  bool _loading = true;
  String? _error;
  VendorConnectionsBundle? _bundle;

  VendorConnectionsGateway get _gateway =>
      widget.gateway ?? _defaultDemoGateway;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bundle = await _gateway.loadBundle(
        operatorId: widget.operatorId,
        locationId: widget.locationId,
      );
      if (!mounted) return;
      setState(() {
        _bundle = bundle;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load vendor connections: $error';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _bundle == null) {
      return const Center(
        key: Key('vendor_connections_loading'),
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return _ErrorBanner(
        key: const Key('vendor_connections_error'),
        message: _error!,
      );
    }
    final bundle = _bundle!;
    return ColoredBox(
      color: AppColors.backgroundDeep,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Header(
                  locationName:
                      widget.locationNameOverride ?? bundle.locationName,
                ),
                const SizedBox(height: 16),
                _CategorySection(
                  key: const Key('vendor_connections_section_pos'),
                  label: 'Point-of-sale',
                  categoryDescription:
                      'Sales, checks, covers, and closed-order timing feed the dashboard and baseline math.',
                  row: bundle.posConnection,
                  isDemo: bundle.demoFlags[VendorCategory.pos] ?? true,
                  category: VendorCategory.pos,
                  canMutate: widget.canMutate,
                  onConnect: _onConnect,
                  onTest: _onTestConnection,
                  onDisconnect: _onDisconnect,
                  onLogs: _onViewLogs,
                ),
                const SizedBox(height: 14),
                _CategorySection(
                  key: const Key('vendor_connections_section_reservation'),
                  label: 'Reservations',
                  categoryDescription:
                      'Bookings and party sizes help forecast covers and compare actual pacing against expected demand.',
                  row: bundle.reservationConnection,
                  isDemo: bundle.demoFlags[VendorCategory.reservation] ?? true,
                  category: VendorCategory.reservation,
                  canMutate: widget.canMutate,
                  onConnect: _onConnect,
                  onTest: _onTestConnection,
                  onDisconnect: _onDisconnect,
                  onLogs: _onViewLogs,
                ),
                const SizedBox(height: 14),
                _CategorySection(
                  key: const Key('vendor_connections_section_labor'),
                  label: 'Scheduling and labor',
                  categoryDescription:
                      'Schedules, punches, and roles power labor variance and week-to-date operating views.',
                  row: bundle.laborConnection,
                  isDemo: bundle.demoFlags[VendorCategory.labor] ?? true,
                  category: VendorCategory.labor,
                  canMutate: widget.canMutate,
                  onConnect: _onConnect,
                  onTest: _onTestConnection,
                  onDisconnect: _onDisconnect,
                  onLogs: _onViewLogs,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _onConnect(VendorCategory category) async {
    final entries = await _gateway.listAvailableVendors(category: category);
    if (!mounted) return;
    final picked = await showDialog<VendorPickerEntry>(
      context: context,
      builder: (_) => _VendorPickerDialog(category: category, entries: entries),
    );
    if (picked == null || !mounted) return;
    String? module;
    if (picked.requiresModule) {
      module = await showDialog<String>(
        context: context,
        builder: (_) => _ModuleDisambiguationDialog(entry: picked),
      );
      // ADP RUN / QuickBooks Payroll is rejected before OAuth.
      if (module == null) return;
      if (module == 'unsupported') {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (_) => const _UnsupportedModuleDialog(),
        );
        return;
      }
    }
    try {
      final flow = await _gateway.startConnect(
        operatorId: widget.operatorId,
        locationId: widget.locationId,
        vendorId: picked.vendorId,
        module: module,
      );
      await widget.onConnectFlowStarted?.call(flow);
      await _refresh();
    } on VendorConnectionsGatewayError catch (e) {
      _showError(e.message, remediation: e.remediation);
    } catch (e) {
      _showError('Could not start the connection: $e');
    }
  }

  Future<void> _onTestConnection(VendorConnectionRow row) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _TestConnectionLoadingDialog(),
    );
    try {
      final result = await _gateway.testConnection(
        operatorId: widget.operatorId,
        locationId: widget.locationId,
        vendorId: row.vendorId,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      await showDialog<void>(
        context: context,
        builder: (_) => _TestConnectionResultDialog(row: row, result: result),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      _showError('Test connection failed: $e');
    }
  }

  Future<void> _onDisconnect(VendorConnectionRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _DisconnectConfirmDialog(row: row),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _gateway.disconnect(
        operatorId: widget.operatorId,
        locationId: widget.locationId,
        vendorId: row.vendorId,
        reason: 'operator_action',
      );
      await _refresh();
    } catch (e) {
      _showError('Disconnect failed: $e');
    }
  }

  Future<void> _onViewLogs(VendorConnectionRow row) async {
    try {
      final logs = await _gateway.loadLogs(
        operatorId: widget.operatorId,
        locationId: widget.locationId,
        vendorId: row.vendorId,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _SyncLogsDialog(row: row, entries: logs),
      );
    } catch (e) {
      _showError('Could not load sync logs: $e');
    }
  }

  void _showError(String message, {String? remediation}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(remediation == null ? message : '$message\n$remediation'),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.locationName});

  final String locationName;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CategoryIcon(category: null, size: 34),
          const SizedBox(height: 10),
          Text(
            'Vendor integrations',
            style: AppTextStyles.pageTitle(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 6),
          Text(
            'Manage the services connected to $locationName. Forge & Flow reads data for reporting and forecasting; it does not push changes back to vendor systems.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _CategorySection extends StatelessWidget {
  const _CategorySection({
    super.key,
    required this.label,
    required this.categoryDescription,
    required this.row,
    required this.isDemo,
    required this.category,
    required this.canMutate,
    required this.onConnect,
    required this.onTest,
    required this.onDisconnect,
    required this.onLogs,
  });

  final String label;
  final String categoryDescription;
  final VendorConnectionRow? row;
  final bool isDemo;
  final VendorCategory category;
  final bool canMutate;
  final ValueChanged<VendorCategory> onConnect;
  final ValueChanged<VendorConnectionRow> onTest;
  final ValueChanged<VendorConnectionRow> onDisconnect;
  final ValueChanged<VendorConnectionRow> onLogs;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(16),
      child: row == null
          ? _EmptyState(
              label: label,
              categoryDescription: categoryDescription,
              isDemo: isDemo,
              category: category,
              canMutate: canMutate,
              onConnect: () => onConnect(category),
            )
          : _ConnectedCard(
              category: category,
              row: row!,
              canMutate: canMutate,
              onTest: () => onTest(row!),
              onDisconnect: () => onDisconnect(row!),
              onLogs: () => onLogs(row!),
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.label,
    required this.categoryDescription,
    required this.isDemo,
    required this.category,
    required this.canMutate,
    required this.onConnect,
  });

  final String label;
  final String categoryDescription;
  final bool isDemo;
  final VendorCategory category;
  final bool canMutate;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CategoryIcon(category: category),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  Text(
                    label,
                    style: AppTextStyles.sectionTitle(
                      color: AppColors.textPrimary,
                    ),
                  ),
                  if (isDemo)
                    Tooltip(
                      message:
                          'This category is showing demo data until a vendor is connected for this location.',
                      child: _StatusChip(
                        key: Key(
                          'vendor_connections_demo_chip_${category.name}',
                        ),
                        label: 'Demo mode',
                        color: AppColors.sunset,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                categoryDescription,
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              if (canMutate)
                FilledButton.icon(
                  key: Key('vendor_connections_connect_${category.name}'),
                  onPressed: onConnect,
                  icon: const Icon(Icons.link, size: 16),
                  label: Text('Connect ${_categoryShortLabel(category)}'),
                )
              else
                Text(
                  'You do not have permission to connect a vendor for this category.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
            ],
          ),
        ),
      ],
    );
  }

  String _categoryShortLabel(VendorCategory category) {
    switch (category) {
      case VendorCategory.pos:
        return 'POS';
      case VendorCategory.labor:
        return 'scheduling vendor';
      case VendorCategory.reservation:
        return 'reservations vendor';
    }
  }
}

class _ConnectedCard extends StatelessWidget {
  const _ConnectedCard({
    required this.category,
    required this.row,
    required this.canMutate,
    required this.onTest,
    required this.onDisconnect,
    required this.onLogs,
  });

  final VendorCategory category;
  final VendorConnectionRow row;
  final bool canMutate;
  final VoidCallback onTest;
  final VoidCallback onDisconnect;
  final VoidCallback onLogs;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _VendorLogo(vendorId: row.vendorId, displayName: row.displayName),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  Text(
                    row.displayName,
                    style: AppTextStyles.sectionTitle(
                      color: AppColors.textPrimary,
                    ),
                  ),
                  _StatusBadge(
                    status: row.status,
                    message: row.lastErrorMessage,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _categoryConnectedLine(category),
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 4),
              Text(
                _summaryLine(row),
                style: AppTextStyles.body12(color: AppColors.textSecondary),
              ),
              if (row.webhookUrl != null) ...<Widget>[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundDeep.withValues(alpha: 0.65),
                    border: Border.all(color: AppColors.borderSubtle),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: SelectableText(
                          'Webhook URL: ${row.webhookUrl}',
                          style: AppTextStyles.mono11(
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                      IconButton(
                        key: Key(
                          'vendor_connections_copy_webhook_${row.vendorId}',
                        ),
                        tooltip:
                            'Copy the webhook URL into your ${row.displayName} portal',
                        onPressed: () {
                          // Copy is a no-op stub at the widget layer; production
                          // wires Clipboard.setData behind a feature plug.
                        },
                        icon: const Icon(Icons.copy, size: 16),
                      ),
                    ],
                  ),
                ),
              ],
              if (row.lastErrorMessage != null) ...<Widget>[
                const SizedBox(height: 8),
                _ErrorRemediation(message: row.lastErrorMessage!),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  if (canMutate)
                    OutlinedButton.icon(
                      key: Key('vendor_connections_test_${row.vendorId}'),
                      onPressed: onTest,
                      icon: const Icon(Icons.fact_check_outlined, size: 16),
                      label: const Text('Test connection'),
                    ),
                  OutlinedButton.icon(
                    key: Key('vendor_connections_logs_${row.vendorId}'),
                    onPressed: onLogs,
                    icon: const Icon(Icons.list_alt, size: 16),
                    label: const Text('View logs'),
                  ),
                  if (canMutate)
                    OutlinedButton.icon(
                      key: Key('vendor_connections_disconnect_${row.vendorId}'),
                      onPressed: onDisconnect,
                      icon: const Icon(Icons.link_off, size: 16),
                      label: const Text('Disconnect'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _categoryConnectedLine(VendorCategory category) {
    switch (category) {
      case VendorCategory.pos:
        return 'Sales and order data are connected for this location.';
      case VendorCategory.reservation:
        return 'Reservation and cover pacing data are connected for this location.';
      case VendorCategory.labor:
        return 'Schedule, punch, and role data are connected for this location.';
    }
  }

  String _summaryLine(VendorConnectionRow row) {
    final lastSync = row.lastSyncAt;
    if (lastSync == null) {
      return 'No data received yet. The first poll runs in the next few minutes.';
    }
    final ago = DateTime.now().toUtc().difference(lastSync);
    final unit = ago.inMinutes < 60
        ? '${ago.inMinutes} min ago'
        : ago.inHours < 24
        ? '${ago.inHours} hr ago'
        : '${ago.inDays} days ago';
    final records = row.recordsLast24h ?? 0;
    final errors = row.errorsLast24h ?? 0;
    return 'Last sync: $unit - $records records - $errors errors (24h)';
  }
}

class _CategoryIcon extends StatelessWidget {
  const _CategoryIcon({required this.category, this.size = 44});

  final VendorCategory? category;
  final double size;

  @override
  Widget build(BuildContext context) {
    final icon = switch (category) {
      VendorCategory.pos => Icons.point_of_sale_outlined,
      VendorCategory.reservation => Icons.event_seat_outlined,
      VendorCategory.labor => Icons.schedule_outlined,
      null => Icons.hub_outlined,
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.12),
        border: Border.all(color: AppColors.peacock.withValues(alpha: 0.34)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: AppColors.peacockDark, size: size * 0.48),
    );
  }
}

class _VendorLogo extends StatelessWidget {
  const _VendorLogo({
    required this.vendorId,
    required this.displayName,
    this.size = 48,
  });

  final String vendorId;
  final String displayName;
  final double size;

  @override
  Widget build(BuildContext context) {
    final brand = _vendorBrand(vendorId, displayName);
    final fallback = _VendorInitials(brand: brand);
    return Tooltip(
      message: brand.iconUrl == null
          ? '${brand.displayName} logo'
          : 'Official ${brand.displayName} icon from ${brand.sourceHost}',
      child: SizedBox(
        width: size,
        height: size,
        child: brand.iconUrl == null || !kIsWeb
            ? fallback
            : ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  brand.iconUrl!,
                  fit: BoxFit.cover,
                  webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
                  errorBuilder: (_, __, ___) => fallback,
                ),
              ),
      ),
    );
  }
}

class _VendorInitials extends StatelessWidget {
  const _VendorInitials({required this.brand});

  final _VendorBrand brand;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: brand.color.withValues(alpha: 0.13),
        border: Border.all(color: brand.color.withValues(alpha: 0.44)),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Text(
        brand.initials,
        style: AppTextStyles.chipLabel(color: brand.color),
      ),
    );
  }
}

class _VendorBrand {
  const _VendorBrand({
    required this.displayName,
    required this.initials,
    required this.color,
    this.iconUrl,
    this.sourceHost,
  });

  final String displayName;
  final String initials;
  final Color color;
  final String? iconUrl;
  final String? sourceHost;
}

_VendorBrand _vendorBrand(String vendorId, String displayName) {
  switch (vendorId) {
    case 'aloha_ncr_voyix':
      return const _VendorBrand(
        displayName: 'Aloha (NCR Voyix)',
        initials: 'NCR',
        color: Color(0xFF004C97),
        iconUrl: 'https://developer.ncrvoyix.com/favicon.ico',
        sourceHost: 'developer.ncrvoyix.com',
      );
    case 'clover':
      return const _VendorBrand(
        displayName: 'Clover',
        initials: 'Cl',
        color: Color(0xFF00875A),
        iconUrl: 'https://www.clover.com/favicon.ico',
        sourceHost: 'clover.com',
      );
    case 'lightspeed_lsk':
      return const _VendorBrand(
        displayName: 'Lightspeed',
        initials: 'LS',
        color: Color(0xFFE21B2D),
        iconUrl: 'https://www.lightspeedhq.com/favicon.ico',
        sourceHost: 'lightspeedhq.com',
      );
    case 'oracle_micros_simphony':
      return const _VendorBrand(
        displayName: 'Oracle MICROS Simphony',
        initials: 'Or',
        color: Color(0xFFC74634),
        iconUrl: 'https://www.oracle.com/favicon.ico',
        sourceHost: 'oracle.com',
      );
    case 'revel':
      return const _VendorBrand(
        displayName: 'Revel Systems',
        initials: 'Rv',
        color: Color(0xFF2B5C8A),
        iconUrl: 'https://revelsystems.com/favicon.ico',
        sourceHost: 'revelsystems.com',
      );
    case 'square':
      return const _VendorBrand(
        displayName: 'Square',
        initials: 'Sq',
        color: Color(0xFF111827),
        iconUrl: 'https://squareup.com/favicon.ico',
        sourceHost: 'squareup.com',
      );
    case 'toast':
      return const _VendorBrand(
        displayName: 'Toast',
        initials: 'To',
        color: Color(0xFFFF4F00),
        iconUrl: 'https://www.toasttab.com/favicon.ico',
        sourceHost: 'toasttab.com',
      );
    case 'libro':
      return const _VendorBrand(
        displayName: 'Libro Reserve',
        initials: 'Li',
        color: Color(0xFF006C5B),
        iconUrl: 'https://librorez.com/favicon.ico',
        sourceHost: 'librorez.com',
      );
    case 'opentable':
      return const _VendorBrand(
        displayName: 'OpenTable',
        initials: 'OT',
        color: Color(0xFFDA3743),
        iconUrl: 'https://www.opentable.com/favicon.ico',
        sourceHost: 'opentable.com',
      );
    case 'sevenrooms':
      return const _VendorBrand(
        displayName: 'SevenRooms',
        initials: '7R',
        color: Color(0xFF25364A),
        iconUrl: 'https://sevenrooms.com/favicon.ico',
        sourceHost: 'sevenrooms.com',
      );
    case 'tock':
      return const _VendorBrand(
        displayName: 'Tock',
        initials: 'Tk',
        color: Color(0xFF1F2933),
        iconUrl: 'https://www.exploretock.com/favicon.ico',
        sourceHost: 'exploretock.com',
      );
    case 'adp':
      return const _VendorBrand(
        displayName: 'ADP Workforce Now / Workforce Manager',
        initials: 'ADP',
        color: Color(0xFFD0271D),
        iconUrl: 'https://www.adp.com/favicon.ico',
        sourceHost: 'adp.com',
      );
    case 'agendrix':
      return const _VendorBrand(
        displayName: 'Agendrix',
        initials: 'Ag',
        color: Color(0xFF246BFE),
        iconUrl: 'https://www.agendrix.com/favicon.ico',
        sourceHost: 'agendrix.com',
      );
    case 'humanity':
      return const _VendorBrand(
        displayName: 'Humanity',
        initials: 'Hu',
        color: Color(0xFF2463EB),
        iconUrl: 'https://www.humanity.com/favicon.ico',
        sourceHost: 'humanity.com',
      );
    case 'push_operations':
      return const _VendorBrand(
        displayName: 'Push Operations',
        initials: 'Pu',
        color: Color(0xFF22577A),
        iconUrl: 'https://www.pushoperations.com/favicon.ico',
        sourceHost: 'pushoperations.com',
      );
    case 'quickbooks_time':
      return const _VendorBrand(
        displayName: 'QuickBooks Time',
        initials: 'QB',
        color: Color(0xFF2CA01C),
        iconUrl: 'https://www.intuit.com/favicon.ico',
        sourceHost: 'quickbooks.intuit.com',
      );
    case 'seven_shifts':
      return const _VendorBrand(
        displayName: '7shifts',
        initials: '7s',
        color: Color(0xFF2E6B4F),
        iconUrl: 'https://www.7shifts.com/favicon.ico',
        sourceHost: '7shifts.com',
      );
    default:
      final words = displayName
          .split(RegExp(r'\s+'))
          .where((word) => word.trim().isNotEmpty)
          .take(2)
          .toList();
      final initials = words.isEmpty
          ? '?'
          : words.map((word) => word.substring(0, 1)).join();
      return _VendorBrand(
        displayName: displayName,
        initials: initials,
        color: AppColors.sunsetDark,
      );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.42)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: AppTextStyles.chipLabel(color: color)),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status, this.message});

  final VendorConnectionStatus status;
  final String? message;

  @override
  Widget build(BuildContext context) {
    final tip = _tooltipFor(status, message);
    final color = _colorFor(context, status);
    final label = _labelFor(status);
    return Tooltip(
      message: tip,
      child: _StatusChip(
        key: Key('vendor_connections_status_$label'),
        label: label,
        color: color,
      ),
    );
  }

  String _labelFor(VendorConnectionStatus status) {
    switch (status) {
      case VendorConnectionStatus.connected:
        return 'connected';
      case VendorConnectionStatus.disconnected:
        return 'disconnected';
      case VendorConnectionStatus.error:
        return 'error';
    }
  }

  String _tooltipFor(VendorConnectionStatus status, String? message) {
    switch (status) {
      case VendorConnectionStatus.connected:
        return 'Live data is flowing. Sync is healthy.';
      case VendorConnectionStatus.disconnected:
        return 'Sync is paused. Historical data stays. Click Reconnect to resume.';
      case VendorConnectionStatus.error:
        return message ??
            'Something is wrong. Most often the vendor revoked our access. '
                'Click Reconnect and sign back in.';
    }
  }

  Color _colorFor(BuildContext context, VendorConnectionStatus status) {
    switch (status) {
      case VendorConnectionStatus.connected:
        return AppColors.positive;
      case VendorConnectionStatus.disconnected:
        return AppColors.textMuted;
      case VendorConnectionStatus.error:
        return AppColors.negative;
    }
  }
}

class _ErrorRemediation extends StatelessWidget {
  const _ErrorRemediation({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.06),
        border: Border.all(color: AppColors.negative.withValues(alpha: 0.34)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: [
              const Icon(
                Icons.error_outline,
                size: 18,
                color: AppColors.negative,
              ),
              const SizedBox(width: 8),
              Text(
                'Vendor access needs attention',
                style: AppTextStyles.sectionTitle(color: AppColors.negative),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'The vendor may have revoked access or changed credentials. '
            'Historical data stays safe.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 6),
          Text(
            'Reconnect with the current vendor account to resume sync and fill '
            'any missing window.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(
            'Vendor message: $message',
            style: AppTextStyles.mono11(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.06),
        border: Border.all(color: AppColors.negative.withValues(alpha: 0.32)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: AppColors.negative),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _VendorPickerDialog extends StatefulWidget {
  const _VendorPickerDialog({required this.category, required this.entries});

  final VendorCategory category;
  final List<VendorPickerEntry> entries;

  @override
  State<_VendorPickerDialog> createState() => _VendorPickerDialogState();
}

class _VendorPickerDialogState extends State<_VendorPickerDialog> {
  String? _picked;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final dialogWidth = (viewport.width - 48).clamp(280.0, 860.0).toDouble();
    final dialogMaxHeight = (viewport.height * 0.76)
        .clamp(320.0, 720.0)
        .toDouble();
    final selected = _picked == null
        ? null
        : widget.entries.firstWhere((entry) => entry.vendorId == _picked);
    final canContinue =
        selected != null && _isConnectableLifecycle(selected.lifecycle);
    return AlertDialog(
      key: const Key('vendor_connections_picker_dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 18),
      title: _VendorPickerTitle(
        category: widget.category,
        title: _titleFor(widget.category),
        count: widget.entries.length,
      ),
      content: SizedBox(
        width: dialogWidth,
        height: dialogMaxHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _introFor(widget.category),
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 6),
            Text(
              'Vendors marked Coming soon are visible before production '
              'credentials are live.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: SingleChildScrollView(
                key: const Key('vendor_connections_picker_scroll_area'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _VendorPickerGrid(
                      entries: widget.entries,
                      pickedVendorId: _picked,
                      summaryFor: _vendorSummaryFor,
                      tagsFor: _tagsFor,
                      onPick: (entry) =>
                          setState(() => _picked = entry.vendorId),
                    ),
                    if (selected != null) ...<Widget>[
                      const SizedBox(height: 14),
                      _SelectedVendorPanel(
                        entry: selected,
                        canContinue: canContinue,
                        reason: canContinue
                            ? _connectableReasonFor(selected)
                            : _unavailableReasonFor(selected.lifecycle),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('vendor_connections_picker_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('vendor_connections_picker_continue'),
          onPressed: !canContinue
              ? null
              : () {
                  Navigator.of(context).pop(selected);
                },
          child: const Text('Continue'),
        ),
      ],
    );
  }

  bool _isConnectableLifecycle(VendorLifecycle lifecycle) {
    switch (lifecycle) {
      case VendorLifecycle.documented:
      case VendorLifecycle.sandboxVerified:
        return false;
      case VendorLifecycle.productionCredentialed:
      case VendorLifecycle.liveWithOperators:
        return true;
    }
  }

  String _unavailableReasonFor(VendorLifecycle lifecycle) {
    switch (lifecycle) {
      case VendorLifecycle.documented:
        return 'The adapter is implemented and documented, but production credentials are not live yet.';
      case VendorLifecycle.sandboxVerified:
        return 'Sandbox validation is complete, but production credentials are not live yet.';
      case VendorLifecycle.productionCredentialed:
      case VendorLifecycle.liveWithOperators:
        return 'This vendor can be connected now.';
    }
  }

  String _connectableReasonFor(VendorPickerEntry entry) {
    switch (entry.lifecycle) {
      case VendorLifecycle.productionCredentialed:
        return '${entry.displayName} has production credentials ready for this connection flow.';
      case VendorLifecycle.liveWithOperators:
        return '${entry.displayName} is live with at least one operator and can be connected here.';
      case VendorLifecycle.documented:
      case VendorLifecycle.sandboxVerified:
        return _unavailableReasonFor(entry.lifecycle);
    }
  }

  String _titleFor(VendorCategory category) {
    switch (category) {
      case VendorCategory.pos:
        return 'Choose the POS vendor';
      case VendorCategory.labor:
        return 'Choose the scheduling vendor';
      case VendorCategory.reservation:
        return 'Choose the reservations vendor';
    }
  }

  String _introFor(VendorCategory category) {
    switch (category) {
      case VendorCategory.pos:
        return 'Pick the system that owns sales, checks, and cover counts for this location.';
      case VendorCategory.labor:
        return 'Pick the system that owns schedules, punches, and role data for this location.';
      case VendorCategory.reservation:
        return 'Pick the system that owns bookings, party sizes, and reservation pacing for this location.';
    }
  }

  String _vendorSummaryFor(VendorPickerEntry entry) {
    switch (entry.category) {
      case VendorCategory.pos:
        return entry.coversFieldExposed
            ? 'Reads closed checks, sales, timing, and cover counts.'
            : 'Reads sales data. Cover counts may need a separate source.';
      case VendorCategory.labor:
        return 'Reads schedules, time punches, and team role data.';
      case VendorCategory.reservation:
        return 'Reads bookings, party sizes, and reservation timing.';
    }
  }

  List<String> _tagsFor(VendorPickerEntry entry) {
    final tags = <String>[];
    final lifecycleTag = _lifecycleTagFor(entry.lifecycle);
    if (lifecycleTag != null) tags.add(lifecycleTag);
    if (entry.requiresModule) tags.add('Pick a product');
    if (!entry.coversFieldExposed && entry.category == VendorCategory.pos) {
      tags.add('No cover count');
    }
    tags.add(_authModeLabel(entry.authMode));
    return tags;
  }

  String? _lifecycleTagFor(VendorLifecycle lifecycle) {
    switch (lifecycle) {
      case VendorLifecycle.documented:
        return 'Coming soon';
      case VendorLifecycle.sandboxVerified:
        return 'Sandbox verified';
      case VendorLifecycle.productionCredentialed:
      case VendorLifecycle.liveWithOperators:
        return null;
    }
  }

  String _authModeLabel(VendorAuthMode mode) {
    switch (mode) {
      case VendorAuthMode.oauth:
        return 'Secure sign-in';
      case VendorAuthMode.keyPaste:
        return 'API key';
      case VendorAuthMode.oauthOrKeyPaste:
        return 'Sign-in or API key';
    }
  }
}

class _VendorPickerTitle extends StatelessWidget {
  const _VendorPickerTitle({
    required this.category,
    required this.title,
    required this.count,
  });

  final VendorCategory category;
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        _CategoryIcon(category: category, size: 42),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title),
              const SizedBox(height: 3),
              Text(
                '$count available vendor options',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VendorPickerGrid extends StatelessWidget {
  const _VendorPickerGrid({
    required this.entries,
    required this.pickedVendorId,
    required this.summaryFor,
    required this.tagsFor,
    required this.onPick,
  });

  final List<VendorPickerEntry> entries;
  final String? pickedVendorId;
  final String Function(VendorPickerEntry entry) summaryFor;
  final List<String> Function(VendorPickerEntry entry) tagsFor;
  final ValueChanged<VendorPickerEntry> onPick;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 680 ? 2 : 1;
        const spacing = 10.0;
        final width =
            (constraints.maxWidth - (spacing * (columns - 1))) / columns;
        return Wrap(
          key: const Key('vendor_connections_picker_grid'),
          spacing: spacing,
          runSpacing: spacing,
          children: <Widget>[
            for (final entry in entries)
              SizedBox(
                width: width,
                child: _VendorPickerCard(
                  key: Key(
                    'vendor_connections_picker_choice_${entry.vendorId}',
                  ),
                  entry: entry,
                  subtitle: summaryFor(entry),
                  tags: tagsFor(entry),
                  selected: entry.vendorId == pickedVendorId,
                  onTap: () => onPick(entry),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _VendorPickerCard extends StatelessWidget {
  const _VendorPickerCard({
    super.key,
    required this.entry,
    required this.subtitle,
    required this.tags,
    required this.selected,
    required this.onTap,
  });

  final VendorPickerEntry entry;
  final String subtitle;
  final List<String> tags;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final borderColor = selected ? AppColors.sunset : AppColors.borderSubtle;
    return Material(
      color: selected
          ? AppColors.sunset.withValues(alpha: 0.08)
          : AppColors.backgroundSurface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: borderColor, width: selected ? 1.4 : 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _VendorLogo(
                    vendorId: entry.vendorId,
                    displayName: entry.displayName,
                    size: 54,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          entry.displayName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.sectionTitle(
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          _categoryLabel(entry.category),
                          style: AppTextStyles.chipLabel(
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: selected
                        ? AppColors.sunsetDark
                        : AppColors.textMuted,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                subtitle,
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              if (tags.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final tag in tags)
                      _StatusChip(label: tag, color: _tagColor(tag)),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _categoryLabel(VendorCategory category) {
    switch (category) {
      case VendorCategory.pos:
        return 'POS system';
      case VendorCategory.labor:
        return 'Scheduling and labor';
      case VendorCategory.reservation:
        return 'Reservations';
    }
  }

  Color _tagColor(String tag) {
    return tag == 'Coming soon' || tag == 'Sandbox verified'
        ? AppColors.textMuted
        : AppColors.peacockDark;
  }
}

class _SelectedVendorPanel extends StatelessWidget {
  const _SelectedVendorPanel({
    required this.entry,
    required this.canContinue,
    required this.reason,
  });

  final VendorPickerEntry entry;
  final bool canContinue;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final color = canContinue ? AppColors.positive : AppColors.warning;
    return Container(
      key: const Key('vendor_connections_picker_selected_panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        border: Border.all(color: color.withValues(alpha: 0.34)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _VendorLogo(
            vendorId: entry.vendorId,
            displayName: entry.displayName,
            size: 44,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  canContinue ? 'Ready to continue' : 'Not ready to connect',
                  style: AppTextStyles.sectionTitle(color: color),
                ),
                const SizedBox(height: 4),
                Text(
                  reason,
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ModuleDisambiguationDialog extends StatelessWidget {
  const _ModuleDisambiguationDialog({required this.entry});

  final VendorPickerEntry entry;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_module_dialog'),
      title: Text('Choose the ${entry.displayName} product'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'This vendor has more than one product. Pick the one that owns scheduling and labor data for this location.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            for (final module in entry.modules)
              Padding(
                key: Key('vendor_connections_module_${entry.vendorId}_$module'),
                padding: const EdgeInsets.only(bottom: 8),
                child: _DialogChoiceTile(
                  leading: Icon(
                    _moduleIcon(entry.vendorId, module),
                    color: _isSupportedModule(entry.vendorId, module)
                        ? AppColors.peacockDark
                        : AppColors.textMuted,
                  ),
                  title: _moduleLabel(entry.vendorId, module),
                  subtitle: _moduleHelp(entry.vendorId, module),
                  tags: _isSupportedModule(entry.vendorId, module)
                      ? const <String>['Supported']
                      : const <String>['Coming soon'],
                  onTap: () => Navigator.of(context).pop(
                    _isSupportedModule(entry.vendorId, module)
                        ? module
                        : 'unsupported',
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('vendor_connections_module_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  bool _isSupportedModule(String vendorId, String module) {
    if (vendorId == 'quickbooks_time') return module == 'time';
    if (vendorId == 'adp') return module != 'run';
    return true;
  }

  IconData _moduleIcon(String vendorId, String module) {
    if (vendorId == 'quickbooks_time') {
      switch (module) {
        case 'time':
          return Icons.schedule_outlined;
        case 'accounting':
          return Icons.receipt_long_outlined;
        case 'payroll':
          return Icons.payments_outlined;
      }
    }
    return Icons.account_tree_outlined;
  }

  String _moduleLabel(String vendorId, String module) {
    if (vendorId == 'quickbooks_time') {
      switch (module) {
        case 'time':
          return 'QuickBooks Time';
        case 'accounting':
          return 'QuickBooks Accounting (use the Connected services tab instead)';
        case 'payroll':
          return 'QuickBooks Payroll - not supported';
      }
    }
    if (vendorId == 'adp') {
      switch (module) {
        case 'workforce_now':
          return 'ADP Workforce Now';
        case 'workforce_manager':
          return 'ADP Workforce Manager';
        case 'run':
          return 'ADP RUN - not supported';
      }
    }
    return module;
  }

  String _moduleHelp(String vendorId, String module) {
    if (vendorId == 'quickbooks_time') {
      switch (module) {
        case 'time':
          return 'Use this for timesheets, punches, and labor timing.';
        case 'accounting':
          return 'Accounting data belongs in the internal connected services area.';
        case 'payroll':
          return 'Payroll setup is not part of the current vendor integration flow.';
      }
    }
    if (vendorId == 'adp') {
      switch (module) {
        case 'workforce_now':
          return 'Use this for ADP scheduling and workforce data.';
        case 'workforce_manager':
          return 'Use this for ADP manager scheduling and time data.';
        case 'run':
          return 'ADP RUN is not supported in this flow yet.';
      }
    }
    return 'Use this product for the selected vendor connection.';
  }
}

class _UnsupportedModuleDialog extends StatelessWidget {
  const _UnsupportedModuleDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_unsupported_module_dialog'),
      title: const Text('That module is not supported'),
      content: _DialogNotice(
        icon: Icons.info_outline,
        title: 'Choose a supported product for now',
        body:
            'Forge & Flow cannot connect that module yet. Pick a supported scheduling product, or contact support if this operator needs a custom mapping.',
        color: AppColors.warning,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

class _TestConnectionLoadingDialog extends StatelessWidget {
  const _TestConnectionLoadingDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_test_loading_dialog'),
      title: const Text('Testing connection'),
      content: SizedBox(
        width: 320,
        child: Row(
          children: [
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'Checking credentials and pulling a small sample.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TestConnectionResultDialog extends StatelessWidget {
  const _TestConnectionResultDialog({required this.row, required this.result});

  final VendorConnectionRow row;
  final VendorTestConnectionResult result;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_test_result_dialog'),
      title: Text('Connection test: ${row.displayName}'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _DialogStatusRow(
              icon: result.authValid
                  ? Icons.check_circle_outline
                  : Icons.error_outline,
              color: result.authValid ? AppColors.positive : AppColors.negative,
              title: result.authValid
                  ? 'Credentials are working'
                  : 'Credentials need reconnecting',
              body: result.authValid
                  ? 'Forge & Flow can still read from this vendor.'
                  : 'Reconnect this vendor before relying on fresh data.',
            ),
            const SizedBox(height: 10),
            _DialogStatusRow(
              icon: Icons.download_done_outlined,
              color: AppColors.peacockDark,
              title: 'Sample read completed',
              body:
                  'The vendor returned a sample in ${result.elapsedMs}ms so mapping can be checked.',
            ),
            const SizedBox(height: 14),
            Text(
              'Sample from vendor',
              style: AppTextStyles.sectionTitle(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 6),
            _DialogSurface(child: Text(result.sampleSummary)),
            const SizedBox(height: 12),
            Text(
              'Field mapping',
              style: AppTextStyles.sectionTitle(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 6),
            for (final entry in result.fieldMapping.entries)
              _MappingRow(source: entry.key, target: entry.value),
            if (result.note != null) ...<Widget>[
              const SizedBox(height: 8),
              _DialogNotice(
                icon: Icons.info_outline,
                title: 'Note',
                body: result.note!,
                color: AppColors.peacockDark,
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('vendor_connections_test_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _DisconnectConfirmDialog extends StatelessWidget {
  const _DisconnectConfirmDialog({required this.row});

  final VendorConnectionRow row;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_disconnect_dialog'),
      title: Text('Disconnect ${row.displayName}?'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'This only stops the live integration for this location. It does not delete historical Forge & Flow data.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            const _DialogBullet(
              icon: Icons.history_outlined,
              title: 'Historical data stays',
              body: 'Reports keep the data that was already imported.',
            ),
            const _DialogBullet(
              icon: Icons.sync_disabled_outlined,
              title: 'New vendor events stop',
              body: 'Fresh sales, booking, or labor records will stop syncing.',
            ),
            const _DialogBullet(
              icon: Icons.key_off_outlined,
              title: 'Stored credentials are removed',
              body:
                  'Forge & Flow forgets the connection token for this vendor.',
            ),
            const _DialogBullet(
              icon: Icons.restart_alt_outlined,
              title: 'Reconnect later if needed',
              body:
                  'A future reconnect resumes from the latest safe checkpoint.',
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('vendor_connections_disconnect_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const Key('vendor_connections_disconnect_confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          icon: const Icon(Icons.link_off, size: 16),
          label: const Text('Disconnect vendor'),
        ),
      ],
    );
  }
}

class _SyncLogsDialog extends StatelessWidget {
  const _SyncLogsDialog({required this.row, required this.entries});

  final VendorConnectionRow row;
  final List<VendorSyncLogEntry> entries;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('vendor_connections_logs_dialog'),
      title: Text('Activity for ${row.displayName}'),
      content: SizedBox(
        width: 520,
        height: 380,
        child: entries.isEmpty
            ? const _DialogNotice(
                icon: Icons.info_outline,
                title: 'No activity yet',
                body: 'This connection has not recorded a sync event yet.',
                color: AppColors.peacockDark,
              )
            : ListView.separated(
                itemCount: entries.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final color = _eventColor(entry.eventKind);
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundSurface,
                      border: Border.all(color: AppColors.borderSubtle),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(_eventIcon(entry.eventKind), color: color),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _eventLabel(entry.eventKind),
                                style: AppTextStyles.sectionTitle(
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                adminHumanDateTime(entry.occurredAt),
                                style: AppTextStyles.body12(
                                  color: AppColors.textSecondary,
                                  style: FontStyle.normal,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _logBody(entry),
                                style: AppTextStyles.body13(
                                  color: AppColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('vendor_connections_logs_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  String _logBody(VendorSyncLogEntry entry) {
    if (entry.errorMessage != null) return entry.errorMessage!;
    if (entry.recordsCount != null) {
      return '${entry.recordsCount} vendor records were processed.';
    }
    return 'The vendor connection recorded this activity.';
  }

  String _eventLabel(String eventKind) {
    switch (eventKind) {
      case 'poll_success':
        return 'Sync completed';
      case 'poll_error':
        return 'Sync failed';
      case 'rate_limit_retry':
        return 'Vendor asked us to slow down';
      case 'sanity_drop':
        return 'Record skipped for safety';
      default:
        return eventKind
            .split('_')
            .where((part) => part.isNotEmpty)
            .map(
              (part) =>
                  '${part.substring(0, 1).toUpperCase()}${part.substring(1)}',
            )
            .join(' ');
    }
  }

  IconData _eventIcon(String eventKind) {
    switch (eventKind) {
      case 'poll_success':
        return Icons.check_circle_outline;
      case 'poll_error':
        return Icons.error_outline;
      case 'rate_limit_retry':
        return Icons.hourglass_bottom_outlined;
      case 'sanity_drop':
        return Icons.rule_outlined;
      default:
        return Icons.info_outline;
    }
  }

  Color _eventColor(String eventKind) {
    switch (eventKind) {
      case 'poll_success':
        return AppColors.positive;
      case 'poll_error':
        return AppColors.negative;
      case 'rate_limit_retry':
        return AppColors.warning;
      case 'sanity_drop':
        return AppColors.peacockDark;
      default:
        return AppColors.textMuted;
    }
  }
}

class _DialogChoiceTile extends StatelessWidget {
  const _DialogChoiceTile({
    this.leading,
    required this.title,
    required this.subtitle,
    this.tags = const <String>[],
    required this.onTap,
  });

  final Widget? leading;
  final String title;
  final String subtitle;
  final List<String> tags;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.backgroundSurface,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: AppColors.borderSubtle),
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (leading != null) ...[
                SizedBox(width: 48, height: 48, child: Center(child: leading)),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTextStyles.sectionTitle(
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final tag in tags)
                            _StatusChip(
                              label: tag,
                              color:
                                  tag == 'Coming soon' ||
                                      tag == 'Sandbox verified'
                                  ? AppColors.textMuted
                                  : AppColors.peacockDark,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.radio_button_off, color: AppColors.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _DialogSurface extends StatelessWidget {
  const _DialogSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep.withValues(alpha: 0.55),
        border: Border.all(color: AppColors.borderSubtle),
        borderRadius: BorderRadius.circular(6),
      ),
      child: DefaultTextStyle.merge(
        style: AppTextStyles.body13(color: AppColors.textSecondary),
        child: child,
      ),
    );
  }
}

class _DialogStatusRow extends StatelessWidget {
  const _DialogStatusRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTextStyles.sectionTitle(color: color)),
              const SizedBox(height: 2),
              Text(
                body,
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MappingRow extends StatelessWidget {
  const _MappingRow({required this.source, required this.target});

  final String source;
  final String target;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: _DialogSurface(
        child: Row(
          children: [
            Expanded(child: Text(source)),
            const Icon(Icons.arrow_forward, size: 14),
            const SizedBox(width: 8),
            Expanded(child: Text(target)),
          ],
        ),
      ),
    );
  }
}

class _DialogNotice extends StatelessWidget {
  const _DialogNotice({
    required this.icon,
    required this.title,
    required this.body,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String body;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.28)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTextStyles.sectionTitle(color: color)),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DialogBullet extends StatelessWidget {
  const _DialogBullet({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppColors.peacockDark, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppTextStyles.sectionTitle(
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
