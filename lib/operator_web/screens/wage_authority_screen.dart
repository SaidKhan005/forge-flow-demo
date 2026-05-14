// Phase 8 W5.A.2 - Operator Web Wage authority screen.
//
// Web parity for the mobile `WageAuthoritySection`. The mobile section
// was collapsed to view-only by W3.A; this screen is where operator
// owners and admins now manage the operator's wage role rows.
//
// Layout:
//   * One section per labor bucket (FOH / BOH / Management).
//   * Each row shows role name, hourly rate, weighted hours, and an
//     optional vendor / job-code mapping. Edit + delete affordances
//     live on each row.
//   * An add-row form sits inside each bucket so the operator can fill
//     the bucket without scrolling away to a global form.
//
// Behavior:
//   * Save fires `upsert` through the gateway with a fresh
//     `Idempotency-Key`. Replay returns the same row (server upserts
//     on the natural-key 4-tuple).
//   * Delete confirms in a dialog, then fires `delete` with a fresh
//     `Idempotency-Key`. Optimistic rollback on error.
//   * Read-only mode: actors who lack operator-write roles see the
//     same data but every action is hidden + a friendly read-only
//     banner explains the constraint. Server-side RLS + the proxy's
//     `kOperatorWriteRoles` gate are the authority; the UI is the
//     friendly-error layer.
//
// UX writing standard (`memory/project_ux_writing_standard.md`):
// every label, button, status, snackbar trains the operator. Plain
// English. No engineering jargon.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models/wage_role_row_record.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/operator_web_wage_authority_gateway.dart';
import '../widgets/hierarchy_scope_notice.dart';
import '../../theme/app_theme.dart';
import 'wage_authority/blended_wage_calculator.dart';
import 'wage_authority/blended_wage_summary_card.dart';
import 'wage_authority/wage_vendor_applicability_label.dart';

/// Roles admitted to write wage rows. Mirrors `kOperatorWriteRoles` in
/// `tool/advisor_proxy/operator_routes.dart` so the UI gate matches the
/// proxy gate.
const Set<String> _kOperatorWriteRoles = <String>{
  'operator_owner',
  'operator_admin',
};

/// Bucket order rendered in the screen. Wire values match the
/// migration's CHECK constraint.
const List<_BucketSpec> _kBuckets = <_BucketSpec>[
  _BucketSpec(wire: 'foh', label: 'Front of house', helper: 'Service team'),
  _BucketSpec(wire: 'boh', label: 'Back of house', helper: 'Kitchen team'),
  _BucketSpec(
    wire: 'manager',
    label: 'Management',
    helper: 'Salaried + management hours',
  ),
];

class _BucketSpec {
  const _BucketSpec({
    required this.wire,
    required this.label,
    required this.helper,
  });

  final String wire;
  final String label;
  final String helper;
}

class WageAuthorityScreen extends StatefulWidget {
  const WageAuthorityScreen({
    super.key,
    required this.session,
    required this.locationId,
    required this.locationName,
    this.gateway,
    this.idempotencyKeyFactory,
    this.connectedLaborVendorIds = const <String>{},
  });

  final OperatorWebSession session;

  /// Operator-selected location whose wage rows the editor manages.
  /// The proxy resolves operator + location from the JWT, but we still
  /// pass the location id explicitly so the GET URL targets the right
  /// scope.
  final String locationId;
  final String locationName;

  /// Live gateway. When null the screen renders honest read-only
  /// state with snackbar copy explaining the disconnect.
  final OperatorWebWageAuthorityGateway? gateway;

  /// Test-injectable idempotency-key generator. Production wires in a
  /// random-bytes generator; tests inject a deterministic counter.
  final String Function()? idempotencyKeyFactory;

  /// Labor vendor ids the operator has connected at this location.
  /// Drives the "Manual only — pick a vendor role…" copy on rows with
  /// no `vendor_id`. Empty when no labor vendor is connected; the
  /// row's label then reads "Manual only — no labor vendor connected".
  final Set<String> connectedLaborVendorIds;

