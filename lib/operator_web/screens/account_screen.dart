// Phase 11W.7 / Wave A2 - Operator-Web Account screen (business identity).
//
// Sibling to MyAccountScreen (sign-in identity / MFA / password / T&Cs).
// This screen owns the business-identity surface: business name, logo,
// currency, locale, week-start day, rollover hour. Every write goes
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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/permission_keys.dart';
import '../../theme/app_theme.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/operator_web_proxy_client.dart';
import '../services/web_account_gateway.dart';
import '../widgets/hierarchy_scope_notice.dart';

const Set<String> _kAccountEditRoles = <String>{
  'operator_owner',
  'operator_admin',
};

const String _kAccountEditPermission = PermissionKeys.accountConfigure;

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.session, this.gateway});

  final OperatorWebSession session;

  /// Live operator-scoped write gateway. When null, the screen
  /// renders honest read-only state (the demo source ships without a
  /// live gateway). The router wires this up when the live source
  /// implements `OperatorWebAccountGatewayProvider`.
  final WebAccountGateway? gateway;

  bool get canEdit =>
      session.roles.any(_kAccountEditRoles.contains) ||
      session.permissions.contains(_kAccountEditPermission);

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

  // Wave 2 W-6 — location timezone editor state. The active value
  // seeds from the session; a custom value lives in
  // `_timezoneCustomController` so the operator can type any IANA tz
  // name not in the shortlist without losing what they typed when
  // they toggle the dropdown.
  late TextEditingController _timezoneCustomController;
  String? _selectedTimezone;
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

  static const List<_OptionPair> _weekStartDays = <_OptionPair>[
    _OptionPair('monday', 'Monday'),
    _OptionPair('tuesday', 'Tuesday'),
    _OptionPair('wednesday', 'Wednesday'),
    _OptionPair('thursday', 'Thursday'),
    _OptionPair('friday', 'Friday'),
    _OptionPair('saturday', 'Saturday'),
    _OptionPair('sunday', 'Sunday'),
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
    final hasInShortlist = initialTimezone != null &&
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
  }

  @override
  void dispose() {
    _businessName.dispose();
    _logoUrl.dispose();
    _timezoneCustomController.dispose();
    _successTimer?.cancel();
    _timezoneSuccessTimer?.cancel();
    super.dispose();
  }

  bool get _hasGateway => widget.gateway != null;

  Future<void> _handleSave() async {
    final gateway = widget.gateway;
    if (gateway == null || !widget.canEdit) return;
    final patch = AccountIdentityPatch(
      businessName: _businessName.text.trim().isEmpty
          ? null
          : _businessName.text.trim(),
      logoUrl: _logoUrl.text.trim().isEmpty ? null : _logoUrl.text.trim(),
      clearLogo: _logoUrl.text.trim().isEmpty,
      currencyCode: _currencyCode,
      localeTag: _localeTag,
      weekStartDay: _weekStartDay,
      rolloverHour: _rolloverHour,
    );
    setState(() {
      _submitting = true;
      _errorMessage = null;
      _successMessage = null;
    });
    try {
      await gateway.patchAccount(patch);
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
      await gateway.patchLocationTimezone(
        AccountLocationTimezonePatch(ianaTimezone: value),
      );
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
            'Could not save the timezone for this location: $error';
      });
      return;
    }
    if (!mounted) return;
    _timezoneSuccessTimer?.cancel();
    setState(() {
      _timezoneSubmitting = false;
      _timezoneSuccessMessage =
          'Saved. Daily timing now uses $value for this location.';
    });
    _timezoneSuccessTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _timezoneSuccessMessage = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const Key('operator_web_account_screen'),
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(),
          const SizedBox(height: 18),
          if (!_hasGateway) const _UnavailableBanner(),
          if (!_hasGateway) const SizedBox(height: 14),
          if (!widget.canEdit) const _ReadOnlyBanner(),
          if (!widget.canEdit) const SizedBox(height: 14),
          _BusinessIdentitySection(
            businessNameController: _businessName,
            logoUrlController: _logoUrl,
            logoLivePreviewUrl: _logoUrl.text.trim().isEmpty
                ? null
                : _logoUrl.text.trim(),
            enabled: widget.canEdit && !_submitting,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 14),
          _RegionSection(
            currencyCode: _currencyCode,
            localeTag: _localeTag,
            currencies: _currencies,
            locales: _locales,
            enabled: widget.canEdit && !_submitting,
            onCurrencyChanged: (value) => setState(() => _currencyCode = value),
            onLocaleChanged: (value) => setState(() => _localeTag = value),
          ),
          const SizedBox(height: 14),
          _BusinessDaySection(
            weekStartDay: _weekStartDay,
            rolloverHour: _rolloverHour,
            weekStartDays: _weekStartDays,
            enabled: widget.canEdit && !_submitting,
            onWeekStartChanged: (value) =>
                setState(() => _weekStartDay = value),
            onRolloverChanged: (value) => setState(() => _rolloverHour = value),
          ),
          const SizedBox(height: 14),
          _LocationTimezoneSection(
            session: widget.session,
            selectedValue: _selectedTimezone,
            customController: _timezoneCustomController,
            shortlist: _timezoneShortlist,
            customSentinel: _timezoneCustomSentinel,
            enabled: widget.canEdit && _hasGateway && !_timezoneSubmitting,
            submitting: _timezoneSubmitting,
            errorMessage: _timezoneErrorMessage,
            successMessage: _timezoneSuccessMessage,
            effectiveValue: _effectiveTimezoneValue(),
            onShortlistChanged: (value) =>
                setState(() => _selectedTimezone = value),
            onCustomChanged: () => setState(() {}),
            onSave: _handleSaveTimezone,
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
            child: SizedBox(
              height: 42,
              child: FilledButton(
                key: const Key('operator_web_account_save'),
                onPressed: widget.canEdit && _hasGateway && !_submitting
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
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(
          Icons.business_outlined,
          size: 22,
          color: AppColors.sunsetDark,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            'Business account',
            style: AppTextStyles.display20(color: AppColors.textPrimary),
          ),
        ),
      ],
    );
  }
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
    required this.logoLivePreviewUrl,
    required this.enabled,
    required this.onChanged,
  });

  final TextEditingController businessNameController;
  final TextEditingController logoUrlController;
  final String? logoLivePreviewUrl;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return _Card(
      cardKey: const Key('operator_web_account_section_identity'),
      icon: Icons.badge_outlined,
      title: 'Business identity',
      subtitle:
          'How your business shows up across Forge & Flow. The name '
          'appears on every dashboard heading; the logo shows in the '
          'console header.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('operator_web_account_business_name'),
            controller: businessNameController,
            enabled: enabled,
            inputFormatters: <TextInputFormatter>[
              LengthLimitingTextInputFormatter(120),
            ],
            decoration: const InputDecoration(
              labelText: 'Business name',
              border: OutlineInputBorder(),
              helperText: 'Up to 120 characters.',
            ),
            onChanged: (_) => onChanged(),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('operator_web_account_logo_url'),
            controller: logoUrlController,
            enabled: enabled,
            inputFormatters: <TextInputFormatter>[
              LengthLimitingTextInputFormatter(2048),
            ],
            decoration: const InputDecoration(
              labelText: 'Logo URL (https only)',
              border: OutlineInputBorder(),
              helperText:
                  'Paste a public https link to your logo. Leave empty '
                  'to clear it.',
            ),
            onChanged: (_) => onChanged(),
          ),
          if (logoLivePreviewUrl != null) ...[
            const SizedBox(height: 10),
            _LogoPreview(url: logoLivePreviewUrl!),
          ],
        ],
      ),
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
              'Logo preview. Forge & Flow loads it directly from the URL '
              'you paste; the proxy never proxies images.',
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
  });

  final String? currencyCode;
  final String? localeTag;
  final List<_OptionPair> currencies;
  final List<_OptionPair> locales;
  final bool enabled;
  final ValueChanged<String?> onCurrencyChanged;
  final ValueChanged<String?> onLocaleChanged;

  @override
  Widget build(BuildContext context) {
    return _Card(
      cardKey: const Key('operator_web_account_section_region'),
      icon: Icons.public_outlined,
      title: 'Region and formatting',
      subtitle:
          'Currency drives every dollar amount you see. Locale drives '
          'date formats and number separators (1,234.56 versus '
          '1.234,56, for example).',
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
    required this.weekStartDays,
    required this.enabled,
    required this.onWeekStartChanged,
    required this.onRolloverChanged,
  });

  final String? weekStartDay;
  final int? rolloverHour;
  final List<_OptionPair> weekStartDays;
  final bool enabled;
  final ValueChanged<String?> onWeekStartChanged;
  final ValueChanged<int?> onRolloverChanged;

  @override
  Widget build(BuildContext context) {
    return _Card(
      cardKey: const Key('operator_web_account_section_business_day'),
      icon: Icons.calendar_today_outlined,
      title: 'Business week and rollover',
      subtitle:
          'Forge & Flow groups your data by business day, not '
          'calendar day. The rollover hour sets when one business '
          'day ends and the next begins. Most restaurants set this '
          'to 04:00 so late-night service stays on the right day.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: const Key('operator_web_account_week_start'),
            initialValue: weekStartDay,
            decoration: const InputDecoration(
              labelText: 'First day of the business week',
              border: OutlineInputBorder(),
            ),
            items: <DropdownMenuItem<String>>[
              for (final option in weekStartDays)
                DropdownMenuItem<String>(
                  value: option.value,
                  child: Text(option.label),
                ),
            ],
            onChanged: enabled ? onWeekStartChanged : null,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            key: const Key('operator_web_account_rollover_hour'),
            initialValue: rolloverHour,
            decoration: const InputDecoration(
              labelText: 'Rollover hour (local)',
              border: OutlineInputBorder(),
            ),
            items: <DropdownMenuItem<int>>[
              for (var hour = 0; hour < 24; hour++)
                DropdownMenuItem<int>(
                  value: hour,
                  child: Text(_formatHour(hour)),
                ),
            ],
            onChanged: enabled ? onRolloverChanged : null,
          ),
        ],
      ),
    );
  }

  String _formatHour(int hour) {
    final hh = hour.toString().padLeft(2, '0');
    if (hour == 0) return '$hh:00 (midnight)';
    if (hour == 4) return '$hh:00 (recommended)';
    return '$hh:00';
  }
}

