// Wave 2 MO-2 — mobile Covers Setup section.
//
// Lives on Settings -> Setup as the first item (above Business
// timing). Lets the operator type one cover count for a chosen
// business date + daypart, and shows their most-recent entries
// underneath the form so the round trip is visible without leaving
// the screen.
//
// Vendor-fallback framing (per debug.md:287-289 + integration spine
// contract):
//   * When the active POS does NOT expose a covers field (Square,
//     Clover) — manual entry is the **primary path**. The header
//     copy and explainer surface that. F&F cannot recover covers any
//     other way for these POS vendors.
//   * When the active POS DOES expose a covers field (Toast, Aloha,
//     Lightspeed K-Series, Oracle MICROS Simphony, Revel) — the form
//     is still available but framed as a **manual override**, so the
//     operator can correct a per-day count without re-syncing.
//
// Hierarchy-scope surfacing (HP #11): the section header shows the
// active restaurant scope so the operator knows which location their
// entry is landing against.
//
// Demo-mode invariant (HP #2): the writer here is the same DAO call
// whether the restaurant is in demo or live mode. No `kDemoMode`
// reader branch. The new `manual_cover_entries` table is the same
// in both worlds.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../infrastructure/persistence/sqlite/dao/manual_cover_entry_dao.dart';
import '../../infrastructure/persistence/sqlite/sqlite_database.dart';
import '../../services/integration/pos_covers_capability.dart';
import '../../theme/app_theme.dart';
import 'settings_shared_widgets.dart';

/// Daypart wire values mirrored from
/// `lib/domain/models/data_accuracy_settings.dart` `Daypart`. Mobile
/// keeps a string list here so this widget doesn't pull the heavier
/// Postgres-bound DataAccuracySettings model into the Setup tab.
const List<String> kSettingsCoversDayparts = <String>[
  'lunch',
  'dinner',
  'late_night',
];

String _daypartDisplayLabel(String daypart) {
  switch (daypart) {
    case 'lunch':
      return 'Lunch';
    case 'dinner':
      return 'Dinner';
    case 'late_night':
      return 'Late night';
    default:
      return daypart;
  }
}

/// Loader abstraction. Production reads from SQLite; widget tests
/// inject a fake to skip database setup.
typedef ManualCoverEntryLoader = Future<List<ManualCoverEntry>>
    Function(String restaurantId);

/// Writer abstraction with the same separation of concerns.
typedef ManualCoverEntryWriter = Future<void> Function(
    ManualCoverEntry entry);

class SettingsCoversSetupSection extends StatefulWidget {
  const SettingsCoversSetupSection({
    super.key,
    required this.restaurantId,
    this.scopeLabel,
    this.posVendorId,
    this.loader,
    this.writer,
    this.initialBusinessDate,
    this.initialDaypart = 'dinner',
    this.onAfterSave,
  });

  /// Restaurant / location ID the entry will be written under. The
  /// Settings host (`settings_screen.dart`) passes the active
  /// restaurant ID from `RestaurantScopeNotifier`.
  final String restaurantId;

  /// Operator-facing display name for the active scope. Surfaced in
  /// the section header per HP #11 (hierarchy-scoped settings).
  final String? scopeLabel;

  /// Active POS vendor id (`'square'`, `'toast'`, …) used to decide
  /// whether the form is framed as the primary path (POS missing
  /// covers) or as a manual override.
  final String? posVendorId;

  /// Loader hook. Production passes a SQLite-backed closure; tests
  /// pass a fake.
  final ManualCoverEntryLoader? loader;

  /// Writer hook. Production passes a SQLite-backed closure; tests
  /// pass a fake.
  final ManualCoverEntryWriter? writer;

  /// Optional initial date for the picker. When null, falls back to
  /// today (restaurant-local approximation = device-local date).
  final DateTime? initialBusinessDate;

  /// Optional initial daypart selection. Default is dinner.
  final String initialDaypart;

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
  List<ManualCoverEntry> _recentEntries = const <ManualCoverEntry>[];

  @override
  void initState() {
    super.initState();
    _coversController = TextEditingController();
    _selectedDate = widget.initialBusinessDate ?? _todayLocal();
    _selectedDaypart = widget.initialDaypart;
    _loadRecent();
  }

