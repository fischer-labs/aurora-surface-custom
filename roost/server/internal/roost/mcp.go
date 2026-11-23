package roost

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

// Model Context Protocol endpoint (Streamable HTTP, JSON responses) so a
// person's AI agents can read and update the family organizer with exactly
// that person's access. Authenticate with an agent key from Family → Settings:
//
//	POST /api/roost/mcp   Authorization: Bearer rk_…
//
// Every write goes through app.Save, so model hooks and realtime updates
// (phones refresh live) behave as for any other change.

var mcpProtocolVersions = []string{"2025-06-18", "2025-03-26", "2024-11-05"}

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type mcpCtx struct {
	app    core.App
	user   *core.Record
	family *core.Record
	me     *core.Record
	loc    *time.Location
}

func registerMCP(se *core.ServeEvent) {
	se.Router.POST("/api/roost/mcp", func(e *core.RequestEvent) error {
		ctx, status, msg := mcpAuth(e)
		if ctx == nil {
			e.Response.Header().Set("WWW-Authenticate", `Bearer realm="roost"`)
			return e.JSON(status, map[string]any{"error": msg})
		}
		raw, err := io.ReadAll(io.LimitReader(e.Request.Body, 1<<20))
		if err != nil {
			return e.BadRequestError("Unreadable body.", nil)
		}
		var req rpcRequest
		if err := json.Unmarshal(raw, &req); err != nil || req.Method == "" {
			return e.JSON(http.StatusOK, map[string]any{"jsonrpc": "2.0", "id": nil, "error": rpcError{-32700, "Parse error"}})
		}
		if len(req.ID) == 0 || string(req.ID) == "null" { // notification
			return e.NoContent(http.StatusAccepted)
		}
		result, rerr := ctx.dispatch(req)
		resp := map[string]any{"jsonrpc": "2.0", "id": req.ID}
		if rerr != nil {
			resp["error"] = rerr
		} else {
			resp["result"] = result
		}
		return e.JSON(http.StatusOK, resp)
	})
	se.Router.POST("/api/roost/agent-keys", createAgentKey)
	se.Router.GET("/api/roost/mcp", func(e *core.RequestEvent) error {
		return e.String(http.StatusMethodNotAllowed, "")
	})
}

func hashAgentToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// createAgentKey: POST /api/roost/agent-keys {family, name} → {id, name, token, path}.
// The token is shown once; only its hash is kept. Kids can't create keys.
func createAgentKey(e *core.RequestEvent) error {
	if e.Auth == nil || e.Auth.Collection().Name != "users" {
		return e.UnauthorizedError("Sign in first.", nil)
	}
	var body struct {
		Family string `json:"family"`
		Name   string `json:"name"`
	}
	if err := e.BindBody(&body); err != nil {
		return e.BadRequestError("Invalid body.", nil)
	}
	m := membershipFor(e.App, body.Family, e.Auth.Id)
	if m == nil {
		return e.ForbiddenError("You're not in that family.", nil)
	}
	if m.GetString("role") == "kid" {
		return e.ForbiddenError("Ask a parent to connect an assistant.", nil)
	}
	existing, _ := e.App.FindAllRecords("agentKeys", dbx.HashExp{"user": e.Auth.Id})
	if len(existing) >= 20 {
		return e.BadRequestError("You already have 20 assistant keys; revoke one first.", nil)
	}
	col, err := e.App.FindCollectionByNameOrId("agentKeys")
	if err != nil {
		return err
	}
	token := "rk_" + strings.ToLower(randomToken(30))
	rec := core.NewRecord(col)
	name := strings.TrimSpace(body.Name)
	if name == "" {
		name = "AI assistant"
	}
	if len(name) > 80 {
		name = name[:80]
	}
	rec.Set("family", body.Family)
	rec.Set("user", e.Auth.Id)
	rec.Set("name", name)
	rec.Set("tokenHash", hashAgentToken(token))
	rec.Set("hint", token[len(token)-4:])
	if err := e.App.Save(rec); err != nil {
		return err
	}
	return e.JSON(http.StatusOK, map[string]any{"id": rec.Id, "name": name, "token": token, "path": "/api/roost/mcp"})
}

func mcpAuth(e *core.RequestEvent) (*mcpCtx, int, string) {
	h := e.Request.Header.Get("Authorization")
	token := strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))
	if !strings.HasPrefix(token, "rk_") || len(token) < 30 {
		return nil, http.StatusUnauthorized, "Use an agent key from Roost → Family → Settings → AI assistants."
	}
	key, err := e.App.FindFirstRecordByData("agentKeys", "tokenHash", hashAgentToken(token))
	if err != nil {
		return nil, http.StatusUnauthorized, "Unknown or revoked agent key."
	}
	user, err := e.App.FindRecordById("users", key.GetString("user"))
	if err != nil {
		return nil, http.StatusUnauthorized, "The key's account no longer exists."
	}
	fam, err := e.App.FindRecordById("families", key.GetString("family"))
	me := (*core.Record)(nil)
	if err == nil {
		me = membershipFor(e.App, fam.Id, user.Id)
	}
	if me == nil {
		return nil, http.StatusForbidden, "The key's account is no longer in this family."
	}
	if last := key.GetDateTime("lastUsedAt"); last.IsZero() || time.Since(last.Time()) > time.Minute {
		key.Set("lastUsedAt", types.NowDateTime())
		_ = e.App.Save(key)
	}
	return &mcpCtx{app: e.App, user: user, family: fam, me: me, loc: loadLoc(fam.GetString("timezone"))}, 0, ""
}

