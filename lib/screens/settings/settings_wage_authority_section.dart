// Phase 7.55o.4 — Settings Wage Authority section.
//
// Wage authority section (7.55p.5f1a — whole-mix editor):
// Read-only summary panel in Settings. A single `Edit Wage Mix`
// button opens a full-screen editor where the user fills the entire
// fallback wage mix in one pass (FOH + BOH + Management inline
// together) and saves once. The editor persists through the same
// `WageRoleRow -> WageStandardContextService -> ActiveTargetProfile`
// authority seam used by Benchmark, Variance, and Shift downstream
// consumers. Behaviour is unchanged from the pre-split file.

import 'package:flutter/material.dart';

import '../../services/wage_standard_context_service.dart';
import '../../domain/models/wage_role_row.dart';
import '../../domain/models/wage_standard_context.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../../infrastructure/persistence/sqlite/repositories/sqlite_wage_role_row_repository.dart';
import '../../theme/app_theme.dart';

class WageAuthoritySection extends StatefulWidget {
  final VoidCallback onChanged;

  /// W3.A — when true, the mobile mirror suppresses the editor button
  /// and renders only the read-only summary. The Operator Web console
  /// owns wage-mix mutations.
  final bool viewOnly;

  /// Test seam (mirrors `SettingsScreen.initialStatus`). When supplied,
  /// the section renders this resolved context + rows immediately and
  /// skips the SQLite `_load()` round-trip. Production passes nothing,
  /// so the read path is unchanged. Lets widget tests exercise the
  /// restyled read-only layout without the seeded-DB load that is not
  /// reachable under `flutter test`.
  final WageStandardContext? initialWageContextForTest;
  final List<WageRoleRow>? initialRowsForTest;

  const WageAuthoritySection({
    super.key,
    required this.onChanged,
    this.viewOnly = false,
    this.initialWageContextForTest,
    this.initialRowsForTest,
  });

  @override
  State<WageAuthoritySection> createState() => _WageAuthoritySectionState();
}

