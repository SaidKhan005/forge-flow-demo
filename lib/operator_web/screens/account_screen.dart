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

import '../../theme/app_theme.dart';
import '../auth/operator_web_auth_source.dart';
import '../services/operator_web_proxy_client.dart';
import '../services/web_account_gateway.dart';
import '../widgets/operator_web_summary_strip.dart';

const Set<String> _kAccountEditRoles = <String>{
  'operator_owner',
  'operator_admin',
};

const String _kAccountEditPermission = 'account.configure';

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

  @override
  void initState() {
    super.initState();
    _businessName = TextEditingController(text: widget.session.businessName);
    _logoUrl = TextEditingController(text: widget.session.logoUrl ?? '');
    _currencyCode = widget.session.currencyCode;
    _localeTag = widget.session.localeTag;
    _weekStartDay = widget.session.weekStartDay;
    _rolloverHour = widget.session.rolloverHour;
  }

  @override
  void dispose() {
    _businessName.dispose();
    _logoUrl.dispose();
    _successTimer?.cancel();
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

  String _valueOrUnset(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? 'Not set' : trimmed;
  }

  String _capitalize(String value) {
    if (value.isEmpty) return value;
    return value[0].toUpperCase() + value.substring(1);
  }

  String _formatRollover(int hour) => '${hour.toString().padLeft(2, '0')}:00';

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
          OperatorWebSummaryStrip(
            key: const Key('operator_web_account_summary'),
            items: [
              OperatorWebSummaryItem(
                icon: Icons.business_outlined,
                label: 'Business name',
                value: _valueOrUnset(_businessName.text),
                helper: 'shown across the console',
              ),
              OperatorWebSummaryItem(
                icon: Icons.public_outlined,
                label: 'Region',
                value: _currencyCode ?? 'Not set',
                helper: _localeTag ?? 'locale not set',
              ),
              OperatorWebSummaryItem(
                icon: Icons.calendar_today_outlined,
                label: 'Business week',
                value: _weekStartDay == null
                    ? 'Not set'
                    : _capitalize(_weekStartDay!),
                helper: 'first day of week',
              ),
              OperatorWebSummaryItem(
                icon: Icons.schedule_outlined,
                label: 'Rollover',
                value: _rolloverHour == null
                    ? 'Not set'
                    : _formatRollover(_rolloverHour!),
                helper: 'business day boundary',
              ),
            ],
          ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
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
        ),
        const SizedBox(height: 8),
        Text(
          'These are the basics every Forge & Flow surface uses to label '
          'your operator and format numbers. They flow into your '
          'dashboards, your printable reports, and the brand mark you '
          'see at the top of the console.',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
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
