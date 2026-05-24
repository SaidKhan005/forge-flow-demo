// UX-parity Slice B — canonical admin top-bar scope picker.
//
// Operator-web has one in-header management-scope picker; admin had
// three competing scope-entry patterns (the Business accounts drill-in,
// the modal `OperatorPickerScreen`, and the per-workspace setup picker)
// and no single top-bar control. This widget is the search-first
// top-bar picker the alignment plan designed (parity item W1 / V3,
// approved mock `docs/_mockups/admin_unified_scope_sample.html`): a
// collapsed control showing the current scope, opening an overlay with
// a search field that filters businesses client-side, a few recents,
// and a capped business list that drills into the chosen business's
// locations.
//
// Additive + pure UI. It REUSES the shell's existing scope state: a
// pick produces an [AdminHierarchyScopeIntent] (business or location)
// and hands it back through [onSelectScope]; the shell feeds that into
// its existing `_selectIntent` path so the 6 scope-aware screens react
// exactly as they do for the Business accounts drill-in. It never
// touches permission gating, gateway writes, or auth — it only reads
// the operator list via the injected [OperatorLocationAdminGateway].

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/scope_icons.dart';
import '../../widgets/console/console_surface.dart';
import '../admin_route_handoff.dart';
import '../models/operator_location_admin_models.dart';
import '../services/operator_location_admin_gateway.dart';

/// How many businesses to show in the resting "All businesses" list and
/// in a filtered result set before collapsing the tail into a
/// "+N more" affordance. Keeps the overlay scannable when the admin
/// spans many businesses.
const int _kBusinessListCap = 8;

/// How many recently-picked scopes to remember and surface per session.
/// Capped at 2 so the "Recent" section stays a quick two-row shortcut,
/// not a second list competing with the full businesses list below it.
const int _kRecentScopesCap = 2;

/// Collapsed top-bar trigger + search-first overlay for choosing the
/// admin's working scope (business → optional location). Stateful so it
/// can load the operator list once and remember session recents.
class AdminScopePicker extends StatefulWidget {
  const AdminScopePicker({
    super.key,
    required this.gateway,
    required this.selectedScope,
    required this.onSelectScope,
    this.compact = false,
  });

  /// Read-only source of businesses + their locations. The picker calls
  /// [OperatorLocationAdminGateway.listOperators] only; it never writes.
  final OperatorLocationAdminGateway gateway;

  /// The shell's current scope, or null when nothing is picked yet
  /// ("All businesses" resting state).
  final AdminHierarchyScopeIntent? selectedScope;

  /// Invoked with the chosen scope. The shell forwards this into its
  /// existing `_selectIntent` path so the scope-aware screens react.
  final ValueChanged<AdminHierarchyScopeIntent> onSelectScope;

  /// When true the trigger collapses to an icon-width control for narrow
  /// headers; the overlay is unchanged.
  final bool compact;

  @override
  State<AdminScopePicker> createState() => _AdminScopePickerState();
}

class _AdminScopePickerState extends State<AdminScopePicker> {
  // Session-scoped recents shared across rebuilds of the picker so the
  // overlay can re-surface the last few scopes. In-memory only by
  // design; durable persistence is a future slice.
  static final List<AdminHierarchyScopeIntent> _recents =
      <AdminHierarchyScopeIntent>[];

  void _rememberRecent(AdminHierarchyScopeIntent scope) {
    _recents
      ..removeWhere((r) => r.cacheKey == scope.cacheKey)
      ..insert(0, scope);
    if (_recents.length > _kRecentScopesCap) {
      _recents.removeRange(_kRecentScopesCap, _recents.length);
    }
  }

