"""Extract content pictures from the Barrio training source files and place
image markers into the verbatim knowledge-graph markdown docs.

Usage (from the repo root):
    python tool/barrio_training_image_extractor.py --src "<path to docs/training>" [--report <path>]

The source drop folder is untracked and normally lives only in the main
checkout (e.g. `C:\\Git Local Repos\\forge_flow_demo\\docs\\training`), so the
path is always passed explicitly.

OWNERSHIP (read this before changing how files are cleared)
-----------------------------------------------------------
This tool is NOT the only writer of `assets/internal/barrio/training/
<doc_id>/`. The 2026-08-02 real-images pass dropped licensed photographs
into those same per-doc folders, numbered after the extracted ones, and
curation has since added `![Photo: <credit>](...)` and `![Diagram: ...]`
captions to markers in the knowledge-graph markdown. Those captions are
shipping content: `tool/barrio_training_content_generator.py` emits the
alt text as the `caption:` on each `HandbookUnitImage`, so a lost
`Photo:` line is a lost licence attribution.

The original "clear the folder, strip every marker, re-extract" contract
assumed a single writer. It no longer holds, and running it destroyed 127
tracked assets and 8 markdown files' markers on a clean checkout. So
ownership is now explicit:

* `tool/barrio_training_extracted_assets.json` records, per doc_id, the
  exact file names this tool produced. Only those files may be deleted,
  and only markers pointing at them may be stripped or moved. Everything
  else in the folder belongs to curation and is left alone.
* A file whose bytes on disk already equal this run's output is adopted
  as extractor-owned (that is how the manifest was seeded, and it means
  a manifest-less checkout still converges instead of hard-stopping).
* Writing DIFFERENT bytes over a file this tool does not own is a hard
  stop, not a silent overwrite. That is the case where a source doc grew
  a picture and the new reading-order number collides with a curated
  photograph; renumbering licensed content is a human decision.
* Markers that already exist for a surviving asset are preserved exactly
  where they are, with their alt text. Placement is derived only for
  assets that have no marker yet. Reviewers hand-corrected some anchors
  (`drink_specs/10.webp`, `11.webp`) and re-deriving would silently undo
  that, the same way PR #1534 lost 44 curated `"replace": true` flags.

The result is that a re-run over an unchanged source drop is a genuine
no-op: no file is rewritten, and `git status --porcelain` stays empty.
`--check` proves it without writing anything, and
`tool/barrio_training_image_extractor_test.py` pins the hazard with
synthetic fixtures so it does not need the untracked PDFs.

Longer term the cleanest shape is a separate `<doc_id>_extracted/`
namespace so the two writers cannot collide by numbering at all; the
manifest is the smaller fix that does not have to renumber and re-point
every shipped asset, manifest entry, and generated card.

What it does per source document (operator decisions, 2026-07-11 plan
`docs/phases/barrio_training_media_search_v1/barrio_training_media_search_v1_plan.md`):

1. Collect unique embedded images (PDF: by xref/digest via PyMuPDF;
   PPTX: media via slide relationship XML, no python-pptx dependency).
2. DECORATION FILTER, content pictures only. Excluded with a logged reason:
   - digest repeated on 3+ pages/slides (logos, watermarks, backgrounds),
   - min dimension under 100 px,
   - raw payload under 10 KB,
   - near-uniform pixels (solid fills / plain gradients; grayscale
     standard deviation below NEAR_UNIFORM_STDDEV).
   Full-page images that survive the filters are kept but FLAGGED for the
   reviewer pass over this report.
3. Placement mapping. PDF: nearest text block ABOVE the image on its page
   (or the page's first block, or the previous page's tail) is normalized
   and located in the doc's markdown; the marker is inserted AFTER the
   markdown paragraph containing that text (after the specific bullet line
   when the paragraph is a bullet list, to keep glossary positions honest).
   If no confident match exists the image attaches to the end of the
   section around the running cursor and is FLAGGED. PPTX: images anchor
   to the end of their `## Slide N` section.
4. Output: WebP (quality 80, max long edge 1200 px, aspect preserved) at
   `assets/internal/barrio/training/<doc_id>/NN.webp` (NN = reading order),
   plus `![](<asset path>)` markers on their own blank-line-separated lines
   in `docs/Knowledge_graph_docs/*.md`. Markers are formatting, not words:
   `tool/barrio_training_verbatim_check.py` strips them, and the word-for-
   word guarantee must stay at 0 lost for every doc.

The placement report (kept + excluded, with reasons and anchors) prints to
stdout and optionally to --report; it goes into the Wave A PR body.
"""

import argparse
import hashlib
import io
import json
import os
import re
import sys
import zipfile

import fitz  # PyMuPDF
from PIL import Image, ImageStat

KG = 'docs/Knowledge_graph_docs'
ASSET_ROOT = 'assets/internal/barrio/training'
# doc_id -> [file name], the files this tool produced and may therefore
# delete. See the ownership section of the module docstring.
MANIFEST_PATH = 'tool/barrio_training_extracted_assets.json'

