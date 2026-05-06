// Phase 8 spine-bridge Lane .C - F&F Ops Console "Data Accuracy" tab.
//
// Tab 1 of the per-location data accuracy admin surface. Operator
// picks covers source per daypart + wage source on their own web
// console (Lane .B); this screen is the cross-operator view F&F
// support uses to inspect / override those settings + audit the
// trail.
//
// Authority: docs/contracts/data_accuracy_settings_contract.md,
// "Tab 1: Data Accuracy (per-location overrides)" section.
//
// Symmetric with [PollingAndPricingAdminScreen] (Tab 2) - both ride
// the [DataAccuracyAdminGateway] so the demo + production wiring are
// identical. Edit affordances gate on `editingEnabled` (which mirrors
// the 11A pattern: super_admin → editable; ff_support → read-only).

import 'package:flutter/material.dart';

import '../../domain/models/data_accuracy_settings.dart';
import '../../theme/app_theme.dart';
import '../admin_route_handoff.dart';
import '../admin_button_styles.dart';
import '../services/data_accuracy_admin_gateway.dart';
import '../widgets/admin_responsive_layout.dart';
import '../widgets/data_accuracy_audit_history_panel.dart';
import '../widgets/operator_location_scope_banner.dart';
import '../widgets/per_location_data_accuracy_table.dart';

class PerLocationDataAccuracyScreen extends StatefulWidget {
  const PerLocationDataAccuracyScreen({
    super.key,
    required this.gateway,
    required this.actorUserId,
    this.editingEnabled = true,
    this.initialScope,
  });

  final DataAccuracyAdminGateway gateway;
  final String actorUserId;
  final AdminOperatorLocationScopeIntent? initialScope;

  /// Mirror of the pricing screen pattern: when false, the screen
  /// hides every mutate affordance. The gateway is the second line of
  /// defence - it throws [DataAccuracyAdminForbiddenException] if a
  /// non-forge-admin caller tries to mutate.
  final bool editingEnabled;

  @override
  State<PerLocationDataAccuracyScreen> createState() =>
      _PerLocationDataAccuracyScreenState();
}

class _PerLocationDataAccuracyScreenState
    extends State<PerLocationDataAccuracyScreen> {
  bool _loading = true;
  String? _loadError;
  String? _actionError;
  List<DataAccuracyAdminRow> _rows = const <DataAccuracyAdminRow>[];
  List<DataAccuracyAdminAuditEvent> _auditEvents =
      const <DataAccuracyAdminAuditEvent>[];
  late AdminOperatorLocationScopeIntent? _scope = widget.initialScope;
  int _refreshGeneration = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant PerLocationDataAccuracyScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialScope != oldWidget.initialScope) {
      _scope = widget.initialScope;
    }
  }

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final results = await Future.wait<Object>([
        widget.gateway.listDataAccuracyRows(),
        widget.gateway.listAuditHistory(),
      ]);
      if (generation != _refreshGeneration) return;
      final rows = results[0] as List<DataAccuracyAdminRow>;
      // Tab 1's audit panel surfaces only data-accuracy override
      // events. The shared audit log buffer also records Tab 2 events
      // (`admin.polling_tier_*`, `admin.margin_rollup.export_csv`)
      // which belong on Tab 2's own Card 5; filtering here prevents
      // cross-surface audit bleed.
      final events = results[1] as List<DataAccuracyAdminAuditEvent>;
      final filtered = events
          .where((e) => e.eventType.startsWith('admin.data_accuracy.'))
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _auditEvents = filtered;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load data accuracy rows: $error';
        _loading = false;
      });
    }
  }

  Future<void> _onEditRow(DataAccuracyAdminRow row) async {
    if (!widget.editingEnabled) return;
    final result = await showDialog<_DataAccuracyOverrideDraft>(
      context: context,
      builder: (_) => _DataAccuracyOverrideDialog(initial: row),
    );
    if (result == null) return;
    setState(() => _actionError = null);
    try {
      await widget.gateway.overrideDataAccuracy(
        operatorId: row.operatorRef.operatorId,
        locationId: row.operatorRef.locationId,
        coversSourceLunch: result.coversSourceLunch,
        coversSourceDinner: result.coversSourceDinner,
        coversSourceLateNight: result.coversSourceLateNight,
        wageSource: result.wageSource,
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        reasonNote: result.reasonNote,
      );
      await _refresh();
    } on DataAccuracyAdminForbiddenException catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = 'Override failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_data_accuracy_screen'),
      color: AppColors.backgroundDeep,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AdminPageHeader(
              title: 'Data accuracy',
              subtitle:
                  "Inspect and override each operator-location's covers and wage source. "
                  'Every override is audit-logged.',
            ),
            const SizedBox(height: 14),
            if (!widget.editingEnabled)
              const _ReadOnlyBanner(
                key: Key('admin_data_accuracy_readonly_banner'),
              ),
            if (_actionError != null)
              _ErrorBanner(
                key: const Key('admin_data_accuracy_action_error'),
                message: _actionError!,
              ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  List<DataAccuracyAdminRow> get _visibleRows {
    final scope = _scope;
    if (scope == null) return _rows;
    return _rows
        .where(
          (row) => scope.matches(
            operatorId: row.operatorRef.operatorId,
            locationId: row.operatorRef.locationId,
          ),
        )
        .toList(growable: false);
  }

  List<DataAccuracyAdminAuditEvent> get _visibleAuditEvents {
    final scope = _scope;
    if (scope == null) return _auditEvents;
    return _auditEvents
        .where(
          (event) => scope.matches(
            operatorId: event.operatorId,
            locationId: event.locationId,
          ),
        )
        .toList(growable: false);
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        key: Key('admin_data_accuracy_loading'),
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sunsetDark,
          ),
        ),
      );
    }
    if (_loadError != null) {
      return _ErrorBanner(
        key: const Key('admin_data_accuracy_load_error'),
        message: _loadError!,
      );
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_scope != null)
            OperatorLocationScopeBanner(
              scope: _scope!,
              surfaceName: 'data accuracy',
              onClear: () => setState(() => _scope = null),
            ),
          PerLocationDataAccuracyTable(
            rows: _visibleRows,
            editingEnabled: widget.editingEnabled,
            onEditRow: _onEditRow,
          ),
          const SizedBox(height: 16),
          DataAccuracyAuditHistoryPanel(events: _visibleAuditEvents),
        ],
      ),
    );
  }
}

