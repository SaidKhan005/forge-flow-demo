// Phase 8.0 / Wave C1 — Header + per-category section (empty state +
// connected card) for the shared Vendor Connections widget tree.
//
// Extracted from `vendor_connections_widget.dart` (Wave C1 code-health
// pass). Behavior is byte-stable. The section root keeps the pinned
// widget keys (`vendor_connections_section_pos|reservation|labor`)
// attached at the same logical layer the parent originally exposed.

part of '../vendor_connections_widget.dart';

class _Header extends StatelessWidget {
  const _Header({required this.locationName, this.leading});

  final String locationName;
  final Widget? leading;

  String get _locationPhrase {
    final trimmed = locationName.trim();
    if (trimmed.isEmpty) return 'this location';
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('location ') && trimmed.contains('-')) {
      return 'this location';
    }
    return trimmed;
  }

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
          if (leading == null)
            Text(
              'Vendor integrations',
              style: AppTextStyles.pageTitle(color: AppColors.textPrimary),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                leading!,
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Vendor integrations',
                    style: AppTextStyles.pageTitle(
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 6),
          Text(
            'Manage the services connected to $_locationPhrase. Forge & Flow reads data for reporting and forecasting; it does not push changes back to vendor systems.',
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
                  label: Text(_categoryActionLabel(category)),
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

  String _categoryActionLabel(VendorCategory category) {
    switch (category) {
      case VendorCategory.pos:
        return 'Choose POS';
      case VendorCategory.labor:
        return 'Choose scheduling';
      case VendorCategory.reservation:
        return 'Choose reservations';
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
              if (row.firstBackfill != null) ...<Widget>[
                const SizedBox(height: 8),
                _FirstBackfillProgress(
                  vendorId: row.vendorId,
                  state: row.firstBackfill!,
                ),
              ],
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
