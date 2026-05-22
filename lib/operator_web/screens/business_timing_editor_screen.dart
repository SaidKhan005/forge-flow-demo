// Phase 11W.7 / Wave A2 - Business Timing Editor screen.
//
// Effective-dated edits for an operator's business timing profile.
// The screen is reached from BusinessSetupScreen's "Edit timing"
// button; that screen stays the read view (inheritance / effective
// fields / current periods).
//
// Every write goes through `WebBusinessTimingGateway` against the
// operator-scoped routes:
//
//   POST   /v1/operator/business-timing-profiles
//   PATCH  /v1/operator/business-timing-profiles/:id
//   POST   /v1/operator/business-timing-profiles/:id/service-periods
//   PATCH  /v1/operator/business-timing-profiles/:id/service-periods/:key
//
// The four binding rules from business_timing_live_plan.md are
// enforced client-side BEFORE submit by `validateServicePeriods`
// (in widgets/service_period_editor.dart) so the operator gets an
// instant explanation. The proxy still validates server-side.
//
// Lane 0 / A0 decision (`profile_id` doubles as `version_id` at V1)
// means the screen never asks the operator to "pick a version" - new
// effective-dated edits get a fresh profile_id on the server.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/permission_keys.dart';
import '../../services/business_timing/business_timing_profile_validator.dart';
import '../../services/business_timing/business_timing_starter_profile.dart';
import '../../theme/app_theme.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/operator_web_proxy_client.dart';
import '../services/web_business_timing_gateway.dart';
import '../widgets/operator_web_info_button.dart';
import '../widgets/operator_web_section_heading.dart';
import '../widgets/service_period_editor.dart';

const String _kBusinessTimingEditPermission =
    PermissionKeys.businessTimingConfigure;

@immutable
class BusinessTimingHierarchyPathEntry {
  const BusinessTimingHierarchyPathEntry({
    required this.scopeKind,
    required this.scopeId,
    required this.name,
    required this.helper,
    this.unitType,
  });

  final String scopeKind;
  final String scopeId;
  final String name;
  final String helper;
  final String? unitType;
}

class BusinessTimingEditorScreen extends StatefulWidget {
  const BusinessTimingEditorScreen({
    super.key,
    required this.session,
    this.locationId,
    this.locationName,
    this.orgUnitId,
    this.orgUnitName,
    this.orgUnitHelper,
    this.initialScopeKind,
    this.gateway,
    this.existingProfile,
    this.initialEffectiveAt,
    this.hierarchyPath = const <BusinessTimingHierarchyPathEntry>[],
    this.scheduleMode = false,
    this.onClose,
  });

  final OperatorWebSession session;
  final String? locationId;
  final String? locationName;
  final String? orgUnitId;
  final String? orgUnitName;
  final String? orgUnitHelper;
  final String? initialScopeKind;
  final WebBusinessTimingGateway? gateway;
  final BusinessTimingProfileWriteResult? existingProfile;
  final DateTime? initialEffectiveAt;
  final List<BusinessTimingHierarchyPathEntry> hierarchyPath;
  final bool scheduleMode;
  final VoidCallback? onClose;

  // G7d (spec §2.B/§3): v2 catalog constant; phantom
  // `'operator_admin'` role check dropped (folded into
  // `operator_owner`). Live-path neutral — the permission-key
  // clause is authoritative for real (snapshot-hydrated) sessions.
  bool get canEdit =>
      session.roles.contains(PermissionKeys.roleOperatorOwner) ||
      session.permissions.contains(_kBusinessTimingEditPermission);

  @override
  State<BusinessTimingEditorScreen> createState() =>
      _BusinessTimingEditorScreenState();
}

