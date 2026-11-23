import { useState } from 'react';
import { Bell, CalendarPlus, Car, Link as LinkIcon, Lock, MapPin, Pencil, Repeat, Trash2 } from 'lucide-react';
import {
  canEditEvent, deleteEvent, deleteOccurrence, editableCalendars, endSeries, member, membersOf, newEvent, saveEvent,
  saveFollowingEdit, saveOccurrenceEdit, saveSeriesEdit, sortedMembers, useRoost, type Occurrence,
} from '../data/store';
import { pbDate, toPB, type EventRec } from '../data/models';
import { RRule } from '../core/recurrence';
import { LocalDateTime, localTZ } from '../core/localdate';
import { Avatar, Chip, Dot, Field, Modal, PeoplePicker, Toggle, colorVar } from '../ui/kit';
import {
  PRESETS, REMINDERS_ALLDAY, REMINDERS_TIMED, detectPreset, fromInput, presetLabel, presetRule, rangeText, recurrenceText, reminderText,
  toInputDT, toInputDate, type RepeatPreset,
} from '../ui/format';
import type { CalItem } from '../ui/calitems';
import { TaskEditor } from './Todos';

export function ItemModal({ item, onClose }: { item: CalItem; onClose: () => void }) {
  if (item.task) return <TaskEditor task={item.task} isNew={false} onClose={onClose} />;
  if (item.occ) return <EventDetail occ={item.occ} onClose={onClose} />;
  return null;
}

export function EventDetail({ occ, onClose }: { occ: Occurrence; onClose: () => void }) {
  const s = useRoost();
  const e = s.events.find((x) => x.id === occ.event.id) ?? occ.event;
  const [editing, setEditing] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const cal = s.calendars.find((c) => c.id === e.calendar);
  const editable = canEditEvent(e, s);
  const recurring = !!e.rrule;
  const driver = member(e.driver, s);
  if (editing) return <EventEditor event={e} isNew={false} occ={recurring ? occ : undefined} onClose={onClose} />;

  return (
    <Modal title="" onClose={onClose} actions={editable ? <button className="btn sm" onClick={() => setEditing(true)}><Pencil size={14} /> Edit</button> : undefined}>
      <div>
        <div className="row small muted" style={{ fontWeight: 650 }}>
          <Dot color={cal?.color ?? 'brown'} /> {cal?.name ?? 'Calendar'}
          {e.private && <Chip icon={<Lock size={11} />}>Private</Chip>}
          {e.source === 'ics' && <Chip icon={<LinkIcon size={11} />}>Subscribed</Chip>}
        </div>
        <h2 style={{ fontSize: 26, margin: '6px 0' }}>{e.busy ? 'Busy' : e.title}</h2>
        <div style={{ fontWeight: 600 }}>{occ.start.toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric', year: 'numeric' })}</div>
        <div className="muted">{rangeText(occ.start, occ.end, e.allDay)}</div>
        {recurring && <div className="row small muted" style={{ marginTop: 4 }}><Repeat size={13} /> {recurrenceText(e.rrule)}</div>}
      </div>
      {(e.members.length > 0 || driver) && (
        <div className="group">
          {membersOf(e.members, s).map((m) => <div key={m.id} className="item"><Avatar member={m} size={28} /> {m.name}</div>)}
          {driver && <div className="item"><Car size={18} color={colorVar(driver.color)} /> {driver.name} is driving</div>}
        </div>
      )}
      {(e.location || e.url) && (
        <div className="group">
          {e.location && <a className="item loc" href={`https://maps.apple.com/?q=${encodeURIComponent(e.location)}`} target="_blank" rel="noreferrer"><MapPin size={16} /> {e.location}</a>}
          {e.url && <a className="item" href={e.url} target="_blank" rel="noreferrer"><LinkIcon size={16} /> {safeHost(e.url)}</a>}
        </div>
      )}
      {e.notes && <div className="card" style={{ whiteSpace: 'pre-wrap' }}>{e.notes}</div>}
      {(e.reminders?.length ?? 0) > 0 && (
        <div className="row small muted" style={{ flexWrap: 'wrap' }}><Bell size={14} /> {(e.reminders ?? []).map((m) => reminderText(m, e.allDay)).join(' · ')}</div>
      )}
      {!e.busy && (
        <div className="row" style={{ flexWrap: 'wrap' }}>
          <button className="btn" onClick={() => downloadICS(e, occ)}><CalendarPlus size={16} /> Add to my calendar</button>
          {editable && <button className="btn danger" onClick={() => setConfirm(true)}><Trash2 size={16} /> Delete</button>}
        </div>
      )}
      {confirm && (
        <div className="card stack">
          <b>Delete {recurring ? 'which events' : 'this event'}?</b>
          {recurring ? (
            <>
              <button className="btn danger" onClick={() => { deleteOccurrence(occ); onClose(); }}>Only this one</button>
              <button className="btn danger" onClick={() => { endSeries(occ); onClose(); }}>This and following</button>
              <button className="btn danger" onClick={() => { deleteEvent(e); onClose(); }}>All events in the series</button>
            </>
          ) : <button className="btn danger" onClick={() => { deleteEvent(e); onClose(); }}>Delete</button>}
          <button className="btn ghost" onClick={() => setConfirm(false)}>Cancel</button>
        </div>
      )}
    </Modal>
  );
}

function safeHost(u: string) { try { return new URL(u).host; } catch { return u; } }

/** Downloads a single-event .ics (one occurrence) to import into any calendar app. */
function downloadICS(e: EventRec, o: Occurrence) {
  const z = (d: Date) => d.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
  const dz = (d: Date) => `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}`;
  const esc = (t: string) => t.replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\n/g, '\\n');
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Roost//EN', 'BEGIN:VEVENT', `UID:${e.id}-${o.key}@roost`, `DTSTAMP:${z(new Date())}`,
    e.allDay ? `DTSTART;VALUE=DATE:${dz(o.start)}` : `DTSTART:${z(o.start)}`, e.allDay ? `DTEND;VALUE=DATE:${dz(o.end)}` : `DTEND:${z(o.end)}`,
    `SUMMARY:${esc(e.title)}`, ...(e.location ? [`LOCATION:${esc(e.location)}`] : []), ...(e.notes ? [`DESCRIPTION:${esc(e.notes)}`] : []),
    ...(e.reminders ?? []).flatMap((m) => ['BEGIN:VALARM', 'ACTION:DISPLAY', `DESCRIPTION:${esc(e.title)}`, `TRIGGER:-PT${Math.max(m, 0)}M`, 'END:VALARM']),
    'END:VEVENT', 'END:VCALENDAR'];
  const url = URL.createObjectURL(new Blob([lines.join('\r\n')], { type: 'text/calendar' }));
  const a = document.createElement('a');
  a.href = url; a.download = `${e.title.replace(/[^\w]+/g, '-').slice(0, 40) || 'event'}.ics`; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}

