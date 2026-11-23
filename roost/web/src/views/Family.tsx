import { useEffect, useState } from 'react';
import { NavLink, Route, Routes } from 'react-router-dom';
import {
  Bell, CalendarClock, Clock, Copy, GraduationCap, HeartPulse, House, Link2, LogOut, Mail, MapPin, Phone, Pin, Plus, RefreshCw, Settings,
  StickyNote, Trash2, UserPlus, Users, type LucideIcon,
} from 'lucide-react';
import {
  canManageCalendar, createInvite, enableNotifications, ensureFeed, feedURL, isAdmin, liveCalendars, liveCards, me, member, myRole,
  refreshSubscription, removeMember, saveCalendar, saveCard, saveMember, signOut, sortedMembers, syncNow, useRoost,
} from '../data/store';
import { COLORS, newId, pbDate, type CalendarRec, type CardRec, type InviteRec, type Member } from '../data/models';
import { LEVEL_LABEL, ROLES, ROLE_BLURB, ROLE_LABEL, defaultLevel, type Level, type Role, type Sharing } from '../core/logic';
import { Avatar, ColorPicker, Dot, Empty, Field, Modal, Toggle, errorText, useToast } from '../ui/kit';
import { REMINDERS_TIMED, reminderText } from '../ui/format';

export function cardIcon(c: CardRec): LucideIcon {
  return ({ contact: Phone, medical: HeartPulse, school: GraduationCap, routine: Clock, home: House } as Record<string, LucideIcon>)[c.kind] ?? StickyNote;
}

export function FamilyPage() {
  const s = useRoost();
  const tabs = [
    { to: '/family', label: 'Care info', icon: HeartPulse },
    { to: '/family/people', label: 'People & roles', icon: Users },
    { to: '/family/calendars', label: 'Calendars', icon: CalendarClock },
    { to: '/family/settings', label: 'Settings', icon: Settings },
  ];
  return (
    <div className="page">
      <div className="pagehead">
        <div className="grow">
          <h1>{s.family?.name}</h1>
          <div className="muted small">You're {myRole(s) === 'relative' ? 'family' : ROLE_LABEL[myRole(s)].toLowerCase()} · {s.members.length} people</div>
        </div>
      </div>
      <div className="seg" style={{ marginBottom: 18 }}>
        {tabs.map(({ to, label, icon: Icon }) => (
          <NavLink key={to} to={to} end className={({ isActive }) => `segl${isActive ? ' on' : ''}`}>
            <Icon size={14} style={{ verticalAlign: -2, marginRight: 6 }} />{label}
          </NavLink>
        ))}
      </div>
      <Routes>
        <Route index element={<CareInfo />} />
        <Route path="people" element={<People />} />
        <Route path="calendars" element={<Calendars />} />
        <Route path="settings" element={<SettingsPane />} />
      </Routes>
    </div>
  );
}

// ---- care info -------------------------------------------------------------

function CareInfo() {
  const s = useRoost();
  const [open, setOpen] = useState<CardRec | null>(null);
  const [edit, setEdit] = useState<CardRec | null>(null);
  const cards = liveCards(s);
  return (
    <>
      <div className="section-title" style={{ marginTop: 0 }}>
        <h2>Care info</h2>
        {isAdmin(s) && <button className="btn sm" onClick={() => setEdit({
          id: newId(), family: s.family!.id, title: '', body: '', kind: 'contact', icon: '', phone: '', address: '', aboutMember: '', pinned: false,
          owner: '', sharing: null, viewers: [], editors: [], sortOrder: cards.length, deleted: false,
        })}><Plus size={14} /> New card</button>}
      </div>
      {!cards.length && <div className="card"><Empty icon={<HeartPulse size={26} />} title="No care info yet">Emergency contacts, allergies, routines and Wi-Fi for sitters and grandparents.</Empty></div>}
      <div className="grid2">
        {cards.map((c) => {
          const Icon = cardIcon(c);
          return (
            <div key={c.id} className="card info-card" role="button" tabIndex={0} onClick={() => setOpen(c)}>
              <div className="row"><Icon size={18} color="var(--accent)" /><b style={{ flex: 1 }}>{c.title}</b>{c.pinned && <Pin size={13} color="var(--ink3)" />}</div>
              {member(c.aboutMember, s) && <div className="small muted">About {member(c.aboutMember, s)!.name}</div>}
              <p>{c.body}</p>
            </div>
          );
        })}
      </div>
      {open && <CardModal card={open} onClose={() => setOpen(null)} onEdit={() => { setEdit(open); setOpen(null); }} />}
      {edit && <CardEditor card={edit} isNew={!s.cards.some((x) => x.id === edit.id)} onClose={() => setEdit(null)} />}
    </>
  );
}

