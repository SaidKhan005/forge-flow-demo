// Phase 11W.7 / Wave A2 - Operator-Web Account screen (business identity).
//
// Sibling to MyAccountScreen (sign-in identity / MFA / password / T&Cs).
// This screen owns the business-identity surface: business name, logo,
// currency, locale, and week-start day. Business day rollover values remain
// readable for compatibility, but Business Timing owns edits to
// business-day start. Every write goes
// through `WebAccountGateway.patchAccount` against the operator-scoped
// PATCH /v1/operator/account route. NO admin gateways; per-operator
// isolation is enforced both client-side (only the current scope's
// fields are shown) and server-side (RLS + scope guard).
//
// Permission gate: keys off `session.roles` and `permissions`. Owners
// and admins get the full editor; location managers see a read-only
// view with a tooltip explaining who can edit.
//
// UX writing standard: every label / explainer reads as if training
// the operator. Plain English, em-dash-free.
//
// Wave 2 U-FU-hp11-account — HP #11 (`CLAUDE.md` Hard Promise #11)
// requires every settings surface to show selected scope, source, and
// current value. The shell's top-bar Managing picker drives the active
// scope; the router forwards the choice here through
// [AccountScreen.selectedScope]. Per the operator decision logged
// 2026-05-14, business account settings are "per-location with
// business-wide fallback":
//
//   * Business scope selected — the operator edits the business
//     defaults. The summary panel says "Set here. Does not inherit
//     from a higher scope." Edit affordances stay live. Saves go to
//     PATCH /v1/operator/account (the existing operator-level write).
//   * Location scope selected — the screen loads the per-location
//     override row from
//     `GET /v1/operator/location-account-overrides/<location_id>` on
//     mount. The summary panel surfaces:
//       - the override value when set ("Set here at <location>.
//         Business default: <value>"), OR
//       - the inheritance line when no override is set ("Inherits the
//         business default from Business: <value>").
//     Save goes to PATCH /v1/operator/location-account-overrides/<id>.
//   * Business display name has no per-location override (single
//     business name doctrine) — the Identity card disables the
//     business-name field at Location scope with an inline explainer.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/permission_keys.dart';
import '../../theme/app_theme.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/business_logo_upload_gateway.dart';
import '../services/operator_web_proxy_client.dart';
import '../services/web_account_gateway.dart';
import '../widgets/business_logo_upload_section.dart';
import '../widgets/hierarchy_scope_notice.dart';
import '../widgets/operator_web_info_button.dart';
import '../widgets/operator_web_screen_header.dart';
import '../widgets/operator_web_section_heading.dart';
import '../widgets/operator_web_surface.dart';
import '../widgets/web_app_shell.dart';

// G7d (spec §2.B/§3): v2 catalog constants. Phantom
// `'operator_admin'` dropped (folded into `operator_owner`).
// Live-path neutral — authoritative gate is
// `_kAccountEditPermission`; this set is the empty-snapshot
// (demo + boot) fallback only.
const Set<String> _kAccountEditRoles = <String>{
  PermissionKeys.roleOperatorOwner,
};

const String _kAccountEditPermission = PermissionKeys.accountConfigure;

class AccountScreen extends StatefulWidget {
  const AccountScreen({
    super.key,
    required this.session,
    this.gateway,
    this.logoUploadGateway,
    this.logoFilePicker,
    this.selectedScope,
    this.onOpenBusinessTiming,
  });

  final OperatorWebSession session;

  /// Live operator-scoped write gateway. When null, the screen
  /// renders honest read-only state (the demo source ships without a
  /// live gateway). The router wires this up when the live source
  /// implements `OperatorWebAccountGatewayProvider`.
  final WebAccountGateway? gateway;

  /// Wave 2 W-5 — optional logo upload gateway. When null the
  /// upload section renders an explainer banner that the URL-paste
  /// field still works. The router wires this up when the live
  /// source provides an Azure Blob-backed uploader.
  final BusinessLogoUploadGateway? logoUploadGateway;

  /// Wave 2 W-5 — widget-test seam for the file picker. Production
  /// leaves null and the upload section uses the conditional-imported
  /// web picker.
  final BusinessLogoFilePickerFn? logoFilePicker;

  /// Opens the Business Timing surface from read-only timing summaries.
  final VoidCallback? onOpenBusinessTiming;

  /// Wave 2 U-FU-hp11-account — current management scope from the
  /// shell's top-bar Managing picker. When null (no router wiring,
  /// older test, or isolated preview), the screen assumes Business
  /// scope so existing affordances render and edits stay live. HP #11
  /// honours the operator's selected scope by rendering the summary
  /// source lines + gating edits when the schema does not yet
  /// support per-scope overrides.
  final OperatorWebManagementScopeOption? selectedScope;

  bool get canEdit =>
      session.roles.any(_kAccountEditRoles.contains) ||
      session.permissions.contains(_kAccountEditPermission);

  /// HP #11 — true when the operator picked a non-Business scope in
  /// the shell's Managing picker. The screen routes saves through the
  /// per-location overrides gateway when this is true, and through
  /// the operator-level account gateway when this is false.
  bool get scopeBelowBusiness {
    final scope = selectedScope;
    if (scope == null) return false;
    return scope.kind != OperatorWebManagementScopeKind.operator;
  }

  /// True when the selected scope is a location (not Business, not an
  /// org unit). Per the operator decision logged 2026-05-14, only the
  /// location scope carries an override row today — org-unit-scoped
  /// overrides are not on the U-FU-hp11-account-schema slice.
  bool get scopeIsLocation {
    final scope = selectedScope;
    if (scope == null) return false;
    return scope.kind == OperatorWebManagementScopeKind.location;
  }

  AccountOverrideScope? get accountOverrideScope {
    final scope = selectedScope;
    if (scope == null) return null;
    switch (scope.kind) {
      case OperatorWebManagementScopeKind.operator:
        return null;
      case OperatorWebManagementScopeKind.orgUnit:
        return AccountOverrideScope(scopeType: 'org_unit', scopeId: scope.id);
      case OperatorWebManagementScopeKind.location:
        return AccountOverrideScope(scopeType: 'location', scopeId: scope.id);
    }
  }

  /// Wave 2 U-FU-hp11-account — location id the override route writes
  /// against. Null when the operator picked Business scope (no
  /// override surface) or when the selected scope is an org unit.
  String? get locationIdForOverride {
    final scope = selectedScope;
    if (scope == null) return null;
    if (scope.kind != OperatorWebManagementScopeKind.location) return null;
    return scope.id;
  }

  /// Plain-English name of the scope target ("Brio Main", "East
  /// Region"). Falls back to the session's business name when the
  /// router has not wired a scope through (older tests, isolated
  /// previews).
  String get scopeName {
    final scope = selectedScope;
    if (scope == null) return session.businessName;
    return scope.label;
  }

  /// Maps the management-picker scope kind onto the [HierarchyScopeLevel]
  /// the notice widget understands. The shell's `operator` kind is
  /// HP #11's "Business"; `orgUnit` aligns with Region; `location`
  /// stays Location.
  HierarchyScopeLevel get scopeLevel {
    final scope = selectedScope;
    if (scope == null) return HierarchyScopeLevel.business;
    switch (scope.kind) {
      case OperatorWebManagementScopeKind.operator:
        return HierarchyScopeLevel.business;
      case OperatorWebManagementScopeKind.orgUnit:
        switch (scope.unitType) {
          case 'brand':
            return HierarchyScopeLevel.brand;
          case 'district':
            return HierarchyScopeLevel.district;
          case 'location_group':
            return HierarchyScopeLevel.group;
          case 'region':
          default:
            return HierarchyScopeLevel.region;
        }
      case OperatorWebManagementScopeKind.location:
        return HierarchyScopeLevel.location;
    }
  }

