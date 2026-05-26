// Phase 8 spine-bridge Lane .B — Operator Web Console Data Accuracy
// screen.
//
// Mounted at `kOperatorWebNavDataAccuracy` in the operator-web shell.
// Renders the operator-controlled data accuracy seams documented in
// `docs/contracts/data_accuracy_settings_contract.md`:
//
//   * Wage source (binary toggle).
//   * Covers source per daypart (3-way picker + manual entry sub-card).
//   * Walk-in handling (only when POS does NOT expose covers AND a
//     reservation system is connected).
//   * 60-day covers historical seed (only for non-covers-exposing POS).
//   * Polling tier status (DISPLAY-ONLY + Request tier change button —
//     F&F controls cadence).
//   * Inline explainer card.
//
// V1 seam: this screen owns its in-memory state. The Lane .A
// repository (`DataAccuracySettingsRepository`) is injected via the
// optional [initialSettings] / `onSaveSettings` props so demo + widget
// tests run without Postgres; production wires the repo at the router
// mount in a follow-up `8.spine-bridge.B.live` slice — same gateway-
// follows-shell pattern Lane 11W.7 / 11W.8 used.
//
// Permission gate: mirrors Vendor connections. `operator_owner`
// admits; `location_manager` lands on a friendly
// forbidden surface explaining who manages data accuracy. Mirrors the
// Phase 9 proxy gate the live wiring will enforce server-side.
//
// UX writing standard (`memory/project_ux_writing_standard.md`):
// every label trains the operator. Plain English. No engineering
// jargon.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../auth/permission_keys.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/operator_web_data_accuracy_gateway.dart';
import '../services/operator_web_tier_email_gateway.dart';
import '../services/operator_web_wage_authority_gateway.dart';
import '../services/web_vendor_applicability_gateway.dart';
import '../widgets/covers_historical_seed_card.dart';
import '../widgets/covers_manual_entry_card.dart';
import '../widgets/covers_source_toggle.dart';
import '../widgets/data_accuracy_applicability.dart';
import '../widgets/hierarchy_map_picker.dart';
import '../widgets/keyed_service_period_accuracy_card.dart';
import 'package:forge_and_flow/widgets/console/console_info_button.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import '../widgets/polling_tier_status_card.dart';
import '../widgets/vendor_relativity_label.dart';
import '../widgets/wage_source_toggle.dart';
import '../widgets/walk_in_handling_card.dart';
import 'wage_authority_screen.dart';
import '../../domain/models/data_accuracy_service_period_setting.dart';
import '../../domain/models/data_accuracy_settings.dart';
import '../../domain/models/service_period_definition.dart';
import '../../domain/services/service_period_definition_resolver.dart';
import '../../services/restaurant_timing_config_read_service.dart';
import '../../integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_models.dart';
import '../../theme/app_theme.dart';

/// Roles permitted to edit data accuracy from the operator-web
/// console. Mirrors the Vendor connections gate. Operator owners
/// read+write; location managers see a friendly forbidden
/// surface (read-mostly role).
// G7d (spec §2.B/§3): v2 catalog constant. Phantom
// `'operator_admin'` dropped (folded into `operator_owner`).
// Live-path neutral — the snapshot permission key is
// authoritative for real sessions; this is the empty-snapshot
// (demo + boot) fallback only.
const Set<String> kOperatorWebDataAccuracyAdmittedRoles = <String>{
  PermissionKeys.roleOperatorOwner,
};

/// Default polling tier surfaced when nothing else is wired in. Lane
/// .A's `ForgeFlowPollingTierRepository` lands the live read in the
/// follow-up `.live` slice; until then the screen renders the
/// canonical Standard tier cadences from
/// `lib/services/integration/polling_tier_presets.dart` (Lane `.0a`)
/// filtered to whichever poll-only vendors the operator has
/// connected.
PollingTierStatus _kDefaultStandardTier(VendorConnectionsBundle? bundle) {
  return PollingTierStatus(
    tier: PollingTierLabel.standard,
    tierDisplayLabel: 'Standard',
    monthlyPriceLabel: 'Bundled with subscription',
    perVendorCadenceSeconds: defaultConnectedPollingCadences(bundle),
  );
}

PollingTierStatus _tierStatusFromSnapshot(OperatorWebPollingTierSnapshot row) {
  final tier = switch (row.tierKey) {
    'premium' => PollingTierLabel.premium,
    'custom' => PollingTierLabel.custom,
    _ => PollingTierLabel.standard,
  };
  final label = switch (tier) {
    PollingTierLabel.standard => 'Standard',
    PollingTierLabel.premium => 'Premium',
    PollingTierLabel.custom => 'Custom',
  };
  final cents = row.monthlyPriceCents;
  return PollingTierStatus(
    tier: tier,
    tierDisplayLabel: label,
    monthlyPriceLabel: cents == null
        ? 'Bundled with subscription'
        : '\$${(cents / 100).toStringAsFixed(2)}/month',
    perVendorCadenceSeconds: row.pollingCadencePerVendorSeconds,
  );
}

/// Today's business date in restaurant-local. The screen takes a
/// fixed string for testability — production wires
/// [BusinessDayClock] in the follow-up.
String _yesterdayIso(String today) {
  final t = DateTime.parse(today);
  final y = t.subtract(const Duration(days: 1));
  return '${y.year.toString().padLeft(4, '0')}-'
      '${y.month.toString().padLeft(2, '0')}-'
      '${y.day.toString().padLeft(2, '0')}';
}

/// Operator Web Console Data Accuracy screen.
class DataAccuracyScreen extends StatefulWidget {
  const DataAccuracyScreen({
    super.key,
    required this.session,
    required this.locationId,
    this.locationName,
    this.gateway,
    this.initialSettings,
    this.dataAccuracyGateway,
    this.vendorApplicabilityGateway,
    required this.businessDateIso,
    this.tierStatus,
    this.walkInModeOverride,
    this.onSaveSettings,
    this.onRequestTierChange,
    this.pollingTierActionLabel = 'Request faster data freshness',
    this.pollingTierActionDescription =
        'Request a change when poll-only vendors need fresher data than '
        'this tier provides.',
    this.pollingTierActionIcon = Icons.bolt_outlined,
    this.pollingTierActionEnabled = true,
    this.pollingTierActionAvailableWhenNotApplicable = false,
    this.tierEmailGateway,
    this.tierEmailIdempotencyKeyFactory,
    this.wageAuthorityGateway,
    this.wageAuthorityIdempotencyKeyFactory,
    this.hierarchyNodes = const <HierarchyMapNode>[],
    this.ancestorOrgUnitIdsNearestFirst = const <String>[],
    this.businessName,
    this.servicePeriodsLoader,
    this.scrollToWageAuthority = false,
  });

  final OperatorWebSession session;
  final String locationId;
  final String? locationName;

  /// Optional gateway — falls back to an in-memory gateway when
  /// omitted (demo / widget tests).
  final VendorConnectionsGateway? gateway;

  /// Seeded settings. When null, the screen renders defaults
  /// (covers_source_* = vendor; wage_source = vendor; empty manual
  /// entries).
  final DataAccuracySettings? initialSettings;

  /// Optional live gateway. When present, the screen hydrates from and
  /// saves to the server-owned data_accuracy_settings row for the
  /// selected operator/location.
  final OperatorWebDataAccuracyGateway? dataAccuracyGateway;

  /// B10.2 read-only gateway for current vendor_applicability wage rows.
  final WebVendorApplicabilityGateway? vendorApplicabilityGateway;

  final String businessDateIso;

