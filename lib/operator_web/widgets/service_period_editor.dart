// Phase 11W.7 / Wave A2 - Service period editor widget.
//
// The editor enforces the four binding rules from
// docs/phases/phase_business_timing_live/business_timing_live_plan.md
// "Canonical Rules" section, client-side, BEFORE submit:
//
//   1. 1-4 service periods.
//   2. Quarter-hour boundaries (minutes in {0,15,30,45}).
//   3. No two periods overlap on the same business date.
//   4. At most one period rolls past midnight.
//
// Server still enforces the same rules (the route contract pins the
// error codes); the client-side validator gives operators an
// instant explanation rather than a round-trip 400.
//
// The widget exposes `ServicePeriodEditorController` so screens can
// observe state and submit only when `isValid`. Validation logic
// lives in `validateServicePeriods` as a pure function so tests can
// pin every rule without rendering Flutter widgets.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Pure value object for a service period in the editor. Times use
/// "HH:MM" 24-hour local strings to match the route contract.
@immutable
class ServicePeriodDraft {
  const ServicePeriodDraft({
    required this.key,
    required this.label,
    required this.startLocal,
    required this.endLocal,
  });

  final String key;
  final String label;
  final String startLocal;
  final String endLocal;

  /// True when the end time is at or before the start time (mod 24h),
  /// meaning the period wraps past midnight. e.g. 22:00 -> 01:00.
  bool get rollsPastMidnight {
    final start = _minutesOrNull(startLocal);
    final end = _minutesOrNull(endLocal);
    if (start == null || end == null) return false;
    return end <= start;
  }

  ServicePeriodDraft copyWith({
    String? key,
    String? label,
    String? startLocal,
    String? endLocal,
  }) =>
      ServicePeriodDraft(
        key: key ?? this.key,
        label: label ?? this.label,
        startLocal: startLocal ?? this.startLocal,
        endLocal: endLocal ?? this.endLocal,
      );
}

/// Pure validation result. Empty errors list means the draft is
/// servable to the gateway.
@immutable
class ServicePeriodValidation {
  const ServicePeriodValidation({required this.errors, required this.warnings});

  final List<ServicePeriodValidationError> errors;
  final List<String> warnings;

  bool get isValid => errors.isEmpty;
}

@immutable
class ServicePeriodValidationError {
  const ServicePeriodValidationError({
    required this.code,
    required this.message,
    this.periodIndex,
  });

  /// Stable code mirroring the proxy error codes. Tests pin these.
  final String code;
  final String message;
  final int? periodIndex;
}

