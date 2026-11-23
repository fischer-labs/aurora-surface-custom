# Roost — Design Specification

Roost is a private family organizer: one shared calendar that connects to the calendars you already use, smart to-do and grocery lists, reminders, and a caregiver info vault, with role-scoped access for parents, nannies, grandparents and kids.

It is built for **one household**, not for retail. That frees us to be opinionated, self-hosted and simple to operate.

---

## 1. Goals and non-goals

**Goals**
1. A calendar that is genuinely good: seven views, color by person, recurring events, who's driving, reminders, and connections to Outlook, Google and iCloud.
2. To-do lists with assignees, due dates, priorities, subtasks, recurrence and reminders.
3. Grocery lists that **group items by aisle automatically**, parse quantities, merge duplicates, learn your corrections and follow your store's aisle order.
4. **Role-level access**: each person sees exactly the right slice (a nanny sees the kids' schedule and groceries, and sees parents' appointments only as "Busy").
5. Native iPhone app + an unlisted web app (same server, same data).
6. Works offline; syncs in real time when online.

**Non-goals (v1)**: messaging/chat, location tracking, meal planning, chore points/allowance, Android app (the web app covers Android relatives).

---

## 2. Architecture

```
 ┌──────────────── iPhone (SwiftUI, iOS 17+) ────────────────┐     ┌──── Browser (PWA) ────┐
 │ RoostKit (pure Swift, tested on Linux + macOS)            │     │ React + TypeScript     │
 │  models · recurrence · grocery brain · quick-add parser   │     │ src/core = TS mirror   │
 │  access rules · layout · task recurrence · ICS writer     │     │ of RoostKit, same      │
 │ App: views · EventKit overlay · local notifications ·     │     │ fixtures               │
 │      JSON snapshot cache + outbox · SSE realtime client   │     │ IndexedDB cache        │
 └───────────────────────────────┬───────────────────────────┘     └──────────┬────────────┘
                                 │ HTTPS (REST + Server-Sent Events)           │
                     ┌───────────▼──────────────────────────────────────────────▼───────┐
                     │ roost-server (one Go binary = PocketBase v0.40 + Roost hooks)    │
                     │  SQLite · auth · realtime · API rules · admin UI (/_/)           │
                     │  /api/roost/join · /ics/{token} · /busy · /categorize · cron     │
                     │  serves the web app at an unlisted path (ROOST_WEB_PATH)         │
                     └───────────┬──────────────────────────────┬───────────────────────┘
                                 │ fetch ICS on schedule        │ optional
                     school / Google secret iCal / Outlook ICS  local LLM (Ollama, OpenAI-compatible)
```

**Shared truth across languages.** Logic that must agree on every device — recurrence expansion, grocery categorization, quick-add parsing, access computation, task recurrence — lives in `RoostKit` (Swift) and `web/src/core` (TypeScript). Both are tested against the **same JSON fixtures** in `shared/fixtures/`, and both load the same `shared/grocery/taxonomy.json`. The server enforces access independently (it never trusts the client).

---

## 3. People, roles and access

### 3.1 Roles

| Role | Typical person | Can do by default |
|---|---|---|
| `owner` | Parent who set up Roost | Everything, including billing-free admin: invites, roles, sharing, deleting. |
| `parent` | Co-parent / partner | Same as owner except cannot remove the owner. |
| `caregiver` | Nanny, au pair, sitter | Edit the Family + kids' calendars, edit groceries, see assigned to-dos, read caregiver info cards; sees parents' personal calendars as **Busy**. |
| `relative` | Grandparents, aunts | View the Family calendar and selected info; no lists by default. |
| `kid` | Children (with or without a login) | View the Family calendar and their own events, add to groceries, check off their to-dos. |

Kids (and anyone) can exist as a **profile without a login** — events and to-dos can still be assigned to them and colored by them.

### 3.2 Per-resource sharing

Every calendar, list and info card has a `sharing` object:

```json
{ "roles":  { "caregiver": "view", "relative": "none" },
  "people": { "<membershipId>": "edit" } }
```

Effective level for a person = `people[id]` → else `roles[role]` → else the **kind default** (table below). The resource's own `owner` membership always gets `edit`.

