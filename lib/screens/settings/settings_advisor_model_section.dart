// Phase 7.57.3a-review-fix — dev-only ADVISOR MODELS Settings section.
//
// Shows the effective quick/nuanced advisor model ids and their source
// (Default / Override), allows dev-mode editing of overrides, exposes a
// Reset Defaults action, runs the injected Anthropic online check, and
// displays the pinned Voyage embedding/rerank values as read-only.
//
// Hidden in non-debug builds via `kDebugMode`. The section dispatch in
// `settings_screen.dart` only emits this slot when running in debug.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../domain/services/advisor_answer_provider.dart';
import '../../domain/services/advisor_model_routing.dart';
import '../../services/advisor_model_config_service.dart';
import '../../theme/app_theme.dart';
import 'settings_shared_widgets.dart';

class SettingsAdvisorModelSection extends StatefulWidget {
  /// Service that owns SharedPreferences read/write + the injected
  /// online-check function. Tests pass a service constructed with fake
  /// loaders; production wires the default service.
  final AdvisorModelConfigService service;

  const SettingsAdvisorModelSection({super.key, required this.service});

  @override
  State<SettingsAdvisorModelSection> createState() =>
      _SettingsAdvisorModelSectionState();
}

class _SettingsAdvisorModelSectionState
    extends State<SettingsAdvisorModelSection> {
  AdvisorModelRouting? _routing;
  AnthropicModelCheckResult? _lastCheck;
  bool _checking = false;
  late final TextEditingController _quickController;
  late final TextEditingController _nuancedController;

  @override
  void initState() {
    super.initState();
    _quickController = TextEditingController();
    _nuancedController = TextEditingController();
    _loadRouting();
  }

  @override
  void dispose() {
    _quickController.dispose();
    _nuancedController.dispose();
    super.dispose();
  }

  Future<void> _loadRouting() async {
    final r = await widget.service.currentRouting();
    if (!mounted) return;
    setState(() {
      _routing = r;
      _quickController.text = r.quickSource == AdvisorModelSource.userOverride
          ? r.effectiveQuickModelId
          : '';
      _nuancedController.text =
          r.nuancedSource == AdvisorModelSource.userOverride
              ? r.effectiveNuancedModelId
              : '';
    });
  }

  Future<void> _saveQuick() async {
    await widget.service.saveQuickOverride(_quickController.text);
    await _loadRouting();
  }

  Future<void> _saveNuanced() async {
    await widget.service.saveNuancedOverride(_nuancedController.text);
    await _loadRouting();
  }

  Future<void> _reset() async {
    await widget.service.resetOverrides();
    await _loadRouting();
  }

  Future<void> _check() async {
    setState(() => _checking = true);
    final result = await widget.service.checkAvailableModels();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _lastCheck = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final routing = _routing;
    if (routing == null) {
      return const SettingsCard(children: [
        Padding(
          padding: EdgeInsets.all(14),
          child: Text('Loading advisor model routing...',
              style: TextStyle(color: AppColors.textSecondary)),
        ),
      ]);
    }
    return SettingsCard(
      children: [
        _AdvisorRoutingHeader(routing: routing),
        const SettingsRowDivider(),
        _OverrideField(
          label: 'QUICK OVERRIDE',
          controller: _quickController,
          hintModelId: routing.effectiveQuickModelId,
          fieldKey: const Key('advisor_quick_override_field'),
          onSave: _saveQuick,
        ),
        const SettingsRowDivider(),
        _OverrideField(
          label: 'NUANCED OVERRIDE',
          controller: _nuancedController,
          hintModelId: routing.effectiveNuancedModelId,
          fieldKey: const Key('advisor_nuanced_override_field'),
          onSave: _saveNuanced,
        ),
        const SettingsRowDivider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  key: const Key('advisor_reset_button'),
                  onPressed: _reset,
                  child: const Text('Reset Defaults'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton(
                  key: const Key('advisor_check_button'),
                  onPressed: _checking ? null : _check,
                  child: Text(_checking
                      ? 'Checking...'
                      : 'Check Anthropic Models'),
                ),
              ),
            ],
          ),
        ),
        if (_lastCheck != null) ...[
          const SettingsRowDivider(),
          _CheckResultRow(result: _lastCheck!),
        ],
        const SettingsRowDivider(),
        _VoyagePinnedRow(routing: routing),
      ],
    );
  }
}

