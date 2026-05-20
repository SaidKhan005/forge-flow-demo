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

import '../../auth/permission_keys.dart';
import '../../services/business_timing/business_timing_starter_profile.dart';
import '../../theme/app_theme.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/operator_web_proxy_client.dart';
import '../services/web_business_timing_gateway.dart';
import '../widgets/hierarchy_tree_visualization.dart';
import '../widgets/service_period_editor.dart';

const String _kBusinessTimingEditPermission =
    PermissionKeys.businessTimingConfigure;

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

  String get _orgUnitLabel {
    final label = widget.orgUnitName?.trim();
    if (label != null && label.isNotEmpty) return label;
    final existing = widget.existingProfile;
    if (existing != null && existing.scopeKind == 'org_unit') {
      return 'Selected group';
    }
    return 'Selected group';
  }

  String get _orgUnitHelper {
    final helper = widget.orgUnitHelper?.trim();
    if (helper != null && helper.isNotEmpty) return helper;
    return 'Group';
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

  String get _locationLabel {
    final label = widget.locationName?.trim();
    if (label != null && label.isNotEmpty) return label;
    return widget.session.primaryLocationName;
  }

  String get _effectiveTimezone {
    final existing = widget.existingProfile?.ianaTimezone.trim();
    if (existing != null && existing.isNotEmpty) return existing;
    final sessionTimezone = widget.session.primaryLocationTimezone?.trim();
    if (sessionTimezone != null && sessionTimezone.isNotEmpty) {
      return sessionTimezone;
    }
    return 'UTC';
  }

  /// Wave 2 H-2 — builds the visual hierarchy tree's node list from
  /// the session + the currently-selected scope kind. The editor does
  /// not call `BusinessTimingGateway.loadTiming`, so we cannot read a
  /// pre-assembled inheritance chain here — instead we render the two
  /// anchors the session always carries (business + location) and
  /// highlight whichever rung the operator has picked in the scope
  /// dropdown.
  ///
  /// TODO(wave-N): wire full tree once hierarchy reachable — the
  /// session does not carry region / brand identifiers today, so the
  /// tree is best-effort with what IS available. The [dataGapExplainer]
  /// rendered below the tree documents the gap to the operator in
  /// plain English (HP #11 final clause).
  List<HierarchyTreeNodeView> _buildEditorHierarchyNodes() {
    final operatorIsCurrent = _scopeKind == 'operator';
    final orgUnitIsCurrent = _scopeKind == 'org_unit';
    final locationIsCurrent = _scopeKind == 'location';
    final nodes = <HierarchyTreeNodeView>[
      HierarchyTreeNodeView(
        level: HierarchyTreeLevel.business,
        name: widget.session.businessName,
        isCurrentScope: operatorIsCurrent,
        subtitle: operatorIsCurrent
            ? 'This profile becomes the default for every location.'
            : 'Default settings every location inherits from.',
        // When the operator is writing a location override, the
        // deeper row "inherits from" the business row above it.
        inheritsFromHere: !_hasOrgUnitScope && locationIsCurrent,
      ),
    ];
    if (_hasOrgUnitScope) {
      nodes.add(
        HierarchyTreeNodeView(
          level: HierarchyTreeLevel.region,
          name: _orgUnitLabel,
          isCurrentScope: orgUnitIsCurrent,
          subtitle: orgUnitIsCurrent
              ? 'Locations in this group inherit this profile.'
              : 'Group settings between the business and location.',
          inheritsFromHere: locationIsCurrent,
        ),
      );
    }
    if (_locationId.isNotEmpty) {
      nodes.add(
        HierarchyTreeNodeView(
          level: HierarchyTreeLevel.location,
          name: _locationLabel,
          isCurrentScope: locationIsCurrent,
          subtitle: locationIsCurrent
              ? 'This profile overrides the business default here only.'
              : _hasOrgUnitScope
              ? 'Location context for this timing profile.'
              : 'Inherits the business default. No local override yet.',
        ),
      );
    }
    return nodes;
  }

  BusinessTimingProfileWriteResult? get _existingProfileForSelectedScope {
    final existing = widget.existingProfile;
    if (existing == null) return null;
    return existing.scopeKind == _scopeKind && existing.scopeId == _scopeId
        ? existing
        : null;
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
            ianaTimezone: _effectiveTimezone,
            weekStartDay: _weekStartDay,
            businessDayStartLocal: _businessDayStartLocal.text.trim(),
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
            ianaTimezone: _effectiveTimezone,
            weekStartDay: _weekStartDay,
            businessDayStartLocal: _businessDayStartLocal.text.trim(),
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
    if (widget.scheduleMode) return 'Schedule timing change';
    return widget.existingProfile == null
        ? 'New business timing profile'
        : 'Edit business timing profile';
  }

  String get _saveButtonText {
    if (widget.scheduleMode) return 'Schedule timing change';
    return widget.existingProfile == null
        ? 'Save new timing profile'
        : 'Save timing changes';
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
              if (widget.onClose != null)
                IconButton(
                  key: const Key('operator_web_business_timing_editor_close'),
                  onPressed: widget.onClose,
                  tooltip: 'Back to business setup',
                  icon: const Icon(
                    Icons.arrow_back,
                    size: 20,
                    color: AppColors.sunsetDark,
                  ),
                ),
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
            'can have one to four. Pick a future date for the change to '
            'take effect; closed days keep the timing they were closed '
            'with.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 18),
          // Wave 2 H-2: visual hierarchy tree so the operator can see
          // where the profile being edited will land before they
          // commit. The scope dropdown below still owns the choice;
          // this is a read-only visualization of the same selection.
          HierarchyTreeVisualization(
            keyName: 'operator_web_business_timing_editor_hierarchy_tree',
            headline: 'Where this profile will land',
            nodes: _buildEditorHierarchyNodes(),
            dataGapExplainer: _hasOrgUnitScope
                ? 'This tree shows the business, selected group, and location '
                      'this profile applies to.'
                : 'Groups will appear here once your hierarchy is connected. '
                      'Today the tree shows the business and the location this '
                      'profile applies to.',
          ),
          const SizedBox(height: 14),
          if (!_hasGateway) const _UnavailableBanner(),
          if (!_hasGateway) const SizedBox(height: 14),
          if (!widget.canEdit) const _ReadOnlyBanner(),
          if (!widget.canEdit) const SizedBox(height: 14),
          _ScopeAndEffectiveSection(
            scopeKind: _scopeKind,
            hasOrgUnitScope: _hasOrgUnitScope,
            orgUnitLabel: _orgUnitLabel,
            orgUnitHelper: _orgUnitHelper,
            locationLabel: _locationLabel,
            hasLocationScope: _locationId.isNotEmpty,
            effectiveAt: _effectiveAt,
            timezoneLabel: _effectiveTimezone,
            businessDayStartController: _businessDayStartLocal,
            weekStartDay: _weekStartDay,
            enabled: widget.canEdit && !_submitting,
            onScopeChanged: (next) => setState(
              () => _scopeKind = _normalizedScopeKind(next ?? _scopeKind),
            ),
            onPickEffectiveDate: _pickEffectiveDate,
            onWeekStartChanged: (next) =>
                setState(() => _weekStartDay = next ?? _weekStartDay),
            onAnyTextChanged: () => setState(() {}),
            formatter: _formatBusinessDate,
          ),
          const SizedBox(height: 18),
          Text(
            'Service periods',
            style: AppTextStyles.mono15(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Use 15-minute increments. Periods cannot overlap, and only '
            'one period can stretch past midnight.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
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
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              height: 42,
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
          ),
        ],
      ),
    );
  }
}

