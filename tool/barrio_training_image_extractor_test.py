"""Regression test for tool/barrio_training_image_extractor.py.

Run it directly, no test framework and no PDFs needed:

    python tool/barrio_training_image_extractor_test.py

WHAT THIS PINS
--------------
On 2026-08-06 a clean-checkout run of the extractor deleted 127 tracked
assets and stripped image markers out of 8 knowledge-graph markdown files
with no code change involved. The extractor cleared every `*.webp` in
`assets/internal/barrio/training/<doc_id>/` and stripped every marker
pointing there, a contract that assumed it was the only writer of those
folders. The 2026-08-02 real-images pass had made that false: licensed
photographs live in the same folders, numbered after the extracted ones,
and their `![Photo: <credit>](...)` alt text is the licence attribution
that ships as the `caption:` on each generated card.

Everything below builds a synthetic source PDF and a synthetic knowledge-
graph doc in a temp directory, so it exercises the real extraction,
placement, and write paths without the untracked `docs/training` drop.

NEGATIVE CONTROL
----------------
These assertions are only worth their runtime if they fail against the
broken tool. Point the test at any revision to check:

    EXTRACTOR_PATH=/tmp/old_extractor.py \
        python tool/barrio_training_image_extractor_test.py

Against the pre-fix extractor (`git show b707ace7:tool/barrio_training_
image_extractor.py`) every scenario reports failures, 15 in total, led by
the two that describe the incident itself: "curated 03.webp must NOT be
deleted" and "the Photo: credit marker must survive verbatim".

Scenarios 7 to 9 pin the permanent ban list
(`tool/barrio_training_extracted_bans.json`, seeded from the 2026-08-09
AI-image purge, PR #1580): a banned file is never written, never gets a
marker, never re-enters the ownership manifest, and a missing banned
file is not a pending `--check` change. Against the pre-ban extractor
(the parent of the commit that added them) those scenarios report 11
failures, led by "banned 02.webp must NOT be written back to disk".
"""

import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import traceback

import fitz
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
EXTRACTOR_PATH = os.environ.get(
    'EXTRACTOR_PATH', os.path.join(HERE, 'barrio_training_image_extractor.py'))

DOC_ID = 'synthetic_manual'
SRC_NAME = 'Synthetic Manual.pdf'
MD_NAME = 'Synthetic Manual.md'

# Each paragraph is mirrored verbatim into the markdown so the extractor's
# anchor matching has something real to find (it needs 5+ matching words).
PARAGRAPHS = [
    'The espresso machine group head must be purged before every single shot.',
    'Steam wands are wiped down and purged immediately after each use.',
    'Grinder burrs are checked for wear at the end of every service period.',
]


def make_image(seed, size=(320, 240)):
    """Deterministic non-uniform image, comfortably over the size floors.

    Deliberately high-entropy (an LCG stream, not a gradient): the extractor
    drops anything whose raw payload compresses under MIN_RAW_BYTES, and a
    smooth pattern sails straight through that floor as decoration.
    """
    state = seed * 7919 + 1
    data = bytearray()
    for _ in range(size[0] * size[1] * 3):
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        data.append((state >> 16) & 0xFF)
    return Image.frombytes('RGB', size, bytes(data))


def png_bytes(seed):
    buf = io.BytesIO()
    make_image(seed).save(buf, 'PNG')
    return buf.getvalue()


def make_pdf(path, seeds):
    """One page per seed: the matching paragraph, then the image below it."""
    doc = fitz.open()
    for i, seed in enumerate(seeds):
        page = doc.new_page(width=400, height=500)
        page.insert_textbox(fitz.Rect(20, 20, 380, 120), PARAGRAPHS[i], fontsize=11)
        page.insert_image(fitz.Rect(40, 150, 360, 390), stream=png_bytes(seed))
    doc.save(path)
    doc.close()


