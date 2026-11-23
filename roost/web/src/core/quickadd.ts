// Natural-language quick add (mirror of RoostKit/QuickAdd.swift). Spec: shared/README.md §4.
import { LocalDate, LocalDateTime } from './localdate';
import { DAY_CODES } from './recurrence';

export type QuickAddMode = 'event' | 'task';

export interface QuickAddResult {
  title: string;
  date: LocalDate | null;
  timeMinutes: number | null;
  endDate: LocalDate | null;
  endTimeMinutes: number | null;
  allDay: boolean;
  rrule: string | null;
  mentions: string[];
  driver: string | null;
  tag: string | null;
  priority: number;
  reminders: number[];
}

const WD = String.raw`(?:mon(?:day)?|tue(?:s(?:day)?)?|wed(?:s|nesday)?|thu(?:r(?:s(?:day)?)?)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)s?`;
const MONTH = String.raw`(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)`;
const ORD = String.raw`(?:1st|2nd|3rd|4th|first|second|third|fourth|last)`;
const MER = String.raw`(am|pm|a\.m\.|p\.m\.)`;
const SEP = String.raw`\s*(?:,\s*and|,|and|&|/)\s*`;
const PRE = String.raw`(?:\b(?:due|on|by)\s+)?`;
const re = (p: string) => new RegExp(p, 'i');

const R = {
  driver: re(String.raw`\bdriver:\s*([A-Za-z][\w'-]*)`),
  mention: re(String.raw`(^|\s)@([A-Za-z][\w'-]*)`),
  tag: re(String.raw`(^|\s)#([A-Za-z0-9][\w-]*)`),
  prioWord: re(String.raw`(^|\s)!(high|medium|med|low)\b`),
  prioBang: re(String.raw`(^|\s)(!{1,3})(?=\s|$)`),
  remind: re(String.raw`\bremind(?:\s+me)?\s+(\d+(?:\.\d+)?)\s*(minutes?|mins?|m|hours?|hrs?|hr|h|days?|d|weeks?|wks?|w)\b(?:\s+before)?`),
  recOrdinal: re(String.raw`\bevery\s+(` + ORD + '(?:' + SEP + ORD + String.raw`)*)\s+(` + WD + String.raw`)\b`),
  recWeekdays: re(String.raw`\bevery\s+(other\s+)?(` + WD + '(?:' + SEP + WD + String.raw`)*)\b`),
  recOtherDay: re(String.raw`\bevery\s+other\s+day\b`),
  recNDays: re(String.raw`\bevery\s+(\d+)\s+days?\b`),
  recDaily: re(String.raw`\b(?:daily|every\s+day)\b`),
  recWeekday: re(String.raw`\b(?:every\s+weekday|weekdays)\b`),
  recWeekend: re(String.raw`\b(?:every\s+weekend|weekends)\b`),
  recOtherWeek: re(String.raw`\b(?:every\s+other\s+week|biweekly)\b`),
  recNWeeks: re(String.raw`\bevery\s+(\d+)\s+weeks?\b`),
  recWeekly: re(String.raw`\b(?:weekly|every\s+week)\b`),
  recNMonths: re(String.raw`\bevery\s+(\d+)\s+months?\b`),
  recMonthly: re(String.raw`\b(?:monthly|every\s+month)\b`),
  recYearly: re(String.raw`\b(?:yearly|annually|every\s+year)\b`),
  dISO: re(PRE + String.raw`\b(\d{4})-(\d{1,2})-(\d{1,2})\b`),
  dNumeric: re(PRE + String.raw`\b(\d{1,2})/(\d{1,2})(?:/(\d{4}|\d{2}))?\b`),
  dMonthDay: re(PRE + String.raw`\b` + MONTH + String.raw`\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b`),
  dDayMonth: re(PRE + String.raw`\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?` + MONTH + String.raw`\b(?:,?\s+(\d{4}))?`),
  dToday: re(String.raw`\b(?:due\s+)?today\b`),
  dTonight: re(String.raw`\btonight\b`),
  dTomorrow: re(String.raw`\b(?:due\s+)?(?:tomorrow|tmrw|tmw)\b`),
  dWeekend: re(String.raw`\bthis\s+weekend\b`),
  dNextWeek: re(String.raw`\bnext\s+week\b`),
  dIn: re(String.raw`\bin\s+(\d+)\s+(days?|weeks?)\b`),
  dNextWD: re(String.raw`\b(?:due\s+)?next\s+(` + WD + String.raw`)\b`),
  dWD: re(String.raw`\b(?:(?:due|on|this)\s+)?(` + WD + String.raw`)\b`),
  tRange: re(String.raw`(?:\bfrom\s+)?\b(\d{1,2})(?::(\d{2}))?\s*` + MER + String.raw`?\s*(?:-|–|—|to|until|till)\s*(\d{1,2})(?::(\d{2}))?\s*` + MER + String.raw`(?!\w)`),
  tRange24: re(String.raw`(?:\bfrom\s+)?\b([01]?\d|2[0-3]):([0-5]\d)\s*(?:-|–|—|to|until|till)\s*([01]?\d|2[0-3]):([0-5]\d)\b`),
  tNoon: re(String.raw`\b(noon|midnight)\b`),
  tMer: re(String.raw`\b(\d{1,2})(?::(\d{2}))?\s*` + MER + String.raw`(?!\w)`),
  tColon: re(String.raw`(\bat\s+)?\b(\d{1,2}):(\d{2})\b`),
  tAt: re(String.raw`\bat\s+(\d{1,2})\b(?!\s*(?::|am|pm|a\.m|p\.m))`),
  duration: re(String.raw`\bfor\s+(\d+(?:\.\d+)?)\s*(hours?|hrs?|hr|h|minutes?|mins?|min|m)\b`),
};

