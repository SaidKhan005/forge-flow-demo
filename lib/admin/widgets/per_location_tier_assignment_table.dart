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
    this.vendorFilter,
    this.onTierFilterChanged,
    this.onMarginBandFilterChanged,
    this.onLocationCountFilterChanged,
    this.onOperatorNameFilterChanged,
    this.onVendorFilterChanged,
  });

  final List<TierAssignmentAdminRow> rows;
  final List<TierDefinition> tierDefinitions;
  final bool editingEnabled;
  final void Function(TierAssignmentAdminRow row) onAssign;
  final PollingTierKey? tierFilter;
  final String? marginBandFilter;
  final LocationCountFilter? locationCountFilter;
  final String? operatorNameFilter;
  final String? vendorFilter;
  final ValueChanged<PollingTierKey?>? onTierFilterChanged;
  final ValueChanged<String?>? onMarginBandFilterChanged;
  final ValueChanged<LocationCountFilter?>? onLocationCountFilterChanged;
  final ValueChanged<String>? onOperatorNameFilterChanged;
  final ValueChanged<String?>? onVendorFilterChanged;

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
    _opNameController = TextEditingController(
      text: widget.operatorNameFilter ?? '',
    );
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
        // descending - null is "no tier" and is the empty value.
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
        cmp = (a.assignment?.monthlyPriceCents ?? 0).compareTo(
          b.assignment?.monthlyPriceCents ?? 0,
        );
        break;
      case _SortColumn.costOverride:
        cmp = (a.assignment?.vendorApiCostEstimateCentsMonthly ?? 0).compareTo(
          b.assignment?.vendorApiCostEstimateCentsMonthly ?? 0,
        );
        break;
      case _SortColumn.netMargin:
        cmp = (a.assignment?.netMarginCents ?? 0).compareTo(
          b.assignment?.netMarginCents ?? 0,
        );
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
            const SizedBox(height: 6),
            Text(
              'Use filters to narrow operator locations. Each row keeps tier, cadence, pricing, margin, and notes together.',
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            _FilterBar(
              tierFilter: widget.tierFilter,
              marginBandFilter: widget.marginBandFilter,
              locationCountFilter: widget.locationCountFilter,
              vendorFilter: widget.vendorFilter,
              operatorNameController: _opNameController,
              onTierChanged: widget.onTierFilterChanged,
              onMarginChanged: widget.onMarginBandFilterChanged,
              onLocationCountChanged: widget.onLocationCountFilterChanged,
              onOperatorNameChanged: widget.onOperatorNameFilterChanged,
              onVendorChanged: widget.onVendorFilterChanged,
            ),
            const SizedBox(height: 12),
            _AssignmentToolbar(
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
                'No tier assignments match this view.',
                style: AppTextStyles.body13(color: AppColors.textMuted),
              )
            else
              Column(
                children: [
                  for (var i = 0; i < sorted.length; i++) ...[
                    _buildRow(sorted[i]),
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

  Widget _buildRow(TierAssignmentAdminRow row) {
    final assignment = row.assignment;
    final definition = assignment == null
        ? null
        : _definitionFor(assignment.tierKey);
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
        ? _tierDefaultMoneyLabel(definition?.defaultMonthlyPriceCents)
        : formatCents(assignment!.monthlyPriceCents!);
    final costLabel = assignment?.vendorApiCostEstimateCentsMonthly == null
        ? _tierDefaultMoneyLabel(definition?.vendorApiCostEstimateCentsMonthly)
        : formatCents(assignment!.vendorApiCostEstimateCentsMonthly!);
    final marginLabel = margin == null ? 'Not calculated' : formatCents(margin);
    final cadences = assignment?.pollingCadencePerVendorSeconds;
    final cadenceLabel = (cadences == null || cadences.isEmpty)
        ? _tierDefaultCadenceLabel(definition?.pollingCadencePerVendorSeconds)
        : '${cadences.length} vendor(s) set';
    final notes = row.adminNotes ?? '';
    final notesLabel = notes.length > 30
        ? '${notes.substring(0, 30)}...'
        : notes;
    final tierLabel = assignment?.tierKey == null
        ? 'Not assigned'
        : _tierLabel(assignment!.tierKey);
    final activeSinceLabel = assignment == null
        ? 'Not assigned yet'
        : adminHumanDateTime(assignment.effectiveAt);
    // Contract Card 2 action label: "Assign / Update" - render as
    // "Assign" for never-assigned rows, "Update" for rows already
    // carrying a current assignment. The button key stays stable so
    // tests can target either state with the same finder.
    final actionLabel = assignment == null ? 'Assign' : 'Update';
    final cadenceTooltip = cadences == null || cadences.isEmpty
        ? 'Using the tier default cadence'
        : cadences.entries
              .map(
                (entry) =>
                    '${kPollOnlyVendorDisplayNames[entry.key] ?? entry.key}: '
                    '${entry.value}s',
              )
              .join(', ');

    final facts = <_AssignmentFact>[
      _AssignmentFact('Tier', tierLabel),
      _AssignmentFact('Active since', activeSinceLabel),
      _AssignmentFact('Cadence', cadenceLabel, tooltip: cadenceTooltip),
      _AssignmentFact('Price', priceLabel),
      _AssignmentFact('Cost basis', costLabel),
      _AssignmentFact('Net margin', marginLabel, valueColor: marginColor),
    ];
    final action = widget.editingEnabled
        ? OutlinedButton.icon(
            key: Key(
              'admin_tier_assignment_assign_'
              '${row.operatorRef.operatorId}_${row.operatorRef.locationId}',
            ),
            style: AdminButtonStyles.secondary(minWidth: 96, minHeight: 36),
            onPressed: () => widget.onAssign(row),
            icon: const Icon(Icons.edit_outlined, size: 14),
            label: Text(actionLabel),
          )
        : Text(
            'Read-only',
            style: AppTextStyles.body12(color: AppColors.textMuted),
          );

    return Container(
      key: ValueKey<String>(
        'admin_tier_assignment_row_'
        '${row.operatorRef.operatorId}_'
        '${row.operatorRef.locationId}',
      ),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 900;
          final identity = _AssignmentIdentity(row: row);
          final factWrap = _AssignmentFactWrap(facts: facts);
          final notesBlock = _NotesBlock(notesLabel: notesLabel);
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                identity,
                const SizedBox(height: 10),
                factWrap,
                const SizedBox(height: 8),
                notesBlock,
                const SizedBox(height: 10),
                action,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: identity),
              const SizedBox(width: 14),
              Expanded(flex: 7, child: factWrap),
              const SizedBox(width: 14),
              Expanded(flex: 2, child: notesBlock),
              const SizedBox(width: 14),
              action,
            ],
          );
        },
      ),
    );
  }

  TierDefinition? _definitionFor(PollingTierKey tierKey) {
    for (final definition in widget.tierDefinitions) {
      if (definition.tierKey == tierKey) return definition;
    }
    return null;
  }

  String _tierDefaultMoneyLabel(int? cents) {
    if (cents == null) return 'Tier default';
    return 'Tier default: ${formatCents(cents)}';
  }

  String _tierDefaultCadenceLabel(Map<String, int>? cadences) {
    if (cadences == null || cadences.isEmpty) return 'Tier default';
    final uniqueCadences = cadences.values.toSet();
    if (uniqueCadences.length == 1) {
      return 'Tier default: ${uniqueCadences.single}s';
    }
    return 'Tier default: ${cadences.length} vendors';
  }
}

