// Client state: optimistic local writes, persisted outbox, full sync + realtime.
import PocketBase, { ClientResponseError } from 'pocketbase';
import { useSyncExternalStore } from 'react';
import { LocalDate, LocalDateTime, localTZ, validTZ } from '../core/localdate';
import { RRule, expand } from '../core/recurrence';
import { categorize, decideMerge, learnKey, mergeKey, parseGroceryLine, taxonomy, type GroceryCategory } from '../core/grocery';
import { nextDue } from '../core/logic';
import {
  newId, pbDate, toPB,
  type CalendarRec, type CardRec, type EventRec, type Family, type FeedRec, type GroceryRec, type InviteRec,
  type LearnedRec, type ListRec, type Member, type Role, type TaskRec, type UserRec,
} from './models';

declare global {
  interface Window { ROOST_CONFIG?: { apiUrl?: string; basePath?: string } }
}

export const apiBase = (window.ROOST_CONFIG?.apiUrl || import.meta.env.VITE_ROOST_API_URL || window.location.origin).replace(/\/$/, '');
export const pb = new PocketBase(apiBase);
pb.autoCancellation(false);

type Coll = 'calendars' | 'events' | 'lists' | 'tasks' | 'groceryItems' | 'groceryLearned' | 'infoCards' | 'memberships' | 'invites' | 'feeds' | 'families';
interface Op { id: string; coll: Coll; recordId: string; kind: 'create' | 'update' | 'delete'; body: Record<string, unknown> }

export type SyncState = 'idle' | 'syncing' | 'offline' | { error: string };

export interface State {
  phase: 'loading' | 'onboarding' | 'ready';
  user: UserRec | null;
  family: Family | null;
  members: Member[];
  calendars: CalendarRec[];
  events: EventRec[];
  busy: EventRec[];
  lists: ListRec[];
  tasks: TaskRec[];
  grocery: GroceryRec[];
  learned: LearnedRec[];
  cards: CardRec[];
  invites: InviteRec[];
  feeds: FeedRec[];
  outbox: Op[];
  sync: SyncState;
  lastSync: string | null;
}

const empty: State = {
  phase: 'loading', user: null, family: null, members: [], calendars: [], events: [], busy: [], lists: [], tasks: [], grocery: [],
  learned: [], cards: [], invites: [], feeds: [], outbox: [], sync: 'idle', lastSync: null,
};

let state: State = empty;
const listeners = new Set<() => void>();
function set(patch: Partial<State>) {
  state = { ...state, ...patch };
  listeners.forEach((l) => l());
  scheduleSave();
}
export function getState(): State { return state; }
export function useRoost(): State {
  return useSyncExternalStore((cb) => { listeners.add(cb); return () => listeners.delete(cb); }, () => state);
}

// ---- persistence ---------------------------------------------------------

const snapKey = (fam: string) => `roost.snapshot.${fam}`;
let saveTimer: number | undefined;
function scheduleSave() {
  if (!state.family) return;
  window.clearTimeout(saveTimer);
  saveTimer = window.setTimeout(() => {
    if (!state.family) return;
    const { phase: _p, sync: _s, ...rest } = state;
    try { localStorage.setItem(snapKey(state.family.id), JSON.stringify(rest)); } catch { /* storage full or blocked */ }
    planReminders();
  }, 500);
}
function loadSnapshot(fam: string): Partial<State> | null {
  try { const raw = localStorage.getItem(snapKey(fam)); return raw ? JSON.parse(raw) : null; } catch { return null; }
}

// ---- derived helpers -----------------------------------------------------

