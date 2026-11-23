import { useEffect, useMemo, useRef, useState, type MouseEvent } from 'react';
import { ChevronLeft, ChevronRight, Filter, House, Plus, Text } from 'lucide-react';
import { editableCalendars, liveCalendars, newEvent, sortedMembers, useRoost } from '../data/store';
import type { EventRec } from '../data/models';
import { layoutDay } from '../core/logic';
import { Avatar, AvatarStack, Dot, Menu, Seg, Toggle, colorVar, fillVar, textOn } from '../ui/kit';
import { buildItems, setPrefs, usePrefs, type CalItem } from '../ui/calitems';
import { addDays, addMonths, dayTitle, fmtHour, fmtTime, isToday, sameDay, startOfDay } from '../ui/format';
import { EventEditor, ItemModal } from './EventModal';
import { ItemRow } from './Today';
import { QuickAdd } from './QuickAdd';
import { membersOf } from '../data/store';

type Mode = 'day' | '3day' | 'week' | 'month' | 'agenda' | 'year' | 'people';
const MODES: { value: Mode; label: string }[] = [
  { value: 'day', label: 'Day' }, { value: '3day', label: '3 Days' }, { value: 'week', label: 'Week' }, { value: 'month', label: 'Month' },
  { value: 'agenda', label: 'Agenda' }, { value: 'year', label: 'Year' }, { value: 'people', label: 'People' },
];

export function CalendarPage() {
  const s = useRoost();
  const [mode, setModeState] = useState<Mode>(() => (localStorage.getItem('roost.calmode') as Mode) || (window.innerWidth < 700 ? 'agenda' : 'month'));
  const setMode = (m: Mode) => { setModeState(m); try { localStorage.setItem('roost.calmode', m); } catch { /* ignore */ } };
  const [anchor, setAnchor] = useState(() => startOfDay(new Date()));
  const [open, setOpen] = useState<CalItem | null>(null);
  const [draft, setDraft] = useState<EventRec | null>(null);
  const [quick, setQuick] = useState(false);
  const canAdd = editableCalendars(s).length > 0;

  const step = (dir: number) => {
    if (mode === 'month') setAnchor(addMonths(anchor, dir));
    else if (mode === 'year') setAnchor(new Date(anchor.getFullYear() + dir, 0, 1));
    else if (mode === 'week') setAnchor(addDays(anchor, 7 * dir));
    else if (mode === '3day') setAnchor(addDays(anchor, 3 * dir));
    else if (mode === 'agenda') setAnchor(addDays(anchor, 14 * dir));
    else setAnchor(addDays(anchor, dir));
  };
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if ((e.target as HTMLElement)?.closest('input, textarea, select, [role=dialog]')) return;
      if (e.key === 'ArrowLeft') step(-1);
      else if (e.key === 'ArrowRight') step(1);
      else if (e.key === 't') setAnchor(startOfDay(new Date()));
      else if (e.key === 'n' && canAdd) setQuick(true);
      else { const m = ({ d: 'day', w: 'week', m: 'month', a: 'agenda', y: 'year', p: 'people' } as Record<string, Mode>)[e.key]; if (m) setMode(m); }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  });

  const title = mode === 'year' ? String(anchor.getFullYear())
    : mode === 'day' || mode === 'people' ? anchor.toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric' })
      : anchor.toLocaleDateString([], { month: 'long', year: 'numeric' });
  const startNew = (d: Date) => { if (canAdd) setDraft(newEvent(d)); };

  return (
    <div className="page wide">
      <div className="calbar">
        <h1>{title}</h1>
        <div className="row" style={{ gap: 4 }}>
          <button className="btn icon" onClick={() => step(-1)} aria-label="Previous"><ChevronLeft size={18} /></button>
          <button className="btn sm" onClick={() => setAnchor(startOfDay(new Date()))}>Today</button>
          <button className="btn icon" onClick={() => step(1)} aria-label="Next"><ChevronRight size={18} /></button>
        </div>
        <div style={{ flex: 1 }} />
        <div className="only-desktop"><Seg value={mode} onChange={setMode} options={MODES} /></div>
        <select className="input only-mobile" style={{ width: 'auto', minHeight: 40 }} value={mode} onChange={(e) => setMode(e.target.value as Mode)} aria-label="Calendar view">
          {MODES.map((m) => <option key={m.value} value={m.value}>{m.label}</option>)}
        </select>
        <FilterMenu />
        <button className="btn primary fab-mobile only-mobile" onClick={() => setQuick(true)} disabled={!canAdd}><Plus size={18} /> New</button>
        <span className="only-desktop"><Menu trigger={(t) => <button className="btn primary" onClick={t} disabled={!canAdd}><Plus size={18} /> New</button>}>
          {(close) => (
            <>
              <button onClick={() => { close(); setQuick(true); }}><Text size={16} /> Quick add <span className="kbd" style={{ marginLeft: 'auto' }}>N</span></button>
              <button onClick={() => { close(); const d = new Date(anchor); d.setHours(isToday(anchor) ? new Date().getHours() + 1 : 9, 0, 0, 0); startNew(d); }}><Plus size={16} /> New event</button>
            </>
          )}
        </Menu></span>
      </div>
      {mode === 'month' && <MonthView anchor={anchor} onPick={setAnchor} onOpen={setOpen} onNew={startNew} />}
      {mode === 'agenda' && <AgendaView anchor={anchor} onOpen={setOpen} />}
      {mode === 'year' && <YearView anchor={anchor} onPickMonth={(d) => { setAnchor(d); setMode('month'); }} />}
      {(mode === 'day' || mode === '3day' || mode === 'week' || mode === 'people') && (
        <TimeGrid anchor={anchor} days={mode === 'week' ? 7 : mode === '3day' ? 3 : 1} byPeople={mode === 'people'} onOpen={setOpen} onNew={startNew}
          onPickDay={(d) => { setAnchor(d); setMode('day'); }} />
      )}
      {open && <ItemModal item={open} onClose={() => setOpen(null)} />}
      {draft && <EventEditor event={draft} isNew onClose={() => setDraft(null)} />}
      {quick && <QuickAdd mode="event" onClose={() => setQuick(false)}
        onMore={() => { setQuick(false); const d = new Date(anchor); d.setHours(isToday(anchor) ? new Date().getHours() + 1 : 9, 0, 0, 0); startNew(d); }} />}
    </div>
  );
}

