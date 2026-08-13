"""Generate the structured ingredient bank for the Barrio Recipes manual.

Usage: run from the repo root with `python tool/barrio_recipe_ingredients_generator.py`.
Rewrites lib/internal/barrio/content/recipes/barrio_recipe_ingredients.dart;
regeneration must be byte-identical unless the recipe content changed. Add
`--check` to render in memory and compare without writing (exits non-zero if a
real run would change the committed file), and `--report` to print the full
per-line classification table instead of writing anything.

WHY THIS EXISTS. The reading card renders a recipe's ingredient list as
verbatim text, which is all a cook needs. A scaling calculator needs the same
lines as DATA: which number is the quantity, what it measures, what the
ingredient is, and above all whether multiplying that number is honest. This
file is that second view, and nothing else: it never restates a body, it only
indexes one.

WHERE THE LINES COME FROM. The parser reads the GENERATED content file
(lib/internal/barrio/content/training/training_recipes_content.dart), not the
source markdown, so every `raw` it emits is lifted character-for-character out
of the body the reader actually sees. An ingredient line is a body paragraph
that opens with the Markdown list bullet `- ` (the recipe manual is the only
doc whose ingredient blocks are lists, which is why this generator is scoped
to that one doc). test/barrio_recipe_ingredients_test.dart re-proves the tie
against the LIVE Dart constant, so a drifted regeneration fails loudly instead
of letting a calculator scale numbers the reader was never shown.

THE SCALING RULE (one rule, applied to every line without exception).

A line is SCALABLE only when it carries exactly one number and that number is
attached to a unit of MASS or VOLUME. Those units divide cleanly at any
multiplier: half of 500mL is 250mL, and 1.4 times 210g is 294g.

Every other line is held back and carried through unchanged, for one of four
stated reasons:

  * noQuantity     - the line carries no leading number at all
                     ('Salt TT', 'The Peel of One Orange').
  * containerCount - it counts containers, and a shelf does not sell 2.5 of
                     them ('1 Jar Aji Amarillo', '2 Bags Yellow Corn Tortilla',
                     '1 Whole Can Chipotle Pepper in Adobo Sauce').
  * wholeItemCount - it counts whole items, and a fraction of one is nonsense
                     at the bench ('4 Cloves of garlic', '2 Stalks Celery',
                     '12 Eggs', '15 Avocados', '3 Corn Tortillas').
  * range          - the operator wrote a range, which is a judgement call
                     rather than a quantity ('8-10lbs of beets').

WHAT A NUMBER WITH NO UNIT WORD MEANS (widened 2026-08-13, REC-4). English
puts a countable noun straight after its number: '12 Eggs' counts eggs the
same way '2 Stalks Celery' counts stalks. The first release read the word
after the number against a vocabulary of unit words only, so a line that put
the counted noun in the ingredient NAME fell through to a fifth reason,
`noUnit`, which told the cook 'the recipe does not say what this number
measures'. That is true of a bare number, and plainly false of '12 Eggs'.

The rule is now stated the way the language works: a leading number whose
attached word is NOT a unit of measure counts the thing the line names. Which
count it is comes from the head of that name: a container word there means
containers ('1 Whole Can ...'), and anything else means whole items. Nothing
is keyed to a specific line, so a recipe added tomorrow classifies itself.

The vocabulary of measure words below carries the spelled-out forms as well
as the abbreviations for exactly this reason: under the widened rule any
measure word MISSING from it would read as a countable noun, and a real
weight ('500 grams Chicken') would stop scaling. RULE_PROBES at the foot of
this file re-proves that boundary on every run.

OPERATOR-CONFIRMED UNITS. Two lines of the manual are weights the source
never spelled out. See OPERATOR_CONFIRMED_UNITS.

A held line still carries whatever quantity and unit could be read off it, so
a calculator can SHOW them; `scalable: false` is what stops it multiplying
them.
"""
import collections
import os
import re
import sys

CONTENT = ('lib/internal/barrio/content/training/'
           'training_recipes_content.dart')