def make_md(path, body_paragraphs):
    lines = ['---', 'title: Synthetic Manual', '---', '', '## Steps', '']
    for para in body_paragraphs:
        lines += [para, '']
    # CRLF with a final newline, matching every real knowledge-graph doc.
    data = '\r\n'.join(lines).encode('utf-8')
    with open(path, 'wb') as f:
        f.write(data)


def load_extractor():
    spec = importlib.util.spec_from_file_location('extractor_under_test', EXTRACTOR_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.SOURCES = [dict(src=SRC_NAME, doc_id=DOC_ID, md=MD_NAME)]
    return mod


class Fixture:
    """A temp tree shaped like the repo, with the extractor pointed at it."""

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix='barrio_extractor_test_')
        self.src_dir = os.path.join(self.root, 'training_src')
        self.kg_dir = os.path.join(self.root, 'docs', 'Knowledge_graph_docs')
        self.asset_dir = os.path.join(
            self.root, 'assets', 'internal', 'barrio', 'training', DOC_ID)
        os.makedirs(self.src_dir)
        os.makedirs(self.kg_dir)
        os.makedirs(self.asset_dir)
        os.makedirs(os.path.join(self.root, 'tool'))  # the manifest lives here
        self.src_pdf = os.path.join(self.src_dir, SRC_NAME)
        self.md_path = os.path.join(self.kg_dir, MD_NAME)
        self.ex = load_extractor()

    def run(self, check=False):
        """Run the tool with the temp tree as CWD. Returns its exit code."""
        argv = ['extractor', '--src', self.src_dir]
        if check:
            argv.append('--check')
        prev_cwd = os.getcwd()
        prev_argv = sys.argv
        prev_stdout, prev_stderr = sys.stdout, sys.stderr
        os.chdir(self.root)
        sys.argv = argv
        sys.stdout = io.StringIO()
        # Captured so a revision that argparse-rejects --check does not spray
        # usage text over the scenario results.
        sys.stderr = io.StringIO()
        try:
            return self.ex.main()
        except SystemExit as e:
            # argparse bails this way on a revision with no --check flag.
            return e.code if isinstance(e.code, int) else 2
        finally:
            self.output = sys.stdout.getvalue() + sys.stderr.getvalue()
            sys.stdout, sys.stderr = prev_stdout, prev_stderr
            sys.argv = prev_argv
            os.chdir(prev_cwd)

    def manifest(self):
        """The ownership manifest, or {} for a tool revision that has none."""
        path = os.path.join(self.root, 'tool', 'barrio_training_extracted_assets.json')
        if not os.path.exists(path):
            return {}
        with open(path, encoding='utf-8') as f:
            return json.load(f)

    def write_bans(self, bans):
        """Write the temp tree's permanent ban list (replacing any prior one)."""
        path = os.path.join(self.root, 'tool', 'barrio_training_extracted_bans.json')
        with open(path, 'w', encoding='utf-8', newline='') as f:
            json.dump(bans, f, indent=2, sort_keys=True)

    def asset(self, name):
        return os.path.join(self.asset_dir, name)

    def assets(self):
        return sorted(os.listdir(self.asset_dir))

    def md_bytes(self):
        with open(self.md_path, 'rb') as f:
            return f.read()

    def md_text(self):
        return self.md_bytes().decode('utf-8')

    def snapshot(self):
        """Bytes of every file in the tree, for exact no-op comparison."""
        out = {}
        for base, _dirs, files in os.walk(self.root):
            if base.startswith(self.src_dir):
                continue
            for name in files:
                p = os.path.join(base, name)
                with open(p, 'rb') as f:
                    out[os.path.relpath(p, self.root)] = f.read()
        return out

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


FAILURES = []


def ok(code):
    """True for a successful run. `None` covers revisions whose main() returns
    nothing, so the negative control reaches the scenarios that matter."""
    return code in (0, None)


def check(condition, message):
    if condition:
        return
    FAILURES.append(message)
    print(f'  FAIL {message}')


