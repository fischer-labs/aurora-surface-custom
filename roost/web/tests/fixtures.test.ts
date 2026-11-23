// Runs the cross-platform acceptance fixtures (roost/shared/fixtures) against the TS core.
import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { LocalDate, LocalDateTime } from '../src/core/localdate';
import { expand, RRule } from '../src/core/recurrence';
import { categorize, decideMerge, mergeKey, parseGroceryLine, taxonomy } from '../src/core/grocery';
import { parseQuickAdd } from '../src/core/quickadd';
import { effectiveLevel, layoutDay, nextDue, type Role } from '../src/core/logic';

const fx = (name: string) => JSON.parse(readFileSync(fileURLToPath(new URL(`../../shared/fixtures/${name}.json`, import.meta.url)), 'utf8'));
const hm = (m: number | null) => (m === null ? null : `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`);

describe('taxonomy', () => {
  it('loads the shared dictionary', () => {
    expect(taxonomy.categories).toHaveLength(20);
    expect(taxonomy.index.size).toBeGreaterThan(2000);
  });
});

describe('grocery parse', () => {
  for (const c of fx('grocery').parse) {
    it(c.input, () => {
      const p = parseGroceryLine(c.input)!;
      expect(p.name).toBe(c.name);
      expect(p.quantity).toBe(c.quantity);
      expect(p.unit).toBe(c.unit);
      expect(categorize(p.name).category).toBe(c.category);
    });
  }
});

describe('grocery categorize', () => {
  const g = fx('grocery');
  for (const c of g.categorize) {
    it(c.input, () => expect(categorize(c.input)).toEqual({ category: c.category, source: c.source }));
  }
  for (const c of g.learned) {
    it(`learned: ${c.input}`, () => expect(categorize(c.input, new Map(Object.entries(c.learned)))).toEqual({ category: c.category, source: c.source }));
  }
  for (const c of g.mergeKey) it(`mergeKey ${c.a}/${c.b}`, () => expect(mergeKey(c.a) === mergeKey(c.b)).toBe(c.same));
  for (const c of g.merge) {
    it(`merge ${c.add}`, () => {
      const d = decideMerge(parseGroceryLine(c.add)!, [c.existing]);
      expect([d.action, d.quantity, d.unit]).toEqual([c.action, c.quantity, c.unit]);
    });
  }
});

describe('quick add', () => {
  const q = fx('quickadd');
  const now = LocalDateTime.parse(q.now)!;
  for (const c of q.cases) {
    it(c.text, () => {
      const r = parseQuickAdd(c.text, now, c.mode);
      expect({
        title: r.title, date: r.date?.toString() ?? null, time: hm(r.timeMinutes), endDate: r.endDate?.toString() ?? null,
        endTime: hm(r.endTimeMinutes), allDay: r.allDay, rrule: r.rrule, mentions: r.mentions, driver: r.driver, tag: r.tag,
        priority: r.priority, reminders: r.reminders,
      }).toEqual(c.expect);
    });
  }
});

describe('recurrence', () => {
  for (const c of fx('recurrence').cases) {
    it(c.name, () => {
      const start = LocalDateTime.parse(c.start)!, end = LocalDateTime.parse(c.end)!;
      const dur = c.allDay ? (end.date.dayNumber - start.date.dayNumber) * 1440 : (end.toDate(c.tz).getTime() - start.toDate(c.tz).getTime()) / 60000;
      const occ = expand({
        start, durationMinutes: dur, allDay: c.allDay, tz: c.tz, rrule: c.rrule, exdates: new Set(c.exdates),
        rangeStart: LocalDateTime.parse(c.rangeStart)!.toDate(c.tz), rangeEnd: LocalDateTime.parse(c.rangeEnd)!.toDate(c.tz),
      });
      expect(occ.map((o) => o.key(c.allDay))).toEqual(c.expected);
      if (c.expectedUtc) expect(occ.map((o) => o.toDate(c.tz).toISOString().replace('.000Z', 'Z'))).toEqual(c.expectedUtc);
    });
  }
  it('round-trips rules', () => {
    for (const s of ['FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR', 'FREQ=MONTHLY;BYDAY=-1FR', 'FREQ=YEARLY;BYMONTH=11;BYDAY=4TH',
      'FREQ=DAILY;COUNT=5', 'FREQ=WEEKLY;BYDAY=TH;UNTIL=20261217', 'FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1']) {
      expect(RRule.parse(s)!.toString()).toBe(s);
    }
    expect(RRule.parse('BYDAY=MO')).toBeNull();
  });
});

describe('layout', () => {
  for (const c of fx('layout').cases) {
    it(c.name, () => {
      const got = layoutDay(c.items);
      for (const [id, [col, cols]] of Object.entries(c.expected as Record<string, [number, number]>)) expect(got[id]).toEqual({ col, cols });
    });
  }
});

describe('access', () => {
  for (const c of fx('access').cases) {
    it(`${c.resource}:${c.subkind} ${c.role}`, () =>
      expect(effectiveLevel(c.resource, c.subkind, c.role as Role, c.membershipId, c.sharing, c.isOwner)).toBe(c.expected));
  }
});

describe('task recurrence', () => {
  for (const c of fx('taskrecurrence').cases) {
    it(c.name, () => expect(nextDue(c.due, c.rrule, LocalDateTime.parse(c.completedAt)!)).toBe(c.expected));
  }
});

describe('date math', () => {
  it('matches known weekdays', () => {
    expect(new LocalDate(1970, 1, 1).weekday).toBe(4);
    expect(new LocalDate(2026, 11, 23).weekday).toBe(1);
    expect(LocalDate.fromDayNumber(new LocalDate(2028, 2, 29).dayNumber).toString()).toBe('2028-02-29');
    expect(LocalDateTime.fromMinuteNumber(-1).toString()).toBe('1969-12-31T23:59');
  });
});