function FilterMenu() {
  const s = useRoost();
  const p = usePrefs();
  const filtered = p.hidden.length > 0 || p.people.length > 0;
  return (
    <Menu trigger={(t) => <button className={`btn icon${filtered ? ' primary' : ''}`} onClick={t} aria-label="Filter"><Filter size={17} /></button>}>
      {() => (
        <div style={{ minWidth: 260, padding: '4px 8px' }}>
          <div className="label">People</div>
          {sortedMembers(s).map((m) => {
            const on = !p.people.length || p.people.includes(m.id);
            return (
              <button key={m.id} className={on ? 'on' : ''} onClick={() => {
                let next = p.people.length ? [...p.people] : s.members.map((x) => x.id);
                next = next.includes(m.id) ? next.filter((x) => x !== m.id) : [...next, m.id];
                setPrefs({ people: next.length === s.members.length ? [] : next });
              }}><Avatar member={m} size={22} /> {m.name}{on && <span style={{ marginLeft: 'auto' }}>✓</span>}</button>
            );
          })}
          <hr />
          <div className="label">Calendars</div>
          {liveCalendars(s).map((c) => {
            const on = !p.hidden.includes(c.id);
            return (
              <button key={c.id} className={on ? 'on' : ''} onClick={() => setPrefs({ hidden: on ? [...p.hidden, c.id] : p.hidden.filter((x) => x !== c.id) })}>
                <Dot color={c.color} /> {c.name}{on && <span style={{ marginLeft: 'auto' }}>✓</span>}
              </button>
            );
          })}
          <hr />
          <Toggle label="Show busy times" checked={p.showBusy} onChange={(v) => setPrefs({ showBusy: v })} />
          <Toggle label="Show to-dos" checked={p.showTasks} onChange={(v) => setPrefs({ showTasks: v })} />
          <Toggle label="Color by person" checked={p.byPerson} onChange={(v) => setPrefs({ byPerson: v })} />
        </div>
      )}
    </Menu>
  );
}

function useItems(from: Date, to: Date) {
  const s = useRoost();
  const p = usePrefs();
  return useMemo(() => buildItems(s, p, from, to), [s, p, from.getTime(), to.getTime()]); // eslint-disable-line react-hooks/exhaustive-deps
}

function weekStartOf(d: Date): Date {
  const ws = Number(localStorage.getItem('roost.weekStart') ?? 0);
  return addDays(startOfDay(d), -((d.getDay() - ws + 7) % 7));
}

// ---- month ----------------------------------------------------------------