class _ScopeAndEffectiveSection extends StatelessWidget {
  const _ScopeAndEffectiveSection({
    required this.scopeKind,
    required this.hasOrgUnitScope,
    required this.orgUnitLabel,
    required this.orgUnitHelper,
    required this.locationLabel,
    required this.hasLocationScope,
    required this.effectiveAt,
    required this.timezoneLabel,
    required this.businessDayStartController,
    required this.weekStartDay,
    required this.enabled,
    required this.onScopeChanged,
    required this.onPickEffectiveDate,
    required this.onWeekStartChanged,
    required this.onAnyTextChanged,
    required this.formatter,
  });

  final String scopeKind;
  final bool hasOrgUnitScope;
  final String orgUnitLabel;
  final String orgUnitHelper;
  final String locationLabel;
  final bool hasLocationScope;
  final DateTime effectiveAt;
  final String timezoneLabel;
  final TextEditingController businessDayStartController;
  final String weekStartDay;
  final bool enabled;
  final ValueChanged<String?> onScopeChanged;
  final VoidCallback onPickEffectiveDate;
  final ValueChanged<String?> onWeekStartChanged;
  final VoidCallback onAnyTextChanged;
  final String Function(DateTime) formatter;

  @override
  Widget build(BuildContext context) {
    final scopeItems = <DropdownMenuItem<String>>[
      const DropdownMenuItem<String>(
        value: 'operator',
        child: Text('Across all locations (business default)'),
      ),
      if (hasOrgUnitScope)
        DropdownMenuItem<String>(
          value: 'org_unit',
          child: Text('$orgUnitLabel ($orgUnitHelper defaults)'),
        ),
      if (hasLocationScope)
        DropdownMenuItem<String>(
          value: 'location',
          child: Text('Just $locationLabel (location override)'),
        ),
    ];
    final selectedItems = <Widget>[
      const Text('Across all locations (business default)'),
      if (hasOrgUnitScope) Text('$orgUnitLabel ($orgUnitHelper defaults)'),
      if (hasLocationScope) Text('Just $locationLabel (location override)'),
    ];
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
                child: DropdownButtonFormField<String>(
                  key: const Key(
                    'operator_web_business_timing_editor_scope_kind',
                  ),
                  initialValue: scopeKind,
                  decoration: const InputDecoration(
                    labelText: 'Where does this profile apply?',
                    border: OutlineInputBorder(),
                  ),
                  items: scopeItems,
                  selectedItemBuilder: (context) => selectedItems,
                  onChanged: enabled ? onScopeChanged : null,
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 220,
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
                child: InputDecorator(
                  key: const Key(
                    'operator_web_business_timing_editor_timezone_readonly',
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Location timezone',
                    border: OutlineInputBorder(),
                    helperText:
                        'Change this in Account or the location record.',
                  ),
                  child: Text(
                    timezoneLabel,
                    style: AppTextStyles.body13(color: AppColors.textPrimary),
                  ),
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
                  decoration: const InputDecoration(
                    labelText: 'Business day starts (HH:MM)',
                    border: OutlineInputBorder(),
                    helperText: 'Quarter-hour boundary.',
                  ),
                  onChanged: (_) => onAnyTextChanged(),
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