String _tierLabel(PollingTierKey tier) {
  switch (tier) {
    case PollingTierKey.standard:
      return 'Regular';
    case PollingTierKey.premium:
      return 'Premium';
    case PollingTierKey.custom:
      return 'Custom';
  }
}

class _AssignmentToolbar extends StatelessWidget {
  const _AssignmentToolbar({
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
            key: const Key('admin_tier_assignment_sort_dropdown'),
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
            key: const Key('admin_tier_assignment_sort_direction'),
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
      case _SortColumn.tier:
        return 'Tier';
      case _SortColumn.activeSince:
        return 'Active since';
      case _SortColumn.priceOverride:
        return 'Price';
      case _SortColumn.costOverride:
        return 'Cost basis';
      case _SortColumn.netMargin:
        return 'Net margin';
    }
  }
}

class _AssignmentIdentity extends StatelessWidget {
  const _AssignmentIdentity({required this.row});

  final TierAssignmentAdminRow row;

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

class _AssignmentFact {
  const _AssignmentFact(
    this.label,
    this.value, {
    this.valueColor,
    this.tooltip,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final String? tooltip;
}

class _AssignmentFactWrap extends StatelessWidget {
  const _AssignmentFactWrap({required this.facts});

  final List<_AssignmentFact> facts;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [for (final fact in facts) _AssignmentFactPill(fact: fact)],
    );
  }
}

class _AssignmentFactPill extends StatelessWidget {
  const _AssignmentFactPill({required this.fact});