export function CardModal({ card, onClose, onEdit }: { card: CardRec; onClose: () => void; onEdit?: () => void }) {
  const s = useRoost();
  const c = s.cards.find((x) => x.id === card.id) ?? card;
  const Icon = cardIcon(c);
  const canEdit = isAdmin(s) || (!!s.user && c.editors.includes(s.user.id));
  return (
    <Modal title="" onClose={onClose} actions={canEdit && onEdit ? <button className="btn sm" onClick={onEdit}>Edit</button> : undefined}>
      <div><Icon size={26} color="var(--accent)" /><h2 style={{ fontSize: 24, marginTop: 6 }}>{c.title}</h2></div>
      {(c.phone || c.address) && (
        <div className="group">
          {c.phone && <a className="item" href={`tel:${c.phone.replace(/[^\d+]/g, '')}`}><Phone size={16} /> {c.phone}</a>}
          {c.address && <a className="item" href={`https://maps.apple.com/?q=${encodeURIComponent(c.address)}`} target="_blank" rel="noreferrer"><MapPin size={16} /> {c.address}</a>}
        </div>
      )}
      {c.body && <div className="card" style={{ whiteSpace: 'pre-wrap' }}>{c.body}</div>}
    </Modal>
  );
}

function CardEditor({ card, isNew, onClose }: { card: CardRec; isNew: boolean; onClose: () => void }) {
  const s = useRoost();
  const [c, setC] = useState(card);
  const up = (p: Partial<CardRec>) => setC((x) => ({ ...x, ...p }));
  return (
    <Modal title={isNew ? 'New card' : 'Edit card'} onClose={onClose}
      actions={<button className="btn primary sm" disabled={!c.title.trim()} onClick={() => { saveCard(c); onClose(); }}>Save</button>}>
      <input className="input big" placeholder="Title (e.g. Pediatrician)" value={c.title} onChange={(e) => up({ title: e.target.value })} autoFocus />
      <div className="row">
        <Field label="Kind">
          <select className="input" value={c.kind} onChange={(e) => up({ kind: e.target.value })}>
            {['contact', 'medical', 'school', 'routine', 'home', 'note'].map((k) => <option key={k} value={k}>{k[0].toUpperCase() + k.slice(1)}</option>)}
          </select>
        </Field>
        <Field label="About">
          <select className="input" value={c.aboutMember} onChange={(e) => up({ aboutMember: e.target.value })}>
            <option value="">Everyone</option>
            {sortedMembers(s).map((m) => <option key={m.id} value={m.id}>{m.name}</option>)}
          </select>
        </Field>
      </div>
      <input className="input" placeholder="Phone" value={c.phone} onChange={(e) => up({ phone: e.target.value })} />
      <input className="input" placeholder="Address" value={c.address} onChange={(e) => up({ address: e.target.value })} />
      <textarea className="input" rows={6} placeholder="Details" value={c.body} onChange={(e) => up({ body: e.target.value })} />
      <Toggle label="Pin to Today" checked={c.pinned} onChange={(v) => up({ pinned: v })} />
      <Field label="Who can see this"><SharingEditor sharing={c.sharing} onChange={(v) => up({ sharing: v })} resource="info" subkind="card" ownerId={c.owner} /></Field>
      {!isNew && <button className="btn danger" onClick={() => { saveCard({ ...c, deleted: true }); onClose(); }}><Trash2 size={16} /> Delete card</button>}
    </Modal>
  );
}