/// Wave 2 W-6 — location timezone editor.
///
/// HP #11: timezone is location-scoped, so the section renders the
/// scope/inherited-from/effective triple via [HierarchyScopeNotice].
/// "Set here" because each location stores its own `locations.timezone`
/// today; there is no business-level rollup yet.
///
/// Two input affordances:
///   * Shortlist dropdown of common IANA timezones.
///   * Custom text field for any other IANA tz name.
/// The dropdown owns the choice unless the operator selects the
/// "Custom IANA timezone" sentinel, in which case the text field's
/// trimmed value is canonical. Saves go through
/// [WebAccountGateway.patchLocationTimezone].
///
/// Time guardrails (`CLAUDE.md`): the location timezone drives every
/// business-date computation for shifts, weeks, and weekly plans.
/// Storage stays UTC; this editor only changes the local-display
/// reference frame, never the stored timestamps.
class _LocationTimezoneSection extends StatelessWidget {
  const _LocationTimezoneSection({
    required this.session,
    required this.selectedValue,
    required this.customController,
    required this.shortlist,
    required this.customSentinel,
    required this.enabled,
    required this.submitting,
    required this.errorMessage,
    required this.successMessage,
    required this.effectiveValue,
    required this.onShortlistChanged,
    required this.onCustomChanged,
    required this.onSave,
  });