class _WageAuthoritySectionState extends State<WageAuthoritySection> {
  WageStandardContext? _wageCtx;
  List<WageRoleRow> _rows = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    if (widget.initialRowsForTest != null) {
      // Test seam — render the injected snapshot directly. No
      // production caller passes these, so the live read path
      // (`_load()`) is untouched.
      _wageCtx = widget.initialWageContextForTest;
      _rows = widget.initialRowsForTest!;
      _isLoading = false;
      return;
    }
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      _wageCtx = await WageStandardContextService.instance.resolve(
        restaurantId,
      );
      _rows = await SqliteWageRoleRowRepository.instance.getRows(restaurantId);
    } catch (_) {}
    if (mounted) setState(() => _isLoading = false);
  }

  /// Applies one whole-mix edit result from [_WageMixEditorScreen]:
  /// upserts every row the editor still contains, deletes any existing
  /// rows the editor removed, then syncs the active profile once.
  ///
  /// This preserves the existing authority seam — every row still
  /// flows through `SqliteWageRoleRowRepository.upsertRow` and the
  /// profile push still happens through
  /// [WageStandardContextService.syncWagesToActiveProfile]. No
  /// UI-only wage truth path is introduced.
  Future<void> _applyMixEdit(_WageMixEditResult result) async {
    for (final row in result.rowsToPersist) {
      await SqliteWageRoleRowRepository.instance.upsertRow(row);
    }
    for (final id in result.idsToDelete) {
      await SqliteWageRoleRowRepository.instance.deleteRow(id);
    }
    await WageStandardContextService.instance.syncWagesToActiveProfile();
    await _load();
    widget.onChanged();
  }

  Future<void> _openMixEditor() async {
    final restaurantId = await SqliteRestaurantScopeRepository.instance
        .getActiveRestaurantId();
    if (!mounted) return;

    final result = await Navigator.of(context).push<_WageMixEditResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _WageMixEditorScreen(
          restaurantId: restaurantId,
          initialRows: _rows,
        ),
      ),
    );
    if (result != null) {
      await _applyMixEdit(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        padding: const EdgeInsets.all(16),
        color: AppColors.backgroundMid,
        child: Text(
          'Loading...',
          style: AppTextStyles.mono11(color: AppColors.textMuted),
        ),
      );
    }

    final w = _wageCtx;
    final summary = WageStandardContextService.summarizeMix(_rows);
    // F (per-daypart V1 UX declutter): the mobile Wage Setup mirror is
    // restyled to match the operator-web Wage Authority screen — flat
    // cards, clean role rows with a single formula crumb, and the
    // blended-mix summary up top. No read-logic change: the same
    // `WageStandardContext` (HP #11 source/effective values) and
    // `summarizeMix` rows drive the view.
    return Container(
      key: const Key('settings_wage_setup_section'),
      color: AppColors.backgroundMid,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Blended-wage summary — mirrors operator-web's
          // BlendedWageSummaryCard. HP #11: the "Source" line states
          // provenance; the front/back/average lines are the effective
          // values in force.
          _WageInfoCard(
            sourceLabel: w?.source.displayLabel ?? 'Not set',
            fohWage: w?.fohWage,
            bohWage: w?.bohWage,
            blendedWage: w?.referenceBlendedWage,
            totalWeightedHours: summary.totalWeightedHours,
            totalHourlyCost: summary.totalHourlyCost,
            hasRows: !summary.isEmpty,
          ),
          if (!summary.hasCompleteFohBoh && !summary.isEmpty) ...[
            const SizedBox(height: 10),
            _WageMixWarningBand(
              text:
                  'Add at least one front role and one back role to use the custom wage mix.',
            ),
          ],
          if (summary.isEmpty) ...[
            const SizedBox(height: 10),
            _WageMixWarningBand(
              text: 'No roles are configured. Default wages are being used.',
            ),
          ],
          const SizedBox(height: 14),
          _WageBucketCard(
            wire: 'foh',
            header: 'Front of house',
            helper: 'Service team',
            rows: summary.fohRows,
          ),
          const SizedBox(height: 10),
          _WageBucketCard(
            wire: 'boh',
            header: 'Back of house',
            helper: 'Kitchen team',
            rows: summary.bohRows,
          ),
          const SizedBox(height: 10),
          _WageBucketCard(
            wire: 'manager',
            header: 'Management',
            helper: 'Salaried + management hours',
            rows: summary.managerRows,
          ),
          if (!widget.viewOnly) ...[
            const SizedBox(height: 16),
            _WageMixPrimaryButton(
              icon: Icons.edit_outlined,
              label: 'Edit wage mix',
              onTap: _openMixEditor,
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Whole-mix editor result (7.55p.5f1a) ───────────────────────────────

/// Diff computed by [_WageMixEditorScreen.Save] vs the initial persisted
/// rows. The Settings section applies this diff in one pass through the
/// existing wage-authority seam.
class _WageMixEditResult {
  final List<WageRoleRow> rowsToPersist;
  final List<int> idsToDelete;
  const _WageMixEditResult({
    required this.rowsToPersist,
    required this.idsToDelete,
  });
}

// ─── Whole-mix editor screen (7.55p.5f1a) ───────────────────────────────
//
// The user enters the entire FOH + BOH + Management mix inline here and
// saves once. Previously each bucket had its own "+ Add role" button
// that opened a separate dialog per row — which is not a whole-mix
// interaction. This screen keeps all three buckets editable on one
// surface and persists in a single save pass.

class _WageMixEditorScreen extends StatefulWidget {
  final String restaurantId;
  final List<WageRoleRow> initialRows;

  const _WageMixEditorScreen({
    required this.restaurantId,
    required this.initialRows,
  });

  @override
  State<_WageMixEditorScreen> createState() => _WageMixEditorScreenState();
}

class _WageMixEditorScreenState extends State<_WageMixEditorScreen> {
  /// Draft editor rows. Order is preserved within each bucket.
  final List<_EditorRow> _drafts = [];

  @override
  void initState() {
    super.initState();
    for (final r in widget.initialRows) {
      _drafts.add(_EditorRow.fromPersisted(r));
    }
  }

  @override
  void dispose() {
    for (final d in _drafts) {
      d.dispose();
    }
    super.dispose();
  }

  void _addRow(String bucket) {
    setState(() {
      _drafts.add(_EditorRow.blank(bucket));
    });
  }

  void _removeRow(_EditorRow row) {
    setState(() {
      row.dispose();
      _drafts.remove(row);
    });
  }

  /// Builds the save diff: valid drafts become upsert rows; any
  /// persisted id that is no longer in the draft list gets deleted.
  _WageMixEditResult _buildResult() {
    final persist = <WageRoleRow>[];
    final keptIds = <int>{};
    for (final d in _drafts) {
      final row = d.toRowOrNull(widget.restaurantId);
      if (row != null) {
        persist.add(row);
        if (d.persistedId != null) {
          keptIds.add(d.persistedId!);
        }
      }
    }
    final deletes = widget.initialRows
        .where((r) => r.id != null && !keptIds.contains(r.id))
        .map((r) => r.id!)
        .toList();
    return _WageMixEditResult(rowsToPersist: persist, idsToDelete: deletes);
  }

  List<_EditorRow> _forBucket(String b) =>
      _drafts.where((d) => d.bucket == b).toList();

  /// Live snapshot of the current draft rows as persisted rows for
  /// totals / warning preview. Drafts with invalid inputs are skipped.
  List<WageRoleRow> _liveRows() {
    return _drafts
        .map((d) => d.toRowOrNull(widget.restaurantId))
        .whereType<WageRoleRow>()
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final summary = WageStandardContextService.summarizeMix(_liveRows());
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundDeep,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        title: Text('Edit wage mix', style: AppTextStyles.display20()),
        leading: IconButton(
          icon: const Icon(Icons.close, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      // Primary Save action is pinned to the bottom so it's always reachable
      // regardless of how far the user has scrolled.
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: const BoxDecoration(
            color: AppColors.backgroundDeep,
            border: Border(
              top: BorderSide(color: AppColors.borderSubtle, width: 1),
            ),
          ),
          child: _WageMixPrimaryButton(
            icon: Icons.check_rounded,
            label: 'Save wage mix',
            onTap: () => Navigator.of(context).pop(_buildResult()),
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Hint so users understand the flow before they see the fields
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
              child: Text(
                'Add every role you staff. Rate is per hour, Hours is per week.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ),

            _editorBucket(
              header: 'Front of house',
              bucket: 'foh',
              addLabel: 'Add front role',
            ),
            const SizedBox(height: 12),
            _editorBucket(
              header: 'Back of house',
              bucket: 'boh',
              addLabel: 'Add back role',
            ),
            const SizedBox(height: 12),
            _editorBucket(
              header: 'Management',
              bucket: 'manager',
              addLabel: 'Add management role',
              helper:
                  'Management roles help estimate the average wage, but do not change front or back staffing.',
            ),

            const SizedBox(height: 16),

            // Live mix summary inside the editor so the user can see the
            // consequence of their in-flight edits before saving.
            _WageMixSectionCard(
              title: 'Mix summary',
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _WageMixStat(
                        label: 'Hours per week',
                        value:
                            '${summary.totalWeightedHours.toStringAsFixed(0)} h',
                      ),
                    ),
                    Expanded(
                      child: _WageMixStat(
                        label: 'Weekly cost',
                        value:
                            '\$${summary.totalHourlyCost.toStringAsFixed(0)}',
                      ),
                    ),
                  ],
                ),
                if (!summary.hasCompleteFohBoh && !summary.isEmpty) ...[
                  const SizedBox(height: 8),
                  _WageMixWarningBand(
                    text:
                        'Add at least one front role and one back role before saving to use the custom wage mix.',
                  ),
                ],
                if (summary.isEmpty) ...[
                  const SizedBox(height: 8),
                  _WageMixWarningBand(
                    text:
                        'No roles yet. Default wages will stay in place until you add a front role and a back role.',
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _editorBucket({
    required String header,
    required String bucket,
    required String addLabel,
    String? helper,
  }) {
    final rows = _forBucket(bucket);
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header strip with role count pill
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
              ),
            ),
            child: Row(
              children: [
                Container(width: 3, height: 14, color: AppColors.sunset),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    header,
                    style: AppTextStyles.mono12(
                      color: AppColors.textPrimary,
                      weight: FontWeight.w700,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.borderSubtle, width: 1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${rows.length}',
                    style: AppTextStyles.mono10(color: AppColors.textMuted),
                  ),
                ),
              ],
            ),
          ),
          if (helper != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Text(
                helper,
                style: AppTextStyles.body13(color: AppColors.textMuted),
              ),
            ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
              child: Text(
                'No roles yet.',
                style: AppTextStyles.body13(color: AppColors.textMuted),
              ),
            ),
          for (int i = 0; i < rows.length; i++) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(10, i == 0 ? 10 : 6, 10, 4),
              child: _editorRowTile(rows[i]),
            ),
          ],
          // Add-row button
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
            child: _WageMixSecondaryButton(
              icon: Icons.add_rounded,
              label: addLabel,
              onTap: () => _addRow(bucket),
            ),
          ),
        ],
      ),
    );
  }

  Widget _editorRowTile(_EditorRow row) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep.withValues(alpha: 0.5),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Role name row + remove
          Row(
            children: [
              Expanded(
                child: _labeledField(
                  label: 'Role',
                  child: TextField(
                    key: row.nameKey,
                    controller: row.nameCtrl,
                    style: AppTextStyles.mono12(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'e.g. Server',
                      hintStyle: AppTextStyles.mono11(
                        color: AppColors.textMuted,
                      ),
                      isDense: true,
                      border: InputBorder.none,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
              IconButton(
                key: row.removeKey,
                tooltip: 'Remove role',
                icon: Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: AppColors.textMuted,
                ),
                onPressed: () => _removeRow(row),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(height: 1, color: AppColors.borderSubtle),
          const SizedBox(height: 6),
          // Rate + Hours row
          Row(
            children: [
              Expanded(
                child: _labeledField(
                  label: 'Rate per hour',
                  child: TextField(
                    key: row.rateKey,
                    controller: row.rateCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: AppTextStyles.mono12(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: '0.00',
                      hintStyle: AppTextStyles.mono11(
                        color: AppColors.textMuted,
                      ),
                      isDense: true,
                      prefixText: '\$',
                      prefixStyle: AppTextStyles.mono12(
                        color: AppColors.textSecondary,
                      ),
                      border: InputBorder.none,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _labeledField(
                  label: 'Hours per week',
                  child: TextField(
                    key: row.hoursKey,
                    controller: row.hoursCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: AppTextStyles.mono12(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: '0',
                      hintStyle: AppTextStyles.mono11(
                        color: AppColors.textMuted,
                      ),
                      isDense: true,
                      suffixText: 'h',
                      suffixStyle: AppTextStyles.mono12(
                        color: AppColors.textSecondary,
                      ),
                      border: InputBorder.none,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _labeledField({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.mono8(color: AppColors.textMuted)),
        const SizedBox(height: 2),
        child,
      ],
    );
  }
}

/// Editable draft state for one row in the whole-mix editor.
///
/// Owns its own text controllers so in-flight edits do not race with
/// SetState rebuilds. `persistedId` is the SQLite id for rows that
/// already exist — `null` for new rows the user added in this editor.
class _EditorRow {
  final int? persistedId;
  final String bucket;
  final TextEditingController nameCtrl;
  final TextEditingController rateCtrl;
  final TextEditingController hoursCtrl;
  final Key nameKey;
  final Key rateKey;
  final Key hoursKey;
  final Key removeKey;

  _EditorRow._({
    required this.persistedId,
    required this.bucket,
    required this.nameCtrl,
    required this.rateCtrl,
    required this.hoursCtrl,
  }) : nameKey = UniqueKey(),
       rateKey = UniqueKey(),
       hoursKey = UniqueKey(),
       removeKey = UniqueKey();

  factory _EditorRow.blank(String bucket) {
    return _EditorRow._(
      persistedId: null,
      bucket: bucket,
      nameCtrl: TextEditingController(),
      rateCtrl: TextEditingController(),
      hoursCtrl: TextEditingController(),
    );
  }

  factory _EditorRow.fromPersisted(WageRoleRow r) {
    return _EditorRow._(
      persistedId: r.id,
      bucket: r.laborBucket,
      nameCtrl: TextEditingController(text: r.roleName),
      rateCtrl: TextEditingController(text: r.hourlyRate.toStringAsFixed(2)),
      hoursCtrl: TextEditingController(
        text: r.weightedHours.toStringAsFixed(0),
      ),
    );
  }

  /// Converts this draft into a persistable `WageRoleRow`, or null if
  /// the user has not filled it in enough to be valid.
  WageRoleRow? toRowOrNull(String restaurantId) {
    final name = nameCtrl.text.trim();
    final rate = double.tryParse(rateCtrl.text.trim());
    final hours = double.tryParse(hoursCtrl.text.trim());
    if (name.isEmpty) return null;
    if (rate == null || rate < 0) return null;
    if (hours == null || hours < 0) return null;
    return WageRoleRow(
      id: persistedId,
      restaurantId: restaurantId,
      roleName: name,
      laborBucket: bucket,
      hourlyRate: rate,
      weightedHours: hours,
    );
  }

  void dispose() {
    nameCtrl.dispose();
    rateCtrl.dispose();
    hoursCtrl.dispose();
  }
}

// ─── Wage mix shared UI primitives ────────────────────────────────────────
// Card surfaces, stat pills, warning bands, and button shells shared by
// both the Settings summary panel and the full-screen editor so the
// read-only view and the edit view feel like one UI.

class _WageMixSectionCard extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  const _WageMixSectionCard({this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title!,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
            const SizedBox(height: 10),
          ],
          ...children,
        ],
      ),
    );
  }
}

class _WageMixStat extends StatelessWidget {
  final String label;
  final String value;
  const _WageMixStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.mono8(color: AppColors.textMuted)),
        const SizedBox(height: 3),
        Text(value, style: AppTextStyles.mono14(color: AppColors.textPrimary)),
      ],
    );
  }
}

class _WageMixWarningBand extends StatelessWidget {
  final String text;
  const _WageMixWarningBand({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border.all(color: AppColors.warning, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 14, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: AppTextStyles.body13(color: AppColors.warning),
            ),
          ),
        ],
      ),
    );
  }
}

/// Blended-wage summary card for the read-only mobile Wage Setup
/// surface. Mirrors operator-web's `BlendedWageSummaryCard` (flat
/// card, no gradient / no count pill): a "Blended wage mix" heading,
/// the effective average hourly cost, the HP #11 provenance line
/// ("Source: …"), the weekly totals line, and front/back effective
/// wage badges. Pure presentation — every value is passed in by the
/// section from the resolved [WageStandardContext] + summarized rows.
class _WageInfoCard extends StatelessWidget {
  const _WageInfoCard({
    required this.sourceLabel,
    required this.fohWage,
    required this.bohWage,
    required this.blendedWage,
    required this.totalWeightedHours,
    required this.totalHourlyCost,
    required this.hasRows,
  });

  final String sourceLabel;
  final double? fohWage;
  final double? bohWage;
  final double? blendedWage;
  final double totalWeightedHours;
  final double totalHourlyCost;
  final bool hasRows;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('settings_wage_setup_summary_card'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.insights_outlined,
                size: 18,
                color: AppColors.sunsetDark,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Blended wage mix',
                  style: AppTextStyles.mono15(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            blendedWage != null
                ? '\$${blendedWage!.toStringAsFixed(2)}/hr'
                : 'Not set yet',
            style: AppTextStyles.display20(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 4),
          // HP #11: provenance of the effective wage values.
          Text(
            'Source: $sourceLabel',
            key: const Key('settings_wage_setup_source'),
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
          if (hasRows) ...[
            const SizedBox(height: 10),
            Text(
              'Total weekly cost: \$${totalHourlyCost.toStringAsFixed(0)} · '
              '${totalWeightedHours.toStringAsFixed(0)} '
              '${totalWeightedHours == 1 ? 'hour' : 'hours'} per week',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ],
          if (fohWage != null || bohWage != null) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 6,
              children: [
                if (fohWage != null)
                  _WageBadge(
                    label:
                        'Front of house · \$${fohWage!.toStringAsFixed(2)}/hr',
                  ),
                if (bohWage != null)
                  _WageBadge(
                    label:
                        'Back of house · \$${bohWage!.toStringAsFixed(2)}/hr',
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _WageBadge extends StatelessWidget {
  const _WageBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        label,
        style: AppTextStyles.body12(color: AppColors.textPrimary),
      ),
    );
  }
}

/// One labor-bucket card for the read-only mobile Wage Setup surface.
/// Mirrors operator-web's `_BucketSection`: a flat card, the bucket
/// label + a short helper phrase, then one clean row per role with a
/// single formula crumb. No gradient, no role-count pill, no per-row
/// columns — the same visual grammar as the operator-web screen.
class _WageBucketCard extends StatelessWidget {
  const _WageBucketCard({
    required this.wire,
    required this.header,
    required this.helper,
    required this.rows,
  });

  final String wire;
  final String header;
  final String helper;
  final List<WageRoleRow> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('settings_wage_setup_bucket_$wire'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            header,
            style: AppTextStyles.mono15(
              color: AppColors.textPrimary,
              weight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            helper,
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            Text(
              'No roles yet.',
              style: AppTextStyles.body12(color: AppColors.textMuted),
            )
          else
            for (var i = 0; i < rows.length; i++) ...[
              _WageRoleLine(row: rows[i]),
              if (i != rows.length - 1)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Divider(
                    height: 1,
                    color: AppColors.borderSubtle,
                  ),
                ),
            ],
        ],
      ),
    );
  }
}

/// A single role row: name on top, then the operator-readable formula
/// crumb (`@ $/hr · weighted hrs/wk = $`) — identical grammar to the
/// operator-web `_WageRowDisplay` so the two surfaces read the same.
class _WageRoleLine extends StatelessWidget {
  const _WageRoleLine({required this.row});

  final WageRoleRow row;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          row.roleName,
          style: AppTextStyles.mono14(
            color: AppColors.textPrimary,
            weight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '@ \$${row.hourlyRate.toStringAsFixed(2)}/hr · '
          '${row.weightedHours.toStringAsFixed(1)} weighted hrs/wk = '
          '\$${(row.hourlyRate * row.weightedHours).toStringAsFixed(2)}',
          style: AppTextStyles.body12(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _WageMixPrimaryButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _WageMixPrimaryButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.sunset, AppColors.sunsetDark],
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: AppColors.backgroundDeep),
            const SizedBox(width: 10),
            Text(
              label,
              style: AppTextStyles.mono14(
                color: AppColors.backgroundDeep,
                weight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WageMixSecondaryButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _WageMixSecondaryButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(
            color: AppColors.sunset.withValues(alpha: 0.6),
            width: 1,
          ),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: AppColors.sunset),
            const SizedBox(width: 8),
            Text(label, style: AppTextStyles.mono12(color: AppColors.sunset)),
          ],
        ),
      ),
    );
  }
}
