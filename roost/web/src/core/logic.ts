// Day layout, access levels, task recurrence (mirror of RoostKit/Logic.swift).
import { LocalDateTime } from './localdate';
import { RRule, iterate } from './recurrence';

// ---- layout (§6) ---------------------------------------------------------

export interface LayoutItem { id: string; start: number; end: number }
export interface LayoutSlot { col: number; cols: number }

export function layoutDay(items: LayoutItem[]): Record<string, LayoutSlot> {
  const norm = items.map((i) => ({ ...i, end: i.end > i.start ? i.end : i.start + 15 }));
  norm.sort((a, b) => a.start - b.start || b.end - a.end || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const out: Record<string, LayoutSlot> = {};
  let cluster: [LayoutItem, number][] = [];
  let colEnds: number[] = [];
  let clusterEnd = -Infinity;
  const flush = () => {
    for (const [it, c] of cluster) out[it.id] = { col: c, cols: colEnds.length };
    cluster = []; colEnds = []; clusterEnd = -Infinity;
  };
  for (const it of norm) {
    if (cluster.length && it.start >= clusterEnd) flush();
    const c = colEnds.findIndex((e) => e <= it.start);
    if (c >= 0) { colEnds[c] = it.end; cluster.push([it, c]); } else { colEnds.push(it.end); cluster.push([it, colEnds.length - 1]); }
    clusterEnd = Math.max(clusterEnd, it.end);
  }
  flush();
  return out;
}

// ---- access (§7) ---------------------------------------------------------

export type Level = 'none' | 'busy' | 'view' | 'edit';
export type Role = 'owner' | 'parent' | 'caregiver' | 'relative' | 'kid';
export const ROLES: Role[] = ['owner', 'parent', 'caregiver', 'relative', 'kid'];
export const LEVEL_RANK: Record<Level, number> = { none: 0, busy: 1, view: 2, edit: 3 };
export interface Sharing { roles?: Partial<Record<Role, Level>>; people?: Record<string, Level> }

export const ROLE_LABEL: Record<Role, string> = { owner: 'Owner', parent: 'Parent', caregiver: 'Caregiver', relative: 'Relative', kid: 'Kid' };
export const ROLE_BLURB: Record<Role, string> = {
  owner: 'Full control, including roles and sharing.',
  parent: 'Manages calendars, lists, invites and sharing.',
  caregiver: "Nanny or sitter: kids' schedule, groceries, assigned to-dos, care info.",
  relative: 'Grandparents, aunts & uncles: view the family calendar and care info.',
  kid: 'Sees the family calendar, adds to groceries, checks off their to-dos.',
};
export const LEVEL_LABEL: Record<Level, string> = { none: 'No access', busy: 'Busy only', view: 'Can view', edit: 'Can edit' };

const DEFAULTS: Record<string, Record<Role, Level>> = {
  'calendar:family': { owner: 'edit', parent: 'edit', caregiver: 'edit', relative: 'view', kid: 'view' },
  'calendar:personal': { owner: 'view', parent: 'view', caregiver: 'busy', relative: 'none', kid: 'none' },
  'calendar:subscription': { owner: 'view', parent: 'view', caregiver: 'view', relative: 'view', kid: 'view' },
  'list:todo': { owner: 'edit', parent: 'edit', caregiver: 'none', relative: 'none', kid: 'none' },
  'list:grocery': { owner: 'edit', parent: 'edit', caregiver: 'edit', relative: 'none', kid: 'edit' },
  'list:packing': { owner: 'edit', parent: 'edit', caregiver: 'edit', relative: 'none', kid: 'view' },
  'info:card': { owner: 'edit', parent: 'edit', caregiver: 'view', relative: 'view', kid: 'none' },
};

export function defaultLevel(resource: string, subkind: string, role: Role): Level {
  return DEFAULTS[`${resource}:${subkind}`]?.[role] ?? 'none';
}

export function effectiveLevel(resource: string, subkind: string, role: Role, membershipId: string, sharing: Sharing | null | undefined, isOwner: boolean): Level {
  if (isOwner) return 'edit';
  const valid = (l: unknown): l is Level => typeof l === 'string' && l in LEVEL_RANK;
  let level: Level;
  const p = sharing?.people?.[membershipId];
  const r = sharing?.roles?.[role];
  if (valid(p)) level = p; else if (valid(r)) level = r; else level = defaultLevel(resource, subkind, role);
  if (level === 'busy' && resource !== 'calendar') level = 'none';
  return level;
}

// ---- task recurrence (§8) ------------------------------------------------

export function nextDue(due: string, rrule: string, completedAt: LocalDateTime): string | null {
  const start = LocalDateTime.parse(due);
  const rule = RRule.parse(rrule);
  if (!start || !rule) return null;
  const allDay = due.length <= 10;
  let found: LocalDateTime | null = null;
  iterate(start, rule, 0, 'UTC', (c) => {
    if (c.compare(start) > 0 && c.date.compare(completedAt.date) > 0) { found = c; return false; }
    return true;
  });
  return found ? (found as LocalDateTime).key(allDay) : null;
}
