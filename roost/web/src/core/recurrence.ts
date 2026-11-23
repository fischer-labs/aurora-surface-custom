// RFC 5545 RRULE subset + expansion (mirror of RoostKit/Recurrence.swift).
import { LocalDate, LocalDateTime } from './localdate';

export type Freq = 'DAILY' | 'WEEKLY' | 'MONTHLY' | 'YEARLY';
export type Until = { kind: 'date'; date: LocalDate } | { kind: 'local'; dt: LocalDateTime } | { kind: 'utc'; at: Date };
export interface WeekdayNum { weekday: number; ordinal?: number }

export const DAY_CODES = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];
export const MAX_ITERATIONS = 50_000;

export class RRule {
  interval = 1;
  count?: number;
  until?: Until;
  byDay: WeekdayNum[] = [];
  byMonthDay: number[] = [];
  byMonth: number[] = [];
  bySetPos: number[] = [];
  wkst = 1;

  constructor(public freq: Freq) {}

  static parse(text: string | null | undefined): RRule | null {
    if (!text) return null;
    let freq: Freq | null = null;
    const r = new RRule('DAILY');
    for (const part of text.replace('RRULE:', '').split(';')) {
      const i = part.indexOf('=');
      if (i < 0) continue;
      const k = part.slice(0, i).toUpperCase();
      const v = part.slice(i + 1).toUpperCase();
      switch (k) {
        case 'FREQ': if (['DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY'].includes(v)) freq = v as Freq; break;
        case 'INTERVAL': r.interval = Math.max(1, parseInt(v) || 1); break;
        case 'COUNT': { const c = parseInt(v); if (!Number.isNaN(c)) r.count = c; break; }
        case 'UNTIL': r.until = RRule.parseUntil(v); break;
        case 'BYDAY':
          r.byDay = v.split(',').flatMap((tok) => {
            if (tok.length < 2) return [];
            const wd = DAY_CODES.indexOf(tok.slice(-2));
            if (wd < 0) return [];
            const ord = tok.length > 2 ? parseInt(tok.slice(0, -2)) : NaN;
            return [{ weekday: wd, ordinal: Number.isNaN(ord) || ord === 0 ? undefined : ord }];
          });
          break;
        case 'BYMONTHDAY': r.byMonthDay = v.split(',').map(Number).filter((n) => Number.isInteger(n) && n !== 0 && Math.abs(n) <= 31); break;
        case 'BYMONTH': r.byMonth = v.split(',').map(Number).filter((n) => n >= 1 && n <= 12); break;
        case 'BYSETPOS': r.bySetPos = v.split(',').map(Number).filter((n) => Number.isInteger(n) && n !== 0); break;
        case 'WKST': { const w = DAY_CODES.indexOf(v); r.wkst = w < 0 ? 1 : w; break; }
      }
    }
    if (!freq) return null;
    r.freq = freq;
    return r;
  }

  static parseUntil(v: string): Until | undefined {
    const digits = v.replace(/\D/g, '');
    if (digits.length < 8) return undefined;
    const date = new LocalDate(+digits.slice(0, 4), +digits.slice(4, 6), +digits.slice(6, 8));
    if (!v.includes('T') || digits.length < 12) return { kind: 'date', date };
    const hh = +digits.slice(8, 10), mm = +digits.slice(10, 12), ss = digits.length >= 14 ? +digits.slice(12, 14) : 0;
    if (v.endsWith('Z')) return { kind: 'utc', at: new Date(Date.UTC(date.year, date.month - 1, date.day, hh, mm, ss)) };
    return { kind: 'local', dt: new LocalDateTime(date, hh, mm) };
  }

  toString(): string {
    const p = [`FREQ=${this.freq}`];
    if (this.interval > 1) p.push(`INTERVAL=${this.interval}`);
    if (this.byMonth.length) p.push(`BYMONTH=${this.byMonth.join(',')}`);
    if (this.byMonthDay.length) p.push(`BYMONTHDAY=${this.byMonthDay.join(',')}`);
    if (this.byDay.length) p.push(`BYDAY=${this.byDay.map((d) => (d.ordinal ?? '') + DAY_CODES[d.weekday]).join(',')}`);
    if (this.bySetPos.length) p.push(`BYSETPOS=${this.bySetPos.join(',')}`);
    if (this.count !== undefined) p.push(`COUNT=${this.count}`);
    if (this.until) {
      const u = this.until;
      const z = (n: number) => String(n).padStart(2, '0');
      if (u.kind === 'date') p.push(`UNTIL=${u.date.year}${z(u.date.month)}${z(u.date.day)}`);
      else if (u.kind === 'local') p.push(`UNTIL=${u.dt.date.year}${z(u.dt.date.month)}${z(u.dt.date.day)}T${z(u.dt.hour)}${z(u.dt.minute)}00`);
      else { const d = u.at; p.push(`UNTIL=${d.getUTCFullYear()}${z(d.getUTCMonth() + 1)}${z(d.getUTCDate())}T${z(d.getUTCHours())}${z(d.getUTCMinutes())}00Z`); }
    }
    return p.join(';');
  }