MIN_DIMENSION_PX = 100
MIN_RAW_BYTES = 10 * 1024
REPEAT_PAGE_LIMIT = 3          # digest on 3+ pages/slides = decoration
NEAR_UNIFORM_STDDEV = 8.0      # grayscale stddev below this = solid fill
FULL_PAGE_AREA_RATIO = 0.90    # bbox covering >= 90% of the page = flag
WEBP_QUALITY = 80
MAX_LONG_EDGE = 1200

# Group 1 = alt text (curation's caption), group 2 = asset path. Both are
# needed: the path decides ownership, the alt text is shipping content.
MARKER_RE = re.compile(
    r'^!\[([^\]]*)\]\((assets/internal/barrio/training/[^)]+)\)\s*$')


def load_manifest():
    if not os.path.exists(MANIFEST_PATH):
        return {}
    with open(MANIFEST_PATH, encoding='utf-8') as f:
        return json.load(f)


def render_manifest(manifest):
    """Stable JSON text for the ownership manifest, LF-normalized.

    Comparison is always against LF because `core.autocrlf` is true in this
    repo: the manifest is committed with LF but lands CRLF in a Windows
    working tree, and comparing raw bytes would then report a change on
    every fresh clone and rewrite the file just to flip its line endings.
    """
    body = json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False)
    return body + '\n'


def read_text_lf(path):
    """File text with line endings normalized to LF, or None if absent."""
    data = read_file(path)
    if data is None:
        return None
    return data.decode('utf-8').replace('\r\n', '\n')


def write_manifest(text, existing):
    """Write the manifest, keeping whatever line endings it already had."""
    if existing is not None and b'\r\n' in existing:
        text = text.replace('\n', '\r\n')
    with open(MANIFEST_PATH, 'w', encoding='utf-8', newline='') as f:
        f.write(text)

# Reviewer-pass exclusions (operator decision: content pictures only; the
# automated filters plus a reviewer pass over the placement report decide).
# Keyed by the PDF image MD5 digest reported by PyMuPDF get_image_info.
REVIEWER_EXCLUSIONS = {
    'c87e7782432d094c51f7a6831e05df28':
        'reviewer pass: Barrio Legado brand logo cover (decoration)',
    '2bfdc28e0f10ab11f6058dd10135a0d5':
        'reviewer pass: ZZZ doodle from a clipart set whose siblings fall '
        'under the size floor (decoration)',
}

# Source file -> manifest doc_id -> knowledge-graph markdown. Verified against
# corpus_manifest.yaml source_path entries (2026-07-11).
SOURCES = [
    dict(src='Barrio Building A Strong Foundation.pdf',
         doc_id='barrio_building_a_strong_foundation',
         md='Barrio Building A Strong Foundation.md'),
    dict(src='Barrio Table Maintenance and Manicuring.pdf',
         doc_id='barrio_table_maintenance_and_manicuring',
         md='Barrio Table Maintenance and Manicuring.md'),
    dict(src='Barrio The Three Pillars of Hospitality.pdf',
         doc_id='barrio_three_pillars_of_hospitality',
         md='Barrio The Three Pillars of Hospitality.md'),
    dict(src='Barrio_Legado_Menu_Concept_Slides_4 (2).pptx',
         doc_id='barrio_legado_menu_concept_slides',
         md='Barrio_Legado_Menu_Concept_Slides_4.md'),
    dict(src='Coffee Training.pdf',
         doc_id='coffee_training',
         md='Coffee Training.md'),
    dict(src='Company Handbook (2) (1).pdf',
         doc_id='barrio_company_handbook',
         md='Barrio_company_handbook.md'),
    dict(src='Copy of OE leveraging Suggestive Selling Techniques.pdf',
         doc_id='oe_leveraging_suggestive_selling',
         md='OE Leveraging Suggestive Selling Techniques.md'),
    dict(src='Labour Cost - understanding the levers (1).pdf',
         doc_id='labour_cost_understanding_the_levers',
         md='Labour Cost - understanding the levers.md'),
    dict(src='Latin American Dishes.pdf',
         doc_id='latin_american_dishes',
         md='Latin American Dishes.md'),
    dict(src='Latin American Ingredients.pdf',
         doc_id='latin_american_ingredients',
         md='Latin American Ingredients.md'),
    dict(src='Tequila Training.pdf',
         doc_id='tequila_training',
         md='Tequila Training.md'),
    dict(src='food safety manual.pdf',
         doc_id='food_safety_manual',
         md='food safety manual.md'),
    dict(src='interview playbook.pdf',
         doc_id='barrio_interview_playbook',
         md='Barrio_interview_playbook.md'),
    dict(src='Clover Training Full Manual.pdf',
         doc_id='clover_sop',
         md='Clover SOP.md'),
    dict(src='Push Employee SOP.pdf',
         doc_id='push_employee_sop',
         md='Push Employee SOP.md'),
    # Manual-drop slice (2026-07-28): host, bar, and combined drink-spec
    # training manuals from operator PDFs. The drink-spec source is the
    # merge of Barrio Drink Specs (2).pdf + (3).pdf (see the doc frontmatter).
    dict(src='Barrio host manual.pdf',
         doc_id='host_manual',
         md='Barrio Host Manual.md'),
    dict(src='bar manual.pdf',
         doc_id='bar_manual',
         md='Bar Manual.md'),
    dict(src='Barrio Drink Specs Combined.pdf',
         doc_id='drink_specs',
         md='Barrio Drink Specs.md'),
    # Manual-drop slice (2026-08-06): the operator wine manual.
    dict(src='Barrio Wine Training.pdf',
         doc_id='wine_training',
         md='Barrio Wine Training.md'),
]


