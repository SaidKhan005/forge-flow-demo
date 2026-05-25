// Admin Timing per-operator screen — EDITABLE parity with operator-web.
//
// Timing-editable parity: this screen is a faithful replica of the
// operator-web business-timing editor
// (`lib/operator_web/screens/business_timing_editor_screen.dart`),
// driven by the admin scope selector (the `AdminSetupWorkspace`
// scope-tree pane). super_admin can edit timezone / business-day start /
// week start / service periods / effective-at and Save (every Save first
// prompts for a server-required `admin_reason`); ff_support
// (`editingEnabled == false`) sees a read-only posture with no Save.
//
// Writes flow through the admin cross-tenant PROFILE WRITE gateway
// (`AdminBusinessTimingProfilesGateway`): if a profile already exists for
// the selected scope it is PATCHed, else a new one is created. The same
// client-side validator the operator-web editor uses
// (`business_timing_profile_validator.dart` rules + the
// `ServicePeriodEditor`'s `validateServicePeriods`) runs before submit so
// the admin gets an instant explanation; the proxy re-validates.
//
// The READ-ONLY "Effective timing" summary (the prior whole screen) is
// kept below the editor as an admin-useful secondary section, driven by
// the READ-ONLY `AdminBusinessTimingResolutionGateway`. The editor is the
// PRIMARY surface.
//
// Timing is NOT location-only: operator / org_unit / location are all
// valid profile scopes, so the editor honors whatever scope the admin
// selected (no "pick a location first" gate, unlike Vendor / Data
// accuracy).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forge_and_flow/widgets/console/console_info_button.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_section_heading.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

import '../../domain/services/business_timing_profile_resolver.dart';
import '../../services/business_timing/business_timing_profile_validator.dart';
import '../../services/business_timing/business_timing_starter_profile.dart';
import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../admin_route_handoff.dart';
import '../models/operator_location_admin_models.dart';
import '../services/admin_business_timing_profiles_gateway.dart';
import '../services/admin_business_timing_resolution_gateway.dart';
import '../services/admin_business_timing_resolution_projection.dart';
import '../services/operator_location_admin_gateway.dart';
// AdminDetailRow is a detail-row primitive (not a card / panel / section /
// scaffold widget), so it stays; the card / panel / scaffold containers in
// this file now come from the shared console kit above (Slice D5).
import '../widgets/admin_business_accounts_back_button.dart';
import '../widgets/admin_responsive_layout.dart';
// Reuse operator-web's PURE PRESENTATIONAL service-period editor (it
// imports only Flutter + theme — no operator-web session / gateway
// dependency), so the admin editor renders byte-identical period rows
// (label, start/end, day chips, short label, sort order, validation
// banner) to operator-web. Sanctioned by the slice guardrail allowing
// reuse of a dependency-free web sub-widget.
import '../../operator_web/widgets/service_period_editor.dart';

class AdminTimingSetupScreen extends StatefulWidget {
  const AdminTimingSetupScreen({
    super.key,
    required this.operatorGateway,
    required this.selectedScope,
    required this.scopeLocationIds,
    this.editingEnabled = true,
    this.timingResolutionGateway,
    this.timingProfilesGateway,
    this.idempotencyKeyFactory,
    this.onBackToBusinessAccounts,
  });

  final OperatorLocationAdminGateway operatorGateway;
  final AdminHierarchyScopeIntent selectedScope;
  final Set<String> scopeLocationIds;

  /// super_admin → true (full edit); ff_support → false (read-only, no
  /// Save). Mirrors how the builder feeds `canEdit` from the signed-in
  /// session's roles.
  final bool editingEnabled;

  /// Fix #4 / S4 (G41): READ-ONLY S2 admin cross-tenant business-
  /// timing resolution gateway feeding the secondary "Effective timing"
  /// summary. Null falls back to the seeded in-memory demo gateway
  /// (mirrors the established optional-gateway admin DI pattern), so
  /// demo / share-preview / widget tests render without the Cloud Run
  /// admin proxy.
  final AdminBusinessTimingResolutionGateway? timingResolutionGateway;