Levels: `none` < `busy` (calendars only: sees time blocks, no details) < `view` < `edit`.

| Kind default | owner | parent | caregiver | relative | kid |
|---|---|---|---|---|---|
| Calendar: family | edit | edit | edit | view | view |
| Calendar: personal | view | view | busy | none | none |
| Calendar: subscription (ICS) | view | view | view | view | view |
| List: todo | edit | edit | none | none | none |
| List: grocery | edit | edit | edit | none | edit |
| List: packing | edit | edit | edit | none | view |
| Info card | edit | edit | view | view | none |

Additional rules:
- Anyone **assigned** to a to-do can see and complete it, even if the list isn't shared with them.
- An event marked **private** shows as "Busy" to people who can view but not edit its calendar.
- Changing `sharing` requires being an admin (owner/parent) or the resource's owner.

### 3.3 Enforcement

The server denormalizes access onto each shareable record as relation fields `viewers`, `editors`, `busyViewers` (user ids), recomputed by hooks whenever a resource, membership or role changes. API rules then stay small and auditable, e.g. events:

```
list/view: calendar.viewers.id ?= @request.auth.id && (private = false || calendar.editors.id ?= @request.auth.id || createdBy = @request.auth.id)
create   : calendar.editors.id ?= @request.auth.id
```

Hooks additionally verify: relation targets belong to the same family, moved records land in a calendar/list the user can edit, imported (ICS) events are read-only, and server-managed fields are never client-writable. Realtime subscriptions inherit the same rules automatically. Go tests cover each role.

---

## 4. Data model (PocketBase collections)

All records have `id`, `created`, `updated`. Syncable records use **soft delete** (`deleted: true`) so offline clients can catch up with `updated > lastSync`; a nightly job purges tombstones older than 60 days.

| Collection | Key fields |
|---|---|
| `users` (auth) | email, name, avatar |
| `families` | name, timezone, weekStart, owner→users, members→users[] *(server)*, admins→users[] *(server)*, settings{} |
| `memberships` | family, user→users?, name, role, color, emoji, birthday, notifyAll, sortOrder |
| `calendars` | family, name, color, kind(family/personal/subscription), owner→memberships, sharing{}, defaultReminders[], sourceUrl, lastSyncedAt, syncError, viewers/editors/busyViewers *(server)*, sortOrder, deleted |
| `events` | family *(server)*, calendar, title, notes, location, url, start, end, allDay, tz, rrule, exdates[], recurrenceParent, members→memberships[], driver→membership, category, reminders[], private, color, source(roost/ics), externalUid, createdBy, updatedBy, deleted |
| `lists` | family, name, kind(todo/grocery/packing), icon, color, owner, sharing{}, storeOrder[], viewers/editors *(server)*, sortOrder, archived, deleted |
| `tasks` | family *(server)*, list, title, notes, due, dueHasTime, assignees→memberships[], priority 0–3, rrule, completed, completedAt, completedBy, parent→tasks, reminders[], tags[], sortOrder, createdBy, deleted |
| `groceryItems` | family *(server)*, list, name, quantity, unit, note, category, categorySource(dictionary/learned/ai/manual), checked, checkedAt, checkedBy, addedBy, sortOrder, deleted |
| `groceryLearned` | family, term, category — the household's corrections |
| `infoCards` | family, title, body, kind(contact/medical/school/routine/home/note), icon, phone, address, aboutMember, pinned, sharing{}, viewers/editors *(server)*, sortOrder, deleted |
| `invites` | family, code, role, name, membership?, expiresAt, createdBy, usedBy, usedAt |
| `feeds` | family, user, token *(server)*, name, calendars[], includeBusy |

### Time representation
- `start`/`end` are UTC instants. `tz` is the IANA zone the event was created in; recurrence is expanded in **wall-clock time in `tz`** so a 4 pm practice stays at 4 pm across DST.
- All-day events: `start` = local midnight of the first day, `end` = local midnight after the last day (exclusive), `allDay = true`.
- An **occurrence key** identifies one instance of a recurring event: local `YYYY-MM-DDTHH:mm` (or `YYYY-MM-DD` for all-day). `exdates` holds occurrence keys.
- Editing **this occurrence** adds its key to the master's `exdates` and creates a standalone event with `recurrenceParent`. **This and following** sets `UNTIL` on the master and creates a new master.

