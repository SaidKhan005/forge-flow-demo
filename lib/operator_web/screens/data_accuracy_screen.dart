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
// Permission gate: mirrors Vendor connections — operator_owner /
// operator_admin admit; location_manager lands on a friendly
// forbidden surface explaining who manages data accuracy. Mirrors the
// Phase 9 proxy gate the live wiring will enforce server-side.
//
// UX writing standard (`memory/project_ux_writing_standard.md`):
// every label trains the operator. Plain English. No engineering
// jargon.

import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/operator_web_auth_source.dart';
import '../services/operator_web_data_accuracy_gateway.dart';
import '../widgets/covers_historical_seed_card.dart';
import '../widgets/covers_manual_entry_card.dart';
import '../widgets/covers_source_toggle.dart';
import '../widgets/data_accuracy_explainer_card.dart';
import '../widgets/operator_web_summary_strip.dart';
import '../widgets/polling_tier_status_card.dart';
import '../widgets/vendor_relativity_label.dart';
import '../widgets/wage_source_toggle.dart';
import '../widgets/walk_in_handling_card.dart';
import '../../domain/models/data_accuracy_settings.dart';
import '../../integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import '../../integrations/ui/vendor_connections/vendor_connections_models.dart';
import '../../services/integration/polling_tier_presets.dart';
import '../../theme/app_theme.dart';

/// Roles permitted to edit data accuracy from the operator-web
/// console. Mirrors the Vendor connections gate — operator owners +
/// admins read+write; location managers see a friendly forbidden
/// surface (read-mostly role).
const Set<String> kOperatorWebDataAccuracyAdmittedRoles = <String>{
  'operator_owner',
  'operator_admin',
};