/// Validates a draft set of service periods against the four binding
/// rules. Pure function; safe to call from anywhere.
///
/// When [businessDayStartLocal] is supplied (HH:MM, quarter-hour), the
/// validator additionally enforces business_timing_live_plan.md rule
/// 13: the business day start must NOT fall inside any service
/// period. Backend enforces the same rule and returns
/// `business_day_start_inside_period`; surfacing it client-side gives
/// the operator an inline error rather than a 400 round-trip.
ServicePeriodValidation validateServicePeriods(
  List<ServicePeriodDraft> draft, {
  String? businessDayStartLocal,
}) {
  final errors = <ServicePeriodValidationError>[];
  final warnings = <String>[];

  if (draft.isEmpty) {
    errors.add(
      const ServicePeriodValidationError(
        code: 'invalid_period_count',
        message: 'Add at least one service period before saving.',
      ),
    );
    return ServicePeriodValidation(errors: errors, warnings: warnings);
  }
  if (draft.length > 4) {
    errors.add(
      ServicePeriodValidationError(
        code: 'invalid_period_count',
        message:
            'A business day can have up to four service periods. You have '
            '${draft.length}; remove one to save.',
      ),
    );
  }

  final keys = <String>{};
  for (var i = 0; i < draft.length; i++) {
    final period = draft[i];

    if (period.key.trim().isEmpty || !_keyPattern.hasMatch(period.key)) {
      errors.add(
        ServicePeriodValidationError(
          code: 'invalid_service_period_key',
          message:
              'The key for "${period.label.isEmpty ? "service period ${i + 1}" : period.label}" '
              'must start with a letter and use only lowercase letters, numbers, '
              'or underscores.',
          periodIndex: i,
        ),
      );
    } else if (!keys.add(period.key)) {
      errors.add(
        ServicePeriodValidationError(
          code: 'duplicate_service_period_key',
          message:
              'Two service periods share the key "${period.key}". Each key '
              'must be unique.',
          periodIndex: i,
        ),
      );
    }

    if (period.label.trim().isEmpty) {
      errors.add(
        ServicePeriodValidationError(
          code: 'invalid_service_period_label',
          message: 'Service period ${i + 1} needs a label your team will see.',
          periodIndex: i,
        ),
      );
    }

    if (!_isQuarterHour(period.startLocal)) {
      errors.add(
        ServicePeriodValidationError(
          code: 'invalid_quarter_hour_boundary',
          message:
              'Start time for "${period.label.isEmpty ? "service period ${i + 1}" : period.label}" '
              'must land on a quarter hour (00, 15, 30, or 45 minutes past).',
          periodIndex: i,
        ),
      );
    }
    if (!_isQuarterHour(period.endLocal)) {
      errors.add(
        ServicePeriodValidationError(
          code: 'invalid_quarter_hour_boundary',
          message:
              'End time for "${period.label.isEmpty ? "service period ${i + 1}" : period.label}" '
              'must land on a quarter hour (00, 15, 30, or 45 minutes past).',
          periodIndex: i,
        ),
      );
    }

    final startMin = _minutesOrNull(period.startLocal);
    final endMin = _minutesOrNull(period.endLocal);
    if (startMin != null && endMin != null && startMin == endMin) {
      errors.add(
        ServicePeriodValidationError(
          code: 'invalid_service_period_range',
          message:
              'The start and end times for "${period.label.isEmpty ? "service period ${i + 1}" : period.label}" '
              'cannot be the same. A service period needs to last at least '
              '15 minutes.',
          periodIndex: i,
        ),
      );
    }
  }

  final pastMidnight = draft.where((p) => p.rollsPastMidnight).toList();
  if (pastMidnight.length > 1) {
    errors.add(
      const ServicePeriodValidationError(
        code: 'multiple_past_midnight_periods',
        message:
            'Only one service period can stretch past midnight. Two of your '
            'periods currently do; trim one so it ends by midnight.',
      ),
    );
  }

  // Overlap detection only runs when no per-period error has been
  // recorded for the involved indices, so the operator first sees the
  // simpler "fix this time" error before the more complex overlap.
  for (var i = 0; i < draft.length; i++) {
    for (var j = i + 1; j < draft.length; j++) {
      final a = draft[i];
      final b = draft[j];
      if (!_isQuarterHour(a.startLocal) ||
          !_isQuarterHour(a.endLocal) ||
          !_isQuarterHour(b.startLocal) ||
          !_isQuarterHour(b.endLocal)) {
        continue;
      }
      if (_periodsOverlap(a, b)) {
        errors.add(
          ServicePeriodValidationError(
            code: 'service_period_overlap',
            message:
                '"${a.label.isEmpty ? "service period ${i + 1}" : a.label}" and '
                '"${b.label.isEmpty ? "service period ${j + 1}" : b.label}" '
                'overlap. Service periods cannot share any minutes on the same '
                'business date.',
            periodIndex: j,
          ),
        );
      }
    }
  }

  if (pastMidnight.length == 1) {
    warnings.add(
      '"${pastMidnight.first.label}" stretches past midnight. Make sure '
      'closing duties are scheduled for the right business date.',
    );
  }

  // Rule 13 from business_timing_live_plan.md: business day start
  // cannot fall inside any service period. Surface client-side so the
  // operator does not have to round-trip a 400 just to learn.
  final dayStart = businessDayStartLocal == null
      ? null
      : _minutesOrNull(businessDayStartLocal);
  if (dayStart != null) {
    for (var i = 0; i < draft.length; i++) {
      final p = draft[i];
      if (!_isQuarterHour(p.startLocal) || !_isQuarterHour(p.endLocal)) {
        continue;
      }
      final startMin = _minutesOrNull(p.startLocal);
      final endMin = _minutesOrNull(p.endLocal);
      if (startMin == null || endMin == null) continue;
      final inside = p.rollsPastMidnight
          ? (dayStart >= startMin || dayStart < endMin)
          : (dayStart >= startMin && dayStart < endMin);
      if (inside) {
        errors.add(
          ServicePeriodValidationError(
            code: 'business_day_start_inside_period',
            message:
                'The business day start ($businessDayStartLocal) lands '
                'inside "${p.label.isEmpty ? "service period ${i + 1}" : p.label}". '
                'Move the day start outside that window or trim the period.',
            periodIndex: i,
          ),
        );
        break;
      }
    }
  }

  return ServicePeriodValidation(errors: errors, warnings: warnings);
}