  /// Optional polling tier override. Demo + widget tests pass a
  /// fixture; production wires Lane .A's
  /// `ForgeFlowPollingTierRepository` in the follow-up.
  final PollingTierStatus? tierStatus;

  /// Optional pre-set walk-in mode (test fixture).
  final WalkInHandlingMode? walkInModeOverride;

  /// Optional save hook — production wires Lane .A's
  /// `DataAccuracySettingsRepository.upsert`. Demo: no-op.
  final void Function(DataAccuracySettings)? onSaveSettings;

  /// Optional ticket-flow opener. Default opens
  /// [showPollingTierChangeRequestDialog].
  final Future<String?> Function(BuildContext)? onRequestTierChange;
  final String pollingTierActionLabel;
  final String pollingTierActionDescription;
  final IconData pollingTierActionIcon;
  final bool pollingTierActionEnabled;
  final bool pollingTierActionAvailableWhenNotApplicable;

  /// Wave 2 U-FU-tier-email — gateway for the "Request faster data
  /// freshness" dialog. When the dialog submits, the screen calls
  /// [OperatorWebTierEmailGateway.submitDataFreshnessRequest] so the
  /// proxy emits a hash-chained audit row + attempts a SendGrid send
  /// to F&F support. Null in widget tests that want the dialog to
  /// remain inert; production binds the HTTP gateway and demo binds
  /// the in-memory variant.
  final OperatorWebTierEmailGateway? tierEmailGateway;

  /// Test-injectable idempotency-key factory for tier-email
  /// submissions. Production binds the proxy client's random
  /// generator; tests pass a deterministic counter.
  final String Function()? tierEmailIdempotencyKeyFactory;

  /// Wave 2 S-2 (`debug.md:220`, OW-13c): the Wage Authority surface
  /// folds under the Data Accuracy page. When wired, the section saves
  /// and reads wage rows through this gateway; when null the embedded
  /// section renders honest read-only state (same fallback the
  /// standalone screen used at S-1).
  final OperatorWebWageAuthorityGateway? wageAuthorityGateway;

  /// Test-injectable idempotency-key factory passed through to the
  /// embedded [WageAuthoritySection]. Production wires the live
  /// random-bytes generator; tests pass a deterministic counter.
  final String Function()? wageAuthorityIdempotencyKeyFactory;

  /// Operator hierarchy passed through to the embedded Wage Authority
  /// section so scope inheritance stays visible inside Data Accuracy.
  final List<HierarchyMapNode> hierarchyNodes;
  final List<String> ancestorOrgUnitIdsNearestFirst;
  final String? businessName;

  /// Per-Daypart V1 Slice R5 (Gap 27/36): resolves the operator's
  /// configured service periods so the covers cards iterate the real
  /// period set, never a hardcoded `Daypart.values` triplet.
  /// Production resolves the persisted timing config; widget tests
  /// inject a fake. Falls back to the canonical fixture-era
  /// definitions only when no config is persisted yet.
  final Future<List<ServicePeriodDefinition>> Function()? servicePeriodsLoader;

  /// When opened from Plan, start near the embedded Wage authority section.
  final bool scrollToWageAuthority;

  bool get _canEditDataAccuracy =>
      session.roles.any(kOperatorWebDataAccuracyAdmittedRoles.contains);

  @override
  State<DataAccuracyScreen> createState() => _DataAccuracyScreenState();
}

class _DataAccuracyScreenState extends State<DataAccuracyScreen> {
  final GlobalKey _wageAuthoritySectionKey = GlobalKey();
  late VendorConnectionsGateway _gateway;
  VendorConnectionsBundle? _bundle;
  PollingTierStatus? _loadedTierStatus;
  bool _tierLoading = false;
  int _tierLoadGeneration = 0;
  bool _loading = true;
  String? _loadError;
  int _loadGeneration = 0;
  bool _settingsLoading = false;
  String? _settingsLoadError;
  String? _settingsSaveError;
  bool _savingSettings = false;
  int _settingsLoadGeneration = 0;
  int _settingsSaveGeneration = 0;
  DataAccuracySettings? _lastSettings;
  bool _wageApplicabilityLoading = false;
  String? _wageApplicabilityError;
  List<WebVendorApplicabilityRow> _wageApplicabilityRows =
      const <WebVendorApplicabilityRow>[];
  int _wageApplicabilityLoadGeneration = 0;
  List<WebVendorApplicabilityRow> _coversApplicabilityRows =
      const <WebVendorApplicabilityRow>[];
  bool _coversApplicabilityLoading = false;
  String? _coversApplicabilityError;
  int _coversApplicabilityLoadGeneration = 0;
  List<WebVendorApplicabilityRow> _pollingApplicabilityRows =
      const <WebVendorApplicabilityRow>[];
  String? _pollingApplicabilityError;
  int _pollingApplicabilityLoadGeneration = 0;

  // Keyed `data_accuracy_service_period_settings` rows (server-owned;
  // mobile mirrors them through operational sync). The screen reads
  // them at hydrate time and writes through
  // [OperatorWebDataAccuracyGateway.saveServicePeriodSetting], which
  // hits the same scoped PATCH route the mobile-operational write
  // surface exposes.
  List<DataAccuracyServicePeriodSetting> _servicePeriodRows =
      const <DataAccuracyServicePeriodSetting>[];
  bool _servicePeriodsLoading = false;
  bool _savingServicePeriod = false;
  String? _servicePeriodLoadError;
  String? _servicePeriodSaveError;
  int _servicePeriodLoadGeneration = 0;
  int _servicePeriodSaveGeneration = 0;

  // Operator-configured service periods (resolver-ordered). The
  // covers cards iterate this set, never a hardcoded daypart triplet
  // (Gap 27/36). Empty until the loader resolves; the cards render an
  // honest "no periods configured" hint while empty.
  List<ServicePeriodDefinition> _servicePeriods =
      const <ServicePeriodDefinition>[];
  int _servicePeriodsLoadGeneration = 0;

  // In-memory editable working copy of the settings. Materialized
  // back into `DataAccuracySettings` on save. Covers source is keyed
  // by the operator-configured service-period id.
  late Map<String, CoversSource> _coversSourcePerPeriod;
  late WageSource _wageSource;
  late Map<String, Map<String, int>> _manualEntries;
  WalkInHandlingMode _walkInMode = WalkInHandlingMode.reservationsOnly;
  int? _walkInDailyCount;
  late Map<String, int> _walkInEntries;
  late bool _pendingInitialWageAuthorityScroll;

  // Active data-accuracy area. The screen shows one area at a time
  // (0 = Labor, 1 = Covers, 2 = Data freshness) so the page stays lean
  // and the operator reads about one source group at a time. Opening
  // the page from Plan (scrollToWageAuthority) lands on the Labor tab,
  // where the Wage authority section lives.
  static const int _kTabLabor = 0;
  static const int _kTabCovers = 1;
  static const int _kTabFreshness = 2;
  late int _activeDataTab;

  bool get _vendorApplicabilityBound =>
      widget.vendorApplicabilityGateway != null;

  List<String> get _applicableWageVendorSlugs => _wageApplicabilityRows
      .map((row) => row.vendorSlug)
      .toList(growable: false);

  List<String> get _applicableCoversVendorSlugs => _coversApplicabilityRows
      .map((row) => row.vendorSlug)
      .toList(growable: false);

