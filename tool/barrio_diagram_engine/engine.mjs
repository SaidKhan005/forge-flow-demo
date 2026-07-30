// Barrio training-diagram engine.
// Reads bare_cards.json, renders one clean "hero" pictogram per card as webp,
// in the house style (cream ground, soft accent badge, Lucide line-icon in the
// manual's accent colour, card title beneath). Emits a manifest fragment.
//
// Usage: node engine.mjs <doc_id|ALL>
import sharp from 'sharp';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const LUCIDE = path.join(HERE, 'node_modules', 'lucide-static', 'icons');
const CARDS = JSON.parse(fs.readFileSync(path.join(HERE, 'bare_cards.json'), 'utf8'));

const CREAM = '#F7F3EA', INK = '#16243B', BADGE_ALPHA = '18'; // ~9% hex alpha
const W = 1400, H = 900, FONT = 'IBM Plex Sans, Segoe UI, Helvetica, Arial, sans-serif';

// ---- diagram output folder per doc (existing two reuse their folders) ----
const DOC_FOLDER = {
  company_handbook: 'barrio_company_handbook_diagrams',
  training_food_safety: 'food_safety_manual_diagrams',
  training_tequila: 'training_tequila_diagrams',
};
const folderFor = (doc) => DOC_FOLDER[doc] || `${doc}_diagrams`;

// ---- icon cache: return inner markup of a lucide icon, or null ----
const iconCache = new Map();
function lucideInner(name) {
  if (iconCache.has(name)) return iconCache.get(name);
  const p = path.join(LUCIDE, name + '.svg');
  if (!fs.existsSync(p)) { iconCache.set(name, null); return null; }
  let s = fs.readFileSync(p, 'utf8');
  s = s.replace(/<!--[\s\S]*?-->/g, '').replace(/<svg[^>]*>/, '').replace(/<\/svg>/, '').trim();
  iconCache.set(name, s);
  return s;
}

