import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Car, ChevronRight, MapPin, Plus, Repeat, ShoppingCart, Sparkles } from 'lucide-react';
import { liveCards, me, member, membersOf, todayKey, toggleTask, useRoost } from '../data/store';
import { AvatarStack, Chip, colorVar, fillVar, textOn, SyncBadge } from '../ui/kit';
import { buildItems, usePrefs, type CalItem } from '../ui/calitems';
import { fmtTime, startOfDay } from '../ui/format';
import { ItemModal } from './EventModal';
import { QuickAdd } from './QuickAdd';
import { TaskRow } from './Todos';
import { CardModal, CardIcon, cardPreview } from './Family';
import type { CardRec } from '../data/models';

export function Today() {
  const s = useRoost();
  const prefs = usePrefs();
  const nav = useNavigate();
  const [now, setNow] = useState(new Date());
  const [open, setOpen] = useState<CalItem | null>(null);
  const [card, setCard] = useState<CardRec | null>(null);
  const [quick, setQuick] = useState(false);
  useEffect(() => { const t = setInterval(() => setNow(new Date()), 60_000); return () => clearInterval(t); }, []);

  const dayStart = startOfDay(now);
  const items = useMemo(() => buildItems(s, prefs, dayStart, new Date(dayStart.getTime() + 86400000)).filter((i) => !i.task),
    [s, prefs, dayStart.getTime()]); // eslint-disable-line react-hooks/exhaustive-deps
  const next = items.find((i) => !i.allDay && i.end > now);
  const h = now.getHours();
  const first = me(s)?.name.split(' ')[0];
  const greeting = `${h < 12 ? 'Good morning' : h < 17 ? 'Good afternoon' : 'Good evening'}${first ? `, ${first}` : ''}`;
  const today = todayKey();
  const due = s.tasks.filter((t) => !t.deleted && !t.completed && t.due && t.due.slice(0, 10) <= today && !t.parent).sort((a, b) => a.due.localeCompare(b.due));
  const groceryList = s.lists.find((l) => l.kind === 'grocery' && !l.deleted);
  const groceries = s.grocery.filter((g) => g.list === groceryList?.id && !g.deleted && !g.checked);
  const pinned = liveCards(s).filter((c) => c.pinned);

  return (
    <div className="page">
      <div className="pagehead">
        <div className="hello grow">
          <small>{now.toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric' }).toUpperCase()}</small>
          <h1>{greeting}</h1>
          <div className="muted">{[
            items.length ? `${items.length} event${items.length === 1 ? '' : 's'}` : 'No events',
            due.length ? `${due.length} to-do${due.length === 1 ? '' : 's'} due` : '',
            groceries.length ? `${groceries.length} grocer${groceries.length === 1 ? 'y' : 'ies'}` : '',
          ].filter(Boolean).join(' · ')} <SyncBadge /></div>
        </div>
        <button className="btn primary fab-mobile" onClick={() => setQuick(true)}><Plus size={18} /> Quick add</button>
      </div>

      <div className="today-grid">
        <div>
          {next && <NextCard item={next} now={now} onOpen={() => setOpen(next)} />}
          <div className="section-title"><h2>Today</h2><span>{items.length ? `${items.length} event${items.length === 1 ? '' : 's'}` : ''}</span></div>
          {items.length === 0 ? (
            <div className="card row"><Sparkles size={18} color="var(--accent)" /> <span className="muted">Nothing scheduled. Enjoy the quiet.</span></div>
          ) : (
            <div className="card flush">{items.map((i) => <ItemRow key={i.id} item={i} onOpen={() => setOpen(i)} />)}</div>
          )}
        </div>
        <div>
          {due.length > 0 && (
            <>
              <div className="section-title"><h2>To-dos due</h2><span>{due.length}</span></div>
              <div className="card flush">
                {due.slice(0, 8).map((t) => <TaskRow key={t.id} task={t} showList />)}
                {due.length > 8 && <button className="btn ghost block" onClick={() => nav('/todos')}>See all {due.length}</button>}
              </div>
            </>
          )}
          {groceryList && (
            <>
              <div className="card tile" style={{ marginTop: 18 }} onClick={() => nav('/groceries')} role="button" tabIndex={0}>
                <div className="ico" style={{ background: 'var(--green)' }}><ShoppingCart size={20} /></div>
                <div style={{ flex: 1 }}>
                  <b>{groceryList.name}</b>
                  <div className="small muted">{groceries.length ? `${groceries.length} item${groceries.length === 1 ? '' : 's'} · ${new Set(groceries.map((g) => g.category)).size} aisles` : 'All stocked up'}</div>
                </div>
                <ChevronRight size={18} color="var(--ink3)" />
              </div>
            </>
          )}
          {pinned.length > 0 && (
            <>
              <div className="section-title"><h2>Care info</h2></div>
              <div className="info-cards">
                {pinned.map((c) => (
                  <div key={c.id} className="card info-card" onClick={() => setCard(c)} role="button" tabIndex={0}>
                    <CardIcon card={c} />
                    <div style={{ fontWeight: 650, marginTop: 8 }}>{c.title}</div>
                    {cardPreview(c) ? <p>{cardPreview(c)}</p> : <p className="faint">Tap to fill in</p>}
                  </div>
                ))}
              </div>
            </>
          )}
        </div>
      </div>
      {open && <ItemModal item={open} onClose={() => setOpen(null)} />}
      {card && <CardModal card={card} onClose={() => setCard(null)} />}
      {quick && <QuickAdd mode="event" onClose={() => setQuick(false)} />}
    </div>
  );
}

function NextCard({ item, now, onOpen }: { item: CalItem; now: Date; onOpen: () => void }) {
  const s = useRoost();
  const isNow = item.start <= now;
  const mins = Math.round((item.start.getTime() - now.getTime()) / 60000);
  const rel = mins < 60 ? `in ${Math.max(mins, 1)} min` : `in ${Math.floor(mins / 60)} hr${mins % 60 ? ` ${mins % 60} min` : ''}`;
  const driver = member(item.driver, s);
  return (
    <div className="next" role="button" tabIndex={0} onClick={onOpen}
      style={{ background: `linear-gradient(135deg, ${fillVar(item.color)}, color-mix(in srgb, ${fillVar(item.color)} 80%, #000))`, color: textOn(item.color) }}>
      <div style={{ flex: 1 }}>
        <div className="k">{isNow ? 'HAPPENING NOW' : 'UP NEXT'}</div>
        <h2>{item.title}</h2>
        <div>{isNow ? `until ${fmtTime(item.end)}` : `${fmtTime(item.start)} · ${rel}`}{item.location ? ` · ${item.location}` : ''}</div>
        {driver && <div className="row small" style={{ marginTop: 6, fontWeight: 700 }}><Car size={14} /> {driver.name} is driving</div>}
      </div>
      <AvatarStack members={membersOf(item.memberIds, s)} size={32} />
    </div>
  );
}

export function ItemRow({ item, onOpen }: { item: CalItem; onOpen: () => void }) {
  const s = useRoost();
  const driver = member(item.driver, s);
  return (
    <div className="irow" onClick={onOpen} role="button" tabIndex={0} onKeyDown={(e) => e.key === 'Enter' && onOpen()}>
      <div className="when">
        {item.allDay ? <span>all day</span> : <><b>{fmtTime(item.start)}</b>{!item.task && <span>{fmtTime(item.end)}</span>}</>}
      </div>
      <div className="bar" style={{ background: item.busy ? 'var(--ink3)' : colorVar(item.color) }} />
      <div className="body">
        <div className="title" style={{ color: item.busy ? 'var(--ink3)' : undefined }}>
          {item.task && (
            <button className="check" style={{ width: 20, height: 20, display: 'inline-grid', marginRight: 8, verticalAlign: -4 }}
              onClick={(e) => { e.stopPropagation(); toggleTask(item.task!); }} aria-label="Mark done" />
          )}
          {item.title} {item.recurring && <Repeat size={12} color="var(--ink3)" />}
        </div>
        <div className="meta">
          {item.location && <span className="row" style={{ gap: 4 }}><MapPin size={12} />{item.location}</span>}
          {driver && <Chip color={driver.color} icon={<Car size={12} />}>{driver.name}</Chip>}
        </div>
      </div>
      <AvatarStack members={membersOf(item.memberIds, s)} size={24} max={3} />
    </div>
  );
}