/// Default polling tier surfaced when nothing else is wired in. Lane
/// .A's `ForgeFlowPollingTierRepository` lands the live read in the
/// follow-up `.live` slice; until then the screen renders the
/// canonical Standard tier cadences from
/// `lib/services/integration/polling_tier_presets.dart` (Lane `.0a`)
/// filtered to whichever poll-only vendors the operator has
/// connected.
PollingTierStatus _kDefaultStandardTier(VendorConnectionsBundle? bundle) {
  final connectedPollOnly = <String, int>{};
  final pos = bundle?.posConnection;
  final labor = bundle?.laborConnection;
  if (pos != null && kStandardTierPresets.containsKey(pos.vendorId)) {
    connectedPollOnly[pos.vendorId] = kStandardTierPresets[pos.vendorId]!;
  }
  if (labor != null && kStandardTierPresets.containsKey(labor.vendorId)) {
    connectedPollOnly[labor.vendorId] = kStandardTierPresets[labor.vendorId]!;
  }
  return PollingTierStatus(
    tier: PollingTierLabel.standard,
    tierDisplayLabel: 'Standard',
    monthlyPriceLabel: 'Bundled with subscription',
    perVendorCadenceSeconds: connectedPollOnly,
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
    this.businessDateIso = '2026-05-05',
    this.tierStatus,
    this.walkInModeOverride,
    this.onSaveSettings,
    this.onRequestTierChange,
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

  bool get _canEditDataAccuracy =>
      session.roles.any(kOperatorWebDataAccuracyAdmittedRoles.contains);

  @override
  State<DataAccuracyScreen> createState() => _DataAccuracyScreenState();
}

class _DataAccuracyScreenState extends State<DataAccuracyScreen> {
  late VendorConnectionsGateway _gateway;
  VendorConnectionsBundle? _bundle;
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

  // In-memory editable working copy of the settings. Materialized
  // back into `DataAccuracySettings` on save.
  late CoversSource _coversSourceLunch;
  late CoversSource _coversSourceDinner;
  late CoversSource _coversSourceLateNight;
  late WageSource _wageSource;
  late Map<String, Map<String, int>> _manualEntries;
  WalkInHandlingMode _walkInMode = WalkInHandlingMode.reservationsOnly;
  int? _walkInDailyCount;
  late Map<String, int> _walkInEntries;

  @override
  void initState() {
    super.initState();
    _gateway = widget.gateway ?? InMemoryVendorConnectionsGateway();
    _applySettingsSeed(widget.initialSettings);
    _settingsLoading = widget.dataAccuracyGateway != null;
    _loadBundle();
    _loadSettings();
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
        _loadError = null;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loadError = 'Could not load vendor connection context: $error';
        _loading = false;
      });
    }
  }

  @override
  void didUpdateWidget(covariant DataAccuracyScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway ||
        oldWidget.locationId != widget.locationId ||
        oldWidget.session.operatorId != widget.session.operatorId ||
        oldWidget.dataAccuracyGateway != widget.dataAccuracyGateway) {
      _gateway = widget.gateway ?? InMemoryVendorConnectionsGateway();
      setState(() {
        _loading = true;
        _loadError = null;
        _settingsLoading = widget.dataAccuracyGateway != null;
        _settingsLoadError = null;
        _settingsSaveError = null;
      });
      _loadBundle();
      _loadSettings();
    }
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

  void _applySettingsSeed(DataAccuracySettings? seed) {
    _lastSettings = seed;
    _coversSourceLunch = seed?.coversSourceLunch ?? CoversSource.vendor;
    _coversSourceDinner = seed?.coversSourceDinner ?? CoversSource.vendor;
    _coversSourceLateNight = seed?.coversSourceLateNight ?? CoversSource.vendor;
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
    _walkInDailyCount = _walkInEntries[widget.businessDateIso];
  }

  // ── Settings materialization ────────────────────────────────────

  DataAccuracySettings _materialize() {
    final now = DateTime.now().toUtc();
    final base = _lastSettings ?? widget.initialSettings;
    return DataAccuracySettings(
      settingId: base?.settingId ?? 'demo-setting-id',
      operatorId: widget.session.operatorId,
      locationId: widget.locationId,
      coversSourceLunch: _coversSourceLunch,
      coversSourceDinner: _coversSourceDinner,
      coversSourceLateNight: _coversSourceLateNight,
      coversManualEntries: <String, Map<String, int>>{
        for (final e in _manualEntries.entries)
          e.key: Map<String, int>.from(e.value),
      },
      wageSource: _wageSource,
      walkInHandlingMode: _domainWalkInModeFromWidget(_walkInMode),
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

  void _handleWageSourceChanged(WageSource value) {
    setState(() => _wageSource = value);
    _emitSave();
  }

  void _handleCoversSourceChanged(Daypart d, CoversSource value) {
    setState(() {
      switch (d) {
        case Daypart.lunch:
          _coversSourceLunch = value;
          break;
        case Daypart.dinner:
          _coversSourceDinner = value;
          break;
        case Daypart.lateNight:
          _coversSourceLateNight = value;
          break;
      }
    });
    _emitSave();
  }

  void _handleManualEntry(Daypart d, int? covers) {
    setState(() {
      final today = widget.businessDateIso;
      final dayMap = _manualEntries.putIfAbsent(today, () => <String, int>{});
      if (covers == null) {
        dayMap.remove(d.wire);
        if (dayMap.isEmpty) _manualEntries.remove(today);
      } else {
        dayMap[d.wire] = covers;
      }
    });
    _emitSave();
  }

  void _handleCopyYesterday(Daypart d) {
    final yesterday = _yesterdayIso(widget.businessDateIso);
    final value = _manualEntries[yesterday]?[d.wire];
    if (value == null) return;
    _handleManualEntry(d, value);
  }

  void _handleApplySeed(Map<String, Map<Daypart, int>> seed) {
    setState(() {
      seed.forEach((dateIso, dayMap) {
        final existing = _manualEntries.putIfAbsent(
          dateIso,
          () => <String, int>{},
        );
        dayMap.forEach((d, covers) {
          existing[d.wire] = covers;
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

  Future<void> _handleRequestTierChange() async {
    final opener =
        widget.onRequestTierChange ??
        (BuildContext ctx) => showPollingTierChangeRequestDialog(ctx);
    await opener(context);
  }

  // ── Conditional card visibility ─────────────────────────────────

  bool get _posExposesCovers {
    final pos = _bundle?.posConnection;
    if (pos == null) return true; // assume exposed when no POS yet.
    return posVendorExposesCovers(pos.vendorId);
  }

  bool get _hasReservationConnection => _bundle?.reservationConnection != null;

  bool get _showWalkInCard => !_posExposesCovers && _hasReservationConnection;

  bool get _showHistoricalSeedCard => !_posExposesCovers;

  bool get _anyDaypartManual =>
      _coversSourceLunch == CoversSource.manual ||
      _coversSourceDinner == CoversSource.manual ||
      _coversSourceLateNight == CoversSource.manual;

  bool get _showAnyFallbackCard =>
      _anyDaypartManual || _showWalkInCard || _showHistoricalSeedCard;

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
                    });
                    _loadBundle();
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
    final tier = widget.tierStatus ?? _kDefaultStandardTier(_bundle);
    final settings = _materialize();
    final locationLabel = _locationLabel();
    return SingleChildScrollView(
      key: const Key('operator_web_data_accuracy_screen'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.tune_outlined,
                size: 22,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Data accuracy',
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Choose where Forge & Flow reads numbers for $locationLabel. '
            'These settings keep your dashboard honest when a vendor '
            'does not expose every field directly.',
            key: const Key('operator_web_data_accuracy_subtitle'),
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 20),
          if (_savingSettings || _settingsSaveError != null) ...[
            _SaveStatusBanner(
              saving: _savingSettings,
              error: _settingsSaveError,
            ),
            const SizedBox(height: 14),
          ],
          OperatorWebSummaryStrip(
            key: const Key('operator_web_data_accuracy_summary'),
            items: [
              OperatorWebSummaryItem(
                icon: Icons.attach_money_outlined,
                label: 'Labor dollars',
                value: _wageSourceLabel(_wageSource),
                helper: 'source for wage cost',
              ),
              OperatorWebSummaryItem(
                icon: Icons.people_alt_outlined,
                label: 'Guest counts',
                value: _coversSummaryLabel(settings),
                helper: 'lunch, dinner, late night',
              ),
              OperatorWebSummaryItem(
                icon: Icons.edit_note_outlined,
                label: 'Fallback cards',
                value: _showAnyFallbackCard ? 'Shown' : 'Hidden',
                helper: 'only when needed',
              ),
              OperatorWebSummaryItem(
                icon: Icons.sync_outlined,
                label: 'Polling tier',
                value: tier.tierDisplayLabel,
                helper: 'managed by F&F',
              ),
            ],
          ),
          const SizedBox(height: 18),
          const _DataAccuracyGroupLabel(
            title: 'Sources',
            subtitle: 'Pick the preferred system for labor and covers.',
          ),
          const SizedBox(height: 10),
          WageSourceToggle(
            value: _wageSource,
            onChanged: _handleWageSourceChanged,
            bundle: _bundle,
          ),
          const SizedBox(height: 14),
          CoversSourceToggle(
            settings: settings,
            onChanged: _handleCoversSourceChanged,
            bundle: _bundle,
          ),
          if (_showAnyFallbackCard) ...[
            const SizedBox(height: 14),
            const _DataAccuracyGroupLabel(
              title: 'Fallback entries',
              subtitle: 'Shown only for sources that need manual numbers.',
            ),
            const SizedBox(height: 10),
          ],
          if (_anyDaypartManual) ...[
            CoversManualEntryCard(
              businessDateIso: widget.businessDateIso,
              yesterdayBusinessDateIso: _yesterdayIso(widget.businessDateIso),
              settings: settings,
              onEnterCovers: _handleManualEntry,
              onCopyYesterday: _handleCopyYesterday,
            ),
          ],
          if (_showWalkInCard) ...[
            const SizedBox(height: 14),
            WalkInHandlingCard(
              mode: _walkInMode,
              onModeChanged: _handleWalkInModeChanged,
              businessDateIso: widget.businessDateIso,
              dailyWalkInCount: _walkInDailyCount,
              onDailyWalkInCountChanged: _handleWalkInCountChanged,
            ),
          ],
          if (_showHistoricalSeedCard) ...[
            const SizedBox(height: 14),
            CoversHistoricalSeedCard(
              endDateIso: _yesterdayIso(widget.businessDateIso),
              dayCount: 60,
              initialEntries: _seedToDaypartMap(_manualEntries),
              onApplySeed: _handleApplySeed,
            ),
          ],
          const SizedBox(height: 14),
          const _DataAccuracyGroupLabel(
            title: 'Monitoring',
            subtitle: 'Check polling cadence and why each fallback exists.',
          ),
          const SizedBox(height: 10),
          PollingTierStatusCard(
            status: tier,
            bundle: _bundle,
            onRequestTierChange: _handleRequestTierChange,
          ),
          const SizedBox(height: 14),
          const DataAccuracyExplainerCard(),
        ],
      ),
    );
  }

  String _locationLabel() {
    final provided = widget.locationName?.trim();
    if (provided != null && provided.isNotEmpty) return provided;
    if (widget.locationId == widget.session.primaryLocationId) {
      return widget.session.primaryLocationName;
    }
    return 'this location';
  }

  static Map<String, Map<Daypart, int>> _seedToDaypartMap(
    Map<String, Map<String, int>> source,
  ) {
    final out = <String, Map<Daypart, int>>{};
    source.forEach((date, dayMap) {
      final inner = <Daypart, int>{};
      dayMap.forEach((wire, covers) {
        inner[DaypartWire.fromWire(wire)] = covers;
      });
      out[date] = inner;
    });
    return out;
  }

  static String _wageSourceLabel(WageSource source) {
    switch (source) {
      case WageSource.vendor:
        return 'Vendor';
      case WageSource.manualMix:
        return 'Manual mix';
    }
  }

  static String _coversSummaryLabel(DataAccuracySettings settings) {
    final sources = <CoversSource>{
      settings.coversSourceLunch,
      settings.coversSourceDinner,
      settings.coversSourceLateNight,
    };
    if (sources.length == 1) return _coversSourceLabel(sources.first);
    return '${sources.length} sources';
  }

  static String _coversSourceLabel(CoversSource source) {
    switch (source) {
      case CoversSource.vendor:
        return 'Vendor';
      case CoversSource.forecast:
        return 'Forecast';
      case CoversSource.manual:
        return 'Manual';
    }
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

class _DataAccuracyGroupLabel extends StatelessWidget {
  const _DataAccuracyGroupLabel({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: AppTextStyles.mono12(
            color: AppColors.textPrimary,
            weight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: AppTextStyles.body12(color: AppColors.textSecondary),
        ),
      ],
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
                      'Data accuracy is admin-managed',
                      style: AppTextStyles.display20(
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Data accuracy settings are managed by your operator '
                'admin or owner; ask them to set up where your numbers '
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
                      'Where your dashboard reads labor dollars and '
                      'covers from is a business-wide decision. Only '
                      'operator admins and owners can change it. '
                      'Location managers can keep reading dashboards '
                      'and shift views in the mobile app — most '
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
