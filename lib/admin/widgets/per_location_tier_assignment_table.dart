import 'package:flutter/material.dart';

import '../../domain/models/forge_flow_polling_tier_assignment.dart';
import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../admin_human_labels.dart';
import '../services/data_accuracy_admin_gateway.dart';
import 'admin_responsive_layout.dart';

enum _SortColumn {
  operator,
  location,
  tier,
  activeSince,
  priceOverride,
  costOverride,
  netMargin,
}

/// Filter options for the contract's "by location count" filter on
/// the tier-assignment table. Maps to:
///   * `single`   → operators with exactly one location in the
///                  visible row set;
///   * `multi`    → operators with two or more locations;
///   * null       → no filter (default).
typedef LocationCountFilter = String;

class PerLocationTierAssignmentTable extends StatefulWidget {
  const PerLocationTierAssignmentTable({
    super.key,
    required this.rows,
    required this.tierDefinitions,
    required this.editingEnabled,
    required this.onAssign,
    this.tierFilter,
    this.marginBandFilter,
    this.locationCountFilter,
    this.operatorNameFilter,
    this.onTierFilterChanged,
    this.onMarginBandFilterChanged,
    this.onLocationCountFilterChanged,
    this.onOperatorNameFilterChanged,
  });

  final List<TierAssignmentAdminRow> rows;
  final List<TierDefinition> tierDefinitions;
  final bool editingEnabled;
  final void Function(TierAssignmentAdminRow row) onAssign;
  final PollingTierKey? tierFilter;
  final String? marginBandFilter;
  final LocationCountFilter? locationCountFilter;
  final String? operatorNameFilter;
  final ValueChanged<PollingTierKey?>? onTierFilterChanged;
  final ValueChanged<String?>? onMarginBandFilterChanged;
  final ValueChanged<LocationCountFilter?>? onLocationCountFilterChanged;
  final ValueChanged<String>? onOperatorNameFilterChanged;

  @override
  State<PerLocationTierAssignmentTable> createState() =>
      _PerLocationTierAssignmentTableState();
}

