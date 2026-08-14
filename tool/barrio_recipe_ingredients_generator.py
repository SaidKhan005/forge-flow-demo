"""Generate the structured ingredient bank for the Barrio Recipes manual.

Usage: run from the repo root with `python tool/barrio_recipe_ingredients_generator.py`.
Rewrites lib/internal/barrio/content/recipes/barrio_recipe_ingredients.dart;
regeneration must be byte-identical unless the recipe content changed. Add
`--check` to render in memory and compare without writing (exits non-zero if a
real run would change the committed file), and `--report` to print the full
per-line table instead of writing anything.

WHY THIS EXISTS. The reading card renders a recipe's ingredient list as
verbatim text, which is all a cook needs. A scaling calculator needs the same
lines as DATA: which part of the line is the amount, what number is in it, and
what the ingredient is. This file is that second view, and nothing else: it
never restates a body, it only indexes one.

WHERE THE LINES COME FROM. The parser reads the GENERATED content file
(lib/internal/barrio/content/training/training_recipes_content.dart), not the
source markdown, so every `raw` it emits is lifted character-for-character out
of the body the reader actually sees. An ingredient line is a body paragraph
that opens with the Markdown list bullet `- ` (the recipe manual is the only
doc whose ingredient blocks are lists, which is why this generator is scoped
to that one doc). test/barrio_recipe_ingredients_test.dart re-proves the tie
against the LIVE Dart constant, so a drifted regeneration fails loudly instead
of letting a calculator scale numbers the reader was never shown.

THE RULE, IN ONE SENTENCE (operator direction, REC-6, 2026-08-13):
a line that carries a number can be multiplied, and a line that carries no
number cannot.

That is the whole of it. There is no category of number that is held back.
'1 Jar Aji Amarillo' at 2.5 times reads '2.5 Jar'; '2 Stalks Celery' at 2.4
times reads '4.8 Stalks'. The operator was shown that reading twice and chose
it: a cook can round a jar count in their head, and a calculator that refused
to move half the list was doing more explaining than arithmetic. The four
'hold' reasons this file used to emit, and the sentences that went with them,
are gone.

WHAT THE UNIT VOCABULARY DECIDES NOW. Only where the amount ENDS, which is a
question of layout, not of honesty. '2 Stalks Celery' shows '2 Stalks' beside
'Celery'; '12 Eggs' shows '12' beside 'Eggs'. Both scale either way, so a
measure word missing from the vocabulary now costs a tidy column rather than a
working calculator line. RULE_PROBES at the foot of this file still pins the
split, because a wrong split reads as a wrong ingredient name.

THE FOUR SHAPES A LINE CAN TAKE.

  * a range   - two numbers with a hyphen between them, and a unit on either
                or both sides: '8-10lbs of beets', '2kg-2.5kg Shrimp Shells',
                '9-10 Roma Tomatoes'. Both numbers scale.
  * a leading amount - the ordinary case: '500mL Olive Oil', '12 Eggs'.
  * a trailing amount - the operator wrote the measurement after the
                ingredient: 'Lime 300mL'. Accepted only when the line ends in
                a number glued or spaced to a word this file knows as a unit,
                which is why 'L5S TT' and 'The Peel of One Orange' stay out.
  * no number - nothing to multiply: 'Salt TT', 'One Large Onion Red Small
                Dice'. These carry no amount and the calculator prints them
                exactly as written, with nothing said about it.

ONE LINE HAS NO AMOUNT COLUMN OF ITS OWN. '(30g) 4-5 Habanero Peppers
(deseeded and deribbed)' opens with a parenthesised weight and then gives a
count of peppers, so it carries two quantities that mean the same thing and
neither of them can be THE amount. It is parsed as a line with no amount, so
the calculator gives it no box to type in. Its numbers still move: see THE
NUMBERS INSIDE A NAME below.

THE NUMBERS INSIDE A NAME (REC-8, 2026-08-14). An amount is not the only place
a recipe line writes a number. Five lines of the manual write a second one
into the ingredient itself, and until REC-8 the calculator moved the amount
and left that one standing, so '180g White/Black Sesame Seed (90g each)' at
twice the batch read '360g White/Black Sesame Seed (90g each)': two numbers on
one line contradicting each other, and a cook weighing to the parenthesis puts
in half what the dish needs.

The rule, in one sentence: EVERY number written in an ingredient line is an
amount of that ingredient and moves with the batch, except a percentage and a
digit that is part of a word.

  * a PERCENTAGE is a ratio between two amounts of the same recipe ('70g Salt
    ( 1.75% weight of beets)'). Scaling both amounts leaves the ratio exactly
    where it was, so scaling the ratio too would be counting it twice.
  * a DIGIT GLUED TO THE LETTER BEFORE IT is part of a word, not a number:
    'L5S TT' is a product code, and 'L10S' at twice the batch would be an
    ingredient that does not exist.

NAME_NUMBERS_HELD lists, by hand, every number the manual actually holds back
under those two clauses, and `check_name_numbers` fails the run if the rule
starts holding a different set. That is what stops a future line quietly
shipping a number that sits still while the line around it moves.

OPERATOR-CONFIRMED UNITS. Two lines of the manual are weights the source never
spelled out. See OPERATOR_CONFIRMED_UNITS.
"""
import collections
import os
import re
import sys

