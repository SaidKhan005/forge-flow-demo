// Phase 8 spine-bridge Lane .B — 60-day covers historical seed card.
//
// Surfaced as an onboarding prompt for operators whose POS does not
// expose covers. Lets them bulk-fill prior business dates x service
// periods so F&F has a baseline to forecast off of.
//
// Authority: docs/contracts/data_accuracy_settings_contract.md
// historical seed handling section.
//
// Per-Daypart V1 Slice R5 (Gap 27/36): the matrix columns are the
// operator-configured service periods (resolver-ordered by the
// screen), not a hardcoded `Daypart.values` triplet. Bulk paste
// accepts TSV/CSV in the form `date<TAB>period1<TAB>period2...` (one
// row per date, columns in the same order as the configured periods).
// Errors render inline in the dialog so the operator can fix them
// without losing what they've already typed in the matrix.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models/service_period_definition.dart';
import '../../theme/app_theme.dart';
import 'operator_web_section_heading.dart';

class CoversHistoricalSeedCard extends StatefulWidget {
  const CoversHistoricalSeedCard({
    super.key,
    required this.endDateIso,
    required this.dayCount,
    required this.servicePeriods,
    required this.initialEntries,
    required this.onApplySeed,
  });

  /// Most recent ISO `YYYY-MM-DD` date in the seed window (typically
  /// today minus one).
  final String endDateIso;

  /// How many days of history to surface. Typically 60.
  final int dayCount;

  /// Operator-configured service periods, resolver-ordered by the
  /// screen. One matrix column per period; never a hardcoded daypart
  /// list.
  final List<ServicePeriodDefinition> servicePeriods;

  /// Existing entries the operator may already have typed. Outer key
  /// = ISO `YYYY-MM-DD`, inner key = service period id.
  final Map<String, Map<String, int>> initialEntries;

  /// Called when the operator applies the seed. The map carries every
  /// date+period cell that holds a value (inner key = service period
  /// id); cells the operator left blank are absent.
  final void Function(Map<String, Map<String, int>>) onApplySeed;

  @override
  State<CoversHistoricalSeedCard> createState() =>
      _CoversHistoricalSeedCardState();
}

class _CoversHistoricalSeedCardState extends State<CoversHistoricalSeedCard> {
  late final List<String> _dates;
  late final Map<String, Map<String, int>> _draft;
  late final Map<String, Map<String, TextEditingController>> _controllers;

  List<ServicePeriodDefinition> get _periods => widget.servicePeriods;

  @override
  void initState() {
    super.initState();
    _dates = _buildDateList(widget.endDateIso, widget.dayCount);
    _draft = <String, Map<String, int>>{};
    for (final entry in widget.initialEntries.entries) {
      _draft[entry.key] = Map<String, int>.from(entry.value);
    }
    _controllers = <String, Map<String, TextEditingController>>{
      for (final date in _dates)
        date: <String, TextEditingController>{
          for (final p in _periods)
            p.id: TextEditingController(
              text: _draft[date]?[p.id]?.toString() ?? '',
            ),
        },
    };
  }

  @override
  void dispose() {
    for (final byDate in _controllers.values) {
      for (final c in byDate.values) {
        c.dispose();
      }
    }
    super.dispose();
  }

  static List<String> _buildDateList(String endDateIso, int dayCount) {
    final end = DateTime.parse(endDateIso);
    final out = <String>[];
    for (var i = 0; i < dayCount; i++) {
      final d = end.subtract(Duration(days: i));
      final iso =
          '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
      out.add(iso);
    }
    return out;
  }