  Future<void> _openOverlay() async {
    final picked = await showOperatorWebDialog<AdminHierarchyScopeIntent>(
      context: context,
      title: 'Choose business',
      icon: Icons.place_outlined,
      maxWidth: 420,
      // Actions live inside the body (search + list); the dialog action
      // row only needs a single dismiss control.
      actions: <Widget>[
        TextButton(
          key: const Key('admin_scope_picker_overlay_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
      child: _AdminScopePickerOverlayBody(
        gateway: widget.gateway,
        selectedScope: widget.selectedScope,
        recents: List<AdminHierarchyScopeIntent>.unmodifiable(_recents),
      ),
    );
    if (picked == null || !mounted) return;
    _rememberRecent(picked);
    widget.onSelectScope(picked);
  }

  @override
  Widget build(BuildContext context) {
    return _AdminScopeTrigger(
      scope: widget.selectedScope,
      compact: widget.compact,
      onTap: _openOverlay,
    );
  }
}

/// Collapsed control rendered in the header. Mirrors operator-web's large
/// management-scope trigger (`HierarchyMapPicker` with `largeTrigger:
/// true`): a tall control showing a "Managing" label, the current
/// business on the primary line, and the location / "All locations"
/// helper beneath it. Functionally it still opens the admin "Choose
/// business" overlay (operator-web opens an inline tree popover), but the
/// resting appearance matches the operator-web top bar.
class _AdminScopeTrigger extends StatelessWidget {
  const _AdminScopeTrigger({
    required this.scope,
    required this.compact,
    required this.onTap,
  });

  final AdminHierarchyScopeIntent? scope;
  final bool compact;
  final VoidCallback onTap;

  /// Below this assigned width the trigger drops the label + chevron and
  /// shows just the icon, so a width-squeezed header never renders a
  /// broken sliver of text.
  static const double _kLabelWidthFloor = 150;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showLabel =
            !compact && constraints.maxWidth >= _kLabelWidthFloor;
        return Material(
          key: const Key('admin_scope_picker_trigger'),
          color: AppColors.backgroundSurface.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              // Fill the width the header allots (operator-web sizes its
              // picker with a fixed-width SizedBox), so the admin "Managing"
              // control is the same width as operator-web's. minHeight
              // matches operator-web's large trigger so the two bars line up.
              width: showLabel ? double.infinity : 60,
              constraints: BoxConstraints(minHeight: showLabel ? 68 : 44),
              padding: EdgeInsets.symmetric(
                horizontal: showLabel ? 14 : 10,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.borderSubtle, width: 1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    _adminScopeTriggerIcon(scope),
                    size: 20,
                    color: AppColors.sunsetDark,
                  ),
                  if (showLabel) ...<Widget>[
                    const SizedBox(width: 12),
                    Expanded(child: _AdminScopeTriggerLabel(scope: scope)),
                    const SizedBox(width: 8),
                    const Icon(
                      Icons.arrow_drop_down,
                      size: 18,
                      color: AppColors.textSecondary,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The three-line "Managing / business / location" label inside the
/// trigger, matching operator-web's large-trigger label stack.
class _AdminScopeTriggerLabel extends StatelessWidget {
  const _AdminScopeTriggerLabel({required this.scope});

  final AdminHierarchyScopeIntent? scope;

  @override
  Widget build(BuildContext context) {
    final primary = adminScopeTriggerPrimaryLabel(scope);
    final helper = adminScopeTriggerHelperLabel(scope);
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Managing',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: AppTextStyles.mono8(color: AppColors.textMuted),
        ),
        const SizedBox(height: 2),
        Text(
          primary,
          key: const Key('admin_scope_picker_trigger_label'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: AppTextStyles.display16(color: AppColors.textPrimary),
        ),
        Text(
          helper,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: AppTextStyles.body12(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

/// Resting-vs-selected label for the collapsed trigger. Plain English,
/// no em dash: a middot separates business and location.
String adminScopeTriggerValueLabel(AdminHierarchyScopeIntent? scope) {
  if (scope == null) return 'All businesses';
  final business = (scope.operatorName ?? '').trim();
  final businessLabel = business.isEmpty ? 'Selected business' : business;
  if (scope.isLocationScope) {
    final location = (scope.locationName ?? '').trim();
    if (location.isNotEmpty) return '$businessLabel · $location';
    return businessLabel;
  }
  return '$businessLabel · All locations';
}

/// The big primary line in the large trigger: the selected business
/// name, or the "All businesses" resting state. Mirrors operator-web's
/// large-trigger primary label.
String adminScopeTriggerPrimaryLabel(AdminHierarchyScopeIntent? scope) {
  if (scope == null) return 'All businesses';
  final business = (scope.operatorName ?? '').trim();
  return business.isEmpty ? 'Selected business' : business;
}

/// The helper sub-line under the primary label: the location name for a
/// location scope, "All locations" for a business-wide scope, or a
/// resting hint before anything is picked. Mirrors operator-web's
/// scope-kind helper line. Plain English, no em dash.
String adminScopeTriggerHelperLabel(AdminHierarchyScopeIntent? scope) {
  if (scope == null) return 'Pick a business to manage';
  if (scope.isLocationScope) {
    final location = (scope.locationName ?? '').trim();
    return location.isEmpty ? 'Location' : location;
  }
  return 'All locations';
}

/// Trigger icon mirroring operator-web's `_iconForKind`: a building for a
/// business-wide scope (and the resting state), a place pin for a
/// location scope. Both glyphs resolve through the canonical
/// [scopeIcon] helper so the trigger matches every other scope surface.
IconData _adminScopeTriggerIcon(AdminHierarchyScopeIntent? scope) {
  if (scope != null && scope.isLocationScope) {
    return scopeIcon(kind: ScopeEntityKind.location);
  }
  return scopeIcon(kind: ScopeEntityKind.business);
}

/// Overlay body: search field, recents, capped business list, and (once
/// a business is expanded) its locations. Loads the operator list once.
class _AdminScopePickerOverlayBody extends StatefulWidget {
  const _AdminScopePickerOverlayBody({
    required this.gateway,
    required this.selectedScope,
    required this.recents,
  });

  final OperatorLocationAdminGateway gateway;
  final AdminHierarchyScopeIntent? selectedScope;
  final List<AdminHierarchyScopeIntent> recents;

  @override
  State<_AdminScopePickerOverlayBody> createState() =>
      _AdminScopePickerOverlayBodyState();
}

class _AdminScopePickerOverlayBodyState
    extends State<_AdminScopePickerOverlayBody> {
  bool _loading = true;
  String? _loadError;
  List<OperatorAdminBundle> _operators = const <OperatorAdminBundle>[];
  String _query = '';
  String? _expandedOperatorId;

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
        _loadError = 'Could not load businesses: $error';
        _loading = false;
      });
    }
  }

  void _onQueryChanged(String value) {
    setState(() {
      _query = value;
      // Typing collapses any open drill-in so results re-rank cleanly.
      if (value.trim().isNotEmpty) _expandedOperatorId = null;
    });
  }

  void _toggleExpanded(String operatorId) {
    setState(() {
      _expandedOperatorId = _expandedOperatorId == operatorId
          ? null
          : operatorId;
    });
  }

  void _pickBusiness(OperatorAdminBundle bundle) {
    Navigator.of(context).pop(
      AdminHierarchyScopeIntent.business(
        operatorId: bundle.operator.operatorId,
        operatorName: bundle.operator.businessName,
      ),
    );
  }

  void _pickLocation(OperatorAdminBundle bundle, LocationAdminRecord location) {
    Navigator.of(context).pop(
      AdminHierarchyScopeIntent.location(
        operatorId: bundle.operator.operatorId,
        locationId: location.locationId,
        operatorName: bundle.operator.businessName,
        locationName: location.name,
      ),
    );
  }

  List<OperatorAdminBundle> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _operators;
    return _operators
        .where((b) => b.operator.businessName.toLowerCase().contains(q))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.maxFinite,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _AdminScopeSearchField(onChanged: _onQueryChanged),
          const SizedBox(height: 12),
          // TODO(ux-parity): search is client-side over the full
          // listOperators() result. For large operator counts the
          // production follow-up is a server-side search endpoint
          // (and an org-unit drill-in once the admin gateway surfaces
          // org-unit names alongside locations).
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 360),
            child: _AdminScopeResults(
              loading: _loading,
              loadError: _loadError,
              query: _query,
              filtered: _filtered,
              recents: widget.recents,
              selectedScope: widget.selectedScope,
              expandedOperatorId: _expandedOperatorId,
              onRetry: _refresh,
              onToggleExpanded: _toggleExpanded,
              onPickBusiness: _pickBusiness,
              onPickLocation: _pickLocation,
              onPickRecent: (scope) => Navigator.of(context).pop(scope),
            ),
          ),
        ],
      ),
    );
  }
}

/// Search input row at the top of the overlay.
class _AdminScopeSearchField extends StatelessWidget {
  const _AdminScopeSearchField({required this.onChanged});

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const Key('admin_scope_picker_search_field'),
      autofocus: true,
      onChanged: onChanged,
      style: AppTextStyles.body14(color: AppColors.textPrimary),
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(
          Icons.search,
          size: 18,
          color: AppColors.textMuted,
        ),
        hintText: 'Search businesses',
        hintStyle: AppTextStyles.body14(color: AppColors.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.borderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.borderSubtle),
        ),
      ),
    );
  }
}