### Recurrence
RFC 5545 RRULE subset: `FREQ` (DAILY/WEEKLY/MONTHLY/YEARLY), `INTERVAL`, `COUNT`, `UNTIL`, `BYDAY` (with ordinals: `2TU`, `-1FR`), `BYMONTHDAY` (incl. negative), `BYMONTH`, `BYSETPOS`, `WKST`. Unknown parts are ignored gracefully (imported feeds).

### Reminders
`reminders` is an array of **minutes before start** (or before due). For all-day events/date-only to-dos the anchor is local midnight, so `900` = "9 AM the day before" and `-540` = "9 AM on the day".
Who is reminded: the event's members and driver (their logins), the creator if nobody is assigned, and anyone who turned on *Notify me about everything* and can see it. To-dos remind assignees (or the creator).

---

## 5. Calendar

**Views** (both apps): Month · Week · 3-Day · Day · Agenda · Year · **People** (a day with one column per family member — the nanny's view).

**Capabilities**
- Color by person (default) or by calendar; filter by person/calendar; search.
- Quick add in plain English: `Soccer practice every Tue 4-5:30pm @Emma driver:Dad remind 30m`.
- Event fields: calendar, time/all-day, repeat (presets + custom), who's involved, **who's driving**, location (opens Maps), link, notes, category, reminders (multiple), private.
- Tasks with due dates appear in Day/Agenda views as checkable rows.
- Overlap layout: side-by-side columns computed by a shared, tested algorithm.

**Connections**
1. **Phone calendars (iOS, EventKit)** — every calendar on the device (Outlook/Exchange, Gmail, iCloud) can be shown in all views; per-calendar toggles; "Copy to my calendar…" on any family event. Two-way on the device, no setup.
2. **Subscribe to a calendar (ICS)** — paste a Google secret iCal address, an Outlook published ICS, or a school/team feed. The server fetches it every 30 min (`Refresh now` available) and everyone with access sees it.
3. **Your Roost feed** — each person gets a private feed URL (filtered to what they're allowed to see) with one-tap links for Apple (`webcal://`), Google and Outlook.
4. **Add to calendar** on any event (`.ics` on web, EventKit on iOS).
5. *(Phase 2)* Direct Google Calendar / Microsoft Graph two-way sync via OAuth.

---

## 6. To-dos

- Multiple lists (Household, Errands, Kids…), each shareable; smart lists: **Today**, **Upcoming**, **Assigned to me**, **Overdue**, **Flagged (priority)**.
- Fields: title, notes, due date (+optional time), assignees, priority (none/low/med/high), repeat, subtasks, reminders, tags.
- Quick add: `Call pediatrician tomorrow 9am @Me !! #Household`.
- Recurring to-dos: completing one logs a completed copy and advances the original to its next due date (shared algorithm).

## 7. Groceries (the "grocery brain")

Pipeline for each line typed or pasted (multi-line paste supported):
1. **Parse quantity & unit**: `2 lbs chicken breast`, `milk x2`, `½ dozen eggs`, `a bag of apples`, `3 avocados`.
2. **Normalize**: lowercase, strip descriptors (organic, fresh, large…), singularize the head noun.
3. **Categorize** (first hit wins): household-learned term → dictionary longest-phrase match (≈1,200 terms, head-noun preference so "chicken broth" → Pantry, "ice cream" → Frozen, "baby spinach" → Produce) → modifier rules (`frozen …` → Frozen, `canned …` → Pantry) → on-device Apple Foundation Models (iOS 26+, when available) or the server's optional local LLM → `Other`.
4. **Merge**: adding "milk" when "Milk" is on the list bumps the quantity instead of duplicating; adding an item that was checked off moves it back.
5. **Learn**: moving an item to another aisle saves the correction for the household (all devices).

Display: grouped by aisle in **your store's order** (drag aisles to reorder per list — e.g. separate "Costco" and "Trader Joe's" lists), quantities as chips, checked items collapse into "In cart", one-tap "Clear checked", and **frequent items** suggestions for re-adding staples.

## 8. Info vault

Cards for emergency contacts, pediatrician, allergies & medications, school info, bedtime routines, Wi-Fi, house notes. Each card is shareable like a calendar (defaults: caregivers and relatives can view). Phone numbers are tap-to-call; addresses open Maps.

## 9. Sync and offline

- **Pull**: `updated > lastSync` per collection (tombstones included), then realtime SSE subscriptions for live changes.
- **Push**: every mutation is applied locally first, appended to a persisted **outbox**, and flushed in order. Conflicts resolve last-writer-wins at the record level; the server echo is authoritative.
- **Local-only mode** (iOS): the app works fully without a server — useful on a plane or for a single-phone trial — and can be connected to a server later.
- Notifications are scheduled **on each device** for the next 14 days of relevant reminders (iOS caps pending local notifications at 64; soonest first). Background app refresh keeps them current.

## 10. Security and privacy

- Self-hosted: the family's data never leaves your server. TLS via Cloudflare Tunnel, Tailscale Funnel, or Caddy.
- Sign-up is closed: the first account bootstraps the family; everyone else needs an invite code (7-day expiry, single use, role pre-set).
- Server-computed access, rule-level enforcement, same-family relation checks, read-only imports.
- ICS feed tokens are 32-byte random, revocable per person; feeds respect the person's access.
- The web app lives at an unlisted path (`ROOST_WEB_PATH`, e.g. `/h/k7q2m9x4/`), sends `X-Robots-Tag: noindex` and `robots.txt: Disallow: /`, and the server root reveals nothing.

## 11. Phase 2 (designed, not built)
- Direct Google/Microsoft OAuth two-way sync (server-side, refresh tokens encrypted at rest).
- APNs push from the server for assignment notifications and server-timed reminders.
- WidgetKit (Today + Groceries), App Intents ("Add eggs to groceries" via Siri / Apple Intelligence), Live Activity for "pickup in 15 min".
- Meal planner → grocery list, chore points for kids.
- An MCP endpoint so home-lab agents can read/write the family calendar and lists.

## 12. Visual design

Warm, calm and legible — closer to a well-made paper planner than a dashboard.

| Token | Light | Dark |
|---|---|---|
| `bg` | `#FAF7F2` warm paper | `#14110E` |
| `surface` | `#FFFFFF` | `#1D1915` |
| `surface2` | `#F3EEE6` | `#27221C` |
| `line` | `#E8E0D4` | `#38302A` |
| `ink` / `ink2` / `ink3` | `#1E1A16` / `#5F564B` / `#938878` | `#F5EFE7` / `#BFB4A6` / `#8C8174` |
| `accent` (ember) | `#D4572A` | `#F0784C` |
| `accentSoft` | `#FBE6DC` | `#3A2219` |

Person colors (12, contrast-checked for white text except amber/lime which use dark text): red `#E5484D`, orange `#F76B15`, amber `#FFB224`, lime `#99D52A`, green `#30A46C`, teal `#12A594`, cyan `#05A2C2`, blue `#0090FF`, indigo `#3E63DD`, violet `#8E4EC6`, pink `#D6409F`, brown `#AD7F58`.

Type: SF Pro Rounded for titles and numerals, SF Pro for body (web: `ui-rounded`/system stack, no web fonts → instant, offline). Radii 10/14/22. Generous touch targets (≥44 pt). Motion: short spring transitions, respects Reduce Motion.

## 13. Testing strategy

| Layer | Tooling | What |
|---|---|---|
| Shared logic | `swift test` (Linux + macOS) and Vitest | Same fixtures: recurrence, grocery, quick-add, layout, access, task recurrence. |
| Server | `go test` with PocketBase test app | Each role's read/write access, invites, family bootstrap, ICS import/export, busy endpoint. |
| Web | Playwright against a real server | Onboarding, events in every view, quick add, grocery grouping, invite → nanny sees the right slice; screenshots. |
| iOS | `xcodebuild` on GitHub-hosted macOS runner | Compile + RoostKit tests on Apple platforms. |