// ---- sharing -------------------------------------------------------------

export function SharingEditor({ sharing, onChange, resource, subkind, ownerId }: {
  sharing: Sharing | null; onChange: (s: Sharing | null) => void; resource: 'calendar' | 'list' | 'info'; subkind: string; ownerId: string;
}) {
  const s = useRoost();
  const [more, setMore] = useState(false);
  const levels: Level[] = resource === 'calendar' ? ['none', 'busy', 'view', 'edit'] : ['none', 'view', 'edit'];
  const setRole = (r: Role, l: Level) => {
    const roles = { ...(sharing?.roles ?? {}) };
    if (l === defaultLevel(resource, subkind, r)) delete roles[r]; else roles[r] = l;
    onChange({ ...(sharing ?? {}), roles });
  };
  const setPerson = (id: string, l: Level | '') => {
    const people = { ...(sharing?.people ?? {}) };
    if (!l) delete people[id]; else people[id] = l;
    onChange({ ...(sharing ?? {}), people });
  };
  return (
    <div className="group">
      {ROLES.map((r) => (
        <div key={r} className="item">
          <div style={{ flex: 1 }}>
            <div style={{ fontWeight: 600 }}>{r === 'relative' ? 'Family (grandparents…)' : `${ROLE_LABEL[r]}s`}</div>
            <div className="faint small">{s.members.filter((m) => m.role === r).map((m) => m.name).join(', ') || '—'}</div>
          </div>
          <select className="input" style={{ width: 'auto' }} aria-label={`${ROLE_LABEL[r]} access`}
            value={sharing?.roles?.[r] ?? defaultLevel(resource, subkind, r)} onChange={(e) => setRole(r, e.target.value as Level)}>
            {levels.map((l) => <option key={l} value={l}>{LEVEL_LABEL[l]}</option>)}
          </select>
        </div>
      ))}
      <div className="item"><button type="button" className="btn ghost sm" onClick={() => setMore(!more)}>{more ? 'Hide' : 'Show'} exceptions for specific people</button></div>
      {more && sortedMembers(s).filter((m) => m.id !== ownerId).map((m) => (
        <div key={m.id} className="item">
          <Avatar member={m} size={24} /><span style={{ flex: 1 }}>{m.name}</span>
          <select className="input" style={{ width: 'auto' }} value={sharing?.people?.[m.id] ?? ''} onChange={(e) => setPerson(m.id, e.target.value as Level | '')}>
            <option value="">Role default</option>
            {levels.map((l) => <option key={l} value={l}>{LEVEL_LABEL[l]}</option>)}
          </select>
        </div>
      ))}
    </div>
  );
}

// ---- people --------------------------------------------------------------

function People() {
  const s = useRoost();
  const [edit, setEdit] = useState<Member | null>(null);
  const [invite, setInvite] = useState<{ profile?: Member } | null>(null);
  const admin = isAdmin(s);
  return (
    <>
      <div className="section-title" style={{ marginTop: 0 }}>
        <h2>People & roles</h2>
        {admin && (
          <div className="row">
            <button className="btn sm" onClick={() => setEdit({
              id: newId(), family: s.family!.id, user: '', name: '', role: 'kid', color: COLORS[s.members.length % COLORS.length], emoji: '', birthday: '', notifyAll: false, sortOrder: s.members.length,
            })}><Plus size={14} /> Profile (no login)</button>
            <button className="btn primary sm" onClick={() => setInvite({})}><UserPlus size={14} /> Invite</button>
          </div>
        )}
      </div>
      <div className="card flush">
        {sortedMembers(s).map((m) => (
          <div key={m.id} className="irow" role="button" tabIndex={0} onClick={() => setEdit(m)}>
            <Avatar member={m} size={38} />
            <div className="body">
              <div className="title">{m.name} {m.user === s.user?.id && <span className="chip accent">You</span>}</div>
              <div className="meta">{ROLE_LABEL[m.role]}{!m.user && ' · no login'}</div>
            </div>
          </div>
        ))}
      </div>
      <p className="faint small">Kids can be profiles without a login — you can still assign events and to-dos to them.</p>
      {admin && s.invites.filter((i) => !i.usedBy).length > 0 && (
        <>
          <div className="section-title"><h2>Pending invites</h2></div>
          <div className="card flush">{s.invites.filter((i) => !i.usedBy).map((i) => <InviteRow key={i.id} inv={i} />)}</div>
        </>
      )}
      {edit && <MemberEditor m={edit} isNew={!s.members.some((x) => x.id === edit.id)} onClose={() => setEdit(null)} onInvite={(p) => { setEdit(null); setInvite({ profile: p }); }} />}
      {invite && <InviteModal profile={invite.profile} onClose={() => setInvite(null)} />}
    </>
  );
}