func (c *mcpCtx) dispatch(req rpcRequest) (any, *rpcError) {
	switch req.Method {
	case "initialize":
		var p struct {
			ProtocolVersion string `json:"protocolVersion"`
		}
		_ = json.Unmarshal(req.Params, &p)
		version := mcpProtocolVersions[0]
		for _, v := range mcpProtocolVersions {
			if v == p.ProtocolVersion {
				version = v
			}
		}
		return map[string]any{
			"protocolVersion": version,
			"capabilities":    map[string]any{"tools": map[string]any{"listChanged": false}},
			"serverInfo":      map[string]any{"name": "roost", "title": "Roost family organizer", "version": Version},
			"instructions": "Tools for one family's shared calendar, to-dos and grocery list. Times are in the family's time zone (" +
				c.loc.String() + "). Call family_overview first to learn people, calendars and lists by name.",
		}, nil
	case "ping":
		return map[string]any{}, nil
	case "tools/list":
		return map[string]any{"tools": mcpTools}, nil
	case "tools/call":
		var p struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(req.Params, &p); err != nil {
			return nil, &rpcError{-32602, "Invalid params"}
		}
		out, err := c.call(p.Name, p.Arguments)
		if err != nil {
			return map[string]any{"isError": true, "content": []map[string]any{{"type": "text", "text": err.Error()}}}, nil
		}
		text, _ := json.MarshalIndent(out, "", "  ")
		return map[string]any{"content": []map[string]any{{"type": "text", "text": string(text)}}, "structuredContent": out}, nil
	}
	return nil, &rpcError{-32601, "Method not found: " + req.Method}
}

// ---- tool catalog ---------------------------------------------------------

func obj(props map[string]any, required ...string) map[string]any {
	s := map[string]any{"type": "object", "properties": props, "additionalProperties": false}
	if len(required) > 0 {
		s["required"] = required
	}
	return s
}

var str = func(desc string) map[string]any { return map[string]any{"type": "string", "description": desc} }
var strs = func(desc string) map[string]any {
	return map[string]any{"type": "array", "items": map[string]any{"type": "string"}, "description": desc}
}

var mcpTools = []map[string]any{
	{"name": "family_overview", "title": "Family overview", "description": "People (with roles), calendars and lists you can see, today's date and the family time zone.",
		"inputSchema": obj(map[string]any{}), "annotations": map[string]any{"readOnlyHint": true}},
	{"name": "list_events", "title": "List calendar events", "description": "Events (with recurring events expanded) from a start date for a number of days. Includes who's involved and who's driving.",
		"inputSchema": obj(map[string]any{
			"from":   str("First day, YYYY-MM-DD (default today)."),
			"days":   map[string]any{"type": "integer", "minimum": 1, "maximum": 62, "description": "Number of days (default 7)."},
			"person": str("Only events involving this person (name)."),
		}), "annotations": map[string]any{"readOnlyHint": true}},
	{"name": "add_event", "title": "Add an event", "description": "Adds an event to a family calendar you can edit.",
		"inputSchema": obj(map[string]any{
			"title":             str("Event title."),
			"start":             str("YYYY-MM-DD for all-day, or YYYY-MM-DDTHH:MM local time."),
			"end":               str("Optional end, same format (default: 1 hour, or 1 day for all-day)."),
			"calendar":          str("Calendar name (default: the shared family calendar)."),
			"repeat":            str("Optional RFC 5545 RRULE, e.g. FREQ=WEEKLY;BYDAY=TU,TH."),
			"people":            strs("Names of people involved."),
			"driver":            str("Name of whoever is driving."),
			"location":          str("Location."),
			"notes":             str("Notes."),
			"reminders_minutes": map[string]any{"type": "array", "items": map[string]any{"type": "integer"}, "description": "Minutes before start."},
		}, "title", "start")},
	{"name": "list_tasks", "title": "List to-dos", "description": "Open to-dos you can see (optionally one list, or only yours).",
		"inputSchema": obj(map[string]any{
			"list":           str("List name."),
			"assigned_to_me": map[string]any{"type": "boolean"},
		}), "annotations": map[string]any{"readOnlyHint": true}},
	{"name": "add_task", "title": "Add a to-do", "description": "Adds a to-do to a list you can edit.",
		"inputSchema": obj(map[string]any{
			"title":     str("What needs doing."),
			"due":       str("Optional YYYY-MM-DD or YYYY-MM-DDTHH:MM."),
			"list":      str("List name (default: first to-do list you can edit)."),
			"assignees": strs("Names of people to assign."),
			"priority":  map[string]any{"type": "integer", "minimum": 0, "maximum": 3},
			"notes":     str("Notes."),
			"repeat":    str("Optional RRULE for a repeating to-do."),
		}, "title")},
	{"name": "complete_task", "title": "Complete a to-do", "description": "Marks a to-do done (repeating to-dos roll forward).",
		"inputSchema": obj(map[string]any{"id": str("The to-do id from list_tasks.")}, "id")},
	{"name": "grocery_list", "title": "Grocery list", "description": "What's still needed, grouped by store aisle.",
		"inputSchema": obj(map[string]any{"list": str("Grocery list name (default: the first one).")}), "annotations": map[string]any{"readOnlyHint": true}},
	{"name": "add_groceries", "title": "Add groceries", "description": "Adds items (e.g. \"2 lb chicken breast\", \"milk\"). They're sorted into aisles and merged with items already on the list.",
		"inputSchema": obj(map[string]any{"items": strs("Items, one per entry."), "list": str("Grocery list name.")}, "items")},
	{"name": "check_off_groceries", "title": "Check off groceries", "description": "Marks items as bought.",
		"inputSchema": obj(map[string]any{"items": strs("Item names."), "list": str("Grocery list name.")}, "items")},
}

