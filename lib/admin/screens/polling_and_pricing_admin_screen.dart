// Phase 8 spine-bridge Lane .C — F&F Ops Console "Polling & Pricing" tab.
//
// Tab 2 of the per-location data accuracy admin surface. F&F-internal:
// operators NEVER see this surface. Carries the F&F-controlled tier
// model (REVERSED 2026-05-05) where F&F absorbs vendor API costs and
// packages them into operator-facing tier prices.
//
// Authority: docs/contracts/data_accuracy_settings_contract.md
// "Tab 2: Polling & Pricing (F&F-controlled, well-labeled)" section,
// including the verbatim plain-English explainer card text.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models/forge_flow_polling_tier_assignment.dart';
import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../services/data_accuracy_admin_gateway.dart';
import '../widgets/admin_responsive_layout.dart';
import '../widgets/data_accuracy_audit_history_panel.dart';
import '../widgets/margin_rollup_card.dart';
import '../widgets/per_location_tier_assignment_table.dart';
import '../widgets/per_vendor_cadence_editor.dart';
import '../widgets/plain_english_explainer_card.dart';
import '../widgets/tier_change_requests_card.dart';
import '../widgets/tier_definition_edit_dialog.dart';
import '../widgets/tier_definitions_card.dart';

class PollingAndPricingAdminScreen extends StatefulWidget {
  const PollingAndPricingAdminScreen({
    super.key,
    required this.gateway,
    required this.actorUserId,
    this.editingEnabled = true,
  });

  final DataAccuracyAdminGateway gateway;
  final String actorUserId;
  final bool editingEnabled;

  @override
  State<PollingAndPricingAdminScreen> createState() =>
      _PollingAndPricingAdminScreenState();
}

