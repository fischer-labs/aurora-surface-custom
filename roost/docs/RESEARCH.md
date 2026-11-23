# Roost — Research Notes

_November 2026. Inputs to the design in [DESIGN.md](DESIGN.md)._

## 1. What the established family organizers do (feature baseline)

| App | Strengths | Gaps we care about |
|---|---|---|
| **Cozi** | Color-coded shared calendar, shopping + to-do lists, recipe box, "Cozi Today" agenda. | Free tier increasingly paywalled; one flat permission level (everyone sees everything); grocery lists don't auto-sort by aisle. |
| **FamilyWall** | Household hub: chores w/ recurring assignment, messaging, location. | Heavy, ad/upsell driven, no caregiver-specific access. |
| **Skylight / Hearth** | Wall displays that mirror family calendars, chores, meal plans. | Hardware-first; app is a companion. Shows that a big "today at a glance" view is valued. |
| **Apple (Calendar/Reminders + Family Sharing)** | Native, reliable, grocery lists auto-categorize in Reminders (iOS 17+). | No roles: a shared calendar is all-or-nothing; grandparents/nanny need Apple IDs and see everything shared; no "who's driving" or caregiver info cards. |
| **Google Family Calendar** | Ubiquitous; easy sharing. | Same all-or-nothing sharing; no grocery intelligence. |

**Takeaways that shape Roost**

1. The table stakes are: one color-coded family calendar, multiple views, shared to-do + grocery lists, reminders.
2. The differentiators we can deliver for *one* family (not a retail product): **role-scoped access** (nanny, grandparents, kids each see the right slice), **aisle-grouped grocery lists that learn**, **who-is-driving / pickup assignment**, and a **caregiver info vault** (allergies, pediatrician, school contacts, routines).
3. Calendar interop matters more than a proprietary calendar: families already live in Outlook (work), Gmail/Google (personal), iCloud and school ICS feeds.

Sources: [Mailfence — Best family calendar apps 2026](https://blog.mailfence.com/best-family-calendar-app/), [usecarly — Best family organizer apps](https://www.usecarly.com/blog/best-family-organizer-apps/), [ParentMap — apps for busy families](https://www.parentmap.com/article/best-apps-help-busy-families-stay-organized), [Skylight vs Cozi](https://au.myskylight.com/blog-best-family-calendar-app-busy-families-cozi).

## 2. Calendar connectivity options (Outlook, Gmail/Google, iCloud, school feeds)

| Method | Direction | Setup cost | Notes |
|---|---|---|---|
| **EventKit (iOS)** | Read + write | None — uses accounts already in iOS Settings (Exchange/Outlook, Gmail, iCloud, Yahoo) | Best path on iPhone. Roost overlays these calendars in every view and can copy a family event into any of them. |
| **ICS subscription (import)** | Read-only into Roost | Paste a URL | Google "Secret address in iCal format", Outlook "Publish calendar → ICS", school/sports (TeamSnap, GameChanger, district calendars). Fetched **server-side** on a schedule so every family member and the web app see them, and browsers avoid CORS. |
| **ICS feed (export)** | Read-only out of Roost | One tap | Per-person secret feed URL honoring that person's access. Subscribe from Google ("Other calendars → From URL"), Outlook ("Add calendar → Subscribe from web"), Apple (`webcal://`). Outlook can take >24 h to refresh subscribed feeds ([Microsoft](https://support.microsoft.com/en-us/office/import-or-subscribe-to-a-calendar-in-outlook-com-or-outlook-on-the-web-cff1429c-5af6-41ec-a5b4-74f2c278e98c), [MS Q&A](https://learn.microsoft.com/en-us/answers/questions/5751534/how-to-sync-ical-shared-calendar-with-new-outlook)). |
| **Per-event "Add to my calendar"** | Write | None | `.ics` download (web) or EventKit save (iOS). |
| **Direct OAuth (Google Calendar API / Microsoft Graph)** | Two-way | Requires registering OAuth apps in Google Cloud + Entra ID | Designed as Phase 2 (see DESIGN §11). EventKit already gives two-way access on the phone without it. |

## 3. Platform facts checked

- **GitHub-hosted `macos-26` runners** are GA with Xcode 26 as the supported major version; Xcode 27 appeared as a public preview on the image in July 2026 ([GitHub changelog](https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/), [runner-images release](https://newreleases.io/project/github/actions/runner-images/release/macos-26%2F20260729.0423)). We compile the iOS app there because the build machine for this work is Linux.
- **Deployment target iOS 17**: gives `@Observable`, SwiftData-era SwiftUI APIs and covers iPhone XS/XR and newer — important for grandparents' older phones. On-device categorization via Apple's Foundation Models framework is used only when available (iOS 26+, Apple Intelligence devices) and always falls back to the built-in dictionary.
- **PocketBase v0.40.6** (Go 1.27, MIT license) is the current release on the Go module proxy. Note the author announced release hosting is moving off GitHub ([CHANGELOG](https://github.com/pocketbase/pocketbase/releases)). We use it **as a Go library**, so updates are just `go get`, and the server is one static binary.

## 4. Backend options considered

| Option | Verdict |
|---|---|
| **CloudKit (CKShare)** | Zero ops, but sharing is per-zone read-only/read-write — no clean way to give a nanny "kids' calendar + groceries, parents shown as Busy". Web access via CloudKit JS is awkward. Rejected. |
| **Firebase / Supabase (hosted)** | Works, but proprietary (Firebase) or heavy to self-host (Supabase: Postgres + GoTrue + Realtime + Kong). |
| **PocketBase (self-hosted, Go)** ✅ | Open source, single binary + SQLite, built-in auth, realtime (SSE), per-collection API rules, admin UI, scheduled backups to S3. Runs on a home-lab box behind Cloudflare Tunnel/Tailscale or a $5 VPS. Fits the "open source when reasonable" preference. |

## 5. Distribution (not a retail app)

- **TestFlight internal testing** — up to 100 people who are users on your App Store Connect team; no App Review; builds expire after 90 days (automate re-uploads with fastlane/Xcode Cloud).
- **TestFlight external testing** — invite by email/public link; first build of each version needs Beta App Review.
- **Unlisted App Store distribution** — reviewed once, not searchable, installs via direct link; no 90-day expiry. Best long-term option for grandparents.
- **Ad Hoc** — up to 100 registered device UDIDs/year; fiddly for non-technical relatives.

Recommendation: TestFlight internal now → request Unlisted distribution once stable. Details in [DEPLOY.md](DEPLOY.md).
