// Record shapes as returned by roost-server (PocketBase). See docs/DESIGN.md §4.
import type { Level, Role, Sharing } from '../core/logic';

export type { Level, Role, Sharing };

export interface Base { id: string; created?: string; updated?: string }

export interface UserRec extends Base { email?: string; name: string }

export interface Family extends Base {
  name: string; timezone: string; weekStart: number; owner: string; members: string[]; admins: string[];
}

export interface Member extends Base {
  family: string; user: string; name: string; role: Role; color: string; emoji: string; birthday: string; notifyAll: boolean; sortOrder: number;
}

export interface CalendarRec extends Base {
  family: string; name: string; color: string; kind: 'family' | 'personal' | 'subscription'; owner: string; sharing: Sharing | null;
  defaultReminders: number[] | null; sourceUrl: string; lastSyncedAt: string; syncError: string;
  viewers: string[]; editors: string[]; busyViewers: string[]; sortOrder: number; deleted: boolean;
}

export interface EventRec extends Base {
  family: string; calendar: string; title: string; notes: string; location: string; url: string;
  start: string; end: string; allDay: boolean; tz: string; rrule: string; exdates: string[] | null; recurrenceParent: string;
  members: string[]; driver: string; category: string; reminders: number[] | null; private: boolean; color: string;
  source: string; externalUid?: string; createdBy: string; updatedBy?: string; deleted: boolean;
  /** Client-side: sanitized busy block from /api/roost/busy. */
  busy?: boolean;
}

export interface ListRec extends Base {
  family: string; name: string; kind: 'todo' | 'grocery' | 'packing'; icon: string; color: string; owner: string; sharing: Sharing | null;
  storeOrder: string[] | null; viewers: string[]; editors: string[]; sortOrder: number; archived: boolean; deleted: boolean;
}

export interface TaskRec extends Base {
  family: string; list: string; title: string; notes: string; due: string; assignees: string[]; priority: number; rrule: string;
  completed: boolean; completedAt: string; completedBy: string; parent: string; reminders: number[] | null; tags: string[] | null;
  sortOrder: number; createdBy: string; deleted: boolean;
}

export interface GroceryRec extends Base {
  family: string; list: string; name: string; quantity: number; unit: string; note: string; category: string;
  categorySource: string; checked: boolean; checkedAt: string; checkedBy?: string; addedBy: string; sortOrder: number; deleted: boolean;
}

export interface LearnedRec extends Base { family: string; term: string; category: string }

export interface CardRec extends Base {
  family: string; title: string; body: string; kind: string; icon: string; phone: string; address: string; aboutMember: string;
  pinned: boolean; owner: string; sharing: Sharing | null; viewers: string[]; editors: string[]; sortOrder: number; deleted: boolean;
}

export interface InviteRec extends Base {
  family: string; code: string; role: Role; name: string; color?: string; membership: string; expiresAt: string; usedBy: string;
}

export interface FeedRec extends Base { family: string; user: string; token: string; name: string; includeBusy: boolean }

export const COLORS = ['red', 'orange', 'amber', 'lime', 'green', 'teal', 'cyan', 'blue', 'indigo', 'violet', 'pink', 'brown'] as const;
export type ColorName = (typeof COLORS)[number];

const ID_ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789';
/** PocketBase-compatible id generated on the client so offline creates keep their identity. */
export function newId(): string {
  const a = new Uint8Array(15);
  crypto.getRandomValues(a);
  return Array.from(a, (b) => ID_ALPHABET[b % ID_ALPHABET.length]).join('');
}

/** PocketBase date string ↔ Date. */
export function pbDate(s: string | null | undefined): Date | null {
  if (!s) return null;
  const d = new Date(s.includes('T') ? s : s.replace(' ', 'T'));
  return Number.isNaN(d.getTime()) ? null : d;
}
export function toPB(d: Date | null): string { return d ? d.toISOString().replace('T', ' ') : ''; }