function inviteText(inv: InviteRec, familyName: string) {
  const join = `${location.origin}${location.pathname.split('/family')[0]}/?code=${inv.code}`;
  return `You're invited to ${familyName} on Roost (as ${ROLE_LABEL[inv.role].toLowerCase()}).\n\nOn a computer or Android: ${join}\nOn iPhone: install Roost (TestFlight link from us), tap “I have an invite code” and enter ${inv.code}\n\nThe code works once and expires in 7 days.`;
}

function InviteRow({ inv }: { inv: InviteRec }) {
  const s = useRoost();
  const [toast, show] = useToast();
  return (
    <div className="irow">
      <div className="body">
        <div className="title">{inv.name || ROLE_LABEL[inv.role]}</div>
        <div className="meta">{ROLE_LABEL[inv.role]} · <span style={{ fontFamily: 'var(--mono)' }}>{inv.code}</span>{pbDate(inv.expiresAt) && ` · expires ${pbDate(inv.expiresAt)!.toLocaleDateString()}`}</div>
      </div>
      <button className="btn sm" onClick={() => void navigator.clipboard?.writeText(inviteText(inv, s.family!.name)).then(() => show('Invite copied'))}><Copy size={14} /> Copy</button>
      {toast}
    </div>
  );
}

function InviteModal({ profile, onClose }: { profile?: Member; onClose: () => void }) {
  const s = useRoost();
  const [role, setRole] = useState<Role>(profile ? (profile.role === 'owner' ? 'parent' : profile.role) : 'caregiver');
  const [name, setName] = useState(profile?.name ?? '');
  const [inv, setInv] = useState<InviteRec | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [toast, show] = useToast();
  const roles = ROLES.filter((r) => r !== 'owner' || myRole(s) === 'owner');
  return (
    <Modal title="Invite" onClose={onClose}>
      {inv ? (
        <>
          <div className="faint small" style={{ textAlign: 'center' }}>Invite code for {inv.name || ROLE_LABEL[inv.role]}</div>
          <div className="code">{inv.code}</div>
          <div className="faint small" style={{ textAlign: 'center' }}>Valid for 7 days, works once.</div>
          <button className="btn primary" onClick={() => void navigator.clipboard?.writeText(inviteText(inv, s.family!.name)).then(() => show('Invite message copied'))}><Copy size={16} /> Copy invite message</button>
          <a className="btn" href={`mailto:?subject=${encodeURIComponent(`Join ${s.family!.name} on Roost`)}&body=${encodeURIComponent(inviteText(inv, s.family!.name))}`}><Mail size={16} /> Email it</a>
        </>
      ) : (
        <>
          <input className="input big" placeholder="Their name" value={name} onChange={(e) => setName(e.target.value)} disabled={!!profile} />
          <Field label="Role">
            <select className="input" value={role} onChange={(e) => setRole(e.target.value as Role)}>
              {roles.map((r) => <option key={r} value={r}>{ROLE_LABEL[r]}</option>)}
            </select>
          </Field>
          <div className="muted small">{ROLE_BLURB[role]} You can fine-tune exactly what they see per calendar and list.</div>
          {err && <div className="err">{err}</div>}
          <button className="btn primary" disabled={busy} onClick={async () => {
            setBusy(true); setErr(null);
            try { setInv(await createInvite(role, name, profile?.id)); } catch (e) { setErr(errorText(e)); } finally { setBusy(false); }
          }}>{busy ? 'Creating…' : 'Create invite'}</button>
        </>
      )}
      {toast}
    </Modal>
  );
}

