// The recipe calculator, as a bottom sheet (operator request,
// 2026-08-13: "key in a certain amount of one ingredient and it gives me
// the adjusted measurement for the other items").
//
// HOW IT WORKS. The cook taps the ingredient they are starting from,
// types how much of it they have, and every other amount that may be
// multiplied follows. The multiplier is derived from that one anchor and
// shown in plain words, so a cook can sanity-check the whole answer with
// one glance. The written amount stays beside the new one.
//
// WHY A SHEET, NOT SOMETHING ON THE CARD. The reader turns the page on a
// tap, and the page-turn zones live in a gesture arena with everything
// the card plants. Slice A9 already proved that adding a gesture-owning
// widget inside the card body kills page turns (see the DO NOT MOVE note
// on `_buildSelectableDeck` in `training_doc_screen.dart`). A modal
// route sits on its own Navigator entry, above that arena entirely, so a
// text field in here can never race the reader's tap. The card carries
// only a button, which is the same shape as the bookmark toggle that has
// been safe there since rec #8.
//
// The arithmetic and every rounding decision live in
// `../content/recipes/barrio_recipe_scaler.dart`. This file is the
// surface: it formats, it never decides a number.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../content/recipes/barrio_recipe_models.dart';
import '../content/recipes/barrio_recipe_scaler.dart';
import 'barrio_destination_scaffold.dart';

/// Opens the recipe calculator for one card's ingredient lines.
///
/// Callers gate on [barrioRecipeIngredientsForUnit] being non-empty, so
/// method cards and every card of every other manual never reach here.
Future<void> showBarrioRecipeScaler(
  BuildContext context, {
  required String recipeTitle,
  required List<BarrioRecipeIngredient> lines,
  required Color accent,
}) {
  return showModalBottomSheet<void>(
    context: context,
    // The keyboard has to be able to push the sheet up without the
    // amount field going under it.
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => BarrioRecipeScalerSheet(
      recipeTitle: recipeTitle,
      lines: lines,
      accent: accent,
    ),
  );
}

/// Bottom sheet that scales one recipe from one ingredient.
class BarrioRecipeScalerSheet extends StatefulWidget {
  /// The card's own title, so a cook knows which recipe they are scaling.
  final String recipeTitle;

  /// Every ingredient line of that card, in reading order, scalable and
  /// held alike.
  final List<BarrioRecipeIngredient> lines;

  /// The owning manual's identity color.
  final Color accent;

  const BarrioRecipeScalerSheet({
    super.key,
    required this.recipeTitle,
    required this.lines,
    required this.accent,
  });

  @override
  State<BarrioRecipeScalerSheet> createState() =>
      _BarrioRecipeScalerSheetState();
}

class _BarrioRecipeScalerSheetState extends State<BarrioRecipeScalerSheet> {
  final TextEditingController _amount = TextEditingController();

  /// The line the cook is starting from. Null only when the recipe holds
  /// nothing that may be scaled at all (three cards of the manual).
  BarrioRecipeIngredient? _anchor;

