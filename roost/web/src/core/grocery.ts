// Grocery brain (mirror of RoostKit/Grocery.swift). Spec: shared/README.md §1–3.
import taxonomyJson from '@shared/grocery/taxonomy.json';

export function normalize(s: string): string {
  let t = s.toLowerCase().normalize('NFD').replace(/\p{M}/gu, '');
  t = t.replace(/&/g, ' and ').replace(/['’]/g, '');
  return t.replace(/[^a-z0-9%]+/g, ' ').trim();
}

export function tokens(s: string): string[] {
  const n = normalize(s);
  return n ? n.split(' ') : [];
}

export function singularVariants(w: string): string[] {
  const v: string[] = [];
  const add = (x: string) => { if (x !== w && x && !v.includes(x)) v.push(x); };
  if (w.endsWith('ies') && w.length > 4) add(w.slice(0, -3) + 'y');
  if (w.endsWith('oes')) add(w.slice(0, -2));
  if (w.endsWith('ves')) { add(w.slice(0, -3) + 'f'); add(w.slice(0, -3) + 'fe'); }
  if (['ses', 'xes', 'zes', 'ches', 'shes'].some((x) => w.endsWith(x))) add(w.slice(0, -2));
  if (w.endsWith('s') && !w.endsWith('ss') && !w.endsWith('us') && !w.endsWith('is')) add(w.slice(0, -1));
  return v;
}

export interface GroceryCategory { key: string; name: string; emoji: string; symbol: string; order: number }

interface RawTaxonomy { categories: GroceryCategory[]; modifiers: Record<string, string>; terms: Record<string, string[]> }

export class Taxonomy {
  readonly categories: GroceryCategory[];
  readonly modifiers: Record<string, string>;
  readonly index = new Map<string, string>();

  constructor(raw: RawTaxonomy) {
    this.categories = [...raw.categories].sort((a, b) => a.order - b.order);
    this.modifiers = raw.modifiers;
    for (const [cat, terms] of Object.entries(raw.terms)) for (const t of terms) this.index.set(normalize(t), cat);
  }

  category(key: string): GroceryCategory {
    return this.categories.find((c) => c.key === key) ?? this.categories[this.categories.length - 1];
  }
}

export const taxonomy = new Taxonomy(taxonomyJson as RawTaxonomy);

// ---- line parsing --------------------------------------------------------

export interface ParsedGrocery { name: string; quantity: number | null; unit: string | null }

const UNIT_GROUPS: [string, string[]][] = [
  ['lb', ['lb', 'lbs', 'pound', 'pounds']], ['oz', ['oz', 'ounce', 'ounces']], ['g', ['g', 'gram', 'grams']],
  ['kg', ['kg', 'kgs', 'kilogram', 'kilograms']], ['ml', ['ml']], ['l', ['l', 'liter', 'liters', 'litre', 'litres']],
  ['gal', ['gal', 'gallon', 'gallons']], ['qt', ['qt', 'quart', 'quarts']], ['pt', ['pt', 'pint', 'pints']],
  ['cup', ['cup', 'cups']], ['dozen', ['dozen', 'doz']], ['pack', ['pack', 'packs', 'pk', 'pkg', 'package', 'packages']],
  ['box', ['box', 'boxes']], ['bag', ['bag', 'bags']], ['can', ['can', 'cans']], ['jar', ['jar', 'jars']],
  ['bottle', ['bottle', 'bottles']], ['bunch', ['bunch', 'bunches']], ['head', ['head', 'heads']], ['loaf', ['loaf', 'loaves']],
  ['carton', ['carton', 'cartons']], ['container', ['container', 'containers']], ['roll', ['roll', 'rolls']],
  ['bar', ['bar', 'bars']], ['stick', ['stick', 'sticks']], ['piece', ['piece', 'pieces', 'pc', 'pcs']],
  ['ct', ['ct', 'count']], ['case', ['case', 'cases']], ['tub', ['tub', 'tubs']],
];
export const UNITS = new Map<string, string>();
for (const [canon, words] of UNIT_GROUPS) for (const w of words) UNITS.set(w, canon);

const WORDS: Record<string, number> = {
  one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10, eleven: 11, twelve: 12, half: 0.5, couple: 2,
};
const FRACTIONS: Record<string, number> = { '½': 0.5, '¼': 0.25, '¾': 0.75, '⅓': 1 / 3, '⅔': 2 / 3, '⅛': 0.125 };

function parseNumber(t: string): number | null {
  if (/^(\d+\.?\d*|\.\d+)$/.test(t)) return Number(t);
  const last = t.slice(-1);
  if (last in FRACTIONS) {
    const head = t.slice(0, -1);
    if (!head) return FRACTIONS[last];
    if (/^\d+$/.test(head)) return Number(head) + FRACTIONS[last];
    return null;
  }
  const m = /^(\d+)\/(\d+)$/.exec(t);
  if (m && Number(m[2]) !== 0) return Number(m[1]) / Number(m[2]);
  return null;
}

const TRAILING = /(?:^|\s)(?:[x×]\s*(\d+(?:\.\d+)?)|\((\d+(?:\.\d+)?)\))\s*$/i;
const GLUED = /^(\d+(?:\.\d+)?|\d*[½¼¾⅓⅔⅛])(x|-?[a-z]+)$/i;

export function cleanName(s: string): string {
  const t = s.replace(/^[\s,;:\-–]+|[\s,;:\-–]+$/g, '');
  return t ? t[0].toUpperCase() + t.slice(1) : '';
}

export function parseGroceryLine(raw: string): ParsedGrocery | null {
  let s = raw.trim();
  if (!s) return null;
  let qty: number | null = null;
  let unit: string | null = null;

  const tm = TRAILING.exec(s);
  if (tm && tm.index > 0) {
    qty = Number(tm[1] ?? tm[2]);
    s = s.slice(0, tm.index).trim();
  }

  let toks = s.split(/[ \t]+/).filter(Boolean);
  if (qty === null && toks.length) {
    const g = GLUED.exec(toks[0]);
    if (g) {
      let rest = g[2];
      if (rest.startsWith('-')) rest = rest.slice(1);
      if (rest.toLowerCase() === 'x' || UNITS.has(rest.toLowerCase())) toks.splice(0, 1, g[1], rest);
    }
    let i = 0;
    const lower = (k: number) => (k < toks.length ? toks[k].toLowerCase() : '');
    const n0 = parseNumber(toks[0]);
    if (lower(0) === 'a' || lower(0) === 'an') {
      if (lower(1) === 'couple') { qty = 2; i = 2; } else { qty = 1; i = 1; }
    } else if (lower(0) in WORDS && (lower(0) !== 'half' || UNITS.has(lower(1)))) {
      qty = WORDS[lower(0)]; i = 1;
    } else if (n0 !== null) {
      qty = n0; i = 1;
      const n1 = lower(1);
      const frac = parseNumber(n1);
      if (frac !== null && (n1.includes('/') || (n1.length === 1 && n1 in FRACTIONS))) { qty = n0 + frac; i = 2; }
    } else if (lower(0) === 'dozen') {
      qty = 1; unit = 'dozen'; i = 1;
    }
    if (qty !== null) {
      if (lower(i) === 'x' || lower(i) === '×') i++;
      let unitIndex: number | null = null;
      const u = UNITS.get(lower(i).replace(/\.+$/, ''));
      if (unit === null && u) { unit = u; unitIndex = i; i++; }
      if (lower(i) === 'of') i++;
      let rest = toks.slice(i);
      if (!rest.length) {
        if (unitIndex !== null) { rest = [toks[unitIndex]]; unit = null; } else { qty = null; unit = null; rest = toks; }
      }
      toks = rest;
    }
  }
  const name = cleanName(toks.join(' '));
  if (!name) return { name: cleanName(raw), quantity: null, unit: null };
  return { name, quantity: qty, unit };
}

export function formatQuantity(q: number | null | undefined, unit?: string | null): string | null {
  if (q === null || q === undefined || q <= 0) return unit || null;
  let n: string;
  if (q === 0.5) n = '½'; else if (q === 0.25) n = '¼'; else if (q === 0.75) n = '¾';
  else if (Number.isInteger(q)) n = String(q); else n = String(Number(q.toPrecision(2)));
  return unit ? `${n} ${unit}` : n;
}

// ---- categorization ------------------------------------------------------

export interface CategoryResult { category: string; source: 'learned' | 'dictionary' | 'none' }

const OVERRIDABLE = new Set(['produce', 'meat', 'bakery', 'dairy']);

export function categorize(name: string, learned: Map<string, string> = new Map(), tax: Taxonomy = taxonomy): CategoryResult {
  const toks = tokens(name);
  if (!toks.length) return { category: 'other', source: 'none' };
  const full = toks.join(' ');
  if (learned.has(full)) return { category: learned.get(full)!, source: 'learned' };
  for (const v of singularVariants(toks[toks.length - 1])) {
    const alt = [...toks.slice(0, -1), v].join(' ');
    if (learned.has(alt)) return { category: learned.get(alt)!, source: 'learned' };
  }
  let best: { len: number; end: number; exact: boolean; cat: string } | null = null;
  for (let len = Math.min(4, toks.length); len >= 1; len--) {
    for (let start = 0; start + len <= toks.length; start++) {
      const gram = toks.slice(start, start + len);
      let hit: { exact: boolean; cat: string } | null = null;
      const exact = tax.index.get(gram.join(' '));
      if (exact) hit = { exact: true, cat: exact };
      else {
        for (const v of singularVariants(gram[gram.length - 1])) {
          const c = tax.index.get([...gram.slice(0, -1), v].join(' '));
          if (c) { hit = { exact: false, cat: c }; break; }
        }
      }
      if (!hit) continue;
      const end = start + len - 1;
      if (best) {
        if (len < best.len) continue;
        if (len === best.len && end < best.end) continue;
        if (len === best.len && end === best.end && (!hit.exact || best.exact)) continue;
      }
      best = { len, end, exact: hit.exact, cat: hit.cat };
    }
  }
  const modifier = toks.map((t) => tax.modifiers[t]).find(Boolean);
  if (best) {
    if (modifier && OVERRIDABLE.has(best.cat)) return { category: modifier, source: 'dictionary' };
    return { category: best.cat, source: 'dictionary' };
  }
  if (modifier) return { category: modifier, source: 'dictionary' };
  return { category: 'other', source: 'none' };
}

export function learnKey(name: string): string { return tokens(name).join(' '); }

// ---- merging -------------------------------------------------------------

export function mergeKey(name: string): string {
  return tokens(name).map((t) => singularVariants(t)[0] ?? t).join(' ');
}

export interface ExistingItem { name: string; quantity: number | null; unit: string | null; checked: boolean }
export interface MergeDecision { action: 'merge' | 'uncheck' | 'new'; targetIndex: number | null; quantity: number | null; unit: string | null }

export function decideMerge(p: ParsedGrocery, items: ExistingItem[]): MergeDecision {
  const key = mergeKey(p.name);
  const matches = items.map((it, i) => ({ it, i })).filter(({ it }) => mergeKey(it.name) === key);
  const same = matches.find(({ it }) => !it.checked && (it.unit ?? null) === (p.unit ?? null));
  if (same) return { action: 'merge', targetIndex: same.i, quantity: (same.it.quantity ?? 1) + (p.quantity ?? 1), unit: p.unit };
  if (matches.some(({ it }) => !it.checked)) return { action: 'new', targetIndex: null, quantity: p.quantity, unit: p.unit };
  const checked = matches.find(({ it }) => it.checked);
  if (checked) return { action: 'uncheck', targetIndex: checked.i, quantity: p.quantity, unit: p.unit };
  return { action: 'new', targetIndex: null, quantity: p.quantity, unit: p.unit };
}