CONTENT = ('lib/internal/barrio/content/training/'
           'training_recipes_content.dart')
OUT = ('lib/internal/barrio/content/recipes/'
       'barrio_recipe_ingredients.dart')

# Words that, sitting straight after a number, belong to the AMOUNT rather
# than to the ingredient's name.
#
# Mass and volume, containers, and whole countable things are one list now,
# because nothing downstream treats them differently: they all just scale. The
# spelled-out forms are here even though the manual writes none of them, so a
# real weight written out ('500 grams Chicken') still reads as '500 grams'
# beside 'Chicken' rather than as '500' beside 'grams Chicken'.
UNIT_WORDS = {
    # mass and volume
    'g', 'kg', 'mg', 'lb', 'lbs', 'oz',
    'ml', 'l', 'tsp', 'tbsp', 'cup', 'cups',
    'gram', 'grams', 'kilogram', 'kilograms', 'milligram', 'milligrams',
    'pound', 'pounds', 'ounce', 'ounces',
    'millilitre', 'millilitres', 'milliliter', 'milliliters',
    'litre', 'litres', 'liter', 'liters',
    'teaspoon', 'teaspoons', 'tablespoon', 'tablespoons',
    # containers off a shelf
    'jar', 'jars', 'can', 'cans', 'bag', 'bags', 'bottle', 'bottles',
    'tin', 'tins', 'case', 'cases', 'box', 'boxes',
    # whole things a cook picks up
    'piece', 'pieces', 'pc', 'pcs', 'clove', 'cloves', 'stalk', 'stalks',
    'bunch', 'bunches', 'head', 'heads', 'sprig', 'sprigs', 'leaf', 'leaves',
    'slab', 'slabs', 'stick', 'sticks',
}

# Vulgar fractions the operator's kitchen actually types.
VULGAR = {
    '¼': '0.25', '½': '0.5', '¾': '0.75',
    '⅓': '0.3333333333333333', '⅔': '0.6666666666666666',
    '⅛': '0.125', '⅜': '0.375', '⅝': '0.625',
    '⅞': '0.875',
}

_NUM = r'(?:\d+(?:\.\d+)?(?:/\d+(?:\.\d+)?)?|[' + ''.join(VULGAR) + r'])'
_UNIT = r'[A-Za-z]+'

# A range: two numbers joined by a hyphen, with a unit on either or both.
RANGE_RE = re.compile(
    r'^(' + _NUM + r')\s*(' + _UNIT + r')?\s*-\s*(' + _NUM + r')\s*('
    + _UNIT + r')?(?![\w-])\s*(.*)$', re.S)
# A single leading quantity, with an optional unit word glued to or after it.
SINGLE_RE = re.compile(
    r'^(' + _NUM + r')\s*(' + _UNIT + r')?(?![\w-])\s*(.*)$', re.S)
# An amount written at the END of the line instead of the start, which is how
# one line of the manual is written ('Lime 300mL'). Tight on purpose: the
# number must open a word boundary and the unit must run to the end of the
# line, so 'L5S TT' and 'The Peel of One Orange' do not match.
TRAILING_RE = re.compile(
    r'(?<![\w.])(' + _NUM + r')\s*(' + _UNIT + r')$')

