# Deploying Roost

Roost has three pieces:

| Piece | What it is | Where it runs |
|---|---|---|
| **roost-server** | One Go binary (PocketBase + Roost). Stores everything in SQLite, serves the API, realtime updates, ICS feeds and the web app. | Your home-lab box (Docker) or a $5 VPS |
| **Web app** | The browser/PWA version, served by the server at an **unlisted path**. | Same server (or any static host) |
| **iPhone app** | Native SwiftUI app. Distributed to the family with TestFlight (or as an Unlisted App Store app). | Family iPhones |

Budget about an hour the first time. Steps 1–3 are yours; step 4 is the family.

---

## 0. Checklist of things only you can do

- [ ] Pick where the server lives (home lab + Cloudflare Tunnel, or a VPS) and a host name, e.g. `family.example.com`.
- [ ] Apple Developer: note your **Team ID**, register a **bundle ID** (e.g. `com.yourname.roost`), create an **App Store Connect app record**.
- [ ] Optional: App Store Connect **API key** (for one-command TestFlight uploads with fastlane).
- [ ] Optional: S3-compatible bucket for off-site backups (Backblaze B2, Cloudflare R2, AWS S3).

---

## 1. Run the server

### Option A — Your home-lab server (recommended)

Roost runs as one container on any of your Linux boxes. The web app is served by that same container at an unlisted path, so **desktop access is just a bookmark** — it isn't linked from any other site. How people reach it:

| Who | How | Setup |
|---|---|---|
| You, on home-lab / tailnet machines | `https://homelab.<tailnet>.ts.net/h/9f3c1a7e2b/` | `tailscale serve --bg 8090` on the server (Tailscale issues the HTTPS cert) |
| Anyone on the home LAN | `http://homelab.local:8090/h/9f3c1a7e2b/` | change the compose port to `"0.0.0.0:8090:8090"` (browsers only; the iPhone app requires HTTPS) |
| Nanny, grandparents, phones away from home | `https://family.example.com/...` | Cloudflare Tunnel (below) — no open router ports, free TLS |

Start it:

```bash
git clone -b claude/family-org-app-izwsw6 https://github.com/fischer-labs/aurora-surface-custom.git
cd aurora-surface-custom/roost
cp deploy/example.env .env
deploy/new-web-path.sh            # e.g. /h/9f3c1a7e2b/  → paste into ROOST_WEB_PATH in .env
docker compose up -d --build      # builds web + server into one ~55 MB image
```

To make it reachable from anywhere (needed for the iPhone app outside your network and for the nanny/grandparents), in the Cloudflare dashboard: **Zero Trust → Networks → Tunnels → Create tunnel**, copy the token into `CLOUDFLARE_TUNNEL_TOKEN` in `.env`, add a public hostname `family.example.com → http://roost:8090`, and run:

```bash
docker compose --profile tunnel up -d
```

### Option B — Small VPS with Caddy

```bash
# on the VPS, after cloning as above
docker compose up -d --build
sudo apt install caddy && sudo cp deploy/Caddyfile /etc/caddy/Caddyfile   # edit the host name
sudo systemctl reload caddy
```

### Option C — No Docker

```bash
cd roost/web && npm ci && npx vite build
cd ../server && CGO_ENABLED=0 go build -o roost-server .
sudo cp roost-server /usr/local/bin/ && sudo mkdir -p /opt/roost/web && sudo cp -r ../web/dist/* /opt/roost/web/
echo "ROOST_WEB_PATH=/h/9f3c1a7e2b/" | sudo tee /etc/roost.env
sudo cp ../deploy/roost.service /etc/systemd/system/ && sudo systemctl enable --now roost
```

### First-time server setup

1. **Admin account** (for the PocketBase dashboard — backups, email, troubleshooting):
   ```bash
   docker compose exec roost /app/roost-server superuser upsert you@example.com 'a-long-unique-password' --dir=/app/pb_data
   ```
   Dashboard: `https://family.example.com/_/`. Consider putting `/_/` behind Cloudflare Access.
2. **Backups**: Dashboard → Settings → Backups → enable daily backups and (ideally) S3 storage. The whole family's data is `pb_data/` — a few MB.
3. **Email (optional)**: Dashboard → Settings → Mail settings → SMTP, so people can reset forgotten passwords.
4. **Smart grocery sorting with a local model (optional)**: set `ROOST_LLM_URL=http://<ollama-host>:11434/v1` and `ROOST_LLM_MODEL` in `.env`. Only item names the built-in 2,374-term dictionary doesn't know are sent, and only to your own model.

### Check it

```bash
curl https://family.example.com/api/roost/config     # {"name":"Roost",...}
curl -I https://family.example.com/                   # 404 — the root reveals nothing
open https://family.example.com/h/9f3c1a7e2b/         # the web app
```

The **first account created becomes the family owner**. So that nobody else can claim a freshly started server, that first sign-up asks for a **setup code** printed in the server log:

```bash
docker compose logs roost | grep "Setup code"     # → Setup code: K7QM-2XPD
```

(Set your own with `ROOST_SETUP_CODE` in `.env`, or `off` to skip.) After the first family exists, sign-up only works with an invite code, and each invite creates at most one account.

---

## 2. The web app at an unlisted path

The server serves the web app only at `ROOST_WEB_PATH`. Nothing links to it, every response carries `X-Robots-Tag: noindex`, `robots.txt` disallows everything, and the root path returns an empty 404. Bookmark it, and on phones use **Share → Add to Home Screen** to install it like an app.

**Hosting the web app on another site you already run** (e.g. a hidden folder on your own website) instead of on the Roost server:

```bash
cd roost/web
VITE_ROOST_API_URL=https://family.example.com npx vite build --base=/family-9f3c1a/
# upload dist/ to https://your-site.example.com/family-9f3c1a/ (with SPA fallback to index.html)
```