class _PerLocationTierAssignmentTableState
    extends State<PerLocationTierAssignmentTable> {
  _SortColumn _sortColumn = _SortColumn.operator;
  bool _ascending = true;
  late final TextEditingController _opNameController;

  @override
  void initState() {
    super.initState();
    _opNameController =
        TextEditingController(text: widget.operatorNameFilter ?? '');
  }

  @override
  void didUpdateWidget(covariant PerLocationTierAssignmentTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.operatorNameFilter ?? '';
    if (_opNameController.text != next &&
        widget.operatorNameFilter != oldWidget.operatorNameFilter) {
      _opNameController.text = next;
    }
  }

  @override
  void dispose() {
    _opNameController.dispose();
    super.dispose();
  }

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

  int _compare(TierAssignmentAdminRow a, TierAssignmentAdminRow b) {
    int cmp;
    switch (_sortColumn) {
      case _SortColumn.operator:
        cmp = a.operatorRef.businessName.compareTo(b.operatorRef.businessName);
        break;
      case _SortColumn.location:
        cmp = a.operatorRef.locationName.compareTo(b.operatorRef.locationName);
        break;
      case _SortColumn.tier:
        // Unassigned rows sort last in ascending order, first in
        // descending — null is "no tier" and is the empty value.
        final aTier = a.assignment?.tierKey.wire ?? '~unassigned';
        final bTier = b.assignment?.tierKey.wire ?? '~unassigned';
        cmp = aTier.compareTo(bTier);
        break;
      case _SortColumn.activeSince:
        final aAt = a.assignment?.effectiveAt;
        final bAt = b.assignment?.effectiveAt;
        if (aAt == null && bAt == null) {
          cmp = 0;
        } else if (aAt == null) {
          cmp = 1;
        } else if (bAt == null) {
          cmp = -1;
        } else {
          cmp = aAt.compareTo(bAt);
        }
        break;
      case _SortColumn.priceOverride:
        cmp = (a.assignment?.monthlyPriceCents ?? 0)
            .compareTo(b.assignment?.monthlyPriceCents ?? 0);
        break;
      case _SortColumn.costOverride:
        cmp = (a.assignment?.vendorApiCostEstimateCentsMonthly ?? 0)
            .compareTo(b.assignment?.vendorApiCostEstimateCentsMonthly ?? 0);
        break;
      case _SortColumn.netMargin:
        cmp = (a.assignment?.netMarginCents ?? 0)
            .compareTo(b.assignment?.netMarginCents ?? 0);
        break;
    }
    return _ascending ? cmp : -cmp;
  }

  @override
  Widget build(BuildContext context) {
    final sorted = <TierAssignmentAdminRow>[...widget.rows]..sort(_compare);

    return Container(
      key: const Key('admin_tier_assignment_table'),
      child: AdminCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Tier assignments',
              style: AppTextStyles.sectionTitle(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 12),
            _FilterBar(
              tierFilter: widget.tierFilter,
              marginBandFilter: widget.marginBandFilter,
              locationCountFilter: widget.locationCountFilter,
              operatorNameController: _opNameController,
              onTierChanged: widget.onTierFilterChanged,
              onMarginChanged: widget.onMarginBandFilterChanged,
              onLocationCountChanged: widget.onLocationCountFilterChanged,
              onOperatorNameChanged: widget.onOperatorNameFilterChanged,
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
                    label: const Text('Tier'),
                    onSort: (_, __) => _toggleSort(_SortColumn.tier),
                  ),
                  DataColumn(
                    label: const Text('Active since'),
                    onSort: (_, __) => _toggleSort(_SortColumn.activeSince),
                  ),
                  const DataColumn(label: Text('Custom cadences')),
                  DataColumn(
                    label: const Text('Price override (USD/month)'),
                    onSort: (_, __) => _toggleSort(_SortColumn.priceOverride),
                  ),
                  DataColumn(
                    label: const Text('Cost basis override (USD/month)'),
                    onSort: (_, __) => _toggleSort(_SortColumn.costOverride),
                  ),
                  DataColumn(
                    label: const Text('Net margin'),
                    onSort: (_, __) => _toggleSort(_SortColumn.netMargin),
                  ),
                  const DataColumn(label: Text('Notes')),
                  const DataColumn(label: Text('Action')),
                ],
                rows: <DataRow>[
                  for (final row in sorted) _buildRow(row),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  DataRow _buildRow(TierAssignmentAdminRow row) {
    final assignment = row.assignment;
    final margin = assignment?.netMarginCents;
    final Color marginColor;
    if (margin == null || margin == 0) {
      marginColor = AppColors.textMuted;
    } else if (margin > 0) {
      marginColor = AppColors.positive;
    } else {
      marginColor = AppColors.negative;
    }
    final priceLabel = assignment?.monthlyPriceCents == null
        ? '—'
        : formatCents(assignment!.monthlyPriceCents!);
    final costLabel = assignment?.vendorApiCostEstimateCentsMonthly == null
        ? '—'
        : formatCents(assignment!.vendorApiCostEstimateCentsMonthly!);
    final marginLabel = margin == null ? '—' : formatCents(margin);
    final cadences = assignment?.pollingCadencePerVendorSeconds;
    final cadenceLabel = (cadences == null || cadences.isEmpty)
        ? '—'
        : '${cadences.length} vendor(s) set';
    final notes = row.adminNotes ?? '';
    final notesLabel = notes.length > 30 ? '${notes.substring(0, 30)}…' : notes;
    final tierLabel = assignment?.tierKey.wire ?? '—';
    final activeSinceLabel = assignment == null
        ? '—'
        : adminHumanDateTime(assignment.effectiveAt);
    // Contract Card 2 action label: "Assign / Update" — render as
    // "Assign" for never-assigned rows, "Update" for rows already
    // carrying a current assignment. The button key stays stable so
    // tests can target either state with the same finder.
    final actionLabel = assignment == null ? 'Assign' : 'Update';

    return DataRow(
      key: ValueKey<String>(
        'admin_tier_assignment_row_'
        '${row.operatorRef.operatorId}_'
        '${row.operatorRef.locationId}',
      ),
      cells: <DataCell>[
        DataCell(Text(
          row.operatorRef.businessName,
          style: AppTextStyles.body13(color: AppColors.textPrimary),
        )),
        DataCell(Text(
          row.operatorRef.locationName,
          style: AppTextStyles.body13(color: AppColors.textPrimary),
        )),
        DataCell(Text(
          tierLabel,
          style: AppTextStyles.mono12(color: AppColors.textPrimary),
        )),
        DataCell(Text(
          activeSinceLabel,
          style: AppTextStyles.mono11(color: AppColors.textMuted),
        )),
        DataCell(Text(
          cadenceLabel,
          style: AppTextStyles.mono12(color: AppColors.textPrimary),
        )),
        DataCell(Text(
          priceLabel,
          style: AppTextStyles.mono12(color: AppColors.textPrimary),
        )),
        DataCell(Text(
          costLabel,
          style: AppTextStyles.mono12(color: AppColors.textPrimary),
        )),
        DataCell(Text(
          marginLabel,
          style: AppTextStyles.mono14(color: marginColor),
        )),
        DataCell(Text(
          notesLabel.isEmpty ? '—' : notesLabel,
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        )),
        DataCell(
          widget.editingEnabled
              ? OutlinedButton(
                  key: Key(
                    'admin_tier_assignment_assign_'
                    '${row.operatorRef.operatorId}_'
                    '${row.operatorRef.locationId}',
                  ),
                  style: AdminButtonStyles.secondary(
                    minWidth: 80,
                    minHeight: 32,
                  ),
                  onPressed: () => widget.onAssign(row),
                  child: Text(actionLabel),
                )
              : Text(
                  'Read-only',
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
        ),
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.tierFilter,
    required this.marginBandFilter,
    required this.locationCountFilter,
    required this.operatorNameController,
    required this.onTierChanged,
    required this.onMarginChanged,
    required this.onLocationCountChanged,
    required this.onOperatorNameChanged,
  });

  final PollingTierKey? tierFilter;
  final String? marginBandFilter;
  final LocationCountFilter? locationCountFilter;
  final TextEditingController operatorNameController;
  final ValueChanged<PollingTierKey?>? onTierChanged;
  final ValueChanged<String?>? onMarginChanged;
  final ValueChanged<LocationCountFilter?>? onLocationCountChanged;
  final ValueChanged<String>? onOperatorNameChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 220,
          child: DropdownButtonFormField<PollingTierKey?>(
            key: const Key('admin_tier_filter_dropdown'),
            initialValue: tierFilter,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Tier',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: <DropdownMenuItem<PollingTierKey?>>[
              const DropdownMenuItem<PollingTierKey?>(
                value: null,
                child: Text('All tiers'),
              ),
              for (final tier in PollingTierKey.values)
                DropdownMenuItem<PollingTierKey?>(
                  value: tier,
                  child: Text(tier.wire),
                ),
            ],
            onChanged: onTierChanged,
          ),
        ),
        SizedBox(
          width: 220,
          child: DropdownButtonFormField<String?>(
            key: const Key('admin_margin_band_dropdown'),
            initialValue: marginBandFilter,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Margin band',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: const <DropdownMenuItem<String?>>[
              DropdownMenuItem<String?>(value: null, child: Text('All')),
              DropdownMenuItem<String?>(
                value: 'positive',
                child: Text('Positive'),
              ),
              DropdownMenuItem<String?>(
                value: 'break_even',
                child: Text('Break-even'),
              ),
              DropdownMenuItem<String?>(
                value: 'negative',
                child: Text('Negative'),
              ),
            ],
            onChanged: onMarginChanged,
          ),
        ),
        SizedBox(
          width: 260,
          child: DropdownButtonFormField<LocationCountFilter?>(
            key: const Key('admin_location_count_dropdown'),
            initialValue: locationCountFilter,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Location count',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: const <DropdownMenuItem<LocationCountFilter?>>[
              DropdownMenuItem<LocationCountFilter?>(
                value: null,
                child: Text('All operators'),
              ),
              DropdownMenuItem<LocationCountFilter?>(
                value: 'single',
                child: Text('Single-location'),
              ),
              DropdownMenuItem<LocationCountFilter?>(
                value: 'multi',
                child: Text('Multi-location'),
              ),
            ],
            onChanged: onLocationCountChanged,
          ),
        ),
        SizedBox(
          width: 240,
          child: TextField(
            key: const Key('admin_operator_name_field'),
            controller: operatorNameController,
            decoration: const InputDecoration(
              labelText: 'Operator name',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: onOperatorNameChanged,
          ),
        ),
      ],
    );
  }
}