class _PollingAndPricingAdminScreenState
    extends State<PollingAndPricingAdminScreen> {
  bool _loading = true;
  String? _loadError;
  String? _actionError;
  List<TierDefinition> _definitions = const <TierDefinition>[];
  List<TierAssignmentAdminRow> _assignments =
      const <TierAssignmentAdminRow>[];
  TierMarginRollup _rollup = const TierMarginRollup(
    totalMonthlyPriceCents: 0,
    totalMonthlyVendorCostCents: 0,
    perTier: <TierMarginPerTier>[],
    perVendor: <TierMarginPerVendor>[],
  );
  List<TierChangeRequest> _changeRequests = const <TierChangeRequest>[];
  List<DataAccuracyAdminAuditEvent> _tierAuditEvents =
      const <DataAccuracyAdminAuditEvent>[];

  PollingTierKey? _tierFilter;
  String? _marginBandFilter;
  String? _locationCountFilter;
  String _operatorNameFilter = '';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final defs = await widget.gateway.listTierDefinitions();
      final assignments = await widget.gateway.listTierAssignments();
      final rollup = await widget.gateway.summarizeMargin();
      final changes = await widget.gateway.listTierChangeRequests();
      // Tab 2 Card 5 (audit history) surfaces only the polling-tier
      // events: tier definition edits, tier assignments, change
      // request resolutions, and CSV exports. Data-accuracy override
      // events stay on Tab 1.
      final allEvents = await widget.gateway.listAuditHistory();
      final tierEvents = allEvents
          .where(
            (e) =>
                e.eventType.startsWith('admin.polling_') ||
                e.eventType.startsWith('admin.margin_rollup.'),
          )
          .toList(growable: false);
      if (!mounted) return;
      setState(() {
        _definitions = defs;
        _assignments = assignments;
        _rollup = rollup;
        _changeRequests = changes;
        _tierAuditEvents = tierEvents;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load polling & pricing data: $error';
        _loading = false;
      });
    }
  }

  List<TierAssignmentAdminRow> get _filteredAssignments {
    final perOperatorLocationCount = <String, int>{};
    for (final row in _assignments) {
      perOperatorLocationCount.update(
        row.operatorRef.operatorId,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    return _assignments.where((row) {
      // The tier filter applies only to rows with an assignment.
      // Unassigned rows (assignment == null) are filtered out when
      // a specific tier is selected; they pass when "All tiers" is
      // selected.
      if (_tierFilter != null) {
        if (row.assignment == null) return false;
        if (row.assignment!.tierKey != _tierFilter) return false;
      }
      final band = _marginBandFilter;
      if (band != null) {
        // Margin band only meaningful for assigned rows; unassigned
        // rows are filtered out when a band is selected.
        if (row.assignment == null) return false;
        final margin = row.assignment!.netMarginCents ?? 0;
        if (band == 'positive' && margin <= 0) return false;
        if (band == 'break_even' && margin != 0) return false;
        if (band == 'negative' && margin >= 0) return false;
      }
      final loc = _locationCountFilter;
      if (loc != null) {
        final count =
            perOperatorLocationCount[row.operatorRef.operatorId] ?? 0;
        if (loc == 'single' && count != 1) return false;
        if (loc == 'multi' && count < 2) return false;
      }
      final query = _operatorNameFilter.trim().toLowerCase();
      if (query.isNotEmpty &&
          !row.operatorRef.businessName.toLowerCase().contains(query) &&
          !row.operatorRef.locationName.toLowerCase().contains(query)) {
        return false;
      }
      return true;
    }).toList(growable: false);
  }

  Future<void> _onEditDefinition(TierDefinition definition) async {
    if (!widget.editingEnabled) return;
    final result = await TierDefinitionEditDialog.show(context, definition);
    if (result == null) return;
    setState(() => _actionError = null);
    try {
      await widget.gateway.updateTierDefinition(
        tierKey: definition.tierKey,
        descriptionMd: result.descriptionMd,
        pollingCadencePerVendorSeconds: result.pollingCadencePerVendorSeconds,
        defaultMonthlyPriceCents: result.defaultMonthlyPriceCents,
        vendorApiCostEstimateCentsMonthly:
            result.vendorApiCostEstimateCentsMonthly,
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        reasonNote: result.reasonNote,
      );
      await _refresh();
    } on DataAccuracyAdminForbiddenException catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = 'Tier definition update failed: $error');
    }
  }

  Future<void> _onAssignTier(TierAssignmentAdminRow row) async {
    if (!widget.editingEnabled) return;
    final result = await showDialog<_TierAssignmentDraft>(
      context: context,
      builder: (_) => _TierAssignmentDialog(row: row, definitions: _definitions),
    );
    if (result == null) return;
    setState(() => _actionError = null);
    try {
      await widget.gateway.assignTier(
        operatorId: row.operatorRef.operatorId,
        locationId: row.operatorRef.locationId,
        tierKey: result.tierKey,
        customCadencePerVendorSeconds: result.customCadence,
        monthlyPriceCentsOverride: result.monthlyPriceCentsOverride,
        vendorApiCostEstimateCentsMonthlyOverride:
            result.vendorApiCostEstimateCentsMonthlyOverride,
        adminNotes: result.adminNotes,
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        reasonNote: result.reasonNote,
      );
      await _refresh();
    } on DataAccuracyAdminForbiddenException catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = 'Tier assignment failed: $error');
    }
  }

  Future<void> _onResolveChangeRequest(
    TierChangeRequest request,
    TierChangeRequestStatus newStatus,
  ) async {
    if (!widget.editingEnabled) return;
    setState(() => _actionError = null);
    try {
      await widget.gateway.resolveTierChangeRequest(
        requestId: request.requestId,
        newStatus: newStatus,
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        reasonNote: 'forge_admin resolved tier change request',
      );
      await _refresh();
    } on DataAccuracyAdminForbiddenException catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = 'Tier change resolution failed: $error');
    }
  }

  Future<void> _onExportCsv() async {
    if (!widget.editingEnabled) return;
    try {
      final csv = await widget.gateway.exportMarginRollupCsv(
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
      );
      if (!mounted) return;
      await Clipboard.setData(ClipboardData(text: csv));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Margin rollup CSV copied to clipboard.')),
      );
    } on DataAccuracyAdminForbiddenException catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = 'CSV export failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_polling_pricing_screen'),
      color: AppColors.backgroundDeep,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const AdminPageHeader(
              title: 'Polling & pricing',
              subtitle:
                  'F&F-controlled tier definitions, per-location assignments, '
                  'margin rollup, and operator change requests.',
            ),
            const SizedBox(height: 14),
            if (!widget.editingEnabled)
              const _ReadOnlyBanner(
                key: Key('admin_polling_pricing_readonly_banner'),
              ),
            if (_actionError != null)
              _ErrorBanner(
                key: const Key('admin_polling_pricing_action_error'),
                message: _actionError!,
              ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        key: Key('admin_polling_pricing_loading'),
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
    if (_loadError != null) {
      return _ErrorBanner(
        key: const Key('admin_polling_pricing_load_error'),
        message: _loadError!,
      );
    }
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const PlainEnglishExplainerCard(),
          const SizedBox(height: 16),
          TierDefinitionsCard(
            definitions: _definitions,
            editingEnabled: widget.editingEnabled,
            onEdit: _onEditDefinition,
          ),
          const SizedBox(height: 16),
          PerLocationTierAssignmentTable(
            rows: _filteredAssignments,
            tierDefinitions: _definitions,
            editingEnabled: widget.editingEnabled,
            onAssign: _onAssignTier,
            tierFilter: _tierFilter,
            marginBandFilter: _marginBandFilter,
            locationCountFilter: _locationCountFilter,
            operatorNameFilter: _operatorNameFilter,
            onTierFilterChanged: (v) => setState(() => _tierFilter = v),
            onMarginBandFilterChanged: (v) =>
                setState(() => _marginBandFilter = v),
            onLocationCountFilterChanged: (v) =>
                setState(() => _locationCountFilter = v),
            onOperatorNameFilterChanged: (v) =>
                setState(() => _operatorNameFilter = v),
          ),
          const SizedBox(height: 16),
          MarginRollupCard(
            rollup: _rollup,
            canExportCsv: widget.editingEnabled,
            onExportCsv: _onExportCsv,
          ),
          const SizedBox(height: 16),
          TierChangeRequestsCard(
            requests: _changeRequests,
            editingEnabled: widget.editingEnabled,
            onResolve: _onResolveChangeRequest,
          ),
          const SizedBox(height: 16),
          // Card 5 (Audit history) per contract — every tier
          // definition edit, tier assignment, change-request
          // resolution, and CSV export the F&F admin runs lands here
          // with prior → new diff display + actor + timestamp + reason
          // note. Filtered to polling-tier event types so Tab 1 data-
          // accuracy overrides do not leak in.
          DataAccuracyAuditHistoryPanel(
            key: const Key('admin_polling_pricing_audit_panel'),
            events: _tierAuditEvents,
            title: 'Audit history',
            emptyText: 'No tier changes recorded yet.',
          ),
        ],
      ),
    );
  }
}

