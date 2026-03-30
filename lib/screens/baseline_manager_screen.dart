// Phase 5.1 — Baseline Manager Screen (contract fix)
// Manager inspects historical closed shifts, toggles star selections,
// previews the full draft target, then commits or discards.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../data/baseline_manager_service.dart';
import '../models/baseline_candidate_shift.dart';
import '../theme/app_theme.dart';

class BaselineManagerScreen extends StatefulWidget {
  /// Production constructor — loads candidates from DB on init.
  const BaselineManagerScreen({super.key}) : initialCandidates = null;

  /// Test-only constructor: skips async DB load and uses the supplied list.
  @visibleForTesting
  const BaselineManagerScreen.withCandidates(
    List<BaselineCandidateShift> candidates, {
    super.key,
  }) : initialCandidates = candidates;

  final List<BaselineCandidateShift>? initialCandidates;

  @override
  State<BaselineManagerScreen> createState() => _BaselineManagerScreenState();
}

class _BaselineManagerScreenState extends State<BaselineManagerScreen> {
  // ── State ──────────────────────────────────────────────────────────────────

  bool _loading = true;
  List<BaselineCandidateShift> _candidates = [];
  late Set<String> _draftKeys;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    if (widget.initialCandidates != null) {
      _candidates = widget.initialCandidates!;
      _draftKeys = _candidates
          .where((c) => c.isSelected)
          .map((c) => c.recordKey)
          .toSet();
      _loading = false;
    } else {
      _loadCandidates();
    }
  }

  Future<void> _loadCandidates() async {
    final candidates =
        await BaselineManagerService.instance.getCandidateShifts();
    if (!mounted) return;
    setState(() {
      _candidates = candidates;
      _draftKeys =
          candidates.where((c) => c.isSelected).map((c) => c.recordKey).toSet();
      _loading = false;
    });
  }

  // ── Draft helpers ──────────────────────────────────────────────────────────

  void _toggle(String recordKey) {
    setState(() {
      if (_draftKeys.contains(recordKey)) {
        _draftKeys.remove(recordKey);
      } else {
        _draftKeys.add(recordKey);
      }
    });
  }

  List<BaselineCandidateShift> get _draftSelected =>
      _candidates.where((c) => _draftKeys.contains(c.recordKey)).toList();

  // ── Navigation actions ─────────────────────────────────────────────────────

  void _cancel() => Navigator.of(context).pop();

  Future<void> _done() async {
    await BaselineManagerService.instance.saveSelection(_draftKeys);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundDeep,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios,
              size: 18, color: AppColors.textMuted),
          onPressed: _cancel,
        ),
        title: Text('Choose Star Shifts', style: AppTextStyles.mono11()),
        centerTitle: false,
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.tealPrimary))
          : Column(
              children: [
                _PreviewPanel(selected: _draftSelected),
                Expanded(
                  child: _CandidateList(
                    candidates: _candidates,
                    draftKeys: _draftKeys,
                    onToggle: _toggle,
                  ),
                ),
                _BottomBar(
                  onCancel: _cancel,
                  onDone: _done,
                ),
              ],
            ),
    );
  }
}

// ─── Preview panel ─────────────────────────────────────────────────────────────

class _PreviewPanel extends StatelessWidget {
  final List<BaselineCandidateShift> selected;

  const _PreviewPanel({required this.selected});