export const me = (s: State = state) => s.members.find((m) => m.user === s.user?.id) ?? null;
export const myRole = (s: State = state): Role => me(s)?.role ?? 'relative';
export const isAdmin = (s: State = state) => ['owner', 'parent'].includes(myRole(s));
export const member = (id: string, s: State = state) => s.members.find((m) => m.id === id) ?? null;
export const membersOf = (ids: string[] | null | undefined, s: State = state) => (ids ?? []).map((i) => member(i, s)).filter((m): m is Member => !!m);
export const sortedMembers = (s: State = state) => [...s.members].sort((a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name));
export const liveCalendars = (s: State = state) => s.calendars.filter((c) => !c.deleted).sort((a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name));
export const liveLists = (s: State = state) => s.lists.filter((l) => !l.deleted && !l.archived).sort((a, b) => a.sortOrder - b.sortOrder || a.name.localeCompare(b.name));
export const liveCards = (s: State = state) => s.cards.filter((c) => !c.deleted).sort((a, b) => Number(b.pinned) - Number(a.pinned) || a.sortOrder - b.sortOrder);
export const canEditCalendar = (c: CalendarRec, s: State = state) => c.kind !== 'subscription' && !!s.user && c.editors.includes(s.user.id);
export const canManageCalendar = (c: CalendarRec, s: State = state) => isAdmin(s) || (!!c.owner && c.owner === me(s)?.id);
export const canEditList = (l: ListRec, s: State = state) => !!s.user && l.editors.includes(s.user.id);
export const canEditEvent = (e: EventRec, s: State = state) => {
  if (e.busy || e.source === 'ics') return false;
  const c = s.calendars.find((x) => x.id === e.calendar);
  return !!c && canEditCalendar(c, s);
};
export const canEditTask = (t: TaskRec, s: State = state) => {
  const l = s.lists.find((x) => x.id === t.list);
  return (!!l && canEditList(l, s)) || (!!me(s) && t.assignees.includes(me(s)!.id));
};
export const editableCalendars = (s: State = state) => liveCalendars(s).filter((c) => canEditCalendar(c, s));
export const learnedMap = (s: State = state) => new Map(s.learned.map((l) => [l.term, l.category]));
export function colorFor(e: EventRec, byPerson = true, s: State = state): string {
  if (e.color) return e.color;
  if (byPerson && e.members?.length) { const m = member(e.members[0], s); if (m) return m.color; }
  return s.calendars.find((c) => c.id === e.calendar)?.color ?? 'orange';
}
export const familyTZ = () => validTZ(state.family?.timezone);

// ---- occurrences ---------------------------------------------------------

export interface Occurrence { id: string; event: EventRec; start: Date; end: Date; key: string }

export function durationMinutes(e: EventRec): number {
  const s = pbDate(e.start)!, en = pbDate(e.end) ?? s;
  if (e.allDay) {
    const tz = validTZ(e.tz);
    const a = LocalDateTime.fromDate(s, tz).date, b = LocalDateTime.fromDate(en, tz).date;
    return Math.max(1, b.dayNumber - a.dayNumber) * 1440;
  }
  return Math.max(0, Math.round((en.getTime() - s.getTime()) / 60000));
}

export function expandEvents(events: EventRec[], from: Date, to: Date): Occurrence[] {
  const out: Occurrence[] = [];
  for (const e of events) {
    if (e.deleted) continue;
    const start = pbDate(e.start);
    if (!start) continue;
    const tz = validTZ(e.tz);
    const dur = durationMinutes(e);
    const starts = expand({ start: LocalDateTime.fromDate(start, tz), durationMinutes: dur, allDay: e.allDay, tz, rrule: e.rrule || null,
      exdates: new Set(e.exdates ?? []), rangeStart: from, rangeEnd: to });
    for (const s of starts) {
      const sd = s.toDate(tz);
      const ed = e.allDay ? s.addMinutes(dur).toDate(tz) : new Date(sd.getTime() + dur * 60000);
      const key = s.key(e.allDay);
      out.push({ id: `${e.id}|${key}`, event: e, start: sd, end: ed, key });
    }
  }
  return out.sort((a, b) => a.start.getTime() - b.start.getTime() || Number(b.event.allDay) - Number(a.event.allDay));
}

// ---- outbox --------------------------------------------------------------

let flushing = false;
function put<K extends 'events' | 'tasks' | 'grocery' | 'lists' | 'calendars' | 'cards' | 'members' | 'learned' | 'invites' | 'feeds'>(key: K, rec: State[K][number]) {
  const arr = state[key] as { id: string }[];
  const i = arr.findIndex((x) => x.id === (rec as { id: string }).id);
  const next = i >= 0 ? arr.map((x, j) => (j === i ? rec : x)) : [...arr, rec];
  set({ [key]: next } as Partial<State>);
}
const collKey: Record<Coll, keyof State> = {
  calendars: 'calendars', events: 'events', lists: 'lists', tasks: 'tasks', groceryItems: 'grocery', groceryLearned: 'learned',
  infoCards: 'cards', memberships: 'members', invites: 'invites', feeds: 'feeds', families: 'family',
};