  void _writeCell(String date, String servicePeriodId, String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _draft[date]?.remove(servicePeriodId);
        if (_draft[date]?.isEmpty ?? false) {
          _draft.remove(date);
        }
      });
      return;
    }
    final parsed = int.tryParse(trimmed);
    if (parsed == null || parsed < 0) return;
    setState(() {
      _draft.putIfAbsent(date, () => <String, int>{})[servicePeriodId] =
          parsed;
    });
  }

  void _clearAll() {
    setState(() {
      _draft.clear();
      for (final byDate in _controllers.values) {
        for (final c in byDate.values) {
          c.text = '';
        }
      }
    });
  }

  Future<void> _openBulkPaste() async {
    final controller = TextEditingController();
    String? error;
    final orderHint = _periods.map((p) => p.label.toLowerCase()).join(', ');
    final applied = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: Text(
                'Paste your covers history',
                style: AppTextStyles.mono15(
                  color: AppColors.textPrimary,
                  weight: FontWeight.w700,
                ),
              ),
              content: SizedBox(
                width: 540,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'One row per business date. Separate values with '
                      'tabs or commas in this order: date, $orderHint. '
                      "Use a number, or leave a column empty if you "
                      "don't have it.",
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller,
                      maxLines: 10,
                      style: AppTextStyles.body14(
                        color: AppColors.textPrimary,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText:
                            '2026-05-04\t40\t96\t12\n2026-05-03\t38\t101\t10',
                      ),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        error!,
                        style: AppTextStyles.body13(
                          color: AppColors.negative,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final result = _parseBulk(controller.text);
                    if (result.error != null) {
                      setLocal(() => error = result.error);
                      return;
                    }
                    _applyParsed(result.entries);
                    Navigator.of(ctx).pop(true);
                  },
                  child: const Text('Add to grid'),
                ),
              ],
            );
          },
        );
      },
    );
    controller.dispose();
    if (applied == true && mounted) {
      setState(() {});
    }
  }

  void _applyParsed(Map<String, Map<String, int>> parsed) {
    parsed.forEach((date, byPart) {
      _draft.putIfAbsent(date, () => <String, int>{}).addAll(byPart);
      final byCtl = _controllers[date];
      if (byCtl != null) {
        byPart.forEach((id, v) {
          byCtl[id]?.text = v.toString();
        });
      }
    });
  }

  _BulkParseResult _parseBulk(String raw) {
    if (raw.trim().isEmpty) {
      return _BulkParseResult(error: 'Paste at least one row to continue.');
    }
    final periodIds = _periods.map((p) => p.id).toList();
    final out = <String, Map<String, int>>{};
    final lines = raw.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final cells = line
          .split(RegExp(r'[\t,]'))
          .map((c) => c.trim())
          .toList();
      if (cells.length < 2) {
        return _BulkParseResult(
          error:
              'Row ${i + 1} needs at least a date and one number. Use a '
              'tab or comma between values.',
        );
      }
      final dateRaw = cells[0];
      DateTime parsedDate;
      try {
        parsedDate = DateTime.parse(dateRaw);
      } catch (_) {
        return _BulkParseResult(
          error: 'Row ${i + 1}: "$dateRaw" is not a valid YYYY-MM-DD date.',
        );
      }
      final iso =
          '${parsedDate.year.toString().padLeft(4, '0')}-'
          '${parsedDate.month.toString().padLeft(2, '0')}-'
          '${parsedDate.day.toString().padLeft(2, '0')}';
      final byPart = <String, int>{};
      for (var col = 1;
          col < cells.length && col <= periodIds.length;
          col++) {
        final cell = cells[col];
        if (cell.isEmpty) continue;
        final parsed = int.tryParse(cell);
        if (parsed == null || parsed < 0) {
          return _BulkParseResult(
            error:
                'Row ${i + 1}, column ${col + 1}: "$cell" is not a whole '
                'number 0 or greater.',
          );
        }
        byPart[periodIds[col - 1]] = parsed;
      }
      if (byPart.isNotEmpty) {
        out[iso] = byPart;
      }
    }
    if (out.isEmpty) {
      return _BulkParseResult(
        error: 'No valid rows found. Check the date format and numbers.',
      );
    }
    return _BulkParseResult(entries: out);
  }

  @override
  Widget build(BuildContext context) {
    final hasDraft = _draft.values.any((m) => m.isNotEmpty);
    return Container(
      key: const Key('data_accuracy_covers_historical_seed_card'),
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
            title: 'Backfill the last ${widget.dayCount} days of covers',
          ),
          const SizedBox(height: 10),
          Text(
            "Your POS doesn't expose covers, so F&F has nothing to learn "
            'from yet. Type your past covers (or paste them in) and F&F '
            'will use them to forecast next week. You can come back and '
            'edit any cell.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          if (_periods.isEmpty)
            Text(
              'No service periods are configured yet. Set up your service '
              'periods under Business timing and they will appear here.',
              key: const Key('covers_historical_seed_no_periods'),
              style: AppTextStyles.body13(color: AppColors.textMuted),
            )
          else ...[
            Row(
              children: [
                OutlinedButton.icon(
                  key: const Key('covers_historical_seed_bulk_paste'),
                  onPressed: _openBulkPaste,
                  icon: const Icon(Icons.content_paste_outlined, size: 16),
                  label: const Text('Bulk paste'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: hasDraft ? _clearAll : null,
                  child: Text(
                    'Clear all',
                    style: AppTextStyles.body13(
                      color: hasDraft
                          ? AppColors.sunsetDark
                          : AppColors.textMuted,
                    ),
                  ),
                ),
                const Spacer(),
                FilledButton(
                  key: const Key('covers_historical_seed_apply'),
                  onPressed:
                      hasDraft ? () => widget.onApplySeed(_draft) : null,
                  child: const Text('Apply seed'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _MatrixHeader(
              periodLabels: [for (final p in _periods) p.label],
            ),
            const SizedBox(height: 6),
            LimitedBox(
              maxHeight: 360,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final date in _dates)
                      _MatrixRow(
                        date: date,
                        periods: _periods,
                        controllers: _controllers[date]!,
                        onChanged: (id, raw) => _writeCell(date, id, raw),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BulkParseResult {
  _BulkParseResult({this.entries = const {}, this.error});

  final Map<String, Map<String, int>> entries;
  final String? error;
}

class _MatrixHeader extends StatelessWidget {
  const _MatrixHeader({required this.periodLabels});

  final List<String> periodLabels;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          SizedBox(
            width: 116,
            child: Text(
              'Date',
              style: AppTextStyles.body13(color: AppColors.textMuted),
            ),
          ),
          for (final label in periodLabels)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  label,
                  style: AppTextStyles.body13(color: AppColors.textMuted),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MatrixRow extends StatelessWidget {
  const _MatrixRow({
    required this.date,
    required this.periods,
    required this.controllers,
    required this.onChanged,
  });

  final String date;
  final List<ServicePeriodDefinition> periods;
  final Map<String, TextEditingController> controllers;
  final void Function(String, String) onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 116,
            child: Text(
              date,
              style: AppTextStyles.body14(color: AppColors.textPrimary),
            ),
          ),
          for (final p in periods)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: TextField(
                  key: Key('covers_historical_seed_${date}_${p.id}'),
                  controller: controllers[p.id],
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: false,
                    signed: false,
                  ),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (raw) => onChanged(p.id, raw),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(),
                  ),
                  style: AppTextStyles.body14(color: AppColors.textPrimary),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