  /// Timing-editable parity: admin cross-tenant business-timing PROFILE
  /// WRITE gateway (create / patch). Null falls back to the seeded
  /// in-memory demo gateway so demo / share-preview / widget tests can
  /// exercise the create → list → patch round-trip without a backend.
  final AdminBusinessTimingProfilesGateway? timingProfilesGateway;

  /// Caller-overridable idempotency-key minter (tests pin a
  /// deterministic value). Production mints a fresh key per Save so a
  /// retried submit is safe (proxy de-dupes on the key).
  final String Function()? idempotencyKeyFactory;

  /// Re-enters Business accounts. Wired by the route shell so the admin
  /// can leave the surface; rendered as a back button in the header
  /// actions when non-null (parity with the four finished screens).
  final VoidCallback? onBackToBusinessAccounts;

  @override
  State<AdminTimingSetupScreen> createState() => _AdminTimingSetupScreenState();
}

class _AdminTimingSetupScreenState extends State<AdminTimingSetupScreen> {
  late final AdminBusinessTimingProfilesGateway _profilesGateway =
      widget.timingProfilesGateway ?? _fallbackTimingProfilesGateway;
  late final AdminBusinessTimingResolutionGateway _resolutionGateway =
      widget.timingResolutionGateway ?? _fallbackTimingResolutionGateway;

  late final ServicePeriodEditorController _periods;
  late final TextEditingController _businessDayStartLocal;
  late final TextEditingController _ianaTimezone;
  late DateTime _effectiveAt;
  String _weekStartDay = kStarterBusinessTimingWeekStartDayWire;

  /// The profile the editor is currently patching, if one exists for the
  /// selected scope. Resolved from `listProfiles` on load and after each
  /// successful save so a second save patches instead of duplicating.
  AdminBusinessTimingProfileRecord? _existingProfile;

  bool _loadingProfiles = true;
  bool _submitting = false;
  String? _error;
  String? _success;
  int _keySeq = 0;

  bool get _canEdit => widget.editingEnabled;