func (c *mcpCtx) call(name string, args json.RawMessage) (any, error) {
	if len(args) == 0 || string(args) == "null" {
		args = json.RawMessage("{}")
	}
	switch name {
	case "family_overview":
		return c.overview()
	case "list_events":
		var a struct {
			From   string `json:"from"`
			Days   int    `json:"days"`
			Person string `json:"person"`
		}
		if err := json.Unmarshal(args, &a); err != nil {
			return nil, err
		}
		return c.listEvents(a.From, a.Days, a.Person)
	case "add_event":
		var a addEventArgs
		if err := json.Unmarshal(args, &a); err != nil {
			return nil, err
		}
		return c.addEvent(a)
	case "list_tasks":
		var a struct {
			List         string `json:"list"`
			AssignedToMe bool   `json:"assigned_to_me"`
		}
		if err := json.Unmarshal(args, &a); err != nil {
			return nil, err
		}
		return c.listTasks(a.List, a.AssignedToMe)
	case "add_task":
		var a addTaskArgs
		if err := json.Unmarshal(args, &a); err != nil {
			return nil, err
		}
		return c.addTask(a)
	case "complete_task":
		var a struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(args, &a); err != nil {
			return nil, err
		}
		return c.completeTask(a.ID)
	case "grocery_list", "add_groceries", "check_off_groceries":
		var a struct {
			Items []string `json:"items"`
			List  string   `json:"list"`
		}
		if err := json.Unmarshal(args, &a); err != nil {
			return nil, err
		}
		switch name {
		case "grocery_list":
			return c.groceryList(a.List)
		case "add_groceries":
			return c.addGroceries(a.List, a.Items)
		default:
			return c.checkOff(a.List, a.Items)
		}
	}
	return nil, fmt.Errorf("unknown tool %q", name)
}

// ---- helpers --------------------------------------------------------------

func (c *mcpCtx) records(coll string) []*core.Record {
	recs, _ := c.app.FindAllRecords(coll, dbx.HashExp{"family": c.family.Id})
	return recs
}

func (c *mcpCtx) members() []*core.Record { return c.records("memberships") }

func (c *mcpCtx) memberName(id string) string {
	if id == "" {
		return ""
	}
	if m, err := c.app.FindRecordById("memberships", id); err == nil {
		return m.GetString("name")
	}
	return ""
}

func (c *mcpCtx) resolvePeople(names []string) ([]string, error) {
	var ids []string
	ms := c.members()
	for _, n := range names {
		n = strings.ToLower(strings.TrimSpace(n))
		if n == "" {
			continue
		}
		if (n == "me" || n == "myself") && c.me != nil {
			ids = append(ids, c.me.Id)
			continue
		}
		var hit *core.Record
		for _, m := range ms {
			if strings.ToLower(m.GetString("name")) == n {
				hit = m
			}
		}
		if hit == nil {
			for _, m := range ms {
				if strings.HasPrefix(strings.ToLower(m.GetString("name")), n) {
					hit = m
					break
				}
			}
		}
		if hit == nil {
			return nil, fmt.Errorf("no one named %q in the family", n)
		}
		ids = append(ids, hit.Id)
	}
	return ids, nil
}

func (c *mcpCtx) can(r *core.Record, field string) bool { return contains(r.GetStringSlice(field), c.user.Id) }