def scenario_1_first_run_extracts(fx):
    print('1. first run extracts and places')
    make_pdf(fx.src_pdf, [1, 2])
    make_md(fx.md_path, PARAGRAPHS[:2])
    code = fx.run()
    check(ok(code), f'first run should succeed, got exit {code}')
    check(fx.assets() == ['01.webp', '02.webp'],
          f'expected 01/02.webp, got {fx.assets()}')
    md = fx.md_text()
    for name in ('01.webp', '02.webp'):
        check(f'![](assets/internal/barrio/training/{DOC_ID}/{name})' in md,
              f'marker for {name} should have been inserted')
    check(fx.manifest().get(DOC_ID) == ['01.webp', '02.webp'],
          f'manifest should record both files, got {fx.manifest().get(DOC_ID)}')
    check(b'\r\n' in fx.md_bytes(), 'CRLF line endings should be preserved')


def scenario_2_rerun_is_noop(fx):
    print('2. re-run changes nothing at all')
    before = fx.snapshot()
    code = fx.run()
    check(ok(code), f're-run should succeed, got exit {code}')
    after = fx.snapshot()
    changed = sorted(set(before) ^ set(after)) + sorted(
        k for k in before.keys() & after.keys() if before[k] != after[k])
    check(not changed, f're-run must be byte-identical; changed: {changed}')
    check(fx.run(check=True) == 0, '--check should exit 0 when nothing would change')

    # core.autocrlf is true in this repo, so the manifest is committed with LF
    # and lands CRLF in a Windows working tree. A byte comparison would then
    # see a change on every fresh clone and rewrite the file just to flip its
    # line endings, which is exactly the churn this tool must not produce.
    path = os.path.join(fx.root, 'tool', 'barrio_training_extracted_assets.json')
    with open(path, 'rb') as f:
        lf = f.read()
    with open(path, 'wb') as f:
        f.write(lf.replace(b'\n', b'\r\n'))
    check(fx.run(check=True) == 0, '--check must ignore CRLF/LF on the manifest')
    fx.run()
    with open(path, 'rb') as f:
        check(f.read() == lf.replace(b'\n', b'\r\n'),
              'a CRLF manifest must be left alone, not rewritten as LF')
    with open(path, 'wb') as f:
        f.write(lf)


def scenario_3_curated_photo_survives(fx):
    print('3. a curated photograph and its credit survive (the 2026-08-06 hazard)')
    # The real-images pass numbers its photos AFTER the extracted ones.
    curated = fx.asset('03.webp')
    make_image(99).save(curated, 'WEBP', quality=80, method=6)
    credit = ('![Photo: A Photographer, CC BY-SA 4.0, via Wikimedia Commons]'
              f'(assets/internal/barrio/training/{DOC_ID}/03.webp)')
    with open(fx.md_path, 'rb') as f:
        text = f.read().decode('utf-8')
    text += credit + '\r\n'
    with open(fx.md_path, 'wb') as f:
        f.write(text.encode('utf-8'))
    curated_bytes = open(curated, 'rb').read()

    code = fx.run()
    check(ok(code), f'run should succeed, got exit {code}')
    check(os.path.exists(curated), 'curated 03.webp must NOT be deleted')
    check(os.path.exists(curated) and open(curated, 'rb').read() == curated_bytes,
          'curated 03.webp must not be rewritten')
    check(credit in fx.md_text(),
          'the Photo: credit marker must survive verbatim (it ships as the caption)')
    check(fx.run(check=True) == 0,
          '--check should still exit 0 with curated content present')


