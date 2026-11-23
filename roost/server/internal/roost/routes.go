package roost

import (
	"net/http"
	"strings"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

func registerRoutes(se *core.ServeEvent, cfg Config) {
	r := se.Router

	r.GET("/api/roost/config", func(e *core.RequestEvent) error {
		return e.JSON(http.StatusOK, map[string]any{
			"name":        "Roost",
			"version":     Version,
			"categorizer": cfg.LLMURL != "",
			"openSignup":  cfg.OpenSignup,
		})
	})

	// Public invite preview so the sign-up screen can say who you're joining.
	r.GET("/api/roost/invites/{code}", func(e *core.RequestEvent) error {
		inv := findValidInvite(e.App, e.Request.PathValue("code"))
		if inv == nil {
			return e.NotFoundError("That invite code isn't valid or has expired.", nil)
		}
		fam, err := e.App.FindRecordById("families", inv.GetString("family"))
		if err != nil {
			return e.NotFoundError("Family not found.", nil)
		}
		return e.JSON(http.StatusOK, map[string]any{
			"family": fam.GetString("name"),
			"role":   inv.GetString("role"),
			"name":   inv.GetString("name"),
		})
	})

	r.POST("/api/roost/join", func(e *core.RequestEvent) error {
		var body struct {
			Code string `json:"code"`
			Name string `json:"name"`
		}
		if err := e.BindBody(&body); err != nil {
			return e.BadRequestError("Invalid body.", err)
		}
		var result map[string]any
		err := e.App.RunInTransaction(func(tx core.App) error {
			inv := findValidInvite(tx, body.Code)
			if inv == nil {
				return e.NotFoundError("That invite code isn't valid or has expired.", nil)
			}
			famID := inv.GetString("family")
			if existing := membershipFor(tx, famID, e.Auth.Id); existing != nil {
				result = map[string]any{"family": famID, "membership": existing.Id, "already": true}
				return nil
			}
			var m *core.Record
			if mid := inv.GetString("membership"); mid != "" {
				pm, err := tx.FindRecordById("memberships", mid)
				if err == nil && pm.GetString("user") == "" {
					m = pm
				}
			}
			if m == nil {
				coll, err := tx.FindCollectionByNameOrId("memberships")
				if err != nil {
					return err
				}
				m = core.NewRecord(coll)
				m.Set("family", famID)
				name := strings.TrimSpace(body.Name)
				if name == "" {
					name = inv.GetString("name")
				}
				if name == "" {
					name = e.Auth.GetString("name")
				}
				if name == "" {
					name = "New member"
				}
				m.Set("name", name)
				color := inv.GetString("color")
				if color == "" {
					color = nextColor(tx, famID)
				}
				m.Set("color", color)
				n, _ := tx.CountRecords("memberships", dbx.HashExp{"family": famID})
				m.Set("sortOrder", n)
			}
			m.Set("user", e.Auth.Id)
			m.Set("role", inv.GetString("role"))
			if err := tx.Save(m); err != nil {
				return err
			}
			inv.Set("usedBy", e.Auth.Id)
			inv.Set("usedAt", types.NowDateTime())
			if err := tx.Save(inv); err != nil {
				return err
			}
			if err := RecomputeFamily(tx, famID); err != nil {
				return err
			}
			result = map[string]any{"family": famID, "membership": m.Id}
			return nil
		})
		if err != nil {
			return err
		}
		return e.JSON(http.StatusOK, result)
	}).Bind(apis.RequireAuth("users"))

	// Busy blocks: events the caller may only see as "Busy".
	r.GET("/api/roost/busy", func(e *core.RequestEvent) error {
		fam := e.Request.URL.Query().Get("family")
		if membershipFor(e.App, fam, e.Auth.Id) == nil {
			return e.ForbiddenError("Not a member of this family.", nil)
		}
		from, to := parseRange(e.Request.URL.Query().Get("from"), e.Request.URL.Query().Get("to"))
		blocks, err := busyBlocks(e.App, fam, e.Auth.Id, from, to)
		if err != nil {
			return err
		}
		return e.JSON(http.StatusOK, map[string]any{"items": blocks})
	}).Bind(apis.RequireAuth("users"))

	r.POST("/api/roost/calendars/{id}/refresh", func(e *core.RequestEvent) error {
		cal, err := e.App.FindRecordById("calendars", e.Request.PathValue("id"))
		if err != nil || cal.GetString("kind") != "subscription" {
			return e.NotFoundError("Subscription not found.", nil)
		}
		if !contains(cal.GetStringSlice("viewers"), e.Auth.Id) {
			return e.ForbiddenError("No access to this calendar.", nil)
		}
		syncErr := SyncSubscription(e.App, cfg, cal)
		fresh, _ := e.App.FindRecordById("calendars", cal.Id)
		resp := map[string]any{"ok": syncErr == nil, "calendar": fresh}
		if syncErr != nil {
			resp["error"] = syncErr.Error()
		}
		return e.JSON(http.StatusOK, resp)
	}).Bind(apis.RequireAuth("users"))

	r.POST("/api/roost/categorize", func(e *core.RequestEvent) error {
		if cfg.LLMURL == "" {
			return e.JSON(http.StatusOK, map[string]any{"categories": map[string]string{}, "enabled": false})
		}
		var body struct {
			Family string   `json:"family"`
			Items  []string `json:"items"`
		}
		if err := e.BindBody(&body); err != nil || len(body.Items) == 0 {
			return e.BadRequestError("Provide items.", nil)
		}
		if membershipFor(e.App, body.Family, e.Auth.Id) == nil {
			return e.ForbiddenError("Not a member of this family.", nil)
		}
		if len(body.Items) > 40 {
			body.Items = body.Items[:40]
		}
		cats, err := categorizeWithLLM(e.Request.Context(), cfg, body.Items)
		if err != nil {
			e.App.Logger().Warn("roost: categorizer failed", "error", err)
			return e.JSON(http.StatusOK, map[string]any{"categories": map[string]string{}, "enabled": true, "error": "categorizer unavailable"})
		}
		return e.JSON(http.StatusOK, map[string]any{"categories": cats, "enabled": true})
	}).Bind(apis.RequireAuth("users"))

	// Per-person ICS feed. Token is the credential; ".ics" suffix optional.
	r.GET("/api/roost/ics/{token}", func(e *core.RequestEvent) error {
		token := strings.TrimSuffix(e.Request.PathValue("token"), ".ics")
		if len(token) < 20 {
			return e.NotFoundError("", nil)
		}
		feed, err := e.App.FindFirstRecordByData("feeds", "token", token)
		if err != nil {
			return e.NotFoundError("", nil)
		}
		body, err := buildFeed(e.App, feed, time.Now())
		if err != nil {
			return err
		}
		e.Response.Header().Set("Cache-Control", "private, max-age=300")
		e.Response.Header().Set("Content-Disposition", `inline; filename="roost.ics"`)
		return e.Blob(http.StatusOK, "text/calendar; charset=utf-8", []byte(body))
	})

	r.GET("/robots.txt", func(e *core.RequestEvent) error {
		return e.String(http.StatusOK, "User-agent: *\nDisallow: /\n")
	})

	registerWeb(se, cfg)
}

func parseRange(fromS, toS string) (time.Time, time.Time) {
	from, err := time.Parse(time.RFC3339, fromS)
	if err != nil {
		from = time.Now().AddDate(0, -1, 0)
	}
	to, err := time.Parse(time.RFC3339, toS)
	if err != nil || !to.After(from) {
		to = from.AddDate(0, 3, 0)
	}
	if to.Sub(from) > 400*24*time.Hour {
		to = from.Add(400 * 24 * time.Hour)
	}
	return from, to
}

type busyBlock struct {
	ID       string   `json:"id"`
	Calendar string   `json:"calendar"`
	Start    string   `json:"start"`
	End      string   `json:"end"`
	AllDay   bool     `json:"allDay"`
	TZ       string   `json:"tz"`
	RRule    string   `json:"rrule"`
	ExDates  []string `json:"exdates"`
	Members  []string `json:"members"`
	Title    string   `json:"title"`
}

// busyBlocks returns sanitized masters (clients expand recurrence) for
// calendars shared as "busy" plus private events the caller can't open.
func busyBlocks(app core.App, familyID, uid string, from, to time.Time) ([]busyBlock, error) {
	cals, err := app.FindAllRecords("calendars", dbx.HashExp{"family": familyID, "deleted": false})
	if err != nil {
		return nil, err
	}
	out := []busyBlock{}
	for _, c := range cals {
		busyOnly := contains(c.GetStringSlice("busyViewers"), uid)
		viewer := contains(c.GetStringSlice("viewers"), uid)
		editor := contains(c.GetStringSlice("editors"), uid)
		if !busyOnly && !(viewer && !editor) {
			continue
		}
		filter := "calendar = {:c} && deleted = false && (rrule != '' || (start < {:to} && end > {:from}))"
		if !busyOnly {
			filter += " && private = true && createdBy != {:u}"
		}
		evs, err := app.FindRecordsByFilter("events", filter, "start", 2000, 0, dbx.Params{
			"c": c.Id, "from": from.UTC().Format(types.DefaultDateLayout), "to": to.UTC().Format(types.DefaultDateLayout), "u": uid,
		})
		if err != nil {
			return nil, err
		}
		for _, ev := range evs {
			var ex []string
			_ = ev.UnmarshalJSONField("exdates", &ex)
			out = append(out, busyBlock{
				ID: ev.Id, Calendar: c.Id, Start: ev.GetDateTime("start").String(), End: ev.GetDateTime("end").String(),
				AllDay: ev.GetBool("allDay"), TZ: ev.GetString("tz"), RRule: ev.GetString("rrule"), ExDates: ex,
				Members: ev.GetStringSlice("members"), Title: "Busy",
			})
		}
	}
	return out, nil
}

func buildFeed(app core.App, feed *core.Record, now time.Time) (string, error) {
	uid := feed.GetString("user")
	fam, err := app.FindRecordById("families", feed.GetString("family"))
	if err != nil {
		return "", err
	}
	if !contains(fam.GetStringSlice("members"), uid) {
		return WriteICS("Roost", fam.GetString("timezone"), nil, now), nil
	}
	var only []string
	_ = feed.UnmarshalJSONField("calendars", &only)
	cals, err := app.FindAllRecords("calendars", dbx.HashExp{"family": fam.Id, "deleted": false})
	if err != nil {
		return "", err
	}
	horizon := now.AddDate(0, 0, -60).UTC().Format(types.DefaultDateLayout)
	var events []ICSEvent
	for _, c := range cals {
		if len(only) > 0 && !contains(only, c.Id) {
			continue
		}
		viewer := contains(c.GetStringSlice("viewers"), uid)
		editor := contains(c.GetStringSlice("editors"), uid)
		busy := contains(c.GetStringSlice("busyViewers"), uid)
		if !viewer && !(busy && feed.GetBool("includeBusy")) {
			continue
		}
		evs, err := app.FindRecordsByFilter("events", "calendar = {:c} && deleted = false && (rrule != '' || end >= {:h})", "start", 5000, 0,
			dbx.Params{"c": c.Id, "h": horizon})
		if err != nil {
			return "", err
		}
		for _, ev := range evs {
			masked := !viewer || (ev.GetBool("private") && !editor && ev.GetString("createdBy") != uid)
			var ex []string
			_ = ev.UnmarshalJSONField("exdates", &ex)
			ie := ICSEvent{
				UID:     ev.Id + "@roost",
				Start:   ev.GetDateTime("start").Time(),
				End:     ev.GetDateTime("end").Time(),
				AllDay:  ev.GetBool("allDay"),
				TZ:      ev.GetString("tz"),
				RRule:   ev.GetString("rrule"),
				ExDates: ex,
				Updated: ev.GetDateTime("updated").Time(),
				Busy:    masked,
			}
			if !masked {
				ie.Summary = ev.GetString("title")
				ie.Description = ev.GetString("notes")
				ie.Location = ev.GetString("location")
				ie.URL = ev.GetString("url")
				if cat := ev.GetString("category"); cat != "" {
					ie.Categories = []string{cat}
				}
			}
			events = append(events, ie)
		}
	}
	name := feed.GetString("name")
	if name == "" {
		name = fam.GetString("name")
	}
	return WriteICS(name, fam.GetString("timezone"), events, now), nil
}