function MonthView({ anchor, onPick, onOpen, onNew }: { anchor: Date; onPick: (d: Date) => void; onOpen: (i: CalItem) => void; onNew: (d: Date) => void }) {
  const first = weekStartOf(new Date(anchor.getFullYear(), anchor.getMonth(), 1));
  const days = Array.from({ length: 42 }, (_, i) => addDays(first, i));
  const items = useItems(days[0], addDays(days[41], 1));
  const byDay = useMemo(() => {
    const m = new Map<string, CalItem[]>();
    for (const it of items) {
      let d = startOfDay(it.start);
      const last = it.allDay ? new Date(it.end.getTime() - 1) : new Date(Math.max(it.start.getTime(), it.end.getTime() - 1));
      for (let n = 0; d <= last && n < 42; n++, d = addDays(d, 1)) {
        const k = d.toDateString();
        m.set(k, [...(m.get(k) ?? []), it]);
      }
    }
    return m;
  }, [items]);
  const selected = byDay.get(anchor.toDateString()) ?? [];
  const phone = window.innerWidth < 820;
  const max = 4;
  return (
    <>
      <div className="month" role="grid" aria-label="Month">
        {days.slice(0, 7).map((d) => <div key={'h' + d.getDay()} className="wd">{d.toLocaleDateString([], { weekday: 'short' })}</div>)}
        {days.map((d) => {
          const list = byDay.get(d.toDateString()) ?? [];
          const cls = ['mcell', d.getMonth() !== anchor.getMonth() && 'out', isToday(d) && 'today', sameDay(d, anchor) && 'sel'].filter(Boolean).join(' ');
          return (
            <div key={d.toISOString()} className={cls} role="gridcell" tabIndex={0} aria-label={`${d.toDateString()}, ${list.length} events`}
              onClick={() => onPick(d)} onDoubleClick={() => { const x = new Date(d); x.setHours(9); onNew(x); }}>
              <span className="num">{d.getDate()}</span>
              {list.slice(0, max).map((it) => <Pill key={it.id + d.getDate()} it={it} onOpen={onOpen} />)}
              {list.length > max && <span className="more">+{list.length - max}{phone ? '' : ' more'}</span>}
            </div>
          );
        })}
      </div>
      <div className="section-title"><h2>{dayTitle(anchor)}</h2><span>{selected.length ? `${selected.length} item${selected.length === 1 ? '' : 's'}` : ''}</span></div>
      {selected.length ? <div className="card flush">{selected.map((i) => <ItemRow key={i.id} item={i} onOpen={() => onOpen(i)} />)}</div>
        : <div className="card muted">Nothing planned. Double-click a day to add an event.</div>}
    </>
  );
}

function Pill({ it, onOpen }: { it: CalItem; onOpen: (i: CalItem) => void }) {
  const c = colorVar(it.color);
  const style = it.busy ? { background: 'var(--surface2)', color: 'var(--ink2)' }
    : it.allDay ? { background: fillVar(it.color), color: textOn(it.color) }
      : { background: `color-mix(in srgb, ${c} var(--tint), transparent)`, color: 'var(--ink)', '--c': c } as React.CSSProperties;
  return (
    <div className={`pill${it.busy ? ' busy' : it.allDay ? ' allday' : ' timed'}`} style={style} title={it.title}
      onClick={(e) => { e.stopPropagation(); onOpen(it); }}>
      {!it.allDay && <span className="t">{fmtTime(it.start).replace(':00', '').replace(/\s?(AM|PM)/i, (m) => m.trim()[0].toLowerCase())}</span>}
      {it.task ? '○ ' : ''}{it.title}
    </div>
  );
}

// ---- agenda ---------------------------------------------------------------

function AgendaView({ anchor, onOpen }: { anchor: Date; onOpen: (i: CalItem) => void }) {
  const [days, setDays] = useState(60);
  const items = useItems(anchor, addDays(anchor, days));
  const groups = useMemo(() => {
    const m = new Map<number, CalItem[]>();
    for (const it of items) {
      const k = Math.max(startOfDay(it.start).getTime(), anchor.getTime());
      m.set(k, [...(m.get(k) ?? []), it]);
    }
    return [...m.entries()].sort((a, b) => a[0] - b[0]);
  }, [items, anchor]);
  return (
    <div style={{ maxWidth: 820 }}>
      {!groups.length && <div className="card muted">Nothing in the next {days} days.</div>}
      {groups.map(([k, list]) => {
        const d = new Date(k);
        return (
          <section key={k}>
            <div className={`agenda-day${isToday(d) ? ' today' : ''}`}><b>{d.getDate()}</b><span className="muted" style={{ fontWeight: 650 }}>{dayTitle(d)}</span></div>
            <div className="card flush">{list.map((i) => <ItemRow key={i.id} item={i} onOpen={() => onOpen(i)} />)}</div>
          </section>
        );
      })}
      <button className="btn ghost block" style={{ marginTop: 16 }} onClick={() => setDays(days + 60)}>Show more</button>
    </div>
  );
}