/// Switches between the load / error / empty / list states. Pure
/// dispatch so each branch stays a small widget.
class _AdminScopeResults extends StatelessWidget {
  const _AdminScopeResults({
    required this.loading,
    required this.loadError,
    required this.query,
    required this.filtered,
    required this.recents,
    required this.selectedScope,
    required this.expandedOperatorId,
    required this.onRetry,
    required this.onToggleExpanded,
    required this.onPickBusiness,
    required this.onPickLocation,
    required this.onPickRecent,
  });

  final bool loading;
  final String? loadError;
  final String query;
  final List<OperatorAdminBundle> filtered;
  final List<AdminHierarchyScopeIntent> recents;
  final AdminHierarchyScopeIntent? selectedScope;
  final String? expandedOperatorId;
  final VoidCallback onRetry;
  final ValueChanged<String> onToggleExpanded;
  final ValueChanged<OperatorAdminBundle> onPickBusiness;
  final void Function(OperatorAdminBundle, LocationAdminRecord) onPickLocation;
  final ValueChanged<AdminHierarchyScopeIntent> onPickRecent;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(
        key: Key('admin_scope_picker_loading'),
        child: Padding(
          padding: EdgeInsets.all(24),
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.sunsetDark,
            ),
          ),
        ),
      );
    }
    final error = loadError;
    if (error != null) {
      return _AdminScopeErrorState(message: error, onRetry: onRetry);
    }
    final showRecents = query.trim().isEmpty && recents.isNotEmpty;
    final cappedBusinesses = filtered.length > _kBusinessListCap
        ? filtered.sublist(0, _kBusinessListCap)
        : filtered;
    final overflow = filtered.length - cappedBusinesses.length;
    return ListView(
      key: const Key('admin_scope_picker_results'),
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: <Widget>[
        if (showRecents) ...<Widget>[
          const _AdminScopeSectionLabel(label: 'Recent'),
          for (final scope in recents)
            _AdminScopeRecentRow(
              scope: scope,
              selected: scope.cacheKey == selectedScope?.cacheKey,
              onTap: () => onPickRecent(scope),
            ),
        ],
        _AdminScopeSectionLabel(label: 'Businesses (${filtered.length})'),
        if (filtered.isEmpty)
          _AdminScopeEmptyState(query: query)
        else
          for (final bundle in cappedBusinesses)
            _AdminScopeBusinessRow(
              bundle: bundle,
              selectedScope: selectedScope,
              expanded: bundle.operator.operatorId == expandedOperatorId,
              onToggleExpanded: () =>
                  onToggleExpanded(bundle.operator.operatorId),
              onPickBusiness: () => onPickBusiness(bundle),
              onPickLocation: (location) => onPickLocation(bundle, location),
            ),
        if (overflow > 0)
          Padding(
            key: const Key('admin_scope_picker_overflow'),
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: Text(
              '+$overflow more. Keep typing to narrow.',
              style: AppTextStyles.body12(color: AppColors.peacockDark),
            ),
          ),
      ],
    );
  }
}

