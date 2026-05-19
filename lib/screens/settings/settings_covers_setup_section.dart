// Wave 2 MO-2 — mobile Covers Setup section.
//
// Lives on Settings -> Setup as the first item (above Business
// timing). Lets the operator type one cover count for a chosen
// business date + daypart, and shows their most-recent entries
// underneath the form so the round trip is visible without leaving
// the screen.
//
// Covers-source framing:
//   Manual entries are stored for the selected business date and
//   service period. They become operative when Covers source is set to
//   Manual, or when the POS connection does not send cover counts.
//
// Hierarchy-scope surfacing (HP #11): the section header shows the
// active restaurant scope so the operator knows which location their
// entry is landing against.
//
// Demo-mode invariant (HP #2): the section accepts an injected writer. Signed-
// in live Settings wires the canonical proxy writer and then mirrors locally;
// demo/unauth tests can keep the SQLite-only fallback without a `kDemoMode`
// reader branch.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models/data_accuracy_service_period_setting.dart';
import '../../domain/models/restaurant_timing_config.dart';
import '../../domain/models/service_period_definition.dart';
import '../../domain/services/service_period_definition_resolver.dart';
import '../../infrastructure/persistence/sqlite/dao/data_accuracy_service_period_settings_cache_dao.dart';
import '../../infrastructure/persistence/sqlite/dao/manual_cover_entry_dao.dart';
import '../../infrastructure/persistence/sqlite/sqlite_database.dart';
import '../../services/business_date_authority_service.dart';
import '../../services/integration/iana_timezone_converter.dart';
import '../../services/restaurant_timing_config_read_service.dart';
import '../../theme/app_theme.dart';
import 'settings_shared_widgets.dart';

/// Resolver-driven service-period loader. Production reads the
/// operator's persisted timing config (Gap 27/36 — never a hardcoded
/// `['lunch','dinner','late_night']` list); widget tests inject a fake
/// to skip the SQLite read. Falls back to the canonical fixture-era
/// definitions only when no timing config is persisted yet, matching
/// the canonical pattern in
/// `lib/services/benchmark_tracker_read_service.dart`.
typedef ServicePeriodDefinitionsLoader =
    Future<List<ServicePeriodDefinition>> Function(String restaurantId);

typedef TimingConfigLoader =
    Future<RestaurantTimingConfig?> Function(String restaurantId);

/// Loads the most recent synced per-service-period data accuracy rows.
typedef ServicePeriodCoversSourceLoader =
    Future<List<DataAccuracyServicePeriodSetting>> Function(
      String restaurantId,
    );

/// Loader abstraction. Production reads from SQLite; widget tests
/// inject a fake to skip database setup.
typedef ManualCoverEntryLoader =
    Future<List<ManualCoverEntry>> Function(String restaurantId);

/// Writer abstraction with the same separation of concerns.
typedef ManualCoverEntryWriter = Future<void> Function(ManualCoverEntry entry);

typedef CoversSetupClock = DateTime Function();

class SettingsCoversSetupSection extends StatefulWidget {
  const SettingsCoversSetupSection({
    super.key,
    required this.restaurantId,
    this.scopeLabel,
    this.posVendorId,
    this.loader,
    this.writer,
    this.servicePeriodsLoader,
    this.timingConfigLoader,
    this.coversSourceLoader,
    this.initialBusinessDate,
    this.initialDaypart = 'dinner',
    this.clock,
    this.onAfterSave,
  });

  /// Restaurant / location ID the entry will be written under. The
  /// Settings host (`settings_screen.dart`) passes the active
  /// restaurant ID from `RestaurantScopeNotifier`.
  final String restaurantId;

  /// Operator-facing display name for the active scope. Surfaced in
  /// the section header per HP #11 (hierarchy-scoped settings).
  final String? scopeLabel;

  /// Active POS vendor id retained for Settings host compatibility.
  /// This section does not change copy by vendor because the host does
  /// not reliably know the active POS connection today.
  final String? posVendorId;

  /// Loader hook. Production passes a SQLite-backed closure; tests
  /// pass a fake.
  final ManualCoverEntryLoader? loader;

  /// Writer hook. Production passes a SQLite-backed closure; tests
  /// pass a fake.
  final ManualCoverEntryWriter? writer;