# Units the OPERATOR confirmed for lines the source prints with no unit at
# all, keyed to the exact line text.
#
# WHY THIS EXISTS. The Recipes source is the operator's own working document,
# and two of its lines are weights written as a bare number. Sitting among
# gram lines in their own cards ('470g Corn Nuts', '478g Red Wine Vinegar'),
# they are plainly grams, but a parser must not guess that. The operator was
# asked and confirmed both on 2026-08-13.
#
# WHAT IT DOES NOT DO. It does not touch the card body. The reader still sees
# the line exactly as the operator wrote it, with no unit, because the
# verbatim law is not negotiable. Only this structured second view carries the
# unit, and it is the one place a calculator shows a unit the page did not.
#
# WHY KEYED TO THE WHOLE RAW LINE. A confirmation is a fact about one exact
# line. Keyed to anything looser it could drift onto a different ingredient
# the next time the manual changes. `check_operator_confirmations` fails the
# run if a key stops appearing, appears more than once, or stops being read as
# a bare count, so a stale confirmation can never be applied quietly.
OPERATOR_CONFIRMED_UNITS = {
    # Beef Skewer Topping, confirmed by the operator 2026-08-13.
    '235 Pumpkin Seeds': 'g',
    # Pork Belly Glaze, confirmed by the operator 2026-08-13.
    '654 Canola Oil': 'g',
}

# Every number this file deliberately leaves standing inside an ingredient
# NAME, taken by hand off the manual on 2026-08-14: the exact line, the exact
# number, and why it does not move.
#
# WHY IT IS A HAND-WRITTEN TABLE. `name_numbers` below decides for itself
# which numbers hold, so a check that re-asked it would prove nothing. This
# table is the independent reference: `check_name_numbers` fails the run when
# the rule holds back a number that is not listed here, or stops holding one
# that is. A new recipe line carrying a number that would sit still while the
# line around it moves therefore stops the generator instead of shipping a
# contradiction to a cook.
NAME_NUMBERS_HELD = {
    # Pickled Beets. Salt is 1.75% of the beets at every batch size.
    ('70g Salt ( 1.75% weight of beets)', '1.75'):
        'a percentage is a ratio between two amounts of the same recipe, so '
        'scaling both of them leaves it exactly where it was',
    # Guacamole and Pico de Gallo both print this one.
    ('L5S TT', '5'):
        'the digit sits inside a word, so it is part of the product code and '
        'not a number',
}

# One parsed ingredient line. Named rather than positional because the reader
# below has to be able to see which field is which. `unit_from_operator` is
# NOT emitted to Dart: nothing renders it any more (the calculator says
# nothing about where a unit came from), and it is kept here only so
# `check_operator_confirmations` can prove the confirmation still lands.
Parsed = collections.namedtuple(
    'Parsed',
    'quantity quantity_high unit amount name unit_from_operator name_numbers')
Row = collections.namedtuple(
    'Row',
    'raw quantity quantity_high unit amount name unit_from_operator '
    'name_numbers')


def to_number(token):
    """'2.5' / '1/4' / a vulgar fraction -> a float, or None."""
    token = VULGAR.get(token, token)
    if '/' in token:
        top, bottom = token.split('/', 1)
        try:
            return float(top) / float(bottom)
        except (ValueError, ZeroDivisionError):
            return None
    try:
        return float(token)
    except ValueError:
        return None


def clean_name(rest):
    """The ingredient name: the line minus its amount, minus a lead 'of '."""
    name = rest.strip()
    name = re.sub(r'^of\s+', '', name, flags=re.I)
    return name.strip()


def is_unit(word):
    """Whether [word] belongs to the amount rather than to the name."""
    return word is not None and word.lower() in UNIT_WORDS


def name_numbers(name):
    """One entry per number inside [name], in the order it is written.

    The entry is the number's own value when it moves with the batch, and
    None when it stays exactly as written. The two None clauses are stated
    once in this file's header and listed line by line in NAME_NUMBERS_HELD.

    The order and the count have to match what Dart's own number pattern
    finds in the same string, because `barrioScaledName` walks the two in
    step. `test/barrio_recipe_ingredients_test.dart` re-derives both from
    the live manual and fails if they ever disagree.
    """
    out = []
    for m in re.finditer(_NUM, name):
        before = name[m.start() - 1] if m.start() else ''
        ratio = re.match(r'\s*(?:%|percent\b)', name[m.end():], re.I)
        held = ratio is not None or before.isalnum()
        out.append(None if held else to_number(m.group(0)))
    return out