  private pick(list: LocalDate[], pos: number): LocalDate | undefined {
    const idx = pos > 0 ? pos - 1 : list.length + pos;
    return idx >= 0 && idx < list.length ? list[idx] : undefined;
  }

  private monthDays(y: number, m: number, defaultDay: number): LocalDate[] {
    const n = LocalDate.daysInMonth(y, m);
    let byMD: LocalDate[] | null = null;
    if (this.byMonthDay.length) {
      byMD = this.byMonthDay.map((md) => (md > 0 ? md : n + md + 1)).filter((d) => d >= 1 && d <= n).map((d) => new LocalDate(y, m, d));
    }
    let byD: LocalDate[] | null = null;
    if (this.byDay.length) {
      byD = [];
      for (const wd of this.byDay) {
        const all: LocalDate[] = [];
        for (let d = 1; d <= n; d++) { const ld = new LocalDate(y, m, d); if (ld.weekday === wd.weekday) all.push(ld); }
        if (wd.ordinal !== undefined) { const p = this.pick(all, wd.ordinal); if (p) byD.push(p); } else byD.push(...all);
      }
    }
    if (byMD && byD) return byMD.filter((a) => byD!.some((b) => b.equals(a)));
    if (byMD) return byMD;
    if (byD) return byD;
    return LocalDate.valid(y, m, defaultDay) ? [new LocalDate(y, m, defaultDay)] : [];
  }

  private matchesFilters(d: LocalDate): boolean {
    if (this.byMonth.length && !this.byMonth.includes(d.month)) return false;
    if (this.byMonthDay.length) {
      const n = LocalDate.daysInMonth(d.year, d.month);
      if (!this.byMonthDay.some((md) => (md > 0 ? md : n + md + 1) === d.day)) return false;
    }
    if (this.byDay.length && !this.byDay.some((w) => w.weekday === d.weekday)) return false;
    return true;
  }

  candidates(period: number, start: LocalDateTime): LocalDate[] {
    const s = start.date;
    let out: LocalDate[] = [];
    switch (this.freq) {
      case 'DAILY': {
        const d = s.addDays(period * this.interval);
        if (this.matchesFilters(d)) out = [d];
        break;
      }
      case 'WEEKLY': {
        const offset = (s.weekday - this.wkst + 7) % 7;
        const weekStart = s.addDays(-offset + period * this.interval * 7);
        const days = this.byDay.length ? this.byDay.map((b) => b.weekday) : [s.weekday];
        for (let i = 0; i < 7; i++) {
          const d = weekStart.addDays(i);
          if (days.includes(d.weekday) && (!this.byMonth.length || this.byMonth.includes(d.month))) out.push(d);
        }
        break;
      }
      case 'MONTHLY': {
        const ym = s.addMonths(period * this.interval);
        if (this.byMonth.length && !this.byMonth.includes(ym.month)) break;
        out = this.monthDays(ym.year, ym.month, s.day);
        break;
      }
      case 'YEARLY': {
        const y = s.year + period * this.interval;
        if (this.byDay.some((b) => b.ordinal !== undefined) && !this.byMonth.length && !this.byMonthDay.length) {
          for (const wd of this.byDay) {
            const all: LocalDate[] = [];
            for (let m = 1; m <= 12; m++) for (let d = 1; d <= LocalDate.daysInMonth(y, m); d++) { const ld = new LocalDate(y, m, d); if (ld.weekday === wd.weekday) all.push(ld); }
            if (wd.ordinal !== undefined) { const p = this.pick(all, wd.ordinal); if (p) out.push(p); } else out.push(...all);
          }
        } else {
          const months = this.byMonth.length ? this.byMonth : [s.month];
          for (const m of months) {
            if (!this.byMonthDay.length && !this.byDay.length) {
              if (LocalDate.valid(y, m, s.day)) out.push(new LocalDate(y, m, s.day));
            } else out.push(...this.monthDays(y, m, s.day));
          }
        }
        break;
      }
    }
    out = uniqSorted(out);
    if (this.bySetPos.length && out.length) {
      const picked: LocalDate[] = [];
      for (const p of this.bySetPos) { const d = this.pick(out, p); if (d) picked.push(d); }
      out = uniqSorted(picked);
    }
    return out;
  }