func (c *mcpCtx) findByName(coll, name string, pick func(*core.Record) bool) (*core.Record, error) {
	var candidates []*core.Record
	for _, r := range c.records(coll) {
		if !r.GetBool("deleted") && pick(r) {
			candidates = append(candidates, r)
		}
	}
	sort.SliceStable(candidates, func(i, j int) bool {
		return candidates[i].GetDateTime("created").Before(candidates[j].GetDateTime("created"))
	})
	if name == "" {
		if len(candidates) == 0 {
			return nil, fmt.Errorf("nothing suitable you can edit")
		}
		return candidates[0], nil
	}
	for _, r := range candidates {
		if strings.EqualFold(r.GetString("name"), strings.TrimSpace(name)) {
			return r, nil
		}
	}
	return nil, fmt.Errorf("no %s named %q that you can use", strings.TrimSuffix(coll, "s"), name)
}

// parseWhen accepts YYYY-MM-DD, YYYY-MM-DDTHH:MM(:SS) (family time) or RFC 3339.
func (c *mcpCtx) parseWhen(s string) (time.Time, bool, error) {
	s = strings.TrimSpace(s)
	if t, err := time.ParseInLocation("2006-01-02", s, c.loc); err == nil {
		return t, true, nil
	}
	for _, layout := range []string{"2006-01-02T15:04", "2006-01-02T15:04:05", "2006-01-02 15:04"} {
		if t, err := time.ParseInLocation(layout, s, c.loc); err == nil {
			return t, false, nil
		}
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t, false, nil
	}
	return time.Time{}, false, fmt.Errorf("can't read the date/time %q (use YYYY-MM-DD or YYYY-MM-DDTHH:MM)", s)
}

func (c *mcpCtx) newRecord(coll string) (*core.Record, error) {
	col, err := c.app.FindCollectionByNameOrId(coll)
	if err != nil {
		return nil, err
	}
	return core.NewRecord(col), nil
}

// ---- tools ----------------------------------------------------------------

func (c *mcpCtx) overview() (any, error) {
	var people []map[string]any
	for _, m := range c.members() {
		people = append(people, map[string]any{"name": m.GetString("name"), "role": m.GetString("role"), "hasLogin": m.GetString("user") != ""})
	}
	var cals, lists []map[string]any
	for _, r := range c.records("calendars") {
		if !r.GetBool("deleted") && (c.can(r, "viewers") || c.can(r, "busyViewers")) {
			cals = append(cals, map[string]any{"name": r.GetString("name"), "kind": r.GetString("kind"),
				"canEdit": c.can(r, "editors") && r.GetString("kind") != "subscription", "busyOnly": !c.can(r, "viewers")})
		}
	}
	for _, r := range c.records("lists") {
		if !r.GetBool("deleted") && c.can(r, "viewers") {
			lists = append(lists, map[string]any{"name": r.GetString("name"), "kind": r.GetString("kind"), "canEdit": c.can(r, "editors")})
		}
	}
	you := map[string]any{"name": c.user.GetString("name")}
	if c.me != nil {
		you["name"], you["role"] = c.me.GetString("name"), c.me.GetString("role")
	}
	return map[string]any{
		"family": c.family.GetString("name"), "timezone": c.loc.String(), "today": time.Now().In(c.loc).Format("Monday 2006-01-02"),
		"you": you, "people": people, "calendars": cals, "lists": lists,
	}, nil
}