def _parsed(quantity, quantity_high, unit, amount, name, from_operator):
    """A [Parsed] with its name's own numbers read off that name."""
    return Parsed(quantity, quantity_high, unit, amount, name, from_operator,
                  name_numbers(name))


def parse_line(raw):
    """One ingredient line -> a [Parsed]. The whole rule lives here."""
    text = raw.strip()

    m = RANGE_RE.match(text)
    if m:
        low, low_unit, high, high_unit, _rest = m.groups()
        # Either unit slot may in fact hold the first word of the ingredient
        # name ('9-10 Roma Tomatoes'), so a slot only counts as a unit when it
        # holds a word UNIT_WORDS recognises. Whatever is left of the line
        # after the accepted amount is the name, sliced out of the original
        # text so its spacing survives.
        if is_unit(high_unit):
            unit, cut = high_unit, m.end(4)
        elif is_unit(low_unit):
            unit, cut = low_unit, m.end(3)
        else:
            unit, cut = None, m.end(3)
        return _parsed(to_number(low), to_number(high), unit,
                       text[:cut], clean_name(text[cut:]), False)

    m = SINGLE_RE.match(text)
    if m:
        number, unit, rest = m.groups()
        quantity = to_number(number)
        if quantity is not None:
            if is_unit(unit):
                return _parsed(quantity, None, unit, text[:m.end(2)],
                               clean_name(rest), False)
            # The word attached to the number is not a unit, so it belongs to
            # the ingredient's own name and the amount is the bare number:
            # '12 Eggs', '3 Corn Tortillas', '1 Whole Can Chipotle Pepper'.
            name = clean_name('{} {}'.format(unit, rest) if unit else rest)
            confirmed = OPERATOR_CONFIRMED_UNITS.get(text)
            return _parsed(quantity, None, confirmed, text[:m.end(1)], name,
                           confirmed is not None)

    m = TRAILING_RE.search(text)
    if m and is_unit(m.group(2)):
        quantity = to_number(m.group(1))
        name = clean_name(text[:m.start()])
        if quantity is not None and name:
            return _parsed(quantity, None, m.group(2), text[m.start():], name,
                           False)

    return _parsed(None, None, None, None, text, False)


# --- Reading the generated content file -----------------------------------

_LITERAL = r"((?:'(?:[^'\\]|\\.)*'\s*)+)"
UNIT_RE = re.compile(
    r"HandbookUnit\(\s*id: '([^']+)',.*?body: " + _LITERAL + r',', re.S)


def unescape(literal):
    """Adjacent single-quoted Dart string literals -> the string they hold."""
    parts = re.findall(r"'((?:[^'\\]|\\.)*)'", literal)
    text = ''.join(parts)
    out, i = [], 0
    while i < len(text):
        ch = text[i]
        if ch == '\\' and i + 1 < len(text):
            nxt = text[i + 1]
            out.append({'n': '\n', 't': '\t', 'r': '\r'}.get(nxt, nxt))
            i += 2
            continue
        out.append(ch)
        i += 1
    return ''.join(out)


def read_units(path):
    """[(unit_id, body)] in file order, straight out of the generated Dart."""
    src = open(path, encoding='utf-8').read()
    return [(m.group(1), unescape(m.group(2))) for m in UNIT_RE.finditer(src)]


def ingredient_lines(body):
    """Body paragraphs that are Markdown list items, bullet stripped."""
    return [p[2:].strip() for p in body.split('\n\n')
            if p.startswith('- ') and p[2:].strip()]


def collect(path):
    """[(unit_id, [Row])] for every card that prints an ingredient line."""
    out = []
    for unit_id, body in read_units(path):
        rows = [Row(raw, *parse_line(raw)) for raw in ingredient_lines(body)]
        if rows:
            out.append((unit_id, rows))
    return out


