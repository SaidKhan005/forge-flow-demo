// Phase 11A.3a follow-up — Operator + location picker.
//
// The Corpus admin "Graph candidates" tab needs a real
// (operator_id, location_id) target before it can commit graph
// approvals. Live mode landed `11A.3a` with the commit button
// disabled and a banner pointing at this slice; this picker is
// what unblocks it. Two cascading dropdowns (operator → location)
// over the existing [OperatorLocationAdminGateway]; pop with the
// resolved pair on confirm, null on cancel.
//
// Caching is in-memory only — keyed by admin UID — so the next
// picker open inside the same session pre-selects the most-
// recently-confirmed pair. Durable cookie / shared-prefs
// persistence is intentionally out of scope; that lands in a
// future slice when cross-session continuity is needed.
//
// The picker mounts via Navigator.push from the Corpus admin
// screen; it is NOT a side-nav route because the boundary is
// "internal helper of the Corpus surface." The route ID
// [kAdminOperatorPickerRouteId] in `admin_routes.dart` is the
// stable handle audit logs / deep-links can refer to.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../models/operator_location_admin_models.dart';
import '../services/operator_location_admin_gateway.dart';

/// Resolved (operator, location) pair the picker pops with on confirm.
/// Carries the human-readable names alongside the IDs so the host
/// screen can render a "Targeting [name]" indicator without a second
/// gateway round-trip.
@immutable
class OperatorPickerResult {
  const OperatorPickerResult({
    required this.operatorId,
    required this.locationId,
    required this.operatorBusinessName,
    required this.locationName,
  });

  final String operatorId;
  final String locationId;
  final String operatorBusinessName;
  final String locationName;
}

/// Modal picker host. Returns an [OperatorPickerResult] via
/// Navigator.pop on confirm, null on cancel.
class OperatorPickerScreen extends StatelessWidget {
  const OperatorPickerScreen({super.key, required this.gateway, this.adminUid});

  final OperatorLocationAdminGateway gateway;

  /// Cache key. When provided, a successful confirm writes the
  /// resolved pair into [_cache] so the next open for the same
  /// admin pre-selects it. Null disables caching (e.g. anonymous
  /// test path).
  final String? adminUid;

  // In-memory only by design — durable persistence is a future
  // slice. The map outlives the screen instance so subsequent
  // opens can hydrate from it.
  static final Map<String, OperatorPickerResult> _cache =
      <String, OperatorPickerResult>{};

  @visibleForTesting
  static void clearCacheForTesting() {
    _cache.clear();
  }

  @visibleForTesting
  static OperatorPickerResult? cachedFor(String adminUid) {
    return _cache[adminUid];
  }

  @override
  Widget build(BuildContext context) {
    final cached = adminUid != null ? _cache[adminUid] : null;
    return Scaffold(
      key: const Key('admin_operator_picker_screen'),
      backgroundColor: AppColors.backgroundDeep,
      appBar: AppBar(
        key: const Key('admin_operator_picker_app_bar'),
        backgroundColor: AppColors.backgroundDeep,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textSecondary),
        title: Text(
          'Pick operator',
          style: AppTextStyles.display20(color: AppColors.textPrimary),
        ),
      ),
      body: _OperatorPickerBody(
        gateway: gateway,
        cachedInitial: cached,
        onConfirmed: (result) {
          final uid = adminUid;
          if (uid != null) {
            _cache[uid] = result;
          }
          Navigator.of(context).pop(result);
        },
      ),
    );
  }
}

class _OperatorPickerBody extends StatefulWidget {
  const _OperatorPickerBody({
    required this.gateway,
    required this.cachedInitial,
    required this.onConfirmed,
  });

  final OperatorLocationAdminGateway gateway;
  final OperatorPickerResult? cachedInitial;
  final void Function(OperatorPickerResult result) onConfirmed;

  @override
  State<_OperatorPickerBody> createState() => _OperatorPickerBodyState();
}