# ---------------------------------------------------------------------------
# Text normalization + markdown block model
# ---------------------------------------------------------------------------

_QUOTE_MAP = {
    '‘': "'", '’': "'", '“': '"', '”': '"',
    '–': '-', '—': '-', '…': '...', ' ': ' ',
}


def norm_words(text):
    """Lowercase words with curly quotes/dashes folded, markdown stripped."""
    for src, dst in _QUOTE_MAP.items():
        text = text.replace(src, dst)
    text = text.replace('**', ' ').replace('`', ' ').replace('|', ' ')
    text = re.sub(r'^\s{0,3}#{1,6}\s*', ' ', text, flags=re.M)
    text = re.sub(r'^\s*[-*+]\s+', ' ', text, flags=re.M)
    text = text.replace('*', ' ')
    words = re.findall(r'[^\s]+', text.lower())
    return [w.strip('.,;:!?()"\'·') for w in words if w.strip('.,;:!?()"\'-=_>·')]


class MdDoc:
    """Blank-line-separated block model over a knowledge-graph markdown file.

    The file is held EXACTLY as read (`self.lines`, plus its line ending and
    final-newline state) so an unchanged run re-renders byte-for-byte. Image
    markers are never rewritten in place: they are indexed by asset path,
    preserved where they sit, and only removed when this tool owns the asset
    AND the asset no longer exists.

    The block model that anchoring runs over is a VIEW with every marker line
    filtered out, so a marker never becomes an anchor and never changes the
    word offsets a placement is derived from. `view_to_orig` maps a view line
    index back to the real file line index.
    """

    def __init__(self, path):
        self.path = path
        self.raw = open(path, 'rb').read()
        self.crlf = b'\r\n' in self.raw
        text = self.raw.decode('utf-8').replace('\r\n', '\n')
        self.final_newline = text.endswith('\n')
        self.lines = text.split('\n')
        if self.final_newline:
            self.lines.pop()  # drop the empty artifact of the trailing newline

        # asset path -> first file line index, and the alt text curation gave
        # it. `marker_all` keeps every occurrence so removing an asset takes
        # all of its markers, not just the first.
        self.marker_line = {}
        self.marker_alt = {}
        self.marker_all = {}
        marker_lines = set()
        for i, ln in enumerate(self.lines):
            m = MARKER_RE.match(ln)
            if not m:
                continue
            marker_lines.add(i)
            asset = m.group(2)
            self.marker_line.setdefault(asset, i)
            self.marker_alt.setdefault(asset, m.group(1))
            self.marker_all.setdefault(asset, []).append(i)

        self.view_to_orig = [i for i in range(len(self.lines)) if i not in marker_lines]
        self.view_lines = [self.lines[i] for i in self.view_to_orig]
        self._build_blocks()
        # insertions: file line index (insert AFTER it) -> [asset]
        self.insertions = {}
        # file line indices to drop (markers for owned assets that are gone)
        self.drops = set()

    def _build_blocks(self):
        """blocks: list of dicts(start, end, text, words, anchorable).

        Indices are VIEW indices (see the class docstring).
        """
        self.blocks = []
        in_front = False
        in_toc = False
        start = None
        for i, ln in enumerate(self.view_lines + ['']):
            if i == 0 and ln.strip() == '---':
                in_front = True
                continue
            if in_front:
                if ln.strip() == '---':
                    in_front = False
                continue
            if re.match(r'^## Table of Contents\s*$', ln):
                in_toc = True
            elif re.match(r'^#{1,3} ', ln):
                in_toc = False
            if ln.strip():
                if start is None:
                    start = i
            else:
                if start is not None:
                    body = '\n'.join(self.view_lines[start:i])
                    self.blocks.append(dict(
                        start=start, end=i - 1, text=body,
                        words=norm_words(body),
                        anchorable=not (in_toc or re.match(r'^#{1,6} ', self.view_lines[start])),
                    ))
                    start = None
        # word offsets for cursor ordering
        off = 0
        for b in self.blocks:
            b['word_off'] = off
            off += len(b['words'])

    def find_anchor(self, needle_words, cursor):
        """Locate needle (list of normalized words) in a block.

        Returns (block_idx, line_idx or None, matched_len) or None. Prefers
        the first match at/after the cursor block; falls back to anywhere.
        Tries the longest suffix of the needle first, down to 5 words.
        """
        if not needle_words:
            return None
        for k in range(min(12, len(needle_words)), 4, -1):
            probe = needle_words[-k:]
            hits = []
            for bi, b in enumerate(self.blocks):
                if not b['anchorable']:
                    continue
                pos = _find_sub(b['words'], probe)
                if pos >= 0:
                    hits.append((bi, pos))
            if not hits:
                continue
            chosen = None
            for bi, pos in hits:
                if bi >= cursor:
                    chosen = (bi, pos)
                    break
            if chosen is None:
                chosen = hits[0]
            bi, pos = chosen
            line_idx = self._line_for_word(self.blocks[bi], pos + len(probe) - 1)
            return bi, line_idx, k
        return None

    def _line_for_word(self, block, word_idx):
        """0-based VIEW line index containing the word_idx-th word of block."""
        count = 0
        for li in range(block['start'], block['end'] + 1):
            n = len(norm_words(self.view_lines[li]))
            if word_idx < count + n:
                return li
            count += n
        return block['end']

    def insert_after_block(self, block_idx, asset):
        self.insert_after_line(self.blocks[block_idx]['end'], asset)

    def insert_after_line(self, view_idx, asset):
        """Schedule `asset`'s marker after the file line behind `view_idx`."""
        self.insertions.setdefault(self.view_to_orig[view_idx], []).append(asset)

    def block_is_bullets(self, block_idx):
        b = self.blocks[block_idx]
        bullet_lines = [li for li in range(b['start'], b['end'] + 1)
                        if re.match(r'^\s*- ', self.view_lines[li])]
        return len(bullet_lines) > 1

    def section_end_line(self, block_idx):
        """Last content VIEW line of the ##/### section containing block_idx."""
        for b in self.blocks[block_idx + 1:]:
            if re.match(r'^#{1,3} ', self.view_lines[b['start']]):
                return b['start'] - 1 if b['start'] > 0 else b['end']
        return self.blocks[-1]['end']

    def last_content_line_before(self, view_idx):
        for li in range(view_idx, -1, -1):
            if self.view_lines[li].strip():
                return li
        return view_idx

    def block_at_file_line(self, orig_idx):
        """Block index whose view lines cover `orig_idx`, else the next one.

        Lets a preserved marker still advance the placement cursor, so a
        picture added to the middle of a source doc anchors after the ones
        curation already positioned rather than jumping back up the file.
        """
        for bi, b in enumerate(self.blocks):
            if self.view_to_orig[b['end']] >= orig_idx:
                return bi
        return len(self.blocks) - 1 if self.blocks else 0

    def file_line(self, view_idx):
        """1-based file line number for a view index, for report messages."""
        if not self.view_to_orig:
            return 1
        view_idx = max(0, min(view_idx, len(self.view_to_orig) - 1))
        return self.view_to_orig[view_idx] + 1

    def drop_marker(self, asset):
        """Remove the marker for an owned asset that no longer exists.

        The blank line the marker was inserted with goes too, so dropping the
        last picture out of a paragraph does not leave a doubled blank behind.
        """
        for i in self.marker_all.get(asset, []):
            self.drops.add(i)
            prev_blank = i > 0 and not self.lines[i - 1].strip()
            nxt = i + 1
            next_blank = nxt >= len(self.lines) or not self.lines[nxt].strip()
            if prev_blank and next_blank:
                self.drops.add(i - 1)

    def render(self):
        """The file's new bytes. Byte-identical to `self.raw` when idle."""
        out = []
        for i, ln in enumerate(self.lines):
            if i not in self.drops:
                out.append(ln)
            for asset in self.insertions.get(i, []):
                if out and out[-1].strip():
                    out.append('')
                out.append(f'![]({asset})')
        text = '\n'.join(out)
        if self.final_newline:
            text += '\n'
        if self.crlf:
            text = text.replace('\n', '\r\n')
        return text.encode('utf-8')