def check_row_shapes(rows_by_unit):
    """Fail the run if a parsed row could not be rendered honestly.

    Three invariants the whole calculator rests on, checked against the real
    manual on every invocation rather than left to a downstream test:

      * an amount and a quantity arrive together or not at all, because the
        Dart side reads the number back OUT of the amount text;
      * the amount is a literal slice of the line, so a cook never reads a
        number the card did not print;
      * the amount carries exactly as many numbers as the row claims, so the
        substitution that scales it cannot silently miss one.
    """
    number = re.compile(_NUM)
    problems = []
    for unit_id, rows in rows_by_unit:
        for row in rows:
            where = '{}: {!r}'.format(unit_id, row.raw)
            if (row.amount is None) != (row.quantity is None):
                problems.append('{}: amount {!r} and quantity {!r} disagree '
                                'about whether the line has a number'
                                .format(where, row.amount, row.quantity))
                continue
            if row.amount is None:
                if row.quantity_high is not None:
                    problems.append('{}: a range with no amount text'
                                    .format(where))
                continue
            if row.amount not in row.raw:
                problems.append('{}: amount {!r} is not printed by the line'
                                .format(where, row.amount))
            found = len(number.findall(row.amount))
            wanted = 1 if row.quantity_high is None else 2
            if found != wanted:
                problems.append('{}: amount {!r} holds {} number(s) but the '
                                'row carries {}'
                                .format(where, row.amount, found, wanted))
            if not row.name.strip():
                problems.append('{}: the line names no ingredient'
                                .format(where))
    if problems:
        raise SystemExit('parsed rows are not renderable:\n  '
                         + '\n  '.join(problems))


def check_name_numbers(rows_by_unit):
    """Fail the run if a number inside an ingredient NAME stops moving.

    A number the calculator leaves standing while the line around it moves
    is the REC-8 defect: two numbers on one line saying different batches.
    Exactly two clauses may hold a number back, and every line they fire on
    is written out by hand in NAME_NUMBERS_HELD, so this compares the rule's
    behaviour against a reference the rule did not produce.

    Both directions fail loudly:

      * a held number that is not in the table means a new line ships a
        number that will contradict its own amount;
      * a table entry the rule no longer holds means the line changed and
        the hand-written reason is now about nothing.
    """
    held = set()
    for _unit_id, rows in rows_by_unit:
        for row in rows:
            tokens = re.findall(_NUM, row.name)
            for token, value in zip(tokens, row.name_numbers):
                if value is None:
                    held.add((row.raw, token))

    problems = []
    for key in sorted(held - set(NAME_NUMBERS_HELD)):
        problems.append(f'{key[1]!r} in {key[0]!r} is held back with no '
                        f'reason on record, so it would sit still while the '
                        f'rest of that line moves')
    for key in sorted(set(NAME_NUMBERS_HELD) - held):
        problems.append(f'{key[1]!r} in {key[0]!r} is listed as held back '
                        f'but the rule now moves it (or the line is gone), '
                        f'so the recorded reason is about nothing')
    if problems:
        raise SystemExit(
            'the numbers written inside ingredient names no longer match '
            'the hand-written record:\n  ' + '\n  '.join(problems)
            + '\nDecide whether the new number is an amount (it moves) or a '
              'ratio (it holds), then update NAME_NUMBERS_HELD in '
              'tool/barrio_recipe_ingredients_generator.py.')


def check_operator_confirmations(rows_by_unit):
    """Fail the run if an operator-confirmed line stopped being what it was.

    A confirmation is a fact taken by hand about ONE exact line on ONE date.
    Three ways it can go stale, all of them silent without this check:

      * the line stops appearing in the manual, so the confirmation is about
        nothing;
      * the same text turns up on a second card, so one confirmation would
        land on two ingredients;
      * the line starts printing its own unit (or becomes a range), so the
        parser no longer reaches the arm that applies the confirmed unit and
        the entry is dead weight nobody notices.

    Any of them means a human has to go back to the operator, which is
    exactly what a loud failure asks for.
    """
    seen = collections.Counter()
    applied = collections.Counter()
    for _unit_id, rows in rows_by_unit:
        for row in rows:
            if row.raw in OPERATOR_CONFIRMED_UNITS:
                seen[row.raw] += 1
                if row.unit_from_operator:
                    applied[row.raw] += 1

    problems = []
    for raw, unit in sorted(OPERATOR_CONFIRMED_UNITS.items()):
        if not seen[raw]:
            problems.append(f'{raw!r}: no longer printed anywhere in the '
                            f'manual, so the confirmed unit {unit!r} is a '
                            f'fact about nothing')
        elif seen[raw] > 1:
            problems.append(f'{raw!r}: printed {seen[raw]} times, so one '
                            f'confirmation would attach {unit!r} to more '
                            f'than one ingredient')
        elif applied[raw] != 1:
            problems.append(f'{raw!r}: still printed, but the parser no '
                            f'longer reads it as a number with no unit '
                            f'word, so {unit!r} was never applied')
    if problems:
        raise SystemExit(
            'operator-confirmed units are stale:\n  ' + '\n  '.join(problems)
            + '\nRe-take the confirmation with the operator, then update '
              'OPERATOR_CONFIRMED_UNITS in '
              'tool/barrio_recipe_ingredients_generator.py.')