  @override
  Widget build(BuildContext context) {
    final count = selected.length;
    final hasData = count > 0;

    final cplh = hasData
        ? (selected.fold(0.0, (s, c) => s + c.cplh) / count)
            .toStringAsFixed(1)
        : '--';
    final splh = hasData
        ? (selected.fold(0.0, (s, c) => s + c.splh) / count)
            .toStringAsFixed(0)
        : '--';
    final ppa = hasData
        ? (selected.fold(0.0, (s, c) => s + c.ppa) / count)
            .toStringAsFixed(0)
        : '--';
    final floor = hasData
        ? selected
            .map((c) => c.cplh)
            .reduce((a, b) => a < b ? a : b)
            .toStringAsFixed(1)
        : '--';
    final ceil = hasData
        ? selected
            .map((c) => c.cplh)
            .reduce((a, b) => a > b ? a : b)
            .toStringAsFixed(1)
        : '--';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.backgroundMid, AppColors.backgroundDeep],
        ),
        border: Border.all(color: AppColors.borderStrong, width: 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Row 1: SELECTED SHIFTS · TARGET CPLH
          Row(
            children: [
              Expanded(
                child: _PreviewCell(
                  label: 'SELECTED SHIFTS',
                  value: '$count',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PreviewCell(
                  label: 'TARGET CPLH',
                  value: cplh,
                  highlight: hasData,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Row 2: TARGET SPLH · TARGET PPA
          Row(
            children: [
              Expanded(
                child: _PreviewCell(label: 'TARGET SPLH', value: splh),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PreviewCell(label: 'TARGET PPA', value: ppa),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Row 3: OPZ FLOOR · OPZ CEILING
          Row(
            children: [
              Expanded(
                child: _PreviewCell(label: 'OPZ FLOOR', value: floor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PreviewCell(label: 'OPZ CEILING', value: ceil),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreviewCell extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _PreviewCell({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: AppTextStyles.mono7(color: AppColors.textMuted)),
        const SizedBox(height: 3),
        Text(
          value,
          style: AppTextStyles.mono14(
            color: highlight ? AppColors.tealPrimary : AppColors.textSecondary,
            weight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

// ─── Candidate list ────────────────────────────────────────────────────────────

class _CandidateList extends StatelessWidget {
  final List<BaselineCandidateShift> candidates;
  final Set<String> draftKeys;
  final ValueChanged<String> onToggle;

  const _CandidateList({
    required this.candidates,
    required this.draftKeys,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    if (candidates.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'No closed shifts found.\nClose some shifts to build your baseline.',
            textAlign: TextAlign.center,
            style: AppTextStyles.body13(color: AppColors.textMuted),
          ),
        ),
      );
    }

    // Group by daypart — candidates arrive pre-sorted: lunch → dinner → late_night
    final groups = <String, List<BaselineCandidateShift>>{};
    for (final c in candidates) {
      groups.putIfAbsent(c.daypart, () => []).add(c);
    }

    // Build section tiles in daypart order
    const daypartOrder = ['lunch', 'dinner', 'late_night'];
    final items = <Widget>[];

    for (final dp in daypartOrder) {
      final group = groups[dp];
      if (group == null || group.isEmpty) continue;

      // Section header
      items.add(_SectionHeader(label: group.first.daypartLabel));

      // Candidate rows
      for (final candidate in group) {
        items.add(_CandidateTile(
          candidate: candidate,
          isSelected: draftKeys.contains(candidate.recordKey),
          onToggle: () => onToggle(candidate.recordKey),
        ));
      }
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: items,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;

  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      child: Row(
        children: [
          Text(label.toUpperCase(),
              style: AppTextStyles.mono11(color: AppColors.textMuted)),
          const SizedBox(width: 12),
          Expanded(
            child: Container(height: 1, color: AppColors.borderSubtle),
          ),
        ],
      ),
    );
  }
}

class _CandidateTile extends StatelessWidget {
  final BaselineCandidateShift candidate;
  final bool isSelected;
  final VoidCallback onToggle;

  const _CandidateTile({
    required this.candidate,
    required this.isSelected,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final borderColor = isSelected
        ? AppColors.tealPrimary.withValues(alpha: 0.7)
        : AppColors.borderSubtle;
    final bgColor = isSelected
        ? AppColors.tealPrimary.withValues(alpha: 0.07)
        : Colors.transparent;

    return GestureDetector(
      onTap: onToggle,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: bgColor,
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Row(
          children: [
            // Selection indicator
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color:
                    isSelected ? AppColors.tealPrimary : Colors.transparent,
                border: Border.all(
                  color: isSelected
                      ? AppColors.tealPrimary
                      : AppColors.textMuted,
                  width: 1.5,
                ),
              ),
              child: isSelected
                  ? const Icon(Icons.check,
                      size: 12, color: AppColors.backgroundDeep)
                  : null,
            ),
            const SizedBox(width: 12),

            // Label + metrics
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    candidate.displayLabel,
                    style: AppTextStyles.mono10(
                        color: isSelected
                            ? AppColors.textPrimary
                            : AppColors.textSecondary),
                  ),
                  const SizedBox(height: 5),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      _MetricChip(
                        label: 'CPLH',
                        value: candidate.cplh.toStringAsFixed(2),
                        highlight: isSelected,
                      ),
                      _MetricChip(
                        label: 'COVERS',
                        value: '${candidate.covers}',
                        highlight: false,
                      ),
                      _MetricChip(
                        label: 'SPLH',
                        value: '\$${candidate.splh.toStringAsFixed(0)}',
                        highlight: false,
                      ),
                      _MetricChip(
                        label: 'PPA',
                        value: '\$${candidate.ppa.toStringAsFixed(0)}',
                        highlight: false,
                      ),
                      _MetricChip(
                        label: 'LEVER',
                        value: candidate.primaryLeverId,
                        highlight: false,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _MetricChip({
    required this.label,
    required this.value,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: AppTextStyles.mono7(color: AppColors.textMuted)),
        Text(
          value,
          style: AppTextStyles.mono10(
              color:
                  highlight ? AppColors.tealPrimary : AppColors.textSecondary),
        ),
      ],
    );
  }
}

// ─── Bottom action bar ─────────────────────────────────────────────────────────

class _BottomBar extends StatelessWidget {
  final VoidCallback onCancel;
  final Future<void> Function() onDone;

  const _BottomBar({
    required this.onCancel,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border(
          top: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Row(
        children: [
          // Cancel
          Expanded(
            child: GestureDetector(
              onTap: onCancel,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  border:
                      Border.all(color: AppColors.borderSubtle, width: 1),
                ),
                alignment: Alignment.center,
                child: Text('CANCEL',
                    style: AppTextStyles.mono8(color: AppColors.textMuted)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Done — always enabled; empty draft clears the override
          Expanded(
            flex: 2,
            child: GestureDetector(
              onTap: onDone,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: const BoxDecoration(
                  color: AppColors.tealPrimary,
                ),
                alignment: Alignment.center,
                child: Text(
                  'DONE',
                  style: AppTextStyles.mono8(
                      color: AppColors.backgroundDeep),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
