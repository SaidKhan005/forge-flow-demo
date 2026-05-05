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
                separatorBuilder: (_, __) =>
                    const Divider(color: AppColors.borderSubtle, height: 16),
                itemBuilder: (context, index) =>
                    _AuditRow(event: sorted[index]),
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
    final actorId = event.actorUserId.trim();
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
                  _eventLabel(event.eventType),
                  style: AppTextStyles.body13(color: AppColors.textPrimary),
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
            'Actor: ${_actorLabel(event)}',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 2),
          Text(
            'Event key: ${event.eventType}',
            style: AppTextStyles.mono11(color: AppColors.textMuted),
          ),
          if (actorId.isNotEmpty && actorId.toLowerCase() != 'system') ...[
            const SizedBox(height: 2),
            Text(
              'User ID: $actorId',
              style: AppTextStyles.mono11(color: AppColors.textMuted),
            ),
          ],
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
  // "prior price -> new price" per contract Card 5.
  static const Set<String> _centFields = <String>{
    'monthly_price_cents',
    'vendor_api_cost_estimate_cents_monthly',
    'default_monthly_price_cents',
  };

  Widget _renderDiffEntry(MapEntry<String, Object?> entry) {
    final value = entry.value;
    final isCents = _centFields.contains(entry.key);
    final rendered = switch (value) {
      Map() =>
        '${_fieldLabel(entry.key)}: '
            '${_fmt(entry.key, value['from'], isCents: isCents)} -> '
            '${_fmt(entry.key, value['to'], isCents: isCents)}',
      _ =>
        '${_fieldLabel(entry.key)}: '
            '${_fmt(entry.key, value, isCents: isCents)}',
    };
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        rendered,
        style: AppTextStyles.body12(color: AppColors.textSecondary),
      ),
    );
  }

  static String _fmt(String key, Object? raw, {bool isCents = false}) {
    if (raw == null) return 'null';
    if (isCents) {
      final cents = raw is int
          ? raw
          : (raw is num ? raw.toInt() : int.tryParse(raw.toString()));
      if (cents != null) return formatCents(cents);
    }
    if (raw is String) return _valueLabel(key, raw);
    return raw.toString();
  }

  static String _eventLabel(String eventType) {
    switch (eventType) {
      case 'admin.data_accuracy.list':
        return 'Viewed data accuracy rows';
      case 'admin.data_accuracy.audit_history.list':
        return 'Viewed data accuracy audit history';
      case 'admin.data_accuracy.override':
        return 'Applied data accuracy override';
      case 'admin.polling_pricing.tier_definitions.list':
        return 'Viewed tier definitions';
      case 'admin.polling_pricing.assignments.list':
        return 'Viewed tier assignments';
      case 'admin.polling_pricing.assign_tier':
      case 'admin.polling_tier_assignment.assign':
        return 'Assigned polling tier';
      case 'admin.polling_pricing.margin.summarize':
        return 'Viewed margin rollup';
      case 'admin.polling_pricing.margin.export_csv':
      case 'admin.margin_rollup.export_csv':
        return 'Exported margin CSV';
      case 'admin.polling_pricing.change_requests.list':
        return 'Viewed tier change requests';
      case 'admin.polling_tier_change_request.resolve':
        return 'Resolved tier change request';
      case 'admin.polling_tier_definition.update':
        return 'Updated tier definition';
      default:
        return _titleCaseId(eventType);
    }
  }

  static String _actorLabel(DataAccuracyAdminAuditEvent event) {
    final actorId = event.actorUserId.trim();
    if (actorId.toLowerCase() == 'system') return 'System';
    switch (event.actorKind.trim().toLowerCase()) {
      case 'forge_admin':
        return 'Forge & Flow admin';
      case 'ff_support':
        return 'Support user';
      case 'system':
        return 'System';
      default:
        return actorId.contains('@') ? actorId : 'Admin user';
    }
  }

  static String _fieldLabel(String key) {
    switch (key) {
      case 'covers_source_lunch':
        return 'Covers source - lunch';
      case 'covers_source_dinner':
        return 'Covers source - dinner';
      case 'covers_source_late_night':
        return 'Covers source - late night';
      case 'wage_source':
        return 'Wage source';
      case 'tier_key':
        return 'Tier';
      case 'monthly_price_cents':
      case 'default_monthly_price_cents':
        return 'Monthly price';
      case 'vendor_api_cost_estimate_cents_monthly':
        return 'Vendor API cost basis';
      case 'polling_cadence_per_vendor_seconds':
        return 'Vendor polling cadence';
      case 'admin_notes':
        return 'Admin notes';
      default:
        return _titleCaseId(key);
    }
  }

  static String _valueLabel(String key, String value) {
    final normalized = value.trim().toLowerCase();
    if (key.startsWith('covers_source')) {
      switch (normalized) {
        case 'vendor':
          return 'Vendor feed';
        case 'forecast':
          return 'Forecast';
        case 'manual':
          return 'Manual entry';
      }
    }
    if (key == 'wage_source') {
      switch (normalized) {
        case 'vendor':
          return 'Vendor wage data';
        case 'manual_mix':
          return 'Manual mix';
      }
    }
    if (key == 'tier_key') return _titleCaseId(value);
    if (value.trim().isEmpty) return 'blank';
    return value;
  }

  static String _titleCaseId(String value) {
    final words = value
        .trim()
        .replaceAll(RegExp(r'[^A-Za-z0-9]+'), ' ')
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty);
    if (words.isEmpty) return 'Unknown action';
    return words
        .map((word) {
          if (word.length == 1) return word.toUpperCase();
          return word.substring(0, 1).toUpperCase() +
              word.substring(1).toLowerCase();
        })
        .join(' ');
  }
}