# --- Emitting the Dart ----------------------------------------------------

def esc(s):
    return s.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$')


def dart_number(value):
    """A quantity as a Dart double literal, exact for the common cases."""
    if value == int(value):
        return f'{int(value)}'
    return repr(round(value, 6))


def emit(rows_by_unit):
    lines = []
    a = lines.append
    a('// GENERATED RECIPE INGREDIENT DATA - regenerate, do not hand-edit.')
    a('//')
    a(f'// Source: {CONTENT}')
    a('// Generator: tool/barrio_recipe_ingredients_generator.py')
    a('//')
    a('// Every `raw` below is lifted character-for-character out of the card')
    a('// body it is keyed to, so the reader and the calculator can never')
    a('// show two different numbers. test/barrio_recipe_ingredients_test.dart')
    a('// re-proves that tie against the live doc, and proves the parse covers')
    a('// every ingredient line with nothing silently dropped.')
    a('//')
    a('// `amount` is the part of the line that is the amount, sliced out of')
    a('// `raw` itself. Scaling rewrites the numbers inside it and leaves')
    a('// everything else alone, so a scaled line is spaced and worded the')
    a('// way the card spaced and worded it.')
    a('//')
    a('// A line with a `quantity` can be multiplied; a line without one has')
    a('// nothing to multiply and prints as written. `quantityHigh` is the')
    a('// second number of a range, and it scales alongside the first.')
    a('//')
    a('// `nameNumbers` is one entry per number written inside the ingredient')
    a('// itself, in the order it is written: the value it scales from, or')
    a('// null for a number that stays exactly as written (a percentage, or a')
    a('// digit inside a word). Absent when the name holds no number at all.')
    a('')
    a("import 'barrio_recipe_models.dart';")
    a('')
    a('/// Structured ingredient lines for the Recipes manual, keyed by the')
    a('/// `HandbookUnit` id of the card whose body carries them.')
    a('const Map<String, List<BarrioRecipeIngredient>> '
      'kBarrioRecipeIngredients =')
    a('    <String, List<BarrioRecipeIngredient>>{')
    for unit_id, rows in rows_by_unit:
        a(f"  '{esc(unit_id)}': <BarrioRecipeIngredient>[")
        for row in rows:
            a('    BarrioRecipeIngredient(')
            a(f"      raw: '{esc(row.raw)}',")
            a(f"      name: '{esc(row.name)}',")
            if row.amount is not None:
                a(f"      amount: '{esc(row.amount)}',")
            if row.quantity is not None:
                a(f'      quantity: {dart_number(row.quantity)},')
            if row.quantity_high is not None:
                a(f'      quantityHigh: {dart_number(row.quantity_high)},')
            if row.unit is not None:
                a(f"      unit: '{esc(row.unit)}',")
            if row.name_numbers:
                inner = ', '.join(
                    'null' if v is None else dart_number(v)
                    for v in row.name_numbers)
                a(f'      nameNumbers: <double?>[{inner}],')
            a('    ),')
        a('  ],')
    a('};')
    a('')
    return '\n'.join(lines)


# --- Proving the rule on lines the manual does not happen to contain ------