export function EventEditor({ event, isNew, occ, onClose }: { event: EventRec; isNew: boolean; occ?: Occurrence; onClose: () => void }) {
  const s = useRoost();
  const [e, setE] = useState<EventRec>(() => {
    if (!occ) return event;
    // Editing an occurrence: start from that occurrence's times.
    return { ...event, start: toPB(occ.start), end: toPB(occ.end) };
  });
  const start = pbDate(e.start) ?? new Date();
  const end = pbDate(e.end) ?? start;
  const [preset, setPreset] = useState<RepeatPreset>(() => detectPreset(event.rrule, start));
  const [until, setUntil] = useState<string>(() => {
    const r = RRule.parse(event.rrule);
    return r?.until?.kind === 'date' ? r.until.date.toString() : '';
  });
  const [scope, setScope] = useState(false);
  const up = (p: Partial<EventRec>) => setE((x) => ({ ...x, ...p }));
  const cals = editableCalendars(s);

  function setAllDay(on: boolean) {
    if (on) {
      const d0 = new Date(start); d0.setHours(0, 0, 0, 0);
      const d1 = new Date(end.getTime() - 1); d1.setHours(0, 0, 0, 0);
      up({ allDay: true, start: toPB(d0), end: toPB(new Date(Math.max(d1.getTime(), d0.getTime()) + 86400000)), reminders: e.reminders?.length ? [900] : [] });
    } else {
      const d0 = new Date(start); d0.setHours(9, 0, 0, 0);
      up({ allDay: false, start: toPB(d0), end: toPB(new Date(d0.getTime() + 3600000)), reminders: e.reminders?.length ? [30] : [] });
    }
  }
  function setStart(d: Date | null) {
    if (!d) return;
    const dur = end.getTime() - start.getTime();
    up({ start: toPB(d), end: toPB(new Date(d.getTime() + Math.max(dur, e.allDay ? 86400000 : 0))) });
  }
  function composed(): string {
    const base = preset === 'custom' ? e.rrule : presetRule(preset, start);
    const r = RRule.parse(base);
    if (!r) return '';
    const u = until ? LocalDateTime.parse(until) : null;
    // Keep "N times" unless an end date was chosen instead.
    r.count = u ? undefined : RRule.parse(event.rrule)?.count;
    r.until = u ? { kind: 'date', date: u.date } : undefined;
    return r.toString();
  }
  function save(which: 'one' | 'following' | 'all') {
    let out: EventRec = { ...e, title: e.title.trim(), rrule: composed(), tz: e.tz || localTZ() };
    if (out.allDay) {
      const a = pbDate(out.start)!, b = pbDate(out.end)!;
      if (b <= a) out = { ...out, end: toPB(new Date(a.getTime() + 86400000)) };
    } else if (pbDate(out.end)! < pbDate(out.start)!) out = { ...out, end: toPB(new Date(pbDate(out.start)!.getTime() + 3600000)) };
    if (occ && which === 'one') saveOccurrenceEdit(occ, out);
    else if (occ && which === 'following') saveFollowingEdit(occ, out);
    else if (occ && which === 'all') saveSeriesEdit(occ, out);
    else saveEvent(out);
    onClose();
  }
  const valid = e.title.trim() && e.calendar;
  const reminderOpts = e.allDay ? REMINDERS_ALLDAY : REMINDERS_TIMED;

  return (
    <Modal title={isNew ? 'New event' : 'Edit event'} onClose={onClose}
      actions={<button className="btn primary sm" disabled={!valid} onClick={() => (occ ? setScope(true) : save('all'))}>Save</button>}>
      {scope && (
        <div className="card stack">
          <b>This is a repeating event.</b>
          <button className="btn" onClick={() => save('one')}>Save for this event only</button>
          <button className="btn" onClick={() => save('following')}>Save for future events</button>
          <button className="btn" onClick={() => save('all')}>Save for all events</button>
        </div>
      )}
      <input className="input big" autoFocus placeholder="Title" value={e.title} onChange={(x) => up({ title: x.target.value })} />
      <input className="input" placeholder="Location" value={e.location} onChange={(x) => up({ location: x.target.value })} />
      <div className="group">
        <Toggle label="All day" checked={e.allDay} onChange={setAllDay} />
        <div className="item" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          <Field label="Starts">
            {e.allDay ? <input className="input" type="date" value={toInputDate(start)} onChange={(x) => setStart(fromInput(x.target.value))} />
              : <input className="input" type="datetime-local" value={toInputDT(start)} onChange={(x) => setStart(fromInput(x.target.value))} />}
          </Field>
          <Field label="Ends">
            {e.allDay ? <input className="input" type="date" value={toInputDate(new Date(end.getTime() - 86400000))} min={toInputDate(start)}
              onChange={(x) => { const d = fromInput(x.target.value); if (d) up({ end: toPB(new Date(d.getTime() + 86400000)) }); }} />
              : <input className="input" type="datetime-local" value={toInputDT(end)} min={toInputDT(start)}
                onChange={(x) => { const d = fromInput(x.target.value); if (d) up({ end: toPB(d) }); }} />}
          </Field>
        </div>
        <div className="item" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
          <Field label="Repeat">
            <select className="input" value={preset} onChange={(x) => setPreset(x.target.value as RepeatPreset)}>
              {PRESETS.map((p) => <option key={p} value={p}>{presetLabel(p, start)}</option>)}
              {preset === 'custom' && <option value="custom">{recurrenceText(e.rrule) ?? 'Custom'}</option>}
            </select>
          </Field>
          {preset !== 'none' && (
            <Field label="Until (optional)"><input className="input" type="date" value={until} min={toInputDate(start)} onChange={(x) => setUntil(x.target.value)} /></Field>
          )}
        </div>
      </div>
      <div className="group">
        <div className="item"><Field label="Calendar">
          <select className="input" value={e.calendar} onChange={(x) => up({ calendar: x.target.value })}>
            {cals.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </Field></div>
        <Toggle label="Private" hint="Others see “Busy” unless they can edit this calendar." checked={e.private} onChange={(v) => up({ private: v })} />
      </div>
      <Field label="Who's involved"><PeoplePicker members={sortedMembers(s)} value={e.members} onChange={(v) => up({ members: v })} /></Field>
      <Field label="Who's driving">
        <select className="input" value={e.driver} onChange={(x) => up({ driver: x.target.value })}>
          <option value="">Nobody</option>
          {sortedMembers(s).map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
        </select>
      </Field>
      <Field label="Reminders">
        <div className="row" style={{ flexWrap: 'wrap', gap: 6 }}>
          {reminderOpts.map((m) => {
            const on = (e.reminders ?? []).includes(m);
            return (
              <button key={m} type="button" className={`btn sm${on ? ' primary' : ''}`}
                onClick={() => up({ reminders: on ? (e.reminders ?? []).filter((x) => x !== m) : [...(e.reminders ?? []), m].sort((a, b) => a - b) })}>
                {reminderText(m, e.allDay)}
              </button>
            );
          })}
        </div>
      </Field>
      <input className="input" placeholder="Link (Zoom, tickets…)" value={e.url} onChange={(x) => up({ url: x.target.value })} />
      <textarea className="input" placeholder="Notes" value={e.notes} onChange={(x) => up({ notes: x.target.value })} />
    </Modal>
  );
}

export function NewEventButton({ at, label, className }: { at?: Date; label?: string; className?: string }) {
  const s = useRoost();
  const [ev, setEv] = useState<EventRec | null>(null);
  const cals = editableCalendars(s);
  return (
    <>
      <button className={className ?? 'btn'} disabled={!cals.length} onClick={() => {
        const d = at ?? (() => { const x = new Date(); x.setMinutes(0, 0, 0); x.setHours(x.getHours() + 1); return x; })();
        setEv(newEvent(d));
      }}>{label ?? 'New event'}</button>
      {ev && <EventEditor event={ev} isNew onClose={() => setEv(null)} />}
    </>
  );
}

export { PRESETS };