// ─── Sub-widgets ─────────────────────────────────────────────────────────────

class _AdvisorRoutingHeader extends StatelessWidget {
  final AdvisorModelRouting routing;
  const _AdvisorRoutingHeader({required this.routing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('QUICK', routing.effectiveQuickModelId,
              routing.sourceLabelForTier(AdvisorTier.quick)),
          const SizedBox(height: 6),
          _row('NUANCED', routing.effectiveNuancedModelId,
              routing.sourceLabelForTier(AdvisorTier.nuanced)),
        ],
      ),
    );
  }

  Widget _row(String tier, String modelId, String source) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('$tier · $modelId',
            style: const TextStyle(
                color: AppColors.textPrimary, fontFamily: 'monospace')),
        Text(source,
            style: const TextStyle(
                color: AppColors.textSecondary, fontSize: 11)),
      ],
    );
  }
}

class _OverrideField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String hintModelId;
  final Key fieldKey;
  final Future<void> Function() onSave;

  const _OverrideField({
    required this.label,
    required this.controller,
    required this.hintModelId,
    required this.fieldKey,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 11)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: fieldKey,
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: 'override (current: $hintModelId)',
                    isDense: true,
                  ),
                  style: const TextStyle(
                      color: AppColors.textPrimary, fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(onPressed: onSave, child: const Text('Save')),
            ],
          ),
        ],
      ),
    );
  }
}

class _CheckResultRow extends StatelessWidget {
  final AnthropicModelCheckResult result;
  const _CheckResultRow({required this.result});

  @override
  Widget build(BuildContext context) {
    // Four UI states (split `available` by update-availability):
    //   * available + no update     → UP TO DATE
    //   * available + update found  → UPDATE AVAILABLE
    //   * unavailable               → UNAVAILABLE
    //   * cannotCheck               → CANNOT CHECK
    final label = switch (result.status) {
      AnthropicModelCheckStatus.available =>
        result.updateAvailable ? 'UPDATE AVAILABLE' : 'UP TO DATE',
      AnthropicModelCheckStatus.unavailable => 'UNAVAILABLE',
      AnthropicModelCheckStatus.cannotCheck => 'CANNOT CHECK',
    };
    return Padding(
      key: const Key('advisor_check_result'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 11)),
          const SizedBox(height: 4),
          Text(result.message,
              style: const TextStyle(color: AppColors.textPrimary)),
          if (result.updateAvailable) ...[
            const SizedBox(height: 6),
            if (result.latestQuickCandidate != null)
              Text(
                'Quick candidate · ${result.latestQuickCandidate}',
                key: const Key('advisor_check_quick_candidate'),
                style: const TextStyle(
                    color: AppColors.textPrimary, fontFamily: 'monospace'),
              ),
            if (result.latestNuancedCandidate != null)
              Text(
                'Nuanced candidate · ${result.latestNuancedCandidate}',
                key: const Key('advisor_check_nuanced_candidate'),
                style: const TextStyle(
                    color: AppColors.textPrimary, fontFamily: 'monospace'),
              ),
          ],
        ],
      ),
    );
  }
}

class _VoyagePinnedRow extends StatelessWidget {
  final AdvisorModelRouting routing;
  const _VoyagePinnedRow({required this.routing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const Key('advisor_voyage_pinned'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('VOYAGE (PINNED, READ-ONLY)',
              style: TextStyle(
                  color: AppColors.textSecondary, fontSize: 11)),
          const SizedBox(height: 4),
          Text(
            'embedding · ${routing.voyageEmbeddingProviderId}/'
            '${routing.voyageEmbeddingModelId} '
            '(${routing.voyageEmbeddingDimensions} dims)',
            style: const TextStyle(
                color: AppColors.textPrimary, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 2),
          Text(
            'rerank · ${routing.voyageRerankProviderId}/'
            '${routing.voyageRerankModelId}',
            style: const TextStyle(
                color: AppColors.textPrimary, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}

// ─── Visibility helper for the settings_screen dispatcher ────────────────────

/// True only when running a debug/dev build. The Settings section
/// dispatch in `settings_screen.dart` consults this so the surface
/// disappears in release builds.
bool get advisorModelSectionEnabled => kDebugMode;