class _TierAssignmentDraft {
  const _TierAssignmentDraft({
    required this.tierKey,
    required this.customCadence,
    required this.monthlyPriceCentsOverride,
    required this.vendorApiCostEstimateCentsMonthlyOverride,
    required this.adminNotes,
    required this.reasonNote,
  });

  final PollingTierKey tierKey;
  final Map<String, int>? customCadence;
  final int? monthlyPriceCentsOverride;
  final int? vendorApiCostEstimateCentsMonthlyOverride;
  final String? adminNotes;
  final String reasonNote;
}

class _TierAssignmentDialog extends StatefulWidget {
  const _TierAssignmentDialog({required this.row, required this.definitions});

  final TierAssignmentAdminRow row;
  final List<TierDefinition> definitions;

  @override
  State<_TierAssignmentDialog> createState() => _TierAssignmentDialogState();
}

class _TierAssignmentDialogState extends State<_TierAssignmentDialog> {
  // Default tier for never-assigned rows is `standard` (the contract's
  // "Default for new operators" tier). For rows with a prior
  // assignment we pre-populate every field from it.
  late PollingTierKey _tierKey =
      widget.row.assignment?.tierKey ?? PollingTierKey.standard;
  late Map<String, int> _customCadence = Map<String, int>.from(
    widget.row.assignment?.pollingCadencePerVendorSeconds ??
        const <String, int>{},
  );
  late final TextEditingController _price = TextEditingController(
    text: widget.row.assignment?.monthlyPriceCents == null
        ? ''
        : (widget.row.assignment!.monthlyPriceCents! / 100).toStringAsFixed(2),
  );
  late final TextEditingController _cost = TextEditingController(
    text: widget.row.assignment?.vendorApiCostEstimateCentsMonthly == null
        ? ''
        : (widget.row.assignment!.vendorApiCostEstimateCentsMonthly! / 100)
            .toStringAsFixed(2),
  );
  late final TextEditingController _notes = TextEditingController(
    text: widget.row.adminNotes ?? '',
  );
  final TextEditingController _reason = TextEditingController();