bool _isQuarterHour(String hhmm) {
  final minutes = _minutesOrNull(hhmm);
  if (minutes == null) return false;
  return minutes % 15 == 0;
}

int? _minutesOrNull(String hhmm) {
  final match = _hhmmPattern.firstMatch(hhmm);
  if (match == null) return null;
  final h = int.tryParse(match.group(1) ?? '');
  final m = int.tryParse(match.group(2) ?? '');
  if (h == null || m == null) return null;
  if (h < 0 || h > 23) return null;
  if (m < 0 || m > 59) return null;
  return h * 60 + m;
}

bool _periodsOverlap(ServicePeriodDraft a, ServicePeriodDraft b) {
  // Convert each draft to one or two [startMin, endMin) windows on a
  // 0..1440 timeline. A past-midnight period contributes two windows:
  // [start, 1440) and [0, end). Then any pairwise window intersection
  // counts as overlap.
  final windowsA = _toWindows(a);
  final windowsB = _toWindows(b);
  for (final wa in windowsA) {
    for (final wb in windowsB) {
      if (wa.start < wb.end && wb.start < wa.end) return true;
    }
  }
  return false;
}

class _Window {
  const _Window(this.start, this.end);
  final int start;
  final int end;
}

List<_Window> _toWindows(ServicePeriodDraft p) {
  final start = _minutesOrNull(p.startLocal);
  final end = _minutesOrNull(p.endLocal);
  if (start == null || end == null) return const <_Window>[];
  if (end > start) {
    return <_Window>[_Window(start, end)];
  }
  // Past midnight: split into two windows.
  return <_Window>[_Window(start, 1440), _Window(0, end)];
}

final RegExp _hhmmPattern = RegExp(r'^(\d{2}):(\d{2})$');
final RegExp _keyPattern = RegExp(r'^[a-z][a-z0-9_]{0,63}$');

/// Editor widget. Hosts a list of [ServicePeriodDraft] rows, an
/// "Add period" button (disabled when at the four-period cap), and a
/// validation banner. The screen listens to [controller] and calls
/// the gateway only when [ServicePeriodEditorController.validation.isValid].
class ServicePeriodEditor extends StatefulWidget {
  const ServicePeriodEditor({
    super.key,
    required this.controller,
    this.maxPeriods = 4,
  });

  final ServicePeriodEditorController controller;
  final int maxPeriods;

  @override
  State<ServicePeriodEditor> createState() => _ServicePeriodEditorState();
}