// ---- keyword -> icon (ordered; SPECIFIC concepts first, generic last). ----
// Matched against the TITLE first (the card's topic), then the body.
const KEYWORDS = [
  // --- abstract lesson concepts + restaurant slang (specific, win first) ---
  [/\bglossar|words? to know|terms?\b/, 'book-open'], [/\bsuccess|winning|thrive\b/, 'target'],
  [/\bconflict|dispute|resolution|de-?escalat\b/, 'handshake'], [/\bphilosoph|mindset|attitude|approach\b/, 'brain'],
  [/\bzone|range|window\b/, 'target'], [/\bmission|vision\b/, 'flag'],
  [/\bnon-?negotiab|must\b/, 'file-check'], [/\bfeature|highlight|special\b/, 'star'],
  [/\bexpo|expedit\b/, 'concierge-bell'], [/\bfront of house|\bfoh\b/, 'store'],
  [/\bback of house|\bboh\b/, 'chef-hat'], [/\bcamper|linger|dwell\b/, 'armchair'],
  [/\b911|emergenc|urgent|weeded|slammed\b/, 'siren'], [/\bdrowning|overwhelm|buried\b/, 'waves'],
  [/\bclopen\b/, 'clock'], [/\bdead|slow night|business decline\b/, 'trending-down'],
  [/\bcomp\b|complimentar\b/, 'gift'], [/\b86|out of stock|sold out\b/, 'ban'],
  [/\bfire\b|on the fly\b/, 'flame'], [/\bturn(over)?|flip the table\b/, 'refresh-cw'],
  [/\bside ?work|closing dut\b/, 'clipboard-list'], [/\bchit|ticket|order slip\b/, 'receipt-text'],
  [/\bsection|station\b/, 'grid-3x3'], [/\brunner|running food\b/, 'utensils'],
  [/\bmenu knowledge\b/, 'book-open'],
  // --- restaurant finance / metrics jargon (specific, win early) ---
  [/\b(agc|guest check|average check|avg check)\b/, 'receipt'],
  [/\bcovers?\b/, 'users'], [/\bper labou?r hour|cplh|splh\b/, 'clock'],
  [/\bset goals?|objective\b/, 'target'], [/\bfactor|driver|lever\b/, 'sliders-horizontal'],
  [/\bbenefit|advantage\b/, 'thumbs-up'], [/\bincreas|boost\b/, 'trending-up'],
  [/\bproductiv|output|throughput\b/, 'gauge'],
  // --- specific single-concept nouns (win over generic) ---
  [/\blight(ing)?\b/, 'lamp-ceiling'], [/\bmusic|playlist\b/, 'music'],
  [/\bdecor\b/, 'armchair'], [/\btemperat|thermom\b/, 'thermometer'],
  [/\btiming|timel|pace\b/, 'clock'], [/\bconsisten|reliab\b/, 'refresh-cw'],
  [/\bbalanc|equilibr\b/, 'scale'], [/\battentiv|attention\b/, 'ear'],
  [/\bcleanlin|clean|sanit|tidy\b/, 'spray-can'], [/\borganiz|organis|order\b/, 'layout-list'],
  [/\bplating|presentation\b/, 'utensils'], [/\bquality|excellen\b/, 'award'],
  [/\bemotion|feel|mood\b/, 'heart'], [/\bconnect|rapport|relationship|bond\b/, 'heart-handshake'],
  [/\bwarm|genuine|hospitalit\b/, 'heart'], [/\bsmile|friendly|welcoming\b/, 'smile'],
  [/\blisten|hear\b/, 'ear'], [/\beye contact|observ|watch|notice\b/, 'eye'],
  [/\bcommunicat|conversation|dialog\b/, 'message-circle'], [/\bgreet|welcom|arrival\b/, 'door-open'],
  [/\bfarewell|goodbye\b/, 'hand'], [/\bempath|kindness|compassion\b/, 'heart'],
  [/\brespect|dignity|courtes\b/, 'handshake'], [/\bteamwork|team|crew|colleague\b/, 'users'],
  // --- food & drink ---
  [/\bmenu\b/, 'book-open'], [/\bdish|entree|course\b/, 'utensils'],
  [/\bingredient|produce\b/, 'leaf'], [/\bwine\b/, 'wine'], [/\bbeer|draught|draft\b/, 'beer'],
  [/\bcocktail|martini|mixolog\b/, 'martini'], [/\bcoffee|espresso|latte\b/, 'coffee'],
  [/\btequila|agave|mezcal\b/, 'martini'], [/\bcook|grill|saute\b/, 'flame'],
  [/\bknife|cut|chop|prep\b/, 'utensils-crossed'], [/\bgarnish|cilantro|lime|citrus\b/, 'citrus'],
  [/\bspice|chili|salsa\b/, 'flame'], [/\brecipe|spec\b/, 'clipboard-list'],
  [/\bportion|serving size\b/, 'utensils'], [/\bpour|glassware|beverage\b/, 'wine'],
  [/\bmeal|food\b/, 'utensils'], [/\bfresh\b/, 'leaf'],
  // --- safety / compliance ---
  [/\bwash|hygien|handwash\b/, 'droplets'], [/\bcold|chill|refriger|fridge\b/, 'snowflake'],
  [/\bcontaminat|separat|cross-?con\b/, 'split'], [/\ballerg|reaction\b/, 'triangle-alert'],
  [/\bsafe|safety|hazard|risk\b/, 'shield-check'], [/\bfire|extinguish|burn\b/, 'flame-kindling'],
  [/\bfirst aid|injur|accident\b/, 'cross'], [/\bstorage|store|labell?ing|expiry\b/, 'package'],
  [/\bpest|rodent|insect\b/, 'bug'], [/\bglove|apron|ppe\b/, 'shield'],
  // --- numbers / metrics / money ---
  [/\bcost|expense|spend\b/, 'dollar-sign'], [/\bsales|revenue|income\b/, 'trending-up'],
  [/\bprofit|margin\b/, 'trending-up'], [/\blabou?r|staffing|payroll\b/, 'users'],
  [/\bhour|shift\b/, 'clock'], [/\bschedul|roster\b/, 'calendar'],
  [/\bratio|percent|rate\b/, 'percent'], [/\btarget|goal|benchmark\b/, 'target'],
  [/\bmetric|measure|kpi\b/, 'gauge'], [/\bchart|graph|data\b/, 'bar-chart-3'],
  [/\btip|gratuit\b/, 'coins'], [/\bbudget|forecast\b/, 'calculator'],
  [/\bgrowth|improve|increase\b/, 'sprout'], [/\bupsell|suggestive|recommend|sell\b/, 'trending-up'],
  [/\bvalue|worth|pricing\b/, 'tag'], [/\bformula|calculat|math\b/, 'calculator'],
  // --- policy / handbook / general ---
  [/\bpolicy|rule|guideline|code of\b/, 'scroll-text'], [/\buniform|dress|grooming|appearance\b/, 'shirt'],
  [/\bphone|cell|mobile\b/, 'smartphone'], [/\bsmok\b/, 'cigarette-off'],
  [/\balcohol|liquor|intoxicat|responsib.*serv\b/, 'wine'], [/\bbreak|rest period\b/, 'coffee'],
  [/\bpay|wage|salary|compensat\b/, 'banknote'], [/\bharass|misconduct\b/, 'shield-alert'],
  [/\btrain|learn|develop|onboard\b/, 'graduation-cap'], [/\bstandard\b/, 'badge-check'],
  [/\bchecklist|checkpoint|verify\b/, 'list-checks'], [/\bstep|procedure|process|workflow\b/, 'footprints'],
  [/\bhistory|origin|heritage|legacy|tradition\b/, 'landmark'], [/\bmission|vision|purpose\b/, 'compass'],
  [/\bidea|innov|creativ\b/, 'lightbulb'], [/\bdesign|aesthetic|brand\b/, 'palette'],
  [/\bhonest|transparen|integrity\b/, 'eye'], [/\bknowledge|understand\b/, 'book-open'],
  [/\bpassion|energy|drive\b/, 'flame'], [/\bownership|account|responsib\b/, 'user-check'],
  [/\bfoundation|core|pillar|strong\b/, 'columns-3'], [/\bkey|essential\b/, 'key'],
  [/\bgift|generos\b/, 'gift'], [/\bfocus|priorit\b/, 'crosshair'],
  [/\bflow|smooth|efficien\b/, 'workflow'], [/\bstory|narrative\b/, 'scroll-text'],
  [/\bexperience|journey\b/, 'route'], [/\benvironment|space|room\b/, 'sofa'],
  [/\bguest|customer|patron|diner\b/, 'users'], [/\bservice|server|waiter\b/, 'hand-platter'],
  [/\bhost|seating|table\b/, 'armchair'],
];

