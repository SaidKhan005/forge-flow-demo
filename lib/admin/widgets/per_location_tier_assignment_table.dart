import 'package:flutter/material.dart';
import '../../domain/models/forge_flow_polling_tier_assignment.dart';
import '../../theme/app_theme.dart';
import '../admin_human_labels.dart';
import '../services/data_accuracy_admin_gateway.dart';
import 'admin_action_controls.dart';
import 'admin_responsive_layout.dart';

class PerLocationTierAssignmentTable extends StatefulWidget {
  const PerLocationTierAssignmentTable({
    super.key,
    required this.rows,
    required this.tierDefinitions,
    required this.editingEnabled,
    required this.onAssign,
    this.onAssignShown,
    this.assignShownLocationCount,
    this.scopeLabel,
    this.tierFilter,
    this.operatorNameFilter,
    this.vendorFilter,
    this.onTierFilterChanged,
    this.onOperatorNameFilterChanged,
    this.onVendorFilterChanged,
  });

  final List<TierAssignmentAdminRow> rows;
  final List<TierDefinition> tierDefinitions;
  final bool editingEnabled;
  final void Function(TierAssignmentAdminRow row) onAssign;
  final VoidCallback? onAssignShown;
  final int? assignShownLocationCount;
  final String? scopeLabel;
  final PollingTierKey? tierFilter;
  final String? operatorNameFilter;
  final String? vendorFilter;
  final ValueChanged<PollingTierKey?>? onTierFilterChanged;
  final ValueChanged<String>? onOperatorNameFilterChanged;
  final ValueChanged<String?>? onVendorFilterChanged;

  @override
  State<PerLocationTierAssignmentTable> createState() =>
      _PerLocationTierAssignmentTableState();
}

