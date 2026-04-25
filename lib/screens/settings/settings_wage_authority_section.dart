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
  const WageAuthoritySection({super.key, required this.onChanged});

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
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final restaurantId = await SqliteRestaurantScopeRepository.instance
          .getActiveRestaurantId();
      _wageCtx =
          await WageStandardContextService.instance.resolve(restaurantId);
      _rows =
          await SqliteWageRoleRowRepository.instance.getRows(restaurantId);
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
        child: Text('Loading...',
            style: AppTextStyles.mono11(color: AppColors.textMuted)),
      );
    }

    final w = _wageCtx;
    final summary = WageStandardContextService.summarizeMix(_rows);
    return Container(
      color: AppColors.backgroundMid,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Resolved wages card — headline numbers at a glance ───────────
          _WageMixSectionCard(
            children: [
              _WageMixStatRow(
                label: 'SOURCE',
                value: w?.source.displayLabel ?? '—',
              ),
              const _WageMixDivider(),
              Row(
                children: [
                  Expanded(
                    child: _WageMixStat(
                      label: 'FOH WAGE',
                      value: w?.fohWage != null
                          ? '\$${w!.fohWage!.toStringAsFixed(2)}'
                          : '—',
                    ),
                  ),
                  Expanded(
                    child: _WageMixStat(
                      label: 'BOH WAGE',
                      value: w?.bohWage != null
                          ? '\$${w!.bohWage!.toStringAsFixed(2)}'
                          : '—',
                    ),
                  ),
                  Expanded(
                    child: _WageMixStat(
                      label: 'BLENDED',
                      value: w?.referenceBlendedWage != null
                          ? '\$${w!.referenceBlendedWage!.toStringAsFixed(2)}'
                          : '—',
                    ),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ── Mix summary card — totals ────────────────────────────────
          _WageMixSectionCard(
            title: 'MIX SUMMARY',
            children: [
              Row(
                children: [
                  Expanded(
                    child: _WageMixStat(
                      label: 'TOTAL HOURS/WK',
                      value:
                          '${summary.totalWeightedHours.toStringAsFixed(0)} h',
                    ),
                  ),
                  Expanded(
                    child: _WageMixStat(
                      label: 'WEEKLY COST',
                      value: '\$${summary.totalHourlyCost.toStringAsFixed(0)}',
                    ),
                  ),
                ],
              ),
              if (!summary.hasCompleteFohBoh && !summary.isEmpty) ...[
                const SizedBox(height: 8),
                _WageMixWarningBand(
                  text: 'Needs at least one FOH role AND one BOH role to '
                      'resolve as App Configured. Currently using Config '
                      'Default.',
                ),
              ],
              if (summary.isEmpty) ...[
                const SizedBox(height: 8),
                _WageMixWarningBand(
                  text:
                      'No roles configured — wages resolve from Config Default.',
                ),
              ],
            ],
          ),

          const SizedBox(height: 12),

          // ── Read-only grouped display of the current mix ──────────────
          _WageMixBucketCard(
            header: 'FRONT OF HOUSE',
            rows: summary.fohRows,
          ),
          const SizedBox(height: 10),
          _WageMixBucketCard(
            header: 'BACK OF HOUSE',
            rows: summary.bohRows,
          ),
          const SizedBox(height: 10),
          _WageMixBucketCard(
            header: 'MANAGEMENT',
            rows: summary.managerRows,
            helper: 'Management rows contribute to reference blended only.',
          ),

          const SizedBox(height: 16),

          // ── Single whole-mix edit action (primary button) ────────────
          _WageMixPrimaryButton(
            icon: Icons.edit_outlined,
            label: 'Edit Wage Mix',
            onTap: _openMixEditor,
          ),
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
    return _WageMixEditResult(
      rowsToPersist: persist,
      idsToDelete: deletes,
    );
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
    final summary =
        WageStandardContextService.summarizeMix(_liveRows());
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundDeep,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        title: Text('Edit Wage Mix', style: AppTextStyles.display20()),
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
            label: 'Save Wage Mix',
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
            header: 'FRONT OF HOUSE',
            bucket: 'foh',
            addLabel: 'Add FOH role',
          ),
          const SizedBox(height: 12),
          _editorBucket(
            header: 'BACK OF HOUSE',
            bucket: 'boh',
            addLabel: 'Add BOH role',
          ),
          const SizedBox(height: 12),
          _editorBucket(
            header: 'MANAGEMENT',
            bucket: 'manager',
            addLabel: 'Add Management role',
            helper: 'Management rows contribute to reference blended only.',
          ),

          const SizedBox(height: 16),

          // Live mix summary inside the editor so the user can see the
          // consequence of their in-flight edits before saving.
          _WageMixSectionCard(
            title: 'MIX SUMMARY',
            children: [
              Row(
                children: [
                  Expanded(
                    child: _WageMixStat(
                      label: 'TOTAL HOURS/WK',
                      value:
                          '${summary.totalWeightedHours.toStringAsFixed(0)} h',
                    ),
                  ),
                  Expanded(
                    child: _WageMixStat(
                      label: 'WEEKLY COST',
                      value: '\$${summary.totalHourlyCost.toStringAsFixed(0)}',
                    ),
                  ),
                ],
              ),
              if (!summary.hasCompleteFohBoh && !summary.isEmpty) ...[
                const SizedBox(height: 8),
                _WageMixWarningBand(
                  text: 'Will fall back to Config Default on save. Add at '
                      'least one FOH row AND one BOH row for App Configured.',
                ),
              ],
              if (summary.isEmpty) ...[
                const SizedBox(height: 8),
                _WageMixWarningBand(
                  text:
                      'No rows — wages will stay on Config Default until you '
                      'add at least one FOH row and one BOH row.',
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
                Container(
                  width: 3,
                  height: 14,
                  color: AppColors.sunset,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(header,
                      style: AppTextStyles.mono12(
                          color: AppColors.textPrimary,
                          weight: FontWeight.w700)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: AppColors.borderSubtle, width: 1),
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
              child: Text(helper,
                  style: AppTextStyles.body13(color: AppColors.textMuted)),
            ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
              child: Text('No roles yet.',
                  style: AppTextStyles.body13(color: AppColors.textMuted)),
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
                  label: 'ROLE',
                  child: TextField(
                    key: row.nameKey,
                    controller: row.nameCtrl,
                    style:
                        AppTextStyles.mono12(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'e.g. Server',
                      hintStyle:
                          AppTextStyles.mono11(color: AppColors.textMuted),
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
                icon: Icon(Icons.delete_outline,
                    size: 18, color: AppColors.textMuted),
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
                  label: 'RATE \$/HR',
                  child: TextField(
                    key: row.rateKey,
                    controller: row.rateCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    style:
                        AppTextStyles.mono12(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: '0.00',
                      hintStyle:
                          AppTextStyles.mono11(color: AppColors.textMuted),
                      isDense: true,
                      prefixText: '\$',
                      prefixStyle: AppTextStyles.mono12(
                          color: AppColors.textSecondary),
                      border: InputBorder.none,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _labeledField(
                  label: 'HOURS/WK',
                  child: TextField(
                    key: row.hoursKey,
                    controller: row.hoursCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    style:
                        AppTextStyles.mono12(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: '0',
                      hintStyle:
                          AppTextStyles.mono11(color: AppColors.textMuted),
                      isDense: true,
                      suffixText: 'h',
                      suffixStyle: AppTextStyles.mono12(
                          color: AppColors.textSecondary),
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
        Text(label,
            style: AppTextStyles.mono8(color: AppColors.textMuted)),
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
  })  : nameKey = UniqueKey(),
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
      hoursCtrl:
          TextEditingController(text: r.weightedHours.toStringAsFixed(0)),
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
            Text(title!,
                style: AppTextStyles.mono10(color: AppColors.textMuted)),
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
        Text(label,
            style: AppTextStyles.mono8(color: AppColors.textMuted)),
        const SizedBox(height: 3),
        Text(value,
            style: AppTextStyles.mono14(color: AppColors.textPrimary)),
      ],
    );
  }
}

class _WageMixStatRow extends StatelessWidget {
  final String label;
  final String value;
  const _WageMixStatRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: AppTextStyles.mono8(color: AppColors.textMuted)),
        ),
        Text(value,
            style: AppTextStyles.mono12(color: AppColors.textPrimary)),
      ],
    );
  }
}

class _WageMixDivider extends StatelessWidget {
  const _WageMixDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(height: 1, color: AppColors.borderSubtle),
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
          Icon(Icons.warning_amber_rounded,
              size: 14, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: AppTextStyles.body13(color: AppColors.warning)),
          ),
        ],
      ),
    );
  }
}

class _WageMixBucketCard extends StatelessWidget {
  final String header;
  final List<WageRoleRow> rows;
  final String? helper;
  const _WageMixBucketCard({
    required this.header,
    required this.rows,
    this.helper,
  });

  @override
  Widget build(BuildContext context) {
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
          // Header strip
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
                  child: Text(header,
                      style: AppTextStyles.mono12(
                          color: AppColors.textPrimary,
                          weight: FontWeight.w700)),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    border: Border.all(
                        color: AppColors.borderSubtle, width: 1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('${rows.length}',
                      style: AppTextStyles.mono10(color: AppColors.textMuted)),
                ),
              ],
            ),
          ),
          if (helper != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Text(helper!,
                  style: AppTextStyles.body13(color: AppColors.textMuted)),
            ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Text('No roles yet.',
                  style: AppTextStyles.body13(color: AppColors.textMuted)),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Column(
                children: [
                  for (int i = 0; i < rows.length; i++) ...[
                    if (i > 0)
                      Container(
                        height: 1,
                        color: AppColors.borderSubtle.withValues(alpha: 0.5),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 4,
                            child: Text(rows[i].roleName,
                                style: AppTextStyles.mono12(
                                    color: AppColors.textPrimary)),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              '\$${rows[i].hourlyRate.toStringAsFixed(2)}',
                              style: AppTextStyles.mono12(
                                  color: AppColors.textPrimary),
                              textAlign: TextAlign.right,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 2,
                            child: Text(
                              '${rows[i].weightedHours.toStringAsFixed(0)} h',
                              style: AppTextStyles.mono11(
                                  color: AppColors.textSecondary),
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
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
            Text(label,
                style: AppTextStyles.mono14(
                    color: AppColors.backgroundDeep,
                    weight: FontWeight.w700)),
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
              color: AppColors.sunset.withValues(alpha: 0.6), width: 1),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: AppColors.sunset),
            const SizedBox(width: 8),
            Text(label,
                style: AppTextStyles.mono12(color: AppColors.sunset)),
          ],
        ),
      ),
    );
  }
}
