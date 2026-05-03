// Phase 11A.1 — Operator + location admin screen.
//
// Admin-side CRUD on operators (`operators` table) and their
// locations (`locations` table). Supports onboarding a new operator
// (creates the row, primary location, subscription tier, currency,
// and admin assignment), editing existing operators, suspending +
// reactivating, and add/edit/remove locations with IANA timezone +
// business-day rollover hour validation.
//
// The screen takes an [OperatorLocationAdminGateway] from the
// outside; production passes the HTTP gateway, demo + widget tests
// pass the in-memory gateway. Brand styling reuses
// `lib/theme/app_theme.dart` verbatim per the 11A non-negotiable.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../models/operator_location_admin_models.dart';
import '../services/operator_location_admin_gateway.dart';
import '../widgets/admin_responsive_layout.dart';
// Phase 8.0 — vendor connections mount (per-location admin sub-route).
// Append-only addition; the existing Edit / Remove / Make-primary
// affordances stay untouched.
import 'vendor_connections/vendor_connections_admin_mount.dart';

class OperatorLocationAdminScreen extends StatefulWidget {
  const OperatorLocationAdminScreen({
    super.key,
    required this.gateway,
    this.idempotencyKeyFactory,
  });

  final OperatorLocationAdminGateway gateway;

  /// Factory for the idempotency key the gateway attaches to each
  /// mutating call. Production binds this to a UUID-shaped generator;
  /// widget tests inject a deterministic counter so retries can be
  /// asserted.
  final String Function()? idempotencyKeyFactory;

  @override
  State<OperatorLocationAdminScreen> createState() =>
      _OperatorLocationAdminScreenState();
}