function applyRecord(coll: Coll, rec: Record<string, unknown>) {
  if (coll === 'families') { set({ family: rec as unknown as Family }); return; }
  put(collKey[coll] as 'events', rec as unknown as EventRec);
}
function removeRecord(coll: Coll, id: string) {
  const k = collKey[coll];
  if (k === 'family') return;
  set({ [k]: (state[k] as { id: string }[]).filter((x) => x.id !== id) } as Partial<State>);
}

function enqueue(coll: Coll, recordId: string, kind: Op['kind'], body: Record<string, unknown>) {
  const outbox = [...state.outbox];
  const i = kind === 'update' ? outbox.map((o) => o.recordId === recordId && o.coll === coll && o.kind !== 'delete').lastIndexOf(true) : -1;
  if (i >= 0) outbox[i] = { ...outbox[i], body: { ...outbox[i].body, ...body } };
  else outbox.push({ id: newId(), coll, recordId, kind, body });
  set({ outbox });
  void flush();
}

function isOffline(e: unknown) { return e instanceof ClientResponseError ? e.status === 0 : true; }

export async function flush() {
  if (flushing || !pb.authStore.isValid) return;
  flushing = true;
  try {
    while (state.outbox.length) {
      const op = state.outbox[0];
      try {
        if (op.kind === 'create') {
          try { applyRecord(op.coll, await pb.collection(op.coll).create({ ...op.body, id: op.recordId })); }
          catch (e) {
            if (e instanceof ClientResponseError && e.status === 400 && e.response?.data?.id) applyRecord(op.coll, await pb.collection(op.coll).update(op.recordId, op.body));
            else throw e;
          }
        } else if (op.kind === 'update') applyRecord(op.coll, await pb.collection(op.coll).update(op.recordId, op.body));
        else await pb.collection(op.coll).delete(op.recordId);
        set({ outbox: state.outbox.slice(1), sync: state.sync === 'offline' ? 'idle' : state.sync });
      } catch (e) {
        if (isOffline(e)) { set({ sync: 'offline' }); return; }
        set({ outbox: state.outbox.slice(1), sync: { error: (e as ClientResponseError).message || 'A change was rejected.' } });
        void syncNow();
      }
    }
  } finally { flushing = false; }
}
window.addEventListener('online', () => { void flush(); void syncNow(); });

// ---- session -------------------------------------------------------------

export async function bootstrap() {
  if (!pb.authStore.isValid || !pb.authStore.record) { set({ phase: 'onboarding' }); return; }
  const user = pb.authStore.record as unknown as UserRec;
  const famId = localStorage.getItem('roost.familyId');
  if (famId) {
    const snap = loadSnapshot(famId);
    if (snap?.family) set({ ...snap, user, phase: 'ready', sync: 'syncing' } as Partial<State>);
  }
  try {
    await pb.collection('users').authRefresh();
    set({ user: pb.authStore.record as unknown as UserRec });
    await openFirstFamily();
  } catch (e) {
    if (e instanceof ClientResponseError && e.status === 401) { signOut(); return; }
    if (!state.family) set({ phase: 'onboarding' });
    else set({ sync: 'offline' });
  }
}

async function openFirstFamily() {
  const fams = await pb.collection('families').getFullList<Family>({ sort: 'created' });
  if (!fams.length) { set({ phase: 'onboarding', family: null }); return; }
  const fam = fams.find((f) => f.id === localStorage.getItem('roost.familyId')) ?? fams[0];
  if (state.family?.id !== fam.id) {
    const snap = loadSnapshot(fam.id);
    set({ ...(snap ?? {}), family: fam, phase: 'ready' } as Partial<State>);
  } else set({ family: fam, phase: 'ready' });
  localStorage.setItem('roost.familyId', fam.id);
  await syncNow();
  startRealtime();
}

export async function signIn(email: string, password: string) {
  await pb.collection('users').authWithPassword(email, password);
  set({ user: pb.authStore.record as unknown as UserRec });
  await openFirstFamily();
  if (!state.family) throw new Error("This account isn't in a family yet. Use an invite code or start a new family.");
}

