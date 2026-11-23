import { useSyncExternalStore } from 'react';
import { LocalDateTime, localTZ } from '../core/localdate';
import type { TaskRec } from '../data/models';
import { colorFor, expandEvents, familyTZ, membersOf, type Occurrence, type State } from '../data/store';
import { startOfDay } from './format';

export interface Prefs { hidden: string[]; people: string[]; showBusy: boolean; showTasks: boolean; byPerson: boolean }
const KEY = 'roost.calprefs';
let prefs: Prefs = { hidden: [], people: [], showBusy: true, showTasks: true, byPerson: true };
try { prefs = { ...prefs, ...JSON.parse(localStorage.getItem(KEY) ?? '{}') }; } catch { /* defaults */ }
const subs = new Set<() => void>();
export function setPrefs(p: Partial<Prefs>) {
  prefs = { ...prefs, ...p };
  try { localStorage.setItem(KEY, JSON.stringify(prefs)); } catch { /* ignore */ }
  subs.forEach((s) => s());
}
export function usePrefs(): Prefs {
  return useSyncExternalStore((cb) => { subs.add(cb); return () => subs.delete(cb); }, () => prefs);
}

export interface CalItem {
  id: string; title: string; start: Date; end: Date; allDay: boolean; color: string;
  occ?: Occurrence; task?: TaskRec; memberIds: string[]; busy: boolean; location: string; driver: string; recurring: boolean;
}

export function buildItems(s: State, p: Prefs, from: Date, to: Date): CalItem[] {
  const hidden = new Set(p.hidden);
  const people = new Set(p.people);
  // Nothing from removed calendars or lists, even if their items haven't been cleaned up yet.
  const liveCals = new Set(s.calendars.filter((c) => !c.deleted).map((c) => c.id));
  const liveLists = new Set(s.lists.filter((l) => !l.deleted).map((l) => l.id));
  let src = s.events.filter((e) => !e.deleted && !hidden.has(e.calendar) && liveCals.has(e.calendar));
  if (p.showBusy) src = src.concat(s.busy.filter((e) => !hidden.has(e.calendar)));
  if (people.size) src = src.filter((e) => e.members.some((m) => people.has(m)) || (e.driver && people.has(e.driver)));
  const out: CalItem[] = expandEvents(src, from, to).map((o) => {
    const e = o.event;
    let title = e.title;
    if (e.busy) {
      const who = membersOf(e.members, s).map((m) => m.name).join(', ');
      title = who ? `${who} busy` : 'Busy';
    }
    return { id: o.id, title, start: o.start, end: o.end, allDay: e.allDay, color: colorFor(e, p.byPerson, s), occ: o, memberIds: e.members,
      busy: !!e.busy, location: e.location, driver: e.driver, recurring: !!e.rrule };
  });
  if (p.showTasks) {
    for (const t of s.tasks) {
      if (t.deleted || t.completed || !t.due || !liveLists.has(t.list)) continue;
      if (people.size && !t.assignees.some((a) => people.has(a))) continue;
      const d = LocalDateTime.parse(t.due);
      if (!d) continue;
      const timed = t.due.length > 10;
      // Due times are in the family's time zone; due dates are floating.
      const start = timed ? d.toDate(familyTZ()) : startOfDay(d.toDate(localTZ()));
      const end = timed ? new Date(start.getTime() + 1800000) : new Date(start.getTime() + 86400000);
      if (start >= to || end <= from) continue;
      const m = membersOf(t.assignees, s)[0];
      out.push({ id: `task|${t.id}`, title: t.title, start, end, allDay: !timed, color: m?.color ?? 'brown', task: t, memberIds: t.assignees,
        busy: false, location: '', driver: '', recurring: !!t.rrule });
    }
  }
  return out.sort((a, b) => (a.allDay !== b.allDay ? (a.allDay ? -1 : 1) : a.start.getTime() - b.start.getTime() || a.title.localeCompare(b.title)));
}
