import { useMemo, useState } from 'react';
import { Bell, CalendarDays, Car, Clock, Flag, Hash, Repeat, Sun, User } from 'lucide-react';
import { parseQuickAdd, qaEnd, qaStart, type QuickAddMode } from '../core/quickadd';
import { LocalDateTime, localTZ } from '../core/localdate';
import { canEditList, editableCalendars, liveLists, me, newEvent, newTask, saveEvent, saveTask, useRoost, type State } from '../data/store';
import { toPB, type Member } from '../data/models';
import { Chip, Modal, Seg } from '../ui/kit';
import { dayTitle, fmtTime, recurrenceText, reminderText } from '../ui/format';

const EXAMPLES: Record<QuickAddMode, string[]> = {
  event: ['Soccer every Tue 4-5:30pm @Emma driver:Dad', "Grandma's birthday dec 3", 'Book club every first tuesday 7pm', 'Dentist fri 3pm remind 1h'],
  task: ['Pay water bill due 12/1 !', 'Take out trash every weekday', 'Call pediatrician tomorrow 9am @Me', 'Renew passports !high #Household'],
};

export function resolveMembers(names: string[], s: State): Member[] {
  return names.flatMap((n) => {
    const l = n.toLowerCase();
    if (l === 'me') { const m = me(s); return m ? [m] : []; }
    const m = s.members.find((x) => x.name.toLowerCase() === l) ?? s.members.find((x) => x.name.toLowerCase().startsWith(l));
    return m ? [m] : [];
  });
}

export function QuickAdd({ mode: initial, onClose, defaultList }: { mode: QuickAddMode; onClose: () => void; defaultList?: string }) {
  const s = useRoost();
  const [mode, setMode] = useState<QuickAddMode>(initial);
  const [text, setText] = useState('');
  const p = useMemo(() => parseQuickAdd(text, LocalDateTime.fromDate(new Date(), localTZ()), mode), [text, mode]);
  const people = resolveMembers(p.mentions, s);
  const driver = p.driver ? resolveMembers([p.driver], s)[0] : undefined;
  const tz = localTZ();

  function add() {
    if (!p.title) return;
    if (mode === 'event') {
      const day = p.date ?? LocalDateTime.fromDate(new Date(), tz).date;
      const start = (qaStart(p) ?? new LocalDateTime(day)).toDate(tz);
      const cal = p.tag ? editableCalendars(s).find((c) => c.name.toLowerCase() === p.tag!.toLowerCase())?.id : undefined;
      const e = newEvent(start, p.allDay, cal);
      if (!e.calendar) return;
      const end = qaEnd(p);
      saveEvent({
        ...e, title: p.title, tz, rrule: p.rrule ?? '', members: people.map((m) => m.id), driver: driver?.id ?? '',
        end: end ? toPB(end.toDate(tz)) : p.allDay ? toPB(new LocalDateTime(day.addDays(1)).toDate(tz)) : e.end,
        reminders: p.reminders.length ? p.reminders : e.reminders,
      });
    } else {
      const lists = liveLists(s).filter((l) => l.kind !== 'grocery' && canEditList(l, s));
      const listId = (p.tag ? lists.find((l) => l.name.toLowerCase() === p.tag!.toLowerCase())?.id : undefined) ?? defaultList ?? lists[0]?.id;
      if (!listId) return;
      const st = qaStart(p);
      saveTask({
        ...newTask(listId, p.title), due: st ? (p.timeMinutes !== null ? st.toString() : st.date.toString()) : '', rrule: p.rrule ?? '',
        assignees: people.map((m) => m.id), priority: p.priority, reminders: p.reminders.length ? p.reminders : p.timeMinutes !== null ? [0] : [],
      });
    }
    onClose();
  }

  const start = qaStart(p)?.toDate(tz);
  const end = qaEnd(p)?.toDate(tz);
  return (
    <Modal title="Quick add" onClose={onClose} actions={<button className="btn primary sm" disabled={!p.title} onClick={add}>Add</button>}>
      <Seg value={mode} onChange={setMode} options={[{ value: 'event', label: 'Event' }, { value: 'task', label: 'To-do' }]} />
      <input className="input big" autoFocus value={text} onChange={(e) => setText(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && add()}
        placeholder={mode === 'event' ? 'Dentist Friday 3pm @Emma' : 'Call pediatrician tomorrow 9am !!'} aria-label="Describe it in plain English" />
      {text && (
        <div className="row" style={{ flexWrap: 'wrap', gap: 6 }}>
          <b style={{ marginRight: 4 }}>{p.title || '—'}</b>
          {start && <Chip accent icon={<CalendarDays size={12} />}>{dayTitle(start)}</Chip>}
          {start && p.timeMinutes !== null && <Chip accent icon={<Clock size={12} />}>{fmtTime(start)}{end ? `–${fmtTime(end)}` : ''}</Chip>}
          {start && p.timeMinutes === null && mode === 'event' && <Chip accent icon={<Sun size={12} />}>All day</Chip>}
          {p.rrule && <Chip accent icon={<Repeat size={12} />}>{recurrenceText(p.rrule)}</Chip>}
          {people.map((m) => <Chip key={m.id} color={m.color} icon={<User size={12} />}>{m.name}</Chip>)}
          {driver && <Chip color={driver.color} icon={<Car size={12} />}>{driver.name}</Chip>}
          {p.tag && <Chip icon={<Hash size={12} />}>{p.tag}</Chip>}
          {p.priority > 0 && <Chip color="orange" icon={<Flag size={12} />}>{'!'.repeat(p.priority)}</Chip>}
          {p.reminders.map((r) => <Chip key={r} icon={<Bell size={12} />}>{reminderText(r, false)}</Chip>)}
        </div>
      )}
      <div className="stack" style={{ gap: 4 }}>
        <span className="faint small" style={{ fontWeight: 700 }}>TRY</span>
        {EXAMPLES[mode].map((x) => (
          <button key={x} className="btn ghost sm" style={{ justifyContent: 'flex-start' }} onClick={() => setText(x)}>{x}</button>
        ))}
        <span className="faint small">@name assigns · driver:Name · #List or #Calendar · ! to !!! priority · “remind 30m”</span>
      </div>
    </Modal>
  );
}
