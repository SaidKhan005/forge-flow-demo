// Phase 8.0 - F&F Ops Console host shell for the shared Vendor
// Connections widget tree.
//
// Hosts `VendorConnectionsWidget` (lib/integrations/ui/vendor_connections/)
// inside the F&F Operations Console route tree. The legacy route reads
// (operator_id, location_id) from constructor args resolved by the
// existing operator picker. Hierarchy-aware callers can also pass a
// selected scope and scope options; business/org-unit scopes render
// location-required copy while location scopes mount the shared widget.

import 'package:flutter/material.dart';

import '../../../integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import '../../../integrations/ui/vendor_connections/vendor_connections_widget.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/console/console_screen_body.dart';
import '../../../widgets/console/console_screen_header.dart';
import '../../../widgets/console/console_surface.dart';
import '../../admin_route_handoff.dart';
import '../../widgets/admin_business_accounts_back_button.dart';
import '../../widgets/admin_responsive_layout.dart';

/// F&F Ops Console host shell for the shared Vendor Connections
/// widget tree.
class VendorConnectionsAdminMount extends StatefulWidget {
  const VendorConnectionsAdminMount({
    super.key,
    required this.operatorId,
    this.locationId,
    this.locationName,
    this.selectedScope,
    this.scopeOptions = const <AdminHierarchyScopeIntent>[],
    this.onScopeSelected,
    this.gateway,
    this.canMutate = true,
    this.embedded = false,
    this.onBackToBusinessAccounts,
  }) : assert(
         locationId != null || selectedScope != null,
         'VendorConnectionsAdminMount needs a location or hierarchy scope',
       );

  final String operatorId;
  final String? locationId;
  final String? locationName;

  /// Optional hierarchy context supplied by the business setup workspace.
  /// Vendor connections use this for navigation, but edit controls remain
  /// location-only.
  final AdminHierarchyScopeIntent? selectedScope;

  /// Legacy scope choices retained for constructor compatibility. Slice 0 stops
  /// rendering a local scope prompt; the shared business hierarchy workspace is
  /// now the source of scope changes.
  final List<AdminHierarchyScopeIntent> scopeOptions;

  final ValueChanged<AdminHierarchyScopeIntent>? onScopeSelected;

  /// Production wires the HTTP gateway above the auth gate; demo +
  /// widget tests inject a seeded in-memory gateway.
  final VendorConnectionsGateway? gateway;

  /// `false` for `ff_support` (read-only). Hides connect / test /
  /// disconnect buttons but still renders status.
  final bool canMutate;

  /// True when the mount is hosted inside another admin workspace
  /// instead of being pushed as its own route.
  final bool embedded;
  final VoidCallback? onBackToBusinessAccounts;

  @override
  State<VendorConnectionsAdminMount> createState() =>
      _VendorConnectionsAdminMountState();
}

