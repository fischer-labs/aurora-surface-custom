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
  /** Changes the server refused (shown in Settings, newest first). */
  rejected: { id: string; what: string; message: string; at: string }[];
  /** The session expired: unsent changes are kept until the same person signs in again. */
  needsSignIn: boolean;
  sync: SyncState;
  lastSync: string | null;
}

const empty: State = {
  phase: 'loading', user: null, family: null, members: [], calendars: [], events: [], busy: [], lists: [], tasks: [], grocery: [],
  learned: [], cards: [], invites: [], feeds: [], outbox: [], rejected: [], needsSignIn: false, sync: 'idle', lastSync: null,
};

let state: State = empty;
const listeners = new Set<() => void>();
function set(patch: Partial<State>) {
  state = { ...state, ...patch };
  listeners.forEach((l) => l());
  if (patch.outbox) saveOutbox();
  scheduleSave();
}
export function getState(): State { return state; }
export function useRoost(): State {
  return useSyncExternalStore((cb) => { listeners.add(cb); return () => listeners.delete(cb); }, () => state);
}

// ---- persistence ---------------------------------------------------------

const snapKey = (fam: string) => `roost.snapshot.${fam}`;
const outboxKey = (fam: string) => `roost.outbox.${fam}`;
let saveTimer: number | undefined;
function scheduleSave() {
  if (!state.family) return;
  window.clearTimeout(saveTimer);
  saveTimer = window.setTimeout(() => {
    if (!state.family) return;
    const { phase: _p, sync: _s, needsSignIn: _n, outbox: _o, ...rest } = state;
    try { localStorage.setItem(snapKey(state.family.id), JSON.stringify(rest)); } catch {
      // Over quota (big subscriptions): keep a smaller snapshot without other people's busy blocks and old events.
      try {
        const cutoff = Date.now() - 31 * 86400000;
        const events = rest.events.filter((e) => e.rrule || (pbDate(e.end)?.getTime() ?? 0) > cutoff);
        localStorage.setItem(snapKey(state.family.id), JSON.stringify({ ...rest, busy: [], events }));
      } catch { /* the outbox is stored separately, so no change is lost */ }
    }
    planReminders();
  }, 500);
}
/** Unsent changes are small and precious: write them synchronously, separately from the snapshot. */
function saveOutbox() {
  if (!state.family) return;
  try {
    localStorage.setItem(outboxKey(state.family.id), JSON.stringify({ user: state.user?.id ?? '', ops: state.outbox }));
  } catch { /* blocked storage: nothing more we can do */ }
}
function loadSnapshot(fam: string, userId?: string): Partial<State> | null {
  let snap: Partial<State> | null = null;
  try { const raw = localStorage.getItem(snapKey(fam)); snap = raw ? JSON.parse(raw) : null; } catch { snap = null; }
  let outbox: Op[] = [];
  try {
    const raw = JSON.parse(localStorage.getItem(outboxKey(fam)) ?? 'null') as { user: string; ops: Op[] } | null;
    // Only replay changes made by the person signing in now.
    if (raw && Array.isArray(raw.ops) && (!userId || raw.user === userId)) outbox = raw.ops;
  } catch { /* ignore */ }
  if (!snap && !outbox.length) return null;
  return { ...(snap ?? {}), outbox };
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
  return s.calendars.find((c) => c.id === e.calendar)?.color ?? 'brown';
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
    // All-day events are floating dates: Dec 4 is Dec 4 for a grandparent in another time zone too.
    const viewTz = e.allDay ? localTZ() : tz;
    const exdates = new Set(Array.isArray(e.exdates) ? e.exdates.filter((x) => typeof x === 'string') : []);
    let starts: LocalDateTime[] = [];
    try {
      starts = expand({ start: LocalDateTime.fromDate(start, tz), durationMinutes: dur, allDay: e.allDay, tz: viewTz, rrule: e.rrule || null,
        exdates, rangeStart: from, rangeEnd: to });
    } catch { continue; } // one malformed event must not break the calendar for everyone
    for (const s of starts) {
      const sd = s.toDate(viewTz);
      const ed = e.allDay ? s.addMinutes(dur).toDate(viewTz) : new Date(sd.getTime() + dur * 60000);
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

/** Records changed locally (or by our own writes) since a given time, so a sync in flight can't overwrite them. */
const touched = new Map<string, number>();
const touch = (id: string) => touched.set(id, Date.now());

let inFlight: string | null = null;
function enqueue(coll: Coll, recordId: string, kind: Op['kind'], body: Record<string, unknown>) {
  touch(recordId);
  const outbox = [...state.outbox];
  // Fold into the latest queued op for this record — but never into the one being sent right now.
  let i = -1;
  if (kind === 'update') {
    for (let j = outbox.length - 1; j >= 0; j--) {
      const o = outbox[j];
      if (o.coll === coll && o.recordId === recordId) { if (o.kind !== 'delete' && o.id !== inFlight) i = j; break; }
    }
  }
  if (i >= 0) outbox[i] = { ...outbox[i], body: { ...outbox[i].body, ...body } };
  else outbox.push({ id: newId(), coll, recordId, kind, body });
  set({ outbox });
  void flush();
}

/** Server answers that mean "this change will never be accepted". Everything else is retried. */
const definitive = (status: number) => status === 400 || status === 403 || status === 404 || status === 413 || status === 422;
function isOffline(e: unknown) { return !(e instanceof ClientResponseError) || !definitive(e.status); }
let retryTimer: number | undefined;
let backoff = 2000;
function scheduleRetry() {
  window.clearTimeout(retryTimer);
  retryTimer = window.setTimeout(() => void flush(), backoff);
  backoff = Math.min(backoff * 2, 60000);
}
const describeOp = (op: Op) => {
  const name = (op.body.title ?? op.body.name) as string | undefined;
  const noun = ({ events: 'event', tasks: 'to-do', groceryItems: 'grocery item', lists: 'list', calendars: 'calendar', infoCards: 'card', memberships: 'person' } as Record<string, string>)[op.coll] ?? 'change';
  return name ? `${noun} “${name}”` : `a ${noun} change`;
};

/** Re-applies changes still queued for a record on top of what the server returned. */
function withPending(coll: Coll, rec: Record<string, unknown> & { id: string }) {
  let out = rec;
  for (const o of state.outbox) if (o.coll === coll && o.recordId === rec.id && o.kind !== 'delete') out = { ...out, ...o.body };
  return out;
}

export async function flush() {
  if (flushing || !pb.authStore.isValid || state.needsSignIn) return;
  flushing = true;
  try {
    while (state.outbox.length) {
      const op = state.outbox[0];
      inFlight = op.id;
      try {
        let rec: Record<string, unknown> & { id: string } | null = null;
        if (op.kind === 'create') {
          try { rec = await pb.collection(op.coll).create({ ...op.body, id: op.recordId }); }
          catch (e) {
            // Already created (a retry after a lost response): turn it into an update.
            if (e instanceof ClientResponseError && e.status === 400 && e.response?.data?.id) rec = await pb.collection(op.coll).update(op.recordId, op.body);
            else throw e;
          }
        } else if (op.kind === 'update') rec = await pb.collection(op.coll).update(op.recordId, op.body);
        else await pb.collection(op.coll).delete(op.recordId);
        inFlight = null;
        set({ outbox: state.outbox.filter((o) => o.id !== op.id), sync: state.sync === 'offline' ? 'idle' : state.sync });
        if (rec) { touch(rec.id); applyRecord(op.coll, withPending(op.coll, rec)); }
        backoff = 2000;
      } catch (e) {
        inFlight = null;
        const status = e instanceof ClientResponseError ? e.status : 0;
        if (status === 401) {
          // The session ran out. Try to renew it; if that fails, keep every change and ask to sign in.
          try { await pb.collection('users').authRefresh(); continue; } catch { set({ needsSignIn: true, sync: { error: 'Please sign in again to send your changes.' } }); return; }
        }
        if (!definitive(status)) { set({ sync: 'offline' }); scheduleRetry(); return; }
        const message = (e as ClientResponseError).message || 'The server refused this change.';
        set({
          outbox: state.outbox.filter((o) => o.id !== op.id),
          rejected: [{ id: op.id, what: describeOp(op), message, at: new Date().toISOString() }, ...state.rejected].slice(0, 20),
          sync: { error: `Couldn't save ${describeOp(op)}: ${message}` },
        });
        // Put the record back the way the server has it (unless more changes for it are queued).
        if (!state.outbox.some((o) => o.recordId === op.recordId)) {
          touched.delete(op.recordId);
          pb.collection(op.coll).getOne(op.recordId).then((r) => applyRecord(op.coll, r)).catch((err) => {
            if (err instanceof ClientResponseError && err.status === 404 && op.kind === 'create') removeRecord(op.coll, op.recordId);
          });
        }
      }
    }
  } finally { inFlight = null; flushing = false; }
}
export const dismissRejected = () => set({ rejected: [], sync: state.outbox.length ? 'offline' : 'idle' });
window.addEventListener('online', () => { void flush(); void syncNow(); });

// ---- session -------------------------------------------------------------

export async function bootstrap() {
  if (!pb.authStore.isValid || !pb.authStore.record) { set({ phase: 'onboarding' }); return; }
  const user = pb.authStore.record as unknown as UserRec;
  const famId = localStorage.getItem('roost.familyId');
  if (famId) {
    const snap = loadSnapshot(famId, user.id);
    if (snap?.family) set({ ...snap, user, phase: 'ready', sync: 'syncing' } as Partial<State>);
  }
  try {
    await pb.collection('users').authRefresh();
    lastAuthRefresh = Date.now();
    set({ user: pb.authStore.record as unknown as UserRec });
    await openFirstFamily();
  } catch (e) {
    if (e instanceof ClientResponseError && e.status === 401) { expireSession(); return; }
    if (!state.family) set({ phase: 'onboarding' });
    else set({ sync: 'offline' });
  }
}

/** The login expired: go to sign-in but keep the snapshot and unsent changes for when this person signs back in. */
export function expireSession() {
  stopRealtime();
  saveOutbox();
  pb.authStore.clear();
  state = { ...empty, phase: 'onboarding' };
  listeners.forEach((l) => l());
}

/** Someone removed us from the family: forget everything we cached about it. */
function leaveFamily(famId: string) {
  stopRealtime();
  try { localStorage.removeItem(snapKey(famId)); localStorage.removeItem(outboxKey(famId)); } catch { /* ignore */ }
  if (localStorage.getItem('roost.familyId') === famId) localStorage.removeItem('roost.familyId');
  state = { ...empty, user: state.user, phase: 'onboarding' };
  listeners.forEach((l) => l());
}

async function openFirstFamily() {
  const fams = await pb.collection('families').getFullList<Family>({ sort: 'created' });
  if (!fams.length) { set({ phase: 'onboarding', family: null }); return; }
  const fam = fams.find((f) => f.id === localStorage.getItem('roost.familyId')) ?? fams[0];
  if (state.family?.id !== fam.id) {
    const snap = loadSnapshot(fam.id, pb.authStore.record?.id);
    set({ ...(snap ?? {}), family: fam, phase: 'ready', needsSignIn: false } as Partial<State>);
  } else set({ family: fam, phase: 'ready', needsSignIn: false });
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
  if (state.family) try { localStorage.removeItem(snapKey(state.family.id)); localStorage.removeItem(outboxKey(state.family.id)); } catch { /* ignore */ }
  localStorage.removeItem('roost.familyId');
  pb.authStore.clear();
  state = { ...empty, phase: 'onboarding' };
  listeners.forEach((l) => l());
}

// ---- sync ----------------------------------------------------------------

let syncStartedAt = 0;
function keepPending<T extends { id: string }>(local: T[], server: T[]): T[] {
  const pending = new Set(state.outbox.map((o) => o.recordId));
  const out = [...server];
  for (const l of local) {
    // Queued, or changed (by us or by realtime) after this sync started: the local copy is newer.
    if (!pending.has(l.id) && (touched.get(l.id) ?? 0) < syncStartedAt) continue;
    const i = out.findIndex((x) => x.id === l.id);
    if (i >= 0) out[i] = l; else out.push(l);
  }
  return out;
}

let syncing: Promise<void> | null = null;
let lastAuthRefresh = 0;
export function syncNow(): Promise<void> {
  if (syncing) return syncing;
  syncing = doSync().finally(() => { syncing = null; });
  return syncing;
}

async function doSync() {
  const fam = state.family;
  if (!fam || !pb.authStore.isValid || state.needsSignIn) return;
  set({ sync: 'syncing' });
  // Renew the login now and then so a tab or phone left open for days doesn't lose its session.
  if (Date.now() - lastAuthRefresh > 6 * 3600000) {
    try { await pb.collection('users').authRefresh(); lastAuthRefresh = Date.now(); }
    catch (e) { if (e instanceof ClientResponseError && e.status === 401) { set({ needsSignIn: true, sync: { error: 'Please sign in again.' } }); return; } }
  }
  await flush();
  syncStartedAt = Date.now();
  try {
    const gone = await pb.collection('families').getOne<Family>(fam.id).then(() => false).catch((e) => e instanceof ClientResponseError && (e.status === 404 || e.status === 403));
    if (gone) { leaveFamily(fam.id); return; }
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
      touch(rec.id);
      if (ev.action === 'delete') removeRecord(coll, rec.id); else applyRecord(coll, withPending(coll, rec));
      if (coll === 'memberships' || coll === 'calendars' || coll === 'lists') {
        window.clearTimeout(resyncTimer);
        resyncTimer = window.setTimeout(() => void syncNow(), 400);
      }
    }).then((u) => unsubs.push(u)).catch(() => undefined);
  }
  pb.realtime.onDisconnect = () => set({ sync: 'offline' });
  // PB_CONNECT fires on every (re)connect: catch up on anything missed while disconnected.
  let first = true;
  pb.realtime.subscribe('PB_CONNECT', () => { if (!first) void syncNow(); first = false; }).then((u) => unsubs.push(u)).catch(() => undefined);
}
// A wall-mounted kitchen screen stays fresh even if realtime silently stalls.
window.setInterval(() => { if (document.visibilityState === 'visible' && state.family && !syncing) void syncNow(); }, 5 * 60000);
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

