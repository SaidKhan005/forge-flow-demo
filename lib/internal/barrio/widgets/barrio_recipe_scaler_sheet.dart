// The recipe calculator, as a bottom sheet.
//
// A CALCULATOR AND NOTHING ELSE (operator direction, REC-6, 2026-08-13:
// "I want the calculator to just be a calculator, no verbage, just keep it
// simple as possible and intuitive as possible, no jargon"). What is on
// screen is the ingredient list at the current scale, one box to type in,
// and the multiplier as a number. There is no heading, no instruction, no
// recipe title, no section labels, and no sentence explaining any line.
// The first release carried all of those; they were deleted, not hidden.
//
// HOW IT WORKS. Every amount is a box. Tapping one picks that ingredient
// and puts the cursor in it; typing an amount moves every other amount.
// An empty box shows what the recipe wrote, greyed, so the list opens as
// the recipe was written.
//
// A LINE WITH NO NUMBER JUST SITS THERE. 'Salt TT' has nothing to
// multiply, so it prints exactly as the card printed it, with no box, no
// badge and no explanation. Silence is the whole treatment.
//
// WHY A SHEET, NOT SOMETHING ON THE CARD. The reader turns the page on a
// tap, and the page-turn zones live in a gesture arena with everything
// the card plants. Slice A9 already proved that adding a gesture-owning
// widget inside the card body kills page turns (see the DO NOT MOVE note
// on `_buildSelectableDeck` in `training_doc_screen.dart`). A modal route
// sits on its own Navigator entry, above that arena entirely, so a text
// field in here can never race the reader's tap. The card carries only a
// button, which is the same shape as the bookmark toggle that has been
// safe there since rec #8.
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
  required List<BarrioRecipeIngredient> lines,
  required Color accent,
}) {
  return showModalBottomSheet<void>(
    context: context,
    // The keyboard has to be able to push the sheet up without the
    // amount box going under it.
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => BarrioRecipeScalerSheet(lines: lines, accent: accent),
  );
}

/// Bottom sheet that scales one recipe from one ingredient.
class BarrioRecipeScalerSheet extends StatefulWidget {
  /// Every ingredient line of that card, in reading order.
  final List<BarrioRecipeIngredient> lines;

  /// The owning manual's identity color.
  final Color accent;

  const BarrioRecipeScalerSheet({
    super.key,
    required this.lines,
    required this.accent,
  });

  @override
  State<BarrioRecipeScalerSheet> createState() =>
      _BarrioRecipeScalerSheetState();
}

class _BarrioRecipeScalerSheetState extends State<BarrioRecipeScalerSheet> {
  final TextEditingController _amount = TextEditingController();
  final FocusNode _focus = FocusNode();

  /// The line the cook is typing against. Null only for a recipe with no
  /// number anywhere in it, which the manual does not currently contain.
  BarrioRecipeIngredient? _anchor;

  @override
  void initState() {
    super.initState();
    final anchors = barrioAnchorLines(widget.lines);
    if (anchors.isNotEmpty) _anchor = anchors.first;
  }

