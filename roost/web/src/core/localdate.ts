// Wall-clock dates with pure integer arithmetic (mirror of RoostKit/LocalDate.swift).

export class LocalDate {
  constructor(public readonly year: number, public readonly month: number, public readonly day: number) {}

  /** Days since 1970-01-01 (Howard Hinnant's algorithm). */
  get dayNumber(): number {
    const y = this.month <= 2 ? this.year - 1 : this.year;
    const era = Math.floor((y >= 0 ? y : y - 399) / 400);
    const yoe = y - era * 400;
    const mp = (this.month + 9) % 12;
    const doy = Math.floor((153 * mp + 2) / 5) + this.day - 1;
    const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
    return era * 146097 + doe - 719468;
  }

  static fromDayNumber(z0: number): LocalDate {
    const z = z0 + 719468;
    const era = Math.floor((z >= 0 ? z : z - 146096) / 146097);
    const doe = z - era * 146097;
    const yoe = Math.floor((doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365);
    const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
    const mp = Math.floor((5 * doy + 2) / 153);
    const d = doy - Math.floor((153 * mp + 2) / 5) + 1;
    const m = mp < 10 ? mp + 3 : mp - 9;
    return new LocalDate(yoe + era * 400 + (m <= 2 ? 1 : 0), m, d);
  }

  /** 0 = Sunday … 6 = Saturday. */
  get weekday(): number { return (((this.dayNumber % 7) + 11) % 7); }

  addDays(n: number): LocalDate { return LocalDate.fromDayNumber(this.dayNumber + n); }

  addMonths(n: number): { year: number; month: number } {
    const total = this.year * 12 + (this.month - 1) + n;
    return { year: Math.floor(total / 12), month: (((total % 12) + 12) % 12) + 1 };
  }

  static daysInMonth(y: number, m: number): number {
    if (m === 2) return LocalDate.isLeap(y) ? 29 : 28;
    return [4, 6, 9, 11].includes(m) ? 30 : 31;
  }
  static isLeap(y: number): boolean { return (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0; }
  static valid(y: number, m: number, d: number): boolean { return m >= 1 && m <= 12 && d >= 1 && d <= LocalDate.daysInMonth(y, m); }

  compare(o: LocalDate): number { return this.dayNumber - o.dayNumber; }
  equals(o: LocalDate | null | undefined): boolean { return !!o && this.dayNumber === o.dayNumber; }

  toString(): string { return `${pad(this.year, 4)}-${pad(this.month)}-${pad(this.day)}`; }

  static parse(iso: string): LocalDate | null {
    const p = iso.slice(0, 10).split('-').map(Number);
    if (p.length !== 3 || p.some(Number.isNaN) || !LocalDate.valid(p[0], p[1], p[2])) return null;
    return new LocalDate(p[0], p[1], p[2]);
  }
}

export class LocalDateTime {
  constructor(public readonly date: LocalDate, public readonly hour = 0, public readonly minute = 0) {}

  get minuteNumber(): number { return this.date.dayNumber * 1440 + this.hour * 60 + this.minute; }
  static fromMinuteNumber(n: number): LocalDateTime {
    const day = Math.floor(n / 1440);
    const rem = n - day * 1440;
    return new LocalDateTime(LocalDate.fromDayNumber(day), Math.floor(rem / 60), rem % 60);
  }
  addMinutes(n: number): LocalDateTime { return LocalDateTime.fromMinuteNumber(this.minuteNumber + n); }
  compare(o: LocalDateTime): number { return this.minuteNumber - o.minuteNumber; }

  toString(): string { return `${this.date.toString()}T${pad(this.hour)}:${pad(this.minute)}`; }
  get timeString(): string { return `${pad(this.hour)}:${pad(this.minute)}`; }
  key(allDay: boolean): string { return allDay ? this.date.toString() : this.toString(); }

  static parse(iso: string): LocalDateTime | null {
    const d = LocalDate.parse(iso);
    if (!d) return null;
    if (iso.length >= 16) {
      const [h, m] = iso.slice(11, 16).split(':').map(Number);
      if (Number.isNaN(h) || Number.isNaN(m)) return null;
      return new LocalDateTime(d, h, m);
    }
    return new LocalDateTime(d);
  }

  /** Instant for this wall time in `tz`. */
  toDate(tz: string): Date {
    const guess = Date.UTC(this.date.year, this.date.month - 1, this.date.day, this.hour, this.minute);
    const off1 = tzOffsetMinutes(guess, tz);
    let t = guess - off1 * 60000;
    const off2 = tzOffsetMinutes(t, tz);
    if (off2 !== off1) t = guess - off2 * 60000;
    return new Date(t);
  }

  static fromDate(d: Date, tz: string): LocalDateTime {
    const p = zonedParts(d.getTime(), tz);
    return new LocalDateTime(new LocalDate(p.y, p.m, p.d), p.h, p.mi);
  }
}

export function pad(n: number, w = 2): string { return String(n).padStart(w, '0'); }

const fmtCache = new Map<string, Intl.DateTimeFormat>();
function formatter(tz: string): Intl.DateTimeFormat {
  let f = fmtCache.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat('en-US', {
      timeZone: tz, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric',
    });
    fmtCache.set(tz, f);
  }
  return f;
}

function zonedParts(ms: number, tz: string) {
  const out: Record<string, number> = {};
  for (const p of formatter(tz).formatToParts(new Date(ms))) if (p.type !== 'literal') out[p.type] = Number(p.value);
  return { y: out.year, m: out.month, d: out.day, h: out.hour === 24 ? 0 : out.hour, mi: out.minute, s: out.second };
}

/** Offset of `tz` from UTC at instant `ms`, in minutes (local − UTC). */
export function tzOffsetMinutes(ms: number, tz: string): number {
  const p = zonedParts(ms, tz);
  const asUTC = Date.UTC(p.y, p.m - 1, p.d, p.h, p.mi, p.s);
  return Math.round((asUTC - Math.floor(ms / 1000) * 1000) / 60000);
}

export function localTZ(): string { return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'; }

export function validTZ(tz: string | undefined | null): string {
  if (!tz) return localTZ();
  try { formatter(tz); return tz; } catch { return localTZ(); }
}
