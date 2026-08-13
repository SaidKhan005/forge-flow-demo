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

Every other line is held back and carried through unchanged, for one of five
stated reasons:

  * noQuantity     - the line carries no leading number at all
                     ('Salt TT', 'The Peel of One Orange').
  * containerCount - it counts containers, and a shelf does not sell 2.5 of
                     them ('1 Jar Aji Amarillo', '2 Bags Yellow Corn Tortilla').
  * wholeItemCount - it counts whole items, and a fraction of one is nonsense
                     at the bench ('4 Cloves of garlic', '2 Stalks Celery',
                     '1 Bunch Thyme', '4 piece Star Anise').
  * noUnit         - it carries a number but never says what that number
                     measures, so scaling it would be a guess ('15 Avocados',
                     '235 Pumpkin Seeds', '654 Canola Oil').
  * range          - the operator wrote a range, which is a judgement call
                     rather than a quantity ('8-10lbs of beets').

A held line still carries whatever quantity and unit could be read off it, so
a calculator can SHOW them; `scalable: false` is what stops it multiplying
them.
"""
import os
import re
import sys

CONTENT = ('lib/internal/barrio/content/training/'
           'training_recipes_content.dart')
OUT = ('lib/internal/barrio/content/recipes/'
       'barrio_recipe_ingredients.dart')

# Units that measure mass or volume. Only these make a line scalable.
MASS_VOLUME_UNITS = {
    'g', 'kg', 'mg', 'lb', 'lbs', 'oz',
    'ml', 'l', 'tsp', 'tbsp', 'cup', 'cups',
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
NO_UNIT = 'noUnit'
RANGE = 'range'


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


def parse_line(raw):
    """One ingredient line -> (quantity, unit, name, scalable, reason).

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
        return to_number(low), unit, clean_name(text[cut:]), False, RANGE

    m = SINGLE_RE.match(text)
    if not m:
        return None, None, text, False, NO_QUANTITY
    number, unit, rest = m.groups()
    quantity = to_number(number)
    if quantity is None:
        return None, None, text, False, NO_QUANTITY

    kind = classify_unit(unit)
    if kind is None:
        # The word after the number is part of the ingredient name, not a
        # unit, so the line counts something without saying what it measures.
        name = clean_name(f'{unit} {rest}' if unit else rest)
        return quantity, None, name, False, NO_UNIT

    name = clean_name(rest)
    if kind == 'massVolume':
        return quantity, unit, name, True, None
    if kind == 'container':
        return quantity, unit, name, False, CONTAINER_COUNT
    return quantity, unit, name, False, WHOLE_ITEM_COUNT


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
    """[(unit_id, [(raw, quantity, unit, name, scalable, reason)])]."""
    out = []
    for unit_id, body in read_units(path):
        rows = [(raw,) + parse_line(raw) for raw in ingredient_lines(body)]
        if rows:
            out.append((unit_id, rows))
    return out


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
    a('// counts, bare numbers with no unit, ranges, and lines with no number')
    a('// at all are held back with the reason why, and a calculator carries')
    a('// them through unchanged. The rule and its five reasons are stated')
    a('// once, in the generator.')
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
        for raw, quantity, unit, name, scalable, reason in rows:
            a('    BarrioRecipeIngredient(')
            a(f"      raw: '{esc(raw)}',")
            a(f"      name: '{esc(name)}',")
            if quantity is not None:
                a(f'      quantity: {dart_number(quantity)},')
            if unit is not None:
                a(f"      unit: '{esc(unit)}',")
            a(f'      scalable: {"true" if scalable else "false"},')
            if reason is not None:
                a(f'      hold: BarrioIngredientHold.{reason},')
            a('    ),')
        a('  ],')
    a('};')
    a('')
    return '\n'.join(lines)


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

    rows_by_unit = collect(CONTENT)
    total = sum(len(rows) for _uid, rows in rows_by_unit)
    scalable = sum(1 for _uid, rows in rows_by_unit
                   for r in rows if r[4])

    if report:
        for unit_id, rows in rows_by_unit:
            print(f'== {unit_id}')
            for raw, q, u, name, sc, reason in rows:
                mark = 'SCALE' if sc else f'hold:{reason}'
                qs = '' if q is None else dart_number(q)
                print(f'   {mark:<22} q={qs:<8} u={u or "":<8} '
                      f'name={name!r:<45} raw={raw!r}')
        print()

    print(f'recipes with ingredients: {len(rows_by_unit)}')
    print(f'ingredient lines: {total}  scalable: {scalable}  '
          f'held: {total - scalable}')
    held = {}
    for _uid, rows in rows_by_unit:
        for r in rows:
            if not r[4]:
                held[r[5]] = held.get(r[5], 0) + 1
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