function MemberEditor({ m: initial, isNew, onClose, onInvite }: { m: Member; isNew: boolean; onClose: () => void; onInvite: (m: Member) => void }) {
  const s = useRoost();
  const [m, setM] = useState(initial);
  const [confirm, setConfirm] = useState(false);
  const isMe = m.user === s.user?.id;
  const admin = isAdmin(s);
  const canEdit = admin || isMe;
  const up = (p: Partial<Member>) => setM((x) => ({ ...x, ...p }));
  return (
    <Modal title={isNew ? 'New profile' : m.name} onClose={onClose}
      actions={canEdit ? <button className="btn primary sm" disabled={!m.name.trim()} onClick={() => { saveMember(m); onClose(); }}>Save</button> : undefined}>
      <div style={{ textAlign: 'center' }}><Avatar member={m} size={72} /></div>
      <fieldset disabled={!canEdit} style={{ border: 0, padding: 0, margin: 0, display: 'flex', flexDirection: 'column', gap: 14 }}>
        <input className="input big" placeholder="Name" value={m.name} onChange={(e) => up({ name: e.target.value })} />
        <input className="input" placeholder="Emoji (optional) 🦊" value={m.emoji} onChange={(e) => up({ emoji: e.target.value })} />
        <Field label="Color"><ColorPicker value={m.color} onChange={(c) => up({ color: c })} /></Field>
        {admin && !isMe && (
          <Field label="Role">
            <select className="input" value={m.role} onChange={(e) => up({ role: e.target.value as Role })}>
              {ROLES.filter((r) => r !== 'owner' || myRole(s) === 'owner').map((r) => <option key={r} value={r}>{ROLE_LABEL[r]}</option>)}
            </select>
            <span className="faint small" style={{ textTransform: 'none', letterSpacing: 0, fontWeight: 400 }}>{ROLE_BLURB[m.role]}</span>
          </Field>
        )}
        {isMe && <Toggle label="Remind me about every family event" hint="Otherwise: events you're in or driving, and your to-dos." checked={m.notifyAll} onChange={(v) => up({ notifyAll: v })} />}
      </fieldset>
      {!isNew && admin && !m.user && <button className="btn" onClick={() => onInvite(m)}><UserPlus size={16} /> Invite {m.name} to log in</button>}
      {!isNew && admin && !isMe && (confirm
        ? <button className="btn danger" onClick={() => { removeMember(m); onClose(); }}>Remove {m.name} from the family?</button>
        : <button className="btn danger" onClick={() => setConfirm(true)}><Trash2 size={16} /> Remove from family</button>)}
    </Modal>
  );
}

// ---- calendars & connections --------------------------------------------------