def _find_sub(haystack, needle):
    n = len(needle)
    for i in range(len(haystack) - n + 1):
        if haystack[i:i + n] == needle:
            return i
    return -1


# ---------------------------------------------------------------------------
# Image loading / filtering / encoding
# ---------------------------------------------------------------------------

def pil_from_pdf_xref(doc, xref, smask):
    """Best-effort PIL image for a PDF xref (smask folded in when present)."""
    try:
        if smask:
            pix = fitz.Pixmap(doc, xref)
            mask = fitz.Pixmap(doc, smask)
            pix = fitz.Pixmap(pix, mask)
            return Image.open(io.BytesIO(pix.tobytes('png')))
        raw = doc.extract_image(xref)
        return Image.open(io.BytesIO(raw['image']))
    except Exception:
        pix = fitz.Pixmap(doc, xref)
        if pix.colorspace and pix.colorspace.n > 3:
            pix = fitz.Pixmap(fitz.csRGB, pix)
        return Image.open(io.BytesIO(pix.tobytes('png')))


def near_uniform(pil):
    g = pil.convert('L')
    if max(g.size) > 256:
        g.thumbnail((256, 256))
    return ImageStat.Stat(g).stddev[0] < NEAR_UNIFORM_STDDEV


def encode_webp(pil):
    """Encoded WebP bytes.

    In memory rather than straight to disk so a run can compare against what
    is already on disk: identical bytes mean nothing to write (and, for a file
    this tool has no manifest entry for yet, mean it is extractor output being
    adopted rather than a curated photograph about to be clobbered).
    """
    img = pil
    if img.mode not in ('RGB', 'RGBA'):
        img = img.convert('RGBA' if 'A' in img.mode or img.mode == 'P' else 'RGB')
    if max(img.size) > MAX_LONG_EDGE:
        img = img.copy()
        img.thumbnail((MAX_LONG_EDGE, MAX_LONG_EDGE), Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, 'WEBP', quality=WEBP_QUALITY, method=6)
    return buf.getvalue()


