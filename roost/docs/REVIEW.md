# Independent reviews

Two separate agents reviewed Roost after it was built. Neither had written the code. One reviewed code and security; the other reviewed UX and aesthetics against the screenshots and DESIGN.md. Every finding below has been addressed, and the fixes are covered by tests where a test can check them.

## Code and security review (25 findings)

### Critical and high

| # | Finding | Resolution |
|---|---|---|
| 1 | Editing a list, calendar or care card failed on both apps: clients echoed `family`, which the update rules forbade | The server now accepts `family` when it's unchanged, and clients send only changed fields. Go test `TestUpdatesMayEchoFamily`; the E2E edits a list, an item and a card |
| 2 | The outbox dropped writes on any non-network error (502/530 during a reboot, 429, 401) | Offline, 408, 429 and 5xx are retried with backoff. 400/403/404 drop the change and show it in a notice. A 401 renews the token. Vitest `outbox.test.ts` |
| 3 | A second edit could be folded into the request already in flight, then lost | Nothing is ever folded into the in-flight op; ops are removed by id; the server echo re-applies queued edits. Covered by a test |
| 4 | An expired login lost writes and wiped the offline cache | Expiry keeps the snapshot and outbox and asks you to sign in again. The token is renewed on foreground and every 6 hours. Covered by a test |
| 5 | Busy-only and view-only people could read secret subscription URLs | `sourceUrl` is hidden from anyone who doesn't manage that calendar, including in the refresh response. `TestSubscriptionURLIsPrivate` |
| 6 | A removed or demoted creator could still delete the family | Deleting requires a current owner membership. `TestOnlyCurrentOwnerDeletesFamily` |
| 7 | Saving a stale copy overwrote newer edits and could resurrect deleted events | Updates are field diffs and never include `deleted` unless it changed. A sync no longer overwrites records touched while it was running |

### Medium

| # | Finding | Resolution |
|---|---|---|
| 8 | Someone merely assigned a task could rewrite it | Assignees can only complete it, or roll a repeating one forward. `TestAssigneeCanOnlyComplete` |
| 9 | Grocery editors, kids included, could soft-delete a list or change its kind | `deleted`, `kind` and `archived` are manage-only. `TestEditorsCantDeleteOrRetypeLists` |
| 10 | Malformed JSON broke ICS feeds and crashed the web calendar | The server validates exdates, reminders, tags, storeOrder, time zones and due dates. The ICS writer has guards; the web has an error boundary. `TestJSONShapesValidated` |
| 11 | Repeating-event edits brought back deleted occurrences and dropped COUNT | "All events" shifts skipped dates with the series. "Following" keeps the later skips and the remaining COUNT. Deleting a series removes its edited children. Vitest series tests |
| 12 | All-day events showed on the wrong day in other time zones | All-day events are floating dates on both platforms. RoostKit `FloatingDateTests` |
| 13 | Removed people kept the cached care info indefinitely | A 403/404 on the family wipes the cache |
| 14 | The web snapshot and outbox shared one localStorage key and silently hit the quota | The outbox has its own small key, written synchronously. The snapshot falls back to a smaller copy |
| 15 | Siri changes and "Mark done" from a notification weren't durable | Siri writes to disk immediately. "Mark done" bootstraps the app on a cold launch and only ever completes |
| 16 | Snooze was cancelled almost immediately | Snoozes use their own prefix |
| 17 | The web didn't resync after realtime reconnected | It catches up on `PB_CONNECT` and also syncs every 5 minutes |
| 18 | Items in deleted calendars and lists still showed and still reminded | Hidden and skipped on both platforms |

### Low

| # | Finding | Resolution |
|---|---|---|
| 19 | SSRF guard gaps (DNS rebinding, CGNAT/Tailscale, NAT64; unthrottled refresh) | The guard checks the IP actually dialled and the blocklist is wider. Refresh is limited to once per 30 s per calendar. `TestBlockedIPs`, `TestManualRefreshThrottle` |
| 20 | ICS line injection through `url`/`tz` | CR/LF are rejected on save and stripped on output, and the TZID is the validated zone |
| 21 | Weak sign-up gate | The first account needs the setup code from the server log, each invite makes one account, and rate limits are on. `TestSetupCodeGuardsFirstAccount`, `TestInviteMakesOneAccount` |
| 22 | Anyone in the family could rewrite learned grocery terms | Grocery editors only. `TestLearnedTermsNeedGroceryAccess` |
| 23 | iOS ran a full sync for every realtime message | Realtime syncs are debounced and run one at a time |
| 24 | iOS treated a non-JSON 200 (a captive portal) as success | Treated as offline |
| 25 | Task times used the device time zone | They use the family time zone; due dates are floating |
| — | Siri split "half and half" into two items | Known "X and Y" products stay whole. RoostKit `SpokenListTests` |

## UX and aesthetic review (17 findings)

| # | Finding | Resolution |
|---|---|---|
| 1 | White text on person colors failed AA; amber and lime had white text | Darker fill shades are used wherever text sits on a person color, with dark text on amber and lime. Applies to avatars, all-day chips and the Up next card on both platforms |
| 2 | Ember and ink3 failed AA; dark-mode buttons were 2.8:1 | New tokens: ember `#B4461E`, `accentFill` `#C2491F`, ink3 `#756A5D` / `#9C9182`. See DESIGN.md §12 |
| 3 | Check-off targets were too small, and tapping a grocery opened the editor | 44 pt hit areas. Tapping a grocery row checks it off; Edit moved to the ⋯ menu (web) and a swipe (iOS) |
| 4 | iOS smart-list tiles had stray chevrons | Plain buttons with a navigation path |
| 5 | The phone month view was unreadable | Colored bars, larger dates and "+N" overflow. Next-month events are no longer faded |
| 6 | Week and People grids truncated titles and opened mid-event | Titles wrap, and the grid never opens with an event cut off at the top. The iOS People view scrolls sideways at 88 pt per column |
| 7 | Avatar stacks hid initials | Less overlap and a single initial on small avatars. White-ring avatars on the hero card |
| 8 | Ember was doing too many jobs | Ember is reserved for action, today and selection. Icons and heat maps are neutral, priority uses danger, orange is assigned to people last |
| 9 | Dark mode: indistinct tints and cool-gray iOS rows | 30% tints with a person-color bar; warm row backgrounds; black shadow on the hero card |
| 10 | iOS Dynamic Type | Rounded large-title greeting; care cards grow and stack at accessibility sizes |
| 11 | Unlabeled sync icon in the iOS toolbar | Moved into the header as "Saved on this phone only" |
| 12 | Care info previews showed blank fields | Blank lines hidden, phone numbers don't break, Call actions, one name ("Care info") |
| 13 | The web phone calendar header took three rows | Title shares a row with navigation; New is a floating button with "More options" |
| 14 | Grocery add bar | Short placeholder plus a hint; Add appears only once there's text; "Buy again" label |
| 15 | Web Today duplicates | A glance line replaces the repeated family name; tighter spacing on phones |
| 16 | Plain language | Relative, Household, Add child, sentence-case labels; Overdue dims at zero |
| 17 | Non-rounded iOS large titles | Rounded navigation titles |

Screenshots in `docs/screenshots/` (web, from the E2E run) and `docs/screenshots/ios/` (Simulator, from CI) show the results.