// ---- year -----------------------------------------------------------------

function YearView({ anchor, onPickMonth }: { anchor: Date; onPickMonth: (d: Date) => void }) {
  const y0 = new Date(anchor.getFullYear(), 0, 1);
  const items = useItems(y0, new Date(anchor.getFullYear() + 1, 0, 1));
  const counts = useMemo(() => {
    const m = new Map<string, number>();
    for (const it of items) m.set(startOfDay(it.start).toDateString(), (m.get(startOfDay(it.start).toDateString()) ?? 0) + 1);
    return m;
  }, [items]);
  return (
    <div className="year">
      {Array.from({ length: 12 }, (_, i) => {
        const m0 = new Date(anchor.getFullYear(), i, 1);
        const lead = (m0.getDay() - Number(localStorage.getItem('roost.weekStart') ?? 0) + 7) % 7;
        const n = new Date(anchor.getFullYear(), i + 1, 0).getDate();
        const current = new Date().getFullYear() === anchor.getFullYear() && new Date().getMonth() === i;
        return (
          <div key={i} className="mini" onClick={() => onPickMonth(m0)} role="button" tabIndex={0}>
            <h3 style={{ textDecoration: current ? 'underline' : undefined, textDecorationColor: 'var(--accent)', textUnderlineOffset: 4 }}>{m0.toLocaleDateString([], { month: 'long' })}</h3>
            <div className="g">
              {Array.from({ length: lead }, (_, j) => <span key={'b' + j} />)}
              {Array.from({ length: n }, (_, j) => {
                const d = new Date(anchor.getFullYear(), i, j + 1);
                const c = counts.get(d.toDateString()) ?? 0;
                return (
                  <span key={j} style={{
                    background: c ? `color-mix(in srgb, var(--ink2) ${Math.min(10 + c * 10, 45)}%, transparent)` : undefined,
                    color: c ? 'var(--ink)' : 'var(--ink2)', outline: isToday(d) ? '1.5px solid var(--accent)' : undefined,
                  }}>{j + 1}</span>
                );
              })}
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ---- time grid (day / 3-day / week / people) -------------------------------

function TimeGrid({ anchor, days, byPeople, onOpen, onNew, onPickDay }: {
  anchor: Date; days: number; byPeople: boolean; onOpen: (i: CalItem) => void; onNew: (d: Date) => void; onPickDay: (d: Date) => void;
}) {
  const s = useRoost();
  const first = days === 7 ? weekStartOf(anchor) : startOfDay(anchor);
  const items = useItems(first, addDays(first, byPeople ? 1 : days));
  const scroller = useRef<HTMLDivElement>(null);
  const hour = 52;
  useEffect(() => {
    // Today in view → an hour before now; otherwise the first timed event (or 7 AM if later).
    // Never cut an event off at the top edge, which would leave an untitled block.
    const timed = items.filter((i) => !i.allDay);
    const hourOf = (d: Date) => Math.max(0, (d.getTime() - startOfDay(d).getTime()) / 3600000);
    const showsToday = Array.from({ length: byPeople ? 1 : days }, (_, i) => addDays(first, i)).some(isToday);
    let h = showsToday ? Math.max(0, new Date().getHours() - 1) : Math.min(7, ...timed.map((i) => hourOf(i.start)));
    for (const i of timed) {
      if (hourOf(i.start) < h && (sameDay(i.start, i.end) ? hourOf(i.end) : 24) > h) h = hourOf(i.start);
    }
    scroller.current?.scrollTo({ top: Math.max(0, h - 0.25) * hour });
  }, [anchor.getTime(), days, byPeople, items.length > 0]); // eslint-disable-line react-hooks/exhaustive-deps

  type Col = { key: string; day: Date; label: React.ReactNode; today: boolean; filter: (i: CalItem) => boolean };
  const cols: Col[] = byPeople
    ? [...sortedMembers(s).map((m) => ({
      key: m.id, day: first, today: false, filter: (i: CalItem) => i.memberIds.includes(m.id) || i.driver === m.id,
      label: <><Avatar member={m} size={26} /><div style={{ color: 'var(--ink)', marginTop: 3 }}>{m.name.split(' ')[0]}</div></>,
    })), {
      key: '_all', day: first, today: false, filter: (i: CalItem) => !i.memberIds.length && !i.driver,
      label: <><House size={22} color="var(--ink2)" /><div style={{ color: 'var(--ink)', marginTop: 3 }}>Everyone</div></>,
    }]
    : Array.from({ length: days }, (_, i) => {
      const d = addDays(first, i);
      return { key: d.toISOString(), day: d, today: isToday(d), filter: () => true,
        label: <>{d.toLocaleDateString([], { weekday: 'short' }).toUpperCase()}<div className="n">{d.getDate()}</div></> };
    });
  const template = `52px repeat(${cols.length}, minmax(${byPeople ? 110 : 60}px, 1fr))`;
  const now = new Date();

  const clickNew = (e: MouseEvent<HTMLDivElement>, day: Date) => {
    if ((e.target as HTMLElement).closest('.ev')) return;
    const rect = e.currentTarget.getBoundingClientRect();
    const mins = Math.floor(((e.clientY - rect.top) / hour) * 60 / 15) * 15;
    const d = new Date(day); d.setHours(0, mins, 0, 0);
    onNew(d);
  };

  return (
    <div className="tg">
      <div style={{ overflowX: 'auto' }}>
        <div style={{ minWidth: byPeople ? 52 + cols.length * 110 : undefined }}>
          <div className="tg-head" style={{ gridTemplateColumns: template }}>
            <div />
            {cols.map((c) => <div key={c.key} className={c.today ? 'today' : ''} onClick={() => !byPeople && days > 1 && onPickDay(c.day)}>{c.label}</div>)}
          </div>
          <div className="tg-allday" style={{ gridTemplateColumns: template }}>
            <div className="lbl">all-day</div>
            {cols.map((c) => (
              <div key={c.key}>
                {items.filter((i) => i.allDay && i.start < addDays(c.day, 1) && i.end > c.day && c.filter(i)).slice(0, 3).map((i) => (
                  <div key={i.id} className={`pill allday`} style={{ background: i.busy ? 'var(--ink3)' : fillVar(i.color), color: i.busy ? '#fff' : textOn(i.color) }} onClick={() => onOpen(i)}>{i.title}</div>
                ))}
              </div>
            ))}
          </div>
        </div>
      </div>
      <div className="tg-scroll" ref={scroller}>
        <div className="tg-body" style={{ gridTemplateColumns: template, height: hour * 24, minWidth: byPeople ? 52 + cols.length * 110 : undefined }}>
          <div className="tg-hours">{Array.from({ length: 24 }, (_, h) => <div key={h}>{h ? fmtHour(h) : ''}</div>)}</div>
          {cols.map((c, ci) => {
            const dayStart = c.day.getTime(), dayEnd = addDays(c.day, 1).getTime();
            const mine = items.filter((i) => !i.allDay && i.start.getTime() < dayEnd && i.end.getTime() > dayStart && c.filter(i));
            const mm = (d: Date) => Math.max(0, Math.min(1440, (d.getTime() - dayStart) / 60000));
            const lay = layoutDay(mine.map((i) => ({ id: i.id, start: mm(i.start), end: mm(i.end) })));
            return (
              <div key={c.key} className={`tg-col${isToday(c.day) && !byPeople ? ' today' : ''}`} onClick={(e) => clickNew(e, c.day)}>
                {mine.map((i) => {
                  const slot = lay[i.id] ?? { col: 0, cols: 1 };
                  const top = (mm(i.start) / 60) * hour;
                  const h = Math.max(((mm(i.end) - mm(i.start)) / 60) * hour, 20);
                  const c2 = colorVar(i.color);
                  return (
                    <div key={i.id} className={`ev${i.busy ? ' busy' : ''}`} onClick={() => onOpen(i)} title={`${i.title} · ${fmtTime(i.start)}`}
                      style={{ top, height: h - 2, left: `calc(${(slot.col / slot.cols) * 100}% + 2px)`, width: `calc(${100 / slot.cols}% - 4px)`,
                        background: `color-mix(in srgb, ${c2} 20%, var(--surface))`, borderLeftColor: c2 }}>
                      <b>{i.task ? '○ ' : ''}{i.title}</b>
                      {h > 34 && <small>{fmtTime(i.start)}{i.location ? ` · ${i.location}` : ''}</small>}
                      {h > 58 && i.memberIds.length > 0 && <div style={{ marginTop: 3 }}><AvatarStack members={membersOf(i.memberIds, s)} size={16} /></div>}
                    </div>
                  );
                })}
                {isToday(c.day) && <div className={`nowline${byPeople && ci > 0 ? ' nodot' : ''}`} style={{ top: ((now.getHours() * 60 + now.getMinutes()) / 60) * hour }} />}
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
