// Regression tests for the offline outbox (code review findings #2, #3, #4, #7).
// The store is a browser module, so give it the few globals it touches.
import { beforeEach, describe, expect, it } from 'vitest';

const ls = new Map<string, string>();
const g = globalThis as unknown as Record<string, unknown>;
g.localStorage = { getItem: (k: string) => ls.get(k) ?? null, setItem: (k: string, v: string) => void ls.set(k, v), removeItem: (k: string) => void ls.delete(k) };
g.window = globalThis;
g.addEventListener = () => undefined;
g.location = { origin: 'http://roost.test', protocol: 'http:' };
g.document = { addEventListener: () => undefined, visibilityState: 'hidden' };

const { ClientResponseError } = await import('pocketbase');
const store = await import('../src/data/store');

type Body = Record<string, unknown>;
const calls: { op: string; coll: string; id: string; body: Body }[] = [];
const server: Record<string, Body> = {};
const pending: (() => void)[] = [];
let failWith = 0;
let refreshFails = false;

Object.defineProperty(store.pb.authStore, 'isValid', { get: () => true });
const reply = <T,>(fn: () => T) => new Promise<T>((res, rej) => {
  pending.push(() => {
    if (failWith) rej(new ClientResponseError({ status: failWith, response: { message: `HTTP ${failWith}` } }));
    else res(fn());
  });
});
(store.pb as unknown as { collection: unknown }).collection = (coll: string) => ({
  update: (id: string, body: Body) => { calls.push({ op: 'update', coll, id, body: { ...body } }); return reply(() => (server[id] = { ...server[id], ...body, id })); },
  create: (body: Body) => { calls.push({ op: 'create', coll, id: body.id as string, body: { ...body } }); return reply(() => (server[body.id as string] = { ...body })); },
  delete: () => Promise.resolve(),
  getOne: (id: string) => (server[id] ? Promise.resolve({ ...server[id] }) : Promise.reject(new ClientResponseError({ status: 404 }))),
  getFullList: () => Promise.resolve([]),
  subscribe: () => Promise.resolve(() => undefined),
  authRefresh: () => (refreshFails ? Promise.reject(new ClientResponseError({ status: 401 })) : Promise.resolve({})),
});
(store.pb as unknown as { send: unknown }).send = () => Promise.resolve({ items: [] });

async function drain() {
  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 0));
    while (pending.length) pending.shift()!();
  }
}

const milk = {
  id: 'g1', family: 'f1', list: 'L1', name: 'Milk', quantity: 1, unit: '', note: '', category: 'dairy', categorySource: 'dictionary' as const,
  checked: false, checkedAt: '', addedBy: 'u1', sortOrder: 1, deleted: false,
};

describe('outbox', () => {
  beforeEach(async () => {
    await drain();
    calls.length = 0;
    failWith = 0;
    refreshFails = false;
  });

  it('never folds a second edit into the request already in flight', async () => {
    const st = store.getState() as unknown as { family: unknown; grocery: unknown[]; user: unknown };
    st.family = { id: 'f1', timezone: 'America/Chicago' };
    st.user = { id: 'u1' };
    st.grocery = [{ ...milk }];
    server.g1 = { ...milk };
    // The grocery item editor changes the aisle and then saves name + quantity in the same tick.
    store.setGroceryCategory(store.getState().grocery[0], 'pantry');
    store.saveGrocery({ ...store.getState().grocery[0], name: 'Oat milk', quantity: 3, category: 'pantry', categorySource: 'manual' });
    await drain();
    expect(server.g1).toMatchObject({ name: 'Oat milk', quantity: 3, category: 'pantry' });
    expect(store.getState().grocery[0]).toMatchObject({ name: 'Oat milk', quantity: 3, category: 'pantry' });
    expect(store.getState().outbox).toHaveLength(0);
  });

  it('sends only the fields that changed', async () => {
    store.saveGrocery({ ...store.getState().grocery[0], note: 'the barista kind' });
    await drain();
    const upd = calls.filter((c) => c.op === 'update' && c.coll === 'groceryItems');
    expect(upd).toHaveLength(1);
    expect(upd[0].body).toEqual({ note: 'the barista kind' });
    expect(upd[0].body).not.toHaveProperty('deleted');
    expect(upd[0].body).not.toHaveProperty('family');
  });

  it('keeps and retries a change when the server is briefly down (502)', async () => {
    failWith = 502;
    store.toggleGrocery(store.getState().grocery[0]);
    await drain();
    expect(store.getState().outbox).toHaveLength(1);
    expect(store.getState().sync).toBe('offline');
    failWith = 0;
    const done = store.flush();
    await drain();
    await done;
    expect(store.getState().outbox).toHaveLength(0);
    expect(server.g1.checked).toBe(true);
  });

  it('drops a refused change, says so, and restores the server copy', async () => {
    failWith = 403;
    store.saveGrocery({ ...store.getState().grocery[0], name: 'Forbidden milk' });
    await drain();
    failWith = 0;
    await drain();
    expect(store.getState().outbox).toHaveLength(0);
    expect(store.getState().rejected[0].what).toContain('Forbidden milk');
    expect(store.getState().grocery[0].name).toBe('Oat milk');
    store.dismissRejected();
  });

  it('keeps changes when the session expires instead of discarding them', async () => {
    failWith = 401;
    refreshFails = true;
    store.saveGrocery({ ...store.getState().grocery[0], quantity: 4 });
    await drain();
    expect(store.getState().needsSignIn).toBe(true);
    expect(store.getState().outbox).toHaveLength(1);
    // The unsent change survives a reload, for the same person only.
    const saved = JSON.parse(ls.get('roost.outbox.f1') ?? '{}');
    expect(saved.user).toBe('u1');
    expect(saved.ops).toHaveLength(1);
  });
});