class _VendorConnectionsAdminMountState
    extends State<VendorConnectionsAdminMount> {
  AdminHierarchyScopeIntent? get _activeScope {
    return widget.selectedScope ?? _legacyLocationScope;
  }

  AdminHierarchyScopeIntent? get _legacyLocationScope {
    final locationId = widget.locationId;
    if (locationId == null) return null;
    return AdminHierarchyScopeIntent.location(
      operatorId: widget.operatorId,
      locationId: locationId,
      locationName: widget.locationName,
      valueState: AdminHierarchyScopeValueState.locationOnly,
      allowedActionsLabel: widget.canMutate ? 'Can edit' : 'Read only',
    );
  }

  bool get _hasHierarchyContext {
    return widget.selectedScope != null || widget.scopeOptions.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    // Embedded inside AdminSetupWorkspace (the per-operator screen): the
    // workspace already supplies the page header, scope context, and
    // back button, so the body mirrors the operator-web Vendor
    // integrations screen — a centered, max-width body holding the
    // shared widget inside a single surface card with its own header
    // suppressed. The standalone Scaffold path below is retained for
    // legacy / direct callers (and is the path the widget tests cover).
    if (widget.embedded) {
      return ColoredBox(
        key: const Key('admin_vendor_connections_screen'),
        color: AppColors.backgroundDeep,
        child: _buildEmbeddedWebBody(),
      );
    }
    final body = _buildBody();
    return Scaffold(
      key: const Key('admin_vendor_connections_screen'),
      appBar: AppBar(
        leading: widget.onBackToBusinessAccounts == null
            ? null
            : IconButton(
                key: kAdminBusinessAccountsBackButtonKey,
                tooltip: 'Back to Business accounts',
                onPressed: widget.onBackToBusinessAccounts,
                icon: const Icon(Icons.arrow_back),
              ),
        title: const Text('Vendor integrations'),
      ),
      body: body,
    );
  }

  /// Operator-web-parity body for the embedded (per-operator workspace)
  /// path. Centered, max-width content; the shared widget sits inside a
  /// single surface card with its own header off (the workspace header
  /// titles the page). Mirrors `vendor_connections_screen.dart`.
  Widget _buildEmbeddedWebBody() {
    final scope = _activeScope;
    final location = _VendorConnectionsLocationScope.from(
      scope: scope,
      fallbackOperatorId: widget.operatorId,
      fallbackLocationId: widget.locationId,
      fallbackLocationName: widget.locationName,
    );
    final Widget content;
    if (location == null) {
      content = _embeddedLocationRequiredPanel(scope);
    } else if (widget.gateway == null) {
      content = _embeddedNotWiredPanel(location.locationName);
    } else {
      content = _embeddedVendorCard(location);
    }
    return OperatorWebScreenBody(
      scrollKey: const Key('admin_vendor_connections_screen_body'),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          OperatorWebScreenHeader(
            icon: Icons.cable_outlined,
            title: 'Vendor integrations',
            subtitle:
                'Connect, test, disconnect, and review vendor setup per '
                'location.',
            actions: <Widget>[
              if (widget.onBackToBusinessAccounts != null)
                AdminBusinessAccountsBackButton(
                  onPressed: widget.onBackToBusinessAccounts,
                ),
            ],
          ),
          const SizedBox(height: 14),
          content,
        ],
      ),
    );
  }

  Widget _embeddedVendorCard(_VendorConnectionsLocationScope location) {
    return DecoratedBox(
      key: const Key('admin_vendor_connections_widget_host'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: VendorConnectionsWidget(
        key: ValueKey<String>(
          'admin_vendor_connections_widget_'
          '${location.operatorId}_${location.locationId}',
        ),
        operatorId: location.operatorId,
        locationId: location.locationId,
        locationNameOverride: location.locationName,
        gateway: widget.gateway,
        canMutate: widget.canMutate,
        showHeader: false,
      ),
    );
  }

  Widget _embeddedLocationRequiredPanel(AdminHierarchyScopeIntent? scope) {
    final selectedScopeLabel = scope == null
        ? 'No hierarchy scope selected'
        : '${scope.scopeType.label}: ${scope.displayLabel}';
    return OperatorWebPanel(
      key: const Key('admin_vendor_connections_location_required'),
      title: 'Choose a location',
      subtitle:
          'Vendor setup is location-only. Business and org-unit scopes narrow '
          'the hierarchy context, but connect, test, disconnect, and sync-log '
          'controls need a specific location.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AdminDetailRow(label: 'Selected scope', value: selectedScopeLabel),
          const AdminDetailRow(
            label: 'Edit controls',
            value: 'Location required',
          ),
          const AdminDetailRow(
            label: 'Global services',
            value: 'Connected services remains separate',
          ),
        ],
      ),
    );
  }

  Widget _embeddedNotWiredPanel(String locationName) {
    return OperatorWebPanel(
      key: const Key('admin_vendor_connections_not_wired'),
      title: 'Lifecycle actions are not live',
      subtitle:
          'Connect, test, disconnect, and sync-log actions are not exposed '
          'from this admin route in preview. This page is intentionally '
          'read-only rather than showing demo vendor data. The live provider '
          'summary stays available in Connected services.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AdminDetailRow(label: 'Location', value: locationName),
          const AdminDetailRow(
            label: 'Current admin status',
            value: 'Not routed',
          ),
          const AdminDetailRow(
            label: 'Safe live view',
            value: 'Connected services',
          ),
          const AdminDetailRow(
            label: 'Mutation state',
            value: 'Disabled until backend bindings exist',
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final scope = _activeScope;
    final location = _VendorConnectionsLocationScope.from(
      scope: scope,
      fallbackOperatorId: widget.operatorId,
      fallbackLocationId: widget.locationId,
      fallbackLocationName: widget.locationName,
    );
    final content = location == null
        ? _VendorLocationRequiredPanel(
            scope: scope,
            onBackToBusinessAccounts: widget.embedded
                ? widget.onBackToBusinessAccounts
                : null,
          )
        : _buildLocationContent(location);

    if (!_hasHierarchyContext) {
      return content;
    }

    return ColoredBox(
      color: AppColors.backgroundDeep,
      child: Column(
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: SingleChildScrollView(
              key: const Key('admin_vendor_connections_scope_context'),
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 920),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (scope != null)
                        _VendorConnectionsScopeContext(scope: scope),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: content),
        ],
      ),
    );
  }

  Widget _buildLocationContent(_VendorConnectionsLocationScope location) {
    final resolvedGateway = widget.gateway;
    return resolvedGateway == null
        ? _VendorLifecycleUnavailablePanel(
            locationName: location.locationName,
            onBackToBusinessAccounts: widget.embedded
                ? widget.onBackToBusinessAccounts
                : null,
          )
        : VendorConnectionsWidget(
            key: ValueKey<String>(
              'admin_vendor_connections_widget_'
              '${location.operatorId}_${location.locationId}',
            ),
            operatorId: location.operatorId,
            locationId: location.locationId,
            locationNameOverride: location.locationName,
            gateway: resolvedGateway,
            canMutate: widget.canMutate,
            headerLeading:
                widget.embedded && widget.onBackToBusinessAccounts != null
                ? AdminBusinessAccountsBackButton(
                    onPressed: widget.onBackToBusinessAccounts,
                  )
                : null,
          );
  }
}