  /// Service-period loader hook. Tests can pass a fake; production
  /// resolves periods from [timingConfigLoader] so labels/order and the
  /// initial business date share the same Timing config.
  final ServicePeriodDefinitionsLoader? servicePeriodsLoader;

  /// Timing config loader hook. Production reads the active local
  /// Timing cache; tests pass a fake config to avoid SQLite setup.
  final TimingConfigLoader? timingConfigLoader;

  /// Optional loader for the synced keyed Covers-source settings. The
  /// default reads the local proxy-sync cache.
  final ServicePeriodCoversSourceLoader? coversSourceLoader;

  /// Optional initial date for the picker. When null, the section uses
  /// the restaurant-local business date from Timing config when
  /// available, with a device-local fallback.
  final DateTime? initialBusinessDate;

  /// Optional initial daypart selection. Default is dinner.
  final String initialDaypart;

  /// Clock hook for deterministic business-date tests.
  final CoversSetupClock? clock;

  /// Fires after a successful save so the host can refresh other
  /// surfaces (Variance / Plan / Benchmark) that read the same SQLite
  /// scope.
  final VoidCallback? onAfterSave;

  @override
  State<SettingsCoversSetupSection> createState() =>
      _SettingsCoversSetupSectionState();
}

class _SettingsCoversSetupSectionState
    extends State<SettingsCoversSetupSection> {
  late final TextEditingController _coversController;
  late DateTime _selectedDate;
  late String _selectedDaypart;
  String? _error;
  String? _confirmation;
  bool _saving = false;
  bool _loadingRecent = true;
  bool _operatorPickedDate = false;
  List<ManualCoverEntry> _recentEntries = const <ManualCoverEntry>[];
  List<ServicePeriodDefinition> _servicePeriods =
      const <ServicePeriodDefinition>[];
  List<DataAccuracyServicePeriodSetting> _servicePeriodSettings =
      const <DataAccuracyServicePeriodSetting>[];

  @override
  void initState() {
    super.initState();
    _coversController = TextEditingController();
    _selectedDate = widget.initialBusinessDate ?? _deviceLocalDate();
    _selectedDaypart = widget.initialDaypart;
    _loadRecent();
    _loadServicePeriods();
    _loadCoversSourceSettings();
  }

  @override
  void didUpdateWidget(covariant SettingsCoversSetupSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.restaurantId != widget.restaurantId) {
      _operatorPickedDate = false;
      _selectedDate = widget.initialBusinessDate ?? _deviceLocalDate();
      _loadRecent();
      _loadServicePeriods();
      _loadCoversSourceSettings();
    }
  }

  String _periodLabel(String servicePeriodId) {
    for (final p in _servicePeriods) {
      if (p.id == servicePeriodId) return p.label;
    }
    return servicePeriodId;
  }

  Future<void> _loadServicePeriods() async {
    final periodsLoader = widget.servicePeriodsLoader;
    final timingLoader =
        widget.timingConfigLoader ?? _defaultTimingConfigLoader;
    try {
      final timingConfig = await timingLoader(widget.restaurantId);
      final periods = periodsLoader == null
          ? _definitionsFromConfig(timingConfig)
          : await periodsLoader(widget.restaurantId);
      final restaurantBusinessDate = _restaurantBusinessDate(timingConfig);
      if (!mounted) return;
      setState(() {
        _servicePeriods = periods;
        if (widget.initialBusinessDate == null &&
            !_operatorPickedDate &&
            restaurantBusinessDate != null) {
          _selectedDate = restaurantBusinessDate;
        }
        // Keep the selection valid if the operator's configured set
        // does not include the previous (or default) selection.
        if (periods.isNotEmpty &&
            !periods.any((p) => p.id == _selectedDaypart)) {
          _selectedDaypart = periods.first.id;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _servicePeriods = ServicePeriodDefinitionResolver.demoDefinitions;
        if (widget.initialBusinessDate == null && !_operatorPickedDate) {
          _selectedDate = _deviceLocalDate();
        }
        if (!_servicePeriods.any((p) => p.id == _selectedDaypart)) {
          _selectedDaypart = _servicePeriods.first.id;
        }
      });
    }
  }

  Future<void> _loadCoversSourceSettings() async {
    final loader = widget.coversSourceLoader ?? _defaultCoversSourceLoader;
    try {
      final rows = await loader(widget.restaurantId);
      if (!mounted) return;
      setState(() => _servicePeriodSettings = rows);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _servicePeriodSettings = const <DataAccuracyServicePeriodSetting>[];
      });
    }
  }

  static Future<List<DataAccuracyServicePeriodSetting>>
  _defaultCoversSourceLoader(String restaurantId) async {
    final db = await SqliteDatabase.instance.database;
    final dao = DataAccuracyServicePeriodSettingsCacheDao(db);
    return dao.getRows(restaurantId);
  }

  static Future<RestaurantTimingConfig?> _defaultTimingConfigLoader(
    String restaurantId,
  ) {
    return RestaurantTimingConfigReadService.instance.getTimingConfig(
      restaurantId,
    );
  }

  static List<ServicePeriodDefinition> _definitionsFromConfig(
    RestaurantTimingConfig? config,
  ) {
    // Canonical pattern (benchmark_tracker_read_service.dart): period
    // set + labels + ordering come from the operator's persisted timing
    // config, never a hardcoded daypart list. Falls back to the
    // canonical fixture-era definitions only when no config is
    // persisted yet.
    final defs = (config?.servicePeriodDefinitions.isNotEmpty ?? false)
        ? config!.servicePeriodDefinitions
        : ServicePeriodDefinitionResolver.demoDefinitions;
    return ServicePeriodDefinitionResolver.ordered(defs);
  }

  @override
  void dispose() {
    _coversController.dispose();
    super.dispose();
  }

  DateTime _deviceLocalDate() {
    final now = _now().toLocal();
    return DateTime(now.year, now.month, now.day);
  }

  DateTime _now() => widget.clock?.call() ?? DateTime.now().toUtc();

  DateTime? _restaurantBusinessDate(RestaurantTimingConfig? config) {
    if (config == null) return null;
    try {
      final localNow = IanaTimezoneConverter.shared.toBusinessLocal(
        restaurantTimezone: config.businessTimezone,
        instant: _now().toUtc(),
      );
      final iso = BusinessDateAuthorityService.resolveBusinessDateFromConfig(
        localTimestamp: localNow,
        config: config,
      );
      return _dateFromIso(iso);
    } catch (_) {
      return null;
    }
  }

  DateTime? _dateFromIso(String isoDate) {
    final parts = isoDate.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    return DateTime(year, month, day);
  }

  String _isoDate(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  Future<void> _loadRecent() async {
    final loader = widget.loader ?? _defaultLoader;
    setState(() => _loadingRecent = true);
    try {
      final rows = await loader(widget.restaurantId);
      if (!mounted) return;
      setState(() {
        _recentEntries = rows;
        _loadingRecent = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _recentEntries = const <ManualCoverEntry>[];
        _loadingRecent = false;
      });
    }
  }

  static Future<List<ManualCoverEntry>> _defaultLoader(
    String restaurantId,
  ) async {
    final db = await SqliteDatabase.instance.database;
    final dao = ManualCoverEntryDao(db);
    return dao.listRecentForRestaurant(restaurantId, limit: 5);
  }

  static Future<void> _defaultWriter(ManualCoverEntry entry) async {
    final db = await SqliteDatabase.instance.database;
    final dao = ManualCoverEntryDao(db);
    await dao.upsert(entry);
  }

  _CoversSourceStatus _coversSourceStatusFor(String servicePeriodId) {
    final selectedDate = _isoDate(_selectedDate);
    DataAccuracyServicePeriodSetting? best;
    for (final row in _servicePeriodSettings) {
      if (row.servicePeriodKey != servicePeriodId) continue;
      if (row.effectiveAtBusinessDate.compareTo(selectedDate) > 0) continue;
      if (best == null ||
          row.effectiveAtBusinessDate.compareTo(best.effectiveAtBusinessDate) >
              0) {
        best = row;
      }
    }
    if (best == null) {
      return const _CoversSourceStatus(
        label: 'Vendor feed',
        sourceLabel: null,
        effectiveAtBusinessDate: null,
      );
    }
    return _CoversSourceStatus(
      label: _coversSourceLabel(best.coversSource),
      sourceLabel: best.coversSourceSource?.label,
      effectiveAtBusinessDate: best.effectiveAtBusinessDate,
    );
  }

  static String _coversSourceLabel(ServicePeriodCoversSource source) {
    switch (source) {
      case ServicePeriodCoversSource.vendor:
        return 'Vendor feed';
      case ServicePeriodCoversSource.forecast:
        return 'Forecast';
      case ServicePeriodCoversSource.manual:
        return 'Manual entry';
      case ServicePeriodCoversSource.reservationPlusWalkin:
        return 'Reservations + walk-ins';
    }
  }

  Future<void> _onPickDate() async {
    final now = _now().toLocal();
    final firstDate = DateTime(now.year - 1, now.month, now.day);
    final lastDate = DateTime(now.year + 1, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: firstDate,
      lastDate: lastDate,
      helpText: 'Pick the business date for these covers',
    );
    if (picked == null) return;
    setState(() {
      _operatorPickedDate = true;
      _selectedDate = DateTime(picked.year, picked.month, picked.day);
      _confirmation = null;
    });
  }

  Future<void> _onSave() async {
    final raw = _coversController.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _error = 'Type how many guests you served.';
        _confirmation = null;
      });
      return;
    }
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 0) {
      setState(() {
        _error = 'Type a whole number, 0 or greater.';
        _confirmation = null;
      });
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final writer = widget.writer ?? _defaultWriter;
    final entry = ManualCoverEntry(
      restaurantId: widget.restaurantId,
      businessDate: _isoDate(_selectedDate),
      daypart: _selectedDaypart,
      covers: parsed,
      recordedAt: _now().toUtc().toIso8601String(),
    );
    try {
      await writer(entry);
      if (!mounted) return;
      _coversController.clear();
      setState(() {
        _confirmation =
            "Saved ${entry.covers} covers for ${_periodLabel(entry.daypart)} on ${entry.businessDate}.";
        _saving = false;
      });
      await _loadRecent();
      widget.onAfterSave?.call();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = "Could not save: $error";
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Styled to match the Business timing card on the same Setup tab:
    // plain SettingsCard (no left accent stripe), 14px inset on all
    // sides, and the section host (`_settingsSection`) supplies the
    // horizontal:16 gutter — so this card sits flush with Business
    // timing instead of being indented + striped.
    return SettingsCard(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(scopeLabel: widget.scopeLabel),
              const SizedBox(height: 12),
              _FormRow(
                label: 'Business date',
                child: _DatePill(
                  key: const Key('settings_covers_setup_business_date_button'),
                  isoDate: _isoDate(_selectedDate),
                  onTap: _onPickDate,
                ),
              ),
              _FormRow(
                label: 'Service period',
                child: _ServicePeriodDropdown(
                  selected: _selectedDaypart,
                  periods: _servicePeriods,
                  onChanged: (next) {
                    if (next == null) return;
                    setState(() {
                      _selectedDaypart = next;
                      _confirmation = null;
                    });
                  },
                ),
              ),
              _FormRow(
                label: 'Covers source',
                child: _CoversSourcePill(
                  status: _coversSourceStatusFor(_selectedDaypart),
                ),
              ),
              _FormRow(
                label: 'Covers',
                child: TextField(
                  key: const Key('settings_covers_setup_covers_field'),
                  controller: _coversController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: false,
                    signed: false,
                  ),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onSubmitted: (_) => _onSave(),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'e.g. 84',
                    border: OutlineInputBorder(),
                  ),
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  key: const Key('settings_covers_setup_error_text'),
                  style: AppTextStyles.body13(color: AppColors.negative),
                ),
              ],
              if (_confirmation != null) ...[
                const SizedBox(height: 8),
                Text(
                  _confirmation!,
                  key: const Key('settings_covers_setup_confirmation_text'),
                  style: AppTextStyles.body13(color: AppColors.positive),
                ),
              ],
              const SizedBox(height: 14),
              // Same button system as the "Manage ... on Ops Web"
              // pointer-row buttons elsewhere on the Setup tab:
              // full-width, height 46, sunset fill / surface
              // foreground, radius 6, mono12 w600 (see
              // settings_pointer_row.dart). Keeps the Setup tab's
              // primary-action styling consistent.
              SizedBox(
                width: double.infinity,
                height: 46,
                child: FilledButton.icon(
                  key: const Key('settings_covers_setup_save_button'),
                  onPressed: _saving ? null : _onSave,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: Text(_saving ? 'Saving...' : 'Save covers'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.sunset,
                    foregroundColor: AppColors.backgroundSurface,
                    disabledBackgroundColor: AppColors.sunset.withValues(
                      alpha: 0.30,
                    ),
                    disabledForegroundColor: AppColors.backgroundSurface
                        .withValues(alpha: 0.85),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    textStyle: AppTextStyles.mono12(weight: FontWeight.w600),
                  ),
                ),
              ),
              if (!_loadingRecent && _recentEntries.isNotEmpty) ...[
                const SettingsRowDivider(),
                const SizedBox(height: 8),
                Text(
                  'Recent entries',
                  style: AppTextStyles.body13(
                    color: AppColors.textSecondary,
                  ).copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                for (final e in _recentEntries)
                  Padding(
                    key: Key(
                      'settings_covers_setup_recent_${e.businessDate}_${e.daypart}',
                    ),
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${e.businessDate} • ${_periodLabel(e.daypart)} • '
                      '${e.covers} covers',
                      style: AppTextStyles.body13(color: AppColors.textPrimary),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.scopeLabel});

  final String? scopeLabel;

  @override
  Widget build(BuildContext context) {
    const title = 'Record cover counts';
    const explainer =
        'Save manual covers for this business date and service '
        'period. F&F uses them when Covers source is set to Manual, or when '
        'your POS does not send cover counts.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.edit_note_outlined,
              size: 18,
              color: AppColors.sunset,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: AppTextStyles.mono15(
                  color: AppColors.textPrimary,
                  weight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        if (scopeLabel != null && scopeLabel!.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            'Applies to: ${scopeLabel!.trim()}',
            key: const Key('settings_covers_setup_scope_label'),
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          explainer,
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _CoversSourceStatus {
  const _CoversSourceStatus({
    required this.label,
    required this.effectiveAtBusinessDate,
    this.sourceLabel,
  });

  final String label;
  final String? sourceLabel;
  final String? effectiveAtBusinessDate;
}

class _CoversSourcePill extends StatelessWidget {
  const _CoversSourcePill({required this.status});

  final _CoversSourceStatus status;

  @override
  Widget build(BuildContext context) {
    final effective = status.effectiveAtBusinessDate;
    final sourceLabel = status.sourceLabel;
    final detail = sourceLabel == null
        ? null
        : effective == null
        ? sourceLabel
        : '$sourceLabel since $effective';
    return Container(
      key: const Key('settings_covers_setup_effective_source'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            status.label,
            key: const Key('settings_covers_setup_effective_source_label'),
            style: AppTextStyles.body14(color: AppColors.textPrimary),
          ),
          if (detail != null) ...[
            const SizedBox(height: 2),
            Text(
              detail,
              key: const Key('settings_covers_setup_effective_source_detail'),
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class _FormRow extends StatelessWidget {
  const _FormRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Label column mirrors `_TimingValueRow` in
    // settings_timing_authority_section.dart (width 128, mono10
    // textMuted, vertical:8 inset, 10px gap) so the Covers setup card
    // and the Business timing card read as one system.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 128,
            child: Text(
              label,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _DatePill extends StatelessWidget {
  const _DatePill({super.key, required this.isoDate, required this.onTap});

  final String isoDate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.cardGlow,
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.calendar_today_outlined,
              size: 16,
              color: AppColors.textSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              isoDate,
              style: AppTextStyles.body14(color: AppColors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServicePeriodDropdown extends StatelessWidget {
  const _ServicePeriodDropdown({
    required this.selected,
    required this.periods,
    required this.onChanged,
  });

  final String selected;
  final List<ServicePeriodDefinition> periods;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (periods.isEmpty) {
      return Text(
        'No service periods configured yet. Set them up under Business '
        'timing.',
        key: const Key('settings_covers_setup_no_periods'),
        style: AppTextStyles.body13(color: AppColors.textMuted),
      );
    }
    final hasSelection = periods.any((p) => p.id == selected);
    return InputDecorator(
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const Key('settings_covers_setup_daypart_dropdown'),
          value: hasSelection ? selected : periods.first.id,
          isExpanded: true,
          onChanged: onChanged,
          items: [
            for (final p in periods)
              DropdownMenuItem<String>(
                value: p.id,
                child: Text(
                  p.label,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