  final OperatorWebSession session;
  final String? selectedValue;
  final TextEditingController customController;
  final List<_OptionPair> shortlist;
  final String customSentinel;
  final bool enabled;
  final bool submitting;
  final String? errorMessage;
  final String? successMessage;
  final String effectiveValue;
  final ValueChanged<String?> onShortlistChanged;
  final VoidCallback onCustomChanged;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    final isCustom = selectedValue == customSentinel;
    final hasEffective = effectiveValue.isNotEmpty;
    return _Card(
      cardKey: const Key('operator_web_account_section_location_timezone'),
      icon: Icons.schedule_outlined,
      title: 'Location timezone',
      subtitle:
          'Forge & Flow groups every shift, week, and weekly plan into '
          'this location\'s local day. Changing the timezone changes how '
          'business dates land for ${session.primaryLocationName} from '
          'this point forward; past data keeps the timezone it was '
          'recorded against.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          HierarchyScopeNotice(
            keyName: 'operator_web_account_timezone_scope',
            selectedScope: HierarchyScopeLevel.location,
            scopeName: session.primaryLocationName,
            effectiveValueSummary: hasEffective
                ? 'This location uses $effectiveValue.'
                : 'No timezone is on file. Set one to lock daily timing.',
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: const Key('operator_web_account_timezone_shortlist'),
            initialValue: selectedValue,
            decoration: const InputDecoration(
              labelText: 'Timezone',
              border: OutlineInputBorder(),
              helperText:
                  'Pick the closest match, or choose "Custom" to type '
                  'any IANA timezone name.',
            ),
            items: <DropdownMenuItem<String>>[
              for (final option in shortlist)
                DropdownMenuItem<String>(
                  value: option.value,
                  child: Text(option.label),
                ),
              DropdownMenuItem<String>(
                value: customSentinel,
                child: const Text('Custom IANA timezone…'),
              ),
            ],
            onChanged: enabled ? onShortlistChanged : null,
          ),
          if (isCustom) ...<Widget>[
            const SizedBox(height: 10),
            TextField(
              key: const Key('operator_web_account_timezone_custom'),
              controller: customController,
              enabled: enabled,
              inputFormatters: <TextInputFormatter>[
                LengthLimitingTextInputFormatter(64),
              ],
              decoration: const InputDecoration(
                labelText: 'IANA timezone name',
                hintText: 'e.g. America/Toronto',
                border: OutlineInputBorder(),
                helperText:
                    'Use the IANA tz database name. We validate the '
                    'value when you save.',
              ),
              onChanged: (_) => onCustomChanged(),
            ),
          ],
          if (errorMessage != null) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              key: const Key('operator_web_account_timezone_error'),
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
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
                      style:
                          AppTextStyles.body13(color: AppColors.negative),
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
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
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
                      style:
                          AppTextStyles.body13(color: AppColors.positive),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              height: 38,
              child: OutlinedButton(
                key: const Key('operator_web_account_timezone_save'),
                onPressed: enabled && !submitting
                    ? () {
                        onSave();
                      }
                    : null,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.sunsetDark,
                  side: const BorderSide(
                    color: AppColors.sunsetDark,
                    width: 1,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                child: submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.sunsetDark,
                        ),
                      )
                    : const Text('Save timezone'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.cardKey,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final Key cardKey;
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
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
          Row(
            children: [
              Icon(icon, size: 18, color: AppColors.sunsetDark),
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
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _OptionPair {
  const _OptionPair(this.value, this.label);
  final String value;
  final String label;
}