class _VendorConnectionsScopeContext extends StatelessWidget {
  const _VendorConnectionsScopeContext({required this.scope});

  final AdminHierarchyScopeIntent scope;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_vendor_connections_selected_scope'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.peacock.withValues(alpha: 0.28),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.account_tree_outlined,
            size: 18,
            color: AppColors.peacockDark,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Selected ${scope.scopeType.label.toLowerCase()} scope',
                  style: AppTextStyles.uiLabel(color: AppColors.peacockDark),
                ),
                const SizedBox(height: 3),
                Text(
                  scope.displayLabel,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
                if (!scope.isLocationScope) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Select a location in Business accounts to configure vendor integrations.',
                    style: AppTextStyles.body12(color: AppColors.textSecondary),
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

class _VendorConnectionsLocationScope {
  const _VendorConnectionsLocationScope({
    required this.operatorId,
    required this.locationId,
    required this.locationName,
  });

  final String operatorId;
  final String locationId;
  final String locationName;

  static _VendorConnectionsLocationScope? from({
    required AdminHierarchyScopeIntent? scope,
    required String fallbackOperatorId,
    required String? fallbackLocationId,
    required String? fallbackLocationName,
  }) {
    if (scope != null && !scope.isLocationScope) return null;
    final locationId = scope?.locationId ?? fallbackLocationId;
    if (locationId == null || locationId.trim().isEmpty) return null;
    return _VendorConnectionsLocationScope(
      operatorId: scope?.operatorId ?? fallbackOperatorId,
      locationId: locationId,
      locationName:
          _clean(scope?.locationName) ??
          _clean(fallbackLocationName) ??
          'Selected location',
    );
  }

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }
}

class _VendorLocationRequiredPanel extends StatelessWidget {
  const _VendorLocationRequiredPanel({
    required this.scope,
    required this.onBackToBusinessAccounts,
  });

  final AdminHierarchyScopeIntent? scope;
  final VoidCallback? onBackToBusinessAccounts;

  @override
  Widget build(BuildContext context) {
    final selectedScopeLabel = scope == null
        ? 'No hierarchy scope selected'
        : '${scope!.scopeType.label}: ${scope!.displayLabel}';
    return ColoredBox(
      color: AppColors.backgroundDeep,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AdminPageHeader(
                  title: 'Vendor integrations',
                  subtitle:
                      'Vendor credentials are connected, tested, disconnected, and logged per location.',
                  leading: onBackToBusinessAccounts == null
                      ? null
                      : AdminBusinessAccountsBackButton(
                          onPressed: onBackToBusinessAccounts,
                        ),
                ),
                const SizedBox(height: 14),
                AdminCard(
                  key: const Key('admin_vendor_connections_location_required'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Icon(
                            // canonical location icon (mirrors scopeIcon(location)); this empty state illustrates a LOCATION
                            Icons.place_outlined,
                            size: 20,
                            color: AppColors.textMuted,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  'Choose a location before editing vendor integrations',
                                  style: AppTextStyles.sectionTitle(
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Business and org-unit scopes narrow the hierarchy context, but vendor setup remains location-only. Select a location scope to show connect, test, disconnect, and sync-log controls.',
                                  style: AppTextStyles.body13(
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      AdminDetailRow(
                        label: 'Selected scope',
                        value: selectedScopeLabel,
                      ),
                      const AdminDetailRow(
                        label: 'Edit controls',
                        value: 'Location required',
                      ),
                      const AdminDetailRow(
                        label: 'Global services',
                        value: 'Connected services remains separate',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VendorLifecycleUnavailablePanel extends StatelessWidget {
  const _VendorLifecycleUnavailablePanel({
    required this.locationName,
    required this.onBackToBusinessAccounts,
  });

  final String locationName;
  final VoidCallback? onBackToBusinessAccounts;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.backgroundDeep,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AdminPageHeader(
                  title: 'Vendor integrations',
                  subtitle:
                      'Live provider summary is available in Connected services. Per-location lifecycle actions stay disabled here until the proxy route has production bindings.',
                  leading: onBackToBusinessAccounts == null
                      ? null
                      : AdminBusinessAccountsBackButton(
                          onPressed: onBackToBusinessAccounts,
                        ),
                ),
                const SizedBox(height: 14),
                AdminCard(
                  key: const Key('admin_vendor_connections_not_wired'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Icon(
                            Icons.lock_outline,
                            size: 20,
                            color: AppColors.textMuted,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  'Lifecycle actions are not live for $locationName',
                                  style: AppTextStyles.sectionTitle(
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Connect, test, disconnect, and sync-log actions are not exposed from this admin route in preview. This page is intentionally read-only rather than showing demo vendor data.',
                                  style: AppTextStyles.body13(
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const AdminDetailRow(
                        label: 'Current admin status',
                        value: 'Not routed',
                      ),
                      const AdminDetailRow(
                        label: 'Safe live view',
                        value: 'Connected services',
                      ),
                      const AdminDetailRow(
                        label: 'Mutation state',
                        value: 'Disabled until backend bindings exist',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