# ---------------------------------------------------------------------------
# PDF extraction
# ---------------------------------------------------------------------------

def collect_pdf_images(pdf_path, report):
    """Returns kept images: list of dicts(page, bbox, pil, raw_len, digest, flags)."""
    doc = fitz.open(pdf_path)
    occurrences = {}  # digest -> dict(pages=set, first=(page, bbox), xref, smask, size, w, h)
    order = []
    for pno in range(doc.page_count):
        page = doc[pno]
        infos = page.get_image_info(hashes=True, xrefs=True)
        infos.sort(key=lambda o: (o['bbox'][1], o['bbox'][0]))
        for info in infos:
            digest = info['digest'].hex() if isinstance(info['digest'], bytes) else str(info['digest'])
            rec = occurrences.get(digest)
            if rec is None:
                rec = dict(pages=set(), first=(pno, info['bbox']), xref=info.get('xref', 0),
                           w=info['width'], h=info['height'])
                occurrences[digest] = rec
                order.append(digest)
            rec['pages'].add(pno)

    kept = []
    for digest in order:
        rec = occurrences[digest]
        pno, bbox = rec['first']
        label = f'p{pno + 1} {rec["w"]}x{rec["h"]}'
        if digest in REVIEWER_EXCLUSIONS:
            report.exclude(label, REVIEWER_EXCLUSIONS[digest])
            continue
        if len(rec['pages']) >= REPEAT_PAGE_LIMIT:
            report.exclude(label, f'repeats on {len(rec["pages"])} pages (decoration)')
            continue
        if min(rec['w'], rec['h']) < MIN_DIMENSION_PX:
            report.exclude(label, f'min dimension {min(rec["w"], rec["h"])}px under {MIN_DIMENSION_PX}px')
            continue
        if not rec['xref']:
            report.exclude(label, 'inline image without xref (not extractable)')
            continue
        try:
            raw = doc.extract_image(rec['xref'])
        except Exception as e:
            report.exclude(label, f'extract failed: {e}')
            continue
        raw_len = len(raw['image'])
        if raw_len < MIN_RAW_BYTES:
            report.exclude(label, f'raw payload {raw_len // 1024} KB under {MIN_RAW_BYTES // 1024} KB')
            continue
        try:
            pil = pil_from_pdf_xref(doc, rec['xref'], raw.get('smask', 0))
        except Exception as e:
            report.exclude(label, f'decode failed: {e}')
            continue
        if near_uniform(pil):
            report.exclude(label, 'near-uniform pixels (solid fill / background)')
            continue
        flags = []
        page = doc[pno]
        page_area = abs(page.rect)
        img_area = (bbox[2] - bbox[0]) * (bbox[3] - bbox[1])
        if page_area and img_area / page_area >= FULL_PAGE_AREA_RATIO:
            flags.append('full-page image (reviewer pass)')
        kept.append(dict(page=pno, bbox=bbox, pil=pil, raw_len=raw_len,
                         digest=digest, flags=flags, doc=doc))
    kept.sort(key=lambda k: (k['page'], k['bbox'][1], k['bbox'][0]))
    return doc, kept


def anchor_text_candidates(doc, pno, bbox):
    """Text blocks to try as the anchor, best-first.

    These Canva-style PDFs are frequently two-column: the picture sits BESIDE
    the text that describes it (or above its caption), not below it. So blocks
    that vertically overlap the image rank first (most-overlapped block first;
    on ties the lower block wins, which picks captions under photos), then the
    nearest block above, then the page's first block, then the tails of the
    previous pages.
    """
    cands = []
    page = doc[pno]
    blocks = [b for b in page.get_text('blocks') if b[6] == 0 and b[4].strip()]
    overlapping = []
    for b in blocks:
        ov = min(b[3], bbox[3]) - max(b[1], bbox[1])
        h = b[3] - b[1]
        if h > 0 and ov > 0 and ov / h >= 0.5:
            overlapping.append((ov / h, b[1], b[4]))
    overlapping.sort(key=lambda t: (-t[0], -t[1]))
    cands.extend(t[2] for t in overlapping)
    above = [b for b in blocks if b[3] <= bbox[1] + 8]
    above.sort(key=lambda b: -b[3])  # nearest above first
    cands.extend(b[4] for b in above if b[4] not in cands)
    if blocks:
        first = min(blocks, key=lambda b: (b[1], b[0]))
        if first[4] not in cands:
            cands.append(first[4])
    # previous pages' tail text, walking back
    for prev in range(pno - 1, max(pno - 3, -1), -1):
        pblocks = [b for b in doc[prev].get_text('blocks') if b[6] == 0 and b[4].strip()]
        pblocks.sort(key=lambda b: (-b[3], b[0]))
        cands.extend(b[4] for b in pblocks[:3])
    return cands


