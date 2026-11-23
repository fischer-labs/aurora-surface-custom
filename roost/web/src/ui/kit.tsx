// Small UI kit shared by all screens.
import { useEffect, useRef, useState, type ReactNode } from 'react';
import { CloudOff, RefreshCw, TriangleAlert, X } from 'lucide-react';
import type { Member } from '../data/models';
import { COLORS } from '../data/models';
import { useRoost } from '../data/store';

export const colorVar = (name: string | undefined) => `var(--${COLORS.includes((name ?? '') as never) ? name : 'brown'})`;
const known = (name?: string) => (COLORS.includes((name ?? '') as never) ? name! : 'brown');
/** Solid fill for a person color when text/icons sit on it (darkened for contrast). */
export const fillVar = (name: string | undefined) => `var(--${known(name)}-strong)`;
/** Text color on fillVar(name): dark on amber/lime, white otherwise. */
export const textOn = (name: string | undefined) => (known(name) === 'amber' || known(name) === 'lime' ? '#1E1A16' : '#fff');

export function Avatar({ member, size = 28 }: { member: Member | null | undefined; size?: number }) {
  const initials = (member?.name ?? '?').split(' ').filter(Boolean).map((p) => p[0]).slice(0, 2).join('').toUpperCase();
  return (
    <span className="avatar" title={member?.name} aria-label={member?.name}
      style={{ width: size, height: size, background: fillVar(member?.color), color: textOn(member?.color), fontSize: size * (member?.emoji ? 0.55 : size < 26 ? 0.48 : 0.4) }}>
      {member?.emoji || (size < 26 ? initials.slice(0, 1) : initials)}
    </span>
  );
}

export function AvatarStack({ members, size = 22, max = 4 }: { members: Member[]; size?: number; max?: number }) {
  if (!members.length) return null;
  return (
    <span className="avatars">
      {members.slice(0, max).map((m) => <Avatar key={m.id} member={m} size={size} />)}
      {members.length > max && <span className="faint small" style={{ marginLeft: 6 }}>+{members.length - max}</span>}
    </span>
  );
}

export function Dot({ color, size = 10 }: { color: string; size?: number }) {
  return <span className="dot" style={{ background: colorVar(color), width: size, height: size }} />;
}

export function Chip({ children, accent, color, icon }: { children: ReactNode; accent?: boolean; color?: string; icon?: ReactNode }) {
  return (
    <span className={`chip${accent ? ' accent' : ''}`} style={color ? { background: `color-mix(in srgb, ${colorVar(color)} 16%, transparent)`, color: colorVar(color) } : undefined}>
      {icon}{children}
    </span>
  );
}

export function Empty({ icon, title, children, action }: { icon: ReactNode; title: string; children?: ReactNode; action?: ReactNode }) {
  return (
    <div className="empty">
      <div className="ico">{icon}</div>
      <h3>{title}</h3>
      {children && <div>{children}</div>}
      {action && <div style={{ marginTop: 14 }}>{action}</div>}
    </div>
  );
}

export function Modal({ title, onClose, children, actions, wide, left }: {
  title: string; onClose: () => void; children: ReactNode; actions?: ReactNode; wide?: boolean; left?: ReactNode;
}) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', onKey);
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => { window.removeEventListener('keydown', onKey); document.body.style.overflow = prev; };
  }, [onClose]);
  return (
    <div className="overlay" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className={`modal${wide ? ' wide' : ''}`} role="dialog" aria-modal="true" aria-label={title}>
        <div className="modal-head">
          {left ?? <button className="btn ghost icon" onClick={onClose} aria-label="Close"><X size={18} /></button>}
          <h2>{title}</h2>
          <div className="row">{actions ?? <span style={{ width: 40 }} />}</div>
        </div>
        <div className="modal-body">{children}</div>
      </div>
    </div>
  );
}

export function Menu({ trigger, children, left }: { trigger: (open: () => void) => ReactNode; children: (close: () => void) => ReactNode; left?: boolean }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const h = (e: MouseEvent) => { if (!ref.current?.contains(e.target as Node)) setOpen(false); };
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false); };
    document.addEventListener('mousedown', h);
    document.addEventListener('keydown', k);
    return () => { document.removeEventListener('mousedown', h); document.removeEventListener('keydown', k); };
  }, [open]);
  return (
    <div className="menu" ref={ref}>
      {trigger(() => setOpen((o) => !o))}
      {open && <div className={`menu-pop${left ? ' left' : ''}`} role="menu">{children(() => setOpen(false))}</div>}
    </div>
  );
}