  periodsBetween(a: LocalDate, b: LocalDate): number {
    switch (this.freq) {
      case 'DAILY': return Math.trunc((b.dayNumber - a.dayNumber) / this.interval);
      case 'WEEKLY': return Math.trunc((b.dayNumber - a.dayNumber) / (7 * this.interval));
      case 'MONTHLY': return Math.trunc(((b.year - a.year) * 12 + (b.month - a.month)) / this.interval);
      case 'YEARLY': return Math.trunc((b.year - a.year) / this.interval);
    }
  }
}

function uniqSorted(list: LocalDate[]): LocalDate[] {
  const seen = new Map<number, LocalDate>();
  for (const d of list) seen.set(d.dayNumber, d);
  return [...seen.values()].sort((a, b) => a.dayNumber - b.dayNumber);
}

/** Walks occurrences in order; DTSTART counts first (RFC 5545). `body` returns false to stop. */
export function iterate(start: LocalDateTime, rule: RRule, fromPeriod: number, tz: string, body: (c: LocalDateTime) => boolean): void {
  let emitted = 0;
  const pastUntil = (c: LocalDateTime): boolean => {
    const u = rule.until;
    if (!u) return false;
    if (u.kind === 'date') return c.date.compare(u.date) > 0;
    if (u.kind === 'local') return c.compare(u.dt) > 0;
    return c.toDate(tz).getTime() > u.at.getTime();
  };
  if (fromPeriod === 0 && !rule.candidates(0, start).some((d) => d.equals(start.date))) {
    emitted++;
    if (!body(start)) return;
  }
  let period = fromPeriod;
  for (let it = 0; it < MAX_ITERATIONS; it++) {
    for (const d of rule.candidates(period, start)) {
      const c = new LocalDateTime(d, start.hour, start.minute);
      if (c.compare(start) < 0) continue;
      if (pastUntil(c)) return;
      if (rule.count !== undefined && emitted >= rule.count) return;
      emitted++;
      if (!body(c)) return;
    }
    period++;
  }
}

/** Wall-clock starts (in tz) of occurrences overlapping [rangeStart, rangeEnd). */
export function expand(opts: {
  start: LocalDateTime; durationMinutes: number; allDay: boolean; tz: string; rrule?: string | null;
  exdates: Set<string>; rangeStart: Date; rangeEnd: Date;
}): LocalDateTime[] {
  const { durationMinutes, allDay, tz, exdates, rangeStart, rangeEnd } = opts;
  const rs = rangeStart.getTime(), re = rangeEnd.getTime();
  const overlaps = (s: LocalDateTime): boolean => {
    const sd = s.toDate(tz).getTime();
    const ed = allDay ? s.addMinutes(Math.max(durationMinutes, 1440)).toDate(tz).getTime() : sd + durationMinutes * 60000;
    if (ed === sd) return rs <= sd && sd < re;
    return sd < re && ed > rs;
  };
  const start = allDay ? new LocalDateTime(opts.start.date) : opts.start;
  const rule = RRule.parse(opts.rrule ?? '');
  if (!rule) return overlaps(start) && !exdates.has(start.key(allDay)) ? [start] : [];
  const endLocal = LocalDateTime.fromDate(rangeEnd, tz).addMinutes(1440);
  let startPeriod = 0;
  if (rule.count === undefined) {
    const earliest = LocalDateTime.fromDate(rangeStart, tz).addMinutes(-Math.max(durationMinutes, 1440) - 1440).date;
    if (earliest.compare(start.date) > 0) startPeriod = Math.max(0, rule.periodsBetween(start.date, earliest) - 1);
  }
  const out: LocalDateTime[] = [];
  iterate(start, rule, startPeriod, tz, (c) => {
    if (c.compare(endLocal) > 0) return false;
    if (!exdates.has(c.key(allDay)) && overlaps(c)) out.push(c);
    return true;
  });
  return out;
}