def existing_anchor_note(md, asset):
    """Report line for a marker that was already in the doc and is kept as-is."""
    note = f'PRESERVED existing marker at line {md.marker_line[asset] + 1}'
    alt = md.marker_alt.get(asset)
    if alt:
        note += f'; caption "{alt}"'
    return note


def place_pdf_images(doc_id, doc, kept, md, report):
    cursor = 0
    for item in kept:
        asset = item['asset']
        if asset in md.marker_line:
            # Already placed, possibly hand-corrected by a reviewer and
            # possibly captioned. Leave it exactly where curation put it.
            cursor = max(cursor, md.block_at_file_line(md.marker_line[asset]))
            item['anchor'] = existing_anchor_note(md, asset)
            report.keep(item, f'p{item["page"] + 1}')
            continue
        placed = False
        anchor_note = ''
        for cand in anchor_text_candidates(doc, item['page'], item['bbox']):
            hit = md.find_anchor(norm_words(cand), cursor)
            if hit is None:
                continue
            bi, line_idx, k = hit
            if md.block_is_bullets(bi):
                md.insert_after_line(line_idx, asset)
                anchor_note = f'after bullet line {md.file_line(line_idx)}'
            else:
                md.insert_after_block(bi, asset)
                anchor_note = f'after paragraph at line {md.file_line(md.blocks[bi]["start"])}'
            preview = ' '.join(norm_words(cand)[-8:])
            anchor_note += f' (matched {k}w: "...{preview}")'
            cursor = max(cursor, bi)
            placed = True
            break
        if not placed:
            # Fallback: end of the section around the running cursor.
            sect_end = md.section_end_line(cursor) if md.blocks else len(md.view_lines) - 1
            md.insert_after_line(md.last_content_line_before(sect_end), asset)
            anchor_note = (f'FLAGGED no confident match; attached to section end '
                           f'(line {md.file_line(sect_end)})')
            item['flags'].append('no confident anchor (reviewer pass)')
        item['anchor'] = anchor_note
        report.keep(item, f'p{item["page"] + 1}')


# ---------------------------------------------------------------------------
# PPTX extraction
# ---------------------------------------------------------------------------

def ordered_slides(zf):
    """[(slide_no, 'ppt/slides/slideN.xml')] in presentation order."""
    pres_rels = zf.read('ppt/_rels/presentation.xml.rels').decode('utf-8')
    rel_map = dict(re.findall(r'Id="([^"]+)"[^>]*Target="([^"]+)"', pres_rels))
    pres = zf.read('ppt/presentation.xml').decode('utf-8')
    order = re.findall(r'<p:sldId [^>]*r:id="([^"]+)"', pres)
    out = []
    for i, rid in enumerate(order, start=1):
        target = rel_map.get(rid, '')
        if 'slide' in target:
            out.append((i, 'ppt/' + target.lstrip('/').replace('../', '')))
    return out


def collect_pptx_images(pptx_path, report):
    zf = zipfile.ZipFile(pptx_path)
    occurrences = {}  # digest -> dict(slides=set, first_slide, first_order, media, raw)
    order = []
    for slide_no, slide_path in ordered_slides(zf):
        xml = zf.read(slide_path).decode('utf-8')
        rels_path = slide_path.replace('slides/', 'slides/_rels/') + '.rels'
        try:
            rels = zf.read(rels_path).decode('utf-8')
        except KeyError:
            continue
        rel_map = dict(re.findall(r'Id="([^"]+)"[^>]*Target="([^"]+)"', rels))
        for seq, rid in enumerate(re.findall(r'<a:blip [^>]*r:embed="([^"]+)"', xml)):
            target = rel_map.get(rid, '')
            if '/media/' not in target and not target.startswith('../media/'):
                continue
            media = 'ppt/media/' + target.split('media/')[-1]
            try:
                raw = zf.read(media)
            except KeyError:
                continue
            digest = hashlib.sha256(raw).hexdigest()
            rec = occurrences.get(digest)
            if rec is None:
                rec = dict(slides=set(), first_slide=slide_no, first_order=seq,
                           media=media, raw=raw)
                occurrences[digest] = rec
                order.append(digest)
            rec['slides'].add(slide_no)

    kept = []
    for digest in order:
        rec = occurrences[digest]
        label = f'slide {rec["first_slide"]} {os.path.basename(rec["media"])}'
        if digest in REVIEWER_EXCLUSIONS:
            report.exclude(label, REVIEWER_EXCLUSIONS[digest])
            continue
        if len(rec['slides']) >= REPEAT_PAGE_LIMIT:
            report.exclude(label, f'repeats on {len(rec["slides"])} slides (decoration)')
            continue
        if len(rec['raw']) < MIN_RAW_BYTES:
            report.exclude(label, f'raw payload {len(rec["raw"]) // 1024} KB under {MIN_RAW_BYTES // 1024} KB')
            continue
        ext = os.path.splitext(rec['media'])[1].lower()
        if ext in ('.wmf', '.emf', '.svg'):
            report.exclude(label, f'unsupported vector media ({ext})')
            continue
        try:
            pil = Image.open(io.BytesIO(rec['raw']))
            pil.load()
        except Exception as e:
            report.exclude(label, f'decode failed: {e}')
            continue
        if min(pil.size) < MIN_DIMENSION_PX:
            report.exclude(label, f'min dimension {min(pil.size)}px under {MIN_DIMENSION_PX}px')
            continue
        if near_uniform(pil):
            report.exclude(label, 'near-uniform pixels (solid fill / background)')
            continue
        kept.append(dict(slide=rec['first_slide'], seq=rec['first_order'], pil=pil,
                         raw_len=len(rec['raw']), digest=digest, flags=[]))
    kept.sort(key=lambda k: (k['slide'], k['seq']))
    return kept