  /// HP #11 inheritance line for the per-field cards when the
  /// operator is below the business scope. Renders one of:
  ///
  ///   * null — Business scope, no inheritance line needed.
  ///   * "Inherits the business default from Business." — non-location
  ///     scope (org unit) with no override surface yet.
  ///   * `Set here at <location>. Business default: <value>.` — the
  ///     location has an override for this field group.
  ///   * `Inherits the business default from Business: <value>.` — the
  ///     location has no override; the inheritance line carries the
  ///     business default value the operator is reading.
  ///
  /// [businessDefaultDisplay] is the rendered string for the cluster
  /// (e.g. "USD / en-US" for region; "04:00 local" for business day rollover; an
  /// "ops@example.com" line for identity contact).
  /// [overrideIsSet] is true when at least one column in the field
  /// cluster has a non-null override in the loaded envelope.
  String? inheritedLabelFor({
    required bool overrideIsSet,
    required String businessDefaultDisplay,
  }) {
    if (!scopeBelowBusiness) return null;
    if (overrideIsSet) {
      return 'Set here at $scopeName. '
          'Inherited value if cleared: $businessDefaultDisplay.';
    }
    return 'Inherits from the nearest parent: $businessDefaultDisplay.';
  }

  /// HP #11 backend-only explainer surfaced inside each notice. Only
  /// rendered when the operator is below business scope AND the
  /// scope is NOT a location (because the location scope now supports
  /// real per-location overrides via this slice).
  String? backendOnlyExplainerForBusinessDefault() {
    return null;
  }

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  late TextEditingController _businessName;
  late TextEditingController _logoUrl;
  String? _currencyCode;
  String? _localeTag;
  String? _weekStartDay;
  int? _rolloverHour;

  // Wave 2 U-FU-hp11-account — location-scope override state. Loaded
  // lazily on mount when the operator picks Location scope. Editing
  // these fields at Location scope writes to the per-location
  // overrides route instead of `PATCH /v1/operator/account`.
  LocationAccountOverridesEnvelope? _locationOverrides;
  bool _locationOverridesLoading = false;
  String? _locationOverridesLoadError;
  late TextEditingController _contactEmail;
  late TextEditingController _contactPhone;

  // Wave 2 W-6 — location timezone editor state. The active value
  // seeds from the session; a custom value lives in
  // `_timezoneCustomController` so the operator can type any IANA tz
  // name not in the shortlist without losing what they typed when
  // they toggle the dropdown.
  late TextEditingController _timezoneCustomController;
  String? _selectedTimezone;
  String? _savedTimezoneValue;
  bool _timezoneSubmitting = false;
  String? _timezoneErrorMessage;
  String? _timezoneSuccessMessage;
  Timer? _timezoneSuccessTimer;

  bool _submitting = false;
  String? _errorMessage;
  String? _successMessage;
  Timer? _successTimer;

  // The set of currencies / locales / days the V1 picker exposes.
  // The proxy validator accepts any ISO 4217 / BCP 47 string; the
  // picker keeps the operator inside a sane shortlist.
  static const List<_OptionPair> _currencies = <_OptionPair>[
    _OptionPair('USD', 'US dollar (USD)'),
    _OptionPair('CAD', 'Canadian dollar (CAD)'),
    _OptionPair('EUR', 'Euro (EUR)'),
    _OptionPair('GBP', 'Pound sterling (GBP)'),
    _OptionPair('AUD', 'Australian dollar (AUD)'),
    _OptionPair('MXN', 'Mexican peso (MXN)'),
  ];

  static const List<_OptionPair> _locales = <_OptionPair>[
    _OptionPair('en-US', 'English (United States)'),
    _OptionPair('en-CA', 'English (Canada)'),
    _OptionPair('fr-CA', 'French (Canada)'),
    _OptionPair('en-GB', 'English (United Kingdom)'),
    _OptionPair('en-AU', 'English (Australia)'),
    _OptionPair('es-MX', 'Spanish (Mexico)'),
  ];

  // Wave 2 W-6 — North American + common European shortlist. Operators
  // outside this list can type any IANA tz name in the custom field;
  // the backend validates against the full tz database.
  static const List<_OptionPair> _timezoneShortlist = <_OptionPair>[
    _OptionPair('America/Toronto', 'Toronto / Montreal (Eastern)'),
    _OptionPair('America/New_York', 'New York / Atlanta (Eastern)'),
    _OptionPair('America/Chicago', 'Chicago / Dallas (Central)'),
    _OptionPair('America/Denver', 'Denver / Calgary (Mountain)'),
    _OptionPair('America/Phoenix', 'Phoenix (Mountain, no DST)'),
    _OptionPair('America/Los_Angeles', 'Los Angeles / Vancouver (Pacific)'),
    _OptionPair('America/Anchorage', 'Anchorage (Alaska)'),
    _OptionPair('America/Halifax', 'Halifax (Atlantic)'),
    _OptionPair('America/St_Johns', "St. John's (Newfoundland)"),
    _OptionPair('America/Mexico_City', 'Mexico City (Central)'),
    _OptionPair('Europe/London', 'London / Dublin'),
    _OptionPair('Europe/Paris', 'Paris / Berlin / Madrid'),
    _OptionPair('Australia/Sydney', 'Sydney / Melbourne'),
    _OptionPair('UTC', 'UTC (no offset)'),
  ];

  // Sentinel value the dropdown uses when the operator has typed a
  // custom timezone not in [_timezoneShortlist]. The dropdown stays
  // visible, and the custom text field below it owns the live value.
  static const String _timezoneCustomSentinel = '__custom__';