def scenario_4_hand_edits_preserved(fx):
    print('4. hand-authored caption and hand-moved marker are preserved')
    plain = f'![](assets/internal/barrio/training/{DOC_ID}/01.webp)'
    captioned = ('![Diagram: the group head being purged before a shot]'
                 f'(assets/internal/barrio/training/{DOC_ID}/01.webp)')
    text = fx.md_text()
    check('\r\n\r\n' + plain in text, 'precondition: plain 01.webp marker present')
    # Caption it AND move it to the end, the way a reviewer pass would. Lift
    # the blank line the marker was inserted with too, so the fixture leaves
    # tidy markdown behind and scenario 5 is judging the tool, not this edit.
    text = text.replace('\r\n\r\n' + plain, '', 1)
    text = text.rstrip('\r\n') + '\r\n\r\n' + captioned + '\r\n'
    with open(fx.md_path, 'wb') as f:
        f.write(text.encode('utf-8'))
    before = fx.md_bytes()

    code = fx.run()
    check(ok(code), f'run should succeed, got exit {code}')
    check(fx.md_bytes() == before,
          'a captioned, hand-moved marker must be left exactly as curation left it')
    check(captioned in fx.md_text(), 'the Diagram: caption must survive')
    check(fx.md_text().count(f'{DOC_ID}/01.webp') == 1,
          'the moved marker must not be duplicated back at its derived anchor')


def scenario_5_owned_removal_still_works(fx):
    print('5. an owned asset dropped from the source is still cleaned up')
    make_pdf(fx.src_pdf, [1])  # image 2 removed from the source
    code = fx.run()
    check(ok(code), f'run should succeed, got exit {code}')
    check(not os.path.exists(fx.asset('02.webp')),
          'owned 02.webp should be deleted once the source stops yielding it')
    check(f'{DOC_ID}/02.webp' not in fx.md_text(),
          "owned 02.webp's marker should be stripped")
    check(os.path.exists(fx.asset('03.webp')),
          'the curated photograph must still survive a real cleanup')
    check(f'{DOC_ID}/03.webp' in fx.md_text(),
          'the curated credit must still survive a real cleanup')
    check('\r\n\r\n\r\n' not in fx.md_text(),
          'removing a marker must not leave a doubled blank line behind')
    check(fx.run(check=True) == 0, '--check should exit 0 after the cleanup settles')


def scenario_6_collision_hard_stops(fx):
    print('6. numbering collision with curated content is a hard stop')
    # Three source images now want 01/02/03 -- and 03 is the curated photo.
    make_pdf(fx.src_pdf, [1, 2, 3])
    before = fx.snapshot()
    code = fx.run()
    check(code == 1, f'a collision must exit non-zero, got exit {code}')
    check('NOT extractor-owned' in fx.output,
          'the error should name the ownership collision')
    after = fx.snapshot()
    changed = sorted(set(before) ^ set(after)) + sorted(
        k for k in before.keys() & after.keys() if before[k] != after[k])
    check(not changed,
          f'a hard stop must leave the tree completely untouched; changed: {changed}')


def scenario_7_banned_file_stays_dead(fx):
    print('7. a banned file is never resurrected (the 2026-08-09 AI purge)')
    # The post-purge state: the banned file is not on disk, not in the
    # ownership manifest, and has no marker, but the untracked source
    # still yields it. The run must not bring any part of it back.
    make_pdf(fx.src_pdf, [1, 2])
    fx.write_bans({DOC_ID: ['02.webp']})
    code = fx.run()
    check(ok(code), f'run should succeed, got exit {code}')
    check('SKIPPED 02.webp (banned)' in fx.output,
          'the run should report the banned file as SKIPPED (banned)')
    check(not os.path.exists(fx.asset('02.webp')),
          'banned 02.webp must NOT be written back to disk')
    check(f'{DOC_ID}/02.webp' not in fx.md_text(),
          'banned 02.webp must NOT get a marker derived')
    check(fx.manifest().get(DOC_ID) == ['01.webp'],
          f'banned 02.webp must NOT re-enter the ownership manifest, '
          f'got {fx.manifest().get(DOC_ID)}')
    check(fx.run(check=True) == 0,
          '--check must treat a missing banned file as settled, not pending')