class _OperatorLocationAdminScreenState
    extends State<OperatorLocationAdminScreen> {
  bool _loading = true;
  String? _loadError;
  List<OperatorAdminBundle> _bundles = const <OperatorAdminBundle>[];
  String? _selectedOperatorId;
  String? _actionError;
  int _idempotencyCounter = 0;

  /// Mints a fresh idempotency key per user action so a retried POST
  /// or PATCH at the proxy collapses to one ledger row + one audit
  /// row in `admin_request_idempotency`. A new key is minted each
  /// time the user triggers a mutation; it is NEVER reused across
  /// re-renders or repeated screen builds.
  String _nextIdempotencyKey() {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencyCounter += 1;
    return 'operator-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '$_idempotencyCounter';
  }

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
      final bundles = await widget.gateway.listOperators();
      if (!mounted) return;
      setState(() {
        _bundles = bundles;
        _loading = false;
        if (_selectedOperatorId != null &&
            bundles.every(
              (b) => b.operator.operatorId != _selectedOperatorId,
            )) {
          _selectedOperatorId = null;
        }
        _selectedOperatorId ??= bundles.isEmpty
            ? null
            : bundles.first.operator.operatorId;
      });
    } on OperatorLocationAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load operators: $error';
        _loading = false;
      });
    }
  }

  OperatorAdminBundle? get _selected {
    final id = _selectedOperatorId;
    if (id == null) return null;
    for (final b in _bundles) {
      if (b.operator.operatorId == id) return b;
    }
    return null;
  }

  Future<void> _runAndRefresh(
    Future<void> Function() action, {
    String? successHint,
  }) async {
    setState(() => _actionError = null);
    try {
      await action();
      await _refresh();
      if (successHint != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successHint)));
      }
    } on OperatorLocationAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_operators_screen'),
      color: AppColors.backgroundDeep,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AdminPageHeader(
              title: 'Customers',
              subtitle:
                  'Create customer accounts, manage locations, and pause or restore access when needed.',
              trailing: FilledButton.icon(
                key: const Key('admin_operators_new_button'),
                onPressed: _openOnboardingDialog,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.sunset,
                  foregroundColor: AppColors.backgroundSurface,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New customer'),
              ),
            ),
            const SizedBox(height: 14),
            if (_actionError != null)
              _ErrorBanner(
                key: const Key('admin_operators_action_error'),
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
        key: Key('admin_operators_loading'),
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
        key: const Key('admin_operators_load_error'),
        message: _loadError!,
      );
    }
    if (_bundles.isEmpty) {
      return Center(
        key: const Key('admin_operators_empty'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No customers yet',
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 8),
                Text(
                  'Select "New customer" to create the first account, primary location, and admin assignment.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return AdminMasterDetailLayout(
      master: _OperatorList(
        bundles: _bundles,
        selectedOperatorId: _selectedOperatorId,
        onSelect: (id) => setState(() => _selectedOperatorId = id),
      ),
      detail: _selected == null
          ? const SizedBox.shrink()
          : _OperatorDetail(
              bundle: _selected!,
              onEditOperator: _openEditOperatorDialog,
              onSuspend: _suspend,
              onReactivate: _reactivate,
              onAddLocation: _openAddLocationDialog,
              onEditLocation: _openEditLocationDialog,
              onRemoveLocation: _removeLocation,
              onSetPrimary: _setPrimaryLocation,
            ),
    );
  }

  Future<void> _openOnboardingDialog() async {
    final command = await showDialog<OperatorOnboardCommand>(
      context: context,
      builder: (_) =>
          _OnboardOperatorDialog(idempotencyKey: _nextIdempotencyKey()),
    );
    if (command == null) return;
    await _runAndRefresh(() async {
      await widget.gateway.onboardOperator(command);
    }, successHint: 'Operator onboarded.');
  }

  Future<void> _openEditOperatorDialog(OperatorAdminBundle bundle) async {
    final patch = await showDialog<OperatorPatchCommand>(
      context: context,
      builder: (_) => _EditOperatorDialog(
        bundle: bundle,
        idempotencyKey: _nextIdempotencyKey(),
      ),
    );
    if (patch == null) return;
    await _runAndRefresh(() async {
      await widget.gateway.patchOperator(patch);
    }, successHint: 'Operator updated.');
  }

  Future<void> _suspend(OperatorAdminBundle bundle) async {
    final key = _nextIdempotencyKey();
    await _runAndRefresh(() async {
      await widget.gateway.suspendOperator(
        bundle.operator.operatorId,
        idempotencyKey: key,
      );
    }, successHint: 'Operator suspended.');
  }

  Future<void> _reactivate(OperatorAdminBundle bundle) async {
    final key = _nextIdempotencyKey();
    await _runAndRefresh(() async {
      await widget.gateway.reactivateOperator(
        bundle.operator.operatorId,
        idempotencyKey: key,
      );
    }, successHint: 'Operator reactivated.');
  }

  Future<void> _openAddLocationDialog(OperatorAdminBundle bundle) async {
    final command = await showDialog<LocationCreateCommand>(
      context: context,
      builder: (_) => _LocationDialog(
        operatorId: bundle.operator.operatorId,
        idempotencyKey: _nextIdempotencyKey(),
      ),
    );
    if (command == null) return;
    await _runAndRefresh(() async {
      await widget.gateway.addLocation(command);
    }, successHint: 'Location added.');
  }

  Future<void> _openEditLocationDialog(LocationAdminRecord location) async {
    final command = await showDialog<LocationPatchCommand>(
      context: context,
      builder: (_) => _LocationDialog(
        operatorId: location.operatorId,
        existing: location,
        idempotencyKey: _nextIdempotencyKey(),
      ),
    );
    if (command == null) return;
    await _runAndRefresh(() async {
      await widget.gateway.patchLocation(command);
    }, successHint: 'Location updated.');
  }

  Future<void> _removeLocation(LocationAdminRecord location) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(
        title: 'Remove ${location.name}?',
        message:
            'This cannot be undone. The location must not be the '
            "operator's primary location.",
        confirmLabel: 'Remove',
      ),
    );
    if (confirmed != true) return;
    final key = _nextIdempotencyKey();
    await _runAndRefresh(() async {
      await widget.gateway.removeLocation(
        operatorId: location.operatorId,
        locationId: location.locationId,
        idempotencyKey: key,
      );
    }, successHint: 'Location removed.');
  }

  Future<void> _setPrimaryLocation(
    OperatorAdminBundle bundle,
    LocationAdminRecord location,
  ) async {
    final key = _nextIdempotencyKey();
    await _runAndRefresh(() async {
      await widget.gateway.patchOperator(
        OperatorPatchCommand(
          operatorId: bundle.operator.operatorId,
          primaryLocationId: location.locationId,
          idempotencyKey: key,
        ),
      );
    }, successHint: 'Primary location updated.');
  }
}