/// Small uppercase section divider label inside the overlay list.
class _AdminScopeSectionLabel extends StatelessWidget {
  const _AdminScopeSectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
      child: Text(
        label,
        style: AppTextStyles.uiLabel(color: AppColors.textMuted),
      ),
    );
  }
}

/// One business row. Tapping the row picks the business-wide scope;
/// tapping the expander reveals the business's locations.
class _AdminScopeBusinessRow extends StatelessWidget {
  const _AdminScopeBusinessRow({
    required this.bundle,
    required this.selectedScope,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onPickBusiness,
    required this.onPickLocation,
  });

  final OperatorAdminBundle bundle;
  final AdminHierarchyScopeIntent? selectedScope;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final VoidCallback onPickBusiness;
  final ValueChanged<LocationAdminRecord> onPickLocation;

  bool get _selectedBusinessWide =>
      selectedScope != null &&
      selectedScope!.isBusinessScope &&
      selectedScope!.operatorId == bundle.operator.operatorId;

  @override
  Widget build(BuildContext context) {
    final operatorId = bundle.operator.operatorId;
    final locations = bundle.locations;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _AdminScopeRow(
          key: Key('admin_scope_picker_business_$operatorId'),
          icon: scopeIcon(kind: ScopeEntityKind.business),
          title: bundle.operator.businessName,
          subtitle: _locationCountLabel(locations.length),
          selected: _selectedBusinessWide,
          onTap: onPickBusiness,
          leading: locations.isEmpty
              ? null
              : _AdminScopeExpander(
                  key: Key('admin_scope_picker_expander_$operatorId'),
                  expanded: expanded,
                  onTap: onToggleExpanded,
                ),
        ),
        if (expanded)
          for (final location in locations)
            _AdminScopeRow(
              key: Key('admin_scope_picker_location_${location.locationId}'),
              icon: scopeIcon(kind: ScopeEntityKind.location),
              title: location.name,
              subtitle: location.address.trim().isEmpty
                  ? 'Location'
                  : location.address,
              indent: true,
              selected:
                  selectedScope != null &&
                  selectedScope!.isLocationScope &&
                  selectedScope!.locationId == location.locationId,
              onTap: () => onPickLocation(location),
            ),
      ],
    );
  }

  static String _locationCountLabel(int count) {
    if (count == 1) return '1 location';
    return '$count locations';
  }
}