class _ServicePeriodEditorState extends State<ServicePeriodEditor> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleChange);
    super.dispose();
  }

  void _handleChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final periods = controller.periods;
    final canAdd = periods.length < widget.maxPeriods;
    return Column(
      key: const Key('service_period_editor'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < periods.length; i++) ...[
          _ServicePeriodRow(
            key: ValueKey('service_period_editor_row_$i'),
            index: i,
            period: periods[i],
            onChanged: (next) => controller.updateAt(i, next),
            onRemove: periods.length > 1
                ? () => controller.removeAt(i)
                : null,
            errors: controller.validation.errors
                .where((e) => e.periodIndex == i)
                .toList(),
          ),
          if (i != periods.length - 1) const SizedBox(height: 12),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('service_period_editor_add'),
            onPressed: canAdd ? controller.addPeriod : null,
            icon: const Icon(Icons.add, size: 16),
            label: Text(
              canAdd
                  ? 'Add service period'
                  : 'Up to ${widget.maxPeriods} service periods',
            ),
          ),
        ),
        const SizedBox(height: 14),
        _ValidationBanner(validation: controller.validation),
      ],
    );
  }
}

class _ServicePeriodRow extends StatefulWidget {
  const _ServicePeriodRow({
    super.key,
    required this.index,
    required this.period,
    required this.onChanged,
    required this.errors,
    this.onRemove,
  });

  final int index;
  final ServicePeriodDraft period;
  final ValueChanged<ServicePeriodDraft> onChanged;
  final VoidCallback? onRemove;
  final List<ServicePeriodValidationError> errors;

  @override
  State<_ServicePeriodRow> createState() => _ServicePeriodRowState();
}