# (line, amount, name) that `parse_line` must produce.
#
# WHY THESE ARE NOT MANUAL LINES. The Dart guards check the split against the
# 203 lines the Recipes manual actually prints, which is the only thing that
# ships. They cannot check the BOUNDARY of the rule, because the manual has no
# line sitting on it. These probes are that boundary, written by hand. They
# run on every invocation, so the rule cannot drift without the generator
# refusing to produce data.
RULE_PROBES = [
    # A measure word belongs to the amount, abbreviated or spelled out.
    ('500g Chicken Thigh', '500g', 'Chicken Thigh'),
    ('500 g Chicken Thigh', '500 g', 'Chicken Thigh'),
    ('500 grams Chicken Thigh', '500 grams', 'Chicken Thigh'),
    ('2 Pounds Beef Shin', '2 Pounds', 'Beef Shin'),
    ('1.5 Litres Chicken Stock', '1.5 Litres', 'Chicken Stock'),
    ('3 Tablespoons Cumin', '3 Tablespoons', 'Cumin'),
    ('2 Cans Tomatoes', '2 Cans', 'Tomatoes'),
    ('2 Stalks Celery', '2 Stalks', 'Celery'),
    # A word that is not a unit belongs to the ingredient's name, and the
    # amount is the bare number.
    ('12 Eggs', '12', 'Eggs'),
    ('15 Avocados', '15', 'Avocados'),
    ('3 Corn Tortillas', '3', 'Corn Tortillas'),
    ('1 Large Red Onion Small Dice', '1', 'Large Red Onion Small Dice'),
    ('1 Whole Can Chipotle Pepper in Adobo Sauce', '1',
     'Whole Can Chipotle Pepper in Adobo Sauce'),
    # A range keeps both numbers, and the unit may sit on either side or
    # on both.
    ('8-10lbs of beets', '8-10lbs', 'beets'),
    ('2kg-2.5kg Shrimp Shells', '2kg-2.5kg', 'Shrimp Shells'),
    ('9-10 Roma Tomatoes', '9-10', 'Roma Tomatoes'),
    # An amount written after the ingredient still reads as an amount ...
    ('Lime 300mL', '300mL', 'Lime'),
    # ... but only when a real unit closes the line. These four carry no
    # number the calculator may touch, and 'L5S TT' is the one that would
    # break if the trailing rule went looking for any digit at all.
    ('Salt TT', None, 'Salt TT'),
    ('L5S TT', None, 'L5S TT'),
    ('The Peel of One Orange', None, 'The Peel of One Orange'),
    ('One Large Onion Red Small Dice', None, 'One Large Onion Red Small Dice'),
    # Deliberately unparsed: a parenthesised weight AND a count of peppers on
    # one line, so scaling either one leaves the other lying.
    ('(30g) 4-5 Habanero Peppers (deseeded and deribbed)', None,
     '(30g) 4-5 Habanero Peppers (deseeded and deribbed)'),
]


def check_rule_probes():
    """Fail the run if the amount/name split stops meaning what it says."""
    problems = []
    for line, want_amount, want_name in RULE_PROBES:
        got = parse_line(line)
        if got.amount != want_amount or got.name != want_name:
            problems.append(
                '{!r}: expected amount {!r} + name {!r}, got amount {!r} + '
                'name {!r}'.format(line, want_amount, want_name, got.amount,
                                   got.name))
    if problems:
        raise SystemExit(
            'the ingredient amount rule no longer holds:\n  '
            + '\n  '.join(problems))


# (ingredient name, the value each of its numbers scales from) that
# `name_numbers` must produce. None is a number that stays as written.
#
# WHY THESE ARE HERE. NAME_NUMBERS_HELD pins the rule against the lines the
# manual prints today; these pin its BOUNDARY, which the manual has no line
# sitting on. Both a percentage spelled with a space or as a word and a digit
# glued into a product code have to keep holding, and an ordinary
# parenthesised weight has to keep moving, whatever else is edited here.
NAME_NUMBER_PROBES = [
    # Nothing to move.
    ('Olive Oil', []),
    ('Pork Belly ( Half a Slab)', []),
    # The REC-8 defect itself: the split instruction moves with the amount.
    ('White/Black Sesame Seed (90g each)', [90.0]),
    ('Chipotle (One 7oz Can)', [7.0]),
    ('Rice Wine Vinegar ( 1 Bottle)', [1.0]),
    # A ratio holds, however it is written.
    ('Salt ( 1.75% weight of beets)', [None]),
    ('Salt ( 1.75 % weight of beets)', [None]),
    ('Salt ( 1.75 percent weight of beets)', [None]),
    # A digit inside a word is part of the word.
    ('L5S TT', [None]),
    ('Sanitizer Q7 Solution', [None]),
    # Every number of a line with no amount column of its own still moves,
    # together, so the weight and the count never disagree.
    ('(30g) 4-5 Habanero Peppers (deseeded and deribbed)', [30.0, 4.0, 5.0]),
]


