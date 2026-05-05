import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../admin_human_labels.dart';
import '../services/data_accuracy_admin_gateway.dart';
import 'admin_responsive_layout.dart';

class DataAccuracyAuditHistoryPanel extends StatelessWidget {
  const DataAccuracyAuditHistoryPanel({
    super.key,
    required this.events,
    this.title = 'Audit history',
    this.emptyText = 'No admin overrides recorded yet.',
  });

  final List<DataAccuracyAdminAuditEvent> events;
  final String title;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final sorted = <DataAccuracyAdminAuditEvent>[...events]
      ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt));

    return Container(
      key: const Key('admin_data_accuracy_audit_panel'),
      child: AdminCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: AppTextStyles.sectionTitle(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 12),
            if (sorted.isEmpty)
              Text(
                emptyText,
                style: AppTextStyles.body13(color: AppColors.textMuted),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: sorted.length,
                separatorBuilder: (_, __) => const Divider(
                  color: AppColors.borderSubtle,
                  height: 16,
                ),
                itemBuilder: (context, index) => _AuditRow(event: sorted[index]),
              ),
          ],
        ),
      ),
    );
  }
}

class _AuditRow extends StatelessWidget {
  const _AuditRow({required this.event});

  final DataAccuracyAdminAuditEvent event;

  @override
  Widget build(BuildContext context) {
    final diffEntries = event.diff.entries.toList();
    return Container(
      key: Key('admin_data_accuracy_audit_row_${event.eventId}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  event.eventType,
                  style: AppTextStyles.mono14(color: AppColors.textPrimary),
                ),
              ),
              Text(
                adminHumanDateTime(event.occurredAt),
                style: AppTextStyles.mono11(color: AppColors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Actor: ${event.actorUserId}',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          if (event.reasonNote != null && event.reasonNote!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Reason: ${event.reasonNote}',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ],
          if (diffEntries.isNotEmpty) ...[
            const SizedBox(height: 6),
            ...diffEntries.map(_renderDiffEntry),
          ],
        ],
      ),
    );
  }

  // Diff keys whose Object? values are cents and should render as
  // dollar amounts ($X.XX). Adding a new monetary field to the audit
  // payload requires adding it here so the diff display reads as
  // "prior price → new price" per contract Card 5.
  static const Set<String> _centFields = <String>{
    'monthly_price_cents',
    'vendor_api_cost_estimate_cents_monthly',
    'default_monthly_price_cents',
  };

  Widget _renderDiffEntry(MapEntry<String, Object?> entry) {
    final value = entry.value;
    final isCents = _centFields.contains(entry.key);
    String rendered;
    if (value is Map) {
      final from = value['from'];
      final to = value['to'];
      rendered =
          '${entry.key}: ${_fmt(from, isCents: isCents)} → ${_fmt(to, isCents: isCents)}';
    } else {
      rendered = '${entry.key}: ${_fmt(value, isCents: isCents)}';
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        rendered,
        style: AppTextStyles.mono12(color: AppColors.textSecondary),
      ),
    );
  }

  String _fmt(Object? raw, {bool isCents = false}) {
    if (raw == null) return 'null';
    if (isCents) {
      final cents = raw is int
          ? raw
          : (raw is num ? raw.toInt() : int.tryParse(raw.toString()));
      if (cents != null) return formatCents(cents);
    }
    if (raw is String) return raw;
    return raw.toString();
  }
}