class _OperatorList extends StatelessWidget {
  const _OperatorList({
    required this.bundles,
    required this.selectedOperatorId,
    required this.onSelect,
  });

  final List<OperatorAdminBundle> bundles;
  final String? selectedOperatorId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_operators_list'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: bundles.length,
        separatorBuilder: (_, __) => Container(
          height: 1,
          color: AppColors.borderSubtle.withValues(alpha: 0.4),
        ),
        itemBuilder: (context, index) {
          final bundle = bundles[index];
          final selected = bundle.operator.operatorId == selectedOperatorId;
          return Material(
            color: selected
                ? AppColors.sunset.withValues(alpha: 0.10)
                : Colors.transparent,
            child: InkWell(
              key: Key('admin_operator_row_${bundle.operator.operatorId}'),
              onTap: () => onSelect(bundle.operator.operatorId),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            bundle.operator.businessName,
                            style: AppTextStyles.mono14(
                              color: AppColors.textPrimary,
                              weight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (bundle.operator.isSuspended)
                          _StatusPill(
                            label: 'suspended',
                            color: AppColors.negative,
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      bundle.operator.ownerEmail,
                      style: AppTextStyles.mono11(
                        color: AppColors.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${bundle.operator.subscriptionTier} '
                      '- ${bundle.locations.length} location'
                      '${bundle.locations.length == 1 ? '' : 's'}',
                      style: AppTextStyles.mono8(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _OperatorDetail extends StatelessWidget {
  const _OperatorDetail({
    required this.bundle,
    required this.onEditOperator,
    required this.onSuspend,
    required this.onReactivate,
    required this.onAddLocation,
    required this.onEditLocation,
    required this.onRemoveLocation,
    required this.onSetPrimary,
  });

  final OperatorAdminBundle bundle;
  final ValueChanged<OperatorAdminBundle> onEditOperator;
  final ValueChanged<OperatorAdminBundle> onSuspend;
  final ValueChanged<OperatorAdminBundle> onReactivate;
  final ValueChanged<OperatorAdminBundle> onAddLocation;
  final ValueChanged<LocationAdminRecord> onEditLocation;
  final ValueChanged<LocationAdminRecord> onRemoveLocation;
  final void Function(OperatorAdminBundle, LocationAdminRecord) onSetPrimary;

  @override
  Widget build(BuildContext context) {
    final operator = bundle.operator;
    return SingleChildScrollView(
      key: Key('admin_operator_detail_${operator.operatorId}'),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AdminCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        operator.businessName,
                        style: AppTextStyles.display20(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    if (operator.isSuspended)
                      _StatusPill(
                        label: 'suspended',
                        color: AppColors.negative,
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                AdminDetailRow(
                  label: 'Owner email',
                  value: operator.ownerEmail,
                ),
                AdminDetailRow(label: 'Plan', value: operator.subscriptionTier),
                AdminDetailRow(
                  label: 'Currency',
                  value: operator.preferredCurrency,
                ),
                AdminDetailRow(
                  label: 'Main location',
                  value: bundle.primaryLocation?.name ?? 'No main location',
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const Key('admin_operator_edit_button'),
                      onPressed: () => onEditOperator(bundle),
                      icon: const Icon(Icons.edit_outlined, size: 14),
                      label: const Text('Edit customer'),
                    ),
                    if (operator.isSuspended)
                      OutlinedButton.icon(
                        key: const Key('admin_operator_reactivate_button'),
                        onPressed: () => onReactivate(bundle),
                        icon: const Icon(Icons.play_arrow_outlined, size: 14),
                        label: const Text('Reactivate'),
                      )
                    else
                      OutlinedButton.icon(
                        key: const Key('admin_operator_suspend_button'),
                        onPressed: () => onSuspend(bundle),
                        icon: const Icon(Icons.pause_outlined, size: 14),
                        label: const Text('Suspend'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.negative,
                          side: const BorderSide(
                            color: AppColors.negative,
                            width: 1,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AdminCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Text(
                      'Restaurant locations',
                      style: AppTextStyles.mono15(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w700,
                      ),
                    ),
                    OutlinedButton.icon(
                      key: const Key('admin_operator_add_location_button'),
                      onPressed: () => onAddLocation(bundle),
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text('Add location'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ...bundle.locations.map(
                  (location) => _LocationRow(
                    key: Key('admin_location_row_${location.locationId}'),
                    location: location,
                    isPrimary:
                        bundle.operator.primaryLocationId ==
                        location.locationId,
                    onEdit: () => onEditLocation(location),
                    onRemove: () => onRemoveLocation(location),
                    onMakePrimary: () => onSetPrimary(bundle, location),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LocationRow extends StatelessWidget {
  const _LocationRow({
    super.key,
    required this.location,
    required this.isPrimary,
    required this.onEdit,
    required this.onRemove,
    required this.onMakePrimary,
  });

  final LocationAdminRecord location;
  final bool isPrimary;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final VoidCallback onMakePrimary;

  @override
  Widget build(BuildContext context) {
    final rolloverHour = location.businessDayRolloverHour ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text(
                      location.name,
                      style: AppTextStyles.mono14(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (isPrimary)
                      _StatusPill(label: 'main', color: AppColors.peacock),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${location.timezone} - business day starts ${rolloverHour.toString().padLeft(2, '0')}:00',
                  style: AppTextStyles.mono11(color: AppColors.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (!isPrimary)
            IconButton(
              key: Key('admin_location_make_primary_${location.locationId}'),
              tooltip: 'Make main location',
              onPressed: onMakePrimary,
              icon: const Icon(Icons.star_outline, size: 16),
            ),
          IconButton(
            key: Key('admin_location_edit_${location.locationId}'),
            tooltip: 'Edit location',
            onPressed: onEdit,
            icon: const Icon(Icons.edit_outlined, size: 16),
          ),
          // Phase 8.0 — vendor connections sub-route for this
          // (operator_id, location_id). Append-only; the existing
          // Make-primary / Edit / Remove buttons stay untouched.
          Builder(
            builder: (subContext) => IconButton(
              key: Key(
                'admin_location_vendor_connections_${location.locationId}',
              ),
              tooltip: 'Vendor connections',
              onPressed: () {
                Navigator.of(subContext).push(
                  MaterialPageRoute<void>(
                    settings: const RouteSettings(name: '/vendor-connections'),
                    builder: (_) => VendorConnectionsAdminMount(
                      operatorId: location.operatorId,
                      locationId: location.locationId,
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.link, size: 16),
            ),
          ),
          IconButton(
            key: Key('admin_location_remove_${location.locationId}'),
            tooltip: 'Remove location',
            onPressed: isPrimary ? null : onRemove,
            icon: const Icon(Icons.delete_outline, size: 16),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: AppTextStyles.mono8(color: color)),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.negative.withValues(alpha: 0.45),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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

class _OnboardOperatorDialog extends StatefulWidget {
  const _OnboardOperatorDialog({required this.idempotencyKey});

  /// Per-action idempotency key minted by the screen and threaded
  /// down so the proxy dedups on retries — see `_nextIdempotencyKey`
  /// in `_OperatorLocationAdminScreenState`.
  final String idempotencyKey;

  @override
  State<_OnboardOperatorDialog> createState() => _OnboardOperatorDialogState();
}

class _OnboardOperatorDialogState extends State<_OnboardOperatorDialog> {
  final _formKey = GlobalKey<FormState>();
  final _businessName = TextEditingController();
  final _ownerEmail = TextEditingController();
  final _adminEmail = TextEditingController();
  final _locationName = TextEditingController();
  final _locationTimezone = TextEditingController(text: 'America/Toronto');
  String _subscriptionTier = 'launch';
  String _preferredCurrency = 'CAD';
  int _rolloverHour = 4;

  @override
  void dispose() {
    _businessName.dispose();
    _ownerEmail.dispose();
    _adminEmail.dispose();
    _locationName.dispose();
    _locationTimezone.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      OperatorOnboardCommand(
        businessName: _businessName.text.trim(),
        ownerEmail: _ownerEmail.text.trim(),
        subscriptionTier: _subscriptionTier,
        preferredCurrency: _preferredCurrency,
        primaryLocationName: _locationName.text.trim(),
        primaryLocationTimezone: _locationTimezone.text.trim(),
        primaryLocationRolloverHour: _rolloverHour,
        adminUserEmail: _adminEmail.text.trim(),
        idempotencyKey: widget.idempotencyKey,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_onboard_operator_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'New operator',
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DialogField(
                  fieldKey: const Key('admin_onboard_business_name'),
                  controller: _businessName,
                  label: 'Business name',
                  validator: _requiredValidator,
                ),
                const SizedBox(height: 12),
                _DialogField(
                  fieldKey: const Key('admin_onboard_owner_email'),
                  controller: _ownerEmail,
                  label: 'Owner email',
                  keyboardType: TextInputType.emailAddress,
                  validator: _requiredValidator,
                ),
                const SizedBox(height: 12),
                _DialogField(
                  fieldKey: const Key('admin_onboard_admin_email'),
                  controller: _adminEmail,
                  label: 'Admin user email',
                  keyboardType: TextInputType.emailAddress,
                  validator: _requiredValidator,
                ),
                const SizedBox(height: 12),
                _SubscriptionTierDropdown(
                  value: _subscriptionTier,
                  onChanged: (v) => setState(() => _subscriptionTier = v),
                ),
                const SizedBox(height: 12),
                _CurrencyDropdown(
                  value: _preferredCurrency,
                  onChanged: (v) => setState(() => _preferredCurrency = v),
                ),
                const SizedBox(height: 16),
                Text(
                  'Primary location',
                  style: AppTextStyles.mono11(color: AppColors.textMuted),
                ),
                const SizedBox(height: 6),
                _DialogField(
                  fieldKey: const Key('admin_onboard_location_name'),
                  controller: _locationName,
                  label: 'Location name',
                  validator: _requiredValidator,
                ),
                const SizedBox(height: 12),
                _DialogField(
                  fieldKey: const Key('admin_onboard_location_timezone'),
                  controller: _locationTimezone,
                  label: 'IANA timezone (e.g. America/Toronto)',
                  validator: _timezoneValidator,
                ),
                const SizedBox(height: 12),
                _RolloverHourDropdown(
                  value: _rolloverHour,
                  onChanged: (v) => setState(() => _rolloverHour = v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('admin_onboard_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_onboard_submit_button'),
          onPressed: _submit,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.sunset,
            foregroundColor: AppColors.backgroundSurface,
          ),
          child: const Text('Onboard operator'),
        ),
      ],
    );
  }
}

class _EditOperatorDialog extends StatefulWidget {
  const _EditOperatorDialog({
    required this.bundle,
    required this.idempotencyKey,
  });

  final OperatorAdminBundle bundle;

  /// Per-action idempotency key minted by the screen.
  final String idempotencyKey;

  @override
  State<_EditOperatorDialog> createState() => _EditOperatorDialogState();
}

class _EditOperatorDialogState extends State<_EditOperatorDialog> {
  late final TextEditingController _businessName;
  late final TextEditingController _ownerEmail;
  late String _subscriptionTier;
  late String _preferredCurrency;
  late String? _primaryLocationId;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _businessName = TextEditingController(
      text: widget.bundle.operator.businessName,
    );
    _ownerEmail = TextEditingController(
      text: widget.bundle.operator.ownerEmail,
    );
    _subscriptionTier = widget.bundle.operator.subscriptionTier;
    _preferredCurrency = widget.bundle.operator.preferredCurrency;
    _primaryLocationId = widget.bundle.operator.primaryLocationId;
  }

  @override
  void dispose() {
    _businessName.dispose();
    _ownerEmail.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      OperatorPatchCommand(
        operatorId: widget.bundle.operator.operatorId,
        businessName: _businessName.text.trim(),
        ownerEmail: _ownerEmail.text.trim(),
        subscriptionTier: _subscriptionTier,
        preferredCurrency: _preferredCurrency,
        primaryLocationId: _primaryLocationId,
        idempotencyKey: widget.idempotencyKey,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_edit_operator_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Edit operator',
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DialogField(
                  fieldKey: const Key('admin_edit_business_name'),
                  controller: _businessName,
                  label: 'Business name',
                  validator: _requiredValidator,
                ),
                const SizedBox(height: 12),
                _DialogField(
                  fieldKey: const Key('admin_edit_owner_email'),
                  controller: _ownerEmail,
                  label: 'Owner email',
                  keyboardType: TextInputType.emailAddress,
                  validator: _requiredValidator,
                ),
                const SizedBox(height: 12),
                _SubscriptionTierDropdown(
                  value: _subscriptionTier,
                  onChanged: (v) => setState(() => _subscriptionTier = v),
                ),
                const SizedBox(height: 12),
                _CurrencyDropdown(
                  value: _preferredCurrency,
                  onChanged: (v) => setState(() => _preferredCurrency = v),
                ),
                const SizedBox(height: 12),
                _PrimaryLocationDropdown(
                  locations: widget.bundle.locations,
                  value: _primaryLocationId,
                  onChanged: (v) => setState(() => _primaryLocationId = v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('admin_edit_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_edit_submit_button'),
          onPressed: _submit,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.sunset,
            foregroundColor: AppColors.backgroundSurface,
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _LocationDialog extends StatefulWidget {
  const _LocationDialog({
    required this.operatorId,
    required this.idempotencyKey,
    this.existing,
  });

  final String operatorId;
  final LocationAdminRecord? existing;

  /// Per-action idempotency key minted by the screen.
  final String idempotencyKey;

  @override
  State<_LocationDialog> createState() => _LocationDialogState();
}

class _LocationDialogState extends State<_LocationDialog> {
  late final TextEditingController _name;
  late final TextEditingController _timezone;
  late int _rolloverHour;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _timezone = TextEditingController(
      text: widget.existing?.timezone ?? 'America/Toronto',
    );
    _rolloverHour = widget.existing?.businessDayRolloverHour ?? 4;
  }

  @override
  void dispose() {
    _name.dispose();
    _timezone.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    if (widget.existing == null) {
      Navigator.of(context).pop(
        LocationCreateCommand(
          operatorId: widget.operatorId,
          name: _name.text.trim(),
          timezone: _timezone.text.trim(),
          businessDayRolloverHour: _rolloverHour,
          idempotencyKey: widget.idempotencyKey,
        ),
      );
    } else {
      Navigator.of(context).pop(
        LocationPatchCommand(
          locationId: widget.existing!.locationId,
          name: _name.text.trim(),
          timezone: _timezone.text.trim(),
          businessDayRolloverHour: _rolloverHour,
          idempotencyKey: widget.idempotencyKey,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return AlertDialog(
      key: Key(
        isEdit ? 'admin_location_edit_dialog' : 'admin_location_add_dialog',
      ),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        isEdit ? 'Edit location' : 'Add location',
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DialogField(
                fieldKey: const Key('admin_location_name_field'),
                controller: _name,
                label: 'Location name',
                validator: _requiredValidator,
              ),
              const SizedBox(height: 12),
              _DialogField(
                fieldKey: const Key('admin_location_timezone_field'),
                controller: _timezone,
                label: 'IANA timezone',
                validator: _timezoneValidator,
              ),
              const SizedBox(height: 12),
              _RolloverHourDropdown(
                value: _rolloverHour,
                onChanged: (v) => setState(() => _rolloverHour = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('admin_location_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_location_submit_button'),
          onPressed: _submit,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.sunset,
            foregroundColor: AppColors.backgroundSurface,
          ),
          child: Text(isEdit ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_confirm_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        title,
        style: AppTextStyles.display20(color: AppColors.textPrimary),
      ),
      content: SizedBox(
        width: 320,
        child: Text(
          message,
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('admin_confirm_cancel_button'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_confirm_confirm_button'),
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.negative,
            foregroundColor: AppColors.backgroundSurface,
          ),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}

class _DialogField extends StatelessWidget {
  const _DialogField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    this.keyboardType,
    this.validator,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final TextInputType? keyboardType;
  final FormFieldValidator<String>? validator;

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
    );
    return TextFormField(
      key: fieldKey,
      controller: controller,
      keyboardType: keyboardType,
      validator: validator,
      style: AppTextStyles.body14(color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: AppTextStyles.mono11(color: AppColors.textMuted),
        floatingLabelStyle: AppTextStyles.mono11(color: AppColors.sunsetDark),
        filled: true,
        fillColor: AppColors.backgroundSurface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: border,
        enabledBorder: border,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.sunset, width: 1.6),
        ),
      ),
    );
  }
}

class _SubscriptionTierDropdown extends StatelessWidget {
  const _SubscriptionTierDropdown({
    required this.value,
    required this.onChanged,
  });

  final String value;
  final ValueChanged<String> onChanged;

  static const List<String> _tiers = <String>[
    'launch',
    'pilot',
    'starter',
    'premium',
    'elite',
    'pro',
    'enterprise',
  ];

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      key: const Key('admin_subscription_tier_dropdown'),
      initialValue: value,
      decoration: InputDecoration(
        labelText: 'Subscription tier',
        labelStyle: AppTextStyles.mono11(color: AppColors.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      items: <DropdownMenuItem<String>>[
        for (final tier in _tiers)
          DropdownMenuItem<String>(value: tier, child: Text(tier)),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

class _CurrencyDropdown extends StatelessWidget {
  const _CurrencyDropdown({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  static const List<String> _currencies = <String>[
    'CAD',
    'USD',
    'EUR',
    'GBP',
    'AUD',
  ];

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      key: const Key('admin_currency_dropdown'),
      initialValue: value,
      decoration: InputDecoration(
        labelText: 'Preferred currency',
        labelStyle: AppTextStyles.mono11(color: AppColors.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      items: <DropdownMenuItem<String>>[
        for (final currency in _currencies)
          DropdownMenuItem<String>(value: currency, child: Text(currency)),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

class _RolloverHourDropdown extends StatelessWidget {
  const _RolloverHourDropdown({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<int>(
      key: const Key('admin_rollover_hour_dropdown'),
      initialValue: value,
      decoration: InputDecoration(
        labelText: 'Business-day rollover hour (0-23)',
        labelStyle: AppTextStyles.mono11(color: AppColors.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      items: <DropdownMenuItem<int>>[
        for (var hour = 0; hour < 24; hour++)
          DropdownMenuItem<int>(
            value: hour,
            child: Text('${hour.toString().padLeft(2, '0')}:00'),
          ),
      ],
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

class _PrimaryLocationDropdown extends StatelessWidget {
  const _PrimaryLocationDropdown({
    required this.locations,
    required this.value,
    required this.onChanged,
  });

  final List<LocationAdminRecord> locations;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      key: const Key('admin_primary_location_dropdown'),
      initialValue: value,
      decoration: InputDecoration(
        labelText: 'Primary location',
        labelStyle: AppTextStyles.mono11(color: AppColors.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      items: <DropdownMenuItem<String>>[
        for (final loc in locations)
          DropdownMenuItem<String>(
            value: loc.locationId,
            child: Text(loc.name),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

String? _requiredValidator(String? value) {
  if (value == null || value.trim().isEmpty) return 'Required';
  return null;
}

String? _timezoneValidator(String? value) {
  if (value == null || value.trim().isEmpty) return 'Required';
  if (!isLikelyIanaTimezone(value)) {
    return 'Use an IANA name like America/Toronto';
  }
  return null;
}