Then restrict the API to that origin: add `--origins=https://your-site.example.com` to the server's `serve` command.

---

## 3. Build the iPhone app

1. On your Mac (Xcode 26+), edit `roost/ios/Config.xcconfig`:
   ```
   DEVELOPMENT_TEAM = ABCDE12345
   ROOST_BUNDLE_ID = com.yourname.roost
   ROOST_SERVER_HOST = family.example.com
   ```
2. Generate the project: `brew install xcodegen && cd roost/ios && xcodegen` (a pre-generated `Roost.xcodeproj` is also committed).
3. Open `Roost.xcodeproj`, pick your iPhone, **Run**. Signing is automatic.
4. Try it without a server: launch with the `-RoostDemo 1` argument (Scheme → Run → Arguments) to explore a sample family, or choose **“Try it on this phone only”** on the welcome screen.

### Ship to the family with TestFlight

**From Xcode:** Product → Archive → Distribute App → App Store Connect → Upload.

**Or with fastlane** (needs an App Store Connect API key):
```bash
cd roost/ios && bundle install
export ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_PATH=~/keys/AuthKey_XXXX.p8
export ROOST_BUNDLE_ID=com.yourname.roost ROOST_TEAM_ID=ABCDE12345
bundle exec fastlane create_app     # first time only
bundle exec fastlane beta
```

**Who gets it:**

| Option | Good for | Notes |
|---|---|---|
| TestFlight **internal** | You and your partner | Testers must be users on your App Store Connect team. No review. |
| TestFlight **external** (public link) | Nanny, grandparents | First build of each version gets a quick Beta App Review. Builds expire after 90 days — re-run `fastlane beta`. |
| **Unlisted App Store app** | Long term | One App Review; not searchable; install from a private link; no expiry. Request via Apple's unlisted-app form once the app is live. |

For App Review / external testing, give reviewers demo access: create an invite code for a test login, or note that `Try it on this phone only` works without an account. The app collects no data for Apple's privacy label (it's your server); a privacy manifest is included.

---

## 4. Bring the family in

1. Open **Family → People & roles → Invite**. Pick a role:
   - **Parent** — everything except removing the owner.
   - **Caregiver** (nanny/sitter) — family + kids' calendars, groceries, to-dos assigned to them, care info; sees parents' personal calendars as **Busy**.
   - **Family** (grandparents) — family calendar and care info, read-only.
   - **Kid** — family calendar, groceries, their own to-dos.
2. Send the code (Copy/Email invite). It works once and expires after 7 days.
   - **iPhone**: install from TestFlight → “I have an invite code”.
   - **Android / computer**: open `https://family.example.com/h/9f3c1a7e2b/?code=K7QM-2XPD`.
3. Kids without phones: **Add a profile (no login)** — you can still assign events and to-dos to them.
4. Fine-tune any calendar, list or care card under its **Who can see it** section (per role, plus per-person exceptions).

### Connect Outlook, Gmail and iCloud

- **On iPhone** (two-way, nothing leaves the phone): Settings → Apps → Calendar → Calendar Accounts → add Outlook/Exchange and Google accounts. Then in Roost: Calendar → Filter → “Show my Outlook, Gmail & iCloud calendars”.
- **Into Roost for everyone** (read-only): Family → Calendars → **Subscribe to a link** — paste Google's “Secret address in iCal format”, Outlook's published ICS link, or a school/team feed. Refreshes every 30 minutes.
- **Roost into Google/Outlook/Apple** (read-only): Family → Calendars → **Get my feed link** → Add to Google / Outlook / Apple. Google refreshes every few hours; Outlook can take up to a day.

---

## Updating

```bash
cd aurora-surface-custom && git pull && cd roost && docker compose up -d --build
```
Database migrations run automatically at start. TestFlight builds expire after 90 days, so run `fastlane beta` at least quarterly (or switch to Unlisted distribution).

## Troubleshooting

| Symptom | Fix |
|---|---|
| App says “Can't reach your Roost server” | Check `curl https://host/api/health`; on iPhone, Family → Settings shows the server and pending changes (they sync automatically when it's back). |
| A subscription shows ⚠ | The link is wrong or private-network. Open it in a browser — it should download an `.ics` file. LAN feeds need `ROOST_ALLOW_PRIVATE_FEEDS=1`. |
| Someone sees too much/too little | Family → Calendars (or the list's settings) → Who can see it. Roles change instantly for everyone. |
| No reminders on iPhone | Family → Settings → Notifications → Turn on. Reminders cover events you're in/driving and to-dos assigned to you, unless “Remind me about every family event” is on. |
| Forgot the owner password | Dashboard `/_/` → users → set a new password. |

## Security notes

- The first account needs the setup code from the server log; after that, sign-up is invite-only. Each invite code creates one account, joins once and expires in 7 days.
- PocketBase rate limits are on (sign-in guessing is throttled). `ROOST_RATE_LIMIT=off` disables them.
- Access is enforced on the server (API rules + hooks, covered by Go integration tests per role), not just hidden in the apps.
- Personal ICS feed URLs are secret 32-byte tokens; delete the feed (Family → Calendars) to revoke.
- Subscription fetching refuses private, loopback, link-local, CGNAT/Tailscale and NAT64 addresses (checked again at connect time, so DNS tricks don't help) unless you opt in, so a pasted link can't probe your LAN.
- Subscription links (often a "secret address" for someone's personal calendar) are only shown to the people who manage that calendar — not to those who merely see it or its busy times.
- AI assistant keys are stored only as SHA-256 hashes and act with exactly their owner's access; revoke them in Family → Settings.
- Keep `pb_data/` backed up and off public file shares; it contains everything.
