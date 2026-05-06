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

import 'package:flutter/material.dart';

import '../auth/operator_web_auth_source.dart';
import '../widgets/covers_historical_seed_card.dart';
import '../widgets/covers_manual_entry_card.dart';
import '../widgets/covers_source_toggle.dart';
import '../widgets/data_accuracy_explainer_card.dart';
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
    this.gateway,
    this.initialSettings,
    this.businessDateIso = '2026-05-05',
    this.tierStatus,
    this.walkInModeOverride,
    this.onSaveSettings,
    this.onRequestTierChange,
  });

  final OperatorWebSession session;
  final String locationId;

  /// Optional gateway — falls back to an in-memory gateway when
  /// omitted (demo / widget tests).
  final VendorConnectionsGateway? gateway;

  /// Seeded settings. When null, the screen renders defaults
  /// (covers_source_* = vendor; wage_source = vendor; empty manual
  /// entries).
  final DataAccuracySettings? initialSettings;

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
  int _loadGeneration = 0;

  // In-memory editable working copy of the settings. Materialized
  // back into `DataAccuracySettings` on save.
  late CoversSource _coversSourceLunch;
  late CoversSource _coversSourceDinner;
  late CoversSource _coversSourceLateNight;
  late WageSource _wageSource;
  late Map<String, Map<String, int>> _manualEntries;
  WalkInHandlingMode _walkInMode = WalkInHandlingMode.reservationsOnly;
  int? _walkInDailyCount;

  @override
  void initState() {
    super.initState();
    _gateway = widget.gateway ?? InMemoryVendorConnectionsGateway();
    final seed = widget.initialSettings;
    _coversSourceLunch = seed?.coversSourceLunch ?? CoversSource.vendor;
    _coversSourceDinner = seed?.coversSourceDinner ?? CoversSource.vendor;
    _coversSourceLateNight = seed?.coversSourceLateNight ?? CoversSource.vendor;
    _wageSource = seed?.wageSource ?? WageSource.vendor;
    _manualEntries = <String, Map<String, int>>{
      for (final e in (seed?.coversManualEntries ?? const {}).entries)
        e.key: Map<String, int>.from(e.value),
    };
    _walkInMode =
        widget.walkInModeOverride ?? WalkInHandlingMode.reservationsOnly;
    _loadBundle();
  }

  Future<void> _loadBundle() async {
    final generation = ++_loadGeneration;
    final bundle = await _gateway.loadBundle(
      operatorId: widget.session.operatorId,
      locationId: widget.locationId,
    );
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _bundle = bundle;
      _loading = false;
    });
  }

  @override
  void didUpdateWidget(covariant DataAccuracyScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.gateway != widget.gateway ||
        oldWidget.locationId != widget.locationId ||
        oldWidget.session.operatorId != widget.session.operatorId) {
      _gateway = widget.gateway ?? InMemoryVendorConnectionsGateway();
      setState(() => _loading = true);
      _loadBundle();
    }
  }

  // ── Settings materialization ────────────────────────────────────

  DataAccuracySettings _materialize() {
    final now = DateTime.now().toUtc();
    final base = widget.initialSettings;
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
      createdAt: base?.createdAt ?? now,
      updatedAt: now,
      updatedBy: widget.session.uid,
    );
  }

  void _emitSave() {
    widget.onSaveSettings?.call(_materialize());
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
  }

  void _handleWalkInCountChanged(int? value) {
    setState(() => _walkInDailyCount = value);
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

  // ── Build ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!widget._canEditDataAccuracy) {
      return _ForbiddenSurface(
        key: const Key('operator_web_data_accuracy_forbidden'),
      );
    }
    if (_loading) {
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
    final tier = widget.tierStatus ?? _kDefaultStandardTier(_bundle);
    final settings = _materialize();
    final locationLabel = widget.locationId == widget.session.primaryLocationId
        ? widget.session.primaryLocationName
        : 'this location';
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
          if (_anyDaypartManual) ...[
            const SizedBox(height: 14),
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
