// Admin Timing per-operator screen: EDITABLE parity with operator-web.
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
// The editor content mirrors operator-web. Admin keeps only the selected
// scope plumbing and the required save-reason dialog.
//
// Timing is NOT location-only: operator / org_unit / location are all
// valid profile scopes, so the editor honors whatever scope the admin
// selected (no "pick a location first" gate, unlike Vendor / Data
// accuracy).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forge_and_flow/widgets/console/console_info_button.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_section_heading.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

import '../../services/business_timing/business_timing_profile_validator.dart';
import '../../services/business_timing/business_timing_starter_profile.dart';
import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../admin_route_handoff.dart';
import '../models/operator_location_admin_models.dart';
import '../services/admin_business_timing_profiles_gateway.dart'
    show
        AdminBusinessTimingProfileCreate,
        AdminBusinessTimingProfileGatewayError,
        AdminBusinessTimingProfilePatch,
        AdminBusinessTimingProfileRecord,
        AdminBusinessTimingProfilesGateway,
        AdminServicePeriodWrite,
        InMemoryAdminBusinessTimingProfilesGateway;
import '../services/admin_business_timing_resolution_gateway.dart';
import '../services/operator_location_admin_gateway.dart';
import '../widgets/admin_action_controls.dart';
import '../widgets/admin_business_accounts_back_button.dart';
// Reuse operator-web's PURE PRESENTATIONAL service-period editor (it
// imports only Flutter + theme, with no operator-web session / gateway
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

  /// super_admin means true (full edit); ff_support means false (read-only, no
  /// Save). Mirrors how the builder feeds `canEdit` from the signed-in
  /// session's roles.
  final bool editingEnabled;

  /// Legacy route API for the previous read-only effective summary. The
  /// editor no longer renders that summary, but keeping the parameter avoids
  /// forcing unrelated route rewiring in this parity pass.
  final AdminBusinessTimingResolutionGateway? timingResolutionGateway;

  /// Timing-editable parity: admin cross-tenant business-timing PROFILE
  /// WRITE gateway (create / patch). Null falls back to the seeded
  /// in-memory demo gateway so demo / share-preview / widget tests can
  /// exercise the create to list to patch round-trip without a backend.
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

  late final ServicePeriodEditorController _periods;
  late final TextEditingController _businessDayStartLocal;
  late final TextEditingController _ianaTimezone;
  late DateTime _effectiveAt;
  String _weekStartDay = kStarterBusinessTimingWeekStartDayWire;

  /// The profile the editor is currently patching, if one exists for the
  /// selected scope. Resolved from `listProfiles` on load and after each
  /// successful save so a second save patches instead of duplicating.
  AdminBusinessTimingProfileRecord? _existingProfile;

  /// The values currently loaded into the editor. This can be the exact
  /// selected-scope profile or the deepest inherited ancestor profile used
  /// as the create baseline for a lower-scope override.
  AdminBusinessTimingProfileRecord? _baselineProfile;
  bool _baselineIsInherited = false;

  bool _loadingProfiles = true;
  bool _submitting = false;
  String? _error;
  String? _success;
  Timer? _successTimer;
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

  /// Scope mapping (operator-confirmed): operator scope maps to scopeKind
  /// 'operator' + scopeId=operatorId; org_unit maps to 'org_unit' +
  /// scopeId=orgUnitId; location maps to 'location' + scopeId=locationId.
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
    AdminBusinessTimingProfileRecord? match;
    for (final profile in profiles) {
      if (profile.scopeKind == _scopeKind && profile.scopeId == _scopeId) {
        match = profile;
        break;
      }
    }
    AdminBusinessTimingProfileRecord? baseline = match;
    var baselineIsInherited = false;
    if (baseline == null) {
      try {
        baseline = await _loadInheritedBaselineProfile();
      } on AdminBusinessTimingResolutionGatewayError catch (error) {
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
          _error = 'Could not load inherited timing: $error';
        });
        return;
      }
      baselineIsInherited = baseline != null;
    }
    final starterDefaults = baseline == null
        ? await _loadStarterDefaults()
        : _AdminTimingStarterDefaults.fallback;
    if (!mounted) return;
    setState(() {
      _loadingProfiles = false;
      _existingProfile = match;
      _baselineProfile = baseline;
      _baselineIsInherited = baselineIsInherited;
      if (baseline != null) {
        _hydrateFromProfile(baseline);
      } else {
        _hydrateStarter(starterDefaults);
      }
    });
  }

  Future<AdminBusinessTimingProfileRecord?>
  _loadInheritedBaselineProfile() async {
    if (_scopeKind == 'operator') return null;
    final gateway = widget.timingResolutionGateway;
    if (gateway == null) return null;
    final locationId = await _resolutionLocationId();
    if (locationId == null || locationId.isEmpty) return null;
    final resolution = await gateway.resolve(
      operatorId: widget.selectedScope.operatorId,
      locationId: locationId,
    );
    final candidate = _inheritedCandidateForSelectedScope(resolution);
    return candidate == null ? null : _recordFromResolutionCandidate(candidate);
  }

  Future<String?> _resolutionLocationId() async {
    final selectedLocationId = widget.selectedScope.locationId?.trim();
    if (selectedLocationId != null && selectedLocationId.isNotEmpty) {
      return selectedLocationId;
    }
    if (widget.scopeLocationIds.isNotEmpty) {
      return widget.scopeLocationIds.first;
    }
    try {
      final bundles = await widget.operatorGateway.listOperators();
      for (final bundle in bundles) {
        if (bundle.operator.operatorId != widget.selectedScope.operatorId) {
          continue;
        }
        return _starterLocation(bundle)?.locationId;
      }
    } catch (_) {
      // Starter resolution is best-effort; profile loading owns hard errors.
    }
    return null;
  }

  AdminResolutionCandidate? _inheritedCandidateForSelectedScope(
    AdminBusinessTimingResolution resolution,
  ) {
    final candidates = resolution.candidates;
    if (candidates.isEmpty) return null;
    switch (widget.selectedScope.scopeType) {
      case AdminHierarchyScopeType.business:
        return null;
      case AdminHierarchyScopeType.location:
        for (final candidate in candidates.reversed) {
          if (candidate.scopeType != 'location') return candidate;
        }
        return null;
      case AdminHierarchyScopeType.orgUnit:
        final selectedDepth = widget.selectedScope.hierarchyPath.length + 1;
        for (final candidate in candidates.reversed) {
          if (candidate.scopeType == 'operator') return candidate;
          if (candidate.scopeType == 'org_unit' &&
              candidate.scopeId != _scopeId &&
              candidate.scopeDepthRank < selectedDepth) {
            return candidate;
          }
        }
        return null;
    }
  }

  AdminBusinessTimingProfileRecord _recordFromResolutionCandidate(
    AdminResolutionCandidate candidate,
  ) {
    return AdminBusinessTimingProfileRecord(
      profileId: candidate.profileId,
      versionId: candidate.profileId,
      scopeKind: candidate.scopeType,
      scopeId: candidate.scopeId,
      effectiveAtBusinessDate: candidate.effectiveAtBusinessDate,
      ianaTimezone: candidate.ianaTimezone,
      weekStartDay: candidate.weekStartDay,
      businessDayStartLocal: candidate.businessDayStartLocal,
      servicePeriods: candidate.servicePeriods,
    );
  }

  Future<_AdminTimingStarterDefaults> _loadStarterDefaults() async {
    try {
      final bundles = await widget.operatorGateway.listOperators();
      for (final bundle in bundles) {
        if (bundle.operator.operatorId != widget.selectedScope.operatorId) {
          continue;
        }
        final location = _starterLocation(bundle);
        if (location == null) break;
        final rolloverHour = location.businessDayRolloverHour;
        return _AdminTimingStarterDefaults(
          ianaTimezone: location.timezone.trim().isEmpty
              ? 'UTC'
              : location.timezone.trim(),
          businessDayStartLocal: rolloverHour == null
              ? kStarterBusinessTimingDayStartLocal
              : '${rolloverHour.toString().padLeft(2, '0')}:00',
        );
      }
    } catch (_) {
      // Starter defaults are a convenience. Profile loading owns the error UI.
    }
    return _AdminTimingStarterDefaults.fallback;
  }

  LocationAdminRecord? _starterLocation(OperatorAdminBundle bundle) {
    final selectedLocationId = widget.selectedScope.locationId;
    if (selectedLocationId != null && selectedLocationId.isNotEmpty) {
      for (final location in bundle.locations) {
        if (location.locationId == selectedLocationId) return location;
      }
    }
    final scopedIds = widget.scopeLocationIds;
    if (scopedIds.isNotEmpty) {
      final primary = bundle.primaryLocation;
      if (primary != null && scopedIds.contains(primary.locationId)) {
        return primary;
      }
      for (final location in bundle.locations) {
        if (scopedIds.contains(location.locationId)) return location;
      }
    }
    return bundle.primaryLocation ??
        (bundle.locations.isEmpty ? null : bundle.locations.first);
  }

  void _hydrateStarter([
    _AdminTimingStarterDefaults defaults = _AdminTimingStarterDefaults.fallback,
  ]) {
    _ianaTimezone.text = defaults.ianaTimezone;
    _weekStartDay = kStarterBusinessTimingWeekStartDayWire;
    _businessDayStartLocal.text = defaults.businessDayStartLocal;
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
      final baseline = _baselineProfile;
      if (baseline != null) {
        _hydrateFromProfile(baseline);
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

  String get _resetButtonText =>
      _baselineIsInherited ? 'Reset to inherited' : 'Discard changes';

  Future<void> _pickEffectiveDate() async {
    final now = DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: _effectiveAt.isBefore(now) ? now : _effectiveAt,
      firstDate: now,
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
            scopeKind: _scopeKind,
            scopeId: _scopeId,
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
    _successTimer?.cancel();
    setState(() {
      _submitting = false;
      _existingProfile = saved;
      _success =
          'Saved. New timing takes effect ${_formatBusinessDate(_effectiveAt)}.';
    });
    _successTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _success = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final canSave = _canEdit && !_submitting && _periods.validation.isValid;
    return OperatorWebScreenBody(
      key: const Key('admin_timing_setup_screen'),
      scrollKey: const Key('admin_timing_setup_screen_body'),
      maxContentWidth: 520,
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          OperatorWebScreenHeader(
            icon: Icons.schedule_outlined,
            title: 'Edit service periods',
            actions: _buildHeaderActions(),
          ),
          const SizedBox(height: 8),
          Text(
            'Service periods break the business day into the chunks your '
            'team works in: lunch, dinner, late night, and so on. You '
            'can have one to four.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 6),
          Text(
            'Already closed days keep the timing they were closed with.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 18),
          if (!_canEdit) const _AdminTimingReadOnlyBanner(),
          if (!_canEdit) const SizedBox(height: 14),
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
          ServicePeriodEditor(
            controller: _periods,
            key: const Key('admin_timing_editor_periods'),
          ),
          const SizedBox(height: 18),
          if (_error != null)
            _AdminTimingMessageBanner(
              key: const Key('admin_timing_editor_error'),
              message: _error!,
              isError: true,
            ),
          if (_success != null)
            _AdminTimingMessageBanner(
              key: const Key('admin_timing_editor_success'),
              message: _success!,
              isError: false,
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
                  style: AdminButtonStyles.primary.copyWith(
                    minimumSize: const WidgetStatePropertyAll(Size(164, 46)),
                    padding: const WidgetStatePropertyAll(
                      EdgeInsets.symmetric(horizontal: 22),
                    ),
                  ),
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
              if (_baselineProfile != null)
                AdminActionButton(
                  key: const Key('admin_timing_editor_reset'),
                  label: _resetButtonText,
                  onPressed: _submitting ? null : _resetToLoadedProfile,
                  icon: Icons.undo_outlined,
                ),
            ],
          ),
        ],
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
}

class _AdminTimingStarterDefaults {
  const _AdminTimingStarterDefaults({
    required this.ianaTimezone,
    required this.businessDayStartLocal,
  });

  static const fallback = _AdminTimingStarterDefaults(
    ianaTimezone: 'UTC',
    businessDayStartLocal: kStarterBusinessTimingDayStartLocal,
  );

  final String ianaTimezone;
  final String businessDayStartLocal;
}

/// Timing-editable parity: shared seeded in-memory write fallback so
/// demo / share-preview / widget tests can exercise create to list to
/// patch without the Cloud Run admin proxy. A single shared instance so
/// the store survives screen rebuilds when no scope is mounted.
final AdminBusinessTimingProfilesGateway _fallbackTimingProfilesGateway =
    InMemoryAdminBusinessTimingProfilesGateway();

/// Read-only posture banner for ff_support (editing disabled).
class _AdminTimingReadOnlyBanner extends StatelessWidget {
  const _AdminTimingReadOnlyBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_timing_readonly_banner'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.lock_outline, size: 18, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Super admins can change business timing. You can review what '
              'is set and ask a super admin to make changes.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminTimingMessageBanner extends StatelessWidget {
  const _AdminTimingMessageBanner({
    super.key,
    required this.message,
    required this.isError,
  });

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? AppColors.negative : AppColors.positive;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: AppTextStyles.body13(color: color)),
          ),
        ],
      ),
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
          Row(
            children: <Widget>[
              Expanded(
                child: InkWell(
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
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 620;
              final timezoneField = _AdminTimezoneDropdown(
                controller: timezoneController,
                enabled: enabled,
                onChanged: onAnyTextChanged,
              );
              final dayStartField = TextField(
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
                    timezoneField,
                    const SizedBox(height: 12),
                    dayStartField,
                  ],
                );
              }
              return Row(
                children: <Widget>[
                  Expanded(child: timezoneField),
                  const SizedBox(width: 12),
                  SizedBox(width: 200, child: dayStartField),
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
    final selected = controller.text.trim().isEmpty
        ? 'UTC'
        : controller.text.trim();
    final options = <String>[
      if (!kBusinessTimingAllowedIanaTimezones.contains(selected)) selected,
      ...kBusinessTimingAllowedIanaTimezones,
    ];
    return DropdownButtonFormField<String>(
      key: const Key('admin_timing_editor_timezone_dropdown'),
      initialValue: selected,
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
        AdminActionButton(
          key: const Key('admin_timing_reason_cancel'),
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          role: AdminActionRole.quiet,
        ),
        AdminActionButton(
          key: const Key('admin_timing_reason_submit'),
          label: 'Confirm',
          onPressed: _onSubmit,
          role: AdminActionRole.primary,
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