class _DataAccuracyOverrideDraft {
  const _DataAccuracyOverrideDraft({
    required this.coversSourceLunch,
    required this.coversSourceDinner,
    required this.coversSourceLateNight,
    required this.wageSource,
    required this.reasonNote,
  });

  final CoversSource? coversSourceLunch;
  final CoversSource? coversSourceDinner;
  final CoversSource? coversSourceLateNight;
  final WageSource? wageSource;
  final String reasonNote;
}

class _DataAccuracyOverrideDialog extends StatefulWidget {
  const _DataAccuracyOverrideDialog({required this.initial});

  final DataAccuracyAdminRow initial;

  @override
  State<_DataAccuracyOverrideDialog> createState() =>
      _DataAccuracyOverrideDialogState();
}

class _DataAccuracyOverrideDialogState
    extends State<_DataAccuracyOverrideDialog> {
  late CoversSource _lunch = widget.initial.settings.coversSourceLunch;
  late CoversSource _dinner = widget.initial.settings.coversSourceDinner;
  late CoversSource _lateNight = widget.initial.settings.coversSourceLateNight;
  late WageSource _wage = widget.initial.settings.wageSource;
  final TextEditingController _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_data_accuracy_override_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Override data accuracy: ${widget.initial.operatorRef.businessName} '
        '/ ${widget.initial.operatorRef.locationName}',
        style: AdminButtonStyles.dialogTitleStyle,
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _CoversSourceField(
                label: 'Covers source - lunch',
                fieldKey: const Key('admin_data_accuracy_lunch'),
                value: _lunch,
                onChanged: (v) => setState(() => _lunch = v),
              ),
              _CoversSourceField(
                label: 'Covers source - dinner',
                fieldKey: const Key('admin_data_accuracy_dinner'),
                value: _dinner,
                onChanged: (v) => setState(() => _dinner = v),
              ),
              _CoversSourceField(
                label: 'Covers source - late night',
                fieldKey: const Key('admin_data_accuracy_late_night'),
                value: _lateNight,
                onChanged: (v) => setState(() => _lateNight = v),
              ),
              const SizedBox(height: 8),
              _WageSourceField(
                value: _wage,
                onChanged: (v) => setState(() => _wage = v),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin_data_accuracy_reason_note'),
                controller: _reason,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Reason for override',
                  hintText: 'Brief explanation for the audit log',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_data_accuracy_override_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_data_accuracy_override_submit'),
          style: AdminButtonStyles.primary,
          onPressed: () {
            final note = _reason.text.trim();
            if (note.isEmpty) return;
            Navigator.of(context).pop(
              _DataAccuracyOverrideDraft(
                coversSourceLunch: _lunch,
                coversSourceDinner: _dinner,
                coversSourceLateNight: _lateNight,
                wageSource: _wage,
                reasonNote: note,
              ),
            );
          },
          child: const Text('Apply override'),
        ),
      ],
    );
  }
}

class _CoversSourceField extends StatelessWidget {
  const _CoversSourceField({
    required this.label,
    required this.fieldKey,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final Key fieldKey;
  final CoversSource value;
  final ValueChanged<CoversSource> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 200,
            child: Text(
              label,
              style: AppTextStyles.uiLabel(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: DropdownButtonFormField<CoversSource>(
              key: fieldKey,
              initialValue: value,
              items: CoversSource.values
                  .map(
                    (c) => DropdownMenuItem<CoversSource>(
                      value: c,
                      child: Text(_coversSourceLabel(c)),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _WageSourceField extends StatelessWidget {
  const _WageSourceField({required this.value, required this.onChanged});

  final WageSource value;
  final ValueChanged<WageSource> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 200,
            child: Text(
              'Wage source',
              style: AppTextStyles.uiLabel(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: DropdownButtonFormField<WageSource>(
              key: const Key('admin_data_accuracy_wage_source'),
              initialValue: value,
              items: WageSource.values
                  .map(
                    (s) => DropdownMenuItem<WageSource>(
                      value: s,
                      child: Text(_wageSourceLabel(s)),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ],
      ),
    );
  }
}

String _coversSourceLabel(CoversSource source) {
  switch (source) {
    case CoversSource.vendor:
      return 'Vendor feed';
    case CoversSource.forecast:
      return 'Forecast';
    case CoversSource.manual:
      return 'Manual entry';
  }
}

String _wageSourceLabel(WageSource source) {
  switch (source) {
    case WageSource.vendor:
      return 'Vendor wage data';
    case WageSource.manualMix:
      return 'Manual mix';
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.lock_outline, size: 16, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'View only: data accuracy overrides require ecosystem admin access.',
              style: AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
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
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.negative, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        message,
        style: AppTextStyles.mono11(color: AppColors.negative),
      ),
    );
  }
}