export async function createAccount(name: string, email: string, password: string, inviteCode?: string) {
  await pb.collection('users').create({ name, email, password, passwordConfirm: password, ...(inviteCode ? { inviteCode } : {}) });
  await pb.collection('users').authWithPassword(email, password);
  set({ user: pb.authStore.record as unknown as UserRec });
}

export async function createFamily(name: string, timezone: string) {
  const fam = await pb.collection('families').create<Family>({ name, timezone });
  localStorage.setItem('roost.familyId', fam.id);
  await openFirstFamily();
}

export async function invitePreview(code: string) {
  return pb.send<{ family: string; role: Role; name: string }>(`/api/roost/invites/${encodeURIComponent(code)}`, {});
}

export async function joinFamily(code: string, name?: string) {
  const r = await pb.send<{ family: string }>('/api/roost/join', { method: 'POST', body: { code, name } });
  localStorage.setItem('roost.familyId', r.family);
  await openFirstFamily();
}

export function signOut() {
  stopRealtime();
  if (state.family) try { localStorage.removeItem(snapKey(state.family.id)); } catch { /* ignore */ }
  localStorage.removeItem('roost.familyId');
  pb.authStore.clear();
  state = { ...empty, phase: 'onboarding' };
  listeners.forEach((l) => l());
}

// ---- sync ----------------------------------------------------------------

function keepPending<T extends { id: string }>(local: T[], server: T[]): T[] {
  const pending = new Set(state.outbox.map((o) => o.recordId));
  const out = [...server];
  for (const l of local) {
    if (!pending.has(l.id)) continue;
    const i = out.findIndex((x) => x.id === l.id);
    if (i >= 0) out[i] = l; else out.push(l);
  }
  return out;
}

let syncing: Promise<void> | null = null;
export function syncNow(): Promise<void> {
  if (syncing) return syncing;
  syncing = doSync().finally(() => { syncing = null; });
  return syncing;
}

async function doSync() {
  const fam = state.family;
  if (!fam || !pb.authStore.isValid) return;
  set({ sync: 'syncing' });
  await flush();
  try {
    const f = pb.filter('family = {:f}', { f: fam.id });
    const live = f + ' && deleted = false';
    const opts = (filter: string) => ({ filter, requestKey: null });
    const [family, members, calendars, events, lists, tasks, grocery, learned, cards] = await Promise.all([
      pb.collection('families').getOne<Family>(fam.id),
      pb.collection('memberships').getFullList<Member>({ ...opts(f), sort: 'sortOrder,created' }),
      pb.collection('calendars').getFullList<CalendarRec>(opts(live)),
      pb.collection('events').getFullList<EventRec>({ ...opts(live), batch: 500 }),
      pb.collection('lists').getFullList<ListRec>(opts(live)),
      pb.collection('tasks').getFullList<TaskRec>({ ...opts(live), batch: 500 }),
      pb.collection('groceryItems').getFullList<GroceryRec>({ ...opts(live), batch: 500 }),
      pb.collection('groceryLearned').getFullList<LearnedRec>(opts(f)),
      pb.collection('infoCards').getFullList<CardRec>(opts(live)),
    ]);
    const admin = ['owner', 'parent'].includes(members.find((m) => m.user === state.user?.id)?.role ?? '');
    const invites = admin ? await pb.collection('invites').getFullList<InviteRec>({ ...opts(f + " && usedBy = ''"), sort: '-created' }).catch(() => []) : [];
    const feeds = await pb.collection('feeds').getFullList<FeedRec>(opts(f)).catch(() => []);
    const from = new Date(Date.now() - 45 * 86400000).toISOString(), to = new Date(Date.now() + 400 * 86400000).toISOString();
    const busy = await pb.send<{ items: EventRec[] }>(`/api/roost/busy?family=${fam.id}&from=${from}&to=${to}`, {}).then((r) => r.items.map((b) => ({ ...b, busy: true }))).catch(() => state.busy);
    set({
      family, members,
      calendars: keepPending(state.calendars, calendars), events: keepPending(state.events, events), lists: keepPending(state.lists, lists),
      tasks: keepPending(state.tasks, tasks), grocery: keepPending(state.grocery, grocery), learned, cards: keepPending(state.cards, cards),
      invites, feeds, busy, lastSync: new Date().toISOString(), sync: state.outbox.length ? 'offline' : 'idle',
    });
  } catch (e) {
    set({ sync: isOffline(e) ? 'offline' : { error: (e as Error).message } });
  }
}