class _PerLocationTierAssignmentTableState
    extends State<PerLocationTierAssignmentTable> {
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
    final location = a.operatorRef.locationName.compareTo(
      b.operatorRef.locationName,
    );
    if (location != 0) return location;
    return a.operatorRef.businessName.compareTo(b.operatorRef.businessName);
  }

  @override
  Widget build(BuildContext context) {
    final sorted = <TierAssignmentAdminRow>[...widget.rows]..sort(_compare);
    final assignShownCount = widget.assignShownLocationCount ?? sorted.length;
    final scopeLabel = widget.scopeLabel?.trim();

    return Container(
      key: const Key('admin_tier_assignment_table'),
      child: AdminCard(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final titleColumn = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Assignments',
                        style: AppTextStyles.sectionTitle(
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        scopeLabel == null || scopeLabel.isEmpty
                            ? _locationCountLabel(sorted.length)
                            : '${_locationCountLabel(assignShownCount)} in $scopeLabel',
                        style: AppTextStyles.body13(
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  );
                  final assignButton = widget.onAssignShown == null
                      ? null
                      : AdminActionButton(
                          key: const Key('admin_polling_setup_scope_assign'),
                          label: assignShownCount == 1
                              ? 'Assign shown location'
                              : 'Assign shown locations',
                          onPressed: widget.onAssignShown,
                          icon: Icons.assignment_outlined,
                          role: AdminActionRole.primary,
                        );
                  // Stack the action below the heading when the row is too
                  // narrow to hold both (the admin console's 1.12 text-scaling
                  // floor in the compact scoped-workspace pane), instead of
                  // overflowing the fixed-width button past the edge.
                  if (assignButton != null && constraints.maxWidth < 520) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        titleColumn,
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: assignButton,
                        ),
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(child: titleColumn),
                      if (assignButton != null) ...<Widget>[
                        const SizedBox(width: 16),
                        assignButton,
                      ],
                    ],
                  );
                },
              ),
            ),
            const Divider(height: 1, color: AppColors.borderSubtle),
            _FilterBar(
              tierFilter: widget.tierFilter,
              vendorFilter: widget.vendorFilter,
              operatorNameController: _opNameController,
              resultCountLabel: _locationCountLabel(sorted.length),
              onTierChanged: widget.onTierFilterChanged,
              onOperatorNameChanged: widget.onOperatorNameFilterChanged,
              onVendorChanged: widget.onVendorFilterChanged,
            ),
            const Divider(height: 1, color: AppColors.borderSubtle),
            _AssignmentHeaderRow(showActions: widget.editingEnabled),
            if (sorted.isEmpty)
              Padding(
                padding: const EdgeInsets.all(18),
                child: Text(
                  'No assignments match this view.',
                  style: AppTextStyles.body13(color: AppColors.textMuted),
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < sorted.length; i++) ...[
                    _buildRow(sorted[i]),
                    if (i != sorted.length - 1)
                      const Divider(height: 1, color: AppColors.borderSubtle),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  String _locationCountLabel(int count) {
    return '$count ${count == 1 ? 'location' : 'locations'}';
  }

  Widget _buildRow(TierAssignmentAdminRow row) {
    final assignment = row.assignment;
    final definition = assignment == null
        ? null
        : _definitionFor(assignment.tierKey);
    final margin = assignment?.netMarginCents;
    final priceLabel = assignment?.monthlyPriceCents == null
        ? 'Default'
        : formatCents(assignment!.monthlyPriceCents!);
    final costLabel = assignment?.vendorApiCostEstimateCentsMonthly == null
        ? 'Default'
        : formatCents(assignment!.vendorApiCostEstimateCentsMonthly!);
    final marginLabel = margin == null ? '—' : formatCents(margin);
    final marginColor = _marginColor(margin);
    final cadences = assignment?.pollingCadencePerVendorSeconds;
    final cadenceLabel = (cadences == null || cadences.isEmpty)
        ? _cadenceSummary(definition?.pollingCadencePerVendorSeconds)
        : _cadenceSummary(cadences);
    final notes = row.adminNotes ?? '';
    final notesLabel = notes.length > 30
        ? '${notes.substring(0, 30)}...'
        : notes;
    final setupLabel = assignment?.tierKey == null
        ? 'Not assigned'
        : _tierLabel(assignment!.tierKey);
    final activeSinceLabel = assignment == null
        ? null
        : adminHumanDateTime(assignment.effectiveAt);
    final actionLabel = assignment == null ? 'Assign' : 'Update';
    final action = widget.editingEnabled
        ? AdminActionButton(
            key: Key(
              'admin_tier_assignment_assign_'
              '${row.operatorRef.operatorId}_${row.operatorRef.locationId}',
            ),
            label: actionLabel,
            onPressed: () => widget.onAssign(row),
            icon: Icons.edit_outlined,
            compact: true,
            minWidth: 96,
          )
        : const SizedBox.shrink();

    return Container(
      key: ValueKey<String>(
        'admin_tier_assignment_row_'
        '${row.operatorRef.operatorId}_'
        '${row.operatorRef.locationId}',
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          final identity = _AssignmentIdentity(row: row);
          final setup = _SetupCell(
            setupLabel: setupLabel,
            activeSinceLabel: activeSinceLabel,
            isUnassigned: assignment == null,
          );
          final cadence = _TextCell(value: cadenceLabel);
          final commercials = _CommercialsCell(
            priceLabel: priceLabel,
            costLabel: costLabel,
            marginLabel: marginLabel,
            marginColor: marginColor,
          );
          final notesBlock = _TextCell(
            value: notesLabel.isEmpty ? '—' : notesLabel,
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                identity,
                const SizedBox(height: 10),
                setup,
                const SizedBox(height: 10),
                cadence,
                const SizedBox(height: 10),
                commercials,
                const SizedBox(height: 10),
                notesBlock,
                if (widget.editingEnabled) ...[
                  const SizedBox(height: 10),
                  Align(alignment: Alignment.centerRight, child: action),
                ],
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 24, child: identity),
              Expanded(flex: 17, child: setup),
              Expanded(flex: 18, child: cadence),
              Expanded(flex: 25, child: commercials),
              Expanded(flex: 8, child: notesBlock),
              if (widget.editingEnabled)
                Expanded(
                  flex: 8,
                  child: Align(alignment: Alignment.topRight, child: action),
                ),
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

  Color _marginColor(int? margin) {
    if (margin == null || margin == 0) return AppColors.textMuted;
    return margin > 0 ? AppColors.positive : AppColors.negative;
  }

  String _cadenceSummary(Map<String, int>? cadences) {
    if (cadences == null || cadences.isEmpty) return 'Default';
    if (cadences.length == 1) {
      final entry = cadences.entries.first;
      final vendor = kPollOnlyVendorDisplayNames[entry.key] ?? entry.key;
      return '$vendor: ${_formatCadence(entry.value)}';
    }
    final uniqueCadences = cadences.values.toSet();
    if (uniqueCadences.length == 1) {
      return '${cadences.length} vendors: ${_formatCadence(uniqueCadences.single)}';
    }
    return '${cadences.length} vendors';
  }

  String _formatCadence(int seconds) {
    if (seconds % 60 == 0) return '${seconds ~/ 60} min';
    return '${seconds}s';
  }
}

String _tierLabel(PollingTierKey tier) {
  return adminPollingTierLabel(tier);
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
          style: AppTextStyles.body14(
            color: AppColors.textPrimary,
          ).copyWith(fontWeight: FontWeight.w700),
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

class _AssignmentHeaderRow extends StatelessWidget {
  const _AssignmentHeaderRow({required this.showActions});

  final bool showActions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 11, 18, 9),
      child: Row(
        children: <Widget>[
          const Expanded(flex: 24, child: _HeaderCell('Location')),
          const Expanded(flex: 17, child: _HeaderCell('Setup')),
          const Expanded(flex: 18, child: _HeaderCell('Cadence')),
          const Expanded(flex: 25, child: _HeaderCell('Commercials')),
          const Expanded(flex: 8, child: _HeaderCell('Notes')),
          if (showActions) const Expanded(flex: 8, child: SizedBox.shrink()),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: AppTextStyles.uiLabel(color: AppColors.textMuted),
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _SetupCell extends StatelessWidget {
  const _SetupCell({
    required this.setupLabel,
    required this.activeSinceLabel,
    required this.isUnassigned,
  });

  final String setupLabel;
  final String? activeSinceLabel;
  final bool isUnassigned;

  @override
  Widget build(BuildContext context) {
    return _StackedCell(
      primary: setupLabel,
      secondary: activeSinceLabel,
      primaryColor: isUnassigned ? AppColors.sunsetDark : AppColors.textPrimary,
      primaryWeight: FontWeight.w700,
    );
  }
}

class _TextCell extends StatelessWidget {
  const _TextCell({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Text(
      value,
      style: AppTextStyles.body13(color: AppColors.textPrimary),
      overflow: TextOverflow.ellipsis,
      maxLines: 2,
    );
  }
}

class _CommercialsCell extends StatelessWidget {
  const _CommercialsCell({
    required this.priceLabel,
    required this.costLabel,
    required this.marginLabel,
    required this.marginColor,
  });

  final String priceLabel;
  final String costLabel;
  final String marginLabel;
  final Color marginColor;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: <Widget>[
        _MiniFact(label: 'Price', value: priceLabel),
        _MiniFact(label: 'Cost', value: costLabel),
        _MiniFact(label: 'Margin', value: marginLabel, valueColor: marginColor),
      ],
    );
  }
}

class _MiniFact extends StatelessWidget {
  const _MiniFact({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 56, maxWidth: 92),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              label,
              style: AppTextStyles.uiLabel(color: AppColors.textMuted),
            ),
            const SizedBox(width: 6),
            Text(
              value,
              style: AppTextStyles.body13(
                color: valueColor ?? AppColors.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _StackedCell extends StatelessWidget {
  const _StackedCell({
    required this.primary,
    this.secondary,
    this.primaryColor = AppColors.textPrimary,
    this.primaryWeight = FontWeight.w400,
  });

  final String primary;
  final String? secondary;
  final Color primaryColor;
  final FontWeight primaryWeight;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          primary,
          style: AppTextStyles.body13(
            color: primaryColor,
          ).copyWith(fontWeight: primaryWeight),
          overflow: TextOverflow.ellipsis,
        ),
        if (secondary != null && secondary!.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(
            secondary!,
            style: AppTextStyles.body12(color: AppColors.textSecondary),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.tierFilter,
    required this.vendorFilter,
    required this.operatorNameController,
    required this.resultCountLabel,
    required this.onTierChanged,
    required this.onOperatorNameChanged,
    required this.onVendorChanged,
  });

  final PollingTierKey? tierFilter;
  final String? vendorFilter;
  final TextEditingController operatorNameController;
  final String resultCountLabel;
  final ValueChanged<PollingTierKey?>? onTierChanged;
  final ValueChanged<String>? onOperatorNameChanged;
  final ValueChanged<String?>? onVendorChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.backgroundMid.withValues(alpha: 0.24),
      padding: const EdgeInsets.fromLTRB(18, 13, 18, 13),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                SizedBox(
                  width: 270,
                  child: TextField(
                    key: const Key('admin_operator_name_field'),
                    controller: operatorNameController,
                    decoration: const InputDecoration(
                      labelText: 'Location name',
                      prefixIcon: Icon(Icons.search, size: 18),
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: onOperatorNameChanged,
                  ),
                ),
                _FilterMenu<PollingTierKey?>(
                  key: const Key('admin_tier_filter_dropdown'),
                  value: tierFilter,
                  label: 'Tier',
                  items: <DropdownMenuItem<PollingTierKey?>>[
                    const DropdownMenuItem<PollingTierKey?>(
                      value: null,
                      child: Text('Tier'),
                    ),
                    for (final tier in PollingTierKey.values)
                      DropdownMenuItem<PollingTierKey?>(
                        value: tier,
                        child: Text(_tierLabel(tier)),
                      ),
                  ],
                  onChanged: onTierChanged,
                ),
                _FilterMenu<String?>(
                  key: const Key('admin_polling_vendor_filter_dropdown'),
                  value: vendorFilter,
                  label: 'Vendor',
                  items: <DropdownMenuItem<String?>>[
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Vendor'),
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
              ],
            ),
          ),
          const SizedBox(width: 14),
          Text(
            resultCountLabel,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _FilterMenu<T> extends StatelessWidget {
  const _FilterMenu({
    super.key,
    required this.value,
    required this.label,
    required this.items,
    required this.onChanged,
  });

  final T? value;
  final String label;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;

  @override
  Widget build(BuildContext context) {
    // Bounded width + isExpanded so a long menu item (e.g. a vendor name)
    // ellipsizes within the chip instead of overflowing the filter bar at
    // the admin console's 1.12 text-scaling floor in narrow scoped panes.
    return Container(
      height: 36,
      width: 170,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(18),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          hint: Text(label, overflow: TextOverflow.ellipsis),
          isDense: true,
          isExpanded: true,
          borderRadius: BorderRadius.circular(8),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}