def place_pptx_images(doc_id, kept, md, report):
    for item in kept:
        asset = item['asset']
        if asset in md.marker_line:
            item['anchor'] = existing_anchor_note(md, asset)
            report.keep(item, f'slide {item["slide"]}')
            continue
        # Anchor: end of the `## Slide N` section.
        target_line = None
        for bi, b in enumerate(md.blocks):
            if re.match(rf'^## Slide {item["slide"]}\s*$', md.view_lines[b['start']]):
                target_line = md.section_end_line(bi)
                break
        if target_line is None:
            target_line = md.blocks[-1]['end']
            item['flags'].append(f'slide {item["slide"]} heading not found (reviewer pass)')
        md.insert_after_line(md.last_content_line_before(target_line), asset)
        item['anchor'] = f'end of "## Slide {item["slide"]}" section'
        report.keep(item, f'slide {item["slide"]}')


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

class Report:
    def __init__(self):
        self.lines = []
        self.total_bytes = 0
        self.kept_count = 0
        self.excluded_count = 0
        self.errors = []

    def doc(self, doc_id, src):
        self.lines.append('')
        self.lines.append(f'== {doc_id} ({src})')

    def note(self, text):
        self.lines.append(f'  {text}')

    def error(self, text):
        self.errors.append(text)
        self.lines.append(f'  ERROR {text}')

    def keep(self, item, where):
        self.kept_count += 1
        flags = f'  [{"; ".join(item["flags"])}]' if item['flags'] else ''
        kb = item.get('webp_len', 0) / 1024
        self.lines.append(
            f'  KEPT {os.path.basename(item["asset"])}: {where}, '
            f'{item["pil"].size[0]}x{item["pil"].size[1]}, '
            f'raw {item["raw_len"] // 1024} KB -> webp {kb:.0f} KB, '
            f'anchor: {item["anchor"]}{flags}')

    def exclude(self, label, reason):
        self.excluded_count += 1
        self.lines.append(f'  EXCLUDED {label}: {reason}')

    def summary(self, changes):
        self.lines.append('')
        self.lines.append(
            f'TOTAL kept={self.kept_count} excluded={self.excluded_count} '
            f'assets={self.total_bytes / (1024 * 1024):.2f} MB')
        self.lines.append('')
        if changes:
            self.lines.append(f'CHANGES ({len(changes)}):')
            self.lines.extend(f'  {c}' for c in changes)
        else:
            self.lines.append('CHANGES none (re-run is a no-op; working tree untouched)')
        if self.errors:
            self.lines.append('')
            self.lines.append(f'ERRORS ({len(self.errors)}): nothing was written.')
        return '\n'.join(self.lines)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def plan_doc(entry, src_root, manifest, report, plan):
    """Work out what this doc needs, writing nothing.

    Appends to `plan` (a dict of pending writes/deletes) and returns the
    doc's new manifest entry, or None to leave the existing entry alone.
    """
    doc_id = entry['doc_id']
    src_path = os.path.join(src_root, entry['src'])
    md_path = os.path.join(KG, entry['md'])
    report.doc(doc_id, entry['src'])
    if not os.path.exists(src_path):
        # No source means no evidence about what this tool owns here, so the
        # manifest entry, the folder, and the markdown all stay untouched.
        report.note(f'MISSING source file: {src_path}')
        return None
    if not os.path.exists(md_path):
        report.note(f'MISSING markdown: {md_path}')
        return None

    out_dir = os.path.join(*ASSET_ROOT.split('/'), doc_id)
    owned = list(manifest.get(doc_id, []))
    md = MdDoc(md_path)
    is_pptx = entry['src'].lower().endswith('.pptx')
    doc = None
    if is_pptx:
        kept = collect_pptx_images(src_path, report)
    else:
        doc, kept = collect_pdf_images(src_path, report)

    # Encode first so the report lines carry final WebP sizes, and so the
    # collision guard below can compare bytes before anything is written.
    for n, item in enumerate(kept, start=1):
        name = f'{n:02d}.webp'
        data = encode_webp(item['pil'])
        item['name'] = name
        item['asset'] = f'{ASSET_ROOT}/{doc_id}/{name}'
        item['webp_bytes'] = data
        item['webp_len'] = len(data)
        report.total_bytes += len(data)

    new_names = [item['name'] for item in kept]
    for item in kept:
        path = os.path.join(out_dir, item['name'])
        on_disk = read_file(path)
        if on_disk == item['webp_bytes']:
            # Byte-identical: this IS extractor output, whether or not the
            # manifest knew about it yet. Nothing to write; adopt it.
            continue
        if on_disk is not None and item['name'] not in owned:
            # A curated photograph sits on the number this run wants. The
            # 2026-08-02 real-images pass numbered its photos after the
            # extracted ones, so this means the source doc grew a picture.
            # Renumbering licensed content is a human decision.
            report.error(
                f'{item["asset"]} exists and is NOT extractor-owned, but this '
                f'run wants to write different bytes over it. The source doc '
                f'likely gained a picture and pushed the numbering into the '
                f'curated range. Move the curated file (and its marker) out of '
                f'the way, or give this doc its own `{doc_id}_extracted/` '
                f'namespace, then re-run.')
            continue
        plan['writes'][path] = item['webp_bytes']
        if on_disk is not None:
            report.note(f'{item["asset"]}: re-encoded, contents changed. If a '
                        f'caption describes the old picture, re-check it.')

    # Owned files the source no longer yields: delete them and drop markers.
    for name in owned:
        if name in new_names:
            continue
        path = os.path.join(out_dir, name)
        asset = f'{ASSET_ROOT}/{doc_id}/{name}'
        if os.path.exists(path):
            plan['deletes'].append(path)
        if asset in md.marker_line:
            md.drop_marker(asset)
        report.note(f'{asset}: no longer in the source; removing it and its marker.')

    if is_pptx:
        place_pptx_images(doc_id, kept, md, report)
    else:
        place_pdf_images(doc_id, doc, kept, md, report)

    rendered = md.render()
    if rendered != md.raw:
        plan['md'][md_path] = rendered
    if kept and not os.path.isdir(out_dir):
        plan['mkdirs'].add(out_dir)
    return new_names