OUT = ('lib/internal/barrio/content/recipes/'
       'barrio_recipe_ingredients.dart')

# Units that measure mass or volume. Only these make a line scalable.
#
# The spelled-out forms are here even though the manual writes none of them
# today, because of the count rule in `parse_line`: a measure word this set
# does not know reads as a countable noun, and '500 grams Chicken' would be
# held as a count of 500 whole chickens instead of scaling. Recognising the
# word costs nothing and keeps the widened rule honest at its own boundary.
MASS_VOLUME_UNITS = {
    'g', 'kg', 'mg', 'lb', 'lbs', 'oz',
    'ml', 'l', 'tsp', 'tbsp', 'cup', 'cups',
    'gram', 'grams', 'kilogram', 'kilograms', 'milligram', 'milligrams',
    'pound', 'pounds', 'ounce', 'ounces',
    'millilitre', 'millilitres', 'milliliter', 'milliliters',
    'litre', 'litres', 'liter', 'liters',
    'teaspoon', 'teaspoons', 'tablespoon', 'tablespoons',
}

# Units that count a container off a shelf.
CONTAINER_UNITS = {
    'jar', 'jars', 'can', 'cans', 'bag', 'bags', 'bottle', 'bottles',
    'tin', 'tins', 'case', 'cases', 'box', 'boxes',
}