  @override
  void initState() {
    super.initState();
    _periods = ServicePeriodEditorController(
      initial: kStarterBusinessTimingServicePeriods
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
    _businessDayStartLocal = TextEditingController(
      text: kStarterBusinessTimingDayStartLocal,
    );
    _ianaTimezone = TextEditingController(text: 'UTC');
    _effectiveAt = DateTime.now();
    _businessDayStartLocal.addListener(_handleDayStartChanged);
    _periods.addListener(_handleEditorChange);
    Future<void>.microtask(() {
      if (!mounted) return;
      _periods.setBusinessDayStartLocal(_businessDayStartLocal.text.trim());
    });
    _loadExistingProfile();
  }

  @override
  void didUpdateWidget(covariant AdminTimingSetupScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The scope-tree pane drives this screen; when the admin picks a
    // different scope the builder rebuilds the screen with a new
    // `selectedScope`, so re-resolve which profile (if any) backs it.
    if (oldWidget.selectedScope.cacheKey != widget.selectedScope.cacheKey) {
      _loadExistingProfile();
    }
  }

  @override
  void dispose() {
    _periods.removeListener(_handleEditorChange);
    _periods.dispose();
    _businessDayStartLocal.removeListener(_handleDayStartChanged);
    _businessDayStartLocal.dispose();
    _ianaTimezone.dispose();
    super.dispose();
  }

  void _handleEditorChange() {
    if (mounted) setState(() {});
  }

  void _handleDayStartChanged() {
    final value = _businessDayStartLocal.text.trim();
    _periods.setBusinessDayStartLocal(value.isEmpty ? null : value);
  }

  /// Scope mapping (operator-confirmed): operator scope → scopeKind
  /// 'operator' + scopeId=operatorId; org_unit → 'org_unit' +
  /// scopeId=orgUnitId; location → 'location' + scopeId=locationId.
  String get _scopeKind {
    switch (widget.selectedScope.scopeType) {
      case AdminHierarchyScopeType.business:
        return 'operator';
      case AdminHierarchyScopeType.orgUnit:
        return 'org_unit';
      case AdminHierarchyScopeType.location:
        return 'location';
    }
  }

  String get _scopeId {
    final scope = widget.selectedScope;
    switch (scope.scopeType) {
      case AdminHierarchyScopeType.business:
        return scope.operatorId;
      case AdminHierarchyScopeType.orgUnit:
        return scope.orgUnitId ?? '';
      case AdminHierarchyScopeType.location:
        return scope.locationId ?? '';
    }
  }

  Future<void> _loadExistingProfile() async {
    setState(() {
      _loadingProfiles = true;
      _error = null;
      _success = null;
    });
    List<AdminBusinessTimingProfileRecord> profiles;
    try {
      profiles = await _profilesGateway.listProfiles(
        operatorId: widget.selectedScope.operatorId,
      );
    } on AdminBusinessTimingProfileGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingProfiles = false;
        _error = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingProfiles = false;
        _error = 'Could not load timing profiles: $error';
      });
      return;
    }
    if (!mounted) return;
    AdminBusinessTimingProfileRecord? match;
    for (final profile in profiles) {
      if (profile.scopeKind == _scopeKind && profile.scopeId == _scopeId) {
        match = profile;
        break;
      }
    }
    setState(() {
      _loadingProfiles = false;
      _existingProfile = match;
      if (match != null) {
        _hydrateFromProfile(match);
      } else {
        _hydrateStarter();
      }
    });
  }

  void _hydrateStarter() {
    _ianaTimezone.text = 'UTC';
    _weekStartDay = kStarterBusinessTimingWeekStartDayWire;
    _businessDayStartLocal.text = kStarterBusinessTimingDayStartLocal;
    _effectiveAt = DateTime.now();
    _periods.replaceAll(
      kStarterBusinessTimingServicePeriods
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
  }

  void _hydrateFromProfile(AdminBusinessTimingProfileRecord profile) {
    _ianaTimezone.text = profile.ianaTimezone;
    _weekStartDay = profile.weekStartDay.isEmpty
        ? kStarterBusinessTimingWeekStartDayWire
        : profile.weekStartDay;
    _businessDayStartLocal.text = profile.businessDayStartLocal.isEmpty
        ? kStarterBusinessTimingDayStartLocal
        : profile.businessDayStartLocal;
    _effectiveAt =
        DateTime.tryParse(profile.effectiveAtBusinessDate) ?? DateTime.now();
    final periods = profile.servicePeriods.toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    _periods.replaceAll(
      periods.isEmpty
          ? <ServicePeriodDraft>[
              ServicePeriodDraft(
                key: kStarterBusinessTimingServicePeriods.first.key,
                label: kStarterBusinessTimingServicePeriods.first.label,
                startLocal:
                    kStarterBusinessTimingServicePeriods.first.startLocal,
                endLocal: kStarterBusinessTimingServicePeriods.first.endLocal,
              ),
            ]
          : <ServicePeriodDraft>[
              for (final p in periods)
                ServicePeriodDraft(
                  key: p.key,
                  label: p.label,
                  startLocal: p.startLocal,
                  endLocal: p.endLocal,
                  applicableDays: List<int>.from(p.applicableDays),
                  shortLabel: p.shortLabel,
                  sortOrder: p.sortOrder,
                ),
            ],
    );
  }

  void _resetToLoadedProfile() {
    if (_submitting) return;
    setState(() {
      _error = null;
      _success = null;
      final existing = _existingProfile;
      if (existing != null) {
        _hydrateFromProfile(existing);
      } else {
        _hydrateStarter();
      }
    });
  }

  String get _timezoneForSave {
    final draft = _ianaTimezone.text.trim();
    return draft.isNotEmpty ? draft : 'UTC';
  }

  String _formatBusinessDate(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';

  String _mintIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    return 'admin-timing-${widget.selectedScope.cacheKey}-'
        '${DateTime.now().microsecondsSinceEpoch}-${_keySeq++}';
  }

  Future<void> _pickEffectiveDate() async {
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: _effectiveAt.isBefore(now) ? now : _effectiveAt,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (selected != null) {
      setState(() => _effectiveAt = selected);
    }
  }

  Future<String?> _promptAdminReason() {
    return showDialog<String>(
      context: context,
      builder: (_) => const _AdminTimingReasonDialog(),
    );
  }

  Future<void> _save() async {
    if (!_canEdit || _submitting) return;
    final validation = _periods.validation;
    if (!validation.isValid) {
      setState(() {
        _error = 'Fix the highlighted issues before saving.';
        _success = null;
      });
      return;
    }
    final reason = await _promptAdminReason();
    // Cancelled or empty reason: the dialog blocks empty itself, so a
    // null result means the admin backed out. No write happens.
    if (reason == null || reason.trim().isEmpty) return;
    if (!mounted) return;

    setState(() {
      _submitting = true;
      _error = null;
      _success = null;
    });

    final servicePeriods = <AdminServicePeriodWrite>[
      for (final p in _periods.periods)
        AdminServicePeriodWrite(
          key: p.key,
          label: p.label,
          startLocal: p.startLocal,
          endLocal: p.endLocal,
          applicableDays: List<int>.from(p.applicableDays),
          shortLabel: p.shortLabel,
          sortOrder: p.sortOrder,
        ),
    ];
    final dayStart = normalizeBusinessTimingTimeInput(
      _businessDayStartLocal.text,
    ).trim();

    AdminBusinessTimingProfileRecord saved;
    try {
      final existing = _existingProfile;
      if (existing == null) {
        saved = await _profilesGateway.createProfile(
          operatorId: widget.selectedScope.operatorId,
          profile: AdminBusinessTimingProfileCreate(
            scopeKind: _scopeKind,
            scopeId: _scopeId,
            effectiveAtBusinessDate: _formatBusinessDate(_effectiveAt),
            ianaTimezone: _timezoneForSave,
            weekStartDay: _weekStartDay,
            businessDayStartLocal: dayStart,
            servicePeriods: servicePeriods,
          ),
          adminReason: reason.trim(),
          idempotencyKey: _mintIdempotencyKey(),
        );
      } else {
        saved = await _profilesGateway.updateProfile(
          operatorId: widget.selectedScope.operatorId,
          profileId: existing.profileId,
          patch: AdminBusinessTimingProfilePatch(
            effectiveAtBusinessDate: _formatBusinessDate(_effectiveAt),
            ianaTimezone: _timezoneForSave,
            weekStartDay: _weekStartDay,
            businessDayStartLocal: dayStart,
            // Whole-set override semantics (mirrors operator-web): the
            // patch's servicePeriods REPLACES the server's set.
            servicePeriods: servicePeriods,
          ),
          adminReason: reason.trim(),
          idempotencyKey: _mintIdempotencyKey(),
        );
      }
    } on AdminBusinessTimingProfileGatewayError catch (error) {
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
    setState(() {
      _submitting = false;
      _existingProfile = saved;
      _success =
          'Saved. New timing takes effect ${_formatBusinessDate(_effectiveAt)}.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final canSave =
        _canEdit && !_submitting && _periods.validation.isValid;
    return ColoredBox(
      key: const Key('admin_timing_setup_screen'),
      color: AppColors.backgroundDeep,
      child: OperatorWebScreenBody(
        scrollKey: const Key('admin_timing_setup_screen_body'),
        padding: const EdgeInsets.all(20),
        maxContentWidth: 880,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            OperatorWebScreenHeader(
              icon: Icons.schedule_outlined,
              title: 'Edit service periods',
              actions: _buildHeaderActions(),
            ),
            const SizedBox(height: 14),
            if (!_canEdit)
              const Padding(
                padding: EdgeInsets.only(bottom: 14),
                child: _AdminTimingReadOnlyBanner(),
              ),
            _buildEditorPanel(canSave: canSave),
            const SizedBox(height: 18),
            _AdminEffectiveTimingSummary(
              selectedScope: widget.selectedScope,
              operatorGateway: widget.operatorGateway,
              scopeLocationIds: widget.scopeLocationIds,
              editingEnabled: _canEdit,
              timingResolutionGateway: _resolutionGateway,
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildHeaderActions() {
    final children = <Widget>[];
    if (widget.onBackToBusinessAccounts != null) {
      children.add(
        AdminBusinessAccountsBackButton(
          onPressed: widget.onBackToBusinessAccounts,
        ),
      );
    }
    return children;
  }

  Widget _buildEditorPanel({required bool canSave}) {
    return OperatorWebPanel(
      key: const Key('admin_timing_editor_panel'),
      title: 'Business timing',
      subtitle:
          'Service periods break the business day into the chunks your team '
          'works in: lunch, dinner, late night, and so on. You can have one '
          'to four. Already closed days keep the timing they were closed '
          'with.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_loadingProfiles)
            const Padding(
              key: Key('admin_timing_editor_loading'),
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          _AdminScopeAndEffectiveSection(
            effectiveAt: _effectiveAt,
            timezoneController: _ianaTimezone,
            businessDayStartController: _businessDayStartLocal,
            weekStartDay: _weekStartDay,
            enabled: _canEdit && !_submitting,
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
          AbsorbPointer(
            absorbing: !_canEdit || _submitting,
            child: Opacity(
              opacity: _canEdit ? 1 : 0.65,
              child: ServicePeriodEditor(
                controller: _periods,
                key: const Key('admin_timing_editor_periods'),
              ),
            ),
          ),
          const SizedBox(height: 6),
          if (_error != null)
            _AdminTimingMessageBanner(
              key: const Key('admin_timing_editor_error'),
              message: _error!,
              tone: OperatorWebBannerTone.error,
            ),
          if (_success != null)
            _AdminTimingMessageBanner(
              key: const Key('admin_timing_editor_success'),
              message: _success!,
              tone: OperatorWebBannerTone.success,
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              SizedBox(
                height: 46,
                child: FilledButton(
                  key: const Key('admin_timing_editor_save'),
                  style: AdminButtonStyles.primary,
                  onPressed: canSave ? _save : null,
                  child: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.backgroundSurface,
                          ),
                        )
                      : const Text('Save service periods'),
                ),
              ),
              SizedBox(
                height: 46,
                child: OutlinedButton.icon(
                  key: const Key('admin_timing_editor_reset'),
                  style: AdminButtonStyles.secondary(),
                  onPressed: _canEdit && !_submitting
                      ? _resetToLoadedProfile
                      : null,
                  icon: const Icon(Icons.undo_outlined, size: 16),
                  label: Text(
                    _existingProfile == null
                        ? 'Reset to starter'
                        : 'Reset to saved',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

}

/// Timing-editable parity: shared seeded in-memory write fallback so
/// demo / share-preview / widget tests can exercise create → list →
/// patch without the Cloud Run admin proxy. A single shared instance so
/// the store survives screen rebuilds when no scope is mounted.
final AdminBusinessTimingProfilesGateway _fallbackTimingProfilesGateway =
    InMemoryAdminBusinessTimingProfilesGateway();

/// Fix #4 / S4 (G41): shared seeded in-memory READ fallback for the
/// secondary "Effective timing" summary. Empty by default → the summary
/// shows its honest "no timing profile yet" state.
final AdminBusinessTimingResolutionGateway _fallbackTimingResolutionGateway =
    InMemoryAdminBusinessTimingResolutionGateway();

/// Read-only posture banner for ff_support (editing disabled).
class _AdminTimingReadOnlyBanner extends StatelessWidget {
  const _AdminTimingReadOnlyBanner();

  @override
  Widget build(BuildContext context) {
    return const OperatorWebBanner(
      key: Key('admin_timing_readonly_banner'),
      icon: Icons.lock_outline,
      message: 'View only. Ask a super admin if timing needs to be changed.',
    );
  }
}

class _AdminTimingMessageBanner extends StatelessWidget {
  const _AdminTimingMessageBanner({
    super.key,
    required this.message,
    required this.tone,
  });

  final String message;
  final OperatorWebBannerTone tone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: OperatorWebBanner(message: message, tone: tone),
    );
  }
}

/// Effective-date + timezone + business-day-start + week-start controls.
/// Replicates the operator-web editor's `_ScopeAndEffectiveSection`
/// (a private widget there, so re-built here).
class _AdminScopeAndEffectiveSection extends StatelessWidget {
  const _AdminScopeAndEffectiveSection({
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
      key: const Key('admin_timing_editor_scope_card'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            key: const Key('admin_timing_editor_effective_pick'),
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
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 520;
              final timezone = _AdminTimezoneDropdown(
                controller: timezoneController,
                enabled: enabled,
                onChanged: onAnyTextChanged,
              );
              final dayStart = TextField(
                key: const Key('admin_timing_editor_business_day_start'),
                controller: businessDayStartController,
                enabled: enabled,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9:]')),
                  LengthLimitingTextInputFormatter(5),
                ],
                decoration: const InputDecoration(
                  labelText: 'Business day starts (HH:MM)',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) {
                  _normalizeTimeController(businessDayStartController, value);
                  onAnyTextChanged();
                },
                onEditingComplete: () {
                  _normalizeTimeController(
                    businessDayStartController,
                    businessDayStartController.text,
                  );
                  onAnyTextChanged();
                },
              );
              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    timezone,
                    const SizedBox(height: 12),
                    dayStart,
                  ],
                );
              }
              return Row(
                children: <Widget>[
                  Expanded(child: timezone),
                  const SizedBox(width: 12),
                  SizedBox(width: 200, child: dayStart),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const Key('admin_timing_editor_week_start'),
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

/// Timezone dropdown, replicated from operator-web's private
/// `_TimezoneDropdown`. Same curated allow-list + GMT labels.
class _AdminTimezoneDropdown extends StatelessWidget {
  const _AdminTimezoneDropdown({
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final selected =
        controller.text.trim().isEmpty ? 'UTC' : controller.text.trim();
    final options = <String>[
      if (!kBusinessTimingAllowedIanaTimezones.contains(selected)) selected,
      ...kBusinessTimingAllowedIanaTimezones,
    ];
    return DropdownButtonFormField<String>(
      key: const Key('admin_timing_editor_timezone_dropdown'),
      initialValue: selected,
      // Ellipsize the long GMT-suffixed label inside the field rather
      // than overflowing the row at narrow widths.
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Timezone',
        border: OutlineInputBorder(),
        helperText: 'Choose the location timezone.',
      ),
      items: options
          .map(
            (timezone) => DropdownMenuItem<String>(
              value: timezone,
              child: Text(
                _timezoneLabel(timezone),
                overflow: TextOverflow.ellipsis,
              ),
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

void _normalizeTimeController(TextEditingController controller, String raw) {
  final formatted = normalizeBusinessTimingTimeInput(raw);
  if (formatted == controller.text || formatted == raw) return;
  controller.value = TextEditingValue(
    text: formatted,
    selection: TextSelection.collapsed(offset: formatted.length),
  );
}

/// admin_reason capture dialog. Mirrors the
/// `audited_support_actions_admin_screen.dart` reason-dialog pattern
/// (blocks empty submissions; returns the trimmed reason on confirm).
class _AdminTimingReasonDialog extends StatefulWidget {
  const _AdminTimingReasonDialog();

  @override
  State<_AdminTimingReasonDialog> createState() =>
      _AdminTimingReasonDialogState();
}

class _AdminTimingReasonDialogState extends State<_AdminTimingReasonDialog> {
  final _reasonController = TextEditingController();
  bool _violated = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) {
      setState(() => _violated = true);
      return;
    }
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_timing_reason_dialog'),
      title: 'Reason for timing change',
      maxWidth: 460,
      showCloseButton: false,
      actions: <Widget>[
        TextButton(
          key: const Key('admin_timing_reason_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_timing_reason_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Confirm'),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'The operator will see this reason in their audit log. Write a '
            'short, plain-English note about why you are changing their '
            'business timing.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('admin_timing_reason_field'),
            controller: _reasonController,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: 'Reason',
              border: const OutlineInputBorder(),
              errorText: _violated ? 'Add a reason before continuing.' : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Secondary, clearly-labelled READ-ONLY "Effective timing" summary
/// (the prior whole screen). Kept as an admin-useful extra below the
/// editor; driven by the READ-ONLY resolution gateway. Resolves the
/// location backing the selected scope first (resolution is
/// location-scoped), then shows the REAL resolved
/// `EffectiveBusinessTimingProfile` with per-field provenance.
class _AdminEffectiveTimingSummary extends StatelessWidget {
  const _AdminEffectiveTimingSummary({
    required this.selectedScope,
    required this.operatorGateway,
    required this.scopeLocationIds,
    required this.editingEnabled,
    required this.timingResolutionGateway,
  });

  final AdminHierarchyScopeIntent selectedScope;
  final OperatorLocationAdminGateway operatorGateway;
  final Set<String> scopeLocationIds;
  final bool editingEnabled;
  final AdminBusinessTimingResolutionGateway timingResolutionGateway;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<OperatorAdminBundle>>(
      future: operatorGateway.listOperators(),
      builder: (context, snapshot) {
        final bundles = snapshot.data ?? const <OperatorAdminBundle>[];
        final bundle = _bundleForScope(bundles, selectedScope.operatorId);
        final location = bundle == null ? null : _locationForScope(bundle);
        if (snapshot.hasError) {
          return const _TimingMessageCard(
            title: 'Effective timing could not load',
            body:
                'Refresh Business Accounts and try this setup screen again.',
          );
        }
        if (location == null) {
          return const _TimingMessageCard(
            title: 'Add a location to see effective timing',
            body:
                'The effective-timing summary resolves a location. Business '
                'and org-unit scopes show inherited timing from the locations '
                'they cover. Add or select a location to review the resolved '
                'timezone, business day, and service periods.',
          );
        }
        final covered = scopeLocationIds.isEmpty
            ? 'Selected location'
            : '${scopeLocationIds.length} covered location'
                  '${scopeLocationIds.length == 1 ? '' : 's'}';
        return OperatorWebPanel(
          key: const Key('admin_timing_summary_card'),
          title: 'Effective timing',
          subtitle:
              'Read-only. The resolved timing for this scope after '
              'inheritance.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (!selectedScope.isLocationScope &&
                  scopeLocationIds.length > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    key: const Key('admin_timing_scope_inheritance_notice'),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.cardGlow,
                      border:
                          Border.all(color: AppColors.borderSubtle, width: 1),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'Other locations under this scope may have their own '
                      'overrides.',
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              AdminDetailRow(label: 'Timing source', value: location.name),
              AdminDetailRow(label: 'Covered locations', value: covered),
              const SizedBox(height: 12),
              _ResolvedTimingFields(
                operatorId: selectedScope.operatorId,
                locationId: location.locationId,
                gateway: timingResolutionGateway,
              ),
            ],
          ),
        );
      },
    );
  }

  OperatorAdminBundle? _bundleForScope(
    List<OperatorAdminBundle> bundles,
    String operatorId,
  ) {
    for (final bundle in bundles) {
      if (bundle.operator.operatorId == operatorId) return bundle;
    }
    return null;
  }

  LocationAdminRecord? _locationForScope(OperatorAdminBundle bundle) {
    final selectedLocationId = selectedScope.locationId;
    if (selectedLocationId != null && selectedLocationId.isNotEmpty) {
      for (final location in bundle.locations) {
        if (location.locationId == selectedLocationId) return location;
      }
    }
    if (scopeLocationIds.isNotEmpty) {
      final primary = bundle.primaryLocation;
      if (primary != null && scopeLocationIds.contains(primary.locationId)) {
        return primary;
      }
      for (final location in bundle.locations) {
        if (scopeLocationIds.contains(location.locationId)) return location;
      }
    }
    return bundle.primaryLocation ??
        (bundle.locations.isEmpty ? null : bundle.locations.first);
  }
}

/// Fix #4 / S4 (G41): resolves the REAL effective business-timing
/// profile via the READ-ONLY S2 admin gateway → canonical resolver →
/// real per-field provenance.
class _ResolvedTimingFields extends StatelessWidget {
  const _ResolvedTimingFields({
    required this.operatorId,
    required this.locationId,
    required this.gateway,
  });

  final String operatorId;
  final String locationId;
  final AdminBusinessTimingResolutionGateway gateway;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AdminBusinessTimingResolution>(
      future: gateway.resolve(operatorId: operatorId, locationId: locationId),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Padding(
            key: Key('admin_timing_resolution_loading'),
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(minHeight: 2),
          );
        }
        if (snapshot.hasError) {
          return Padding(
            key: const Key('admin_timing_resolution_error'),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Effective timing could not load. The operator owns these '
              'values; try again after a timing profile has been saved.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          );
        }
        final resolution = snapshot.data!;
        if (resolution.candidates.isEmpty) {
          return Padding(
            key: const Key('admin_timing_resolution_empty'),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No business timing profile has been saved for this scope yet. '
              'Save above and the resolved timezone, business day, and '
              'service periods will appear here.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          );
        }
        final AdminEffectiveTimingProjection projection;
        try {
          projection =
              AdminBusinessTimingResolutionProjection.project(resolution);
        } on BusinessTimingProfileResolutionException {
          return Padding(
            key: const Key('admin_timing_resolution_error'),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Effective timing could not load. The operator owns these '
              'values; try again after a timing profile has been saved.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          );
        }
        final effective = projection.effective;
        final sourceLabel = projection.provenance.detailLabel;
        final timezoneValue =
            resolution.ianaTimezone?.trim().isNotEmpty == true
            ? resolution.ianaTimezone!.trim()
            : effective.businessTimezone;
        final periods = effective.servicePeriodDefinitions.toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
        return Column(
          key: const Key('admin_timing_resolved_fields'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AdminDetailRow(
              label: 'Effective from',
              value: projection.effectiveDateLabel,
            ),
            AdminDetailRow(label: 'Timezone', value: timezoneValue),
            const AdminDetailRow(
              label: 'Timezone source',
              value: 'Location timezone',
            ),
            AdminDetailRow(
              label: 'Business day starts',
              value: effective.businessDayStartLocalTime,
            ),
            AdminDetailRow(label: 'Day-start source', value: sourceLabel),
            AdminDetailRow(
              label: 'Week starts',
              value: AdminBusinessTimingResolutionProjection.weekdayLabel(
                effective.weekStartDay,
              ),
            ),
            AdminDetailRow(label: 'Week-start source', value: sourceLabel),
            const SizedBox(height: 16),
            Container(
              key: const Key('admin_timing_service_periods_panel'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.cardGlow,
                border: Border.all(color: AppColors.borderSubtle, width: 1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final period in periods)
                    _TimingPeriodLine(
                      label: period.label,
                      range:
                          '${period.startLocalTime} to ${period.endLocalTime}',
                      daysLabel:
                          AdminBusinessTimingResolutionProjection.daysLabel(
                        period.applicableDays,
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Source: $sourceLabel',
                      style: AppTextStyles.mono11(color: AppColors.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TimingPeriodLine extends StatelessWidget {
  const _TimingPeriodLine({
    required this.label,
    required this.range,
    this.daysLabel,
  });

  final String label;
  final String range;

  /// G45 / Gap 28: plain-English day restriction (e.g. "Mon, Tue"),
  /// or null when the period runs every day (the common case).
  final String? daysLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
                if (daysLabel != null)
                  Text(
                    daysLabel!,
                    style: AppTextStyles.mono11(color: AppColors.textMuted),
                  ),
              ],
            ),
          ),
          Text(range, style: AppTextStyles.mono11(color: AppColors.textMuted)),
        ],
      ),
    );
  }
}

class _TimingMessageCard extends StatelessWidget {
  const _TimingMessageCard({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      key: const Key('admin_timing_message_card'),
      title: title,
      child: Text(
        body,
        style: AppTextStyles.body13(color: AppColors.textSecondary),
      ),
    );
  }
}