  @override
  void dispose() {
    _amount.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Starts from [line], with an empty box. The list therefore goes back
  /// to the recipe as written rather than carrying a rounded amount
  /// across, which would nudge the multiplier every time the cook changed
  /// their mind.
  void _pick(BarrioRecipeIngredient line) {
    setState(() {
      _anchor = line;
      _amount.clear();
    });
    _focus.requestFocus();
  }

  /// The amount the cook typed, or null when the box is empty or holds
  /// nothing that is a batch: a half-typed '.', a zero, a negative. A
  /// comma is read as a decimal point, because some keyboards offer one
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
    final multiplier =
        barrioRecipeMultiplier(anchor: _anchor, amount: _typedAmount);
    // The amount column keeps its proportions as the reader's text grows,
    // so the ingredient names stay lined up at every text size.
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final amountWidth = 100 * textScale;

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
        // Keeps the amount box above the keyboard instead of behind it.
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TopBar(multiplier: multiplier, accent: widget.accent),
            Flexible(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 22),
                itemCount: widget.lines.length,
                itemBuilder: (BuildContext context, int index) {
                  final line = widget.lines[index];
                  final isAnchor = identical(line, _anchor);
                  return _IngredientRow(
                    index: index,
                    line: line,
                    multiplier: multiplier,
                    amountWidth: amountWidth,
                    accent: widget.accent,
                    controller: isAnchor ? _amount : null,
                    focusNode: isAnchor ? _focus : null,
                    onChanged: isAnchor ? () => setState(() {}) : null,
                    onPick: isAnchor ? null : () => _pick(line),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The drag handle, with the multiplier as a number beside it.
///
/// A number, not a sentence: 'x2.5' is the whole readout. It is the one
/// thing on the sheet that is not an ingredient line, and it earns that
/// because it is how a cook checks the answer at a glance.
class _TopBar extends StatelessWidget {
  final double multiplier;
  final Color accent;

  const _TopBar({required this.multiplier, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
      child: Row(
        children: [
          const Expanded(child: SizedBox.shrink()),
          Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: BarrioColors.hairline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                'x${barrioFormatMultiplier(multiplier)}',
                key: const ValueKey<String>('barrio_recipe_scale_multiplier'),
                textAlign: TextAlign.end,
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: accent,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One ingredient line: its amount, then what it is an amount of.
///
/// Three shapes, and the row picks its own:
///
///   * the picked line puts the cook's box where its amount goes;
///   * any other line with a number shows that amount in a box the cook
///     can tap to start typing there instead;
///   * a line with no number shows nothing in the amount column and
///     prints its own text, exactly as the card printed it.
class _IngredientRow extends StatelessWidget {
  final int index;
  final BarrioRecipeIngredient line;
  final double multiplier;
  final double amountWidth;
  final Color accent;

  /// Set only on the picked line.
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final VoidCallback? onChanged;

  /// Set only on a line the cook could pick instead.
  final VoidCallback? onPick;

  const _IngredientRow({
    required this.index,
    required this.line,
    required this.multiplier,
    required this.amountWidth,
    required this.accent,
    this.controller,
    this.focusNode,
    this.onChanged,
    this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final name = Text(
      line.name,
      style: GoogleFonts.ibmPlexSans(
        fontSize: 14,
        height: 1.4,
        color: BarrioColors.textPrimary,
      ),
    );

    if (controller != null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: amountWidth,
              child: _AmountField(
                controller: controller!,
                focusNode: focusNode,
                line: line,
                accent: accent,
                onChanged: onChanged!,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: name,
            )),
          ],
        ),
      );
    }

    final scaled = barrioScaledAmount(line, multiplier);
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: amountWidth,
          child: scaled == null
              ? const SizedBox.shrink()
              : _AmountBox(text: scaled),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: name,
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MergeSemantics(
        child: onPick == null
            ? row
            : Semantics(
                button: true,
                child: GestureDetector(
                  key: ValueKey<String>('barrio_recipe_row_$index'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onPick!();
                  },
                  child: row,
                ),
              ),
      ),
    );
  }
}

/// One amount the cook is not typing in, shown the way the box they can
/// type in is shown, because tapping it is what makes it that box.
class _AmountBox extends StatelessWidget {
  final String text;

  const _AmountBox({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: BarrioColors.shellMid,
        borderRadius: BorderRadius.circular(BarrioRadii.card),
        border: Border.all(color: BarrioColors.hairline),
      ),
      child: Text(
        text,
        style: GoogleFonts.ibmPlexMono(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: BarrioColors.textPrimary,
        ),
      ),
    );
  }
}

/// The one box the cook types in, fixed to its own line's unit.
///
/// No unit picker and no conversion: the suffix names the unit the recipe
/// already used, so the number typed here means the same thing the card
/// meant. Left empty, the hint shows the amount the recipe wrote, which
/// is what makes an untouched sheet the recipe as written.
class _AmountField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final BarrioRecipeIngredient line;
  final Color accent;
  final VoidCallback onChanged;

  const _AmountField({
    required this.controller,
    required this.focusNode,
    required this.line,
    required this.accent,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final unit = line.unit ?? '';
    final written = line.quantity;
    return TextField(
      key: const ValueKey<String>('barrio_recipe_scale_amount'),
      controller: controller,
      focusNode: focusNode,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
      ],
      onChanged: (_) => onChanged(),
      style: GoogleFonts.ibmPlexMono(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: BarrioColors.textPrimary,
      ),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: BarrioColors.shellMid,
        hintText: written == null ? null : barrioFormatRecipeAmount(written),
        hintStyle: GoogleFonts.ibmPlexMono(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: BarrioColors.textMuted,
        ),
        suffixText: unit.isEmpty ? null : unit,
        suffixStyle: GoogleFonts.ibmPlexMono(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: accent,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(BarrioRadii.card),
          borderSide: BorderSide(color: accent.withValues(alpha: 0.55)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(BarrioRadii.card),
          borderSide: BorderSide(color: accent.withValues(alpha: 0.55)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(BarrioRadii.card),
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
      ),
    );
  }
}