def read_file(path):
    if not os.path.exists(path):
        return None
    with open(path, 'rb') as f:
        return f.read()


def describe(plan, manifest_text, manifest_on_disk):
    out = []
    out += [f'write  {p}' for p in sorted(plan['writes'])]
    out += [f'delete {p}' for p in sorted(plan['deletes'])]
    out += [f'edit   {p}' for p in sorted(plan['md'])]
    if manifest_text != manifest_on_disk:
        out.append(f'edit   {MANIFEST_PATH}')
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--src', required=True, help='path to the docs/training source drop folder')
    ap.add_argument('--report', help='optional path to also write the placement report')
    ap.add_argument('--check', action='store_true',
                    help='dry run: leave the repo tree untouched (only the '
                         'explicitly requested --report file is written) and '
                         'exit non-zero if a real run would change anything')
    args = ap.parse_args()

    if not os.path.isdir(args.src):
        # Never pass vacuously: a --check that silently found no sources
        # would report "no changes" for a tool that had done nothing.
        print(f'ERROR --src is not a directory: {args.src}', file=sys.stderr)
        return 2

    manifest = load_manifest()
    new_manifest = dict(manifest)
    report = Report()
    plan = dict(writes={}, deletes=[], md={}, mkdirs=set())

    for entry in SOURCES:
        names = plan_doc(entry, args.src, manifest, report, plan)
        if names is not None:
            new_manifest[entry['doc_id']] = names

    manifest_text = render_manifest(new_manifest)
    manifest_raw = read_file(MANIFEST_PATH)
    changes = describe(plan, manifest_text, read_text_lf(MANIFEST_PATH))

    text = report.summary(changes)
    print(text)
    if args.report:
        with open(args.report, 'w', encoding='utf-8', newline='\n') as f:
            f.write(text + '\n')

    if report.errors:
        return 1
    if args.check:
        return 1 if changes else 0

    # Apply. Everything above this line is read-only, so a hard stop in any
    # doc leaves the whole tree untouched rather than half-updated.
    for d in sorted(plan['mkdirs']):
        os.makedirs(d, exist_ok=True)
    for path, data in plan['writes'].items():
        with open(path, 'wb') as f:
            f.write(data)
    for path in plan['deletes']:
        os.remove(path)
        parent = os.path.dirname(path)
        if os.path.isdir(parent) and not os.listdir(parent):
            os.rmdir(parent)
    for path, data in plan['md'].items():
        with open(path, 'wb') as f:
            f.write(data)
    if manifest_text != read_text_lf(MANIFEST_PATH):
        write_manifest(manifest_text, manifest_raw)
    return 0


if __name__ == '__main__':
    sys.exit(main())
