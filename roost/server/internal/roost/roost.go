// Package roost adds the family-organizer schema, access rules, hooks and
// routes on top of PocketBase. See docs/DESIGN.md.
package roost

import (
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

const Version = "1.0.0"

type Config struct {
	// WebPath is the unlisted path the web app is served at, e.g. "/h/k7q2m9x4/".
	WebPath string
	// WebDir holds the built web app (web/dist). Empty disables serving it.
	WebDir string
	// OpenSignup lets anyone create an account (default: invite-only).
	OpenSignup          bool
	DefaultTimezone     string
	SubscriptionRefresh time.Duration
	AllowPrivateFeeds   bool
	// Optional OpenAI-compatible endpoint (e.g. Ollama) for unknown grocery items.
	LLMURL, LLMModel, LLMKey string
}

func ConfigFromEnv() Config {
	cfg := Config{
		WebPath:             os.Getenv("ROOST_WEB_PATH"),
		WebDir:              os.Getenv("ROOST_WEB_DIR"),
		OpenSignup:          envBool("ROOST_OPEN_SIGNUP"),
		DefaultTimezone:     os.Getenv("ROOST_TIMEZONE"),
		AllowPrivateFeeds:   envBool("ROOST_ALLOW_PRIVATE_FEEDS"),
		LLMURL:              strings.TrimRight(os.Getenv("ROOST_LLM_URL"), "/"),
		LLMModel:            os.Getenv("ROOST_LLM_MODEL"),
		LLMKey:              os.Getenv("ROOST_LLM_KEY"),
		SubscriptionRefresh: 30 * time.Minute,
	}
	if m, err := strconv.Atoi(os.Getenv("ROOST_SUBSCRIPTION_MINUTES")); err == nil && m >= 5 {
		cfg.SubscriptionRefresh = time.Duration(m) * time.Minute
	}
	return cfg.withDefaults()
}

func (c Config) withDefaults() Config {
	if c.DefaultTimezone == "" {
		c.DefaultTimezone = "America/Chicago"
	}
	if c.WebDir == "" {
		if st, err := os.Stat("web"); err == nil && st.IsDir() {
			c.WebDir = "web"
		}
	}
	if c.WebPath != "" {
		c.WebPath = "/" + strings.Trim(c.WebPath, "/") + "/"
	}
	if c.SubscriptionRefresh == 0 {
		c.SubscriptionRefresh = 30 * time.Minute
	}
	if c.LLMModel == "" {
		c.LLMModel = "llama3.1:8b"
	}
	return c
}

func envBool(k string) bool {
	v := strings.ToLower(os.Getenv(k))
	return v == "1" || v == "true" || v == "yes"
}

// Register wires Roost into a PocketBase app.
func Register(app core.App, cfg Config) {
	cfg = cfg.withDefaults()
	registerHooks(app, cfg)

	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		registerRoutes(se, cfg)
		return se.Next()
	})

	app.OnBootstrap().BindFunc(func(e *core.BootstrapEvent) error {
		if err := e.Next(); err != nil {
			return err
		}
		e.App.Cron().MustAdd("roostSubscriptions", "*/10 * * * *", func() { syncDueSubscriptions(e.App, cfg) })
		e.App.Cron().MustAdd("roostHousekeeping", "17 3 * * *", func() { housekeeping(e.App) })
		return nil
	})
}

// housekeeping purges tombstones older than 60 days and stale invites.
func housekeeping(app core.App) {
	cutoff := types.NowDateTime().AddDate(0, 0, -60).String()
	for _, coll := range []string{"events", "tasks", "groceryItems", "infoCards", "lists", "calendars"} {
		recs, err := app.FindRecordsByFilter(coll, "deleted = true && updated < {:c}", "", 500, 0, dbx.Params{"c": cutoff})
		if err != nil {
			continue
		}
		for _, r := range recs {
			_ = app.Delete(r)
		}
	}
	old := types.NowDateTime().AddDate(0, 0, -30).String()
	if invs, err := app.FindRecordsByFilter("invites", "expiresAt < {:c}", "", 500, 0, dbx.Params{"c": old}); err == nil {
		for _, r := range invs {
			_ = app.Delete(r)
		}
	}
}