  @override
  void initState() {
    super.initState();
    _businessName = TextEditingController(text: widget.session.businessName);
    _logoUrl = TextEditingController(text: widget.session.logoUrl ?? '');
    _currencyCode = widget.session.currencyCode;
    _localeTag = widget.session.localeTag;
    _weekStartDay = widget.session.weekStartDay;
    _rolloverHour = widget.session.rolloverHour;
    // Wave 2 W-6 — seed timezone state from the session. Drop the
    // initial value onto either the shortlist dropdown or the custom
    // text field depending on whether it appears in
    // [_timezoneShortlist].
    final initialTimezone = widget.session.primaryLocationTimezone?.trim();
    _savedTimezoneValue = initialTimezone;
    final hasInShortlist =
        initialTimezone != null &&
        initialTimezone.isNotEmpty &&
        _timezoneShortlist.any((opt) => opt.value == initialTimezone);
    _selectedTimezone = hasInShortlist
        ? initialTimezone
        : (initialTimezone == null || initialTimezone.isEmpty
              ? null
              : _timezoneCustomSentinel);
    _timezoneCustomController = TextEditingController(
      text: hasInShortlist ? '' : (initialTimezone ?? ''),
    );
    _contactEmail = TextEditingController();
    _contactPhone = TextEditingController();
    // Wave 2 U-FU-hp11-account — preload per-location overrides when
    // the router opens this screen at Location scope.
    if (widget.scopeBelowBusiness && widget.gateway != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadScopeOverrides();
      });
    } else if (widget.gateway != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadBusinessAccount();
      });
    }
  }

  @override
  void didUpdateWidget(AccountScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousSessionTimezone = oldWidget.session.primaryLocationTimezone
        ?.trim();
    final nextSessionTimezone = widget.session.primaryLocationTimezone?.trim();
    if (previousSessionTimezone != nextSessionTimezone) {
      _savedTimezoneValue = nextSessionTimezone;
    }
    // Reload overrides when the operator flips the Managing picker
    // between scopes. Loading is a no-op at Business scope.
    if (oldWidget.selectedScope?.id != widget.selectedScope?.id ||
        oldWidget.selectedScope?.kind != widget.selectedScope?.kind) {
      if (widget.scopeBelowBusiness && widget.gateway != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadScopeOverrides();
        });
      } else {
        setState(() {
          _locationOverrides = null;
          _locationOverridesLoadError = null;
          _contactEmail.text = '';
          _contactPhone.text = '';
        });
        if (widget.gateway != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _loadBusinessAccount();
          });
        }
      }
    }
  }

  WebAccountScopeOverridesGateway? get _scopeOverridesGateway {
    final gateway = widget.gateway;
    if (gateway is WebAccountScopeOverridesGateway) {
      return gateway as WebAccountScopeOverridesGateway;
    }
    return null;
  }

  void _applyAccountIdentity(AccountIdentity identity) {
    _businessName.text = identity.businessName;
    _logoUrl.text = identity.logoUrl ?? '';
    _currencyCode = identity.currencyCode;
    _localeTag = identity.localeTag;
    _weekStartDay = identity.weekStartDay;
    _rolloverHour = identity.rolloverHour;
    _contactEmail.text = identity.contactEmail ?? '';
    _contactPhone.text = identity.contactPhone ?? '';
  }

  Future<void> _loadBusinessAccount() async {
    final gateway = widget.gateway;
    if (gateway == null || widget.scopeBelowBusiness) return;
    try {
      final identity = await gateway.getAccount();
      if (!mounted || widget.scopeBelowBusiness) return;
      setState(() => _applyAccountIdentity(identity));
    } catch (_) {
      // The session still contains enough identity defaults to render. Save
      // continues to surface live proxy errors through the normal form path.
    }
  }

  Future<void> _loadScopeOverrides() async {
    final gateway = widget.gateway;
    if (gateway == null) return;
    final scopeGateway = _scopeOverridesGateway;
    final scope = widget.accountOverrideScope;
    final locationId = widget.locationIdForOverride;
    if (widget.scopeBelowBusiness &&
        scopeGateway == null &&
        locationId == null) {
      return;
    }
    if (scope == null) return;
    if (scopeGateway == null && locationId == null) return;
    setState(() {
      _locationOverridesLoading = true;
      _locationOverridesLoadError = null;
    });
    try {
      final useScopeGateway = scopeGateway != null && !widget.scopeIsLocation;
      final envelope = useScopeGateway
          ? await scopeGateway.getAccountScopeOverrides(scope: scope)
          : await gateway.getLocationAccountOverrides(locationId: locationId!);
      if (!mounted) return;
      setState(() {
        _locationOverrides = envelope;
        _locationOverridesLoading = false;
        // Seed the form controllers with the current override values
        // (fall back to business defaults so the operator can edit
        // from the inherited starting point).
        _seedAccountFormFromEnvelope(envelope);
      });
    } on OperatorWebProxyException catch (error) {
      if (!mounted) return;
      setState(() {
        _locationOverridesLoading = false;
        _locationOverridesLoadError = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _locationOverridesLoading = false;
        _locationOverridesLoadError =
            'Could not load this scope\'s account overrides: $error';
      });
    }
  }

  void _seedTimezoneDraft(String? value) {
    final trimmed = value?.trim();
    final hasInShortlist =
        trimmed != null &&
        trimmed.isNotEmpty &&
        _timezoneShortlist.any((opt) => opt.value == trimmed);
    _selectedTimezone = hasInShortlist
        ? trimmed
        : (trimmed == null || trimmed.isEmpty ? null : _timezoneCustomSentinel);
    _timezoneCustomController.text = hasInShortlist ? '' : (trimmed ?? '');
  }

  /// Seeds the editable form controllers from [envelope], preferring the
  /// scope's own override and falling back to the inherited business
  /// default. Shared by the initial load and the reset-to-inherited path.
  void _seedAccountFormFromEnvelope(LocationAccountOverridesEnvelope envelope) {
    _currencyCode =
        envelope.override.currencyCode ??
        envelope.businessDefault.currencyCode ??
        _currencyCode;
    _localeTag =
        envelope.override.localeCode ??
        envelope.businessDefault.localeCode ??
        _localeTag;
    _rolloverHour =
        envelope.override.businessDayRolloverHour ??
        envelope.businessDefault.businessDayRolloverHour ??
        _rolloverHour;
    _contactEmail.text =
        envelope.override.contactEmail ??
        envelope.businessDefault.contactEmail ??
        '';
    _contactPhone.text =
        envelope.override.contactPhone ??
        envelope.businessDefault.contactPhone ??
        '';
    _savedTimezoneValue =
        envelope.override.ianaTimezone ??
        envelope.businessDefault.ianaTimezone ??
        _savedTimezoneValue;
    _seedTimezoneDraft(_savedTimezoneValue);
  }

  /// True when the current below-business scope has at least one account
  /// value set locally, so reverting to the inherited value is meaningful.
  bool get _scopeHasOverride {
    final override = _locationOverrides?.override;
    if (override == null) return false;
    return override.currencyCode != null ||
        override.localeCode != null ||
        override.businessDayRolloverHour != null ||
        override.contactEmail != null ||
        override.contactPhone != null ||
        override.ianaTimezone != null;
  }

  /// Clears every account override at the current scope so the values
  /// fall back to the ones inherited from the higher scope. Only valid
  /// below Business scope (Business has no parent to inherit from).
  Future<void> _handleResetToInherited() async {
    final gateway = widget.gateway;
    final scope = widget.accountOverrideScope;
    if (gateway == null || !widget.canEdit || scope == null) return;
    if (!widget.scopeBelowBusiness) return;
    final scopeGateway = _scopeOverridesGateway;
    final locationId = widget.locationIdForOverride;
    if (scopeGateway == null && locationId == null) return;

    final confirmed = await showOperatorWebDialog<bool>(
      context: context,
      title: 'Use inherited values?',
      icon: Icons.undo_outlined,
      child: Text(
        'This clears the custom account values set for ${widget.scopeName} '
        'and goes back to the values inherited from the higher scope. You '
        'can set custom values again whenever you need to.',
        style: AppTextStyles.body13(color: AppColors.textPrimary),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('operator_web_account_reset_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('operator_web_account_reset_confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.sunset,
            foregroundColor: AppColors.backgroundSurface,
          ),
          child: const Text('Use inherited values'),
        ),
      ],
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _submitting = true;
      _errorMessage = null;
      _successMessage = null;
    });
    try {
      final patch = LocationAccountOverridesPatchPayload(
        clearCurrencyCode: true,
        clearLocaleCode: true,
        clearIanaTimezone: true,
        clearBusinessDayRolloverHour: true,
        clearContactEmail: true,
        clearContactPhone: true,
      );
      final useScopeGateway = scopeGateway != null && !widget.scopeIsLocation;
      final envelope = useScopeGateway
          ? await scopeGateway.patchAccountScopeOverrides(
              scope: scope,
              patch: patch,
            )
          : await gateway.patchLocationAccountOverrides(
              locationId: locationId!,
              patch: patch,
            );
      if (!mounted) return;
      _successTimer?.cancel();
      setState(() {
        _locationOverrides = envelope;
        _seedAccountFormFromEnvelope(envelope);
        _submitting = false;
        _successMessage =
            'Done. ${widget.scopeName} now uses the inherited values.';
      });
      _successTimer = Timer(const Duration(seconds: 4), () {
        if (!mounted) return;
        setState(() => _successMessage = null);
      });
    } on OperatorWebProxyException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = 'Could not reset to the inherited values: $error';
      });
    }
  }

  @override
  void dispose() {
    _businessName.dispose();
    _logoUrl.dispose();
    _timezoneCustomController.dispose();
    _contactEmail.dispose();
    _contactPhone.dispose();
    _successTimer?.cancel();
    _timezoneSuccessTimer?.cancel();
    super.dispose();
  }

  bool get _hasGateway => widget.gateway != null;

  bool _draftDiffers(String? draft, String? saved) {
    final normalizedDraft = draft?.trim() ?? '';
    final normalizedSaved = saved?.trim() ?? '';
    return normalizedDraft != normalizedSaved;
  }

  String _unsavedSourceLabel(String settingLabel) {
    return 'Unsaved change here. Save to set $settingLabel at '
        '${_scopeLevelLabel(widget.scopeLevel)}: ${widget.scopeName}.';
  }

  String _scopeLevelLabel(HierarchyScopeLevel level) {
    switch (level) {
      case HierarchyScopeLevel.business:
        return 'Business';
      case HierarchyScopeLevel.brand:
        return 'Brand';
      case HierarchyScopeLevel.region:
        return 'Region';
      case HierarchyScopeLevel.district:
        return 'District';
      case HierarchyScopeLevel.group:
        return 'Location group';
      case HierarchyScopeLevel.location:
        return 'Location';
    }
  }

  String? _savedSourceLabelForGroup(
    List<_AccountSourcePart> parts, {
    String? fallback,
  }) {
    if (!widget.scopeBelowBusiness) return null;
    final withSource = <_AccountSourcePart>[
      for (final part in parts)
        if (part.source != null) part,
    ];
    if (withSource.isEmpty) return fallback;
    final first = withSource.first.source!;
    final allSame = withSource.every(
      (part) => _sameSource(part.source!, first),
    );
    if (allSame) return _sourceSentence(first);
    final phrases = <String>[
      for (final part in withSource)
        '${part.label} ${_sourcePhrase(part.source!)}',
    ];
    return '${phrases.join('; ')}.';
  }

  bool _sameSource(
    LocationAccountOverridesFieldSource left,
    LocationAccountOverridesFieldSource right,
  ) {
    return left.scopeType == right.scopeType &&
        left.scopeId == right.scopeId &&
        left.scopeLabel == right.scopeLabel &&
        left.setHere == right.setHere;
  }

  String _sourceSentence(LocationAccountOverridesFieldSource source) {
    final owner = _sourceOwnerLabel(source);
    return source.setHere ? 'Set here at $owner.' : 'Inherited from $owner.';
  }

  String _sourcePhrase(LocationAccountOverridesFieldSource source) {
    final owner = _sourceOwnerLabel(source);
    return source.setHere ? 'set here at $owner' : 'from $owner';
  }

  String _sourceOwnerLabel(LocationAccountOverridesFieldSource source) {
    return '${_sourceTypeLabel(source.scopeType)}: ${source.scopeLabel}';
  }

  String _sourceTypeLabel(String scopeType) {
    switch (scopeType) {
      case 'business':
        return 'Business';
      case 'brand':
        return 'Brand';
      case 'region':
        return 'Region';
      case 'district':
        return 'District';
      case 'location_group':
        return 'Location group';
      case 'location':
        return 'Location';
      default:
        return 'Hierarchy scope';
    }
  }

  Future<void> _handleSave() async {
    final gateway = widget.gateway;
    if (gateway == null || !widget.canEdit) return;
    // Wave 2 U-FU-hp11-account — route the save to the correct
    // gateway based on selected scope. Business scope writes to the
    // operator-level account row; Location scope writes to the per-
    // location override row.
    final locationId = widget.locationIdForOverride;
    final scopeGateway = _scopeOverridesGateway;
    final scope = widget.accountOverrideScope;
    if (widget.scopeBelowBusiness &&
        scopeGateway == null &&
        locationId == null) {
      return;
    }
    setState(() {
      _submitting = true;
      _errorMessage = null;
      _successMessage = null;
    });
    try {
      if (widget.scopeBelowBusiness && scope != null) {
        final patch = LocationAccountOverridesPatchPayload(
          // Currency / locale ride along when set. Business-day start
          // now lives in Business Timing, so Account saves do not
          // write rollover overrides. Business display name + logo
          // are operator-wide; the Identity card disables those
          // fields below Business scope.
          currencyCode: _currencyCode,
          localeCode: _localeTag,
          contactEmail: _contactEmail.text.trim().isEmpty
              ? null
              : _contactEmail.text.trim(),
          clearContactEmail: _contactEmail.text.trim().isEmpty,
          contactPhone: _contactPhone.text.trim().isEmpty
              ? null
              : _contactPhone.text.trim(),
          clearContactPhone: _contactPhone.text.trim().isEmpty,
        );
        final useScopeGateway = scopeGateway != null && !widget.scopeIsLocation;
        final envelope = useScopeGateway
            ? await scopeGateway.patchAccountScopeOverrides(
                scope: scope,
                patch: patch,
              )
            : await gateway.patchLocationAccountOverrides(
                locationId: locationId!,
                patch: patch,
              );
        if (!mounted) return;
        setState(() {
          _locationOverrides = envelope;
        });
      } else {
        final patch = AccountIdentityPatch(
          businessName: _businessName.text.trim().isEmpty
              ? null
              : _businessName.text.trim(),
          logoUrl: _logoUrl.text.trim().isEmpty ? null : _logoUrl.text.trim(),
          clearLogo: _logoUrl.text.trim().isEmpty,
          currencyCode: _currencyCode,
          localeTag: _localeTag,
          contactEmail: _contactEmail.text.trim().isEmpty
              ? null
              : _contactEmail.text.trim(),
          clearContactEmail: _contactEmail.text.trim().isEmpty,
          contactPhone: _contactPhone.text.trim().isEmpty
              ? null
              : _contactPhone.text.trim(),
          clearContactPhone: _contactPhone.text.trim().isEmpty,
        );
        final identity = await gateway.patchAccount(patch);
        if (!mounted) return;
        setState(() => _applyAccountIdentity(identity));
      }
    } on OperatorWebProxyException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = 'Could not save your business account: $error';
      });
      return;
    }
    if (!mounted) return;
    _successTimer?.cancel();
    setState(() {
      _submitting = false;
      _successMessage = 'Saved. Your changes are live.';
    });
    _successTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _successMessage = null);
    });
  }

  /// Resolves the value the timezone editor will send to the gateway.
  /// When the dropdown is on the custom sentinel, the custom field's
  /// trimmed text is the canonical value; otherwise the dropdown
  /// value wins.
  String _effectiveTimezoneValue() {
    if (_selectedTimezone == _timezoneCustomSentinel) {
      return _timezoneCustomController.text.trim();
    }
    return _selectedTimezone?.trim() ?? '';
  }

  Future<void> _handleSaveTimezone() async {
    final gateway = widget.gateway;
    if (gateway == null || !widget.canEdit) return;
    final value = _effectiveTimezoneValue();
    if (value.isEmpty) {
      setState(() {
        _timezoneErrorMessage =
            'Pick a timezone from the list, or type the IANA name '
            '(for example, America/Toronto) before saving.';
        _timezoneSuccessMessage = null;
      });
      return;
    }
    setState(() {
      _timezoneSubmitting = true;
      _timezoneErrorMessage = null;
      _timezoneSuccessMessage = null;
    });
    try {
      String savedTimezoneValue;
      final scopeGateway = _scopeOverridesGateway;
      final scope = widget.accountOverrideScope;
      if (widget.scopeBelowBusiness &&
          scope != null &&
          !widget.scopeIsLocation &&
          scopeGateway != null) {
        final envelope = await scopeGateway.patchAccountScopeOverrides(
          scope: scope,
          patch: LocationAccountOverridesPatchPayload(ianaTimezone: value),
        );
        if (!mounted) return;
        _locationOverrides = envelope;
        savedTimezoneValue = envelope.effective.ianaTimezone ?? value;
      } else if (widget.scopeBelowBusiness &&
          widget.scopeIsLocation &&
          widget.locationIdForOverride != null) {
        final envelope = await gateway.patchLocationAccountOverrides(
          locationId: widget.locationIdForOverride!,
          patch: LocationAccountOverridesPatchPayload(ianaTimezone: value),
        );
        if (!mounted) return;
        _locationOverrides = envelope;
        savedTimezoneValue = envelope.effective.ianaTimezone ?? value;
      } else {
        final savedTimezone = await gateway.patchLocationTimezone(
          AccountLocationTimezonePatch(ianaTimezone: value),
        );
        savedTimezoneValue = savedTimezone.ianaTimezone.trim();
      }
      if (!mounted) return;
      _timezoneSuccessTimer?.cancel();
      setState(() {
        _savedTimezoneValue = savedTimezoneValue;
        _timezoneSubmitting = false;
        _timezoneSuccessMessage =
            'Saved. Daily timing now uses $savedTimezoneValue for '
            '${widget.scopeName}.';
      });
      _timezoneSuccessTimer = Timer(const Duration(seconds: 4), () {
        if (!mounted) return;
        setState(() => _timezoneSuccessMessage = null);
      });
      return;
    } on OperatorWebProxyException catch (error) {
      if (!mounted) return;
      setState(() {
        _timezoneSubmitting = false;
        _timezoneErrorMessage = error.message;
      });
      return;
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _timezoneSubmitting = false;
        _timezoneErrorMessage =
            'Could not save the timezone for this scope: $error';
      });
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Edits are enabled when this screen has the write gateway for the
    // selected scope: Business writes operator-level account fields,
    // Location writes location overrides, and org units write scoped
    // account overrides.
    final scopeBelowBusiness = widget.scopeBelowBusiness;
    final scopeIsLocation = widget.scopeIsLocation;
    final lowerScopeEditable =
        !scopeBelowBusiness ||
        scopeIsLocation ||
        _scopeOverridesGateway != null;
    // Business display name + logo are operator-wide (single business
    // name doctrine); the Identity card disables those two fields at
    // Location scope. Contact email + phone are the location-scoped
    // identity surface.
    final identityNameEnabled =
        widget.canEdit && !_submitting && !scopeBelowBusiness;
    final identityContactEnabled =
        widget.canEdit && !_submitting && lowerScopeEditable;
    final regionEnabled = widget.canEdit && !_submitting && lowerScopeEditable;
    // Helpers for the Account scope summary source lines. At Business scope
    // the helper returns null (no inheritance), so the notice falls
    // back to "Set here. Does not inherit from a higher scope."
    final overrides = _locationOverrides;
    final savedIdentityContactEmail = overrides == null
        ? ''
        : overrides.override.contactEmail ??
              overrides.businessDefault.contactEmail ??
              '';
    final savedIdentityContactPhone = overrides == null
        ? ''
        : overrides.override.contactPhone ??
              overrides.businessDefault.contactPhone ??
              '';
    final identityDraftChanged =
        scopeBelowBusiness &&
        overrides != null &&
        (_draftDiffers(_contactEmail.text, savedIdentityContactEmail) ||
            _draftDiffers(_contactPhone.text, savedIdentityContactPhone));
    final regionOverrideSet =
        overrides != null &&
        (overrides.override.currencyCode != null ||
            overrides.override.localeCode != null);
    // `U-FU-hp11-account-demo-defaults` (2026-05-14): defend against
    // null session values so a brand-new operator (no projected
    // currency / locale / business day rollover yet) sees "no currency" /
    // "no rollover hour" instead of literal "null". The non-overrides
    // branch above already handles this via `?? "no currency"`; mirror
    // it here for the session-fallback branch.
    final regionBusinessDefault = overrides == null
        ? '${widget.session.currencyCode ?? "no currency"} / '
              '${widget.session.localeTag ?? "no locale"}'
        : '${overrides.businessDefault.currencyCode ?? "no currency"} / '
              '${overrides.businessDefault.localeCode ?? "no locale"}';
    final savedRegionCurrency = overrides == null
        ? widget.session.currencyCode
        : overrides.override.currencyCode ??
              overrides.businessDefault.currencyCode ??
              widget.session.currencyCode;
    final savedRegionLocale = overrides == null
        ? widget.session.localeTag
        : overrides.override.localeCode ??
              overrides.businessDefault.localeCode ??
              widget.session.localeTag;
    final regionDraftChanged =
        scopeBelowBusiness &&
        overrides != null &&
        (_draftDiffers(_currencyCode, savedRegionCurrency) ||
            _draftDiffers(_localeTag, savedRegionLocale));
    final businessDayOverrideSet =
        overrides != null && overrides.override.businessDayRolloverHour != null;
    final businessDayBusinessDefault = overrides == null
        ? (widget.session.rolloverHour == null
              ? 'no rollover hour'
              : '${widget.session.rolloverHour!.toString().padLeft(2, '0')}:00 local')
        : (overrides.businessDefault.businessDayRolloverHour == null
              ? 'no rollover hour'
              : '${overrides.businessDefault.businessDayRolloverHour!.toString().padLeft(2, '0')}:00 local');
    final identityOverrideSet =
        overrides != null &&
        (overrides.override.contactEmail != null ||
            overrides.override.contactPhone != null);
    final identityBusinessDefault = overrides == null
        ? widget.session.businessName
        : (overrides.businessDefault.contactEmail ??
              widget.session.businessName);
    final identityInheritedLabel = _savedSourceLabelForGroup(
      <_AccountSourcePart>[
        _AccountSourcePart('Email', overrides?.sources.contactEmail),
        _AccountSourcePart('Phone', overrides?.sources.contactPhone),
      ],
      fallback: widget.inheritedLabelFor(
        overrideIsSet: identityOverrideSet,
        businessDefaultDisplay: identityBusinessDefault,
      ),
    );
    final identitySourceLabel = identityDraftChanged
        ? _unsavedSourceLabel('these contact details')
        : identityInheritedLabel;
    final regionInheritedLabel = regionDraftChanged
        ? _unsavedSourceLabel('these formatting settings')
        : _savedSourceLabelForGroup(
            <_AccountSourcePart>[
              _AccountSourcePart('Currency', overrides?.sources.currencyCode),
              _AccountSourcePart('Locale', overrides?.sources.localeCode),
            ],
            fallback: widget.inheritedLabelFor(
              overrideIsSet: regionOverrideSet,
              businessDefaultDisplay: regionBusinessDefault,
            ),
          );
    final businessDayInheritedLabel = _savedSourceLabelForGroup(
      <_AccountSourcePart>[
        _AccountSourcePart(
          'Business day rollover',
          overrides?.sources.businessDayRolloverHour,
        ),
      ],
      fallback: widget.inheritedLabelFor(
        overrideIsSet: businessDayOverrideSet,
        businessDefaultDisplay: businessDayBusinessDefault,
      ),
    );
    final timezoneEffectiveValue = _effectiveTimezoneValue();
    final savedTimezoneDisplay = _savedTimezoneValue?.trim();
    final timezoneDefaultDisplay = overrides == null
        ? (savedTimezoneDisplay == null || savedTimezoneDisplay.isEmpty
              ? 'no timezone'
              : savedTimezoneDisplay)
        : (overrides.businessDefault.ianaTimezone ?? 'no timezone');
    final timezoneInheritedLabel =
        _draftDiffers(timezoneEffectiveValue, _savedTimezoneValue)
        ? 'Unsaved change here. Save timezone to set it at '
              '${_scopeLevelLabel(widget.scopeLevel)}: ${widget.scopeName}.'
        : _savedSourceLabelForGroup(
            <_AccountSourcePart>[
              _AccountSourcePart('Timezone', overrides?.sources.ianaTimezone),
            ],
            fallback: widget.inheritedLabelFor(
              overrideIsSet: overrides?.override.ianaTimezone != null,
              businessDefaultDisplay: timezoneDefaultDisplay,
            ),
          );
    return SingleChildScrollView(
      key: const Key('operator_web_account_screen'),
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const OperatorWebScreenHeader(
            icon: Icons.business_outlined,
            title: 'Business account',
          ),
          const SizedBox(height: 18),
          if (!_hasGateway) const _UnavailableBanner(),
          if (!_hasGateway) const SizedBox(height: 14),
          if (!widget.canEdit) const _ReadOnlyBanner(),
          if (!widget.canEdit) const SizedBox(height: 14),
          if (_locationOverridesLoading)
            const _LocationOverridesLoadingBanner(),
          if (_locationOverridesLoading) const SizedBox(height: 14),
          if (_locationOverridesLoadError != null)
            _LocationOverridesErrorBanner(
              message: _locationOverridesLoadError!,
            ),
          if (_locationOverridesLoadError != null) const SizedBox(height: 14),
          _BusinessIdentitySection(
            businessNameController: _businessName,
            logoUrlController: _logoUrl,
            contactEmailController: _contactEmail,
            contactPhoneController: _contactPhone,
            logoLivePreviewUrl: _logoUrl.text.trim().isEmpty
                ? null
                : _logoUrl.text.trim(),
            nameAndLogoEnabled: identityNameEnabled,
            contactEnabled: identityContactEnabled,
            scopeBelowBusiness: scopeBelowBusiness,
            scopeLabel: _scopeLevelLabel(widget.scopeLevel),
            sourceStatus: _compactSourceStatus(
              _sourceLabel(identitySourceLabel),
            ),
            onChanged: () => setState(() {}),
            logoUploadGateway: widget.logoUploadGateway,
            logoFilePicker: widget.logoFilePicker,
            logoUploadDisabledReason: scopeBelowBusiness
                ? 'Logo changes are set at the Business level. Switch '
                      'Managing to All locations to upload a PNG.'
                : null,
            onLogoUploaded: (url) {
              // Wave 2 W-5: the upload section uploaded the file to
              // Azure Blob and got back a URL. Drop it into the
              // existing controller so the next "Save business
              // account" PATCH commits it to public.operators.
              setState(() {
                _logoUrl.text = url;
              });
            },
          ),
          const SizedBox(height: 14),
          _RegionSection(
            currencyCode: _currencyCode,
            localeTag: _localeTag,
            currencies: _currencies,
            locales: _locales,
            enabled: regionEnabled,
            onCurrencyChanged: (value) => setState(() => _currencyCode = value),
            onLocaleChanged: (value) => setState(() => _localeTag = value),
            sourceStatus: _compactSourceStatus(
              _sourceLabel(regionInheritedLabel),
            ),
          ),
          const SizedBox(height: 14),
          _BusinessDaySection(
            weekStartDay: _weekStartDay,
            rolloverHour: _rolloverHour,
            onOpenBusinessTiming: widget.onOpenBusinessTiming,
            sourceStatus: _compactSourceStatus(
              _sourceLabel(businessDayInheritedLabel),
            ),
          ),
          const SizedBox(height: 14),
          _LocationTimezoneSection(
            scopeLabel: _scopeLevelLabel(widget.scopeLevel),
            scopeName: widget.scopeName,
            selectedValue: _selectedTimezone,
            customController: _timezoneCustomController,
            shortlist: _timezoneShortlist,
            customSentinel: _timezoneCustomSentinel,
            enabled:
                widget.canEdit &&
                _hasGateway &&
                !_timezoneSubmitting &&
                lowerScopeEditable,
            submitting: _timezoneSubmitting,
            errorMessage: _timezoneErrorMessage,
            successMessage: _timezoneSuccessMessage,
            onShortlistChanged: (value) =>
                setState(() => _selectedTimezone = value),
            onCustomChanged: () => setState(() {}),
            onSave: _handleSaveTimezone,
            onOpenBusinessTiming: widget.onOpenBusinessTiming,
            sourceStatus: _compactSourceStatus(
              _sourceLabel(timezoneInheritedLabel),
            ),
          ),
          const SizedBox(height: 18),
          if (_errorMessage != null)
            Container(
              key: const Key('operator_web_account_error'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.negative.withValues(alpha: 0.10),
                border: Border.all(
                  color: AppColors.negative.withValues(alpha: 0.45),
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 16,
                    color: AppColors.negative,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: AppTextStyles.body13(color: AppColors.negative),
                    ),
                  ),
                ],
              ),
            ),
          if (_successMessage != null)
            Container(
              key: const Key('operator_web_account_success'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.positive.withValues(alpha: 0.10),
                border: Border.all(
                  color: AppColors.positive.withValues(alpha: 0.45),
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.check_circle_outline,
                    size: 16,
                    color: AppColors.positive,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _successMessage!,
                      style: AppTextStyles.body13(color: AppColors.positive),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  height: 42,
                  child: FilledButton(
                    key: const Key('operator_web_account_save'),
                    onPressed:
                        widget.canEdit &&
                            _hasGateway &&
                            !_submitting &&
                            lowerScopeEditable
                        ? _handleSave
                        : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.sunset,
                      foregroundColor: AppColors.backgroundSurface,
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.backgroundSurface,
                            ),
                          )
                        : const Text('Save business account'),
                  ),
                ),
                if (widget.scopeBelowBusiness)
                  SizedBox(
                    height: 42,
                    child: OutlinedButton.icon(
                      key: const Key('operator_web_account_reset_to_inherited'),
                      onPressed:
                          widget.canEdit &&
                              _hasGateway &&
                              !_submitting &&
                              lowerScopeEditable &&
                              _scopeHasOverride
                          ? _handleResetToInherited
                          : null,
                      icon: const Icon(Icons.undo_outlined, size: 16),
                      label: const Text('Use inherited values'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.sunsetDark,
                        side: const BorderSide(
                          color: AppColors.sunsetDark,
                          width: 1,
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _sourceLabel(String? inheritedLabel) {
    return inheritedLabel ?? 'Set here. Does not inherit from a higher scope.';
  }

  static String _compactSourceStatus(String sourceLabel) {
    final lower = sourceLabel.toLowerCase();
    if (lower.startsWith('unsaved')) return 'Unsaved';
    if (lower.startsWith('set here') || lower.contains('set here at')) {
      return 'Set here';
    }
    if (lower.contains('inherit') ||
        lower.contains('business default') ||
        lower.contains(' from ')) {
      return 'Inherited';
    }
    return 'Source';
  }
}

class _AccountSourcePart {
  const _AccountSourcePart(this.label, this.source);

  final String label;
  final LocationAccountOverridesFieldSource? source;
}

class _UnavailableBanner extends StatelessWidget {
  const _UnavailableBanner();
  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_account_unavailable'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, size: 18, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Live editing is not connected yet on this build. You can '
              'review the current values, but Save is disabled until the '
              'operator account write route is online.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _LocationOverridesLoadingBanner extends StatelessWidget {
  const _LocationOverridesLoadingBanner();
  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_account_overrides_loading'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Loading this scope\'s account overrides...',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _LocationOverridesErrorBanner extends StatelessWidget {
  const _LocationOverridesErrorBanner({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_account_overrides_load_error'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.10),
        border: Border.all(color: AppColors.negative.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(8),
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
  const _ReadOnlyBanner();
  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_account_readonly'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, size: 18, color: AppColors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'You can view your business account. Only operator owners '
              'and admins can change these settings.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _BusinessIdentitySection extends StatelessWidget {
  const _BusinessIdentitySection({
    required this.businessNameController,
    required this.logoUrlController,
    required this.contactEmailController,
    required this.contactPhoneController,
    required this.logoLivePreviewUrl,
    required this.nameAndLogoEnabled,
    required this.contactEnabled,
    required this.scopeBelowBusiness,
    required this.scopeLabel,
    required this.sourceStatus,
    required this.onChanged,
    required this.onLogoUploaded,
    this.logoUploadGateway,
    this.logoFilePicker,
    this.logoUploadDisabledReason,
  });

  final TextEditingController businessNameController;
  final TextEditingController logoUrlController;

  /// Wave 2 U-FU-hp11-account — location-scoped contact email + phone
  /// controllers. Only rendered at Location scope.
  final TextEditingController contactEmailController;
  final TextEditingController contactPhoneController;
  final String? logoLivePreviewUrl;

  /// Whether the business name + logo URL fields are editable. False
  /// at Location scope (single business name doctrine).
  final bool nameAndLogoEnabled;

  /// Whether the contact email + phone fields are editable. True at
  /// Business scope (writes to operators) and at Location scope
  /// (writes to location_account_overrides).
  final bool contactEnabled;

  /// Wave 2 U-FU-hp11-account — true when the selected scope is a
  /// location. Drives whether the contact email + phone fields show
  /// up at all (they only render at Business or Location scope) and
  /// whether the business-name carve-out explainer is rendered.
  final bool scopeBelowBusiness;
  final String scopeLabel;
  final String sourceStatus;

  final VoidCallback onChanged;
  final ValueChanged<String> onLogoUploaded;
  final BusinessLogoUploadGateway? logoUploadGateway;
  final BusinessLogoFilePickerFn? logoFilePicker;
  final String? logoUploadDisabledReason;

  @override
  Widget build(BuildContext context) {
    return _Card(
      cardKey: const Key('operator_web_account_section_identity'),
      title: 'Business identity',
      subtitle: '',
      sourceStatus: sourceStatus,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _AccountSubheading(
            title: 'How your business shows up across Forge & Flow',
            body: 'The name appears on every dashboard heading.',
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('operator_web_account_business_name'),
            controller: businessNameController,
            enabled: nameAndLogoEnabled,
            inputFormatters: <TextInputFormatter>[
              LengthLimitingTextInputFormatter(120),
            ],
            decoration: InputDecoration(
              labelText: 'Business name',
              border: const OutlineInputBorder(),
              helperText: scopeBelowBusiness
                  ? 'The business name is set at the Business level.'
                  : 'Up to 120 characters.',
            ),
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: 12),
          // Wave 2 W-5 — file upload section. Sits above the URL
          // paste field so the upload UX reads as the recommended
          // path. After a successful upload the resulting URL is
          // copied into [logoUrlController] and the regular Save
          // button persists it.
          const _AccountSubheading(
            title: 'Logo',
            body:
                'The logo shows in the console header and the mobile app header.',
          ),
          const SizedBox(height: 10),
          BusinessLogoUploadSection(
            gateway: logoUploadGateway,
            enabled: nameAndLogoEnabled,
            onUploaded: onLogoUploaded,
            filePicker: logoFilePicker,
            disabledReason: logoUploadDisabledReason,
          ),
          const SizedBox(height: 10),
          const _AccountSubheading(
            title: 'Paste a public https link to your logo',
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('operator_web_account_logo_url'),
            controller: logoUrlController,
            enabled: nameAndLogoEnabled,
            inputFormatters: <TextInputFormatter>[
              LengthLimitingTextInputFormatter(2048),
            ],
            decoration: const InputDecoration(
              labelText: 'Logo link',
              border: OutlineInputBorder(),
              helperText: 'Use a public https link. Leave empty to clear it.',
            ),
            onChanged: (_) => onChanged(),
          ),
          if (logoLivePreviewUrl != null) ...[
            const SizedBox(height: 10),
            _LogoPreview(url: logoLivePreviewUrl!),
          ],
          // Wave 2 U-FU-hp11-account — contact email + phone live in
          // the per-location override table. We render them at every
          // scope because the operator might also want to set a
          // business-wide contact email/phone someday. The proxy
          // route accepts both; the schema's NULL columns inherit
          // the business default.
          const SizedBox(height: 14),
          _AccountSubheading(
            title: 'Contact',
            body: scopeBelowBusiness
                ? 'If blank here, this ${scopeLabel.toLowerCase()} inherits the nearest contact.'
                : 'Locations inherit this contact unless they set their own.',
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('operator_web_account_contact_email'),
            controller: contactEmailController,
            enabled: contactEnabled,
            inputFormatters: <TextInputFormatter>[
              LengthLimitingTextInputFormatter(320),
            ],
            decoration: const InputDecoration(
              labelText: 'Contact email',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('operator_web_account_contact_phone'),
            controller: contactPhoneController,
            enabled: contactEnabled,
            inputFormatters: <TextInputFormatter>[
              LengthLimitingTextInputFormatter(64),
            ],
            decoration: const InputDecoration(
              labelText: 'Contact phone',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => onChanged(),
          ),
        ],
      ),
    );
  }
}

class _AccountSubheading extends StatelessWidget {
  const _AccountSubheading({required this.title, this.body});

  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final bodyText = body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: AppTextStyles.mono14(
            color: AppColors.textPrimary,
            weight: FontWeight.w700,
          ),
        ),
        if (bodyText != null && bodyText.isNotEmpty) ...<Widget>[
          const SizedBox(height: 3),
          Text(
            bodyText,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
        ],
      ],
    );
  }
}

class _BusinessTimingLinkedText extends StatelessWidget {
  const _BusinessTimingLinkedText({
    required this.textBeforeLink,
    required this.linkKey,
    this.onOpenBusinessTiming,
  });

  final String textBeforeLink;
  final Key linkKey;
  final VoidCallback? onOpenBusinessTiming;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      runSpacing: 0,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
          textBeforeLink,
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
        TextButton(
          key: linkKey,
          onPressed: onOpenBusinessTiming,
          style: TextButton.styleFrom(
            foregroundColor: AppColors.sunsetDark,
            padding: EdgeInsets.zero,
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
          child: Text(
            'Business Timing.',
            style: AppTextStyles.body13(
              color: AppColors.sunsetDark,
            ).copyWith(decoration: TextDecoration.underline),
          ),
        ),
      ],
    );
  }
}

class _LogoPreview extends StatelessWidget {
  const _LogoPreview({required this.url});
  final String url;
  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_account_logo_preview'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.backgroundSurface,
              border: Border.all(color: AppColors.borderSubtle, width: 1),
              borderRadius: BorderRadius.circular(4),
              image: url.startsWith('https://')
                  ? DecorationImage(image: NetworkImage(url), fit: BoxFit.cover)
                  : null,
            ),
            alignment: Alignment.center,
            child: url.startsWith('https://')
                ? null
                : Text(
                    'Preview',
                    style: AppTextStyles.body12(color: AppColors.textMuted),
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Logo preview',
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _RegionSection extends StatelessWidget {
  const _RegionSection({
    required this.currencyCode,
    required this.localeTag,
    required this.currencies,
    required this.locales,
    required this.enabled,
    required this.onCurrencyChanged,
    required this.onLocaleChanged,
    required this.sourceStatus,
  });

  final String? currencyCode;
  final String? localeTag;
  final List<_OptionPair> currencies;
  final List<_OptionPair> locales;
  final bool enabled;
  final ValueChanged<String?> onCurrencyChanged;
  final ValueChanged<String?> onLocaleChanged;
  final String sourceStatus;

  @override
  Widget build(BuildContext context) {
    return _Card(
      cardKey: const Key('operator_web_account_section_region'),
      title: 'Currency and locale',
      subtitle:
          'Currency drives every dollar amount you see. Locale drives '
          'date formats and number separators (1,234.56 versus '
          '1.234,56, for example).',
      sourceStatus: sourceStatus,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: const Key('operator_web_account_currency'),
            initialValue: currencyCode,
            decoration: const InputDecoration(
              labelText: 'Currency',
              border: OutlineInputBorder(),
            ),
            items: <DropdownMenuItem<String>>[
              for (final option in currencies)
                DropdownMenuItem<String>(
                  value: option.value,
                  child: Text(option.label),
                ),
            ],
            onChanged: enabled ? onCurrencyChanged : null,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const Key('operator_web_account_locale'),
            initialValue: localeTag,
            decoration: const InputDecoration(
              labelText: 'Locale',
              border: OutlineInputBorder(),
            ),
            items: <DropdownMenuItem<String>>[
              for (final option in locales)
                DropdownMenuItem<String>(
                  value: option.value,
                  child: Text(option.label),
                ),
            ],
            onChanged: enabled ? onLocaleChanged : null,
          ),
        ],
      ),
    );
  }
}