  // Vendor slugs the admin has turned OFF for scheduled polling at this
  // (operator, location). DENY model: a current winner
  // (`setting_kind == 'polling'`, `effectiveUntil == null`) with
  // `enabled == false` means OFF. `enabled == true` or no row leaves the
  // vendor polled by default. Consistent with the background worker.
  List<String> get _polledOffVendorSlugs => _pollingApplicabilityRows
      .where(
        (row) =>
            row.settingKind == 'polling' &&
            !row.enabled &&
            row.effectiveUntil == null,
      )
      .map((row) => row.vendorSlug)
      .toList(growable: false);

  @override
  void initState() {
    super.initState();
    _pendingInitialWageAuthorityScroll = widget.scrollToWageAuthority;
    // Labor is the default landing tab, and it is also where the Wage
    // authority section lives, so an open-from-Plan request
    // (scrollToWageAuthority) lands on the same tab.
    _activeDataTab = _kTabLabor;
    _gateway = widget.gateway ?? InMemoryVendorConnectionsGateway();
    _applySettingsSeed(widget.initialSettings);
    _settingsLoading = widget.dataAccuracyGateway != null;
    _wageApplicabilityLoading = widget.vendorApplicabilityGateway != null;
    _coversApplicabilityLoading = widget.vendorApplicabilityGateway != null;
    _servicePeriodsLoading = widget.dataAccuracyGateway != null;
    _tierLoading = widget.dataAccuracyGateway != null;
    _loadBundle();
    _loadTierStatus();
    _loadSettings();
    _loadWageApplicability();
    _loadCoversApplicability();
    _loadPollingApplicability();
    _loadServicePeriodSettings();
    _loadServicePeriods();
  }

  Future<void> _loadServicePeriods() async {
    final generation = ++_servicePeriodsLoadGeneration;
    final loader = widget.servicePeriodsLoader ?? _defaultServicePeriodsLoader;
    try {
      final periods = await loader();
      if (!mounted || generation != _servicePeriodsLoadGeneration) return;
      setState(() {
        _servicePeriods = periods;
        _normalizeWorkingSources();
      });
    } catch (_) {
      if (!mounted || generation != _servicePeriodsLoadGeneration) return;
      setState(() {
        _servicePeriods = ServicePeriodDefinitionResolver.ordered(
          ServicePeriodDefinitionResolver.demoDefinitions,
        );
        _normalizeWorkingSources();
      });
    }
  }

  // Canonical pattern (benchmark_tracker_read_service.dart): period
  // set + labels + ordering come from the operator's persisted timing
  // config, never a hardcoded daypart list. Falls back to the
  // canonical fixture-era definitions only when no config is persisted
  // yet.
  static Future<List<ServicePeriodDefinition>>
  _defaultServicePeriodsLoader() async {
    final config = await RestaurantTimingConfigReadService.instance
        .getActiveTimingConfig();
    final defs = (config?.servicePeriodDefinitions.isNotEmpty ?? false)
        ? config!.servicePeriodDefinitions
        : ServicePeriodDefinitionResolver.demoDefinitions;
    return ServicePeriodDefinitionResolver.ordered(defs);
  }

