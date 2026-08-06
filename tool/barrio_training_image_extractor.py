"""Extract content pictures from the Barrio training source files and place
image markers into the verbatim knowledge-graph markdown docs.

Usage (from the repo root):
    python tool/barrio_training_image_extractor.py --src "<path to docs/training>" [--report <path>]

The source drop folder is untracked and normally lives only in the main
checkout (e.g. `C:\\Git Local Repos\\forge_flow_demo\\docs\\training`), so the
path is always passed explicitly. The tool is idempotent: it clears the
per-doc asset folders and strips previously inserted training image markers
from the markdown before re-extracting, so re-runs converge to the same
output.

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
import os
import re
import sys
import zipfile

import fitz  # PyMuPDF
from PIL import Image, ImageStat

KG = 'docs/Knowledge_graph_docs'
ASSET_ROOT = 'assets/internal/barrio/training'

MIN_DIMENSION_PX = 100
MIN_RAW_BYTES = 10 * 1024
REPEAT_PAGE_LIMIT = 3          # digest on 3+ pages/slides = decoration
NEAR_UNIFORM_STDDEV = 8.0      # grayscale stddev below this = solid fill
FULL_PAGE_AREA_RATIO = 0.90    # bbox covering >= 90% of the page = flag
WEBP_QUALITY = 80
MAX_LONG_EDGE = 1200

MARKER_RE = re.compile(r'^!\[[^\]]*\]\(assets/internal/barrio/training/[^)]+\)\s*$')

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
    """Blank-line-separated block model over a knowledge-graph markdown file."""

    def __init__(self, path):
        self.path = path
        raw = open(path, 'rb').read()
        self.crlf = b'\r\n' in raw
        text = raw.decode('utf-8').replace('\r\n', '\n')
        # Idempotency: strip previously inserted training image markers.
        lines = [ln for ln in text.split('\n') if not MARKER_RE.match(ln)]
        text = re.sub(r'\n{3,}', '\n\n', '\n'.join(lines))
        self.lines = text.split('\n')
        self._build_blocks()
        # insertions: line_index (insert AFTER this 0-based line) -> [asset]
        self.insertions = {}

    def _build_blocks(self):
        """blocks: list of dicts(start, end, text, words, anchorable)."""
        self.blocks = []
        in_front = False
        in_toc = False
        start = None
        for i, ln in enumerate(self.lines + ['']):
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
                    body = '\n'.join(self.lines[start:i])
                    self.blocks.append(dict(
                        start=start, end=i - 1, text=body,
                        words=norm_words(body),
                        anchorable=not (in_toc or re.match(r'^#{1,6} ', self.lines[start])),
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
        """0-based file line index containing the word_idx-th word of block."""
        count = 0
        for li in range(block['start'], block['end'] + 1):
            n = len(norm_words(self.lines[li]))
            if word_idx < count + n:
                return li
            count += n
        return block['end']

    def insert_after_block(self, block_idx, asset):
        self.insertions.setdefault(self.blocks[block_idx]['end'], []).append(asset)

    def insert_after_line(self, line_idx, asset):
        self.insertions.setdefault(line_idx, []).append(asset)

    def block_is_bullets(self, block_idx):
        b = self.blocks[block_idx]
        bullet_lines = [li for li in range(b['start'], b['end'] + 1)
                        if re.match(r'^\s*- ', self.lines[li])]
        return len(bullet_lines) > 1

    def section_end_line(self, block_idx):
        """Last content line of the ##/### section containing block_idx."""
        for b in self.blocks[block_idx + 1:]:
            if re.match(r'^#{1,3} ', self.lines[b['start']]):
                return b['start'] - 1 if b['start'] > 0 else b['end']
        return self.blocks[-1]['end']

    def last_content_line_before(self, line_idx):
        for li in range(line_idx, -1, -1):
            if self.lines[li].strip():
                return li
        return line_idx

    def write(self):
        out = []
        for i, ln in enumerate(self.lines):
            out.append(ln)
            for asset in self.insertions.get(i, []):
                out.append('')
                out.append(f'![]({asset})')
        text = re.sub(r'\n{3,}', '\n\n', '\n'.join(out))
        if not text.endswith('\n'):
            text += '\n'
        data = text.replace('\n', '\r\n') if self.crlf else text
        with open(self.path, 'w', encoding='utf-8', newline='') as f:
            f.write(data)


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


