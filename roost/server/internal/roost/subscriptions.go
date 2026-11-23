package roost

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

const maxICSBytes = 8 << 20

// fetchURLHook lets tests replace network fetches.
var fetchURLHook func(ctx context.Context, u string) (io.ReadCloser, error)

func normalizeFeedURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if strings.HasPrefix(strings.ToLower(raw), "webcal://") {
		raw = "https://" + raw[len("webcal://"):]
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return "", errors.New("enter an https:// or webcal:// calendar link")
	}
	return u.String(), nil
}

// checkHostAllowed refuses private/loopback targets unless allowed, so a feed
// URL can't be used to probe the home network.
func checkHostAllowed(ctx context.Context, host string, allowPrivate bool) error {
	if allowPrivate {
		return nil
	}
	ips, err := net.DefaultResolver.LookupIP(ctx, "ip", host)
	if err != nil {
		return err
	}
	for _, ip := range ips {
		if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() {
			return fmt.Errorf("refusing to fetch from private address %s (set ROOST_ALLOW_PRIVATE_FEEDS=1 to allow)", ip)
		}
	}
	return nil
}

func feedClient(allowPrivate bool) *http.Client {
	return &http.Client{
		Timeout: 45 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return errors.New("too many redirects")
			}
			return checkHostAllowed(req.Context(), req.URL.Hostname(), allowPrivate)
		},
	}
}

func fetchFeed(ctx context.Context, cfg Config, u string) (io.ReadCloser, error) {
	if fetchURLHook != nil {
		return fetchURLHook(ctx, u)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "Roost-Calendar/1.0")
	req.Header.Set("Accept", "text/calendar, */*")
	if err := checkHostAllowed(ctx, req.URL.Hostname(), cfg.AllowPrivateFeeds); err != nil {
		return nil, err
	}
	res, err := feedClient(cfg.AllowPrivateFeeds).Do(req)
	if err != nil {
		return nil, err
	}
	if res.StatusCode != http.StatusOK {
		res.Body.Close()
		return nil, fmt.Errorf("calendar server answered %s", res.Status)
	}
	return struct {
		io.Reader
		io.Closer
	}{io.LimitReader(res.Body, maxICSBytes), res.Body}, nil
}

// asyncInitialSync fetches a new subscription in the background right after
// it's created (disabled in tests).
var asyncInitialSync = true

// syncLocks serializes syncs per calendar (cron, manual refresh, initial fetch).
var syncLocks sync.Map

// SyncSubscription refreshes one subscription calendar.
func SyncSubscription(app core.App, cfg Config, cal *core.Record) error {
	mu, _ := syncLocks.LoadOrStore(cal.Id, &sync.Mutex{})
	mu.(*sync.Mutex).Lock()
	defer mu.(*sync.Mutex).Unlock()
	if fresh, err := app.FindRecordById("calendars", cal.Id); err == nil {
		cal = fresh
	}
	src, err := normalizeFeedURL(cal.GetString("sourceUrl"))
	if err != nil {
		return markSync(app, cal, err)
	}
	family, err := app.FindRecordById("families", cal.GetString("family"))
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	body, err := fetchFeed(ctx, cfg, src)
	if err != nil {
		return markSync(app, cal, err)
	}
	defer body.Close()
	parsed, err := ParseICS(body, family.GetString("timezone"))
	if err != nil {
		return markSync(app, cal, err)
	}
	if err := upsertImported(app, cal, parsed); err != nil {
		return markSync(app, cal, err)
	}
	return markSync(app, cal, nil)
}

func markSync(app core.App, cal *core.Record, syncErr error) error {
	cal.Set("lastSyncedAt", types.NowDateTime())
	if syncErr != nil {
		msg := syncErr.Error()
		if len(msg) > 480 {
			msg = msg[:480]
		}
		cal.Set("syncError", msg)
	} else {
		cal.Set("syncError", "")
	}
	if err := app.Save(cal); err != nil {
		return err
	}
	return syncErr
}