  @override
  void initState() {
    super.initState();
    final scalable = barrioScalableLines(widget.lines);
    if (scalable.isNotEmpty) _setAnchor(scalable.first);
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  /// Starts from [line], with the field holding that line's WRITTEN
  /// amount. The recipe therefore opens exactly as authored (multiplier
  /// 1) and switching anchors goes back to as-written rather than
  /// carrying a rounded amount across, which would nudge the multiplier
  /// every time the cook changed their mind.
  void _setAnchor(BarrioRecipeIngredient line) {
    _anchor = line;
    final written = line.quantity;
    _amount.text = written == null ? '' : barrioFormatRecipeAmount(written);
  }

  /// The batch size the cook typed, or null when the field is empty or
  /// holds nothing that is a batch: a half-typed '.', a zero, a negative.
  /// A comma is read as a decimal point, because some keyboards offer one
  /// and a cook should not have to care which.
  double? get _typedAmount {
    final text = _amount.text.trim().replaceAll(',', '.');
    if (text.isEmpty) return null;
    final value = double.tryParse(text);
    if (value == null || !value.isFinite || value <= 0) return null;
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final scale = barrioScaleRecipe(
      lines: widget.lines,
      anchor: _anchor,
      amount: _typedAmount,
    );
    final scaled = <BarrioScaledIngredient>[
      for (final line in scale.lines)
        if (line.scaled) line,
    ];
    final held = <BarrioScaledIngredient>[
      for (final line in scale.lines)
        if (!line.scaled) line,
    ];

    return Container(
      key: const ValueKey<String>('barrio_recipe_scaler_sheet'),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.86,
      ),
      decoration: const BoxDecoration(
        color: BarrioColors.shellDeep,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(BarrioRadii.sheet),
        ),
        border: Border(top: BorderSide(color: BarrioColors.hairline)),
      ),
      child: Padding(
        // Keeps the amount field above the keyboard instead of behind it.
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
              child: _Header(
                recipeTitle: widget.recipeTitle,
                accent: widget.accent,
                anchor: _anchor,
              ),
            ),
            if (_anchor != null) ...[
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: _AmountField(
                  controller: _amount,
                  anchor: _anchor!,
                  accent: widget.accent,
                  onChanged: () => setState(() {}),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: _MultiplierLine(
                  scale: scale,
                  accent: widget.accent,
                  hasAmount: _typedAmount != null,
                ),
              ),
            ],
            const SizedBox(height: 6),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                children: [
                  if (scaled.isNotEmpty) ...[
                    const _SectionHeading('Scales with your amount'),
                    const SizedBox(height: 8),
                    for (var i = 0; i < scaled.length; i++)
                      _ScalableRow(
                        index: i,
                        entry: scaled[i],
                        accent: widget.accent,
                        isAnchor: identical(scaled[i].line, _anchor),
                        onTap: () => setState(() => _setAnchor(scaled[i].line)),
                      ),
                    const SizedBox(height: 18),
                  ],
                  if (held.isNotEmpty) ...[
                    const _SectionHeading('Stays as the recipe wrote it'),
                    const SizedBox(height: 6),
                    Text(
                      'These lines cannot be multiplied honestly, so the '
                      'calculator leaves them alone.',
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 12.5,
                        height: 1.5,
                        color: BarrioColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (var i = 0; i < held.length; i++)
                      _HeldRow(index: i, entry: held[i]),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String recipeTitle;
  final Color accent;
  final BarrioRecipeIngredient? anchor;

  const _Header({
    required this.recipeTitle,
    required this.accent,
    required this.anchor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.calculate_rounded, size: 18, color: accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Scale this recipe',
                style: GoogleFonts.playfairDisplay(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: BarrioColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          recipeTitle,
          style: GoogleFonts.ibmPlexMono(
            fontSize: 11,
            letterSpacing: 0.4,
            color: BarrioColors.textMuted,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          anchor == null
              ? 'Nothing in this recipe can be scaled by typing an amount. '
                  'Here is why every line stays as it is written.'
              : 'Tap the ingredient you are starting from, then type how '
                  'much of it you have. Every amount that can move follows.',
          style: GoogleFonts.ibmPlexSans(
            fontSize: 13,
            height: 1.55,
            color: BarrioColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// The one number the cook types, fixed to the anchor's own unit.
///
/// No unit picker and no conversion: the suffix names the unit the
/// recipe already used, so the number typed here means the same thing the
/// card meant.
class _AmountField extends StatelessWidget {
  final TextEditingController controller;
  final BarrioRecipeIngredient anchor;
  final Color accent;
  final VoidCallback onChanged;

  const _AmountField({
    required this.controller,
    required this.anchor,
    required this.accent,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final unit = anchor.unit ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'How much ${anchor.name} do you have?',
          style: GoogleFonts.ibmPlexSans(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: BarrioColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey<String>('barrio_recipe_scale_amount'),
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
          ],
          onChanged: (_) => onChanged(),
          style: GoogleFonts.ibmPlexMono(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: BarrioColors.textPrimary,
          ),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: BarrioColors.shellMid,
            hintText: 'Amount',
            hintStyle: GoogleFonts.ibmPlexMono(
              fontSize: 16,
              color: BarrioColors.textMuted,
            ),
            suffixText: unit.isEmpty ? null : unit,
            suffixStyle: GoogleFonts.ibmPlexMono(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: accent,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(BarrioRadii.card),
              borderSide: const BorderSide(color: BarrioColors.hairline),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(BarrioRadii.card),
              borderSide: const BorderSide(color: BarrioColors.hairline),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(BarrioRadii.card),
              borderSide: BorderSide(color: accent, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

/// The derived multiplier, said out loud so a cook can sanity-check the
/// whole answer at a glance.
class _MultiplierLine extends StatelessWidget {
  final BarrioRecipeScale scale;
  final Color accent;
  final bool hasAmount;

  const _MultiplierLine({
    required this.scale,
    required this.accent,
    required this.hasAmount,
  });

  @override
  Widget build(BuildContext context) {
    final String message;
    if (!hasAmount) {
      message = 'Type an amount to see the rest of the recipe change.';
    } else if (scale.isAsWritten) {
      message = 'That is the recipe exactly as it is written.';
    } else {
      message = 'Every amount below is '
          '${barrioFormatMultiplier(scale.multiplier)} times the recipe.';
    }
    return Container(
      key: const ValueKey<String>('barrio_recipe_scale_multiplier'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(BarrioRadii.chip),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Text(
        message,
        style: GoogleFonts.ibmPlexSans(
          fontSize: 12.5,
          height: 1.45,
          fontWeight: FontWeight.w600,
          color: BarrioColors.textPrimary,
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  final String label;

  const _SectionHeading(this.label);

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: GoogleFonts.ibmPlexMono(
        fontSize: 10.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.0,
        color: BarrioColors.textMuted,
      ),
    );
  }
}

/// One line that moved. Tapping it makes it the ingredient the cook is
/// starting from.
class _ScalableRow extends StatelessWidget {
  final int index;
  final BarrioScaledIngredient entry;
  final Color accent;
  final bool isAnchor;
  final VoidCallback onTap;

  const _ScalableRow({
    required this.index,
    required this.entry,
    required this.accent,
    required this.isAnchor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // The two lines whose unit the operator confirmed rather than the
    // recipe printing it. Shown on the row rather than beside the amount
    // box so the note is there whether or not the cook is starting from
    // that line.
    final unitNote = barrioUnitSourceNote(entry.line);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MergeSemantics(
        child: Semantics(
          button: true,
          selected: isAnchor,
          child: GestureDetector(
            key: ValueKey<String>('barrio_recipe_scaled_row_$index'),
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isAnchor
                    ? accent.withValues(alpha: 0.07)
                    : BarrioColors.shellMid,
                borderRadius: BorderRadius.circular(BarrioRadii.card),
                border: Border.all(
                  color: isAnchor
                      ? accent.withValues(alpha: 0.55)
                      : BarrioColors.hairline,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.line.name,
                          style: GoogleFonts.ibmPlexSans(
                            fontSize: 13,
                            height: 1.4,
                            color: BarrioColors.textPrimary,
                          ),
                        ),
                        if (isAnchor) ...[
                          const SizedBox(height: 3),
                          Text(
                            'Starting from this one',
                            style: GoogleFonts.ibmPlexMono(
                              fontSize: 10,
                              letterSpacing: 0.4,
                              color: accent,
                            ),
                          ),
                        ],
                        if (unitNote != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            unitNote,
                            style: GoogleFonts.ibmPlexSans(
                              fontSize: 11,
                              height: 1.4,
                              color: BarrioColors.textMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          entry.scaledText ?? '',
                          textAlign: TextAlign.end,
                          style: GoogleFonts.ibmPlexMono(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: BarrioColors.textPrimary,
                          ),
                        ),
                        // The written amount stays visible whenever it is
                        // no longer the amount on the left, so a cook can
                        // always see what changed.
                        if (entry.changed) ...[
                          const SizedBox(height: 2),
                          Text(
                            'was ${entry.originalText}',
                            textAlign: TextAlign.end,
                            style: GoogleFonts.ibmPlexMono(
                              fontSize: 11,
                              color: BarrioColors.textMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One line that may not be multiplied: shown exactly as the card printed
/// it, with the reason it did not move.
class _HeldRow extends StatelessWidget {
  final int index;
  final BarrioScaledIngredient entry;

  const _HeldRow({required this.index, required this.entry});

  @override
  Widget build(BuildContext context) {
    final hold = entry.line.hold;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MergeSemantics(
        child: Container(
          key: ValueKey<String>('barrio_recipe_held_row_$index'),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: BarrioColors.shellSurface,
            borderRadius: BorderRadius.circular(BarrioRadii.card),
            border: Border.all(color: BarrioColors.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.line.raw,
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 13,
                  height: 1.4,
                  color: BarrioColors.textPrimary,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                hold == null ? '' : barrioHoldReason(hold),
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 11.5,
                  height: 1.45,
                  color: BarrioColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 42,
        height: 4,
        margin: const EdgeInsets.only(top: 10, bottom: 10),
        decoration: BoxDecoration(
          color: const Color(0x3316243B),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