# Units that count a whole item a cook picks up.
WHOLE_ITEM_UNITS = {
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

# Reason names, mirrored one for one by the Dart enum this file emits.
NO_QUANTITY = 'noQuantity'
CONTAINER_COUNT = 'containerCount'
WHOLE_ITEM_COUNT = 'wholeItemCount'
RANGE = 'range'

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
# verbatim law is not negotiable. Only this structured second view carries
# the unit, and it carries a flag with it so the calculator can tell the cook
# where the unit came from.
#
# WHY KEYED TO THE WHOLE RAW LINE. A confirmation is a fact about one exact
# line. Keyed to anything looser it could drift onto a different ingredient
# the next time the manual changes. `check_operator_confirmations` fails the
# run if a key stops appearing, appears more than once, or stops being read
# as a bare count, so a stale confirmation can never be applied quietly.
OPERATOR_CONFIRMED_UNITS = {
    # Beef Skewer Topping, confirmed by the operator 2026-08-13.
    '235 Pumpkin Seeds': 'g',
    # Pork Belly Glaze, confirmed by the operator 2026-08-13.
    '654 Canola Oil': 'g',
}

# One parsed ingredient line. Named rather than positional because the
# reader below has to be able to see which field is which.
Parsed = collections.namedtuple(
    'Parsed', 'quantity unit name scalable reason unit_from_operator')
Row = collections.namedtuple(
    'Row', 'raw quantity unit name scalable reason unit_from_operator')


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
    """The ingredient name: the line after its quantity, minus a lead 'of '."""
    name = rest.strip()
    name = re.sub(r'^of\s+', '', name, flags=re.I)
    return name.strip()


def classify_unit(unit):
    """'massVolume' | 'container' | 'wholeItem' | None for an unknown word."""
    if unit is None:
        return None
    folded = unit.lower()
    if folded in MASS_VOLUME_UNITS:
        return 'massVolume'
    if folded in CONTAINER_UNITS:
        return 'container'
    if folded in WHOLE_ITEM_UNITS:
        return 'wholeItem'
    return None


def head_words(name, count=2):
    """The first [count] words of an ingredient name, folded for lookup."""
    folded = []
    for word in name.split()[:count]:
        letters = re.sub(r'[^a-z]', '', word.lower())
        if letters:
            folded.append(letters)
    return folded


def count_kind(name):
    """A bare count counts CONTAINERS or WHOLE ITEMS: which one.

    English puts the counted noun straight after its number, with at most an
    adjective in front of it ('1 Whole Can Chipotle Pepper in Adobo Sauce'),
    so only the head of the name is consulted. A container word further along
    a description is not what the number counts, and must not be read as if
    it were.
    """
    for word in head_words(name):
        if word in CONTAINER_UNITS:
            return CONTAINER_COUNT
    return WHOLE_ITEM_COUNT


def parse_line(raw):
    """One ingredient line -> a [Parsed].

    The whole scaling rule lives here, and nowhere else.
    """
    text = raw.strip()

    m = RANGE_RE.match(text)
    if m:
        low, low_unit, _high, high_unit, _rest = m.groups()
        # Either unit slot may in fact hold the first word of the ingredient
        # name ('9-10 Roma Tomatoes'), so a slot only counts as a unit when
        # it holds a word the vocabularies above recognise. Whatever is left
        # of the line after the accepted quantity is the name, sliced out of
        # the original text so its spacing survives.
        if classify_unit(high_unit) is not None:
            unit, cut = high_unit, m.end(4)
        elif classify_unit(low_unit) is not None:
            unit, cut = low_unit, m.end(3)
        else:
            unit, cut = None, m.end(3)
        return Parsed(to_number(low), unit, clean_name(text[cut:]), False,
                      RANGE, False)

    m = SINGLE_RE.match(text)
    if not m:
        return Parsed(None, None, text, False, NO_QUANTITY, False)
    number, unit, rest = m.groups()
    quantity = to_number(number)
    if quantity is None:
        return Parsed(None, None, text, False, NO_QUANTITY, False)

    kind = classify_unit(unit)
    if kind is None:
        # THE COUNT RULE. The word attached to the number is not a unit of
        # measure, so it belongs to the ingredient's own name and the number
        # counts that ingredient: '12 Eggs', '3 Corn Tortillas', '15
        # Avocados'. This is the same shape as '2 Stalks Celery'; the only
        # difference is that the countable noun sits in the name rather than
        # in a unit slot, which is a fact about English, not about the line.
        name = clean_name(f'{unit} {rest}' if unit else rest)
        confirmed = OPERATOR_CONFIRMED_UNITS.get(text)
        if confirmed is not None:
            # Not a count at all: a weight the source never spelled out, and
            # the operator said so. `check_operator_confirmations` proves
            # this arm was reached for every confirmation, exactly once.
            return Parsed(quantity, confirmed, name, True, None, True)
        return Parsed(quantity, None, name, False, count_kind(name), False)

    name = clean_name(rest)
    if kind == 'massVolume':
        return Parsed(quantity, unit, name, True, None, False)
    if kind == 'container':
        return Parsed(quantity, unit, name, False, CONTAINER_COUNT, False)
    return Parsed(quantity, unit, name, False, WHOLE_ITEM_COUNT, False)


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
    a('// body it is keyed to, so the reader and a calculator can never show')
    a('// two different numbers. test/barrio_recipe_ingredients_test.dart')
    a('// re-proves that tie against the live doc, and proves the parse covers')
    a('// every ingredient line with nothing silently dropped.')
    a('//')
    a('// `scalable` is the whole point: only a single quantity in a unit of')
    a('// mass or volume may be multiplied. Container counts, whole-item')
    a('// counts, ranges, and lines with no number at all are held back with')
    a('// the reason why, and a calculator carries them through unchanged.')
    a('// The rule and its four reasons are stated once, in the generator.')
    a('//')
    a('// `unitFromOperator` marks the two lines whose unit the OPERATOR')
    a('// confirmed rather than the recipe printing it. The card body is')
    a('// untouched: it still shows no unit there, which is why the')
    a('// calculator says where the unit came from.')
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
            if row.quantity is not None:
                a(f'      quantity: {dart_number(row.quantity)},')
            if row.unit is not None:
                a(f"      unit: '{esc(row.unit)}',")
            if row.unit_from_operator:
                a('      unitFromOperator: true,')
            a(f'      scalable: {"true" if row.scalable else "false"},')
            if row.reason is not None:
                a(f'      hold: BarrioIngredientHold.{row.reason},')
            a('    ),')
        a('  ],')
    a('};')
    a('')
    return '\n'.join(lines)


# --- Proving the rule on lines the manual does not happen to contain ------

# (line, scalable, reason) that `parse_line` must produce.
#
# WHY THESE ARE NOT MANUAL LINES. The Dart guards check the rule against the
# 203 lines the Recipes manual actually prints, which is the only thing that
# ships. They cannot check the BOUNDARY of the rule, because the manual has
# no line sitting on it. These probes are that boundary, written by hand:
# every one of them is a way the widened count rule could be wrong, and the
# dangerous direction is first. They run on every invocation, so the rule
# cannot drift without the generator refusing to produce data.
RULE_PROBES = [
    # A measure word must never read as a countable noun, abbreviated or
    # spelled out. This is the direction that would COST a cook a working
    # calculator line, so it leads.
    ('500g Chicken Thigh', True, None),
    ('500 g Chicken Thigh', True, None),
    ('500 grams Chicken Thigh', True, None),
    ('2 Pounds Beef Shin', True, None),
    ('1.5 Litres Chicken Stock', True, None),
    ('3 Tablespoons Cumin', True, None),
    # A number followed by a countable noun counts that noun.
    ('12 Eggs', False, WHOLE_ITEM_COUNT),
    ('15 Avocados', False, WHOLE_ITEM_COUNT),
    ('3 Corn Tortillas', False, WHOLE_ITEM_COUNT),
    ('1 Large Red Onion Small Dice', False, WHOLE_ITEM_COUNT),
    # A container word at the head of the name counts containers, whether or
    # not an adjective sits in front of it.
    ('1 Whole Can Chipotle Pepper in Adobo Sauce', False, CONTAINER_COUNT),
    ('2 Cans Tomatoes', False, CONTAINER_COUNT),
    # ... but a container word further along a description is not what the
    # number counts.
    ('12 Eggs in a Box', False, WHOLE_ITEM_COUNT),
    # The reasons that existed before the widening still hold.
    ('2 Stalks Celery', False, WHOLE_ITEM_COUNT),
    ('8-10lbs of beets', False, RANGE),
    ('Salt TT', False, NO_QUANTITY),
]


def check_rule_probes():
    """Fail the run if the classification rule stops meaning what it says."""
    problems = []
    for line, want_scalable, want_reason in RULE_PROBES:
        got = parse_line(line)
        if got.scalable != want_scalable or got.reason != want_reason:
            problems.append(
                f'{line!r}: expected '
                f'{"scalable" if want_scalable else f"hold:{want_reason}"}, '
                f'got '
                f'{"scalable" if got.scalable else f"hold:{got.reason}"}')
    if problems:
        raise SystemExit(
            'the ingredient classification rule no longer holds:\n  '
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
    rows_by_unit = collect(CONTENT)
    check_operator_confirmations(rows_by_unit)
    total = sum(len(rows) for _uid, rows in rows_by_unit)
    scalable = sum(1 for _uid, rows in rows_by_unit
                   for row in rows if row.scalable)

    if report:
        for unit_id, rows in rows_by_unit:
            print(f'== {unit_id}')
            for row in rows:
                mark = 'SCALE' if row.scalable else f'hold:{row.reason}'
                if row.unit_from_operator:
                    mark += '*'
                qs = '' if row.quantity is None else dart_number(row.quantity)
                print(f'   {mark:<22} q={qs:<8} u={row.unit or "":<8} '
                      f'name={row.name!r:<45} raw={row.raw!r}')
        print()
        print('* = unit confirmed by the operator, not printed by the recipe')
        print()

    print(f'recipes with ingredients: {len(rows_by_unit)}')
    print(f'ingredient lines: {total}  scalable: {scalable}  '
          f'held: {total - scalable}')
    held = {}
    for _uid, rows in rows_by_unit:
        for row in rows:
            if not row.scalable:
                held[row.reason] = held.get(row.reason, 0) + 1
    for reason, n in sorted(held.items(), key=lambda kv: -kv[1]):
        print(f'   {reason}: {n}')
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