func upsertImported(app core.App, cal *core.Record, parsed []ParsedEvent) error {
	coll, err := app.FindCollectionByNameOrId("events")
	if err != nil {
		return err
	}
	existing, err := app.FindAllRecords("events", dbx.HashExp{"calendar": cal.Id, "source": "ics"})
	if err != nil {
		return err
	}
	byUID := map[string]*core.Record{}
	for _, r := range existing {
		byUID[r.GetString("externalUid")] = r
	}
	// Overridden instances become exdates on their master + standalone events.
	overrides := map[string][]string{}
	for _, p := range parsed {
		if p.RecurrenceID != "" {
			overrides[p.UID] = append(overrides[p.UID], p.RecurrenceID)
		}
	}
	seen := map[string]bool{}
	return app.RunInTransaction(func(tx core.App) error {
		for _, p := range parsed {
			key := p.UID
			if p.RecurrenceID != "" {
				key = p.UID + "#" + p.RecurrenceID
			}
			if key == "" || seen[key] {
				continue
			}
			if p.Cancelled {
				if p.RecurrenceID != "" {
					continue // already excluded from the master via overrides
				}
				continue
			}
			seen[key] = true
			rec := byUID[key]
			if rec == nil {
				rec = core.NewRecord(coll)
				rec.Set("calendar", cal.Id)
				rec.Set("family", cal.GetString("family"))
				rec.Set("source", "ics")
				rec.Set("externalUid", key)
			}
			title := strings.TrimSpace(p.Summary)
			if title == "" {
				title = "(No title)"
			}
			if len(title) > 200 {
				title = title[:200]
			}
			ex := append([]string{}, p.ExDates...)
			ex = append(ex, overrides[p.UID]...)
			if p.RecurrenceID != "" {
				ex = nil
			}
			rr := p.RRule
			if p.RecurrenceID != "" {
				rr = ""
			}
			fields := map[string]any{
				"title":    title,
				"notes":    truncate(p.Description, 10000),
				"location": truncate(p.Location, 300),
				"url":      truncate(p.URL, 1000),
				"start":    p.Start.UTC(),
				"end":      p.End.UTC(),
				"allDay":   p.AllDay,
				"tz":       p.TZ,
				"rrule":    rr,
				"exdates":  ex,
				"deleted":  false,
			}
			changed := rec.IsNew()
			for k, v := range fields {
				if !changed && fmt.Sprint(rec.Get(k)) != fmt.Sprint(normalizeForCompare(rec, k, v)) {
					changed = true
				}
				rec.Set(k, v)
			}
			if changed {
				if err := tx.Save(rec); err != nil {
					return err
				}
			}
		}
		for key, r := range byUID {
			if !seen[key] && !r.GetBool("deleted") {
				r.Set("deleted", true)
				if err := tx.Save(r); err != nil {
					return err
				}
			}
		}
		return nil
	})
}

// normalizeForCompare converts a value the way the record would store it so
// unchanged events aren't re-saved (which would bump `updated` and wake clients).
func normalizeForCompare(rec *core.Record, key string, v any) any {
	clone := rec.Fresh()
	clone.Set(key, v)
	return clone.Get(key)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// syncDueSubscriptions is run by cron.
func syncDueSubscriptions(app core.App, cfg Config) {
	cals, err := app.FindAllRecords("calendars", dbx.HashExp{"kind": "subscription", "deleted": false})
	if err != nil {
		app.Logger().Error("roost: list subscriptions", "error", err)
		return
	}
	for _, c := range cals {
		last := c.GetDateTime("lastSyncedAt")
		if !last.IsZero() && time.Since(last.Time()) < cfg.SubscriptionRefresh-time.Minute {
			continue
		}
		if err := SyncSubscription(app, cfg, c); err != nil {
			app.Logger().Warn("roost: subscription sync failed", "calendar", c.Id, "error", err)
		}
	}
}
