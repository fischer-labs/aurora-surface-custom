package roost

import (
	"encoding/json"
	"fmt"
	"regexp"
	"sync"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

// Server-side guards that keep one family member (or a buggy client) from
// hurting the others. See docs/DESIGN.md §9.

func registerHardening(app core.App, cfg Config) {
	// A subscription's URL is often a secret ("private iCal address"), so
	// only the people who manage the calendar can read it back.
	app.OnRecordEnrich("calendars").BindFunc(func(e *core.RecordEnrichEvent) error {
		if e.Record.GetString("sourceUrl") != "" && !canSeeSource(e.App, e.Record, e.RequestInfo) {
			e.Record.Hide("sourceUrl")
		}
		return e.Next()
	})

	// Only someone who is an owner right now can delete the family.
	app.OnRecordDeleteRequest("families").BindFunc(func(e *core.RecordRequestEvent) error {
		if !e.HasSuperuserAuth() {
			me := membershipFor(e.App, e.Record.Id, authID(e.RequestEvent))
			if me == nil || me.GetString("role") != RoleOwner {
				return e.ForbiddenError("Only an owner can delete the family.", nil)
			}
		}
		return e.Next()
	})

	// Learned grocery terms change everyone's aisles: grocery editors only.
	learnedGuard := func(e *core.RecordRequestEvent) error {
		if !e.HasSuperuserAuth() && !canEditAnyGroceryList(e.App, e.Record.GetString("family"), authID(e.RequestEvent)) {
			return e.ForbiddenError("Only people who can edit a grocery list can teach it.", nil)
		}
		return e.Next()
	}
	app.OnRecordCreateRequest("groceryLearned").BindFunc(learnedGuard)
	app.OnRecordUpdateRequest("groceryLearned").BindFunc(learnedGuard)
	app.OnRecordDeleteRequest("groceryLearned").BindFunc(learnedGuard)

	// List JSON shapes.
	listShape := func(e *core.RecordRequestEvent) error {
		if err := validateJSONList(e.Record, "storeOrder", 100, isShortString); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		return e.Next()
	}
	app.OnRecordCreateRequest("lists").BindFunc(listShape)
	app.OnRecordUpdateRequest("lists").BindFunc(listShape)

	// Calendars: default reminders.
	calShape := func(e *core.RecordRequestEvent) error {
		if err := validateJSONList(e.Record, "defaultReminders", 10, isReminder); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		return e.Next()
	}
	app.OnRecordCreateRequest("calendars").BindFunc(calShape)
	app.OnRecordUpdateRequest("calendars").BindFunc(calShape)

	// Turn on PocketBase's built-in rate limits (sign-in guessing, floods).
	if cfg.RateLimit {
		app.OnBootstrap().BindFunc(func(e *core.BootstrapEvent) error {
			if err := e.Next(); err != nil {
				return err
			}
			s := e.App.Settings()
			if !s.RateLimits.Enabled {
				s.RateLimits.Enabled = true
				if err := e.App.Save(s); err != nil {
					e.App.Logger().Warn("could not enable rate limits", "error", err)
				}
			}
			return nil
		})
	}
}

func canSeeSource(app core.App, cal *core.Record, info *core.RequestInfo) bool {
	if info == nil {
		return true // internal use (cron sync, tests without a request)
	}
	if info.HasSuperuserAuth() {
		return true
	}
	if info.Auth == nil {
		return false
	}
	return canManage(app, cal, info.Auth.Id)
}

func canEditAnyGroceryList(app core.App, familyID, uid string) bool {
	if uid == "" {
		return false
	}
	lists, _ := app.FindAllRecords("lists", dbx.HashExp{"family": familyID, "kind": "grocery", "deleted": false})
	for _, l := range lists {
		if contains(l.GetStringSlice("editors"), uid) {
			return true
		}
	}
	return false
}

// ---- JSON field shapes ----------------------------------------------------

var occurrenceKeyRe = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?$`)

func isShortString(v any) bool { s, ok := v.(string); return ok && len(s) <= 100 }
func isOccurrenceKey(v any) bool {
	s, ok := v.(string)
	return ok && occurrenceKeyRe.MatchString(s)
}
func isReminder(v any) bool {
	f, ok := v.(float64)
	return ok && f == float64(int(f)) && f >= 0 && f <= 40320 // up to 4 weeks before
}

// validateJSONList requires field to be empty/null or a JSON array of at most
// max items that all pass ok. Malformed values would otherwise break feeds and
// every family member's calendar.
func validateJSONList(r *core.Record, field string, max int, ok func(any) bool) error {
	raw, err := json.Marshal(r.Get(field))
	if err != nil {
		return fmt.Errorf("%s: invalid", field)
	}
	if string(raw) == "null" || string(raw) == `""` {
		return nil
	}
	var items []any
	if err := json.Unmarshal(raw, &items); err != nil {
		return fmt.Errorf("%s must be a list", field)
	}
	if len(items) > max {
		return fmt.Errorf("%s has too many entries", field)
	}
	for _, it := range items {
		if !ok(it) {
			return fmt.Errorf("%s has an invalid entry", field)
		}
	}
	return nil
}

var dueRe = regexp.MustCompile(`^(\d{4}-\d{2}-\d{2}(T\d{2}:\d{2})?)?$`)

func validTimezone(tz string) bool {
	if tz == "" {
		return true
	}
	if _, err := time.LoadLocation(tz); err == nil {
		return true
	}
	_, ok := windowsZones[tz]
	return ok
}

// ---- refresh throttling -----------------------------------------------------

var lastManualRefresh sync.Map // calendar id → time.Time

// manualRefreshEvery is the minimum gap between on-demand refetches.
var manualRefreshEvery = 30 * time.Second

// allowManualRefresh lets each subscription be refetched on demand at most
// every 30 seconds.
func allowManualRefresh(calID string) bool {
	now := time.Now()
	if v, ok := lastManualRefresh.Load(calID); ok && now.Sub(v.(time.Time)) < manualRefreshEvery {
		return false
	}
	lastManualRefresh.Store(calID, now)
	return true
}