const DOC_DEFAULT = {
  company_handbook: 'book-open', interview_playbook: 'user-search', jim_taylor_labor_model: 'gauge',
  training_strong_foundation: 'columns-3', training_table_manicuring: 'sparkles', training_three_pillars: 'columns-3',
  training_suggestive_selling: 'trending-up', training_tequila: 'martini', training_menu_concept: 'book-open',
  training_labour_cost: 'scale', training_bold_by_design: 'palette', training_food_safety: 'shield-check',
  training_cheers_responsibility: 'wine', training_mastering_metrics: 'gauge', training_general_words: 'book-open',
  training_clover_sop: 'monitor', training_push_sop: 'calendar-clock', training_host_manual: 'concierge-bell',
  training_bar_manual: 'martini', training_drink_specs: 'wine',
};
// per-doc rotation to break monotony when keyword misses / repeats
const DOC_ROTATE = {
  training_general_words: ['book-open', 'graduation-cap', 'sparkles', 'bookmark', 'library', 'pen-line'],
  training_bold_by_design: ['palette', 'sparkles', 'pen-tool', 'shapes', 'lightbulb', 'layout-dashboard'],
  training_bar_manual: ['martini', 'wine', 'beer', 'glass-water', 'citrus', 'flame'],
  training_food_safety: ['shield-check', 'droplets', 'thermometer', 'snowflake', 'spray-can', 'package'],
  company_handbook: ['book-open', 'scroll-text', 'badge-check', 'users', 'shield-check', 'clipboard-list'],
};

function firstExisting(names) {
  for (const n of names) if (n && lucideInner(n)) return n;
  return null;
}
function matchIn(text) {
  const t = text.toLowerCase();
  for (const [re, name] of KEYWORDS) if (re.test(t) && lucideInner(name)) return name;
  return null;
}
function pickIcon(card, prev, rotIdx) {
  // 1) title is the card's topic — match it first (repeats across cards are fine).
  const byTitle = matchIn(card.title);
  if (byTitle) return byTitle;
  // 2) fall back to the body, but avoid immediately repeating the previous icon.
  const t = card.body.toLowerCase();
  const bodyHits = [];
  for (const [re, name] of KEYWORDS) if (re.test(t) && lucideInner(name)) bodyHits.push(name);
  for (const n of bodyHits) if (n !== prev) return n;
  if (bodyHits.length) return bodyHits[0];
  // 3) no keyword at all: rotate the doc's tasteful set, else the doc default.
  const rot = DOC_ROTATE[card.doc];
  if (rot) {
    for (let k = 0; k < rot.length; k++) {
      const n = rot[(rotIdx + k) % rot.length];
      if (lucideInner(n) && n !== prev) return n;
    }
  }
  return firstExisting([DOC_DEFAULT[card.doc], 'book-open', 'circle']);
}