const RT: Coll[] = ['memberships', 'calendars', 'events', 'lists', 'tasks', 'groceryItems', 'groceryLearned', 'infoCards', 'invites'];
let unsubs: (() => void)[] = [];
let resyncTimer: number | undefined;
function startRealtime() {
  stopRealtime();
  for (const coll of RT) {
    pb.collection(coll).subscribe('*', (ev) => {
      const rec = ev.record as unknown as Record<string, unknown> & { id: string; family?: string };
      if (rec.family && rec.family !== state.family?.id) return;
      if (ev.action === 'delete') removeRecord(coll, rec.id); else applyRecord(coll, rec);
      if (coll === 'memberships' || coll === 'calendars' || coll === 'lists') {
        window.clearTimeout(resyncTimer);
        resyncTimer = window.setTimeout(() => void syncNow(), 400);
      }
    }).then((u) => unsubs.push(u)).catch(() => undefined);
  }
  pb.realtime.onDisconnect = () => set({ sync: 'offline' });
}
function stopRealtime() {
  unsubs.forEach((u) => u());
  unsubs = [];
}
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && state.family) void syncNow(); });

// ---- events --------------------------------------------------------------

export function newEvent(start: Date, allDay = false, calendarId?: string): EventRec {
  const cals = editableCalendars();
  const cal = cals.find((c) => c.id === calendarId) ?? cals.find((c) => c.kind === 'family') ?? cals[0];
  const end = allDay ? new Date(start.getTime() + 86400000) : new Date(start.getTime() + 3600000);
  return {
    id: newId(), family: state.family?.id ?? '', calendar: cal?.id ?? '', title: '', notes: '', location: '', url: '',
    start: toPB(start), end: toPB(end), allDay, tz: localTZ(), rrule: '', exdates: [], recurrenceParent: '', members: [], driver: '',
    category: '', reminders: cal?.defaultReminders ?? [30], private: false, color: '', source: 'roost', createdBy: state.user?.id ?? '', deleted: false,
  };
}

const eventBody = (e: EventRec) => ({
  calendar: e.calendar, title: e.title, notes: e.notes, location: e.location, url: e.url, start: e.start, end: e.end, allDay: e.allDay,
  tz: e.tz, rrule: e.rrule, exdates: e.exdates ?? [], recurrenceParent: e.recurrenceParent, members: e.members, driver: e.driver,
  category: e.category, reminders: e.reminders ?? [], private: e.private, color: e.color, deleted: e.deleted,
});

export function saveEvent(e: EventRec) {
  const isNew = !state.events.some((x) => x.id === e.id);
  const rec = { ...e, family: state.family?.id ?? e.family, updated: new Date().toISOString() };
  put('events', rec);
  enqueue('events', e.id, isNew ? 'create' : 'update', eventBody(rec));
}
export function deleteEvent(e: EventRec) {
  put('events', { ...e, deleted: true });
  enqueue('events', e.id, 'update', { deleted: true });
}
export function deleteOccurrence(o: Occurrence) {
  const m = state.events.find((x) => x.id === o.event.id);
  if (!m) return;
  const exdates = [...new Set([...(m.exdates ?? []), o.key])];
  put('events', { ...m, exdates });
  enqueue('events', m.id, 'update', { exdates });
}
export function endSeries(o: Occurrence) {
  const m = state.events.find((x) => x.id === o.event.id);
  const rule = RRule.parse(m?.rrule);
  if (!m || !rule) return;
  const prev = LocalDateTime.fromDate(o.start, validTZ(m.tz)).date.addDays(-1);
  rule.count = undefined;
  rule.until = { kind: 'date', date: prev };
  const rrule = rule.toString();
  put('events', { ...m, rrule });
  enqueue('events', m.id, 'update', { rrule });
}
export function saveOccurrenceEdit(o: Occurrence, edited: EventRec) {
  deleteOccurrence(o);
  saveEvent({ ...edited, id: newId(), rrule: '', exdates: [], recurrenceParent: o.event.id });
}
export function saveFollowingEdit(o: Occurrence, edited: EventRec) {
  endSeries(o);
  saveEvent({ ...edited, id: newId(), exdates: [] });
}