def scenario_8_ban_preserves_sibling_numbering(fx):
    print('8. banning an early file neither renumbers nor revives anything')
    # Ban 01 instead: the sibling that has always shipped as 02.webp must
    # KEEP that name (sliding it down to 01.webp would collide with
    # curated content), and the still-owned 01.webp converges through the
    # normal owned-cleanup path: removed exactly once, never recreated.
    fx.write_bans({DOC_ID: ['01.webp']})
    code = fx.run()
    check(ok(code), f'run should succeed, got exit {code}')
    check(not os.path.exists(fx.asset('01.webp')),
          'a banned still-owned file should be removed via owned cleanup')
    check(f'{DOC_ID}/01.webp' not in fx.md_text(),
          "the banned file's marker should be stripped with it")
    check(os.path.exists(fx.asset('02.webp')),
          'the unbanned sibling must still extract')
    check(f'{DOC_ID}/02.webp' in fx.md_text(),
          'the unbanned sibling must keep its shipped number, not slide to 01')
    check(fx.manifest().get(DOC_ID) == ['02.webp'],
          f'manifest should list only the sibling, got {fx.manifest().get(DOC_ID)}')
    before = fx.snapshot()
    code = fx.run()
    check(ok(code), f're-run should succeed, got exit {code}')
    after = fx.snapshot()
    changed = sorted(set(before) ^ set(after)) + sorted(
        k for k in before.keys() & after.keys() if before[k] != after[k])
    check(not changed,
          f'a banned file is deleted once, never recreated; changed: {changed}')
    check(fx.run(check=True) == 0, '--check should settle after the ban cleanup')


def scenario_9_ban_shields_curated_number(fx):
    print('9. a ban shields a curated file sitting on a banned number')
    # Scenario 6's hard stop: source image 3 wants 03.webp, where the
    # curated photograph lives. With 03.webp banned the extractor skips
    # it BEFORE the ownership byte comparison: no collision error, and
    # the curated file plus its credit are untouched.
    make_pdf(fx.src_pdf, [1, 2, 3])
    fx.write_bans({DOC_ID: ['01.webp', '03.webp']})
    curated_bytes = open(fx.asset('03.webp'), 'rb').read()
    before_md = fx.md_bytes()
    code = fx.run()
    check(ok(code), f'a banned collision must not hard-stop, got exit {code}')
    check('NOT extractor-owned' not in fx.output,
          'the ownership collision error must not fire for a banned name')
    check(open(fx.asset('03.webp'), 'rb').read() == curated_bytes,
          'the curated photograph on the banned number must be untouched')
    check(fx.md_bytes() == before_md,
          'the markdown (including the Photo: credit) must be untouched')
    check(fx.manifest().get(DOC_ID) == ['02.webp'],
          f'manifest should still list only 02.webp, got {fx.manifest().get(DOC_ID)}')
    check(fx.run(check=True) == 0, '--check should stay settled')


def main():
    print(f'extractor under test: {EXTRACTOR_PATH}')
    fx = Fixture()
    try:
        for scenario in (scenario_1_first_run_extracts,
                         scenario_2_rerun_is_noop,
                         scenario_3_curated_photo_survives,
                         scenario_4_hand_edits_preserved,
                         scenario_5_owned_removal_still_works,
                         scenario_6_collision_hard_stops,
                         scenario_7_banned_file_stays_dead,
                         scenario_8_ban_preserves_sibling_numbering,
                         scenario_9_ban_shields_curated_number):
            try:
                scenario(fx)
            except Exception:
                # A scenario that blows up is a failure, not a reason to stop:
                # the later scenarios are the ones that pin the hazard.
                check(False, f'{scenario.__name__} raised\n'
                             f'{traceback.format_exc()}')
    finally:
        fx.cleanup()

    print()
    if FAILURES:
        print(f'FAILED ({len(FAILURES)}):')
        for f in FAILURES:
            print(f'  - {f}')
        return 1
    print('PASSED: curated assets, captions, and hand-placed markers all '
          'survive, and banned files stay dead.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