// ---- text helpers ----
const xmlesc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const deDash = (s) => s.replace(/\s*[—–]\s*/g, ' - ').replace(/\s+/g, ' ').trim();
// normalized base title (drops a trailing "(cont.)" so split cards share art)
const baseKey = (t) => t.replace(/\s*\((cont\.?|continued)\)\s*$/i, '').trim().toLowerCase();
const cleanLabel = (t) => deDash(t.replace(/\s*\((cont\.?|continued)\)\s*$/i, '').trim());
function wrap(str, maxChars, maxLines) {
  const words = str.split(' ');
  const lines = [];
  let cur = '';
  for (const w of words) {
    if ((cur + ' ' + w).trim().length > maxChars && cur) { lines.push(cur); cur = w; }
    else cur = (cur + ' ' + w).trim();
    if (lines.length === maxLines - 1 && (cur + ' ').length > maxChars) break;
  }
  if (cur) lines.push(cur);
  if (lines.length > maxLines) { lines.length = maxLines; lines[maxLines - 1] += '…'; }
  return lines;
}

function renderSVG(card, iconName) {
  const accent = card.accent;
  const inner = lucideInner(iconName) || lucideInner('circle');
  const ICON = 300, s = ICON / 24, sw = (9 / s).toFixed(3);
  const iconCX = 700, iconCY = 348;
  const badge = 250; // half-size of rounded badge
  const title = cleanLabel(card.title);
  const lines = wrap(title, 26, 3);
  const titleTop = 600;
  const lh = 74, tsize = 58;
  const tspans = lines.map((ln, i) =>
    `<tspan x="700" dy="${i === 0 ? 0 : lh}">${xmlesc(ln)}</tspan>`).join('');
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <rect width="${W}" height="${H}" fill="${CREAM}"/>
  <rect x="${iconCX - badge}" y="${iconCY - badge}" width="${badge * 2}" height="${badge * 2}" rx="64" fill="${accent}${BADGE_ALPHA}"/>
  <g fill="none" stroke="${accent}" stroke-width="${sw}" stroke-linecap="round" stroke-linejoin="round" transform="translate(${iconCX},${iconCY}) scale(${s}) translate(-12,-12)">${inner}</g>
  <text font-family="${FONT}" font-size="${tsize}" font-weight="600" fill="${INK}" text-anchor="middle" y="${titleTop}">${tspans}</text>
</svg>`;
}

async function renderDoc(doc, cards, missing, usage) {
  const folder = folderFor(doc);
  const outDir = path.join(HERE, 'out', folder);
  fs.mkdirSync(outDir, { recursive: true });
  const manifest = {};
  const baseIcon = new Map();
  let prev = null;
  const jobs = cards.map((card, i) => {
    const bk = baseKey(card.title);
    let iconName = baseIcon.get(bk);
    if (!iconName) { iconName = pickIcon(card, prev, i); baseIcon.set(bk, iconName); }
    prev = iconName;
    if (!lucideInner(iconName)) missing.add(iconName);
    usage[iconName] = (usage[iconName] || 0) + 1;
    const svg = renderSVG(card, iconName);
    const assetPath = `assets/internal/barrio/training/${folder}/${card.id}.webp`;
    manifest[card.id] = [{ afterParagraph: -1, assetPath, caption: `Diagram: ${cleanLabel(card.title)}` }];
    return sharp(Buffer.from(svg)).webp({ quality: 88 }).toFile(path.join(outDir, card.id + '.webp'));
  });
  await Promise.all(jobs);
  fs.writeFileSync(path.join(HERE, 'out', `${doc}.manifest.json`), JSON.stringify(manifest, null, 1));
  return cards.length;
}

const arg = process.argv[2] || 'ALL';
const docs = arg === 'ALL' ? Object.keys(CARDS) : [arg];
const missing = new Set();
const usage = {};
let total = 0;
for (const doc of docs) {
  const cards = CARDS[doc] || [];
  if (!cards.length) continue;
  total += await renderDoc(doc, cards, missing, usage);
  console.log(`${doc}: ${cards.length} rendered -> out/${folderFor(doc)}/`);
}
console.log(`\nTOTAL rendered: ${total}`);
if (missing.size) console.log('MISSING icons (fell back):', [...missing].join(', '));