// ---- tasks ---------------------------------------------------------------

export function newTask(list: string, title = ''): TaskRec {
  const max = Math.max(0, ...state.tasks.filter((t) => t.list === list).map((t) => t.sortOrder));
  return {
    id: newId(), family: state.family?.id ?? '', list, title, notes: '', due: '', assignees: [], priority: 0, rrule: '', completed: false,
    completedAt: '', completedBy: '', parent: '', reminders: [], tags: [], sortOrder: max + 1, createdBy: state.user?.id ?? '', deleted: false,
  };
}
const taskBody = (t: TaskRec) => ({
  list: t.list, title: t.title, notes: t.notes, due: t.due, assignees: t.assignees, priority: t.priority, rrule: t.rrule, completed: t.completed,
  completedAt: t.completedAt, parent: t.parent, reminders: t.reminders ?? [], tags: t.tags ?? [], sortOrder: t.sortOrder, deleted: t.deleted,
});
export function saveTask(t: TaskRec) {
  const isNew = !state.tasks.some((x) => x.id === t.id);
  put('tasks', { ...t, family: state.family?.id ?? t.family, updated: new Date().toISOString() });
  enqueue('tasks', t.id, isNew ? 'create' : 'update', taskBody(t));
}
export function toggleTask(t0: TaskRec) {
  const t = state.tasks.find((x) => x.id === t0.id) ?? t0;
  if (!t.completed && t.rrule && t.due) {
    saveTask({ ...t, id: newId(), rrule: '', completed: true, completedAt: toPB(new Date()) });
    const next = nextDue(t.due, t.rrule, LocalDateTime.fromDate(new Date(), localTZ()));
    saveTask(next ? { ...t, due: next } : { ...t, completed: true, completedAt: toPB(new Date()) });
    return;
  }
  saveTask({ ...t, completed: !t.completed, completedAt: t.completed ? '' : toPB(new Date()) });
}
export function deleteTask(t: TaskRec) {
  put('tasks', { ...t, deleted: true });
  enqueue('tasks', t.id, 'update', { deleted: true });
  for (const s of state.tasks.filter((x) => x.parent === t.id && !x.deleted)) deleteTask(s);
}
export const subtasks = (t: TaskRec, s: State = state) => s.tasks.filter((x) => x.parent === t.id && !x.deleted).sort((a, b) => a.sortOrder - b.sortOrder);

// ---- groceries -----------------------------------------------------------

