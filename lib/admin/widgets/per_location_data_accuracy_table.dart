import 'package:flutter/material.dart';

import '../../domain/models/data_accuracy_settings.dart';
import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../admin_human_labels.dart';
import '../services/data_accuracy_admin_gateway.dart';
import 'admin_responsive_layout.dart';

enum _SortColumn { operator, location, covers, wage, modifiedBy, modifiedAt }

class PerLocationDataAccuracyTable extends StatefulWidget {
  const PerLocationDataAccuracyTable({
    super.key,
    required this.rows,
    required this.editingEnabled,
    required this.onEditRow,
  });

  final List<DataAccuracyAdminRow> rows;
  final bool editingEnabled;
  final void Function(DataAccuracyAdminRow row) onEditRow;

  @override
  State<PerLocationDataAccuracyTable> createState() =>
      _PerLocationDataAccuracyTableState();
}

class _PerLocationDataAccuracyTableState
    extends State<PerLocationDataAccuracyTable> {
  _SortColumn _sortColumn = _SortColumn.operator;
  bool _ascending = true;

  int _compare(DataAccuracyAdminRow a, DataAccuracyAdminRow b) {
    int cmp;
    switch (_sortColumn) {
      case _SortColumn.operator:
        cmp = a.operatorRef.businessName.compareTo(b.operatorRef.businessName);
        break;
      case _SortColumn.location:
        cmp = a.operatorRef.locationName.compareTo(b.operatorRef.locationName);
        break;
      case _SortColumn.covers:
        cmp = _coversSummary(a).compareTo(_coversSummary(b));
        break;
      case _SortColumn.wage:
        cmp = a.settings.wageSource.wire.compareTo(b.settings.wageSource.wire);
        break;
      case _SortColumn.modifiedBy:
        cmp = (a.settings.updatedBy ?? '').compareTo(
          b.settings.updatedBy ?? '',
        );
        break;
      case _SortColumn.modifiedAt:
        cmp = a.settings.updatedAt.compareTo(b.settings.updatedAt);
        break;
    }
    return _ascending ? cmp : -cmp;
  }

  static String _coversSummary(DataAccuracyAdminRow row) {
    final s = row.settings;
    return '${_coversLabel(s.coversSourceLunch)} / '
        '${_coversLabel(s.coversSourceDinner)} / '
        '${_coversLabel(s.coversSourceLateNight)}';
  }

  @override
  Widget build(BuildContext context) {
    final sorted = <DataAccuracyAdminRow>[...widget.rows]..sort(_compare);

    return Container(
      key: const Key('admin_data_accuracy_table'),
      child: AdminCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Per-location data accuracy',
              style: AppTextStyles.sectionTitle(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 6),
            Text(
              'Covers are shown as lunch, dinner, and late night so support can scan each location without moving sideways.',
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            _TableToolbar(
              count: sorted.length,
              sortColumn: _sortColumn,
              ascending: _ascending,
              onSortChanged: (column) => setState(() {
                _sortColumn = column;
                _ascending = true;
              }),
              onDirectionPressed: () =>
                  setState(() => _ascending = !_ascending),
            ),
            const SizedBox(height: 10),
            if (sorted.isEmpty)
              Text(
                'No locations match this view.',
                style: AppTextStyles.body13(color: AppColors.textMuted),
              )
            else
              Column(
                children: [
                  for (var i = 0; i < sorted.length; i++) ...[
                    _buildSummaryRow(sorted[i]),
                    if (i != sorted.length - 1)
                      const Divider(color: AppColors.borderSubtle, height: 14),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryRow(DataAccuracyAdminRow row) {
    final updatedBy = _updatedByLabel(row.settings.updatedBy);
    final updatedAt = _modifiedAtLabel(row);
    final covers = <_MiniFact>[
      _MiniFact('Lunch', _coversLabel(row.settings.coversSourceLunch)),
      _MiniFact('Dinner', _coversLabel(row.settings.coversSourceDinner)),
      _MiniFact('Late night', _coversLabel(row.settings.coversSourceLateNight)),
    ];
    final metadata = <_MiniFact>[
      _MiniFact('Wage source', _wageLabel(row.settings.wageSource)),
      _MiniFact('Last override', updatedAt),
      _MiniFact('Changed by', updatedBy),
    ];

    final action = widget.editingEnabled
        ? OutlinedButton.icon(
            key: Key(
              'admin_data_accuracy_edit_'
              '${row.operatorRef.operatorId}_${row.operatorRef.locationId}',
            ),
            style: AdminButtonStyles.secondary(minWidth: 88, minHeight: 36),
            onPressed: () => widget.onEditRow(row),
            icon: const Icon(Icons.edit_outlined, size: 14),
            label: const Text('Edit'),
          )
        : Text(
            'Read-only',
            style: AppTextStyles.body12(color: AppColors.textMuted),
          );

    return Container(
      key: Key(
        'admin_data_accuracy_row_'
        '${row.operatorRef.operatorId}_${row.operatorRef.locationId}',
      ),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 820;
          final heading = _OperatorLocationBlock(row: row);
          final facts = _FactWrap(facts: covers);
          final details = _FactWrap(facts: metadata);
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading,
                const SizedBox(height: 10),
                facts,
                const SizedBox(height: 8),
                details,
                const SizedBox(height: 10),
                action,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: heading),
              const SizedBox(width: 16),
              Expanded(flex: 4, child: facts),
              const SizedBox(width: 16),
              Expanded(flex: 4, child: details),
              const SizedBox(width: 16),
              action,
            ],
          );
        },
      ),
    );
  }

  static String _wageLabel(WageSource source) {
    switch (source) {
      case WageSource.vendor:
        return 'Vendor';
      case WageSource.manualMix:
        return 'Manual mix';
    }
  }

  static String _coversLabel(CoversSource source) {
    switch (source) {
      case CoversSource.vendor:
        return 'Vendor';
      case CoversSource.forecast:
        return 'Forecast';
      case CoversSource.manual:
        return 'Manual';
    }
  }

  static String _modifiedAtLabel(DataAccuracyAdminRow row) {
    if (row.settings.updatedBy == null) return 'No override yet';
    return adminHumanDateTime(row.settings.updatedAt);
  }

  static String _updatedByLabel(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) return 'Not changed yet';
    if (trimmed.toLowerCase() == 'system') return 'System';
    if (trimmed.contains('@')) return trimmed;
    return 'Forge & Flow admin';
  }
}