const CONNECTORS = new Set(['at', 'on', 'from', 'by', 'due', 'for', 'in', 'every', 'the']);

class Work {
  constructor(public s: string) {}
  take(r: RegExp): (string | undefined)[] | null {
    const m = r.exec(this.s);
    if (!m) return null;
    this.s = this.s.slice(0, m.index) + ' ' + this.s.slice(m.index + m[0].length);
    return Array.from(m);
  }
  takeAll(r: RegExp): (string | undefined)[][] {
    const out: (string | undefined)[][] = [];
    for (let g = this.take(r); g; g = this.take(r)) out.push(g);
    return out;
  }
}

const weekdayIndex = (s: string) => ({ su: 0, mo: 1, tu: 2, we: 3, th: 4, fr: 5, sa: 6 } as Record<string, number>)[s.toLowerCase().slice(0, 2)] ?? 1;
const monthIndex = (s: string) => ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'].indexOf(s.toLowerCase().slice(0, 3)) + 1;
const ordinalValue = (s: string) => ({ '1st': 1, first: 1, '2nd': 2, second: 2, '3rd': 3, third: 3, '4th': 4, fourth: 4 } as Record<string, number>)[s.toLowerCase()] ?? -1;

function minutes(n: number, unit: string): number {
  const u = unit.toLowerCase();
  if (u.startsWith('w')) return Math.trunc(n * 10080);
  if (u.startsWith('d')) return Math.trunc(n * 1440);
  if (u.startsWith('h')) return Math.trunc(n * 60);
  return Math.trunc(n);
}
function to24(h: number, mer?: string): number {
  if (!mer) return h;
  if (mer.toLowerCase().startsWith('a')) return h === 12 ? 0 : h;
  return h === 12 ? 12 : h + 12;
}
const bareHour = (h: number) => (h >= 1 && h <= 7 ? h + 12 : h);
const weekStart = (d: LocalDate) => d.addDays(-((d.weekday + 6) % 7));
const onOrAfter = (today: LocalDate, wd: number) => today.addDays((wd - today.weekday + 7) % 7);
const strictlyAfter = (today: LocalDate, wd: number) => { const n = (wd - today.weekday + 7) % 7; return today.addDays(n === 0 ? 7 : n); };