const groceryBody = (g: GroceryRec) => ({
  list: g.list, name: g.name, quantity: g.quantity || 0, unit: g.unit, note: g.note, category: g.category,
  categorySource: g.categorySource || 'none', checked: g.checked, sortOrder: g.sortOrder, deleted: g.deleted,
});
export function saveGrocery(g: GroceryRec) {
  const isNew = !state.grocery.some((x) => x.id === g.id);
  put('grocery', { ...g, family: state.family?.id ?? g.family, updated: new Date().toISOString() });
  enqueue('groceryItems', g.id, isNew ? 'create' : 'update', groceryBody(g));
}
export function addGroceries(text: string, list: string) {
  const learned = learnedMap();
  const unknown: GroceryRec[] = [];
  for (const line of text.split(/[\n,;]/)) {
    const p = parseGroceryLine(line);
    if (!p) continue;
    const existing = state.grocery.filter((g) => g.list === list && !g.deleted);
    const d = decideMerge(p, existing.map((g) => ({ name: g.name, quantity: g.quantity || null, unit: g.unit || null, checked: g.checked })));
    if (d.action !== 'new') {
      const it = existing[d.targetIndex!];
      saveGrocery({ ...it, quantity: d.quantity ?? 0, unit: d.unit ?? '', checked: false, checkedAt: '' });
    } else {
      const r = categorize(p.name, learned);
      const g: GroceryRec = {
        id: newId(), family: state.family?.id ?? '', list, name: p.name, quantity: p.quantity ?? 0, unit: p.unit ?? '', note: '',
        category: r.category, categorySource: r.source, checked: false, checkedAt: '', addedBy: state.user?.id ?? '', sortOrder: Date.now() / 1000, deleted: false,
      };
      saveGrocery(g);
      if (r.source === 'none') unknown.push(g);
    }
  }
  if (unknown.length && state.family) {
    pb.send<{ categories: Record<string, string> }>('/api/roost/categorize', { method: 'POST', body: { family: state.family.id, items: unknown.map((u) => u.name) } })
      .then((r) => {
        for (const u of unknown) {
          const c = r.categories?.[u.name];
          const cur = state.grocery.find((g) => g.id === u.id);
          if (c && c !== 'other' && cur && cur.categorySource === 'none') saveGrocery({ ...cur, category: c, categorySource: 'ai' });
        }
      })
      .catch(() => undefined);
  }
}
export function toggleGrocery(g: GroceryRec) { saveGrocery({ ...g, checked: !g.checked, checkedAt: g.checked ? '' : toPB(new Date()) }); }
export function deleteGrocery(g: GroceryRec) { put('grocery', { ...g, deleted: true }); enqueue('groceryItems', g.id, 'update', { deleted: true }); }
export function clearChecked(list: string) { for (const g of state.grocery.filter((x) => x.list === list && x.checked && !x.deleted)) deleteGrocery(g); }
export function setGroceryCategory(g: GroceryRec, category: string) {
  saveGrocery({ ...g, category, categorySource: 'manual' });
  const term = learnKey(g.name);
  if (!term || !state.family) return;
  const rec: LearnedRec = { id: newId(), family: state.family.id, term, category };
  set({ learned: [...state.learned.filter((l) => l.term !== term), rec] });
  enqueue('groceryLearned', rec.id, 'create', { family: rec.family, term, category });
}
export function suggestions(list: string, limit = 12): string[] {
  const on = new Set(state.grocery.filter((g) => g.list === list && !g.deleted && !g.checked).map((g) => mergeKey(g.name)));
  const counts = new Map<string, { name: string; n: number }>();
  for (const g of state.grocery) {
    if (g.list !== list) continue;
    const k = mergeKey(g.name);
    if (on.has(k)) continue;
    const c = counts.get(k) ?? { name: g.name, n: 0 };
    c.n++;
    counts.set(k, c);
  }
  return [...counts.values()].sort((a, b) => b.n - a.n || a.name.localeCompare(b.name)).slice(0, limit).map((c) => c.name);
}
export function orderedCategories(l: ListRec): GroceryCategory[] {
  const order = l.storeOrder ?? [];
  if (!order.length) return taxonomy.categories;
  const pos = new Map(order.map((k, i) => [k, i]));
  return [...taxonomy.categories].sort((a, b) => (pos.get(a.key) ?? 1000 + a.order) - (pos.get(b.key) ?? 1000 + b.order));
}

// ---- lists, calendars, cards, people -------------------------------------