function Calendars() {
  const s = useRoost();
  const [edit, setEdit] = useState<CalendarRec | null>(null);
  const [subscribe, setSubscribe] = useState(false);
  const [feed, setFeed] = useState(false);
  const blank = (kind: CalendarRec['kind']): CalendarRec => ({
    id: newId(), family: s.family!.id, name: '', color: 'teal', kind, owner: kind === 'personal' ? me(s)?.id ?? '' : '', sharing: null,
    defaultReminders: [30], sourceUrl: '', lastSyncedAt: '', syncError: '', viewers: [], editors: [], busyViewers: [], sortOrder: s.calendars.length, deleted: false,
  });
  return (
    <>
      <div className="section-title" style={{ marginTop: 0 }}>
        <h2>Roost calendars</h2>
        <div className="row">
          {(isAdmin(s) || myRole(s) === 'caregiver') && <button className="btn sm" onClick={() => setEdit(blank(isAdmin(s) ? 'family' : 'personal'))}><Plus size={14} /> New</button>}
          {isAdmin(s) && <button className="btn sm" onClick={() => setSubscribe(true)}><Link2 size={14} /> Subscribe to a link</button>}
        </div>
      </div>
      <div className="card flush">
        {liveCalendars(s).map((c) => (
          <div key={c.id} className="irow" role="button" tabIndex={0} onClick={() => canManageCalendar(c, s) && setEdit(c)} style={{ cursor: canManageCalendar(c, s) ? 'pointer' : 'default' }}>
            <Dot color={c.color} size={12} />
            <div className="body">
              <div className="title">{c.name}</div>
              <div className="meta" style={{ color: c.syncError ? 'var(--danger)' : undefined }}>
                {c.kind === 'family' ? 'Shared family calendar' : c.kind === 'personal' ? `Personal · ${member(c.owner, s)?.name ?? ''}`
                  : c.syncError ? `⚠ ${c.syncError}` : `Subscribed · ${pbDate(c.lastSyncedAt) ? `updated ${pbDate(c.lastSyncedAt)!.toLocaleString()}` : 'waiting for first sync'}`}
              </div>
            </div>
          </div>
        ))}
      </div>
      <div className="section-title"><h2>Connect with Google, Outlook & Apple</h2></div>
      <div className="grid2">
        <div className="card stack">
          <b>See Roost in your other calendars</b>
          <span className="muted small">A private feed of everything you can see in Roost. Subscribe from Google Calendar, Outlook or Apple Calendar.</span>
          <button className="btn primary" onClick={() => setFeed(true)}><CalendarClock size={16} /> Get my feed link</button>
        </div>
        <div className="card stack">
          <b>Bring other calendars into Roost</b>
          <span className="muted small">Paste a Google “secret iCal address”, an Outlook published ICS link, or a school/team calendar. Everyone with access sees it.</span>
          <button className="btn" disabled={!isAdmin(s)} onClick={() => setSubscribe(true)}><Link2 size={16} /> Subscribe to a link</button>
        </div>
      </div>
      <p className="faint small">On iPhone, the Roost app can also show your phone's Outlook, Gmail and iCloud calendars side by side — two-way, without sharing them with the family.</p>
      {edit && <CalendarEditor cal={edit} isNew={!s.calendars.some((x) => x.id === edit.id)} onClose={() => setEdit(null)} />}
      {subscribe && <SubscribeModal onClose={() => setSubscribe(false)} />}
      {feed && <FeedModal onClose={() => setFeed(false)} />}
    </>
  );
}