export function parseQuickAdd(text: string, now: LocalDateTime, mode: QuickAddMode): QuickAddResult {
  const r: QuickAddResult = {
    title: '', date: null, timeMinutes: null, endDate: null, endTimeMinutes: null, allDay: true, rrule: null,
    mentions: [], driver: null, tag: null, priority: 0, reminders: [],
  };
  const w = new Work(' ' + text + ' ');
  const today = now.date;

  const dg = w.take(R.driver);
  if (dg) r.driver = dg[1] ?? null;
  r.mentions = w.takeAll(R.mention).map((g) => g[2]!).filter(Boolean);
  const tags = w.takeAll(R.tag).map((g) => g[2]!).filter(Boolean);
  r.tag = tags.length ? tags[0].replace(/_/g, ' ') : null;
  const pw = w.take(R.prioWord);
  if (pw) r.priority = ({ high: 3, medium: 2, med: 2, low: 1 } as Record<string, number>)[pw[2]!.toLowerCase()] ?? 0;
  else { const pb = w.take(R.prioBang); if (pb) r.priority = pb[2]!.length; }
  r.reminders = w.takeAll(R.remind).map((g) => minutes(Number(g[1]), g[2]!));

  // Recurrence.
  let byDays: number[] = [];
  let ordinals: [number, number][] = [];
  let g: (string | undefined)[] | null;
  if ((g = w.take(R.recOrdinal))) {
    const wd = weekdayIndex(g[2]!);
    const ords = g[1]!.split(/[,&]/).flatMap((x) => x.split(' and ')).map((x) => x.trim()).filter(Boolean);
    ordinals = ords.map((o) => [ordinalValue(o), wd]);
    r.rrule = 'FREQ=MONTHLY;BYDAY=' + ordinals.map(([o, d]) => `${o}${DAY_CODES[d]}`).join(',');
  } else if ((g = w.take(R.recWeekdays))) {
    const names = [...g[2]!.matchAll(new RegExp(WD, 'gi'))].map((m) => m[0]);
    byDays = [...new Set(names.map(weekdayIndex))].sort((a, b) => ((a + 6) % 7) - ((b + 6) % 7));
    r.rrule = 'FREQ=WEEKLY;' + (g[1] ? 'INTERVAL=2;' : '') + 'BYDAY=' + byDays.map((d) => DAY_CODES[d]).join(',');
  } else if (w.take(R.recOtherDay)) r.rrule = 'FREQ=DAILY;INTERVAL=2';
  else if ((g = w.take(R.recNDays))) r.rrule = `FREQ=DAILY;INTERVAL=${g[1]}`;
  else if (w.take(R.recDaily)) r.rrule = 'FREQ=DAILY';
  else if (w.take(R.recWeekday)) { byDays = [1, 2, 3, 4, 5]; r.rrule = 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR'; }
  else if (w.take(R.recWeekend)) { byDays = [6, 0]; r.rrule = 'FREQ=WEEKLY;BYDAY=SA,SU'; }
  else if (w.take(R.recOtherWeek)) r.rrule = 'FREQ=WEEKLY;INTERVAL=2';
  else if ((g = w.take(R.recNWeeks))) r.rrule = `FREQ=WEEKLY;INTERVAL=${g[1]}`;
  else if (w.take(R.recWeekly)) r.rrule = 'FREQ=WEEKLY';
  else if ((g = w.take(R.recNMonths))) r.rrule = `FREQ=MONTHLY;INTERVAL=${g[1]}`;
  else if (w.take(R.recMonthly)) r.rrule = 'FREQ=MONTHLY';
  else if (w.take(R.recYearly)) r.rrule = 'FREQ=YEARLY';

  // Dates.
  let tonight = false;
  const rollYear = (m: number, d: number, y?: string): LocalDate | null => {
    if (y) {
      let yy = Number(y);
      if (yy < 100) yy += 2000;
      return LocalDate.valid(yy, m, d) ? new LocalDate(yy, m, d) : null;
    }
    if (!LocalDate.valid(today.year, m, d)) return null;
    const c = new LocalDate(today.year, m, d);
    if (c.compare(today) < 0) return LocalDate.valid(today.year + 1, m, d) ? new LocalDate(today.year + 1, m, d) : null;
    return c;
  };
  if ((g = w.take(R.dISO))) {
    const [y, m, d] = [Number(g[1]), Number(g[2]), Number(g[3])];
    r.date = LocalDate.valid(y, m, d) ? new LocalDate(y, m, d) : null;
  } else if ((g = w.take(R.dNumeric))) r.date = rollYear(Number(g[1]), Number(g[2]), g[3]);
  else if ((g = w.take(R.dMonthDay))) r.date = rollYear(monthIndex(g[1]!), Number(g[2]), g[3]);
  else if ((g = w.take(R.dDayMonth))) r.date = rollYear(monthIndex(g[2]!), Number(g[1]), g[3]);
  else if (w.take(R.dToday)) r.date = today;
  else if (w.take(R.dTonight)) { r.date = today; tonight = true; }
  else if (w.take(R.dTomorrow)) r.date = today.addDays(1);
  else if (w.take(R.dWeekend)) r.date = today.weekday === 6 ? today : onOrAfter(today, 6);
  else if (w.take(R.dNextWeek)) r.date = weekStart(today).addDays(7);
  else if ((g = w.take(R.dIn))) { const n = Number(g[1]); r.date = today.addDays(g[2]!.toLowerCase().startsWith('w') ? n * 7 : n); }
  else if ((g = w.take(R.dNextWD))) {
    let d = strictlyAfter(today, weekdayIndex(g[1]!));
    if (weekStart(d).equals(weekStart(today))) d = d.addDays(7);
    r.date = d;
  } else if ((g = w.take(R.dWD))) r.date = onOrAfter(today, weekdayIndex(g[1]!));

  // Times.
  let start: number | null = null;
  let end: number | null = null;
  if ((g = w.take(R.tRange))) {
    const em = to24(Number(g[4]), g[6]) * 60 + Number(g[5] ?? 0);
    let sh = Number(g[1]);
    const smin = Number(g[2] ?? 0);
    if (g[3]) sh = to24(sh, g[3]);
    else {
      sh = to24(sh, g[6]);
      if (sh * 60 + smin > em) sh = to24(Number(g[1]), 'am');
    }
    start = sh * 60 + smin;
    end = em;
  } else if ((g = w.take(R.tRange24))) {
    start = Number(g[1]) * 60 + Number(g[2]);
    end = Number(g[3]) * 60 + Number(g[4]);
  } else if ((g = w.take(R.tNoon))) start = g[1]!.toLowerCase() === 'noon' ? 720 : 0;
  else if ((g = w.take(R.tMer))) start = to24(Number(g[1]), g[3]) * 60 + Number(g[2] ?? 0);
  else if ((g = w.take(R.tColon))) {
    let h = Number(g[2]);
    if (g[1]) h = bareHour(h);
    start = h * 60 + Number(g[3]);
  } else if ((g = w.take(R.tAt))) start = bareHour(Number(g[1])) * 60;
  const dur = w.take(R.duration);
  if (dur && start !== null) end = start + minutes(Number(dur[1]), dur[2]!);
  if (start === null && tonight) start = 18 * 60;
  if (start !== null && start >= 1440) start = null;

  if (!r.date) {
    if (ordinals.length) {
      let d = today;
      for (let i = 0; i < 400; i++) {
        const n = LocalDate.daysInMonth(d.year, d.month);
        if (ordinals.some(([o, wd]) => d.weekday === wd && (o > 0 ? Math.floor((d.day - 1) / 7) + 1 === o : d.day + 7 > n))) break;
        d = d.addDays(1);
      }
      r.date = d;
    } else if (byDays.length) {
      for (let i = 0; i < 7; i++) { const d = today.addDays(i); if (byDays.includes(d.weekday)) { r.date = d; break; } }
    } else if (mode === 'event' || r.rrule || start !== null) r.date = today;
  }

  if (start !== null && r.date) {
    r.timeMinutes = start;
    r.allDay = false;
    if (mode === 'event') {
      let e = end ?? start + 60;
      let ed = r.date;
      if (e <= start && end !== null) e += 1440;
      while (e >= 1440) { e -= 1440; ed = ed.addDays(1); }
      r.endDate = ed;
      r.endTimeMinutes = e;
    }
  }

  // Title.
  const clean = (x: string) => x.replace(/^[,;:\-–—]+|[,;:\-–—]+$/g, '');
  const words = w.s.split(/\s+/).filter(Boolean);
  while (words.length && (CONNECTORS.has(clean(words[0]).toLowerCase()) || !clean(words[0]))) words.shift();
  while (words.length && (CONNECTORS.has(clean(words[words.length - 1]).toLowerCase()) || !clean(words[words.length - 1]))) words.pop();
  let title = words.join(' ').replace(/^[\s,;:\-–—]+|[\s,;:\-–—]+$/g, '');
  if (title) title = title[0].toUpperCase() + title.slice(1);
  r.title = title;
  return r;
}

/** Start as a wall-clock date-time (midnight for all-day). */
export function qaStart(r: QuickAddResult): LocalDateTime | null {
  return r.date ? new LocalDateTime(r.date, Math.floor((r.timeMinutes ?? 0) / 60), (r.timeMinutes ?? 0) % 60) : null;
}
export function qaEnd(r: QuickAddResult): LocalDateTime | null {
  return r.endDate && r.endTimeMinutes !== null ? new LocalDateTime(r.endDate, Math.floor(r.endTimeMinutes / 60), r.endTimeMinutes % 60) : null;
}