export function saveList(l: ListRec) {
  const isNew = !state.lists.some((x) => x.id === l.id);
  put('lists', l);
  enqueue('lists', l.id, isNew ? 'create' : 'update', {
    family: state.family?.id, name: l.name, kind: l.kind, icon: l.icon, color: l.color, owner: l.owner, sharing: l.sharing,
    storeOrder: l.storeOrder ?? [], sortOrder: l.sortOrder, archived: l.archived, deleted: l.deleted,
  });
}
export function saveCalendar(c: CalendarRec) {
  const isNew = !state.calendars.some((x) => x.id === c.id);
  put('calendars', c);
  enqueue('calendars', c.id, isNew ? 'create' : 'update', {
    family: state.family?.id, name: c.name, color: c.color, kind: c.kind, owner: c.owner, sharing: c.sharing,
    defaultReminders: c.defaultReminders ?? [], sourceUrl: c.sourceUrl, sortOrder: c.sortOrder, deleted: c.deleted,
  });
}
export function saveCard(c: CardRec) {
  const isNew = !state.cards.some((x) => x.id === c.id);
  put('cards', c);
  enqueue('infoCards', c.id, isNew ? 'create' : 'update', {
    family: state.family?.id, title: c.title, body: c.body, kind: c.kind || 'note', icon: c.icon, phone: c.phone, address: c.address,
    aboutMember: c.aboutMember, pinned: c.pinned, sharing: c.sharing, sortOrder: c.sortOrder, deleted: c.deleted,
  });
}
export function saveMember(m: Member) {
  const isNew = !state.members.some((x) => x.id === m.id);
  put('members', m);
  const body: Record<string, unknown> = { name: m.name, color: m.color, emoji: m.emoji, birthday: m.birthday, notifyAll: m.notifyAll, sortOrder: m.sortOrder };
  if (isNew) { body.family = state.family?.id; body.role = m.role; } else if (isAdmin() && m.user !== state.user?.id) body.role = m.role;
  enqueue('memberships', m.id, isNew ? 'create' : 'update', body);
}
export function removeMember(m: Member) {
  set({ members: state.members.filter((x) => x.id !== m.id) });
  enqueue('memberships', m.id, 'delete', {});
}
export async function createInvite(role: Role, name: string, membership?: string): Promise<InviteRec> {
  const inv = await pb.collection('invites').create<InviteRec>({ family: state.family!.id, role, name, ...(membership ? { membership } : {}) });
  put('invites', inv);
  return inv;
}
export async function ensureFeed(): Promise<FeedRec> {
  const f = state.feeds.find((x) => x.user === state.user?.id);
  if (f) return f;
  const rec = await pb.collection('feeds').create<FeedRec>({ family: state.family!.id, user: state.user!.id, name: state.family!.name, includeBusy: true });
  put('feeds', rec);
  return rec;
}
export const feedURL = (f: FeedRec) => `${apiBase}/api/roost/ics/${f.token}.ics`;
export async function refreshSubscription(c: CalendarRec): Promise<string | null> {
  try {
    const r = await pb.send<{ ok: boolean; error?: string }>(`/api/roost/calendars/${c.id}/refresh`, { method: 'POST' });
    await syncNow();
    return r.ok ? null : r.error ?? 'Refresh failed.';
  } catch (e) { return (e as Error).message; }
}

// ---- reminders (while the app is open) ------------------------------------

let reminderTimers: number[] = [];
const fired = new Set<string>();
export async function enableNotifications(): Promise<NotificationPermission> {
  if (!('Notification' in window)) return 'denied';
  const p = await Notification.requestPermission();
  planReminders();
  return p;
}
function notify(title: string, body: string, tag: string) {
  if (fired.has(tag) || !('Notification' in window) || Notification.permission !== 'granted') return;
  fired.add(tag);
  navigator.serviceWorker?.getRegistration().then((reg) => {
    if (reg) void reg.showNotification(title, { body, tag, icon: 'icon-192.png' });
    else new Notification(title, { body, tag });
  }).catch(() => new Notification(title, { body, tag }));
}
function planReminders() {
  reminderTimers.forEach((t) => window.clearTimeout(t));
  reminderTimers = [];
  if (!('Notification' in window) || Notification.permission !== 'granted' || !state.family) return;
  const now = Date.now(), horizon = now + 24 * 3600000;
  const mine = me();
  const relevant = state.events.filter((e) => !e.deleted && (e.reminders?.length ?? 0) > 0 &&
    (mine?.notifyAll || (mine && (e.members.includes(mine.id) || e.driver === mine.id)) || (!e.members.length && e.createdBy === state.user?.id)));
  for (const o of expandEvents(relevant, new Date(now), new Date(horizon + 7 * 86400000))) {
    for (const m of o.event.reminders ?? []) {
      const at = o.start.getTime() - m * 60000;
      if (at > now && at < horizon) {
        reminderTimers.push(window.setTimeout(() => notify(o.event.title, o.start.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }) + (o.event.location ? ` · ${o.event.location}` : ''), `e.${o.id}.${m}`), at - now));
      }
    }
  }
  for (const t of state.tasks) {
    if (t.deleted || t.completed || !t.due || !(t.reminders?.length)) continue;
    if (!(mine?.notifyAll || (mine && t.assignees.includes(mine.id)) || (!t.assignees.length && t.createdBy === state.user?.id))) continue;
    const due = LocalDateTime.parse(t.due);
    if (!due) continue;
    for (const m of t.reminders!) {
      const at = due.toDate(localTZ()).getTime() - m * 60000;
      if (at > now && at < horizon) reminderTimers.push(window.setTimeout(() => notify(t.title, 'To-do due', `t.${t.id}.${m}`), at - now));
    }
  }
}

export const todayKey = () => LocalDateTime.fromDate(new Date(), localTZ()).date.toString();
export { LocalDate };