class _OperatorPickerBodyState extends State<_OperatorPickerBody> {
  bool _loading = true;
  String? _loadError;
  List<OperatorAdminBundle> _operators = const <OperatorAdminBundle>[];
  String? _selectedOperatorId;
  String? _selectedLocationId;

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
      final operators = await widget.gateway.listOperators();
      if (!mounted) return;
      setState(() {
        _operators = operators;
        _loading = false;
        _hydrateFromCache();
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

  void _hydrateFromCache() {
    final cached = widget.cachedInitial;
    if (cached == null) return;
    OperatorAdminBundle? hit;
    for (final b in _operators) {
      if (b.operator.operatorId == cached.operatorId) {
        hit = b;
        break;
      }
    }
    if (hit == null) return;
    _selectedOperatorId = hit.operator.operatorId;
    final hasLoc = hit.locations.any((l) => l.locationId == cached.locationId);
    if (hasLoc) {
      _selectedLocationId = cached.locationId;
    } else {
      _selectedLocationId =
          hit.operator.primaryLocationId ??
          (hit.locations.isNotEmpty ? hit.locations.first.locationId : null);
    }
  }

  void _onOperatorChanged(String? operatorId) {
    setState(() {
      _selectedOperatorId = operatorId;
      if (operatorId == null) {
        _selectedLocationId = null;
        return;
      }
      OperatorAdminBundle? bundle;
      for (final b in _operators) {
        if (b.operator.operatorId == operatorId) {
          bundle = b;
          break;
        }
      }
      if (bundle == null) {
        _selectedLocationId = null;
        return;
      }
      _selectedLocationId =
          bundle.operator.primaryLocationId ??
          (bundle.locations.isNotEmpty
              ? bundle.locations.first.locationId
              : null);
    });
  }

  void _onLocationChanged(String? locationId) {
    setState(() => _selectedLocationId = locationId);
  }

  void _onConfirm() {
    final operatorId = _selectedOperatorId;
    final locationId = _selectedLocationId;
    if (operatorId == null || locationId == null) return;
    OperatorAdminBundle? bundle;
    for (final b in _operators) {
      if (b.operator.operatorId == operatorId) {
        bundle = b;
        break;
      }
    }
    if (bundle == null) return;
    LocationAdminRecord? location;
    for (final l in bundle.locations) {
      if (l.locationId == locationId) {
        location = l;
        break;
      }
    }
    if (location == null) return;
    widget.onConfirmed(
      OperatorPickerResult(
        operatorId: operatorId,
        locationId: locationId,
        operatorBusinessName: bundle.operator.businessName,
        locationName: location.name,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        key: Key('admin_operator_picker_loading'),
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
      return Padding(
        padding: const EdgeInsets.all(20),
        child: _PickerErrorBanner(message: _loadError!, onRetry: _refresh),
      );
    }
    if (_operators.isEmpty) {
      return Center(
        key: const Key('admin_operator_picker_empty'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No operators yet',
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 8),
                Text(
                  'Add an operator before applying relationship decisions.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  key: const Key('admin_operator_picker_empty_cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    OperatorAdminBundle? selectedBundle;
    if (_selectedOperatorId != null) {
      for (final b in _operators) {
        if (b.operator.operatorId == _selectedOperatorId) {
          selectedBundle = b;
          break;
        }
      }
    }
    final locations =
        selectedBundle?.locations ?? const <LocationAdminRecord>[];
    final canConfirm =
        _selectedOperatorId != null && _selectedLocationId != null;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Pick the operator and location for approved relationship decisions. Selection is remembered '
              'for the rest of this admin session.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 18),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Operator',
                    style: AppTextStyles.mono11(color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 6),
                  DropdownButton<String>(
                    key: const Key('admin_operator_picker_operator_dropdown'),
                    value: _selectedOperatorId,
                    isExpanded: true,
                    hint: const Text('Select operator'),
                    items: <DropdownMenuItem<String>>[
                      for (final b in _operators)
                        DropdownMenuItem<String>(
                          key: Key(
                            'admin_operator_picker_operator_item_'
                            '${b.operator.operatorId}',
                          ),
                          value: b.operator.operatorId,
                          child: Text(b.operator.businessName),
                        ),
                    ],
                    onChanged: _onOperatorChanged,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Location',
                    style: AppTextStyles.mono11(color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 6),
                  DropdownButton<String>(
                    key: const Key('admin_operator_picker_location_dropdown'),
                    value: _selectedLocationId,
                    isExpanded: true,
                    hint: const Text('Select location'),
                    items: <DropdownMenuItem<String>>[
                      for (final l in locations)
                        DropdownMenuItem<String>(
                          key: Key(
                            'admin_operator_picker_location_item_'
                            '${l.locationId}',
                          ),
                          value: l.locationId,
                          child: Text(l.name),
                        ),
                    ],
                    onChanged: locations.isEmpty ? null : _onLocationChanged,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  key: const Key('admin_operator_picker_confirm'),
                  onPressed: canConfirm ? _onConfirm : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.sunset,
                    foregroundColor: AppColors.backgroundSurface,
                  ),
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Use selection'),
                ),
                OutlinedButton(
                  key: const Key('admin_operator_picker_cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }
}

class _PickerErrorBanner extends StatelessWidget {
  const _PickerErrorBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_operator_picker_error'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.negative, width: 1),
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
              style: AppTextStyles.mono11(color: AppColors.negative),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton(
            key: const Key('admin_operator_picker_retry'),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