def check_name_number_probes():
    """Fail the run if the in-name number rule stops meaning what it says."""
    problems = []
    for name, want in NAME_NUMBER_PROBES:
        got = name_numbers(name)
        if got != want:
            problems.append('{!r}: expected {!r}, got {!r}'
                            .format(name, want, got))
    if problems:
        raise SystemExit(
            'the in-name number rule no longer holds:\n  '
            + '\n  '.join(problems))


def rendered_bytes(out_path, text):
    """Match the line endings the checkout already uses (see the content
    generator's identical note: a CRLF checkout must not read as drift)."""
    data = text.encode('utf-8')
    if os.path.exists(out_path):
        with open(out_path, 'rb') as f:
            if b'\r\n' in f.read():
                data = data.replace(b'\n', b'\r\n')
    return data


def main():
    sys.stdout.reconfigure(encoding='utf-8')
    args = sys.argv[1:]
    check = '--check' in args
    report = '--report' in args
    unknown = [a for a in args if a not in ('--check', '--report')]
    if unknown:
        raise SystemExit(
            f'unknown argument(s): {", ".join(unknown)}. Usage: '
            f'barrio_recipe_ingredients_generator.py [--check] [--report]')

    check_rule_probes()
    check_name_number_probes()
    rows_by_unit = collect(CONTENT)
    check_row_shapes(rows_by_unit)
    check_name_numbers(rows_by_unit)
    check_operator_confirmations(rows_by_unit)
    total = sum(len(rows) for _uid, rows in rows_by_unit)
    scales = sum(1 for _uid, rows in rows_by_unit
                 for row in rows if row.quantity is not None)

    if report:
        for unit_id, rows in rows_by_unit:
            print(f'== {unit_id}')
            for row in rows:
                mark = 'SCALES' if row.quantity is not None else 'as written'
                if row.unit_from_operator:
                    mark += '*'
                if row.quantity_high is not None:
                    mark += ' (range)'
                print(f'   {mark:<20} amount={str(row.amount):<12} '
                      f'unit={row.unit or "":<8} name={row.name!r:<45} '
                      f'raw={row.raw!r}')
        print()
        print('* = unit confirmed by the operator, not printed by the recipe')
        print()
        print('lines the calculator prints exactly as written:')
        for unit_id, rows in rows_by_unit:
            for row in rows:
                if row.quantity is None:
                    print(f'   {unit_id}: {row.raw!r}')
        print()
        print('numbers written inside an ingredient name:')
        for unit_id, rows in rows_by_unit:
            for row in rows:
                if not row.name_numbers:
                    continue
                for token, value in zip(re.findall(_NUM, row.name),
                                        row.name_numbers):
                    verdict = 'HOLDS' if value is None else 'moves'
                    print(f'   {verdict:<6} {token:<6} in {row.raw!r}')
        print()

    print(f'recipes with ingredients: {len(rows_by_unit)}')
    print(f'ingredient lines: {total}  scales: {scales}  '
          f'as written: {total - scales}')
    ranges = sum(1 for _uid, rows in rows_by_unit
                 for row in rows if row.quantity_high is not None)
    print(f'   ranges (two numbers): {ranges}')
    if report:
        return

    text = emit(rows_by_unit)
    data = rendered_bytes(OUT, text)
    if check:
        current = open(OUT, 'rb').read() if os.path.exists(OUT) else None
        if current != data:
            raise SystemExit(
                f'barrio recipe ingredient drift: a generator run would '
                f'change {OUT}. The file is generated output; regenerate it '
                f'with: python tool/barrio_recipe_ingredients_generator.py')
        print(f'barrio recipe ingredient check: {OUT} matches a fresh run.')
        return
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'wb') as f:
        f.write(data)
    print(f'wrote {OUT}')


main()