class _BusinessTimingEditorScreenState
    extends State<BusinessTimingEditorScreen> {
  late ServicePeriodEditorController _periods;
  late TextEditingController _businessDayStartLocal;
  late TextEditingController _ianaTimezone;
  late DateTime _effectiveAt;

  /// Default to operator-scope: a brand-new operator typically has no
  /// timing profile yet, and the first profile they write is the
  /// operator default. Location overrides come later. Matches the
  /// dropdown copy that labels operator scope as "(default)".
  String _scopeKind = 'operator';
  String _weekStartDay = kStarterBusinessTimingWeekStartDayWire;

  bool _submitting = false;
  String? _error;
  String? _success;
  Timer? _successTimer;

  @override
  void initState() {
    super.initState();
    final existing = widget.existingProfile;
    _periods = ServicePeriodEditorController(
      initial: existing == null
          ? kStarterBusinessTimingServicePeriods
                .map(
                  (p) => ServicePeriodDraft(
                    key: p.key,
                    label: p.label,
                    startLocal: p.startLocal,
                    endLocal: p.endLocal,
                    applicableDays: List<int>.from(p.applicableDays),
                    shortLabel: p.shortLabel,
                    sortOrder: p.sortOrder,
                  ),
                )
                .toList()
          // Slice 2.5 / Gap 28: carry the three editor-side fields
          // through from the existing profile. The gateway's
          // ServicePeriod already defaults applicableDays /
          // shortLabel / sortOrder to safe values when the server
          // omits them, so old payloads land here as 7-day, '', 0.
          : existing.servicePeriods
                .map(
                  (p) => ServicePeriodDraft(
                    key: p.key,
                    label: p.label,
                    startLocal: p.startLocal,
                    endLocal: p.endLocal,
                    applicableDays: List<int>.from(p.applicableDays),
                    shortLabel: p.shortLabel,
                    sortOrder: p.sortOrder,
                  ),
                )
                .toList(),
    );
    final initialDayStart =
        existing?.businessDayStartLocal ??
        (widget.session.rolloverHour != null
            ? '${widget.session.rolloverHour!.toString().padLeft(2, '0')}:00'
            : kStarterBusinessTimingDayStartLocal);
    _businessDayStartLocal = TextEditingController(text: initialDayStart);
    _ianaTimezone = TextEditingController(text: _initialTimezone);
    _businessDayStartLocal.addListener(_handleDayStartChanged);
    // Seed the controller's day-start so the validator picks up rule
    // 13 (business_day_start_inside_period) on the first paint.
    Future<void>.microtask(() {
      if (!mounted) return;
      _periods.setBusinessDayStartLocal(initialDayStart);
    });
    _effectiveAt = widget.initialEffectiveAt ?? DateTime.now();
    if (existing != null) {
      _scopeKind = existing.scopeKind;
      _weekStartDay = existing.weekStartDay;
    } else if (_isSupportedScopeKind(widget.initialScopeKind)) {
      _scopeKind = widget.initialScopeKind!;
    } else if (widget.session.weekStartDay != null) {
      _weekStartDay = widget.session.weekStartDay!;
    }
    _scopeKind = _normalizedScopeKind(_scopeKind);
    _periods.addListener(_handleEditorChange);
  }

  @override
  void dispose() {
    _periods.removeListener(_handleEditorChange);
    _periods.dispose();
    _businessDayStartLocal.removeListener(_handleDayStartChanged);
    _businessDayStartLocal.dispose();
    _ianaTimezone.dispose();
    _successTimer?.cancel();
    super.dispose();
  }

  void _handleEditorChange() {
    if (mounted) setState(() {});
  }

  void _handleDayStartChanged() {
    final value = _businessDayStartLocal.text.trim();
    _periods.setBusinessDayStartLocal(value.isEmpty ? null : value);
  }

  bool get _hasGateway => widget.gateway != null;

  bool get _hasOrgUnitScope => _orgUnitId != null;

  String? get _orgUnitId {
    final provided = widget.orgUnitId?.trim();
    if (provided != null && provided.isNotEmpty) return provided;
    final existing = widget.existingProfile;
    if (existing != null && existing.scopeKind == 'org_unit') {
      final id = existing.scopeId.trim();
      if (id.isNotEmpty) return id;
    }
    return null;
  }

  String _normalizedScopeKind(String value) {
    if (value == 'org_unit' && _hasOrgUnitScope) return value;
    if (value == 'location' && _locationId.isNotEmpty) return value;
    return 'operator';
  }

  bool _isSupportedScopeKind(String? value) {
    if (value == null) return false;
    return value == 'operator' ||
        (value == 'org_unit' && _hasOrgUnitScope) ||
        (value == 'location' && _locationId.isNotEmpty);
  }

  String get _scopeId {
    switch (_scopeKind) {
      case 'operator':
        return widget.session.operatorId;
      case 'org_unit':
        return _orgUnitId ?? '';
      case 'location':
      default:
        return _locationId;
    }
  }

  String get _locationId {
    final provided = widget.locationId?.trim();
    if (provided != null && provided.isNotEmpty) return provided;
    return widget.session.primaryLocationId?.trim() ?? '';
  }

  String get _initialTimezone {
    final existing = widget.existingProfile?.ianaTimezone.trim();
    if (existing != null && existing.isNotEmpty) return existing;
    final sessionTimezone = widget.session.primaryLocationTimezone?.trim();
    if (sessionTimezone != null && sessionTimezone.isNotEmpty) {
      return sessionTimezone;
    }
    return 'UTC';
  }

  String get _timezoneForSave {
    final draft = _ianaTimezone.text.trim();
    return draft.isNotEmpty ? draft : 'UTC';
  }

  BusinessTimingProfileWriteResult? get _existingProfileForSelectedScope {
    final existing = widget.existingProfile;
    if (existing == null) return null;
    return existing.scopeKind == _scopeKind && existing.scopeId == _scopeId
        ? existing
        : null;
  }

  void _resetToExistingProfile() {
    final existing = widget.existingProfile;
    if (existing == null || _submitting) return;
    setState(() {
      _scopeKind = _normalizedScopeKind(existing.scopeKind);
      _effectiveAt =
          DateTime.tryParse(existing.effectiveAtBusinessDate) ?? _effectiveAt;
      _ianaTimezone.text = existing.ianaTimezone;
      _weekStartDay = existing.weekStartDay;
      _businessDayStartLocal.text = existing.businessDayStartLocal;
      _periods.replaceAll(
        existing.servicePeriods
            .map(
              (p) => ServicePeriodDraft(
                key: p.key,
                label: p.label,
                startLocal: p.startLocal,
                endLocal: p.endLocal,
                applicableDays: List<int>.from(p.applicableDays),
                shortLabel: p.shortLabel,
                sortOrder: p.sortOrder,
              ),
            )
            .toList(),
      );
      _error = null;
      _success = null;
    });
  }

  Future<void> _save() async {
    final gateway = widget.gateway;
    if (gateway == null || !widget.canEdit) return;
    final validation = _periods.validation;
    if (!validation.isValid) {
      setState(() {
        _error = 'Fix the highlighted issues before saving.';
      });
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
      _success = null;
    });
    try {
      final existingForScope = _existingProfileForSelectedScope;
      if (existingForScope == null) {
        await gateway.createProfile(
          BusinessTimingProfileCreate(
            scopeKind: _scopeKind,
            scopeId: _scopeId,
            effectiveAtBusinessDate: _formatBusinessDate(_effectiveAt),
            ianaTimezone: _timezoneForSave,
            weekStartDay: _weekStartDay,
            businessDayStartLocal: normalizeBusinessTimingTimeInput(
              _businessDayStartLocal.text,
            ).trim(),
            // Slice 2.5 / Gap 28: carry applicableDays / shortLabel /
            // sortOrder through to the wire so day-restricted periods
            // (e.g. "Weekend Brunch" Sat/Sun) round-trip end-to-end.
            servicePeriods: _periods.periods
                .map(
                  (p) => ServicePeriodCreate(
                    key: p.key,
                    label: p.label,
                    startLocal: p.startLocal,
                    endLocal: p.endLocal,
                    applicableDays: List<int>.from(p.applicableDays),
                    shortLabel: p.shortLabel,
                    sortOrder: p.sortOrder,
                  ),
                )
                .toList(),
          ),
        );
      } else {
        await gateway.updateProfile(
          profileId: existingForScope.profileId,
          patch: BusinessTimingProfilePatch(
            scopeKind: _scopeKind,
            scopeId: _scopeId,
            effectiveAtBusinessDate: _formatBusinessDate(_effectiveAt),
            ianaTimezone: _timezoneForSave,
            weekStartDay: _weekStartDay,
            businessDayStartLocal: normalizeBusinessTimingTimeInput(
              _businessDayStartLocal.text,
            ).trim(),
            // Slice 2.5 / Gap 28: same as createProfile above — the
            // patch's whole-set semantics REPLACE the server's period
            // list, so we must supply the new fields each save.
            servicePeriods: _periods.periods
                .map(
                  (p) => ServicePeriodCreate(
                    key: p.key,
                    label: p.label,
                    startLocal: p.startLocal,
                    endLocal: p.endLocal,
                    applicableDays: List<int>.from(p.applicableDays),
                    shortLabel: p.shortLabel,
                    sortOrder: p.sortOrder,
                  ),
                )
                .toList(),
          ),
        );
      }
    } on OperatorWebProxyException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Could not save business timing: $error';
      });
      return;
    }
    if (!mounted) return;
    _successTimer?.cancel();
    setState(() {
      _submitting = false;
      _success =
          'Saved. New timing takes effect '
          '${_formatBusinessDate(_effectiveAt)}.';
    });
    _successTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _success = null);
    });
  }

  String _formatBusinessDate(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';

  String get _headingText {
    if (widget.scheduleMode) return 'Schedule service periods';
    return 'Edit service periods';
  }

  String get _saveButtonText {
    if (widget.scheduleMode) return 'Schedule service periods';
    return widget.existingProfile == null
        ? 'Save service periods'
        : 'Save service periods';
  }

  Future<void> _pickEffectiveDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: _effectiveAt,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (selected != null) {
      setState(() => _effectiveAt = selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const Key('operator_web_business_timing_editor_screen'),
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.schedule_outlined,
                size: 22,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _headingText,
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Service periods break the business day into the chunks your '
            'team works in: lunch, dinner, late night, and so on. You '
            'can have one to four. Already closed days keep the timing '
            'they were closed with.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 18),
          if (!_hasGateway) const _UnavailableBanner(),
          if (!_hasGateway) const SizedBox(height: 14),
          if (!widget.canEdit) const _ReadOnlyBanner(),
          if (!widget.canEdit) const SizedBox(height: 14),
          _ScopeAndEffectiveSection(
            effectiveAt: _effectiveAt,
            timezoneController: _ianaTimezone,
            businessDayStartController: _businessDayStartLocal,
            weekStartDay: _weekStartDay,
            enabled: widget.canEdit && !_submitting,
            onPickEffectiveDate: _pickEffectiveDate,
            onWeekStartChanged: (next) =>
                setState(() => _weekStartDay = next ?? _weekStartDay),
            onAnyTextChanged: () => setState(() {}),
            formatter: _formatBusinessDate,
          ),
          const SizedBox(height: 18),
          OperatorWebSectionHeading(
            title: 'Service periods',
            trailing: OperatorWebInfoButton(
              title: 'Service periods',
              tooltip: 'Service periods',
              body: Text(
                'Use 15-minute increments. Periods cannot overlap, and only '
                'one period can stretch past midnight.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ),
          ),
          const SizedBox(height: 12),
          ServicePeriodEditor(
            controller: _periods,
            key: const Key('operator_web_business_timing_editor_periods'),
          ),
          const SizedBox(height: 18),
          if (_error != null)
            Container(
              key: const Key('operator_web_business_timing_editor_error'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                      _error!,
                      style: AppTextStyles.body13(color: AppColors.negative),
                    ),
                  ),
                ],
              ),
            ),
          if (_success != null)
            Container(
              key: const Key('operator_web_business_timing_editor_success'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.positive.withValues(alpha: 0.10),
                border: Border.all(
                  color: AppColors.positive.withValues(alpha: 0.45),
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.check_circle_outline,
                    size: 16,
                    color: AppColors.positive,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _success!,
                      style: AppTextStyles.body13(color: AppColors.positive),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              SizedBox(
                height: 46,
                child: FilledButton(
                  key: const Key('operator_web_business_timing_editor_save'),
                  onPressed:
                      widget.canEdit &&
                          _hasGateway &&
                          !_submitting &&
                          _periods.validation.isValid
                      ? _save
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.sunset,
                    foregroundColor: AppColors.backgroundSurface,
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.backgroundSurface,
                          ),
                        )
                      : Text(_saveButtonText),
                ),
              ),
              if (widget.existingProfile != null)
                SizedBox(
                  height: 46,
                  child: OutlinedButton.icon(
                    key: const Key('operator_web_business_timing_editor_reset'),
                    onPressed: _submitting ? null : _resetToExistingProfile,
                    icon: const Icon(Icons.undo_outlined, size: 16),
                    label: const Text('Reset to inherited'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String _timezoneLabel(String timezone) {
  final gmt = _kTimezoneGmtLabels[timezone];
  return gmt == null ? timezone : '$timezone ($gmt)';
}

const Map<String, String> _kTimezoneGmtLabels = <String, String>{
  'America/Toronto': 'GMT-05:00 / -04:00',
  'America/New_York': 'GMT-05:00 / -04:00',
  'America/Chicago': 'GMT-06:00 / -05:00',
  'America/Denver': 'GMT-07:00 / -06:00',
  'America/Phoenix': 'GMT-07:00',
  'America/Los_Angeles': 'GMT-08:00 / -07:00',
  'America/Anchorage': 'GMT-09:00 / -08:00',
  'America/Halifax': 'GMT-04:00 / -03:00',
  'America/St_Johns': 'GMT-03:30 / -02:30',
  'America/Vancouver': 'GMT-08:00 / -07:00',
  'America/Edmonton': 'GMT-07:00 / -06:00',
  'America/Winnipeg': 'GMT-06:00 / -05:00',
  'America/Mexico_City': 'GMT-06:00',
  'America/Sao_Paulo': 'GMT-03:00',
  'Europe/London': 'GMT+00:00 / +01:00',
  'Europe/Dublin': 'GMT+00:00 / +01:00',
  'Europe/Paris': 'GMT+01:00 / +02:00',
  'Europe/Berlin': 'GMT+01:00 / +02:00',
  'Europe/Madrid': 'GMT+01:00 / +02:00',
  'Europe/Rome': 'GMT+01:00 / +02:00',
  'Europe/Amsterdam': 'GMT+01:00 / +02:00',
  'Europe/Stockholm': 'GMT+01:00 / +02:00',
  'Europe/Helsinki': 'GMT+02:00 / +03:00',
  'Europe/Athens': 'GMT+02:00 / +03:00',
  'Europe/Istanbul': 'GMT+03:00',
  'Europe/Moscow': 'GMT+03:00',
  'Africa/Johannesburg': 'GMT+02:00',
  'Asia/Dubai': 'GMT+04:00',
  'Asia/Kolkata': 'GMT+05:30',
  'Asia/Singapore': 'GMT+08:00',
  'Asia/Hong_Kong': 'GMT+08:00',
  'Asia/Shanghai': 'GMT+08:00',
  'Asia/Tokyo': 'GMT+09:00',
  'Asia/Seoul': 'GMT+09:00',
  'Australia/Sydney': 'GMT+10:00 / +11:00',
  'Australia/Melbourne': 'GMT+10:00 / +11:00',
  'Australia/Perth': 'GMT+08:00',
  'Pacific/Auckland': 'GMT+12:00 / +13:00',
  'UTC': 'GMT+00:00',
};

class _TimezoneDropdown extends StatelessWidget {
  const _TimezoneDropdown({
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = controller.text.trim().isEmpty
        ? 'UTC'
        : controller.text.trim();
    final options = <String>[
      if (!kBusinessTimingAllowedIanaTimezones.contains(selected)) selected,
      ...kBusinessTimingAllowedIanaTimezones,
    ];

    return DropdownButtonFormField<String>(
      key: const Key('operator_web_business_timing_editor_timezone_dropdown'),
      initialValue: selected,
      decoration: const InputDecoration(
        labelText: 'Timezone',
        border: OutlineInputBorder(),
        helperText: 'Choose the location timezone.',
      ),
      items: options
          .map(
            (timezone) => DropdownMenuItem<String>(
              value: timezone,
              child: Text(_timezoneLabel(timezone)),
            ),
          )
          .toList(growable: false),
      onChanged: enabled
          ? (timezone) {
              if (timezone == null) return;
              controller.text = timezone;
              onChanged();
            }
          : null,
    );
  }
}

void _normalizeBusinessTimingTimeController(
  TextEditingController controller,
  String raw,
) {
  final formatted = normalizeBusinessTimingTimeInput(raw);
  if (formatted == controller.text || formatted == raw) return;
  controller.value = TextEditingValue(
    text: formatted,
    selection: TextSelection.collapsed(offset: formatted.length),
  );
}

class _ScopeAndEffectiveSection extends StatelessWidget {
  const _ScopeAndEffectiveSection({
    required this.effectiveAt,
    required this.timezoneController,
    required this.businessDayStartController,
    required this.weekStartDay,
    required this.enabled,
    required this.onPickEffectiveDate,
    required this.onWeekStartChanged,
    required this.onAnyTextChanged,
    required this.formatter,
  });

  final DateTime effectiveAt;
  final TextEditingController timezoneController;
  final TextEditingController businessDayStartController;
  final String weekStartDay;
  final bool enabled;
  final VoidCallback onPickEffectiveDate;
  final ValueChanged<String?> onWeekStartChanged;
  final VoidCallback onAnyTextChanged;
  final String Function(DateTime) formatter;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_business_timing_editor_scope_card'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  key: const Key(
                    'operator_web_business_timing_editor_effective_pick',
                  ),
                  onTap: enabled ? onPickEffectiveDate : null,
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Take effect on',
                      border: const OutlineInputBorder(),
                      enabled: enabled,
                    ),
                    child: Text(
                      formatter(effectiveAt),
                      style: AppTextStyles.body13(color: AppColors.textPrimary),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _TimezoneDropdown(
                  controller: timezoneController,
                  enabled: enabled,
                  onChanged: onAnyTextChanged,
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 200,
                child: TextField(
                  key: const Key(
                    'operator_web_business_timing_editor_business_day_start',
                  ),
                  controller: businessDayStartController,
                  enabled: enabled,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9:]')),
                    LengthLimitingTextInputFormatter(5),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Business day starts (HH:MM)',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) {
                    _normalizeBusinessTimingTimeController(
                      businessDayStartController,
                      value,
                    );
                    onAnyTextChanged();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const Key('operator_web_business_timing_editor_week_start'),
            initialValue: weekStartDay,
            decoration: const InputDecoration(
              labelText: 'First day of the business week',
              border: OutlineInputBorder(),
            ),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(value: 'monday', child: Text('Monday')),
              DropdownMenuItem<String>(
                value: 'tuesday',
                child: Text('Tuesday'),
              ),
              DropdownMenuItem<String>(
                value: 'wednesday',
                child: Text('Wednesday'),
              ),
              DropdownMenuItem<String>(
                value: 'thursday',
                child: Text('Thursday'),
              ),
              DropdownMenuItem<String>(value: 'friday', child: Text('Friday')),
              DropdownMenuItem<String>(
                value: 'saturday',
                child: Text('Saturday'),
              ),
              DropdownMenuItem<String>(value: 'sunday', child: Text('Sunday')),
            ],
            onChanged: enabled ? onWeekStartChanged : null,
          ),
        ],
      ),
    );
  }
}

class _UnavailableBanner extends StatelessWidget {
  const _UnavailableBanner();
  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_business_timing_editor_unavailable'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 18, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Live editing is not connected yet on this build. You can '
              'fill the form to see the validation, but Save is disabled '
              'until the operator timing write route is online.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner();
  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_business_timing_editor_readonly'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, size: 18, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Operator owners and admins can change business timing. '
              'You can review what is set and request a change from your '
              'admin.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