func (c *mcpCtx) listEvents(from string, days int, person string) (any, error) {
	start := time.Now().In(c.loc)
	start = time.Date(start.Year(), start.Month(), start.Day(), 0, 0, 0, 0, c.loc)
	if from != "" {
		t, _, err := c.parseWhen(from)
		if err != nil {
			return nil, err
		}
		start = t
	}
	if days <= 0 {
		days = 7
	}
	if days > 62 {
		days = 62
	}
	end := start.AddDate(0, 0, days)
	var personID string
	if person != "" {
		ids, err := c.resolvePeople([]string{person})
		if err != nil {
			return nil, err
		}
		personID = ids[0]
	}
	type occ struct {
		at  time.Time
		out map[string]any
	}
	var all []occ
	for _, cal := range c.records("calendars") {
		viewer, busy := c.can(cal, "viewers"), c.can(cal, "busyViewers")
		if cal.GetBool("deleted") || (!viewer && !busy) {
			continue
		}
		editor := c.can(cal, "editors")
		evs, err := c.app.FindRecordsByFilter("events", "calendar = {:c} && deleted = false && (rrule != '' || (start < {:to} && end > {:from}))", "start", 5000, 0,
			dbx.Params{"c": cal.Id, "from": start.UTC().Format(types.DefaultDateLayout), "to": end.UTC().Format(types.DefaultDateLayout)})
		if err != nil {
			return nil, err
		}
		for _, ev := range evs {
			members := ev.GetStringSlice("members")
			if personID != "" && !contains(members, personID) && ev.GetString("driver") != personID {
				continue
			}
			masked := !viewer || (ev.GetBool("private") && !editor && ev.GetString("createdBy") != c.user.Id)
			loc := loadLoc(ev.GetString("tz"))
			s, e := ev.GetDateTime("start").Time(), ev.GetDateTime("end").Time()
			allDay := ev.GetBool("allDay")
			dur := int(e.Sub(s).Minutes())
			if allDay {
				dur = (toLocalDT(e, loc).date.dayNumber() - toLocalDT(s, loc).date.dayNumber()) * 1440
			}
			var ex []string
			_ = ev.UnmarshalJSONField("exdates", &ex)
			exset := map[string]bool{}
			for _, x := range ex {
				exset[x] = true
			}
			for _, o := range expandOccurrences(toLocalDT(s, loc), dur, allDay, loc, ev.GetString("rrule"), exset, start, end) {
				os := o.in(loc)
				oe := os.Add(time.Duration(dur) * time.Minute)
				if allDay {
					oe = time.Date(o.date.y, time.Month(o.date.m), o.date.d+maxInt(dur/1440, 1), 0, 0, 0, 0, loc)
				}
				var names []string
				for _, m := range members {
					names = append(names, c.memberName(m))
				}
				item := map[string]any{"calendar": cal.GetString("name"), "allDay": allDay, "people": names,
					"start": os.In(c.loc).Format(time.RFC3339), "end": oe.In(c.loc).Format(time.RFC3339)}
				if masked {
					item["title"] = "Busy"
				} else {
					item["id"], item["title"] = ev.Id, ev.GetString("title")
					if d := c.memberName(ev.GetString("driver")); d != "" {
						item["driver"] = d
					}
					if l := ev.GetString("location"); l != "" {
						item["location"] = l
					}
					if ev.GetString("rrule") != "" {
						item["repeats"] = ev.GetString("rrule")
					}
				}
				all = append(all, occ{os, item})
			}
		}
	}
	sort.SliceStable(all, func(i, j int) bool { return all[i].at.Before(all[j].at) })
	events := make([]map[string]any, 0, len(all))
	for _, o := range all {
		events = append(events, o.out)
	}
	return map[string]any{"from": start.Format("2006-01-02"), "days": days, "events": events}, nil
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

type addEventArgs struct {
	Title            string   `json:"title"`
	Start            string   `json:"start"`
	End              string   `json:"end"`
	Calendar         string   `json:"calendar"`
	Repeat           string   `json:"repeat"`
	People           []string `json:"people"`
	Driver           string   `json:"driver"`
	Location         string   `json:"location"`
	Notes            string   `json:"notes"`
	RemindersMinutes []int    `json:"reminders_minutes"`
}

func (c *mcpCtx) addEvent(a addEventArgs) (any, error) {
	if strings.TrimSpace(a.Title) == "" {
		return nil, fmt.Errorf("title is required")
	}
	start, allDay, err := c.parseWhen(a.Start)
	if err != nil {
		return nil, err
	}
	end := start.Add(time.Hour)
	if allDay {
		end = start.AddDate(0, 0, 1)
	}
	if a.End != "" {
		e, endAllDay, err := c.parseWhen(a.End)
		if err != nil {
			return nil, err
		}
		if endAllDay && allDay {
			e = e.AddDate(0, 0, 1) // inclusive last day → exclusive end
		}
		if e.Before(start) {
			return nil, fmt.Errorf("end is before start")
		}
		end = e
	}
	cal, err := c.findByName("calendars", a.Calendar, func(r *core.Record) bool {
		return c.can(r, "editors") && r.GetString("kind") != "subscription" && (a.Calendar != "" || r.GetString("kind") == "family")
	})
	if err != nil {
		return nil, err
	}
	if a.Repeat != "" && parseRRule(a.Repeat) == nil {
		return nil, fmt.Errorf("repeat must be an RRULE with FREQ, e.g. FREQ=WEEKLY;BYDAY=MO")
	}
	people, err := c.resolvePeople(a.People)
	if err != nil {
		return nil, err
	}
	driver := ""
	if a.Driver != "" {
		ids, err := c.resolvePeople([]string{a.Driver})
		if err != nil {
			return nil, err
		}
		driver = ids[0]
	}
	reminders := a.RemindersMinutes
	if reminders == nil {
		var def []int
		_ = cal.UnmarshalJSONField("defaultReminders", &def)
		reminders = def
	}
	ev, err := c.newRecord("events")
	if err != nil {
		return nil, err
	}
	for k, v := range map[string]any{
		"calendar": cal.Id, "title": strings.TrimSpace(a.Title), "start": start.UTC(), "end": end.UTC(), "allDay": allDay, "tz": c.loc.String(),
		"rrule": strings.TrimPrefix(a.Repeat, "RRULE:"), "members": people, "driver": driver, "location": a.Location, "notes": a.Notes,
		"reminders": reminders, "source": "roost", "createdBy": c.user.Id, "updatedBy": c.user.Id,
	} {
		ev.Set(k, v)
	}
	if err := validateEvent(c.app, ev); err != nil {
		return nil, err
	}
	if err := c.app.Save(ev); err != nil {
		return nil, err
	}
	return map[string]any{"added": ev.GetString("title"), "id": ev.Id, "calendar": cal.GetString("name"),
		"start": start.In(c.loc).Format(time.RFC3339), "end": end.In(c.loc).Format(time.RFC3339), "allDay": allDay}, nil
}

func (c *mcpCtx) taskOut(t *core.Record, listName string) map[string]any {
	var names []string
	for _, a := range t.GetStringSlice("assignees") {
		names = append(names, c.memberName(a))
	}
	out := map[string]any{"id": t.Id, "title": t.GetString("title"), "list": listName, "assignees": names, "priority": t.GetInt("priority")}
	if d := t.GetString("due"); d != "" {
		out["due"] = d
	}
	if r := t.GetString("rrule"); r != "" {
		out["repeats"] = r
	}
	return out
}

func (c *mcpCtx) listTasks(list string, mine bool) (any, error) {
	lists := map[string]*core.Record{}
	for _, l := range c.records("lists") {
		if !l.GetBool("deleted") && l.GetString("kind") != "grocery" {
			lists[l.Id] = l
		}
	}
	var out []map[string]any
	for _, t := range c.records("tasks") {
		if t.GetBool("deleted") || t.GetBool("completed") || t.GetString("parent") != "" {
			continue
		}
		l := lists[t.GetString("list")]
		if l == nil {
			continue
		}
		assigned := c.me != nil && contains(t.GetStringSlice("assignees"), c.me.Id)
		if !c.can(l, "viewers") && !assigned {
			continue
		}
		if mine && !assigned {
			continue
		}
		if list != "" && !strings.EqualFold(l.GetString("name"), list) {
			continue
		}
		out = append(out, c.taskOut(t, l.GetString("name")))
	}
	sort.SliceStable(out, func(i, j int) bool {
		di, _ := out[i]["due"].(string)
		dj, _ := out[j]["due"].(string)
		if (di == "") != (dj == "") {
			return di != ""
		}
		return di < dj
	})
	return map[string]any{"tasks": out}, nil
}

type addTaskArgs struct {
	Title     string   `json:"title"`
	Due       string   `json:"due"`
	List      string   `json:"list"`
	Assignees []string `json:"assignees"`
	Priority  int      `json:"priority"`
	Notes     string   `json:"notes"`
	Repeat    string   `json:"repeat"`
}

func (c *mcpCtx) addTask(a addTaskArgs) (any, error) {
	if strings.TrimSpace(a.Title) == "" {
		return nil, fmt.Errorf("title is required")
	}
	l, err := c.findByName("lists", a.List, func(r *core.Record) bool { return c.can(r, "editors") && r.GetString("kind") != "grocery" })
	if err != nil {
		return nil, err
	}
	due := ""
	if a.Due != "" {
		t, allDay, err := c.parseWhen(a.Due)
		if err != nil {
			return nil, err
		}
		if allDay {
			due = t.Format("2006-01-02")
		} else {
			due = t.In(c.loc).Format("2006-01-02T15:04")
		}
	}
	if a.Repeat != "" && (due == "" || parseRRule(a.Repeat) == nil) {
		return nil, fmt.Errorf("a repeating to-do needs a due date and an RRULE with FREQ")
	}
	people, err := c.resolvePeople(a.Assignees)
	if err != nil {
		return nil, err
	}
	if a.Priority < 0 || a.Priority > 3 {
		a.Priority = 0
	}
	t, err := c.newRecord("tasks")
	if err != nil {
		return nil, err
	}
	reminders := []int{}
	if len(due) > 10 {
		reminders = []int{0}
	}
	for k, v := range map[string]any{
		"list": l.Id, "title": strings.TrimSpace(a.Title), "notes": a.Notes, "due": due, "assignees": people, "priority": a.Priority,
		"rrule": strings.TrimPrefix(a.Repeat, "RRULE:"), "reminders": reminders, "createdBy": c.user.Id, "sortOrder": float64(time.Now().Unix()),
	} {
		t.Set(k, v)
	}
	if err := validateTask(c.app, t); err != nil {
		return nil, err
	}
	if err := c.app.Save(t); err != nil {
		return nil, err
	}
	return map[string]any{"added": c.taskOut(t, l.GetString("name"))}, nil
}

func (c *mcpCtx) completeTask(id string) (any, error) {
	t, err := c.app.FindRecordById("tasks", id)
	if err != nil || t.GetString("family") != c.family.Id || t.GetBool("deleted") {
		return nil, fmt.Errorf("no to-do with id %q", id)
	}
	l, err := c.app.FindRecordById("lists", t.GetString("list"))
	if err != nil {
		return nil, err
	}
	assigned := c.me != nil && contains(t.GetStringSlice("assignees"), c.me.Id)
	if !c.can(l, "editors") && !assigned {
		return nil, fmt.Errorf("you can't change that to-do")
	}
	now := time.Now().In(c.loc)
	if rr, due := t.GetString("rrule"), t.GetString("due"); rr != "" && due != "" {
		done, err := c.newRecord("tasks")
		if err != nil {
			return nil, err
		}
		for _, f := range []string{"list", "title", "notes", "due", "assignees", "priority", "tags", "createdBy", "sortOrder"} {
			done.Set(f, t.Get(f))
		}
		done.Set("reminders", []int{})
		done.Set("completed", true)
		done.Set("completedAt", types.NowDateTime())
		done.Set("completedBy", c.user.Id)
		if err := c.app.Save(done); err != nil {
			return nil, err
		}
		next := nextTaskDue(due, rr, localDate{now.Year(), int(now.Month()), now.Day()})
		if next == "" {
			t.Set("completed", true)
			t.Set("completedAt", types.NowDateTime())
			t.Set("completedBy", c.user.Id)
		} else {
			t.Set("due", next)
		}
		if err := c.app.Save(t); err != nil {
			return nil, err
		}
		return map[string]any{"completed": t.GetString("title"), "nextDue": next}, nil
	}
	t.Set("completed", true)
	t.Set("completedAt", types.NowDateTime())
	t.Set("completedBy", c.user.Id)
	if err := c.app.Save(t); err != nil {
		return nil, err
	}
	return map[string]any{"completed": t.GetString("title")}, nil
}

// nextTaskDue implements shared/README.md §8.
func nextTaskDue(due, rule string, completedOn localDate) string {
	r := parseRRule(rule)
	if r == nil {
		return ""
	}
	start := localDT{}
	allDay := len(due) <= 10
	if allDay {
		t, err := time.Parse("2006-01-02", due)
		if err != nil {
			return ""
		}
		start = localDT{localDate{t.Year(), int(t.Month()), t.Day()}, 0, 0}
	} else {
		t, err := time.Parse("2006-01-02T15:04", due)
		if err != nil {
			return ""
		}
		start = localDT{localDate{t.Year(), int(t.Month()), t.Day()}, t.Hour(), t.Minute()}
	}
	found := ""
	r.iterate(start, 0, time.UTC, func(c localDT) bool {
		if start.less(c) && completedOn.less(c.date) {
			found = c.key(allDay)
			return false
		}
		return true
	})
	return found
}

// ---- groceries ------------------------------------------------------------

type groceryCat struct {
	Key   string `json:"key"`
	Name  string `json:"name"`
	Emoji string `json:"emoji"`
	Order int    `json:"order"`
}

var groceryCats = func() []groceryCat {
	var raw struct {
		Categories []groceryCat `json:"categories"`
	}
	_ = json.Unmarshal(taxonomyJSON, &raw)
	sort.Slice(raw.Categories, func(i, j int) bool { return raw.Categories[i].Order < raw.Categories[j].Order })
	return raw.Categories
}()

func mergeKey(name string) string {
	toks := strings.Fields(normalizeText(name))
	for i, t := range toks {
		if v := singularVariants(t); len(v) > 0 {
			toks[i] = v[0]
		}
	}
	return strings.Join(toks, " ")
}

var unitWords = map[string]string{"lb": "lb", "lbs": "lb", "pound": "lb", "pounds": "lb", "oz": "oz", "ounce": "oz", "ounces": "oz",
	"g": "g", "kg": "kg", "gal": "gal", "gallon": "gal", "gallons": "gal", "dozen": "dozen", "pack": "pack", "packs": "pack",
	"box": "box", "boxes": "box", "bag": "bag", "bags": "bag", "can": "can", "cans": "can", "jar": "jar", "jars": "jar",
	"bottle": "bottle", "bottles": "bottle", "bunch": "bunch", "loaf": "loaf", "loaves": "loaf", "carton": "carton", "cartons": "carton"}

// parseItem understands the common forms agents send: "2 lb chicken", "milk x2", "3 avocados".
func parseItem(s string) (name string, qty float64, unit string) {
	f := strings.Fields(strings.TrimSpace(s))
	if len(f) >= 2 {
		last := strings.ToLower(f[len(f)-1])
		if strings.HasPrefix(last, "x") {
			if n, err := strconv.ParseFloat(last[1:], 64); err == nil {
				qty, f = n, f[:len(f)-1]
			}
		}
	}
	if qty == 0 && len(f) >= 2 {
		if n, err := strconv.ParseFloat(f[0], 64); err == nil && n > 0 {
			qty, f = n, f[1:]
			if len(f) >= 2 {
				if u, ok := unitWords[strings.ToLower(f[0])]; ok {
					unit, f = u, f[1:]
					if len(f) >= 2 && strings.EqualFold(f[0], "of") {
						f = f[1:]
					}
				}
			}
		}
	}
	name = strings.Join(f, " ")
	if name != "" {
		name = strings.ToUpper(name[:1]) + name[1:]
	}
	return
}

func (c *mcpCtx) groceryListRecord(name string, edit bool) (*core.Record, error) {
	field := "viewers"
	if edit {
		field = "editors"
	}
	return c.findByName("lists", name, func(r *core.Record) bool { return r.GetString("kind") == "grocery" && c.can(r, field) })
}

func (c *mcpCtx) openItems(list *core.Record) []*core.Record {
	items, _ := c.app.FindAllRecords("groceryItems", dbx.HashExp{"list": list.Id, "deleted": false})
	return items
}

func (c *mcpCtx) groceryList(name string) (any, error) {
	l, err := c.groceryListRecord(name, false)
	if err != nil {
		return nil, err
	}
	var order []string
	_ = l.UnmarshalJSONField("storeOrder", &order)
	pos := map[string]int{}
	for i, k := range order {
		pos[k] = i
	}
	cats := append([]groceryCat{}, groceryCats...)
	sort.SliceStable(cats, func(i, j int) bool {
		pi, oki := pos[cats[i].Key]
		pj, okj := pos[cats[j].Key]
		if !oki {
			pi = 1000 + cats[i].Order
		}
		if !okj {
			pj = 1000 + cats[j].Order
		}
		return pi < pj
	})
	byCat := map[string][]string{}
	n := 0
	for _, it := range c.openItems(l) {
		if it.GetBool("checked") {
			continue
		}
		label := it.GetString("name")
		if q := it.GetFloat("quantity"); q > 0 {
			label += " (" + strconv.FormatFloat(q, 'f', -1, 64)
			if u := it.GetString("unit"); u != "" {
				label += " " + u
			}
			label += ")"
		}
		byCat[it.GetString("category")] = append(byCat[it.GetString("category")], label)
		n++
	}
	var aisles []map[string]any
	for _, cat := range cats {
		if items := byCat[cat.Key]; len(items) > 0 {
			aisles = append(aisles, map[string]any{"aisle": cat.Name, "items": items})
		}
	}
	return map[string]any{"list": l.GetString("name"), "count": n, "aisles": aisles}, nil
}

func (c *mcpCtx) addGroceries(name string, items []string) (any, error) {
	l, err := c.groceryListRecord(name, true)
	if err != nil {
		return nil, err
	}
	learned := learnedTerms(c.app, c.family.Id)
	existing := c.openItems(l)
	var added, merged []string
	for _, raw := range items {
		itemName, qty, unit := parseItem(raw)
		if itemName == "" {
			continue
		}
		key := mergeKey(itemName)
		var match *core.Record
		for _, it := range existing {
			if mergeKey(it.GetString("name")) == key && it.GetString("unit") == unit {
				match = it
				break
			}
		}
		if match != nil {
			if match.GetBool("checked") {
				match.Set("checked", false)
				match.Set("quantity", qty)
			} else {
				q, add := match.GetFloat("quantity"), qty
				if q == 0 {
					q = 1
				}
				if add == 0 {
					add = 1
				}
				match.Set("quantity", q+add)
			}
			if err := c.app.Save(match); err != nil {
				return nil, err
			}
			merged = append(merged, match.GetString("name"))
			continue
		}
		cat, src := categorizeGrocery(itemName, learned)
		it, err := c.newRecord("groceryItems")
		if err != nil {
			return nil, err
		}
		for k, v := range map[string]any{"list": l.Id, "name": itemName, "quantity": qty, "unit": unit, "category": cat,
			"categorySource": src, "addedBy": c.user.Id, "sortOrder": float64(time.Now().UnixNano()) / 1e9} {
			it.Set(k, v)
		}
		if err := c.app.Save(it); err != nil {
			return nil, err
		}
		existing = append(existing, it)
		added = append(added, fmt.Sprintf("%s → %s", itemName, categoryName(cat)))
	}
	return map[string]any{"list": l.GetString("name"), "added": added, "mergedWithExisting": merged}, nil
}

func categoryName(key string) string {
	for _, c := range groceryCats {
		if c.Key == key {
			return c.Name
		}
	}
	return "Other"
}

func (c *mcpCtx) checkOff(name string, items []string) (any, error) {
	l, err := c.groceryListRecord(name, true)
	if err != nil {
		return nil, err
	}
	open := c.openItems(l)
	var done, missing []string
	for _, raw := range items {
		n, _, _ := parseItem(raw)
		key := mergeKey(n)
		found := false
		for _, it := range open {
			if !it.GetBool("checked") && mergeKey(it.GetString("name")) == key {
				it.Set("checked", true)
				it.Set("checkedAt", types.NowDateTime())
				it.Set("checkedBy", c.user.Id)
				if err := c.app.Save(it); err != nil {
					return nil, err
				}
				done = append(done, it.GetString("name"))
				found = true
				break
			}
		}
		if !found {
			missing = append(missing, raw)
		}
	}
	return map[string]any{"checkedOff": done, "notOnList": missing}, nil
}