  @override
  State<WageAuthorityScreen> createState() => _WageAuthorityScreenState();
}

class _WageAuthorityScreenState extends State<WageAuthorityScreen> {
  /// Current rows, keyed by `wage_role_row_id`. Mirrors what the
  /// gateway returned on the most recent list call.
  final Map<String, WageRoleRowRecord> _rowsById = <String, WageRoleRowRecord>{};

  bool _loading = true;
  String? _loadError;

  /// Set of row ids currently expanded into in-line edit mode.
  final Set<String> _editingIds = <String>{};

  /// Set of bucket wire values whose add-row form is currently
  /// visible. The form is rendered alongside the bucket section so
  /// the operator can fill one bucket without losing scroll position.
  final Set<String> _addingForBuckets = <String>{};

  /// In-flight per-row edits, keyed by `wage_role_row_id`. Updated
  /// every time the operator types in the edit form so the blended-
  /// wage summary card recomputes without waiting for a save round-
  /// trip. Cleared when the form closes (save / cancel).
  final Map<String, _DraftRowValues> _draftEdits =
      <String, _DraftRowValues>{};

  /// In-flight values for an open add-row form, keyed by `laborBucket`.
  /// Updated by the same typing seam as [_draftEdits] so newly typed
  /// rows roll into the blended-wage summary immediately.
  final Map<String, _DraftRowValues> _draftAdds =
      <String, _DraftRowValues>{};

  int _idemCounter = 0;

  @override
  void initState() {
    super.initState();
    _idemCounter = 0;
    unawaited(_loadInitial());
  }

  bool get _canWrite =>
      widget.gateway != null &&
      widget.session.roles.any(_kOperatorWriteRoles.contains);