export function Toggle({ label, checked, onChange, hint }: { label: ReactNode; checked: boolean; onChange: (v: boolean) => void; hint?: string }) {
  return (
    <label className="toggle">
      <span>{label}{hint && <div className="faint small">{hint}</div>}</span>
      <input type="checkbox" role="switch" checked={checked} onChange={(e) => onChange(e.target.checked)} />
    </label>
  );
}

export function Field({ label, children }: { label: string; children: ReactNode }) {
  return <label className="field"><span>{label}</span>{children}</label>;
}

export function Seg<T extends string>({ value, options, onChange }: { value: T; options: { value: T; label: ReactNode }[]; onChange: (v: T) => void }) {
  return (
    <div className="seg" role="tablist">
      {options.map((o) => (
        <button key={o.value} role="tab" aria-selected={o.value === value} className={o.value === value ? 'on' : ''} onClick={() => onChange(o.value)}>{o.label}</button>
      ))}
    </div>
  );
}

export function ColorPicker({ value, onChange }: { value: string; onChange: (c: string) => void }) {
  return (
    <div className="colors">
      {COLORS.map((c) => (
        <button key={c} type="button" aria-label={c} aria-pressed={value === c} className={value === c ? 'on' : ''} style={{ background: colorVar(c) }} onClick={() => onChange(c)} />
      ))}
    </div>
  );
}

export function PeoplePicker({ members, value, onChange }: { members: Member[]; value: string[]; onChange: (v: string[]) => void }) {
  return (
    <div className="people-pick">
      {members.map((m) => {
        const on = value.includes(m.id);
        return (
          <button key={m.id} type="button" className={on ? 'on' : ''} aria-pressed={on} style={{ color: colorVar(m.color) }}
            onClick={() => onChange(on ? value.filter((x) => x !== m.id) : [...value, m.id])}>
            <Avatar member={m} size={38} />
            <span style={{ color: on ? 'var(--ink)' : undefined }}>{m.name.split(' ')[0]}</span>
          </button>
        );
      })}
    </div>
  );
}

export function Logo({ size = 64 }: { size?: number }) {
  return (
    <svg className="logo" width={size} height={size} viewBox="0 0 1024 1024" aria-hidden="true">
      <defs>
        <linearGradient id="lg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stopColor="#EC7344" /><stop offset="1" stopColor="#C2441D" /></linearGradient>
      </defs>
      <rect width="1024" height="1024" rx="236" fill="url(#lg)" />
      <polyline points="214,500 512,252 810,500" fill="none" stroke="#FFF6EC" strokeWidth="88" strokeLinecap="round" strokeLinejoin="round" />
      <g fill="#FFF6EC">
        <circle cx="414" cy="584" r="60" /><circle cx="610" cy="584" r="60" /><circle cx="512" cy="612" r="44" />
        <path d="M292 640 H732 Q732 812 512 812 Q292 812 292 640 Z" stroke="#FFF6EC" strokeWidth="22" strokeLinejoin="round" />
      </g>
    </svg>
  );
}

export function SyncBadge() {
  const s = useRoost();
  if (s.sync === 'syncing') return <span className="syncdot"><RefreshCw size={13} className="spin" /> Syncing</span>;
  if (s.sync === 'offline') return <span className="syncdot"><CloudOff size={13} /> Offline{s.outbox.length ? ` · ${s.outbox.length} waiting` : ''}</span>;
  if (typeof s.sync === 'object') return <span className="syncdot err" title={s.sync.error}><TriangleAlert size={13} /> Sync issue</span>;
  return null;
}

export function useToast(): [ReactNode, (msg: string) => void] {
  const [msg, setMsg] = useState<string | null>(null);
  useEffect(() => { if (!msg) return; const t = setTimeout(() => setMsg(null), 2200); return () => clearTimeout(t); }, [msg]);
  return [msg ? <div className="toast" role="status">{msg}</div> : null, setMsg];
}

export function errorText(e: unknown): string {
  const r = (e as { response?: { message?: string; data?: Record<string, { message?: string }> } })?.response;
  if (r?.data && Object.keys(r.data).length) {
    const [k, v] = Object.entries(r.data)[0];
    return `${r.message ?? 'Error'} (${k}: ${v?.message ?? ''})`;
  }
  return r?.message || (e as Error)?.message || 'Something went wrong.';
}