  @override
  void dispose() {
    _price.dispose();
    _cost.dispose();
    _notes.dispose();
    _reason.dispose();
    super.dispose();
  }

  int? _parseCents(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final dollars = double.tryParse(trimmed);
    if (dollars == null) return null;
    return (dollars * 100).round();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_tier_assignment_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Assign tier — ${widget.row.operatorRef.businessName} '
        '/ ${widget.row.operatorRef.locationName}',
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              DropdownButtonFormField<PollingTierKey>(
                key: const Key('admin_tier_assignment_dialog_tier'),
                initialValue: _tierKey,
                decoration: const InputDecoration(
                  labelText: 'Tier',
                  border: OutlineInputBorder(),
                ),
                items: PollingTierKey.values
                    .map(
                      (t) => DropdownMenuItem<PollingTierKey>(
                        value: t,
                        child: Text(t.wire),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (v) {
                  if (v != null) setState(() => _tierKey = v);
                },
              ),
              const SizedBox(height: 12),
              if (_tierKey == PollingTierKey.custom)
                PerVendorCadenceEditor(
                  initialCadence: _customCadence,
                  onChanged: (next) =>
                      setState(() => _customCadence = next),
                ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin_tier_assignment_dialog_price'),
                controller: _price,
                decoration: const InputDecoration(
                  labelText: 'Price override (USD/month)',
                  hintText: 'Leave blank to use tier default',
                  border: OutlineInputBorder(),
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin_tier_assignment_dialog_cost'),
                controller: _cost,
                decoration: const InputDecoration(
                  labelText: 'Cost basis override (USD/month)',
                  hintText: 'Leave blank to use tier default',
                  border: OutlineInputBorder(),
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin_tier_assignment_dialog_notes'),
                controller: _notes,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Admin notes',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin_tier_assignment_dialog_reason'),
                controller: _reason,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Reason for assignment',
                  hintText: 'Required for the audit log',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_tier_assignment_dialog_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_tier_assignment_dialog_submit'),
          style: AdminButtonStyles.primary,
          onPressed: () {
            final reason = _reason.text.trim();
            if (reason.isEmpty) return;
            Navigator.of(context).pop(
              _TierAssignmentDraft(
                tierKey: _tierKey,
                customCadence: _tierKey == PollingTierKey.custom
                    ? Map<String, int>.from(_customCadence)
                    : null,
                monthlyPriceCentsOverride: _parseCents(_price.text),
                vendorApiCostEstimateCentsMonthlyOverride:
                    _parseCents(_cost.text),
                adminNotes: _notes.text.trim().isEmpty
                    ? null
                    : _notes.text.trim(),
                reasonNote: reason,
              ),
            );
          },
          child: const Text('Assign / update'),
        ),
      ],
    );
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.lock_outline, size: 16, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'View only: tier definitions and assignments require ecosystem admin access.',
              style: AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.negative, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        message,
        style: AppTextStyles.mono11(color: AppColors.negative),
      ),
    );
  }
}