class _ServicePeriodRowState extends State<_ServicePeriodRow> {
  late final TextEditingController _label;
  late final TextEditingController _key;
  late final TextEditingController _start;
  late final TextEditingController _end;

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(text: widget.period.label);
    _key = TextEditingController(text: widget.period.key);
    _start = TextEditingController(text: widget.period.startLocal);
    _end = TextEditingController(text: widget.period.endLocal);
  }

  @override
  void didUpdateWidget(covariant _ServicePeriodRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.period.label != widget.period.label) {
      _label.text = widget.period.label;
    }
    if (oldWidget.period.key != widget.period.key) {
      _key.text = widget.period.key;
    }
    if (oldWidget.period.startLocal != widget.period.startLocal) {
      _start.text = widget.period.startLocal;
    }
    if (oldWidget.period.endLocal != widget.period.endLocal) {
      _end.text = widget.period.endLocal;
    }
  }

  @override
  void dispose() {
    _label.dispose();
    _key.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pastMidnight = widget.period.rollsPastMidnight;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Service period ${widget.index + 1}',
                  style: AppTextStyles.mono11(color: AppColors.sunsetDark),
                ),
              ),
              if (pastMidnight)
                Container(
                  key: ValueKey(
                    'service_period_editor_past_midnight_${widget.index}',
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.peacockDark.withValues(alpha: 0.12),
                    border: Border.all(
                      color: AppColors.peacockDark.withValues(alpha: 0.45),
                    ),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'Rolls past midnight',
                    style: AppTextStyles.mono8(color: AppColors.peacockDark),
                  ),
                ),
              if (widget.onRemove != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  key: ValueKey(
                    'service_period_editor_remove_${widget.index}',
                  ),
                  onPressed: widget.onRemove,
                  tooltip: 'Remove this service period',
                  icon: const Icon(
                    Icons.close,
                    size: 16,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: ValueKey(
                    'service_period_editor_label_${widget.index}',
                  ),
                  controller: _label,
                  decoration: const InputDecoration(
                    labelText: 'Label your team sees',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => widget.onChanged(
                    widget.period.copyWith(label: value),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 160,
                child: TextField(
                  key: ValueKey('service_period_editor_key_${widget.index}'),
                  controller: _key,
                  decoration: const InputDecoration(
                    labelText: 'Stable key',
                    border: OutlineInputBorder(),
                    helperText: 'lower_snake_case',
                  ),
                  onChanged: (value) => widget.onChanged(
                    widget.period.copyWith(key: value),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              SizedBox(
                width: 130,
                child: TextField(
                  key: ValueKey(
                    'service_period_editor_start_${widget.index}',
                  ),
                  controller: _start,
                  decoration: const InputDecoration(
                    labelText: 'Starts (HH:MM)',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => widget.onChanged(
                    widget.period.copyWith(startLocal: value),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 130,
                child: TextField(
                  key: ValueKey('service_period_editor_end_${widget.index}'),
                  controller: _end,
                  decoration: const InputDecoration(
                    labelText: 'Ends (HH:MM)',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => widget.onChanged(
                    widget.period.copyWith(endLocal: value),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Use 15-minute increments (00, 15, 30, or 45).',
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
              ),
            ],
          ),
          if (widget.errors.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final error in widget.errors)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  error.message,
                  key: ValueKey(
                    'service_period_editor_error_${widget.index}_${error.code}',
                  ),
                  style: AppTextStyles.body12(color: AppColors.negative),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ValidationBanner extends StatelessWidget {
  const _ValidationBanner({required this.validation});

  final ServicePeriodValidation validation;

  @override
  Widget build(BuildContext context) {
    final globalErrors = validation.errors
        .where((e) => e.periodIndex == null)
        .toList();
    if (globalErrors.isEmpty && validation.warnings.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      key: const Key('service_period_editor_banner'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final error in globalErrors)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.negative.withValues(alpha: 0.10),
              border: Border.all(
                color: AppColors.negative.withValues(alpha: 0.45),
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 16,
                  color: AppColors.negative,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    error.message,
                    key: Key(
                      'service_period_editor_banner_error_${error.code}',
                    ),
                    style: AppTextStyles.body13(color: AppColors.negative),
                  ),
                ),
              ],
            ),
          ),
        for (final warning in validation.warnings)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.peacockDark.withValues(alpha: 0.10),
              border: Border.all(
                color: AppColors.peacockDark.withValues(alpha: 0.45),
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.info_outline,
                  size: 16,
                  color: AppColors.peacockDark,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    warning,
                    style: AppTextStyles.body13(color: AppColors.peacockDark),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Mutable controller for [ServicePeriodEditor]. Screens hold one of
/// these, listen for changes, and call [periods] when ready to
/// submit (only when [validation.isValid]).
class ServicePeriodEditorController extends ChangeNotifier {
  ServicePeriodEditorController({
    required List<ServicePeriodDraft> initial,
    String? businessDayStartLocal,
  })  : _periods = List<ServicePeriodDraft>.from(initial),
        _businessDayStartLocal = businessDayStartLocal;

  List<ServicePeriodDraft> _periods;
  String? _businessDayStartLocal;

  List<ServicePeriodDraft> get periods =>
      List<ServicePeriodDraft>.unmodifiable(_periods);

  /// Optional business-day start that participates in rule 13
  /// validation (business_day_start_inside_period). When the parent
  /// screen owns this state, it should call [setBusinessDayStartLocal]
  /// whenever the field changes so the validation banner stays in
  /// sync.
  String? get businessDayStartLocal => _businessDayStartLocal;

  ServicePeriodValidation get validation => validateServicePeriods(
        _periods,
        businessDayStartLocal: _businessDayStartLocal,
      );

  void updateAt(int index, ServicePeriodDraft next) {
    if (index < 0 || index >= _periods.length) return;
    _periods[index] = next;
    notifyListeners();
  }

  void addPeriod({ServicePeriodDraft? template}) {
    if (_periods.length >= 4) return;
    _periods.add(
      template ??
          ServicePeriodDraft(
            key: 'period_${_periods.length + 1}',
            label: '',
            startLocal: '00:00',
            endLocal: '00:00',
          ),
    );
    notifyListeners();
  }

  void removeAt(int index) {
    if (_periods.length <= 1) return;
    if (index < 0 || index >= _periods.length) return;
    _periods.removeAt(index);
    notifyListeners();
  }

  void replaceAll(List<ServicePeriodDraft> next) {
    _periods = List<ServicePeriodDraft>.from(next);
    notifyListeners();
  }

  /// Updates the business-day start used by rule-13 validation. Pass
  /// null to clear the check (e.g. when the field is cleared).
  void setBusinessDayStartLocal(String? next) {
    if (_businessDayStartLocal == next) return;
    _businessDayStartLocal = next;
    notifyListeners();
  }
}