  String _newIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idemCounter += 1;
    final ts = DateTime.now().microsecondsSinceEpoch;
    final r = Random().nextInt(0xffffff);
    return 'web-wage-$ts-$_idemCounter-$r';
  }

  Future<void> _loadInitial() async {
    final gateway = widget.gateway;
    if (gateway == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final rows = await gateway.list(
        operatorId: widget.session.operatorId,
        locationId: widget.locationId,
      );
      if (!mounted) return;
      setState(() {
        _rowsById
          ..clear()
          ..addEntries(<MapEntry<String, WageRoleRowRecord>>[
            for (final r in rows) MapEntry(r.wageRoleRowId, r),
          ]);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError =
            "We couldn't load your wage rows. Refresh the page or try again in a minute.";
      });
    }
  }

  List<WageRoleRowRecord> _rowsForBucket(String wireBucket) {
    final list = _rowsById.values
        .where((r) => r.laborBucket == wireBucket && r.isActive)
        .toList()
      ..sort((a, b) => a.roleName.toLowerCase().compareTo(
            b.roleName.toLowerCase(),
          ));
    return list;
  }

  Future<void> _saveRow({
    required String laborBucket,
    required _WageRowFormResult form,
    String? existingRowId,
  }) async {
    final gateway = widget.gateway;
    if (gateway == null) return;
    final restaurantId = form.restaurantId.isNotEmpty
        ? form.restaurantId
        // Fallback for the V1 1:1 location-to-restaurant model: use the
        // location id as the restaurant id when the operator hasn't
        // entered an explicit value. Keeps the editor usable for
        // operators who don't carry a separate restaurant_id concept.
        : widget.locationId;
    final request = WageRoleRowUpsert(
      restaurantId: restaurantId,
      roleName: form.roleName,
      laborBucket: laborBucket,
      hourlyRate: form.hourlyRate,
      weightedHours: form.weightedHours,
      jobCode: form.jobCode,
      vendorId: form.vendorId,
      vendorRoleId: form.vendorRoleId,
    );
    try {
      final saved = await gateway.upsert(
        request: request,
        idempotencyKey: _newIdempotencyKey(),
      );
      if (!mounted) return;
      setState(() {
        // Drop any previous row keyed by the same role_name +
        // restaurant_id (server upsert may have collided onto a
        // different uuid in the demo gateway path).
        if (existingRowId != null) _rowsById.remove(existingRowId);
        _rowsById[saved.wageRoleRowId] = saved;
        _editingIds.remove(existingRowId);
        _addingForBuckets.remove(laborBucket);
        if (existingRowId != null) _draftEdits.remove(existingRowId);
        _draftAdds.remove(laborBucket);
      });
      _showSnackBar('Saved just now', isError: false);
    } catch (_) {
      if (!mounted) return;
      _showSnackBar(
        "Couldn't save - try again",
        isError: true,
        keyName: 'wage_authority_save_error_snackbar',
      );
    }
  }

  Future<void> _confirmAndDelete(WageRoleRowRecord row) async {
    final gateway = widget.gateway;
    if (gateway == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('wage_authority_delete_confirm_dialog'),
        title: const Text('Remove this wage row?'),
        content: Text(
          'Forge & Flow will stop using ${row.roleName} (\$${row.hourlyRate.toStringAsFixed(2)}/hr) '
          'when calculating your labor mix. You can add it back any time.',
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('wage_authority_delete_cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            key: const Key('wage_authority_delete_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // Optimistic remove.
    final snapshot = _rowsById[row.wageRoleRowId];
    setState(() => _rowsById.remove(row.wageRoleRowId));
    try {
      await gateway.delete(
        wageRoleRowId: row.wageRoleRowId,
        idempotencyKey: _newIdempotencyKey(),
      );
      if (!mounted) return;
      _showSnackBar('Removed', isError: false);
    } catch (_) {
      if (!mounted) return;
      // Roll back the optimistic remove.
      setState(() {
        if (snapshot != null) _rowsById[row.wageRoleRowId] = snapshot;
      });
      _showSnackBar(
        "Couldn't remove - try again",
        isError: true,
        keyName: 'wage_authority_delete_error_snackbar',
      );
    }
  }

  /// Build the input rows for [computeBlendedWageSummary]. Saved rows
  /// are projected straight through; rows with an open edit form get
  /// their saved values overridden by the in-flight draft; open add-
  /// forms contribute the operator's typed-but-unsaved row.
  ///
  /// Only `isActive` saved rows participate — soft-deleted rows are
  /// excluded the same way they are from [_rowsForBucket].
  List<BlendedWageInputRow> _summaryInputs() {
    final inputs = <BlendedWageInputRow>[];
    for (final row in _rowsById.values) {
      if (!row.isActive) continue;
      final draft = _draftEdits[row.wageRoleRowId];
      if (draft != null) {
        inputs.add(BlendedWageInputRow(
          laborBucket: row.laborBucket,
          hourlyRate: draft.hourlyRate ?? row.hourlyRate,
          weightedHours: draft.weightedHours ?? row.weightedHours,
        ));
      } else {
        inputs.add(BlendedWageInputRow(
          laborBucket: row.laborBucket,
          hourlyRate: row.hourlyRate,
          weightedHours: row.weightedHours,
        ));
      }
    }
    for (final entry in _draftAdds.entries) {
      final hr = entry.value.hourlyRate;
      final wh = entry.value.weightedHours;
      if (hr == null || wh == null) continue;
      inputs.add(BlendedWageInputRow(
        laborBucket: entry.key,
        hourlyRate: hr,
        weightedHours: wh,
      ));
    }
    return inputs;
  }

  /// Compute the set of vendor ids actually used by any wage row on
  /// this screen. Falls back to the caller-supplied
  /// `connectedLaborVendorIds` when no row carries a `vendor_id` yet.
  /// Used by the per-row "Manual only - pick a vendor role..." copy
  /// to remind the operator which connected labor vendor a row can
  /// sync with.
  Set<String> _effectiveLaborVendorIds() {
    final fromRows = <String>{
      for (final r in _rowsById.values)
        if (r.isActive && r.vendorId != null && r.vendorId!.isNotEmpty)
          r.vendorId!,
    };
    if (fromRows.isNotEmpty) return fromRows;
    return widget.connectedLaborVendorIds;
  }

  void _showSnackBar(
    String message, {
    required bool isError,
    String? keyName,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: keyName != null ? Key(keyName) : null,
        content: Text(message),
        backgroundColor: isError ? AppColors.negative : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        key: Key('wage_authority_loading'),
        child: CircularProgressIndicator(),
      );
    }
    return SingleChildScrollView(
      key: const Key('wage_authority_screen'),
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _Header(),
          const SizedBox(height: 14),
          // HP #11 (`CLAUDE.md`): every settings / pricing / accuracy
          // surface declares its selected scope, inherited source, and
          // effective value. Wage authority writes the operator-scoped
          // `wage_role_rows` fact table; rows are keyed by
          // (operator_id, location_id, restaurant_id, role_name) per
          // db/migrations/202605080200_phase_8_wage_role_rows_server_
          // truth.sql, so the scope is Location with no higher-level
          // inheritance yet.
          //
          // When the wage table grows hierarchy-aware columns (e.g.
          // `scope_kind` + `inherited_from_scope_id`) each row will
          // carry its own inheritance badge inside the bucket section
          // — the same pattern Business setup's `_EffectiveFieldRow`
          // already follows. Until then the surface renders the scope
          // triple at the top of the screen and each bucket row stays
          // value-only.
          // TODO(wave-3+ hierarchy wages): replace the screen-level
          // notice with per-row inheritance badges once `wage_role_
          // rows` carries hierarchy columns.
          HierarchyScopeNotice(
            keyName: 'wage_authority_hierarchy_scope',
            selectedScope: HierarchyScopeLevel.location,
            scopeName: widget.locationName,
            inheritedFromLabel: null,
            effectiveValueSummary:
                "These wage rows apply only to ${widget.locationName}. "
                "Other locations carry their own wage rows.",
            backendOnlyExplainer:
                "Region- and brand-level wage floors (e.g. a corporate "
                "minimum that every location inherits unless overridden) "
                "are coming in a later wave. For now every wage row is "
                "set at the Location scope.",
          ),
          if (_loadError != null) ...<Widget>[
            const SizedBox(height: 12),
            _ErrorBanner(message: _loadError!),
          ],
          if (!_canWrite && widget.gateway != null) ...<Widget>[
            const SizedBox(height: 12),
            _ReadOnlyBanner(
              message:
                  'Only operator owners and operator admins can change wage rows. '
                  'Ask one of them to make the change for you.',
            ),
          ],
          if (widget.gateway == null) ...<Widget>[
            const SizedBox(height: 12),
            _ReadOnlyBanner(
              message:
                  'Wage row editing is unavailable in this preview. Sign in to '
                  'a live operator account to edit wage rows.',
            ),
          ],
          const SizedBox(height: 14),
          // Live blended-wage preview. Wave 2 S-1 — computes Σ(hours ×
          // rate) / Σ(hours) across saved rows plus any open in-flight
          // draft, so the operator sees the mix update before they
          // save. Anchored to debug.md:198-235 (OW-13a + OW-13b).
          BlendedWageSummaryCard(
            summary: computeBlendedWageSummary(
              rows: _summaryInputs(),
              bucketOrder: <String>[
                for (final b in _kBuckets) b.wire,
              ],
            ),
          ),
          const SizedBox(height: 18),
          for (final bucket in _kBuckets) ...<Widget>[
            _BucketSection(
              bucket: bucket,
              rows: _rowsForBucket(bucket.wire),
              canWrite: _canWrite,
              isEditing: (id) => _editingIds.contains(id),
              isAdding: _addingForBuckets.contains(bucket.wire),
              connectedLaborVendorIds: _effectiveLaborVendorIds(),
              onStartEdit: (id) {
                setState(() {
                  _editingIds.add(id);
                  _addingForBuckets.remove(bucket.wire);
                  _draftAdds.remove(bucket.wire);
                });
              },
              onCancelEdit: (id) {
                setState(() {
                  _editingIds.remove(id);
                  _draftEdits.remove(id);
                });
              },
              onStartAdd: () {
                setState(() {
                  _addingForBuckets.add(bucket.wire);
                });
              },
              onCancelAdd: () {
                setState(() {
                  _addingForBuckets.remove(bucket.wire);
                  _draftAdds.remove(bucket.wire);
                });
              },
              onEditDraftChanged: (id, draft) {
                setState(() {
                  _draftEdits[id] = draft;
                });
              },
              onAddDraftChanged: (draft) {
                setState(() {
                  _draftAdds[bucket.wire] = draft;
                });
              },
              onSaveEdit: (row, form) => _saveRow(
                laborBucket: bucket.wire,
                form: form,
                existingRowId: row.wageRoleRowId,
              ),
              onSaveAdd: (form) => _saveRow(
                laborBucket: bucket.wire,
                form: form,
              ),
              onDelete: _confirmAndDelete,
            ),
            const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        const Icon(
          Icons.payments_outlined,
          size: 22,
          color: AppColors.sunsetDark,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Wage authority',
            style: AppTextStyles.display20(color: AppColors.textPrimary),
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('wage_authority_error_banner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.10),
        border: Border.all(
          color: AppColors.negative.withValues(alpha: 0.45),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.error_outline, size: 16, color: AppColors.negative),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.negative),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('wage_authority_readonly_banner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          const Icon(
            Icons.lock_outline,
            size: 16,
            color: AppColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _BucketSection extends StatelessWidget {
  const _BucketSection({
    required this.bucket,
    required this.rows,
    required this.canWrite,
    required this.isEditing,
    required this.isAdding,
    required this.connectedLaborVendorIds,
    required this.onStartEdit,
    required this.onCancelEdit,
    required this.onStartAdd,
    required this.onCancelAdd,
    required this.onEditDraftChanged,
    required this.onAddDraftChanged,
    required this.onSaveEdit,
    required this.onSaveAdd,
    required this.onDelete,
  });

  final _BucketSpec bucket;
  final List<WageRoleRowRecord> rows;
  final bool canWrite;
  final bool Function(String) isEditing;
  final bool isAdding;
  final Set<String> connectedLaborVendorIds;
  final void Function(String) onStartEdit;
  final void Function(String) onCancelEdit;
  final VoidCallback onStartAdd;
  final VoidCallback onCancelAdd;
  final void Function(String rowId, _DraftRowValues draft) onEditDraftChanged;
  final void Function(_DraftRowValues draft) onAddDraftChanged;
  final Future<void> Function(WageRoleRowRecord, _WageRowFormResult) onSaveEdit;
  final Future<void> Function(_WageRowFormResult) onSaveAdd;
  final Future<void> Function(WageRoleRowRecord) onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('wage_authority_bucket_${bucket.wire}'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      bucket.label,
                      style: AppTextStyles.mono15(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      bucket.helper,
                      style: AppTextStyles.body12(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              if (canWrite && !isAdding)
                TextButton.icon(
                  key: Key('wage_authority_add_button_${bucket.wire}'),
                  onPressed: onStartAdd,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add a role'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (rows.isEmpty && !isAdding)
            Padding(
              key: Key('wage_authority_empty_${bucket.wire}'),
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                canWrite
                    ? "No wage rates set at this scope yet. Add rates and "
                        "Forge & Flow will inherit them down to lower scopes."
                    : "No roles yet for this group. An operator owner or "
                        "admin can add one so Forge & Flow knows the typical "
                        "hourly cost.",
                style: AppTextStyles.body12(color: AppColors.textMuted),
              ),
            ),
          for (var i = 0; i < rows.length; i++) ...<Widget>[
            isEditing(rows[i].wageRoleRowId)
                ? _WageRowForm(
                    key: Key('wage_authority_row_edit_${rows[i].wageRoleRowId}'),
                    initial: rows[i],
                    onCancel: () => onCancelEdit(rows[i].wageRoleRowId),
                    onSave: (form) => onSaveEdit(rows[i], form),
                    onDraftChanged: (draft) =>
                        onEditDraftChanged(rows[i].wageRoleRowId, draft),
                  )
                : _WageRowDisplay(
                    row: rows[i],
                    canWrite: canWrite,
                    connectedLaborVendorIds: connectedLaborVendorIds,
                    onEdit: () => onStartEdit(rows[i].wageRoleRowId),
                    onDelete: () => onDelete(rows[i]),
                  ),
            if (i != rows.length - 1)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Divider(height: 1, color: AppColors.borderSubtle),
              ),
          ],
          if (isAdding) ...<Widget>[
            if (rows.isNotEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Divider(height: 1, color: AppColors.borderSubtle),
              ),
            _WageRowForm(
              key: Key('wage_authority_row_add_${bucket.wire}'),
              initial: null,
              onCancel: onCancelAdd,
              onSave: onSaveAdd,
              onDraftChanged: onAddDraftChanged,
            ),
          ],
        ],
      ),
    );
  }
}

class _WageRowDisplay extends StatelessWidget {
  const _WageRowDisplay({
    required this.row,
    required this.canWrite,
    required this.connectedLaborVendorIds,
    required this.onEdit,
    required this.onDelete,
  });

  final WageRoleRowRecord row;
  final bool canWrite;
  final Set<String> connectedLaborVendorIds;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    // Wave 2 S-1 — vendor applicability label per debug.md:198-220.
    // The plain-English label tells the operator which labor vendor
    // will receive this rate on the next sync; falls back to "Manual
    // only — no labor vendor connected" when nothing is wired.
    final vendorLabel = buildWageVendorApplicabilityLabel(
      vendorId: row.vendorId,
      vendorRoleId: row.vendorRoleId,
      jobCode: row.jobCode,
      connectedLaborVendorIds: connectedLaborVendorIds,
    );
    return Row(
      key: Key('wage_authority_row_display_${row.wageRoleRowId}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                row.roleName,
                style: AppTextStyles.mono14(
                  color: AppColors.textPrimary,
                  weight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              // Operator-readable formula crumb (`@ $/hr × hours = $`),
              // mirrors the debug.md example so the operator can sanity-
              // check the math in-line.
              Text(
                '@ \$${row.hourlyRate.toStringAsFixed(2)}/hr · '
                '${row.weightedHours.toStringAsFixed(1)} weighted hrs/wk = '
                '\$${(row.hourlyRate * row.weightedHours).toStringAsFixed(2)}',
                style: AppTextStyles.body12(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 4),
              Text(
                vendorLabel.text,
                key: Key(
                  'wage_authority_row_vendor_label_${row.wageRoleRowId}',
                ),
                style: AppTextStyles.body11(
                  color: _toneColor(vendorLabel.tone),
                ),
              ),
            ],
          ),
        ),
        if (canWrite) ...<Widget>[
          const SizedBox(width: 12),
          IconButton(
            key: Key('wage_authority_row_edit_btn_${row.wageRoleRowId}'),
            icon: const Icon(Icons.edit_outlined, size: 18),
            tooltip: 'Edit',
            onPressed: onEdit,
          ),
          IconButton(
            key: Key('wage_authority_row_delete_btn_${row.wageRoleRowId}'),
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: 'Remove',
            onPressed: onDelete,
          ),
        ],
      ],
    );
  }

  static Color _toneColor(WageVendorApplicabilityTone tone) {
    switch (tone) {
      case WageVendorApplicabilityTone.perPositionSync:
        return AppColors.textSecondary;
      case WageVendorApplicabilityTone.perEmployeeAdvisory:
      case WageVendorApplicabilityTone.hoursOnlyAdvisory:
        return AppColors.textMuted;
      case WageVendorApplicabilityTone.manualOnly:
        return AppColors.textMuted;
    }
  }
}

/// In-flight numeric values for one open form, used by the live
/// blended-wage summary. `null` fields mean the operator has not yet
/// entered a valid number (e.g. empty input, mid-keystroke `.`); the
/// caller falls back to the saved row for an edit form, or skips the
/// row entirely for an add form.
class _DraftRowValues {
  const _DraftRowValues({this.hourlyRate, this.weightedHours});

  final double? hourlyRate;
  final double? weightedHours;
}

class _WageRowFormResult {
  const _WageRowFormResult({
    required this.restaurantId,
    required this.roleName,
    required this.hourlyRate,
    required this.weightedHours,
    this.jobCode,
    this.vendorId,
    this.vendorRoleId,
  });

  final String restaurantId;
  final String roleName;
  final double hourlyRate;
  final double weightedHours;
  final String? jobCode;
  final String? vendorId;
  final String? vendorRoleId;
}

class _WageRowForm extends StatefulWidget {
  const _WageRowForm({
    super.key,
    required this.initial,
    required this.onCancel,
    required this.onSave,
    this.onDraftChanged,
  });

  /// Existing row when this form is editing; null when adding a new
  /// row.
  final WageRoleRowRecord? initial;
  final VoidCallback onCancel;
  final Future<void> Function(_WageRowFormResult) onSave;

  /// Fires every keystroke on the `@/hr` and weighted-hours fields so
  /// the parent's blended-wage summary card can recompute live. The
  /// parent typically wires this to a `setState` that updates a
  /// per-row draft map. The form does not depend on the result.
  final void Function(_DraftRowValues draft)? onDraftChanged;

  @override
  State<_WageRowForm> createState() => _WageRowFormState();
}

class _WageRowFormState extends State<_WageRowForm> {
  late final TextEditingController _roleName;
  late final TextEditingController _hourlyRate;
  late final TextEditingController _weightedHours;
  late final TextEditingController _restaurantId;
  late final TextEditingController _jobCode;
  late final TextEditingController _vendorId;
  late final TextEditingController _vendorRoleId;

  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _roleName = TextEditingController(text: initial?.roleName ?? '');
    _hourlyRate = TextEditingController(
      text: initial == null ? '' : initial.hourlyRate.toStringAsFixed(2),
    );
    _weightedHours = TextEditingController(
      text: initial == null ? '' : initial.weightedHours.toStringAsFixed(1),
    );
    _restaurantId = TextEditingController(text: initial?.restaurantId ?? '');
    _jobCode = TextEditingController(text: initial?.jobCode ?? '');
    _vendorId = TextEditingController(text: initial?.vendorId ?? '');
    _vendorRoleId = TextEditingController(text: initial?.vendorRoleId ?? '');
    _hourlyRate.addListener(_emitDraft);
    _weightedHours.addListener(_emitDraft);
  }

  @override
  void dispose() {
    _hourlyRate.removeListener(_emitDraft);
    _weightedHours.removeListener(_emitDraft);
    _roleName.dispose();
    _hourlyRate.dispose();
    _weightedHours.dispose();
    _restaurantId.dispose();
    _jobCode.dispose();
    _vendorId.dispose();
    _vendorRoleId.dispose();
    super.dispose();
  }

  void _emitDraft() {
    final cb = widget.onDraftChanged;
    if (cb == null) return;
    cb(_DraftRowValues(
      hourlyRate: double.tryParse(_hourlyRate.text.trim()),
      weightedHours: double.tryParse(_weightedHours.text.trim()),
    ));
  }

  Future<void> _onSave() async {
    final roleName = _roleName.text.trim();
    final hourlyRate = double.tryParse(_hourlyRate.text.trim());
    final weightedHours = double.tryParse(_weightedHours.text.trim());
    if (roleName.isEmpty) {
      setState(() => _error = "Type a role name to continue.");
      return;
    }
    if (hourlyRate == null || hourlyRate < 0) {
      setState(() => _error = "Type an hourly rate as a number, like 18.50.");
      return;
    }
    if (weightedHours == null || weightedHours < 0) {
      setState(() => _error = "Type weighted hours as a number, like 32.");
      return;
    }
    final restaurantId = _restaurantId.text.trim();
    final jobCode = _jobCode.text.trim();
    final vendorId = _vendorId.text.trim();
    final vendorRoleId = _vendorRoleId.text.trim();
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      await widget.onSave(_WageRowFormResult(
        restaurantId: restaurantId,
        roleName: roleName,
        hourlyRate: hourlyRate,
        weightedHours: weightedHours,
        jobCode: jobCode.isEmpty ? null : jobCode,
        vendorId: vendorId.isEmpty ? null : vendorId,
        vendorRoleId: vendorRoleId.isEmpty ? null : vendorRoleId,
      ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdd = widget.initial == null;
    return Container(
      key: Key(
        isAdd
            ? 'wage_authority_form_add'
            : 'wage_authority_form_edit_${widget.initial!.wageRoleRowId}',
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                flex: 3,
                child: TextField(
                  key: Key(
                    isAdd
                        ? 'wage_authority_form_role_name_add'
                        : 'wage_authority_form_role_name_edit_${widget.initial!.wageRoleRowId}',
                  ),
                  controller: _roleName,
                  decoration: const InputDecoration(
                    labelText: 'Role name',
                    hintText: 'e.g., Server',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TextField(
                  key: Key(
                    isAdd
                        ? 'wage_authority_form_hourly_rate_add'
                        : 'wage_authority_form_hourly_rate_edit_${widget.initial!.wageRoleRowId}',
                  ),
                  controller: _hourlyRate,
                  decoration: const InputDecoration(
                    labelText: 'Hourly rate',
                    prefixText: '\$ ',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.allow(
                      RegExp(r'^\d*\.?\d{0,2}'),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TextField(
                  key: Key(
                    isAdd
                        ? 'wage_authority_form_weighted_hours_add'
                        : 'wage_authority_form_weighted_hours_edit_${widget.initial!.wageRoleRowId}',
                  ),
                  controller: _weightedHours,
                  decoration: const InputDecoration(
                    labelText: 'Weighted hours',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.allow(
                      RegExp(r'^\d*\.?\d{0,2}'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: Key(
                    isAdd
                        ? 'wage_authority_form_job_code_add'
                        : 'wage_authority_form_job_code_edit_${widget.initial!.wageRoleRowId}',
                  ),
                  controller: _jobCode,
                  decoration: const InputDecoration(
                    labelText: 'Job code (optional)',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  key: Key(
                    isAdd
                        ? 'wage_authority_form_vendor_id_add'
                        : 'wage_authority_form_vendor_id_edit_${widget.initial!.wageRoleRowId}',
                  ),
                  controller: _vendorId,
                  decoration: const InputDecoration(
                    labelText: 'Vendor id (optional)',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  key: Key(
                    isAdd
                        ? 'wage_authority_form_vendor_role_id_add'
                        : 'wage_authority_form_vendor_role_id_edit_${widget.initial!.wageRoleRowId}',
                  ),
                  controller: _vendorRoleId,
                  decoration: const InputDecoration(
                    labelText: 'Vendor role id (optional)',
                  ),
                ),
              ),
            ],
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: AppTextStyles.body12(color: AppColors.negative),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                key: Key(
                  isAdd
                      ? 'wage_authority_form_cancel_add'
                      : 'wage_authority_form_cancel_edit_${widget.initial!.wageRoleRowId}',
                ),
                onPressed: _saving ? null : widget.onCancel,
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: Key(
                  isAdd
                      ? 'wage_authority_form_save_add'
                      : 'wage_authority_form_save_edit_${widget.initial!.wageRoleRowId}',
                ),
                onPressed: _saving ? null : _onSave,
                child: Text(_saving ? 'Saving...' : 'Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