/// A previously-picked scope, re-surfaced in the Recent section.
class _AdminScopeRecentRow extends StatelessWidget {
  const _AdminScopeRecentRow({
    required this.scope,
    required this.selected,
    required this.onTap,
  });

  final AdminHierarchyScopeIntent scope;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isLocation = scope.isLocationScope;
    return _AdminScopeRow(
      key: Key('admin_scope_picker_recent_${scope.cacheKey}'),
      icon: scopeIcon(
        kind: isLocation
            ? ScopeEntityKind.location
            : ScopeEntityKind.business,
      ),
      title: adminScopeTriggerValueLabel(scope),
      subtitle: isLocation ? 'Location' : 'Business: all locations',
      selected: selected,
      onTap: onTap,
    );
  }
}

/// Shared row chrome for businesses, locations, and recents.
class _AdminScopeRow extends StatelessWidget {
  const _AdminScopeRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.leading,
    this.indent = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final Widget? leading;
  final bool indent;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? AppColors.sunset.withValues(alpha: 0.10)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: EdgeInsets.fromLTRB(indent ? 30 : 8, 9, 8, 9),
          child: Row(
            children: <Widget>[
              if (leading != null) ...<Widget>[
                leading!,
                const SizedBox(width: 4),
              ],
              Icon(
                icon,
                size: 17,
                color: selected ? AppColors.sunsetDark : AppColors.textMuted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body14(
                        color: selected
                            ? AppColors.textPrimary
                            : AppColors.textSecondary,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body12(color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              if (selected)
                const Icon(
                  Icons.check,
                  size: 16,
                  color: AppColors.sunsetDark,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Disclosure chevron for a business row's locations.
class _AdminScopeExpander extends StatelessWidget {
  const _AdminScopeExpander({super.key, required this.expanded, required this.onTap});

  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Icon(
          expanded ? Icons.expand_more : Icons.chevron_right,
          size: 18,
          color: AppColors.textMuted,
        ),
      ),
    );
  }
}

/// Honest empty state when a search matches no business.
class _AdminScopeEmptyState extends StatelessWidget {
  const _AdminScopeEmptyState({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final trimmed = query.trim();
    final message = trimmed.isEmpty
        ? 'No businesses yet.'
        : 'No businesses match "$trimmed".';
    return Padding(
      key: const Key('admin_scope_picker_empty'),
      padding: const EdgeInsets.all(18),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: AppTextStyles.body13(color: AppColors.textMuted),
      ),
    );
  }
}

/// Inline error + retry when the operator list fails to load.
class _AdminScopeErrorState extends StatelessWidget {
  const _AdminScopeErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('admin_scope_picker_error'),
      padding: const EdgeInsets.all(8),
      child: OperatorWebBanner(
        message: message,
        tone: OperatorWebBannerTone.error,
        action: TextButton(
          key: const Key('admin_scope_picker_retry'),
          onPressed: onRetry,
          child: const Text('Retry'),
        ),
      ),
    );
  }
}