  final _AssignmentFact fact;

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      constraints: const BoxConstraints(minWidth: 110, maxWidth: 172),
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
            fact.label,
            style: AppTextStyles.uiLabel(color: AppColors.textMuted),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            fact.value,
            style: AppTextStyles.body13(
              color: fact.valueColor ?? AppColors.textPrimary,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
    final tooltip = fact.tooltip;
    if (tooltip == null || tooltip.isEmpty) return pill;
    return Tooltip(message: tooltip, child: pill);
  }
}

class _NotesBlock extends StatelessWidget {
  const _NotesBlock({required this.notesLabel});

  final String notesLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Notes', style: AppTextStyles.uiLabel(color: AppColors.textMuted)),
        const SizedBox(height: 2),
        Text(
          notesLabel.isEmpty ? 'No notes' : notesLabel,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.body13(color: AppColors.textSecondary),
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
    required this.vendorFilter,
    required this.operatorNameController,
    required this.onTierChanged,
    required this.onMarginChanged,
    required this.onLocationCountChanged,
    required this.onOperatorNameChanged,
    required this.onVendorChanged,
  });

  final PollingTierKey? tierFilter;
  final String? marginBandFilter;
  final LocationCountFilter? locationCountFilter;
  final String? vendorFilter;
  final TextEditingController operatorNameController;
  final ValueChanged<PollingTierKey?>? onTierChanged;
  final ValueChanged<String?>? onMarginChanged;
  final ValueChanged<LocationCountFilter?>? onLocationCountChanged;
  final ValueChanged<String>? onOperatorNameChanged;
  final ValueChanged<String?>? onVendorChanged;

  @override
  Widget build(BuildContext context) {
    final hasActiveFilters =
        tierFilter != null ||
        marginBandFilter != null ||
        locationCountFilter != null ||
        vendorFilter != null ||
        operatorNameController.text.trim().isNotEmpty;
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
                  child: Text(_tierLabel(tier)),
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
          width: 230,
          child: DropdownButtonFormField<String?>(
            key: const Key('admin_polling_vendor_filter_dropdown'),
            initialValue: vendorFilter,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Polling vendor',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: <DropdownMenuItem<String?>>[
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('All polling vendors'),
              ),
              for (final vendorId in kPollOnlyVendorIds)
                DropdownMenuItem<String?>(
                  value: vendorId,
                  child: Text(
                    kPollOnlyVendorDisplayNames[vendorId] ?? vendorId,
                  ),
                ),
            ],
            onChanged: onVendorChanged,
          ),
        ),
        SizedBox(
          width: 280,
          child: DropdownButtonFormField<LocationCountFilter?>(
            key: const Key('admin_location_count_dropdown'),
            initialValue: locationCountFilter,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Operator location count',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: const <DropdownMenuItem<LocationCountFilter?>>[
              DropdownMenuItem<LocationCountFilter?>(
                value: null,
                child: Text('All location counts'),
              ),
              DropdownMenuItem<LocationCountFilter?>(
                value: 'single',
                child: Text('Single-location operators'),
              ),
              DropdownMenuItem<LocationCountFilter?>(
                value: 'multi',
                child: Text('Multi-location operators'),
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
        if (hasActiveFilters)
          OutlinedButton.icon(
            key: const Key('admin_tier_assignment_clear_filters'),
            style: AdminButtonStyles.secondary(minWidth: 120, minHeight: 40),
            onPressed: () {
              operatorNameController.clear();
              onTierChanged?.call(null);
              onMarginChanged?.call(null);
              onLocationCountChanged?.call(null);
              onVendorChanged?.call(null);
              onOperatorNameChanged?.call('');
            },
            icon: const Icon(Icons.filter_alt_off_outlined, size: 16),
            label: const Text('Clear filters'),
          ),
      ],
    );
  }
}