describe('repeating event edits', () => {
  const tz = 'America/Chicago';
  const master = {
    id: 'ev1', family: 'f1', calendar: 'c1', title: 'Swim', notes: '', location: '', url: '', start: '2026-11-24 22:00:00.000Z', end: '2026-11-24 23:00:00.000Z',
    allDay: false, tz, rrule: 'FREQ=WEEKLY;COUNT=5', exdates: ['2026-12-01T16:00'], recurrenceParent: '', members: [], driver: '', category: '',
    reminders: [], private: false, color: '', source: 'roost' as const, createdBy: 'u1', deleted: false,
  };
  const keys = () => store.expandEvents(store.getState().events.filter((e) => !e.deleted), new Date('2026-11-20'), new Date('2027-02-01'))
    .map((o) => `${o.event.id === 'ev1' ? 'A' : 'B'} ${o.key}`);
  const setup = () => {
    const st = store.getState() as unknown as { events: unknown[]; calendars: unknown[] };
    st.calendars = [{ id: 'c1', family: 'f1', name: 'Family', kind: 'family', deleted: false }];
    st.events = [{ ...master }];
  };

  it('"all events" moves skipped dates along with the series and keeps COUNT', async () => {
    setup();
    const occ = store.expandEvents(store.getState().events, new Date('2026-11-20'), new Date('2026-11-30'))[0];
    store.saveSeriesEdit(occ, { ...store.getState().events[0], start: '2026-11-24 23:00:00.000Z', end: '2026-11-25 00:00:00.000Z' });
    await drain();
    const ev = store.getState().events[0];
    expect(ev.exdates).toEqual(['2026-12-01T17:00']);
    expect(ev.rrule).toContain('COUNT=5');
    expect(keys()).toEqual(['A 2026-11-24T17:00', 'A 2026-12-08T17:00', 'A 2026-12-15T17:00', 'A 2026-12-22T17:00']);
  });

  it('"this and following" splits the series without adding occurrences', async () => {
    setup();
    const third = store.expandEvents(store.getState().events, new Date('2026-12-07'), new Date('2026-12-09'))[0];
    expect(third.key).toBe('2026-12-08T16:00');
    store.saveFollowingEdit(third, { ...store.getState().events[0], title: 'Swim (new coach)', start: third.event.start.replace('11-24', '12-08'), end: third.event.end.replace('11-24', '12-08') });
    await drain();
    expect(keys()).toEqual(['A 2026-11-24T16:00', 'B 2026-12-08T16:00', 'B 2026-12-15T16:00', 'B 2026-12-22T16:00']);
  });

  it('deleting a series takes its separately edited occurrences with it', async () => {
    setup();
    const occ = store.expandEvents(store.getState().events, new Date('2026-12-14'), new Date('2026-12-16'))[0];
    store.saveOccurrenceEdit(occ, { ...store.getState().events[0], title: 'Swim (pool B)' });
    await drain();
    expect(store.getState().events.filter((e) => !e.deleted)).toHaveLength(2);
    store.deleteEvent(store.getState().events.find((e) => e.id === 'ev1')!);
    await drain();
    expect(store.getState().events.filter((e) => !e.deleted)).toHaveLength(0);
  });
});
