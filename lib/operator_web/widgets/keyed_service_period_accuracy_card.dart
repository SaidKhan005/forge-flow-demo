// Doc 1 keyed-data-accuracy-write — operator-web keyed service-period
// data-accuracy editor card.
//
// Authority:
//   * docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md
//   * docs/contracts/data_accuracy_settings_contract.md
//     "Business timing compatibility amendment (2026-05-06)" — keyed
//     service-period overrides supersede the legacy
//     covers_source_lunch / _dinner / _late_night triplet.
//   * docs/_execution/2026-05-07_admin_web_setting_sync_closeout.md
//     §"Keyed data accuracy admin/operator write surface".
//
// V1 seam (HP #1 transport-only): the card lists keyed rows the
// operator already has (one per (service_period_key,
// effective_at_business_date)) and lets owner/admin operators add or
// supersede a row via the existing
// /v1/operators/.../data_accuracy_service_period_settings PATCH.
//
// The widget is gateway-driven so it works with both the live HTTP
// gateway and an in-memory test double. The screen owns load/save
// orchestration; this card is presentation + dialog only.
//
// UX writing standard (`memory/project_ux_writing_standard.md`): plain
// English. The dialog explains the four allowed covers sources and the
// four allowed wage sources without engineering jargon.

import 'package:flutter/material.dart';

import '../../domain/models/data_accuracy_service_period_setting.dart';
import '../../theme/app_theme.dart';

/// Pure value object the card emits when the operator submits the
/// dialog. The screen forwards this into
/// [OperatorWebDataAccuracyGateway.saveServicePeriodSetting].
class KeyedServicePeriodAccuracyDraft {
  const KeyedServicePeriodAccuracyDraft({
    required this.servicePeriodKey,
    required this.coversSource,
    required this.wageSource,
    required this.effectiveAtBusinessDateIso,
  });

  final String servicePeriodKey;
  final ServicePeriodCoversSource coversSource;
  final ServicePeriodWageSource wageSource;
  final String effectiveAtBusinessDateIso;
}

/// Visual key contract — mirrors the rest of the operator-web Data
/// Accuracy surface so widget tests can find the card by name.
const Key kKeyedServicePeriodAccuracyCardKey = Key(
  'data_accuracy_keyed_service_period_card',
);
const Key kKeyedServicePeriodAccuracyAddButtonKey = Key(
  'data_accuracy_keyed_service_period_add',
);
const Key kKeyedServicePeriodAccuracyDialogKey = Key(
  'data_accuracy_keyed_service_period_dialog',
);
const Key kKeyedServicePeriodAccuracyKeyFieldKey = Key(
  'data_accuracy_keyed_service_period_key_field',
);
const Key kKeyedServicePeriodAccuracyEffectiveDateFieldKey = Key(
  'data_accuracy_keyed_service_period_effective_date_field',
);
const Key kKeyedServicePeriodAccuracyCoversFieldKey = Key(
  'data_accuracy_keyed_service_period_covers_field',
);
const Key kKeyedServicePeriodAccuracyWageFieldKey = Key(
  'data_accuracy_keyed_service_period_wage_field',
);
const Key kKeyedServicePeriodAccuracySubmitKey = Key(
  'data_accuracy_keyed_service_period_submit',
);
const Key kKeyedServicePeriodAccuracyCancelKey = Key(
  'data_accuracy_keyed_service_period_cancel',
);
const Key kKeyedServicePeriodAccuracyLoadErrorKey = Key(
  'data_accuracy_keyed_service_period_load_error',
);

class KeyedServicePeriodAccuracyCard extends StatelessWidget {
  const KeyedServicePeriodAccuracyCard({
    super.key,
    required this.rows,
    required this.busy,
    required this.loadError,
    required this.saveError,
    required this.editingEnabled,
    required this.onAddOrEdit,
    required this.onRetry,
    this.defaultEffectiveAtBusinessDateIso,
  });

  /// Rows the gateway returned for the current operator/location.
  /// Sorted by (service_period_key, effective_at_business_date desc) by
  /// the gateway; the card preserves that ordering.
  final List<DataAccuracyServicePeriodSetting> rows;

  /// True while the screen has a load or save in flight.
  final bool busy;

  /// Most recent load error, if any. Surfaces a retry button.
  final String? loadError;

  /// Most recent save error, if any. Surfaces inline below the table.
  final String? saveError;

  /// Mirrors the screen-level role gate: `operator_owner` /
  /// `operator_admin` only. False for `location_manager`.
  final bool editingEnabled;

  /// Submit callback. Returns the saved row from the gateway or
  /// `null` if the dialog was cancelled.
  final Future<void> Function(KeyedServicePeriodAccuracyDraft draft)
  onAddOrEdit;