function CalendarEditor({ cal, isNew, onClose }: { cal: CalendarRec; isNew: boolean; onClose: () => void }) {
  const s = useRoost();
  const [c, setC] = useState(cal);
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const up = (p: Partial<CalendarRec>) => setC((x) => ({ ...x, ...p }));
  return (
    <Modal title={isNew ? 'New calendar' : c.name} onClose={onClose}
      actions={<button className="btn primary sm" disabled={!c.name.trim()} onClick={() => { saveCalendar(c); onClose(); }}>Save</button>}>
      <input className="input big" placeholder="Calendar name" value={c.name} onChange={(e) => up({ name: e.target.value })} autoFocus />
      {isNew && isAdmin(s) && (
        <Field label="Type">
          <select className="input" value={c.kind} onChange={(e) => up({ kind: e.target.value as CalendarRec['kind'], owner: e.target.value === 'personal' ? me(s)?.id ?? '' : '' })}>
            <option value="family">Shared family calendar</option>
            <option value="personal">Personal calendar</option>
          </select>
        </Field>
      )}
      <Field label="Color"><ColorPicker value={c.color} onChange={(v) => up({ color: v })} /></Field>
      {c.kind === 'subscription' ? (
        <Field label="Source">
          <div className="small muted" style={{ wordBreak: 'break-all', fontFamily: 'var(--mono)' }}>{c.sourceUrl}</div>
          <button className="btn sm" disabled={busy} onClick={async () => { setBusy(true); setMsg((await refreshSubscription(c)) ?? 'Updated.'); setBusy(false); }}>
            <RefreshCw size={14} /> {busy ? 'Refreshing…' : 'Refresh now'}
          </button>
          {msg && <span className="small muted">{msg}</span>}
        </Field>
      ) : (
        <Field label="Default reminder for new events">
          <select className="input" value={c.defaultReminders?.[0] ?? -1} onChange={(e) => up({ defaultReminders: Number(e.target.value) >= 0 ? [Number(e.target.value)] : [] })}>
            <option value={-1}>None</option>
            {REMINDERS_TIMED.map((m) => <option key={m} value={m}>{reminderText(m, false)}</option>)}
          </select>
        </Field>
      )}
      <Field label="Who can see it">
        <SharingEditor sharing={c.sharing} onChange={(v) => up({ sharing: v })} resource="calendar" subkind={c.kind} ownerId={c.owner} />
        <span className="faint small" style={{ textTransform: 'none', letterSpacing: 0, fontWeight: 400 }}>“Busy only” shows time blocks without details — handy for a nanny who needs to know when parents are unavailable.</span>
      </Field>
      {!isNew && <button className="btn danger" onClick={() => { saveCalendar({ ...c, deleted: true }); onClose(); }}><Trash2 size={16} /> Delete calendar</button>}
    </Modal>
  );
}

function SubscribeModal({ onClose }: { onClose: () => void }) {
  const s = useRoost();
  const [name, setName] = useState('');
  const [url, setUrl] = useState('');
  const [color, setColor] = useState('cyan');
  const help: [string, string][] = [
    ['Google Calendar', 'Settings → (your calendar) → Integrate calendar → “Secret address in iCal format”.'],
    ['Outlook.com / Microsoft 365', 'Settings → Calendar → Shared calendars → Publish a calendar → copy the ICS link.'],
    ['iCloud', 'Calendar → (i) next to a calendar → Public Calendar → copy link.'],
    ['School & sports', 'Look for “Subscribe”, “iCal” or “Add to calendar” on the school, TeamSnap or league site.'],
  ];
  return (
    <Modal title="Subscribe to a calendar" onClose={onClose} actions={
      <button className="btn primary sm" disabled={!name.trim() || url.trim().length < 10} onClick={() => {
        const c: CalendarRec = {
          id: newId(), family: s.family!.id, name, color, kind: 'subscription', owner: '', sharing: null, defaultReminders: [], sourceUrl: url.trim(),
          lastSyncedAt: '', syncError: '', viewers: [], editors: [], busyViewers: [], sortOrder: s.calendars.length, deleted: false,
        };
        saveCalendar(c);
        setTimeout(() => { void refreshSubscription(c); }, 1500);
        onClose();
      }}>Subscribe</button>}>
      <input className="input big" placeholder="Name (e.g. Lincoln Elementary)" value={name} onChange={(e) => setName(e.target.value)} autoFocus />
      <input className="input" placeholder="webcal:// or https:// link" value={url} onChange={(e) => setUrl(e.target.value)} />
      <Field label="Color"><ColorPicker value={color} onChange={setColor} /></Field>
      <div className="group">{help.map(([t, d]) => <div key={t} className="item" style={{ display: 'block' }}><b className="small">{t}</b><div className="small muted">{d}</div></div>)}</div>
    </Modal>
  );
}