const same = (a: unknown, b: unknown) => JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
/** Only the fields that changed, so a stale copy can't overwrite someone else's newer edits. */
function changed(prev: Record<string, unknown>, next: Record<string, unknown>) {
  const out: Record<string, unknown> = {};
  for (const k of Object.keys(next)) if (!same(prev[k], next[k])) out[k] = next[k];
  return out;
}
type Keyed = 'events' | 'tasks' | 'grocery' | 'lists' | 'calendars' | 'cards' | 'members';
function commit<T extends { id: string }>(coll: Coll, key: Keyed, rec: T, body: (r: T) => Record<string, unknown>, createExtra: Record<string, unknown> = {}) {
  const prev = (state[key] as unknown as T[]).find((x) => x.id === rec.id);
  put(key, rec as never);
  if (!prev) { enqueue(coll, rec.id, 'create', { ...body(rec), ...createExtra }); return; }
  const d = changed(body(prev), body(rec));
  if (Object.keys(d).length) enqueue(coll, rec.id, 'update', d);
}

const eventBody = (e: EventRec) => ({
  calendar: e.calendar, title: e.title, notes: e.notes, location: e.location, url: e.url, start: e.start, end: e.end, allDay: e.allDay,
  tz: e.tz, rrule: e.rrule, exdates: e.exdates ?? [], recurrenceParent: e.recurrenceParent, members: e.members, driver: e.driver,
  category: e.category, reminders: e.reminders ?? [], private: e.private, color: e.color, deleted: e.deleted,
});