  /// Triggered when the operator presses "Retry" on a load error.
  final VoidCallback onRetry;

  /// Pre-filled effective business date (current business date) used
  /// when the operator opens the dialog without editing an existing
  /// row. The dialog still lets the operator pick another date.
  final String? defaultEffectiveAtBusinessDateIso;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: kKeyedServicePeriodAccuracyCardKey,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.schedule_outlined,
                size: 18,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Service-period overrides',
                  style: AppTextStyles.mono15(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              if (editingEnabled)
                FilledButton.icon(
                  key: kKeyedServicePeriodAccuracyAddButtonKey,
                  onPressed: busy
                      ? null
                      : () => _openDialog(
                          context,
                          existing: null,
                        ),
                  icon: const Icon(Icons.add, size: 14),
                  label: const Text('Add or supersede'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Add an override for a specific service period (lunch, dinner, '
            'breakfast, brunch, late night, or any custom name your kitchen '
            'uses). Forge & Flow uses the most recent override at-or-before '
            'each closed shift’s business date, so future-dating an '
            'override stages it without overwriting history.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          if (loadError != null)
            _LoadErrorBlock(
              key: kKeyedServicePeriodAccuracyLoadErrorKey,
              message: loadError!,
              onRetry: onRetry,
            )
          else if (rows.isEmpty)
            Text(
              'No service-period overrides yet. The covers and wage cards '
              'above still apply across every service period until you add '
              'one here.',
              style: AppTextStyles.body12(color: AppColors.textMuted),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  _RowSummary(
                    row: rows[i],
                    editingEnabled: editingEnabled,
                    onEdit: () => _openDialog(
                      context,
                      existing: rows[i],
                    ),
                  ),
                  if (i != rows.length - 1)
                    const Divider(
                      color: AppColors.borderSubtle,
                      height: 14,
                    ),
                ],
              ],
            ),
          if (saveError != null) ...[
            const SizedBox(height: 12),
            Container(
              key: const Key(
                'data_accuracy_keyed_service_period_save_error',
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.warningBadgeBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.warning),
              ),
              child: Text(
                saveError!,
                style: AppTextStyles.body12(color: AppColors.warning),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openDialog(
    BuildContext context, {
    required DataAccuracyServicePeriodSetting? existing,
  }) async {
    final draft = await showDialog<KeyedServicePeriodAccuracyDraft>(
      context: context,
      builder: (_) => _KeyedServicePeriodDialog(
        existing: existing,
        defaultEffectiveAtBusinessDateIso: defaultEffectiveAtBusinessDateIso,
      ),
    );
    if (draft == null) return;
    await onAddOrEdit(draft);
  }
}

class _RowSummary extends StatelessWidget {
  const _RowSummary({
    required this.row,
    required this.editingEnabled,
    required this.onEdit,
  });

  final DataAccuracyServicePeriodSetting row;
  final bool editingEnabled;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key(
        'data_accuracy_keyed_service_period_row_'
        '${row.servicePeriodKey}_${row.effectiveAtBusinessDate}',
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.servicePeriodKey,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  'Effective ${row.effectiveAtBusinessDate} • '
                  'covers: ${_coversLabel(row.coversSource)} • '
                  'wages: ${_wageLabel(row.wageSource)}',
                  style: AppTextStyles.body12(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          if (editingEnabled)
            OutlinedButton.icon(
              key: Key(
                'data_accuracy_keyed_service_period_edit_'
                '${row.servicePeriodKey}_${row.effectiveAtBusinessDate}',
              ),
              onPressed: onEdit,
              icon: const Icon(Icons.edit_outlined, size: 14),
              label: const Text('Edit'),
            ),
        ],
      ),
    );
  }
}

class _LoadErrorBlock extends StatelessWidget {
  const _LoadErrorBlock({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.warningBadgeBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.warning),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_outlined,
            size: 16,
            color: AppColors.warning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body12(color: AppColors.warning),
            ),
          ),
          TextButton(
            key: const Key(
              'data_accuracy_keyed_service_period_retry',
            ),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _KeyedServicePeriodDialog extends StatefulWidget {
  const _KeyedServicePeriodDialog({
    required this.existing,
    required this.defaultEffectiveAtBusinessDateIso,
  });

  final DataAccuracyServicePeriodSetting? existing;
  final String? defaultEffectiveAtBusinessDateIso;

  @override
  State<_KeyedServicePeriodDialog> createState() =>
      _KeyedServicePeriodDialogState();
}

class _KeyedServicePeriodDialogState extends State<_KeyedServicePeriodDialog> {
  static final RegExp _keyPattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
  static final RegExp _datePattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  late final TextEditingController _keyCtl = TextEditingController(
    text: widget.existing?.servicePeriodKey ?? '',
  );
  late final TextEditingController _dateCtl = TextEditingController(
    text:
        widget.existing?.effectiveAtBusinessDate ??
        widget.defaultEffectiveAtBusinessDateIso ??
        '',
  );
  late ServicePeriodCoversSource _covers =
      widget.existing?.coversSource ?? ServicePeriodCoversSource.vendor;
  late ServicePeriodWageSource _wage =
      widget.existing?.wageSource ?? ServicePeriodWageSource.vendorPerEmployee;
  String? _errorText;

  bool get _editingExisting => widget.existing != null;

  @override
  void dispose() {
    _keyCtl.dispose();
    _dateCtl.dispose();
    super.dispose();
  }

  void _submit() {
    final key = _keyCtl.text.trim();
    final date = _dateCtl.text.trim();
    if (!_keyPattern.hasMatch(key)) {
      setState(() {
        _errorText =
            'Use lowercase letters, numbers, or underscores only. Start with '
            'a letter (e.g. "breakfast", "happy_hour").';
      });
      return;
    }
    if (!_datePattern.hasMatch(date)) {
      setState(() {
        _errorText =
            'Effective date must be YYYY-MM-DD (e.g. 2026-06-01).';
      });
      return;
    }
    Navigator.of(context).pop(
      KeyedServicePeriodAccuracyDraft(
        servicePeriodKey: key,
        coversSource: _covers,
        wageSource: _wage,
        effectiveAtBusinessDateIso: date,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: kKeyedServicePeriodAccuracyDialogKey,
      title: Text(
        _editingExisting
            ? 'Edit ${widget.existing!.servicePeriodKey}'
            : 'Add a service-period override',
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: kKeyedServicePeriodAccuracyKeyFieldKey,
                controller: _keyCtl,
                enabled: !_editingExisting,
                decoration: const InputDecoration(
                  labelText: 'Service period key',
                  helperText:
                      'Lowercase. Examples: lunch, dinner, breakfast, brunch.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: kKeyedServicePeriodAccuracyEffectiveDateFieldKey,
                controller: _dateCtl,
                decoration: const InputDecoration(
                  labelText: 'Effective from (business date)',
                  helperText: 'YYYY-MM-DD. Future dates stage the change.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ServicePeriodCoversSource>(
                key: kKeyedServicePeriodAccuracyCoversFieldKey,
                initialValue: _covers,
                decoration: const InputDecoration(
                  labelText: 'Covers source',
                  border: OutlineInputBorder(),
                ),
                items: ServicePeriodCoversSource.values
                    .map(
                      (s) => DropdownMenuItem<ServicePeriodCoversSource>(
                        value: s,
                        child: Text(_coversLabel(s)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value != null) setState(() => _covers = value);
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ServicePeriodWageSource>(
                key: kKeyedServicePeriodAccuracyWageFieldKey,
                initialValue: _wage,
                decoration: const InputDecoration(
                  labelText: 'Wage source',
                  border: OutlineInputBorder(),
                ),
                items: ServicePeriodWageSource.values
                    .map(
                      (s) => DropdownMenuItem<ServicePeriodWageSource>(
                        value: s,
                        child: Text(_wageLabel(s)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (value) {
                  if (value != null) setState(() => _wage = value);
                },
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 12),
                Text(
                  _errorText!,
                  key: const Key(
                    'data_accuracy_keyed_service_period_dialog_error',
                  ),
                  style: AppTextStyles.body12(color: AppColors.warning),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: kKeyedServicePeriodAccuracyCancelKey,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: kKeyedServicePeriodAccuracySubmitKey,
          onPressed: _submit,
          child: Text(_editingExisting ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}

String _coversLabel(ServicePeriodCoversSource source) {
  switch (source) {
    case ServicePeriodCoversSource.vendor:
      return 'Vendor (POS) feed';
    case ServicePeriodCoversSource.forecast:
      return 'Forecast substitution';
    case ServicePeriodCoversSource.manual:
      return 'Manual entry';
    case ServicePeriodCoversSource.reservationPlusWalkin:
      return 'Reservations + walk-ins';
  }
}

String _wageLabel(ServicePeriodWageSource source) {
  switch (source) {
    case ServicePeriodWageSource.vendorPerEmployee:
      return 'Vendor (per employee)';
    case ServicePeriodWageSource.vendorPerPosition:
      return 'Vendor (per position)';
    case ServicePeriodWageSource.targetSubstitution:
      return 'Target substitution';
    case ServicePeriodWageSource.manualMix:
      return 'Manual mix';
  }
}