  @override
  void didUpdateWidget(covariant SettingsCoversSetupSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.restaurantId != widget.restaurantId) {
      _loadRecent();
    }
  }

  @override
  void dispose() {
    _coversController.dispose();
    super.dispose();
  }

  DateTime _todayLocal() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
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
      String restaurantId) async {
    final db = await SqliteDatabase.instance.database;
    final dao = ManualCoverEntryDao(db);
    return dao.listRecentForRestaurant(restaurantId, limit: 5);
  }

  static Future<void> _defaultWriter(ManualCoverEntry entry) async {
    final db = await SqliteDatabase.instance.database;
    final dao = ManualCoverEntryDao(db);
    await dao.upsert(entry);
  }

  Future<void> _onPickDate() async {
    final now = DateTime.now();
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
      recordedAt: DateTime.now().toUtc().toIso8601String(),
    );
    try {
      await writer(entry);
      if (!mounted) return;
      _coversController.clear();
      setState(() {
        _confirmation =
            "Saved ${entry.covers} covers for ${_daypartDisplayLabel(entry.daypart)} on ${entry.businessDate}.";
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
    final exposes = posVendorExposesCovers(widget.posVendorId);
    final primaryPath = exposes == false || exposes == null;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SettingsCard(
        accentColor: primaryPath ? AppColors.sunset : AppColors.positive,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                  scopeLabel: widget.scopeLabel,
                  primaryPath: primaryPath,
                  posVendorId: widget.posVendorId,
                ),
                const SizedBox(height: 12),
                _FormRow(
                  label: 'Business date',
                  child: _DatePill(
                    key: const Key(
                        'settings_covers_setup_business_date_button'),
                    isoDate: _isoDate(_selectedDate),
                    onTap: _onPickDate,
                  ),
                ),
                const SizedBox(height: 10),
                _FormRow(
                  label: 'Daypart',
                  child: _DaypartDropdown(
                    selected: _selectedDaypart,
                    onChanged: (next) {
                      if (next == null) return;
                      setState(() {
                        _selectedDaypart = next;
                        _confirmation = null;
                      });
                    },
                  ),
                ),
                const SizedBox(height: 10),
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
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    key: const Key('settings_covers_setup_save_button'),
                    onPressed: _saving ? null : _onSave,
                    child: Text(_saving ? 'Saving...' : 'Save covers'),
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
                          'settings_covers_setup_recent_${e.businessDate}_${e.daypart}'),
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${e.businessDate} • ${_daypartDisplayLabel(e.daypart)} • '
                        '${e.covers} covers',
                        style: AppTextStyles.body13(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.scopeLabel,
    required this.primaryPath,
    required this.posVendorId,
  });

  final String? scopeLabel;
  final bool primaryPath;
  final String? posVendorId;

  @override
  Widget build(BuildContext context) {
    final title = primaryPath ? "Type today's covers" : 'Manual cover override';
    final accent = primaryPath ? AppColors.sunset : AppColors.positive;
    final explainer = primaryPath
        ? _explainerWhenPrimary(posVendorId)
        : _explainerWhenOverride(posVendorId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.edit_note_outlined, size: 18, color: accent),
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

  static String _explainerWhenPrimary(String? posVendorId) {
    if (posVendorId == null) {
      return "Your point-of-sale isn't connected yet, so F&F has no "
          'covers to read. Type the count here and F&F will use it for '
          "today's targets and benchmarks.";
    }
    return "Your point-of-sale (${_humanizeVendor(posVendorId)}) doesn't "
        'send a cover count to F&F. Type the number of guests you '
        "served and it lands here. F&F will use it where covers feed "
        'today\'s targets.';
  }

  static String _explainerWhenOverride(String? posVendorId) {
    final vendor =
        posVendorId == null ? 'your point-of-sale' : _humanizeVendor(posVendorId);
    return "$vendor already sends covers to F&F. Use this form only "
        'when you need to override a count for a specific shift.';
  }

  static String _humanizeVendor(String posVendorId) {
    switch (posVendorId) {
      case 'aloha':
        return 'Aloha';
      case 'clover':
        return 'Clover';
      case 'lightspeed_lsk':
        return 'Lightspeed K-Series';
      case 'oracle_micros_simphony':
        return 'Oracle MICROS Simphony';
      case 'revel':
        return 'Revel';
      case 'square':
        return 'Square';
      case 'toast':
        return 'Toast';
      default:
        return posVendorId;
    }
  }
}

class _FormRow extends StatelessWidget {
  const _FormRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: AppTextStyles.body14(color: AppColors.textPrimary),
          ),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _DatePill extends StatelessWidget {
  const _DatePill({
    super.key,
    required this.isoDate,
    required this.onTap,
  });

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

class _DaypartDropdown extends StatelessWidget {
  const _DaypartDropdown({
    required this.selected,
    required this.onChanged,
  });

  final String selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: const InputDecoration(
        isDense: true,
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const Key('settings_covers_setup_daypart_dropdown'),
          value: selected,
          isExpanded: true,
          onChanged: onChanged,
          items: [
            for (final d in kSettingsCoversDayparts)
              DropdownMenuItem<String>(
                value: d,
                child: Text(
                  _daypartDisplayLabel(d),
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