function FeedModal({ onClose }: { onClose: () => void }) {
  const s = useRoost();
  const [url, setUrl] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [toast, show] = useToast();
  useEffect(() => { ensureFeed().then((f) => setUrl(feedURL(f))).catch((e) => setErr(errorText(e))); }, []);
  const webcal = url?.replace(/^https?:/, 'webcal:');
  const name = encodeURIComponent(s.family?.name ?? 'Roost');
  return (
    <Modal title="Your Roost feed" onClose={onClose}>
      {err && <div className="err">{err}</div>}
      {!url && !err && <div className="muted">Creating your private link…</div>}
      {url && webcal && (
        <>
          <a className="btn primary" href={`https://calendar.google.com/calendar/r?cid=${encodeURIComponent(webcal)}`} target="_blank" rel="noreferrer">Add to Google Calendar</a>
          <a className="btn" href={`https://outlook.live.com/calendar/0/addfromweb?url=${encodeURIComponent(url)}&name=${name}`} target="_blank" rel="noreferrer">Add to Outlook.com</a>
          <a className="btn" href={`https://outlook.office.com/calendar/0/addfromweb?url=${encodeURIComponent(url)}&name=${name}`} target="_blank" rel="noreferrer">Add to Outlook (work / Microsoft 365)</a>
          <a className="btn" href={webcal}>Add to Apple Calendar</a>
          <div className="card small" style={{ wordBreak: 'break-all', fontFamily: 'var(--mono)' }}>{url}</div>
          <button className="btn ghost" onClick={() => void navigator.clipboard?.writeText(url).then(() => show('Link copied'))}><Copy size={16} /> Copy link</button>
          <div className="faint small">Keep this link private — anyone with it can read your feed. Google refreshes every few hours; Outlook can take up to a day.</div>
        </>
      )}
      {toast}
    </Modal>
  );
}

// ---- settings --------------------------------------------------------------

function SettingsPane() {
  const s = useRoost();
  const [perm, setPerm] = useState<NotificationPermission | 'unsupported'>(() => ('Notification' in window ? Notification.permission : 'unsupported'));
  const [theme, setTheme] = useState(() => localStorage.getItem('roost.theme') ?? 'auto');
  const [weekStart, setWeekStart] = useState(() => localStorage.getItem('roost.weekStart') ?? '0');
  const m = me(s);
  useEffect(() => {
    if (theme === 'auto') document.documentElement.removeAttribute('data-theme'); else document.documentElement.setAttribute('data-theme', theme);
    try { localStorage.setItem('roost.theme', theme); } catch { /* ignore */ }
  }, [theme]);
  return (
    <div className="stack" style={{ maxWidth: 640 }}>
      <div className="card stack">
        <b className="row"><Bell size={16} /> Reminders</b>
        {perm === 'granted' ? <span className="muted small">Browser notifications are on while Roost is open. For reminders anytime, use the iPhone app.</span>
          : perm === 'unsupported' ? <span className="muted small">This browser doesn't support notifications.</span>
            : <button className="btn" onClick={async () => setPerm(await enableNotifications())}>Turn on browser notifications</button>}
        {m && <Toggle label="Remind me about every family event" checked={m.notifyAll} onChange={(v) => saveMember({ ...m, notifyAll: v })} />}
      </div>
      <div className="card stack">
        <b>Appearance</b>
        <Field label="Theme">
          <select className="input" value={theme} onChange={(e) => setTheme(e.target.value)}>
            <option value="auto">Match system</option><option value="light">Light</option><option value="dark">Dark</option>
          </select>
        </Field>
        <Field label="Week starts on">
          <select className="input" value={weekStart} onChange={(e) => { setWeekStart(e.target.value); localStorage.setItem('roost.weekStart', e.target.value); }}>
            <option value="0">Sunday</option><option value="1">Monday</option>
          </select>
        </Field>
      </div>
      <div className="card stack">
        <b>Account</b>
        <div className="muted small">Signed in as {s.user?.name || s.user?.email}{s.lastSync && ` · last synced ${new Date(s.lastSync).toLocaleTimeString()}`}{s.outbox.length > 0 && ` · ${s.outbox.length} change(s) waiting`}</div>
        <div className="row">
          <button className="btn" onClick={() => void syncNow()}><RefreshCw size={16} /> Sync now</button>
          <button className="btn danger" onClick={signOut}><LogOut size={16} /> Sign out</button>
        </div>
      </div>
      <p className="faint small">Roost is private to your family. Your data lives on your own server.</p>
    </div>
  );
}
