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

  void _toggleSort(_SortColumn column) {
    setState(() {
      if (_sortColumn == column) {
        _ascending = !_ascending;
      } else {
        _sortColumn = column;
        _ascending = true;
      }
    });
  }

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
              'Covers are shown as lunch / dinner / late night. '
              'Scroll sideways for override history and actions.',
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                sortColumnIndex: _sortColumn.index,
                sortAscending: _ascending,
                columns: <DataColumn>[
                  DataColumn(
                    label: const Text('Operator'),
                    onSort: (_, __) => _toggleSort(_SortColumn.operator),
                  ),
                  DataColumn(
                    label: const Text('Location'),
                    onSort: (_, __) => _toggleSort(_SortColumn.location),
                  ),
                  DataColumn(
                    label: const Text('Covers source'),
                    onSort: (_, __) => _toggleSort(_SortColumn.covers),
                  ),
                  DataColumn(
                    label: const Text('Wage source'),
                    onSort: (_, __) => _toggleSort(_SortColumn.wage),
                  ),
                  DataColumn(
                    label: const Text('Last modified by'),
                    onSort: (_, __) => _toggleSort(_SortColumn.modifiedBy),
                  ),
                  DataColumn(
                    label: const Text('Last modified at'),
                    onSort: (_, __) => _toggleSort(_SortColumn.modifiedAt),
                  ),
                  const DataColumn(label: Text('Actions')),
                ],
                rows: <DataRow>[
                  for (final row in sorted)
                    DataRow(
                      cells: <DataCell>[
                        DataCell(
                          Text(
                            key: Key(
                              'admin_data_accuracy_row_'
                              '${row.operatorRef.operatorId}_'
                              '${row.operatorRef.locationId}',
                            ),
                            row.operatorRef.businessName,
                            style: AppTextStyles.body13(
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        DataCell(
                          Text(
                            row.operatorRef.locationName,
                            style: AppTextStyles.body13(
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        DataCell(
                          Text(
                            _coversSummary(row),
                            style: AppTextStyles.body13(
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        DataCell(
                          Text(
                            _wageLabel(row.settings.wageSource),
                            style: AppTextStyles.body13(
                              color: AppColors.textPrimary,
                            ),
                          ),
                        ),
                        DataCell(
                          Text(
                            row.settings.updatedBy ?? '-',
                            style: AppTextStyles.body13(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ),
                        DataCell(
                          Text(
                            _modifiedAtLabel(row),
                            style: row.settings.updatedBy == null
                                ? AppTextStyles.body13(
                                    color: AppColors.textSecondary,
                                  )
                                : AppTextStyles.mono11(
                                    color: AppColors.textMuted,
                                  ),
                          ),
                        ),
                        DataCell(
                          widget.editingEnabled
                              ? OutlinedButton(
                                  key: Key(
                                    'admin_data_accuracy_edit_'
                                    '${row.operatorRef.operatorId}_'
                                    '${row.operatorRef.locationId}',
                                  ),
                                  style: AdminButtonStyles.secondary(
                                    minWidth: 72,
                                    minHeight: 32,
                                  ),
                                  onPressed: () => widget.onEditRow(row),
                                  child: const Text('Edit'),
                                )
                              : Text(
                                  'Read-only',
                                  style: AppTextStyles.body12(
                                    color: AppColors.textMuted,
                                  ),
                                ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
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
}
