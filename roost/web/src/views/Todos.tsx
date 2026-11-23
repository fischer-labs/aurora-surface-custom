import { useMemo, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { CalendarDays, Check, CircleAlert, Ellipsis, Flag, ListChecks, Luggage, Plus, Repeat, StickyNote, Sun, Trash2, User } from 'lucide-react';
import {
  canEditList, canEditTask, deleteTask, isAdmin, liveLists, me, member, membersOf, myRole, newTask, saveList, saveTask, sortedMembers,
  subtasks, todayKey, toggleTask, useRoost, type State,
} from '../data/store';
import { newId, type ListRec, type TaskRec } from '../data/models';
import { parseQuickAdd } from '../core/quickadd';
import { LocalDateTime, localTZ } from '../core/localdate';
import { AvatarStack, ColorPicker, Empty, Field, Modal, PeoplePicker, Seg, colorVar } from '../ui/kit';
import { PRESETS, REMINDERS_ALLDAY, REMINDERS_TIMED, detectPreset, dueText, presetLabel, presetRule, recurrenceText, reminderText, type RepeatPreset } from '../ui/format';
import { resolveMembers } from './QuickAdd';
import { SharingEditor } from './Family';

type Smart = 'today' | 'upcoming' | 'mine' | 'overdue' | 'flagged';
const SMART: { key: Smart; title: string; icon: typeof Sun; color: string }[] = [
  { key: 'today', title: 'Today', icon: Sun, color: 'blue' },
  { key: 'upcoming', title: 'Upcoming', icon: CalendarDays, color: 'violet' },
  { key: 'mine', title: 'Assigned to me', icon: User, color: 'green' },
  { key: 'overdue', title: 'Overdue', icon: CircleAlert, color: 'red' },
  { key: 'flagged', title: 'Priority', icon: Flag, color: 'red' },
];

export const taskSort = (a: TaskRec, b: TaskRec) =>
  Number(a.completed) - Number(b.completed) || Number(!a.due) - Number(!b.due) || a.due.localeCompare(b.due) || b.priority - a.priority || a.sortOrder - b.sortOrder;

function smartTasks(k: Smart, s: State): TaskRec[] {
  const today = todayKey();
  const open = s.tasks.filter((t) => !t.deleted && !t.completed && !t.parent);
  switch (k) {
    case 'today': return open.filter((t) => t.due && t.due.slice(0, 10) <= today).sort(taskSort);
    case 'upcoming': return open.filter((t) => t.due.slice(0, 10) > today).sort(taskSort);
    case 'mine': { const m = me(s); return open.filter((t) => m && t.assignees.includes(m.id)).sort(taskSort); }
    case 'overdue': return open.filter((t) => t.due && t.due.slice(0, 10) < today).sort(taskSort);
    case 'flagged': return open.filter((t) => t.priority > 0).sort((a, b) => b.priority - a.priority);
  }
}

export function Todos() {
  const s = useRoost();
  const { listId } = useParams();
  const nav = useNavigate();
  const [smart, setSmart] = useState<Smart | null>(listId ? null : 'today');
  const [newList, setNewList] = useState<ListRec | null>(null);
  const lists = liveLists(s).filter((l) => l.kind !== 'grocery');
  const list = listId ? s.lists.find((l) => l.id === listId) : undefined;
  const canCreate = !['relative', 'kid'].includes(myRole(s));

  return (
    <div className="page">
      <div className="pagehead"><h1 className="grow">To-Dos</h1></div>
      <div className="lists-layout">
        <aside>
          <div className="smart">
            {SMART.map(({ key, title, icon: Icon, color }) => (
              <button key={key} className={!list && smart === key ? 'on' : ''} onClick={() => { setSmart(key); nav('/todos'); }}>
                <div className="top"><i style={{ background: colorVar(color) }}><Icon size={16} /></i><b>{smartTasks(key, s).length}</b></div>
                <span>{title}</span>
              </button>
            ))}
          </div>
          <div className="listnav">
            <div className="row" style={{ justifyContent: 'space-between', padding: '8px 4px' }}>
              <b className="small faint" style={{ letterSpacing: '.05em' }}>LISTS</b>
              {canCreate && <button className="btn ghost sm" onClick={() => setNewList({
                id: newId(), family: s.family!.id, name: '', kind: 'todo', icon: 'checklist', color: 'blue', owner: me(s)?.id ?? '', sharing: null,
                storeOrder: [], viewers: [], editors: [], sortOrder: lists.length, archived: false, deleted: false,
              })}><Plus size={14} /> New</button>}
            </div>
            {lists.map((l) => {
              const n = s.tasks.filter((t) => t.list === l.id && !t.deleted && !t.completed && !t.parent).length;
              const Icon = l.kind === 'packing' ? Luggage : ListChecks;
              return (
                <button key={l.id} className={list?.id === l.id ? 'on' : ''} onClick={() => nav(`/todos/${l.id}`)}>
                  <i style={{ background: colorVar(l.color) }}><Icon size={14} /></i>{l.name}<span className="n">{n || ''}</span>
                </button>
              );
            })}
            {!lists.length && <p className="small muted" style={{ padding: 8 }}>No lists are shared with you yet. To-dos assigned to you appear in “Assigned to me”.</p>}
          </div>
        </aside>
        <section>
          {list ? <ListView list={list} /> : smart && <SmartView k={smart} />}
        </section>
      </div>
      {newList && <ListSettings list={newList} isNew onClose={() => setNewList(null)} />}
    </div>
  );
}

function SmartView({ k }: { k: Smart }) {
  const s = useRoost();
  const def = SMART.find((x) => x.key === k)!;
  const tasks = smartTasks(k, s);
  return (
    <>
      <div className="section-title" style={{ marginTop: 0 }}><h2>{def.title}</h2><span>{tasks.length}</span></div>
      {tasks.length ? <div className="card flush">{tasks.map((t) => <TaskRow key={t.id} task={t} showList />)}</div>
        : <div className="card"><Empty icon={<def.icon size={26} />} title="All clear">Nothing here right now.</Empty></div>}
    </>
  );
}

function ListView({ list }: { list: ListRec }) {
  const s = useRoost();
  const [text, setText] = useState('');
  const [showDone, setShowDone] = useState(false);
  const [settings, setSettings] = useState(false);
  const editable = canEditList(list, s);
  const all = s.tasks.filter((t) => t.list === list.id && !t.deleted && !t.parent);
  const open = all.filter((t) => !t.completed).sort(taskSort);
  const done = all.filter((t) => t.completed).sort((a, b) => b.completedAt.localeCompare(a.completedAt));
  const p = useMemo(() => parseQuickAdd(text, LocalDateTime.fromDate(new Date(), localTZ()), 'task'), [text]);

  function add() {
    if (!text.trim()) return;
    const due = p.date ? (p.timeMinutes !== null ? `${p.date}T${String(Math.floor(p.timeMinutes / 60)).padStart(2, '0')}:${String(p.timeMinutes % 60).padStart(2, '0')}` : p.date.toString()) : '';
    saveTask({
      ...newTask(list.id, p.title || text.trim()), due, rrule: p.rrule ?? '', priority: p.priority,
      assignees: resolveMembers(p.mentions, s).map((m) => m.id), reminders: p.reminders.length ? p.reminders : p.timeMinutes !== null ? [0] : [],
    });
    setText('');
  }
  const hint = text && (p.date || p.rrule || p.priority || p.mentions.length)
    ? `→ ${p.title}${p.date ? ` · ${p.date.toString()}` : ''}${p.rrule ? ` · ${recurrenceText(p.rrule)}` : ''}${p.priority ? ` · ${'!'.repeat(p.priority)}` : ''}${p.mentions.length ? ` · @${p.mentions.join(' @')}` : ''}`
    : null;

  return (
    <>
      <div className="section-title" style={{ marginTop: 0 }}>
        <h2 className="row"><span className="dot" style={{ background: colorVar(list.color) }} />{list.name}</h2>
        {(isAdmin(s) || list.owner === me(s)?.id) && <button className="btn ghost sm" onClick={() => setSettings(true)}><Ellipsis size={16} /> Settings</button>}
      </div>
      {editable && (
        <div style={{ marginBottom: 14 }}>
          <div className="addbar">
            <Plus size={18} color="var(--accent)" />
            <input value={text} onChange={(e) => setText(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && add()}
              placeholder="Add a to-do — try “Call dentist fri 2pm !”" aria-label="Add a to-do" />
            <button className="btn primary sm" onClick={add} disabled={!text.trim()}>Add</button>
          </div>
          {hint && <div className="hint">{hint}</div>}
        </div>
      )}
      {open.length ? <div className="card flush">{open.map((t) => <TaskRow key={t.id} task={t} />)}</div>
        : <div className="card"><Empty icon={<Check size={26} />} title="Nothing to do">Nice.</Empty></div>}
      {done.length > 0 && (
        <>
          <button className="btn ghost sm" style={{ margin: '16px 0 8px' }} onClick={() => setShowDone(!showDone)}>
            {showDone ? 'Hide' : 'Show'} completed ({done.length})
          </button>
          {showDone && <div className="card flush">{done.slice(0, 50).map((t) => <TaskRow key={t.id} task={t} />)}</div>}
        </>
      )}
      {settings && <ListSettings list={list} isNew={false} onClose={() => setSettings(false)} />}
    </>
  );
}

export function TaskRow({ task, showList }: { task: TaskRec; showList?: boolean }) {
  const s = useRoost();
  const [edit, setEdit] = useState(false);
  const overdue = !task.completed && task.due && task.due.slice(0, 10) < todayKey();
  const subs = subtasks(task, s);
  const list = s.lists.find((l) => l.id === task.list);
  return (
    <div className={`trow${task.completed ? ' done' : ''}`}>
      <button className={`check${task.completed ? ' on' : ''}${task.priority > 0 ? ' prio' : ''}`} disabled={!canEditTask(task, s)}
        onClick={() => toggleTask(task)} aria-label={task.completed ? 'Mark not done' : 'Mark done'}>
        {task.completed && <Check size={14} strokeWidth={3} />}
      </button>
      <div className="body" onClick={() => setEdit(true)} role="button" tabIndex={0} onKeyDown={(e) => e.key === 'Enter' && setEdit(true)}>
        <div className="title">{task.priority > 0 && <span className="prio">{'!'.repeat(task.priority)}</span>}{task.title}</div>
        <div className="meta">
          {dueText(task) && <span className={`row${overdue ? ' overdue' : ''}`} style={{ gap: 4 }}>{task.rrule ? <Repeat size={12} /> : <CalendarDays size={12} />}{dueText(task)}</span>}
          {subs.length > 0 && <span>{subs.filter((x) => x.completed).length}/{subs.length} subtasks</span>}
          {task.notes && <StickyNote size={12} />}
          {showList && list && <span className="faint">{list.name}</span>}
        </div>
      </div>
      <AvatarStack members={membersOf(task.assignees, s)} size={22} max={3} />
      {edit && <TaskEditor task={task} isNew={false} onClose={() => setEdit(false)} />}
    </div>
  );
}

export function TaskEditor({ task, isNew, onClose }: { task: TaskRec; isNew: boolean; onClose: () => void }) {
  const s = useRoost();
  const [t, setT] = useState<TaskRec>(task);
  const [hasTime, setHasTime] = useState(task.due.length > 10);
  const [preset, setPreset] = useState<RepeatPreset>(() => detectPreset(task.rrule, new Date()));
  const [sub, setSub] = useState('');
  const up = (p: Partial<TaskRec>) => setT((x) => ({ ...x, ...p }));
  const editable = isNew || canEditTask(task, s);
  const date = t.due.slice(0, 10);
  const time = t.due.length > 10 ? t.due.slice(11, 16) : '09:00';
  const lists = liveLists(s).filter((l) => l.kind !== 'grocery' && canEditList(l, s));
  const dueDate = LocalDateTime.parse(t.due)?.toDate(localTZ()) ?? new Date();
  const createdBy = s.members.find((m) => m.user === task.createdBy);

  function save() {
    const out = { ...t, title: t.title.trim(), rrule: t.due ? (preset === 'custom' ? t.rrule : presetRule(preset, dueDate)) : '', reminders: t.due ? t.reminders : [] };
    saveTask(out);
    onClose();
  }
  return (
    <Modal title={isNew ? 'New to-do' : 'To-do'} onClose={onClose}
      actions={editable ? <button className="btn primary sm" disabled={!t.title.trim() || !t.list} onClick={save}>Save</button> : undefined}>
      <fieldset disabled={!editable} style={{ border: 0, padding: 0, margin: 0, display: 'flex', flexDirection: 'column', gap: 16 }}>
        <input className="input big" value={t.title} placeholder="To-do" onChange={(e) => up({ title: e.target.value })} autoFocus={isNew} />
        <textarea className="input" value={t.notes} placeholder="Notes" onChange={(e) => up({ notes: e.target.value })} />
        <div className="group">
          <div className="item" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <Field label="Due date"><input className="input" type="date" value={date} onChange={(e) => up({ due: e.target.value ? (hasTime ? `${e.target.value}T${time}` : e.target.value) : '' })} /></Field>
            <Field label="Time">
              <input className="input" type="time" value={hasTime ? time : ''} disabled={!date}
                onChange={(e) => { const v = e.target.value; setHasTime(!!v); up({ due: v ? `${date}T${v}` : date }); }} />
            </Field>
          </div>
          {date && (
            <div className="item"><Field label="Repeat">
              <select className="input" value={preset} onChange={(e) => setPreset(e.target.value as RepeatPreset)}>
                {PRESETS.map((p) => <option key={p} value={p}>{presetLabel(p, dueDate)}</option>)}
                {preset === 'custom' && <option value="custom">{recurrenceText(t.rrule) ?? 'Custom'}</option>}
              </select>
            </Field></div>
          )}
        </div>
        {date && (
          <Field label="Remind">
            <div className="row" style={{ flexWrap: 'wrap', gap: 6 }}>
              {(hasTime ? REMINDERS_TIMED : REMINDERS_ALLDAY).map((m) => {
                const on = (t.reminders ?? []).includes(m);
                return <button key={m} type="button" className={`btn sm${on ? ' primary' : ''}`}
                  onClick={() => up({ reminders: on ? (t.reminders ?? []).filter((x) => x !== m) : [...(t.reminders ?? []), m] })}>{reminderText(m, !hasTime)}</button>;
              })}
            </div>
          </Field>
        )}
        <Field label="Assign to"><PeoplePicker members={sortedMembers(s)} value={t.assignees} onChange={(v) => up({ assignees: v })} /></Field>
        <div className="group">
          <div className="item" style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <Field label="Priority">
              <Seg value={String(t.priority) as '0'} onChange={(v) => up({ priority: Number(v) })}
                options={[{ value: '0', label: 'None' }, { value: '1', label: '!' }, { value: '2', label: '!!' }, { value: '3', label: '!!!' }] as { value: '0'; label: string }[]} />
            </Field>
            <Field label="List">
              <select className="input" value={t.list} onChange={(e) => up({ list: e.target.value })}>
                {lists.map((l) => <option key={l.id} value={l.id}>{l.name}</option>)}
                {!lists.some((l) => l.id === t.list) && <option value={t.list}>{s.lists.find((l) => l.id === t.list)?.name ?? '—'}</option>}
              </select>
            </Field>
          </div>
        </div>
      </fieldset>
      {!isNew && (
        <Field label="Subtasks">
          <div className="card flush">
            {subtasks(task, s).map((x) => (
              <div key={x.id} className={`trow${x.completed ? ' done' : ''}`}>
                <button className={`check${x.completed ? ' on' : ''}`} onClick={() => toggleTask(x)} aria-label="Toggle subtask">{x.completed && <Check size={14} strokeWidth={3} />}</button>
                <div className="body"><div className="title">{x.title}</div></div>
                {editable && <button className="btn ghost icon" onClick={() => deleteTask(x)} aria-label="Delete subtask"><Trash2 size={15} /></button>}
              </div>
            ))}
            {editable && (
              <div className="trow">
                <Plus size={18} color="var(--ink3)" />
                <input className="input" style={{ border: 0, minHeight: 30, padding: 0 }} placeholder="Add subtask" value={sub} onChange={(e) => setSub(e.target.value)}
                  onKeyDown={(e) => { if (e.key === 'Enter' && sub.trim()) { saveTask({ ...newTask(task.list, sub.trim()), parent: task.id }); setSub(''); } }} />
              </div>
            )}
          </div>
        </Field>
      )}
      {!isNew && createdBy && <div className="faint small">Added by {createdBy.name}{member(task.completedBy, s) ? '' : ''}</div>}
      {!isNew && editable && <button className="btn danger" onClick={() => { deleteTask(task); onClose(); }}><Trash2 size={16} /> Delete to-do</button>}
    </Modal>
  );
}

export function ListSettings({ list, isNew, onClose }: { list: ListRec; isNew: boolean; onClose: () => void }) {
  const s = useRoost();
  const [l, setL] = useState<ListRec>(list);
  const [confirm, setConfirm] = useState(false);
  const up = (p: Partial<ListRec>) => setL((x) => ({ ...x, ...p }));
  return (
    <Modal title={isNew ? 'New list' : 'List settings'} onClose={onClose}
      actions={<button className="btn primary sm" disabled={!l.name.trim()} onClick={() => { saveList(l); onClose(); }}>Save</button>}>
      <input className="input big" placeholder="List name" value={l.name} onChange={(e) => up({ name: e.target.value })} autoFocus />
      {isNew && <Seg value={l.kind} onChange={(v) => up({ kind: v })} options={[{ value: 'todo', label: 'To-do' }, { value: 'grocery', label: 'Groceries' }, { value: 'packing', label: 'Packing' }]} />}
      <Field label="Color"><ColorPicker value={l.color} onChange={(c) => up({ color: c })} /></Field>
      {(isAdmin(s) || isNew) && (
        <Field label="Who can see this list">
          <SharingEditor sharing={l.sharing} onChange={(v) => up({ sharing: v })} resource="list" subkind={l.kind} ownerId={l.owner} />
        </Field>
      )}
      {!isNew && (confirm
        ? <button className="btn danger" onClick={() => { saveList({ ...l, deleted: true }); onClose(); }}>Really delete “{l.name}”?</button>
        : <button className="btn danger" onClick={() => setConfirm(true)}><Trash2 size={16} /> Delete list</button>)}
    </Modal>
  );
}