def encode_webp(pil, out_path):
    img = pil
    if img.mode not in ('RGB', 'RGBA'):
        img = img.convert('RGBA' if 'A' in img.mode or img.mode == 'P' else 'RGB')
    if max(img.size) > MAX_LONG_EDGE:
        img = img.copy()
        img.thumbnail((MAX_LONG_EDGE, MAX_LONG_EDGE), Image.LANCZOS)
    img.save(out_path, 'WEBP', quality=WEBP_QUALITY, method=6)
    return os.path.getsize(out_path)


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


def place_pdf_images(doc_id, doc, kept, md, report):
    cursor = 0
    for n, item in enumerate(kept, start=1):
        asset = f'{ASSET_ROOT}/{doc_id}/{n:02d}.webp'
        placed = False
        anchor_note = ''
        for cand in anchor_text_candidates(doc, item['page'], item['bbox']):
            hit = md.find_anchor(norm_words(cand), cursor)
            if hit is None:
                continue
            bi, line_idx, k = hit
            if md.block_is_bullets(bi):
                md.insert_after_line(line_idx, asset)
                anchor_note = f'after bullet line {line_idx + 1}'
            else:
                md.insert_after_block(bi, asset)
                anchor_note = f'after paragraph at line {md.blocks[bi]["start"] + 1}'
            preview = ' '.join(norm_words(cand)[-8:])
            anchor_note += f' (matched {k}w: "...{preview}")'
            cursor = max(cursor, bi)
            placed = True
            break
        if not placed:
            # Fallback: end of the section around the running cursor.
            sect_end = md.section_end_line(cursor) if md.blocks else len(md.lines) - 1
            md.insert_after_line(md.last_content_line_before(sect_end), asset)
            anchor_note = f'FLAGGED no confident match; attached to section end (line {sect_end + 1})'
            item['flags'].append('no confident anchor (reviewer pass)')
        item['asset'] = asset
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
    for n, item in enumerate(kept, start=1):
        asset = f'{ASSET_ROOT}/{doc_id}/{n:02d}.webp'
        # Anchor: end of the `## Slide N` section.
        target_line = None
        for bi, b in enumerate(md.blocks):
            if re.match(rf'^## Slide {item["slide"]}\s*$', md.lines[b['start']]):
                target_line = md.section_end_line(bi)
                break
        if target_line is None:
            target_line = md.blocks[-1]['end']
            item['flags'].append(f'slide {item["slide"]} heading not found (reviewer pass)')
        md.insert_after_line(md.last_content_line_before(target_line), asset)
        item['asset'] = asset
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

    def doc(self, doc_id, src):
        self.lines.append('')
        self.lines.append(f'== {doc_id} ({src})')

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

    def summary(self):
        self.lines.append('')
        self.lines.append(
            f'TOTAL kept={self.kept_count} excluded={self.excluded_count} '
            f'assets={self.total_bytes / (1024 * 1024):.2f} MB')
        return '\n'.join(self.lines)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--src', required=True, help='path to the docs/training source drop folder')
    ap.add_argument('--report', help='optional path to also write the placement report')
    args = ap.parse_args()

    report = Report()
    for entry in SOURCES:
        src_path = os.path.join(args.src, entry['src'])
        md_path = os.path.join(KG, entry['md'])
        report.doc(entry['doc_id'], entry['src'])
        if not os.path.exists(src_path):
            report.lines.append(f'  MISSING source file: {src_path}')
            continue
        if not os.path.exists(md_path):
            report.lines.append(f'  MISSING markdown: {md_path}')
            continue

        out_dir = os.path.join(*ASSET_ROOT.split('/'), entry['doc_id'])
        os.makedirs(out_dir, exist_ok=True)
        for old in os.listdir(out_dir):
            if old.endswith('.webp'):
                os.remove(os.path.join(out_dir, old))

        md = MdDoc(md_path)
        if entry['src'].lower().endswith('.pptx'):
            kept = collect_pptx_images(src_path, report)
        else:
            doc, kept = collect_pdf_images(src_path, report)

        # Encode first so the report lines carry final WebP sizes.
        for n, item in enumerate(kept, start=1):
            out_path = os.path.join(out_dir, f'{n:02d}.webp')
            size = encode_webp(item['pil'], out_path)
            item['webp_len'] = size
            report.total_bytes += size

        if entry['src'].lower().endswith('.pptx'):
            place_pptx_images(entry['doc_id'], kept, md, report)
        else:
            place_pdf_images(entry['doc_id'], doc, kept, md, report)
        md.write()
        if not kept:
            os.rmdir(out_dir)

    text = report.summary()
    print(text)
    if args.report:
        with open(args.report, 'w', encoding='utf-8', newline='\n') as f:
            f.write(text + '\n')


if __name__ == '__main__':
    sys.exit(main())
