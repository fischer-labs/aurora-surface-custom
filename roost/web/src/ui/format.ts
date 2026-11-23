import { RRule } from '../core/recurrence';
import { LocalDateTime, localTZ } from '../core/localdate';
import type { TaskRec } from '../data/models';

export const fmtTime = (d: Date) => d.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
export const fmtHour = (h: number) => new Date(2026, 0, 1, h).toLocaleTimeString([], { hour: 'numeric' });

export function startOfDay(d: Date): Date { const x = new Date(d); x.setHours(0, 0, 0, 0); return x; }
export function addDays(d: Date, n: number): Date { const x = new Date(d); x.setDate(x.getDate() + n); return x; }
export function addMonths(d: Date, n: number): Date { const x = new Date(d.getFullYear(), d.getMonth() + n, 1); return x; }
export function sameDay(a: Date, b: Date): boolean { return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate(); }
export const isToday = (d: Date) => sameDay(d, new Date());

export function dayTitle(d: Date): string {
  const t = startOfDay(new Date());
  const diff = Math.round((startOfDay(d).getTime() - t.getTime()) / 86400000);
  if (diff === 0) return 'Today';
  if (diff === 1) return 'Tomorrow';
  if (diff === -1) return 'Yesterday';
  return d.toLocaleDateString([], { weekday: 'long', month: 'short', day: 'numeric' });
}

export function rangeText(start: Date, end: Date, allDay: boolean): string {
  if (allDay) {
    const days = Math.round((startOfDay(end).getTime() - startOfDay(start).getTime()) / 86400000);
    return days > 1 ? `All day · ${days} days` : 'All day';
  }
  return `${fmtTime(start)} – ${fmtTime(end)}`;
}

export function reminderText(m: number, allDay: boolean): string {
  if (allDay) {
    const special: Record<number, string> = { [-540]: '9 AM on the day', 900: '9 AM the day before', 2340: '9 AM two days before', 9540: '9 AM a week before' };
    if (special[m]) return special[m];
  }
  if (m === 0) return 'At start';
  if (m % 10080 === 0) return `${m / 10080} week${m === 10080 ? '' : 's'} before`;
  if (m % 1440 === 0) return `${m / 1440} day${m === 1440 ? '' : 's'} before`;
  if (m % 60 === 0) return `${m / 60} hour${m === 60 ? '' : 's'} before`;
  return `${m} min before`;
}
export const REMINDERS_TIMED = [0, 5, 10, 15, 30, 60, 120, 1440, 2880, 10080];
export const REMINDERS_ALLDAY = [-540, 900, 2340, 9540];

const WD = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
export function recurrenceText(rrule: string): string | null {
  const r = RRule.parse(rrule);
  if (!r) return null;
  const every = r.interval > 1 ? `Every ${r.interval} ` : 'Every ';
  let s: string;
  switch (r.freq) {
    case 'DAILY': s = r.interval > 1 ? `${every}days` : 'Daily'; break;
    case 'WEEKLY': {
      const days = r.byDay.map((d) => WD[d.weekday]);
      if (days.join() === 'Mon,Tue,Wed,Thu,Fri') { s = 'Weekdays'; break; }
      const unit = r.interval > 1 ? `${every}weeks` : 'Weekly';
      s = days.length ? `${unit} on ${days.join(', ')}` : unit;
      break;
    }
    case 'MONTHLY': {
      const d = r.byDay[0];
      if (d?.ordinal !== undefined) {
        const ord = d.ordinal < 0 ? (d.ordinal === -1 ? 'last' : `${-d.ordinal}th-to-last`) : ['', '1st', '2nd', '3rd', '4th', '5th'][Math.min(d.ordinal, 5)];
        s = `Monthly on the ${ord} ${WD[d.weekday]}`;
      } else s = r.interval > 1 ? `${every}months` : 'Monthly';
      break;
    }
    default: s = 'Yearly';
  }
  if (r.until?.kind === 'date') s += ` until ${r.until.date.toString()}`;
  return s;
}

export type RepeatPreset = 'none' | 'daily' | 'weekdays' | 'weekly' | 'biweekly' | 'monthlyDate' | 'monthlyWeekday' | 'yearly' | 'custom';
const CODES = ['SU', 'MO', 'TU', 'WE', 'TH', 'FR', 'SA'];
export function weekOrdinal(d: Date): number {
  const day = d.getDate();
  const n = new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate();
  return day + 7 > n ? -1 : Math.floor((day - 1) / 7) + 1;
}
export function presetRule(p: RepeatPreset, start: Date): string {
  const code = CODES[start.getDay()];
  switch (p) {
    case 'daily': return 'FREQ=DAILY';
    case 'weekdays': return 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR';
    case 'weekly': return `FREQ=WEEKLY;BYDAY=${code}`;
    case 'biweekly': return `FREQ=WEEKLY;INTERVAL=2;BYDAY=${code}`;
    case 'monthlyDate': return 'FREQ=MONTHLY';
    case 'monthlyWeekday': return `FREQ=MONTHLY;BYDAY=${weekOrdinal(start)}${code}`;
    case 'yearly': return 'FREQ=YEARLY';
    default: return '';
  }
}
export function presetLabel(p: RepeatPreset, start: Date): string {
  const wd = start.toLocaleDateString([], { weekday: 'long' });
  switch (p) {
    case 'none': return 'Never';
    case 'daily': return 'Every day';
    case 'weekdays': return 'Every weekday (Mon–Fri)';
    case 'weekly': return `Every week on ${wd}`;
    case 'biweekly': return `Every 2 weeks on ${wd}`;
    case 'monthlyDate': return `Monthly on day ${start.getDate()}`;
    case 'monthlyWeekday': { const n = weekOrdinal(start); return `Monthly on the ${n === -1 ? 'last' : ['', '1st', '2nd', '3rd', '4th'][n]} ${wd}`; }
    case 'yearly': return `Every year on ${start.toLocaleDateString([], { month: 'long', day: 'numeric' })}`;
    default: return 'Custom';
  }
}
export const PRESETS: RepeatPreset[] = ['none', 'daily', 'weekdays', 'weekly', 'biweekly', 'monthlyDate', 'monthlyWeekday', 'yearly'];
export function detectPreset(rrule: string, start: Date): RepeatPreset {
  if (!rrule) return 'none';
  const base = rrule.split(';').filter((p) => !p.startsWith('UNTIL') && !p.startsWith('COUNT')).join(';');
  return PRESETS.find((p) => p !== 'none' && presetRule(p, start) === base) ?? 'custom';
}

export function dueText(t: TaskRec): string | null {
  const d = LocalDateTime.parse(t.due);
  if (!d) return null;
  const date = d.toDate(localTZ());
  return t.due.length > 10 ? `${dayTitle(date)}, ${fmtTime(date)}` : dayTitle(date);
}

/** <input type="datetime-local"> helpers (local time). */
export const toInputDT = (d: Date) => `${toInputDate(d)}T${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
export const toInputDate = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
export const fromInput = (s: string) => { const d = new Date(s.length === 10 ? s + 'T00:00' : s); return Number.isNaN(d.getTime()) ? null : d; };