class _TableToolbar extends StatelessWidget {
  const _TableToolbar({
    required this.count,
    required this.sortColumn,
    required this.ascending,
    required this.onSortChanged,
    required this.onDirectionPressed,
  });

  final int count;
  final _SortColumn sortColumn;
  final bool ascending;
  final ValueChanged<_SortColumn> onSortChanged;
  final VoidCallback onDirectionPressed;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '$count ${count == 1 ? 'location' : 'locations'}',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
        SizedBox(
          width: 220,
          child: DropdownButtonFormField<_SortColumn>(
            key: const Key('admin_data_accuracy_sort_dropdown'),
            initialValue: sortColumn,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Sort by',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: <DropdownMenuItem<_SortColumn>>[
              for (final column in _SortColumn.values)
                DropdownMenuItem<_SortColumn>(
                  value: column,
                  child: Text(_sortColumnLabel(column)),
                ),
            ],
            onChanged: (value) {
              if (value != null) onSortChanged(value);
            },
          ),
        ),
        Tooltip(
          message: ascending ? 'Sort descending' : 'Sort ascending',
          child: IconButton.outlined(
            key: const Key('admin_data_accuracy_sort_direction'),
            onPressed: onDirectionPressed,
            icon: Icon(
              ascending
                  ? Icons.arrow_upward_outlined
                  : Icons.arrow_downward_outlined,
              size: 18,
            ),
          ),
        ),
      ],
    );
  }

  static String _sortColumnLabel(_SortColumn column) {
    switch (column) {
      case _SortColumn.operator:
        return 'Operator';
      case _SortColumn.location:
        return 'Location';
      case _SortColumn.covers:
        return 'Covers source';
      case _SortColumn.wage:
        return 'Wage source';
      case _SortColumn.modifiedBy:
        return 'Changed by';
      case _SortColumn.modifiedAt:
        return 'Last override';
    }
  }
}

class _OperatorLocationBlock extends StatelessWidget {
  const _OperatorLocationBlock({required this.row});

  final DataAccuracyAdminRow row;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          row.operatorRef.businessName,
          style: AppTextStyles.body14(color: AppColors.textPrimary),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          row.operatorRef.locationName,
          style: AppTextStyles.body13(color: AppColors.textSecondary),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _MiniFact {
  const _MiniFact(this.label, this.value);

  final String label;
  final String value;
}

class _FactWrap extends StatelessWidget {
  const _FactWrap({required this.facts});

  final List<_MiniFact> facts;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final fact in facts)
          _FactPill(label: fact.label, value: fact.value),
      ],
    );
  }
}

class _FactPill extends StatelessWidget {
  const _FactPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 116, maxWidth: 190),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid.withValues(alpha: 0.8),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: AppTextStyles.uiLabel(color: AppColors.textMuted),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: AppTextStyles.body13(color: AppColors.textPrimary),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