class _BusinessDaySection extends StatelessWidget {
  const _BusinessDaySection({
    required this.weekStartDay,
    required this.rolloverHour,
    required this.sourceStatus,
    this.onOpenBusinessTiming,
  });

  final String? weekStartDay;
  final int? rolloverHour;
  final String sourceStatus;
  final VoidCallback? onOpenBusinessTiming;

  @override
  Widget build(BuildContext context) {
    final weekStartDisplay = weekStartDay == null || weekStartDay!.isEmpty
        ? 'no first day of week on file'
        : titleCase(weekStartDay!);
    final rolloverDisplay = rolloverHour == null
        ? 'no rollover hour on file'
        : '${rolloverHour!.toString().padLeft(2, '0')}:00 local';
    return _Card(
      cardKey: const Key('operator_web_account_section_business_day'),
      title: 'Business week',
      subtitle:
          'Forge & Flow groups your data by business day. You can edit '
          'the business day start in Business Timing.',
      sourceStatus: sourceStatus,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            key: const Key('operator_web_account_week_start'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.backgroundMid,
              border: Border.all(color: AppColors.borderSubtle, width: 1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Business week start',
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                _BusinessTimingLinkedText(
                  textBeforeLink: 'Week starts $weekStartDisplay. Edit this in',
                  linkKey: const Key(
                    'operator_web_account_week_start_business_timing_link',
                  ),
                  onOpenBusinessTiming: onOpenBusinessTiming,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Container(
            key: const Key(
              'operator_web_account_business_day_rollover_readonly',
            ),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.backgroundMid,
              border: Border.all(color: AppColors.borderSubtle, width: 1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Business day rollover',
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                _BusinessTimingLinkedText(
                  textBeforeLink:
                      '$rolloverDisplay. Sales before that time count '
                      'toward the prior business day. Edit this in',
                  linkKey: const Key(
                    'operator_web_account_rollover_business_timing_link',
                  ),
                  onOpenBusinessTiming: onOpenBusinessTiming,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Title-cases a single lowercase day token ("monday" → "Monday").
  /// UX writing standard mandates Title Case in plain-English
  /// summaries. Kept local to this section so the helper does not
  /// leak.
  static String titleCase(String value) {
    if (value.isEmpty) return value;
    return value[0].toUpperCase() + value.substring(1);
  }
}

/// Read-only timezone handoff. Timezone changes live with Business
/// Timing so week start, business-day rollover, timezone, and service
/// periods move through one location-focused workflow.
class _LocationTimezoneSection extends StatelessWidget {
  const _LocationTimezoneSection({
    required this.scopeLabel,
    required this.scopeName,
    required this.selectedValue,
    required this.customController,
    required this.shortlist,
    required this.customSentinel,
    required this.enabled,
    required this.submitting,
    required this.errorMessage,
    required this.successMessage,
    required this.onShortlistChanged,
    required this.onCustomChanged,
    required this.onSave,
    this.onOpenBusinessTiming,
    required this.sourceStatus,
  });

  final String scopeLabel;
  final String scopeName;
  final String? selectedValue;
  final TextEditingController customController;
  final List<_OptionPair> shortlist;
  final String customSentinel;
  final bool enabled;
  final bool submitting;
  final String? errorMessage;
  final String? successMessage;
  final ValueChanged<String?> onShortlistChanged;
  final VoidCallback onCustomChanged;
  final Future<void> Function() onSave;
  final VoidCallback? onOpenBusinessTiming;
  final String sourceStatus;

  @override
  Widget build(BuildContext context) {
    final display = _displayTimezone();
    return _Card(
      cardKey: const Key('operator_web_account_section_location_timezone'),
      title: '$scopeLabel timezone',
      subtitle:
          'Forge & Flow groups every shift, week, and weekly plan into '
          'this scope\'s local day. Timezone edits live in Business '
          'Timing so timing changes stay together for $scopeName.',
      sourceStatus: sourceStatus,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            key: const Key('operator_web_account_timezone_readonly'),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.backgroundMid,
              border: Border.all(color: AppColors.borderSubtle, width: 1),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Timezone',
                  style: AppTextStyles.mono14(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                _BusinessTimingLinkedText(
                  textBeforeLink: 'Timezone is $display. Edit this in',
                  linkKey: const Key(
                    'operator_web_account_timezone_business_timing_link',
                  ),
                  onOpenBusinessTiming: onOpenBusinessTiming,
                ),
              ],
            ),
          ),
          if (errorMessage != null) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              key: const Key('operator_web_account_timezone_error'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.negative.withValues(alpha: 0.10),
                border: Border.all(
                  color: AppColors.negative.withValues(alpha: 0.45),
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.error_outline,
                    size: 16,
                    color: AppColors.negative,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      errorMessage!,
                      style: AppTextStyles.body13(color: AppColors.negative),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (successMessage != null) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              key: const Key('operator_web_account_timezone_success'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.positive.withValues(alpha: 0.10),
                border: Border.all(
                  color: AppColors.positive.withValues(alpha: 0.45),
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.check_circle_outline,
                    size: 16,
                    color: AppColors.positive,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      successMessage!,
                      style: AppTextStyles.body13(color: AppColors.positive),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _displayTimezone() {
    if (selectedValue == customSentinel) {
      final custom = customController.text.trim();
      return custom.isEmpty ? 'not set' : custom;
    }
    final selected = selectedValue?.trim();
    if (selected == null || selected.isEmpty) return 'not set';
    return selected;
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.cardKey,
    required this.title,
    required this.subtitle,
    required this.child,
    this.sourceStatus,
  });

  final Key cardKey;
  final String title;
  final String subtitle;
  final Widget child;
  final String? sourceStatus;

  @override
  Widget build(BuildContext context) {
    final hasTrailing =
        (sourceStatus != null && sourceStatus!.isNotEmpty) ||
        subtitle.isNotEmpty;
    return Container(
      key: cardKey,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OperatorWebSectionHeading(
            title: title,
            trailing: hasTrailing
                ? _CardHeaderTrailing(
                    title: title,
                    subtitle: subtitle,
                    sourceStatus: sourceStatus,
                  )
                : null,
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _CardHeaderTrailing extends StatelessWidget {
  const _CardHeaderTrailing({
    required this.title,
    required this.subtitle,
    required this.sourceStatus,
  });

  final String title;
  final String subtitle;
  final String? sourceStatus;

  @override
  Widget build(BuildContext context) {
    final status = sourceStatus;
    final hasStatus = status != null && status.isNotEmpty;
    final hasInfo = subtitle.isNotEmpty;
    if (!hasStatus && !hasInfo) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        if (hasStatus) _SourceStatusPill(label: status),
        if (hasInfo)
          OperatorWebInfoButton(
            title: title,
            tooltip: title,
            body: Text(
              subtitle,
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
      ],
    );
  }
}

class _SourceStatusPill extends StatelessWidget {
  const _SourceStatusPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final isSetHere = label == 'Set here';
    final isUnsaved = label == 'Unsaved';
    final color = isUnsaved
        ? AppColors.warning
        : isSetHere
        ? AppColors.peacockDark
        : AppColors.textMuted;
    return Container(
      key: Key('operator_web_account_source_status_${label.toLowerCase()}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.36), width: 1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: AppTextStyles.mono8(color: color)),
    );
  }
}

class _OptionPair {
  const _OptionPair(this.value, this.label);
  final String value;
  final String label;
}