export function saveEvent(e: EventRec) {
  commit('events', 'events', { ...e, family: state.family?.id ?? e.family, updated: new Date().toISOString() }, eventBody);
}
export function deleteEvent(e: EventRec) {
  put('events', { ...e, deleted: true });
  enqueue('events', e.id, 'update', { deleted: true });
  // Occurrences edited on their own belong to the series and go with it.
  for (const c of state.events.filter((x) => x.recurrenceParent === e.id && !x.deleted)) {
    put('events', { ...c, deleted: true });
    enqueue('events', c.id, 'update', { deleted: true });
  }
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
/** Wall-clock minutes between two instants as seen in tz (so DST doesn't skew a shift). */
function wallDelta(from: Date, to: Date, tz: string) {
  return LocalDateTime.fromDate(to, tz).minuteNumber - LocalDateTime.fromDate(from, tz).minuteNumber;
}
function shiftKey(key: string, minutes: number, allDay: boolean): string | null {
  const k = LocalDateTime.parse(key);
  return k ? k.addMinutes(minutes).key(allDay) : null;
}
/** "Save for all events": move the series by the same wall-clock shift and keep its skipped dates skipped. */
export function saveSeriesEdit(o: Occurrence, edited: EventRec) {
  const master = state.events.find((x) => x.id === o.event.id);
  if (!master) return;
  const tz = validTZ(master.tz);
  const newStart = pbDate(edited.start)!, newEnd = pbDate(edited.end)!;
  const delta = wallDelta(o.start, newStart, tz);
  const ms = LocalDateTime.fromDate(pbDate(master.start)!, tz).addMinutes(delta).toDate(tz);
  const dur = newEnd.getTime() - newStart.getTime();
  const exdates = (master.exdates ?? []).map((k) => shiftKey(k, delta, edited.allDay)).filter((k): k is string => !!k);
  saveEvent({ ...edited, id: master.id, start: toPB(ms), end: toPB(new Date(ms.getTime() + dur)), exdates });
}
/** "Save for future events": end the old series the day before and start a new one that keeps the later skips (and COUNT). */
export function saveFollowingEdit(o: Occurrence, edited: EventRec) {
  const master = state.events.find((x) => x.id === o.event.id);
  if (!master) return;
  const tz = validTZ(master.tz);
  const delta = wallDelta(o.start, pbDate(edited.start)!, tz);
  const exdates = (master.exdates ?? []).filter((k) => k >= o.key).map((k) => shiftKey(k, delta, edited.allDay)).filter((k): k is string => !!k);
  let rrule = edited.rrule;
  const oldRule = RRule.parse(master.rrule), newRule = RRule.parse(edited.rrule);
  if (oldRule?.count !== undefined && newRule) {
    // Occurrences already used up before the split come off the count.
    const before = expand({ start: LocalDateTime.fromDate(pbDate(master.start)!, tz), durationMinutes: durationMinutes(master), allDay: master.allDay, tz,
      rrule: master.rrule, exdates: new Set(), rangeStart: pbDate(master.start)!, rangeEnd: o.start }).filter((x) => x.key(master.allDay) < o.key).length;
    newRule.count = Math.max(1, oldRule.count - before);
    rrule = newRule.toString();
  }
  endSeries(o);
  saveEvent({ ...edited, id: newId(), rrule, exdates, recurrenceParent: '' });
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
  commit('tasks', 'tasks', { ...t, family: state.family?.id ?? t.family, updated: new Date().toISOString() }, taskBody);
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
  commit('groceryItems', 'grocery', { ...g, family: state.family?.id ?? g.family, updated: new Date().toISOString() }, groceryBody);
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

// `family` goes only on create; updates send just the changed fields.
export function saveList(l: ListRec) {
  commit('lists', 'lists', l, (x) => ({
    name: x.name, kind: x.kind, icon: x.icon, color: x.color, owner: x.owner, sharing: x.sharing,
    storeOrder: x.storeOrder ?? [], sortOrder: x.sortOrder, archived: x.archived, deleted: x.deleted,
  }), { family: state.family?.id });
}
export function saveCalendar(c: CalendarRec) {
  commit('calendars', 'calendars', c, (x) => ({
    name: x.name, color: x.color, kind: x.kind, owner: x.owner, sharing: x.sharing,
    defaultReminders: x.defaultReminders ?? [], ...(x.sourceUrl !== undefined ? { sourceUrl: x.sourceUrl } : {}), sortOrder: x.sortOrder, deleted: x.deleted,
  }), { family: state.family?.id });
}
export function saveCard(c: CardRec) {
  commit('infoCards', 'cards', c, (x) => ({
    title: x.title, body: x.body, kind: x.kind || 'note', icon: x.icon, phone: x.phone, address: x.address,
    aboutMember: x.aboutMember, pinned: x.pinned, sharing: x.sharing, sortOrder: x.sortOrder, deleted: x.deleted,
  }), { family: state.family?.id });
}
export function saveMember(m: Member) {
  const isNew = !state.members.some((x) => x.id === m.id);
  const canSetRole = isNew || (isAdmin() && m.user !== state.user?.id);
  commit('memberships', 'members', m, (x) => ({
    name: x.name, color: x.color, emoji: x.emoji, birthday: x.birthday, notifyAll: x.notifyAll, sortOrder: x.sortOrder, ...(canSetRole ? { role: x.role } : {}),
  }), { family: state.family?.id });
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
// ---- AI assistant (MCP) keys: per person, not synced, secret shown once ----
export interface AgentKey { id: string; name: string; hint: string; lastUsedAt: string; created: string }
export const mcpURL = `${apiBase}/api/roost/mcp`;
export async function listAgentKeys(): Promise<AgentKey[]> {
  return pb.collection('agentKeys').getFullList<AgentKey>({ sort: '-created', filter: pb.filter('user = {:u}', { u: state.user?.id ?? '' }) });
}
export async function createAgentKey(name: string): Promise<AgentKey & { token: string }> {
  return pb.send('/api/roost/agent-keys', { method: 'POST', body: { family: state.family!.id, name } });
}
export async function revokeAgentKey(id: string) { await pb.collection('agentKeys').delete(id); }
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
  const liveCals = new Set(state.calendars.filter((c) => !c.deleted).map((c) => c.id));
  const liveLists = new Set(state.lists.filter((l) => !l.deleted).map((l) => l.id));
  const relevant = state.events.filter((e) => !e.deleted && liveCals.has(e.calendar) && Array.isArray(e.reminders) && e.reminders.length > 0 &&
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
    if (t.deleted || t.completed || !t.due || !liveLists.has(t.list) || !Array.isArray(t.reminders) || !t.reminders.length) continue;
    if (!(mine?.notifyAll || (mine && t.assignees.includes(mine.id)) || (!t.assignees.length && t.createdBy === state.user?.id))) continue;
    const due = LocalDateTime.parse(t.due);
    if (!due) continue;
    for (const m of t.reminders!) {
      // Timed: family time zone. Dated: offsets count from local midnight (−540 = 9 AM on the day).
      const at = (t.due.length > 10 ? due.toDate(familyTZ()) : due.toDate(localTZ())).getTime() - m * 60000;
      if (at > now && at < horizon) reminderTimers.push(window.setTimeout(() => notify(t.title, 'To-do due', `t.${t.id}.${m}`), at - now));
    }
  }
}

export const todayKey = () => LocalDateTime.fromDate(new Date(), localTZ()).date.toString();
export { LocalDate };