  Future<void> _loadBundle() async {
    final generation = ++_loadGeneration;
    try {
      final bundle = await _gateway.loadBundle(
        operatorId: widget.session.operatorId,
        locationId: widget.locationId,
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _bundle = bundle;
        _normalizeWorkingSources();
        _loadError = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loadError = 'Could not load vendor integration context: $error';
        _loading = false;
      });
    }
  }

  Future<void> _loadTierStatus() async {
    final generation = ++_tierLoadGeneration;
    final gateway = widget.dataAccuracyGateway;
    if (gateway == null) {
      _tierLoading = false;
      return;
    }
    try {
      final snapshot = await gateway.loadPollingTierAssignment(
        operatorId: widget.session.operatorId,
        locationId: widget.locationId,
      );
      if (!mounted || generation != _tierLoadGeneration) return;
      setState(() {
        _loadedTierStatus = snapshot == null
            ? null
            : _tierStatusFromSnapshot(snapshot);
        _tierLoading = false;
      });
    } catch (_) {
      if (!mounted || generation != _tierLoadGeneration) return;
      setState(() => _tierLoading = false);
    }
  }

  @override
  void didUpdateWidget(covariant DataAccuracyScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.scrollToWageAuthority && widget.scrollToWageAuthority) {
      _pendingInitialWageAuthorityScroll = true;
    }
    if (oldWidget.gateway != widget.gateway ||
        oldWidget.locationId != widget.locationId ||
        oldWidget.session.operatorId != widget.session.operatorId ||
        oldWidget.dataAccuracyGateway != widget.dataAccuracyGateway ||
        oldWidget.vendorApplicabilityGateway !=
            widget.vendorApplicabilityGateway ||
        oldWidget.servicePeriodsLoader != widget.servicePeriodsLoader) {
      _gateway = widget.gateway ?? InMemoryVendorConnectionsGateway();
      setState(() {
        _loading = true;
        _loadError = null;
        _settingsLoading = widget.dataAccuracyGateway != null;
        _settingsLoadError = null;
        _settingsSaveError = null;
        _loadedTierStatus = null;
        _tierLoading = widget.dataAccuracyGateway != null;
        _wageApplicabilityLoading = widget.vendorApplicabilityGateway != null;
        _wageApplicabilityError = null;
        _wageApplicabilityRows = const <WebVendorApplicabilityRow>[];
        _coversApplicabilityLoading = widget.vendorApplicabilityGateway != null;
        _coversApplicabilityError = null;
        _coversApplicabilityRows = const <WebVendorApplicabilityRow>[];
        _pollingApplicabilityError = null;
        _pollingApplicabilityRows = const <WebVendorApplicabilityRow>[];
        _servicePeriodsLoading = widget.dataAccuracyGateway != null;
        _servicePeriodLoadError = null;
        _servicePeriodSaveError = null;
        _servicePeriodRows = const <DataAccuracyServicePeriodSetting>[];
        _servicePeriods = const <ServicePeriodDefinition>[];
      });
      _loadBundle();
      _loadTierStatus();
      _loadSettings();
      _loadWageApplicability();
      _loadCoversApplicability();
      _loadPollingApplicability();
      _loadServicePeriodSettings();
      _loadServicePeriods();
    }
  }

  void _scheduleWageAuthorityScrollIfNeeded() {
    if (!_pendingInitialWageAuthorityScroll) return;
    _pendingInitialWageAuthorityScroll = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final targetContext = _wageAuthoritySectionKey.currentContext;
      if (targetContext == null) return;
      Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignment: 0.06,
      );
    });
  }

  Future<void> _loadSettings() async {
    final gateway = widget.dataAccuracyGateway;
    if (gateway == null) {
      _settingsLoading = false;
      return;
    }
    final generation = ++_settingsLoadGeneration;
    try {
      final settings = await gateway.loadSettings(
        operatorId: widget.session.operatorId,
        locationId: widget.locationId,
      );
      if (!mounted || generation != _settingsLoadGeneration) return;
      setState(() {
        if (settings != null) _applySettingsSeed(settings);
        _normalizeWorkingSources();
        _settingsLoading = false;
        _settingsLoadError = null;
      });
    } catch (error) {
      if (!mounted || generation != _settingsLoadGeneration) return;
      setState(() {
        _settingsLoading = false;
        _settingsLoadError = 'Could not load data accuracy settings: $error';
      });
    }
  }

  Future<void> _loadWageApplicability() async {
    final gateway = widget.vendorApplicabilityGateway;
    if (gateway == null) {
      _wageApplicabilityLoading = false;
      return;
    }
    final generation = ++_wageApplicabilityLoadGeneration;
    try {
      final rows = await gateway.list(settingKind: 'wage');
      final currentEnabled =
          rows
              .where(
                (row) =>
                    row.settingKind == 'wage' &&
                    row.enabled &&
                    row.effectiveUntil == null,
              )
              .toList(growable: false)
            ..sort((a, b) => a.vendorSlug.compareTo(b.vendorSlug));
      if (!mounted || generation != _wageApplicabilityLoadGeneration) return;
      setState(() {
        _wageApplicabilityRows = currentEnabled;
        _normalizeWorkingSources();
        _wageApplicabilityLoading = false;
        _wageApplicabilityError = null;
      });
    } catch (error) {
      if (!mounted || generation != _wageApplicabilityLoadGeneration) return;
      setState(() {
        _wageApplicabilityRows = const <WebVendorApplicabilityRow>[];
        _wageApplicabilityLoading = false;
        _wageApplicabilityError =
            'Could not load wage vendor applicability: $error';
      });
    }
  }

  // Mirrors [_loadWageApplicability] for the `covers` setting kind. The
  // allow-list gates the vendor-backed covers chips (POS covers,
  // reservations + walk-ins) on top of the existing capability check;
  // it cannot loosen the capability check, so the read is additive.
  // On error the rows stay empty, which mirrors wage: the vendor-backed
  // covers options stay restricted rather than silently re-opening.
  Future<void> _loadCoversApplicability() async {
    final gateway = widget.vendorApplicabilityGateway;
    if (gateway == null) {
      _coversApplicabilityLoading = false;
      return;
    }
    final generation = ++_coversApplicabilityLoadGeneration;
    try {
      final rows = await gateway.list(settingKind: 'covers');
      final currentEnabled =
          rows
              .where(
                (row) =>
                    row.settingKind == 'covers' &&
                    row.enabled &&
                    row.effectiveUntil == null,
              )
              .toList(growable: false)
            ..sort((a, b) => a.vendorSlug.compareTo(b.vendorSlug));
      if (!mounted || generation != _coversApplicabilityLoadGeneration) return;
      setState(() {
        _coversApplicabilityRows = currentEnabled;
        _coversApplicabilityLoading = false;
        _normalizeWorkingSources();
        _coversApplicabilityError = null;
      });
    } catch (error) {
      if (!mounted || generation != _coversApplicabilityLoadGeneration) return;
      setState(() {
        _coversApplicabilityRows = const <WebVendorApplicabilityRow>[];
        _coversApplicabilityLoading = false;
        _normalizeWorkingSources();
        _coversApplicabilityError =
            'Could not load vendor approval for covers: $error';
      });
    }
  }

  // Mirrors [_loadCoversApplicability] for the `polling` setting kind.
  // Unlike wage/covers (allow-list), polling is a DENY model: the card
  // is interested in current winners that are turned OFF
  // (`enabled == false`), so we keep ALL current rows
  // (`effectiveUntil == null`) here and let [_polledOffVendorSlugs]
  // select the disabled ones. On error the rows stay empty, which means
  // "no turn-offs": the card keeps its default polled behavior rather
  // than silently hiding vendors.
  Future<void> _loadPollingApplicability() async {
    final gateway = widget.vendorApplicabilityGateway;
    if (gateway == null) return;
    final generation = ++_pollingApplicabilityLoadGeneration;
    try {
      final rows = await gateway.list(settingKind: 'polling');
      final current =
          rows
              .where(
                (row) =>
                    row.settingKind == 'polling' && row.effectiveUntil == null,
              )
              .toList(growable: false)
            ..sort((a, b) => a.vendorSlug.compareTo(b.vendorSlug));
      if (!mounted || generation != _pollingApplicabilityLoadGeneration) return;
      setState(() {
        _pollingApplicabilityRows = current;
        _pollingApplicabilityError = null;
      });
    } catch (error) {
      if (!mounted || generation != _pollingApplicabilityLoadGeneration) return;
      setState(() {
        _pollingApplicabilityRows = const <WebVendorApplicabilityRow>[];
        _pollingApplicabilityError =
            'Could not load data freshness vendor approval: $error';
      });
    }
  }

  void _applySettingsSeed(DataAccuracySettings? seed) {
    _lastSettings = seed;
    _coversSourcePerPeriod = <String, CoversSource>{
      for (final e in (seed?.coversSourcePerServicePeriod ?? const {}).entries)
        e.key: e.value,
    };
    _wageSource = seed?.wageSource ?? WageSource.vendor;
    _manualEntries = <String, Map<String, int>>{
      for (final e in (seed?.coversManualEntries ?? const {}).entries)
        e.key: Map<String, int>.from(e.value),
    };
    _walkInEntries = <String, int>{
      for (final e in (seed?.walkInManualEntries ?? const {}).entries)
        e.key: e.value,
    };
    _walkInMode =
        widget.walkInModeOverride ??
        _widgetWalkInModeFromDomain(
          seed?.walkInHandlingMode ??
              DataAccuracyWalkInHandlingMode.reservationsOnly,
        );
    _walkInDailyCount = seed?.dailyWalkInCountFor(widget.businessDateIso);
  }

  void _normalizeWorkingSources() {
    final bundle = _bundle;
    if (bundle == null) return;
    if (!_vendorApplicabilityBound || !_wageApplicabilityLoading) {
      _wageSource = effectiveWageSource(
        configured: _wageSource,
        bundle: bundle,
        vendorApplicabilityBound: _vendorApplicabilityBound,
        applicableWageVendorSlugs: _applicableWageVendorSlugs,
      );
    }
    if (_servicePeriods.isEmpty) return;
    _coversSourcePerPeriod = <String, CoversSource>{
      ..._coversSourcePerPeriod,
      for (final period in _servicePeriods)
        period.id: effectiveCoversSourceHonoringApplicability(
          configured: _coversSourcePerPeriod[period.id] ?? kDefaultCoversSource,
          bundle: bundle,
          vendorApplicabilityBound:
              _vendorApplicabilityBound && !_coversApplicabilityLoading,
          applicableCoversVendorSlugs: _applicableCoversVendorSlugs,
        ),
    };
  }

  // ── Settings materialization ────────────────────────────────────

  DataAccuracySettings _materialize() {
    final now = DateTime.now().toUtc();
    final base = _lastSettings ?? widget.initialSettings;
    return DataAccuracySettings(
      settingId: base?.settingId ?? 'demo-setting-id',
      operatorId: widget.session.operatorId,
      locationId: widget.locationId,
      coversSourcePerServicePeriod: Map<String, CoversSource>.from(
        _coversSourcePerPeriod,
      ),
      coversSourcePerServicePeriodSources:
          Map<String, DataAccuracySettingSource>.from(
            base?.coversSourcePerServicePeriodSources ??
                const <String, DataAccuracySettingSource>{},
          ),
      coversManualEntries: <String, Map<String, int>>{
        for (final e in _manualEntries.entries)
          e.key: Map<String, int>.from(e.value),
      },
      wageSource: _wageSource,
      wageSourceSource: base?.wageSourceSource,
      walkInHandlingMode: _domainWalkInModeFromWidget(_walkInMode),
      walkInHandlingModeSource: base?.walkInHandlingModeSource,
      walkInManualEntries: Map<String, int>.from(_walkInEntries),
      createdAt: base?.createdAt ?? now,
      updatedAt: now,
      updatedBy: widget.session.uid,
    );
  }

  void _emitSave() {
    final settings = _materialize();
    widget.onSaveSettings?.call(settings);
    final gateway = widget.dataAccuracyGateway;
    if (gateway != null) unawaited(_saveSettings(gateway, settings));
  }

  Future<void> _loadServicePeriodSettings() async {
    final gateway = widget.dataAccuracyGateway;
    if (gateway == null) {
      _servicePeriodsLoading = false;
      return;
    }
    final generation = ++_servicePeriodLoadGeneration;
    try {
      final rows = await gateway.loadServicePeriodSettings(
        operatorId: widget.session.operatorId,
        locationId: widget.locationId,
      );
      if (!mounted || generation != _servicePeriodLoadGeneration) return;
      setState(() {
        _servicePeriodRows = rows;
        _servicePeriodsLoading = false;
        _servicePeriodLoadError = null;
      });
    } catch (error) {
      if (!mounted || generation != _servicePeriodLoadGeneration) return;
      setState(() {
        _servicePeriodsLoading = false;
        _servicePeriodLoadError =
            'Could not load service-period overrides: $error';
      });
    }
  }

  Future<void> _saveKeyedServicePeriod(
    KeyedServicePeriodAccuracyDraft draft,
  ) async {
    final gateway = widget.dataAccuracyGateway;
    if (gateway == null) return;
    final generation = ++_servicePeriodSaveGeneration;
    setState(() {
      _savingServicePeriod = true;
      _servicePeriodSaveError = null;
    });
    try {
      await gateway.saveServicePeriodSetting(
        operatorId: widget.session.operatorId,
        locationId: widget.locationId,
        servicePeriodKey: draft.servicePeriodKey,
        coversSource: draft.coversSource,
        wageSource: draft.wageSource,
        effectiveAtBusinessDateIso: draft.effectiveAtBusinessDateIso,
      );
      if (!mounted || generation != _servicePeriodSaveGeneration) return;
      setState(() {
        _savingServicePeriod = false;
        _servicePeriodSaveError = null;
      });
      // Refresh both the keyed list and the primary source state so
      // the covers/manual cards do not stay on stale effective values.
      await Future.wait(<Future<void>>[
        _loadServicePeriodSettings(),
        _loadSettings(),
      ]);
    } catch (error) {
      if (!mounted || generation != _servicePeriodSaveGeneration) return;
      setState(() {
        _savingServicePeriod = false;
        _servicePeriodSaveError =
            'Could not save service-period override: $error';
      });
    }
  }

  Future<void> _resetKeyedServicePeriod(
    DataAccuracyServicePeriodSetting row,
  ) async {
    final gateway = widget.dataAccuracyGateway;
    if (gateway == null) return;
    final generation = ++_servicePeriodSaveGeneration;
    setState(() {
      _savingServicePeriod = true;
      _servicePeriodSaveError = null;
    });
    try {
      await gateway.resetServicePeriodSetting(
        operatorId: widget.session.operatorId,
        locationId: widget.locationId,
        servicePeriodKey: row.servicePeriodKey,
      );
      if (!mounted || generation != _servicePeriodSaveGeneration) return;
      setState(() {
        _savingServicePeriod = false;
        _servicePeriodSaveError = null;
      });
      await Future.wait(<Future<void>>[
        _loadServicePeriodSettings(),
        _loadSettings(),
      ]);
    } catch (error) {
      if (!mounted || generation != _servicePeriodSaveGeneration) return;
      setState(() {
        _savingServicePeriod = false;
        _servicePeriodSaveError =
            'Could not reset service-period override: $error';
      });
    }
  }

  Future<void> _saveSettings(
    OperatorWebDataAccuracyGateway gateway,
    DataAccuracySettings settings,
  ) async {
    final generation = ++_settingsSaveGeneration;
    setState(() {
      _savingSettings = true;
      _settingsSaveError = null;
    });
    try {
      final saved = await gateway.saveSettings(settings);
      if (!mounted || generation != _settingsSaveGeneration) return;
      setState(() {
        _applySettingsSeed(saved);
        _savingSettings = false;
        _settingsSaveError = null;
      });
    } catch (error) {
      if (!mounted || generation != _settingsSaveGeneration) return;
      setState(() {
        _savingSettings = false;
        _settingsSaveError = 'Could not save data accuracy settings: $error';
      });
    }
  }

  // ── Handlers ────────────────────────────────────────────────────

  Future<void> _clearManualCovers(
    OperatorWebDataAccuracyGateway gateway, {
    required String businessDateIso,
    required String servicePeriodId,
  }) async {
    final generation = ++_settingsSaveGeneration;
    setState(() {
      _savingSettings = true;
      _settingsSaveError = null;
    });
    try {
      final saved = await gateway.clearManualCovers(
        operatorId: widget.session.operatorId,
        locationId: widget.locationId,
        businessDateIso: businessDateIso,
        servicePeriodKey: servicePeriodId,
      );
      if (!mounted || generation != _settingsSaveGeneration) return;
      setState(() {
        _applySettingsSeed(saved);
        _savingSettings = false;
        _settingsSaveError = null;
      });
    } catch (error) {
      if (!mounted || generation != _settingsSaveGeneration) return;
      setState(() {
        _savingSettings = false;
        _settingsSaveError = 'Could not clear manual covers: $error';
      });
    }
  }

  Future<void> _saveManualCovers(
    OperatorWebDataAccuracyGateway gateway, {
    required String businessDateIso,
    required String servicePeriodId,
    required int covers,
  }) async {
    final generation = ++_settingsSaveGeneration;
    setState(() {
      _savingSettings = true;
      _settingsSaveError = null;
    });
    try {
      final saved = await gateway.saveManualCovers(
        operatorId: widget.session.operatorId,
        locationId: widget.locationId,
        businessDateIso: businessDateIso,
        servicePeriodKey: servicePeriodId,
        covers: covers,
      );
      if (!mounted || generation != _settingsSaveGeneration) return;
      setState(() {
        _applySettingsSeed(saved);
        _savingSettings = false;
        _settingsSaveError = null;
      });
    } catch (error) {
      if (!mounted || generation != _settingsSaveGeneration) return;
      setState(() {
        _savingSettings = false;
        _settingsSaveError = 'Could not save manual covers: $error';
      });
    }
  }

  void _handleWageSourceChanged(WageSource value) {
    setState(() => _wageSource = value);
    _emitSave();
  }

  void _handleCoversSourceChanged(String servicePeriodId, CoversSource value) {
    setState(() {
      _coversSourcePerPeriod = <String, CoversSource>{
        ..._coversSourcePerPeriod,
        servicePeriodId: value,
      };
    });
    _emitSave();
  }

  void _handleManualEntry(String servicePeriodId, int? covers) {
    final today = widget.businessDateIso;
    setState(() {
      final dayMap = _manualEntries.putIfAbsent(today, () => <String, int>{});
      if (covers == null) {
        dayMap.remove(servicePeriodId);
        if (dayMap.isEmpty) _manualEntries.remove(today);
      } else {
        dayMap[servicePeriodId] = covers;
      }
    });
    final gateway = widget.dataAccuracyGateway;
    if (covers == null && gateway != null) {
      unawaited(
        _clearManualCovers(
          gateway,
          businessDateIso: today,
          servicePeriodId: servicePeriodId,
        ),
      );
      return;
    }
    if (covers != null && gateway != null) {
      unawaited(
        _saveManualCovers(
          gateway,
          businessDateIso: today,
          servicePeriodId: servicePeriodId,
          covers: covers,
        ),
      );
      return;
    }
    _emitSave();
  }

  void _handleCopyYesterday(String servicePeriodId) {
    final yesterday = _yesterdayIso(widget.businessDateIso);
    final value = _manualEntries[yesterday]?[servicePeriodId];
    if (value == null) return;
    _handleManualEntry(servicePeriodId, value);
  }

  void _handleApplySeed(Map<String, Map<String, int>> seed) {
    setState(() {
      seed.forEach((dateIso, dayMap) {
        final existing = _manualEntries.putIfAbsent(
          dateIso,
          () => <String, int>{},
        );
        dayMap.forEach((servicePeriodId, covers) {
          existing[servicePeriodId] = covers;
        });
      });
    });
    _emitSave();
  }

  void _handleWalkInModeChanged(WalkInHandlingMode value) {
    setState(() => _walkInMode = value);
    _emitSave();
  }

  void _handleWalkInCountChanged(int? value) {
    setState(() {
      _walkInDailyCount = value;
      if (value == null) {
        _walkInEntries.remove(widget.businessDateIso);
      } else {
        _walkInEntries[widget.businessDateIso] = value;
      }
    });
    _emitSave();
  }

  void _handleWalkInServicePeriodCountChanged(
    String servicePeriodId,
    int? value,
  ) {
    final key = DataAccuracySettings.walkInManualEntryKey(
      widget.businessDateIso,
      servicePeriodId,
    );
    setState(() {
      if (value == null) {
        _walkInEntries.remove(key);
      } else {
        _walkInEntries[key] = value;
      }
    });
    _emitSave();
  }

  Map<String, int> _walkInCountsByServicePeriod() {
    return <String, int>{
      for (final period in _servicePeriods)
        if (_walkInEntries[DataAccuracySettings.walkInManualEntryKey(
              widget.businessDateIso,
              period.id,
            )]
            case final count?)
          period.id: count,
    };
  }

  Future<void> _handleRequestTierChange() async {
    final opener =
        widget.onRequestTierChange ??
        (BuildContext ctx) => showPollingTierChangeRequestDialog(ctx);
    final reason = await opener(context);
    if (reason == null) return;
    final trimmedReason = reason.trim();
    if (trimmedReason.isEmpty) return;
    if (!mounted) return;
    final gateway = widget.tierEmailGateway;
    if (gateway == null) {
      // No gateway wired — capture the request at the dialog level
      // and surface a muted toast so the operator does not believe
      // the request was delivered. Production deploys MUST bind the
      // gateway.
      _showTierEmailToast(
        message: 'Request captured. Tell F&F support so they can pick it up.',
        isSuccess: false,
      );
      return;
    }
    final tier = _displayTierStatus ?? _kDefaultStandardTier(_bundle);
    final idempotencyKey =
        widget.tierEmailIdempotencyKeyFactory?.call() ??
        _defaultTierEmailIdempotencyKey();
    final result = await gateway.submitDataFreshnessRequest(
      request: OperatorTierEmailRequest(
        currentTier: tier.tierDisplayLabel,
        requestedCadence: 'Faster than current tier',
        businessReason: trimmedReason,
      ),
      idempotencyKey: idempotencyKey,
    );
    if (!mounted) return;
    switch (result.kind) {
      case OperatorTierEmailResultKind.emailSent:
        _showTierEmailToast(
          message: 'Request submitted and emailed to F&F support.',
          isSuccess: true,
        );
        break;
      case OperatorTierEmailResultKind.emailFailed:
      case OperatorTierEmailResultKind.submitFailed:
        _showTierEmailToast(
          message: 'Request submitted to F&F support.',
          isSuccess: false,
        );
        break;
    }
  }

  /// Per-dialog-session idempotency key. Retries from the dialog
  /// hash to the same row; production injects the proxy client's
  /// secure factory via [widget.tierEmailIdempotencyKeyFactory].
  String _defaultTierEmailIdempotencyKey() {
    final ts = DateTime.now().toUtc().microsecondsSinceEpoch;
    final rand = (ts ^ widget.session.uid.hashCode).toRadixString(16);
    return 'tier-email-$rand';
  }

  void _showTierEmailToast({required String message, required bool isSuccess}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: Key(
            isSuccess
                ? 'polling_tier_email_toast_sent'
                : 'polling_tier_email_toast_failed',
          ),
          content: Text(message),
          backgroundColor: isSuccess ? AppColors.peacock : AppColors.sunsetDark,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
  }

  // ── Conditional card visibility ─────────────────────────────────

  bool get _posExposesCovers {
    final pos = _bundle?.posConnection;
    if (pos == null) return true; // assume exposed when no POS yet.
    return posVendorExposesCovers(pos.vendorId);
  }

  bool get _hasReservationConnection => _bundle?.reservationConnection != null;

  bool get _anyDaypartReservationPlusWalkin => _servicePeriods.any(
    (p) =>
        (_coversSourcePerPeriod[p.id] ?? kDefaultCoversSource) ==
        CoversSource.reservationPlusWalkin,
  );

  bool get _showWalkInCard =>
      _hasReservationConnection &&
      (!_posExposesCovers || _anyDaypartReservationPlusWalkin);

  bool get _showHistoricalSeedCard => !_posExposesCovers;

  bool get _anyDaypartManual => _servicePeriods.any(
    (p) =>
        (_coversSourcePerPeriod[p.id] ?? kDefaultCoversSource) ==
        CoversSource.manual,
  );

  bool get _showAnyFallbackCard =>
      _anyDaypartManual || _showWalkInCard || _showHistoricalSeedCard;

  // True only when at least one CONNECTED poll-only vendor is still
  // polled (i.e. NOT turned off by the admin). Honors the polling
  // applicability DENY model when the gateway is bound; falls back to
  // the connection-only check otherwise.
  bool get _dataFreshnessApplies => dataFreshnessAppliesHonoringApplicability(
    bundle: _bundle,
    vendorApplicabilityBound: _vendorApplicabilityBound,
    turnedOffVendorSlugs: _polledOffVendorSlugs,
  );

  PollingTierStatus? get _displayTierStatus {
    final tier =
        widget.tierStatus ??
        _loadedTierStatus ??
        (_tierLoading ? null : _kDefaultStandardTier(_bundle));
    if (tier == null) return null;
    return PollingTierStatus(
      tier: tier.tier,
      tierDisplayLabel: tier.tierDisplayLabel,
      monthlyPriceLabel: tier.monthlyPriceLabel,
      // Drop the admin-turned-off poll-only vendors from the cadence
      // list so the card only shows vendors F&F still polls.
      perVendorCadenceSeconds: connectedPollingCadencesHonoringApplicability(
        bundle: _bundle,
        source: tier.perVendorCadenceSeconds,
        vendorApplicabilityBound: _vendorApplicabilityBound,
        turnedOffVendorSlugs: _polledOffVendorSlugs,
      ),
    );
  }

  // ── Tab current-value pills ─────────────────────────────────────

  // Labor tab pill: the current wage choice in plain English.
  String get _laborTabValue =>
      _wageSource == WageSource.manualMix ? 'Manual wage mix' : 'Vendor wages';

  // Covers tab pill: the single source name when every configured
  // service period agrees, otherwise "Mixed". Periods absent from the
  // working map resolve to the default source, matching the per-period
  // cards.
  String get _coversTabValue {
    if (_servicePeriods.isEmpty) {
      return _coversSourceShortLabel(kDefaultCoversSource);
    }
    final sources = <CoversSource>{
      for (final period in _servicePeriods)
        _coversSourcePerPeriod[period.id] ?? kDefaultCoversSource,
    };
    if (sources.length == 1) return _coversSourceShortLabel(sources.first);
    return 'Mixed';
  }

  static String _coversSourceShortLabel(CoversSource source) {
    switch (source) {
      case CoversSource.vendor:
        return 'Vendor';
      case CoversSource.forecast:
        return 'Forecast';
      case CoversSource.manual:
        return 'Manual';
      case CoversSource.reservationPlusWalkin:
        return 'Reservations + walk-ins';
    }
  }

  // Data freshness tab pill: the current tier label (e.g. "Standard").
  // Falls back to the canonical Standard label while the tier loads.
  String get _freshnessTabValue =>
      _displayTierStatus?.tierDisplayLabel ?? 'Standard';

  // ── Build ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!widget._canEditDataAccuracy) {
      return _ForbiddenSurface(
        key: const Key('operator_web_data_accuracy_forbidden'),
      );
    }
    if (_loading || _settingsLoading) {
      return const Center(
        key: Key('operator_web_data_accuracy_loading'),
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
    final loadError = _loadError ?? _settingsLoadError;
    if (loadError != null) {
      return Center(
        key: const Key('operator_web_data_accuracy_load_error'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Data accuracy could not load',
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 8),
                Text(
                  loadError,
                  style: AppTextStyles.body13(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 14),
                OutlinedButton(
                  key: const Key('operator_web_data_accuracy_load_retry'),
                  onPressed: () {
                    setState(() {
                      _loading = true;
                      _loadError = null;
                      _settingsLoading = widget.dataAccuracyGateway != null;
                      _settingsLoadError = null;
                      _tierLoading = widget.dataAccuracyGateway != null;
                    });
                    _loadBundle();
                    _loadTierStatus();
                    _loadSettings();
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final settings = _materialize();
    _scheduleWageAuthorityScrollIfNeeded();
    return OperatorWebScreenBody(
      scrollKey: const Key('operator_web_data_accuracy_screen'),
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const OperatorWebScreenHeader(
            icon: Icons.tune_outlined,
            title: 'Data accuracy',
            subtitle: "Where this location's numbers come from.",
          ),
          const SizedBox(height: 22),
          _DataAccuracyTabBar(
            activeTab: _activeDataTab,
            laborValue: _laborTabValue,
            coversValue: _coversTabValue,
            freshnessValue: _freshnessTabValue,
            onTabSelected: (tab) => setState(() => _activeDataTab = tab),
          ),
          const SizedBox(height: 22),
          if (_savingSettings || _settingsSaveError != null) ...[
            _SaveStatusBanner(
              saving: _savingSettings,
              error: _settingsSaveError,
            ),
            const SizedBox(height: 18),
          ],
          if (_activeDataTab == _kTabLabor)
            ..._buildLaborPanel(settings)
          else if (_activeDataTab == _kTabCovers)
            ..._buildCoversPanel(settings)
          else
            ..._buildFreshnessPanel(),
        ],
      ),
    );
  }

  // ── Active-area panels ──────────────────────────────────────────
  //
  // Only the active tab's panel is built, so the page never stacks
  // wasted height behind a hidden area. Each panel preserves the exact
  // widget wiring, keys, and conditional-visibility rules the
  // single-page layout used.

  List<Widget> _buildLaborPanel(DataAccuracySettings settings) {
    final locationLabel = _locationLabel();
    return <Widget>[
      WageSourceToggle(
        value: _wageSource,
        onChanged: _handleWageSourceChanged,
        bundle: _bundle,
        source: settings.wageSourceSource,
        vendorApplicabilityBound: widget.vendorApplicabilityGateway != null,
        vendorApplicabilityLoading: _wageApplicabilityLoading,
        vendorApplicabilityError: _wageApplicabilityError,
        applicableWageVendorSlugs: _applicableWageVendorSlugs,
      ),
      const SizedBox(height: 18),
      KeyedSubtree(
        key: _wageAuthoritySectionKey,
        child: Container(
          key: const Key('operator_web_data_accuracy_wage_authority_section'),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          decoration: BoxDecoration(
            color: AppColors.backgroundSurface,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: WageAuthoritySection(
            session: widget.session,
            locationId: widget.locationId,
            locationName: locationLabel,
            gateway: widget.wageAuthorityGateway,
            idempotencyKeyFactory: widget.wageAuthorityIdempotencyKeyFactory,
            hierarchyNodes: widget.hierarchyNodes,
            ancestorOrgUnitIdsNearestFirst:
                widget.ancestorOrgUnitIdsNearestFirst,
            businessName: widget.businessName,
            showHeader: false,
            editingEnabled: _wageSource == WageSource.manualMix,
            editingDisabledMessage:
                'Manual wage mix is locked while labor vendor wages are selected.',
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildCoversPanel(DataAccuracySettings settings) {
    return <Widget>[
      if (_coversApplicabilityError != null) ...[
        _ApplicabilityWarningBanner(
          key: const Key(
            'operator_web_data_accuracy_covers_applicability_error',
          ),
          message: _coversApplicabilityError!,
        ),
        const SizedBox(height: 14),
      ],
      CoversSourceToggle(
        settings: settings,
        servicePeriods: _servicePeriods,
        onChanged: _handleCoversSourceChanged,
        bundle: _bundle,
        vendorApplicabilityBound:
            widget.vendorApplicabilityGateway != null &&
            !_coversApplicabilityLoading,
        applicableCoversVendorSlugs: _applicableCoversVendorSlugs,
      ),
      if (_showAnyFallbackCard) ...[
        const SizedBox(height: 18),
        const _DataAccuracyGroupLabel(
          title: 'Fallback entries',
          subtitle: 'Shown only for sources that need manual numbers.',
        ),
        const SizedBox(height: 12),
      ],
      if (_anyDaypartManual) ...[
        CoversManualEntryCard(
          businessDateIso: widget.businessDateIso,
          yesterdayBusinessDateIso: _yesterdayIso(widget.businessDateIso),
          settings: settings,
          servicePeriods: _servicePeriods,
          onEnterCovers: _handleManualEntry,
          onCopyYesterday: _handleCopyYesterday,
        ),
      ],
      if (_showWalkInCard) ...[
        const SizedBox(height: 18),
        WalkInHandlingCard(
          mode: _walkInMode,
          onModeChanged: _handleWalkInModeChanged,
          businessDateIso: widget.businessDateIso,
          dailyWalkInCount: _walkInDailyCount,
          servicePeriods: _servicePeriods,
          perPeriodWalkInCounts: _walkInCountsByServicePeriod(),
          source: settings.walkInHandlingModeSource,
          onDailyWalkInCountChanged: _handleWalkInCountChanged,
          onPerPeriodWalkInCountChanged: _handleWalkInServicePeriodCountChanged,
        ),
      ],
      if (_showHistoricalSeedCard) ...[
        const SizedBox(height: 18),
        CoversHistoricalSeedCard(
          endDateIso: _yesterdayIso(widget.businessDateIso),
          dayCount: 60,
          servicePeriods: _servicePeriods,
          initialEntries: <String, Map<String, int>>{
            for (final e in _manualEntries.entries)
              e.key: Map<String, int>.from(e.value),
          },
          onApplySeed: _handleApplySeed,
        ),
      ],
      if (widget.dataAccuracyGateway != null) ...[
        const SizedBox(height: 18),
        const _DataAccuracyGroupLabel(
          title: 'Service-period overrides',
          subtitle: 'Add a covers override for a specific service period.',
        ),
        const SizedBox(height: 12),
        KeyedServicePeriodAccuracyCard(
          rows: _servicePeriodRows,
          busy: _servicePeriodsLoading || _savingServicePeriod,
          loadError: _servicePeriodLoadError,
          saveError: _servicePeriodSaveError,
          editingEnabled: widget._canEditDataAccuracy,
          configuredServicePeriods: _servicePeriods,
          defaultEffectiveAtBusinessDateIso: widget.businessDateIso,
          onAddOrEdit: _saveKeyedServicePeriod,
          onReset: _resetKeyedServicePeriod,
          onRetry: _loadServicePeriodSettings,
        ),
      ],
    ];
  }

  List<Widget> _buildFreshnessPanel() {
    return <Widget>[
      if (_pollingApplicabilityError != null) ...[
        _ApplicabilityWarningBanner(
          key: const Key(
            'operator_web_data_accuracy_polling_applicability_error',
          ),
          message: _pollingApplicabilityError!,
        ),
        const SizedBox(height: 14),
      ],
      PollingTierStatusCard(
        status: _displayTierStatus,
        bundle: _bundle,
        appliesToConnectedVendors: _dataFreshnessApplies,
        onRequestTierChange: _handleRequestTierChange,
        actionLabel: widget.pollingTierActionLabel,
        actionDescription: widget.pollingTierActionDescription,
        actionIcon: widget.pollingTierActionIcon,
        actionEnabled: widget.pollingTierActionEnabled,
        actionAvailableWhenNotApplicable:
            widget.pollingTierActionAvailableWhenNotApplicable,
      ),
    ];
  }

  String _locationLabel() {
    final provided = widget.locationName?.trim();
    if (provided != null && provided.isNotEmpty) return provided;
    if (widget.locationId == widget.session.primaryLocationId) {
      return widget.session.primaryLocationName;
    }
    return 'this location';
  }

  static WalkInHandlingMode _widgetWalkInModeFromDomain(
    DataAccuracyWalkInHandlingMode mode,
  ) {
    switch (mode) {
      case DataAccuracyWalkInHandlingMode.reservationsOnly:
        return WalkInHandlingMode.reservationsOnly;
      case DataAccuracyWalkInHandlingMode.walkInsAddedToReservations:
        return WalkInHandlingMode.walkInsAddedToReservations;
      case DataAccuracyWalkInHandlingMode.walkInsTrackedSeparately:
        return WalkInHandlingMode.walkInsTrackedSeparately;
    }
  }

  static DataAccuracyWalkInHandlingMode _domainWalkInModeFromWidget(
    WalkInHandlingMode mode,
  ) {
    switch (mode) {
      case WalkInHandlingMode.reservationsOnly:
        return DataAccuracyWalkInHandlingMode.reservationsOnly;
      case WalkInHandlingMode.walkInsAddedToReservations:
        return DataAccuracyWalkInHandlingMode.walkInsAddedToReservations;
      case WalkInHandlingMode.walkInsTrackedSeparately:
        return DataAccuracyWalkInHandlingMode.walkInsTrackedSeparately;
    }
  }
}

class _SaveStatusBanner extends StatelessWidget {
  const _SaveStatusBanner({required this.saving, required this.error});

  final bool saving;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final isError = error != null;
    return Container(
      key: Key(
        isError
            ? 'operator_web_data_accuracy_save_error'
            : 'operator_web_data_accuracy_saving',
      ),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isError ? AppColors.warningBadgeBg : AppColors.cardGlow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isError ? AppColors.warning : AppColors.borderSubtle,
        ),
      ),
      child: Row(
        children: [
          if (saving) ...[
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.sunsetDark,
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              error ?? 'Saving data accuracy settings...',
              style: AppTextStyles.body12(
                color: isError ? AppColors.warning : AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ApplicabilityWarningBanner extends StatelessWidget {
  const _ApplicabilityWarningBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.warningBadgeBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.warning),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: AppColors.warning,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body12(color: AppColors.warning),
            ),
          ),
        ],
      ),
    );
  }
}

class _DataAccuracyGroupLabel extends StatelessWidget {
  const _DataAccuracyGroupLabel({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              title,
              style: AppTextStyles.mono12(
                color: AppColors.textPrimary,
                weight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 6),
            OperatorWebInfoButton(
              title: title,
              tooltip: title,
              body: Text(
                subtitle,
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Segmented tab bar for the three data-accuracy areas (Labor,
/// Covers, Data freshness). Styled to the app theme's pill grammar:
/// the active tab is a raised surface chip in the sunset family; each
/// tab carries a small current-value pill (the wage choice, the
/// agreed covers source or "Mixed", the freshness tier). Mirrors the
/// approved redesign mockup's pill tab bar so the operator reads about
/// one source group at a time.
class _DataAccuracyTabBar extends StatelessWidget {
  const _DataAccuracyTabBar({
    required this.activeTab,
    required this.laborValue,
    required this.coversValue,
    required this.freshnessValue,
    required this.onTabSelected,
  });

  final int activeTab;
  final String laborValue;
  final String coversValue;
  final String freshnessValue;
  final ValueChanged<int> onTabSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: <Widget>[
          _DataAccuracyTab(
            tabKey: const Key('data_accuracy_tab_labor'),
            icon: Icons.payments_outlined,
            label: 'Labor',
            value: laborValue,
            selected: activeTab == _DataAccuracyScreenState._kTabLabor,
            onTap: () => onTabSelected(_DataAccuracyScreenState._kTabLabor),
          ),
          _DataAccuracyTab(
            tabKey: const Key('data_accuracy_tab_covers'),
            icon: Icons.groups_2_outlined,
            label: 'Covers',
            value: coversValue,
            selected: activeTab == _DataAccuracyScreenState._kTabCovers,
            onTap: () => onTabSelected(_DataAccuracyScreenState._kTabCovers),
          ),
          _DataAccuracyTab(
            tabKey: const Key('data_accuracy_tab_freshness'),
            icon: Icons.sync_outlined,
            label: 'Data freshness',
            value: freshnessValue,
            selected: activeTab == _DataAccuracyScreenState._kTabFreshness,
            onTap: () => onTabSelected(_DataAccuracyScreenState._kTabFreshness),
          ),
        ],
      ),
    );
  }
}

class _DataAccuracyTab extends StatelessWidget {
  const _DataAccuracyTab({
    required this.tabKey,
    required this.icon,
    required this.label,
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final Key tabKey;
  final IconData icon;
  final String label;
  final String value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: tabKey,
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? AppColors.backgroundSurface : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          boxShadow: selected
              ? <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ]
              : const <BoxShadow>[],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              size: 16,
              color: selected ? AppColors.sunsetDark : AppColors.textSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: AppTextStyles.body14(
                color: selected
                    ? AppColors.textPrimary
                    : AppColors.textSecondary,
              ).copyWith(fontWeight: FontWeight.w600),
            ),
            if (value.isNotEmpty) ...<Widget>[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 1),
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.sunset.withValues(alpha: 0.12)
                      : AppColors.backgroundSurface,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  value,
                  style: AppTextStyles.body12(
                    color: selected
                        ? AppColors.sunsetDark
                        : AppColors.textMuted,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ForbiddenSurface extends StatelessWidget {
  const _ForbiddenSurface({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.lock_outline,
                    size: 20,
                    color: AppColors.sunsetDark,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Admin or owner access needed',
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Your operator admin or owner can set up where your numbers '
                'come from for this location.',
                key: const Key('operator_web_data_accuracy_forbidden_body'),
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: AppColors.cardGlow,
                  border: Border.all(color: AppColors.borderSubtle, width: 1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Why you are seeing this',
                      style: AppTextStyles.mono11(color: AppColors.sunsetDark),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Where your app dashboard reads labor dollars and '
                      'covers from is a business-wide decision. Only '
                      'operator owners can change it. '
                      'Location managers can keep reading app dashboards '
                      'and shift views in the mobile app. Most '
                      'day-to-day actions live there.',
                      style: AppTextStyles.body13(color: AppColors.textPrimary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
