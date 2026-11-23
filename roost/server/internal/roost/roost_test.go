package roost

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"
)

// ---------------------------------------------------------------------------
// Harness: a real PocketBase app + Roost behind an httptest server.
// ---------------------------------------------------------------------------

type env struct {
	t   *testing.T
	app *tests.TestApp
	srv *httptest.Server
}

func newEnv(t *testing.T) *env { t.Helper(); return newEnvCfg(t, Config{}) }

func newEnvCfg(t *testing.T, cfg Config) *env {
	t.Helper()
	asyncInitialSync = false
	manualRefreshEvery = 0
	app, err := tests.NewTestAppWithConfig(core.BaseAppConfig{DataDir: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	webDir := t.TempDir()
	os.WriteFile(filepath.Join(webDir, "index.html"), []byte("<!doctype html><html><head><title>Roost</title></head><body></body></html>"), 0o644)
	os.MkdirAll(filepath.Join(webDir, "assets"), 0o755)
	os.WriteFile(filepath.Join(webDir, "assets", "app.js"), []byte("console.log(1)"), 0o644)
	cfg.WebPath, cfg.WebDir = "/h/test-path/", webDir
	Register(app, cfg)

	router, err := apis.NewRouter(app)
	if err != nil {
		t.Fatal(err)
	}
	se := &core.ServeEvent{App: app, Router: router}
	var srv *httptest.Server
	err = app.OnServe().Trigger(se, func(e *core.ServeEvent) error {
		mux, err := e.Router.BuildMux()
		if err != nil {
			return err
		}
		srv = httptest.NewServer(mux)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { srv.Close(); app.Cleanup() })
	return &env{t: t, app: app, srv: srv}
}

type resp struct {
	Status int
	Body   map[string]any
	Raw    string
}

func (r resp) str(k string) string { s, _ := r.Body[k].(string); return s }
func (r resp) items() []map[string]any {
	var out []map[string]any
	if arr, ok := r.Body["items"].([]any); ok {
		for _, x := range arr {
			out = append(out, x.(map[string]any))
		}
	}
	return out
}

func (e *env) do(method, path, token string, body any) resp {
	e.t.Helper()
	var rdr io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rdr = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, e.srv.URL+path, rdr)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", token)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	out := resp{Status: res.StatusCode, Raw: string(raw)}
	_ = json.Unmarshal(raw, &out.Body)
	return out
}

func (e *env) must(r resp, status int, what string) resp {
	e.t.Helper()
	if r.Status != status {
		e.t.Fatalf("%s: expected %d, got %d: %s", what, status, r.Status, r.Raw)
	}
	return r
}

func (e *env) signup(email, name, invite string) (int, string) {
	e.t.Helper()
	body := map[string]any{"email": email, "password": "correct-horse-1", "passwordConfirm": "correct-horse-1", "name": name}
	if invite != "" {
		body["inviteCode"] = invite
	}
	r := e.do("POST", "/api/collections/users/records", "", body)
	if r.Status != 200 {
		return r.Status, ""
	}
	a := e.must(e.do("POST", "/api/collections/users/auth-with-password", "", map[string]any{"identity": email, "password": "correct-horse-1"}), 200, "auth "+email)
	return 200, a.str("token")
}

func (e *env) list(coll, token, filter string) []map[string]any {
	e.t.Helper()
	q := "/api/collections/" + coll + "/records?perPage=500"
	if filter != "" {
		q += "&filter=" + urlQueryEscape(filter)
	}
	return e.must(e.do("GET", q, token, nil), 200, "list "+coll).items()
}

func urlQueryEscape(s string) string {
	r := strings.NewReplacer(" ", "%20", "\"", "%22", "'", "%27", "=", "%3D", "&", "%26", "|", "%7C", "!", "%21", "~", "%7E")
	return r.Replace(s)
}

func titles(items []map[string]any, key string) []string {
	var out []string
	for _, it := range items {
		out = append(out, fmt.Sprint(it[key]))
	}
	return out
}

func has(list []string, v string) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

func byField(items []map[string]any, key, val string) map[string]any {
	for _, it := range items {
		if fmt.Sprint(it[key]) == val {
			return it
		}
	}
	return nil
}

// ---------------------------------------------------------------------------

func TestAccessFixtures(t *testing.T) {
	raw, err := os.ReadFile("../../../shared/fixtures/access.json")
	if err != nil {
		t.Fatal(err)
	}
	var fx struct {
		Cases []struct {
			Resource, Subkind, Role, MembershipID, Expected string
			Sharing                                         Sharing
			IsOwner                                         bool
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	if len(fx.Cases) < 40 {
		t.Fatalf("too few cases: %d", len(fx.Cases))
	}
	for _, c := range fx.Cases {
		got := EffectiveLevel(c.Resource, c.Subkind, c.Role, c.MembershipID, c.Sharing, c.IsOwner)
		if got != c.Expected {
			t.Errorf("%s:%s role=%s sharing=%+v owner=%v: got %s want %s", c.Resource, c.Subkind, c.Role, c.Sharing, c.IsOwner, got, c.Expected)
		}
	}
}

func TestFamilyRolesEndToEnd(t *testing.T) {
	e := newEnv(t)

	// --- bootstrap: first sign-up is allowed, the next needs an invite.
	st, owner := e.signup("parent@example.com", "Alex", "")
	if st != 200 {
		t.Fatalf("owner signup: %d", st)
	}
	fam := e.must(e.do("POST", "/api/collections/families/records", owner, map[string]any{"name": "The Testers", "timezone": "America/Chicago"}), 200, "create family")
	famID := fam.str("id")
	if st, _ := e.signup("stranger@example.com", "Stranger", ""); st != 403 {
		t.Fatalf("sign-up without invite should be 403, got %d", st)
	}
	// Clients can't smuggle server-managed fields.
	if r := e.do("PATCH", "/api/collections/families/records/"+famID, owner, map[string]any{"admins": []string{}}); r.Status == 200 {
		t.Fatal("families.admins is server-managed")
	}

	// --- seeded defaults
	cals := e.list("calendars", owner, "")
	if len(cals) != 2 {
		t.Fatalf("expected 2 seeded calendars, got %v", titles(cals, "name"))
	}
	familyCal := byField(cals, "kind", "family")["id"].(string)
	personalCal := byField(cals, "kind", "personal")["id"].(string)
	lists := e.list("lists", owner, "")
	groceryList := byField(lists, "kind", "grocery")["id"].(string)
	todoList := byField(lists, "kind", "todo")["id"].(string)
	if n := len(e.list("infoCards", owner, "")); n != 2 {
		t.Fatalf("expected 2 seeded info cards, got %d", n)
	}
	members := e.list("memberships", owner, "")
	if len(members) != 1 || members[0]["role"] != "owner" {
		t.Fatalf("owner membership missing: %v", members)
	}
	ownerMember := members[0]["id"].(string)

	// --- a kid profile without a login
	kid := e.must(e.do("POST", "/api/collections/memberships/records", owner, map[string]any{"family": famID, "name": "Emma", "role": "kid"}), 200, "kid profile").str("id")
	e.must(e.do("POST", "/api/collections/memberships/records", owner, map[string]any{"family": famID, "name": "Sneaky", "role": "kid", "user": "abc"}), 400, "admins can't attach arbitrary users")

	// --- invite the nanny and grandma
	nannyInv := e.must(e.do("POST", "/api/collections/invites/records", owner, map[string]any{"family": famID, "role": "caregiver", "name": "Maria"}), 200, "invite nanny")
	code := nannyInv.str("code")
	if len(code) != 9 || code[4] != '-' {
		t.Fatalf("unexpected code %q", code)
	}
	preview := e.must(e.do("GET", "/api/roost/invites/"+strings.ToLower(strings.ReplaceAll(code, "-", "")), "", nil), 200, "invite preview")
	if preview.str("family") != "The Testers" || preview.str("role") != "caregiver" {
		t.Fatalf("bad preview: %s", preview.Raw)
	}
	_, nanny := e.signup("nanny@example.com", "Maria", code)
	if nanny == "" {
		t.Fatal("nanny signup with invite failed")
	}
	joined := e.must(e.do("POST", "/api/roost/join", nanny, map[string]any{"code": code}), 200, "nanny join")
	nannyMember := joined.str("membership")
	e.must(e.do("POST", "/api/roost/join", owner, map[string]any{"code": code}), 404, "invite is single-use")

	grandmaInv := e.must(e.do("POST", "/api/collections/invites/records", owner, map[string]any{"family": famID, "role": "relative", "name": "Grandma"}), 200, "invite grandma").str("code")
	_, grandma := e.signup("grandma@example.com", "Grandma", grandmaInv)
	e.must(e.do("POST", "/api/roost/join", grandma, map[string]any{"code": grandmaInv}), 200, "grandma join")

	// An outsider created out-of-band (e.g. a different family on the same server).
	usersColl, _ := e.app.FindCollectionByNameOrId("users")
	out := core.NewRecord(usersColl)
	out.SetEmail("outsider@example.com")
	out.SetPassword("correct-horse-1")
	out.Set("name", "Outsider")
	if err := e.app.Save(out); err != nil {
		t.Fatal(err)
	}
	outsider := e.must(e.do("POST", "/api/collections/users/auth-with-password", "", map[string]any{"identity": "outsider@example.com", "password": "correct-horse-1"}), 200, "outsider auth").str("token")

	// --- events
	start := time.Date(2026, 11, 24, 22, 0, 0, 0, time.UTC)
	mkEvent := func(token, cal, title string, private bool) resp {
		return e.do("POST", "/api/collections/events/records", token, map[string]any{
			"calendar": cal, "title": title, "start": start.Format(time.RFC3339), "end": start.Add(time.Hour).Format(time.RFC3339),
			"tz": "America/Chicago", "private": private, "members": []string{kid}, "reminders": []int{30},
		})
	}
	soccer := e.must(mkEvent(owner, familyCal, "Soccer", false), 200, "family event")
	if soccer.str("family") != famID || soccer.str("createdBy") == "" {
		t.Fatalf("server fields not set: %s", soccer.Raw)
	}
	e.must(mkEvent(owner, familyCal, "Surprise party planning", true), 200, "private family event")
	e.must(mkEvent(owner, personalCal, "Dermatology appt", false), 200, "personal event")
	e.must(e.do("POST", "/api/collections/events/records", owner, map[string]any{
		"calendar": familyCal, "title": "Bad", "start": start.Format(time.RFC3339), "end": start.Format(time.RFC3339), "members": []string{"nope"},
	}), 400, "foreign member ids rejected")

	ownerTitles := titles(e.list("events", owner, ""), "title")
	nannyTitles := titles(e.list("events", nanny, ""), "title")
	grandmaTitles := titles(e.list("events", grandma, ""), "title")
	if len(ownerTitles) != 3 {
		t.Fatalf("owner should see 3 events, got %v", ownerTitles)
	}
	if !has(nannyTitles, "Soccer") || has(nannyTitles, "Dermatology appt") {
		t.Fatalf("nanny events wrong: %v", nannyTitles)
	}
	if !has(nannyTitles, "Surprise party planning") {
		t.Fatalf("nanny edits the family calendar, so sees private family events: %v", nannyTitles)
	}
	if !has(grandmaTitles, "Soccer") || has(grandmaTitles, "Surprise party planning") || has(grandmaTitles, "Dermatology appt") {
		t.Fatalf("grandma events wrong: %v", grandmaTitles)
	}
	if n := len(e.list("events", outsider, "")); n != 0 {
		t.Fatalf("outsider sees %d events", n)
	}

	// Busy endpoint: nanny sees the personal appointment as Busy; grandma sees the private family event as Busy.
	nb := e.must(e.do("GET", "/api/roost/busy?family="+famID, nanny, nil), 200, "nanny busy")
	if len(nb.items()) != 1 || nb.items()[0]["title"] != "Busy" || strings.Contains(nb.Raw, "Dermatology") {
		t.Fatalf("nanny busy wrong: %s", nb.Raw)
	}
	gb := e.must(e.do("GET", "/api/roost/busy?family="+famID, grandma, nil), 200, "grandma busy")
	if len(gb.items()) != 1 || strings.Contains(gb.Raw, "Surprise") {
		t.Fatalf("grandma busy wrong: %s", gb.Raw)
	}
	e.must(e.do("GET", "/api/roost/busy?family="+famID, outsider, nil), 403, "outsider busy")

	// Write permissions.
	e.must(mkEvent(nanny, familyCal, "Playdate", false), 200, "nanny adds to family calendar")
	if r := mkEvent(nanny, personalCal, "Nope", false); r.Status == 200 {
		t.Fatal("nanny must not write to a parent's personal calendar")
	}
	if r := mkEvent(grandma, familyCal, "Nope", false); r.Status == 200 {
		t.Fatal("grandma must not write to the family calendar")
	}
	if r := e.do("PATCH", "/api/collections/events/records/"+soccer.str("id"), nanny, map[string]any{"calendar": personalCal}); r.Status == 200 {
		t.Fatal("nanny must not move an event into a calendar she can't edit")
	}

	// Sharing changes: only parents/owners.
	if r := e.do("PATCH", "/api/collections/calendars/records/"+familyCal, nanny, map[string]any{"sharing": map[string]any{"roles": map[string]string{"relative": "edit"}}}); r.Status == 200 {
		t.Fatal("nanny must not change sharing")
	}
	e.must(e.do("PATCH", "/api/collections/calendars/records/"+personalCal, owner, map[string]any{
		"sharing": map[string]any{"people": map[string]string{nannyMember: "view"}},
	}), 200, "owner shares personal calendar with nanny")
	if !has(titles(e.list("events", nanny, ""), "title"), "Dermatology appt") {
		t.Fatal("nanny should now see the personal calendar")
	}
	e.must(e.do("PATCH", "/api/collections/calendars/records/"+personalCal, owner, map[string]any{
		"sharing": map[string]any{"roles": map[string]string{"caregiver": "superuser"}},
	}), 400, "invalid sharing levels rejected")

	// --- lists and tasks
	nannyLists := titles(e.list("lists", nanny, ""), "name")
	if !has(nannyLists, "Groceries") || has(nannyLists, "Household") {
		t.Fatalf("nanny lists wrong: %v", nannyLists)
	}
	if n := len(e.list("lists", grandma, "")); n != 0 {
		t.Fatalf("grandma should see no lists, got %d", n)
	}
	e.must(e.do("POST", "/api/collections/groceryItems/records", nanny, map[string]any{"list": groceryList, "name": "Milk", "category": "dairy"}), 200, "nanny adds groceries")
	e.must(e.do("POST", "/api/collections/tasks/records", owner, map[string]any{"list": todoList, "title": "Renew passports"}), 200, "private task")
	assigned := e.must(e.do("POST", "/api/collections/tasks/records", owner, map[string]any{"list": todoList, "title": "Pick up Emma's prescription", "assignees": []string{nannyMember}}), 200, "assigned task")
	nannyTasks := titles(e.list("tasks", nanny, ""), "title")
	if len(nannyTasks) != 1 || nannyTasks[0] != "Pick up Emma's prescription" {
		t.Fatalf("nanny should see only her assigned task: %v", nannyTasks)
	}
	done := e.must(e.do("PATCH", "/api/collections/tasks/records/"+assigned.str("id"), nanny, map[string]any{"completed": true}), 200, "assignee completes task")
	if done.str("completedBy") == "" {
		t.Fatalf("completedBy not set: %s", done.Raw)
	}
	if r := e.do("PATCH", "/api/collections/tasks/records/"+assigned.str("id"), nanny, map[string]any{"list": groceryList}); r.Status == 200 {
		t.Fatal("assignee must not move a task to another list")
	}

	// --- info cards
	if n := len(e.list("infoCards", nanny, "")); n != 2 {
		t.Fatalf("nanny should read info cards, got %d", n)
	}
	if n := len(e.list("infoCards", grandma, "")); n != 2 {
		t.Fatalf("grandma should read info cards, got %d", n)
	}

	// --- people
	if n := len(e.list("users", nanny, "")); n != 3 {
		t.Fatalf("nanny should see the 3 family logins, got %d", n)
	}
	if n := len(e.list("users", outsider, "")); n != 1 {
		t.Fatalf("outsider should only see themself, got %d", n)
	}
	if n := len(e.list("memberships", outsider, "")); n != 0 {
		t.Fatalf("outsider sees memberships: %d", n)
	}

	// --- role guards
	_ = ownerMember
	parentInv := e.must(e.do("POST", "/api/collections/invites/records", owner, map[string]any{"family": famID, "role": "parent", "name": "Sam"}), 200, "invite parent").str("code")
	_, parent := e.signup("sam@example.com", "Sam", parentInv)
	e.must(e.do("POST", "/api/roost/join", parent, map[string]any{"code": parentInv}), 200, "parent join")
	if r := e.do("PATCH", "/api/collections/memberships/records/"+nannyMember, parent, map[string]any{"role": "owner"}); r.Status == 200 {
		t.Fatal("a parent must not grant owner")
	}
	e.must(e.do("PATCH", "/api/collections/memberships/records/"+nannyMember, parent, map[string]any{"role": "relative"}), 200, "parent changes nanny role")
	if n := len(e.list("lists", nanny, "")); n != 0 {
		t.Fatalf("after demotion to relative nanny should lose grocery access, sees %d", n)
	}
	if r := e.do("DELETE", "/api/collections/memberships/records/"+ownerMember, owner, nil); r.Status == 204 {
		t.Fatal("must not delete the last owner")
	}
	e.must(e.do("PATCH", "/api/collections/memberships/records/"+nannyMember, nanny, map[string]any{"emoji": "🌻"}), 200, "self-edit emoji")
	if r := e.do("PATCH", "/api/collections/memberships/records/"+nannyMember, nanny, map[string]any{"role": "owner"}); r.Status == 200 {
		t.Fatal("self-promotion must fail")
	}

	// --- ICS feed
	feed := e.must(e.do("POST", "/api/collections/feeds/records", owner, map[string]any{"family": famID, "user": decodeUserID(t, e, owner)}), 200, "owner feed")
	ics := e.do("GET", "/api/roost/ics/"+feed.str("token")+".ics", "", nil)
	if ics.Status != 200 || !strings.Contains(ics.Raw, "SUMMARY:Soccer") || !strings.Contains(ics.Raw, "BEGIN:VCALENDAR") {
		t.Fatalf("owner feed wrong (%d): %s", ics.Status, ics.Raw)
	}
	gfeed := e.must(e.do("POST", "/api/collections/feeds/records", grandma, map[string]any{"family": famID, "user": decodeUserID(t, e, grandma)}), 200, "grandma feed")
	gics := e.do("GET", "/api/roost/ics/"+gfeed.str("token"), "", nil)
	if strings.Contains(gics.Raw, "Surprise") || strings.Contains(gics.Raw, "Dermatology") || !strings.Contains(gics.Raw, "SUMMARY:Busy") {
		t.Fatalf("grandma feed leaks or lacks busy: %s", gics.Raw)
	}
	e.must(e.do("GET", "/api/roost/ics/AAAAAAAAAAAAAAAAAAAAAAAAAAAA", "", nil), 404, "unknown feed")
}

func decodeUserID(t *testing.T, e *env, token string) string {
	r := e.must(e.do("POST", "/api/collections/users/auth-refresh", token, nil), 200, "auth refresh")
	rec, _ := r.Body["record"].(map[string]any)
	return rec["id"].(string)
}

const sampleICS = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//School//EN\r\n" +
	"BEGIN:VTIMEZONE\r\nTZID:Central Standard Time\r\nEND:VTIMEZONE\r\n" +
	"BEGIN:VEVENT\r\nUID:practice-1\r\nSUMMARY:Robotics club\r\nDTSTART;TZID=America/Chicago:20261103T153000\r\nDTEND;TZID=America/Chicago:20261103T164500\r\n" +
	"RRULE:FREQ=WEEKLY;BYDAY=TU;X-FOO=1\r\nEXDATE;TZID=America/Chicago:20261124T153000\r\nDESCRIPTION:Bring laptop\\, charger\\nRoom 4\r\n" +
	"BEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:ignored\r\nEND:VALARM\r\nEND:VEVENT\r\n" +
	"BEGIN:VEVENT\r\nUID:practice-1\r\nRECURRENCE-ID;TZID=America/Chicago:20261110T153000\r\nSUMMARY:Robotics club (moved)\r\n" +
	"DTSTART;TZID=America/Chicago:20261111T153000\r\nDTEND;TZID=America/Chicago:20261111T164500\r\nEND:VEVENT\r\n" +
	"BEGIN:VEVENT\r\nUID:holiday-1\r\nSUMMARY:Thanksgiving break — no sc\r\n hool\r\nDTSTART;VALUE=DATE:20261125\r\nDTEND;VALUE=DATE:20261128\r\nEND:VEVENT\r\n" +
	"BEGIN:VEVENT\r\nUID:outlook-1\r\nSUMMARY:Staff meeting\r\nDTSTART;TZID=Central Standard Time:20261201T090000\r\nDURATION:PT45M\r\nEND:VEVENT\r\n" +
	"BEGIN:VEVENT\r\nUID:cancelled-1\r\nSUMMARY:Cancelled thing\r\nSTATUS:CANCELLED\r\nDTSTART:20261201T150000Z\r\nDTEND:20261201T160000Z\r\nEND:VEVENT\r\n" +
	"END:VCALENDAR\r\n"

func TestParseICS(t *testing.T) {
	evs, err := ParseICS(strings.NewReader(sampleICS), "America/Chicago")
	if err != nil {
		t.Fatal(err)
	}
	if len(evs) != 5 {
		t.Fatalf("expected 5 VEVENTs, got %d", len(evs))
	}
	m := evs[0]
	if m.Summary != "Robotics club" || m.RRule != "FREQ=WEEKLY;BYDAY=TU" || m.TZ != "America/Chicago" {
		t.Fatalf("master parsed wrong: %+v", m)
	}
	if m.Start.UTC().Format(time.RFC3339) != "2026-11-03T21:30:00Z" {
		t.Fatalf("tz conversion wrong: %s", m.Start.UTC())
	}
	if len(m.ExDates) != 1 || m.ExDates[0] != "2026-11-24T15:30" {
		t.Fatalf("exdates: %v", m.ExDates)
	}
	if m.Description != "Bring laptop, charger\nRoom 4" {
		t.Fatalf("unescape: %q", m.Description)
	}
	if evs[1].RecurrenceID != "2026-11-10T15:30" {
		t.Fatalf("recurrence id: %q", evs[1].RecurrenceID)
	}
	if !evs[2].AllDay || evs[2].Summary != "Thanksgiving break — no school" {
		t.Fatalf("all-day / unfolding: %+v", evs[2])
	}
	if evs[3].TZ != "America/Chicago" || evs[3].End.Sub(evs[3].Start) != 45*time.Minute {
		t.Fatalf("windows tz / duration: %+v", evs[3])
	}
	if !evs[4].Cancelled {
		t.Fatal("cancelled flag")
	}
}

func TestSubscriptionSync(t *testing.T) {
	e := newEnv(t)
	_, owner := e.signup("p@example.com", "Pat", "")
	famID := e.must(e.do("POST", "/api/collections/families/records", owner, map[string]any{"name": "Fam", "timezone": "America/Chicago"}), 200, "family").str("id")
	cal := e.must(e.do("POST", "/api/collections/calendars/records", owner, map[string]any{
		"family": famID, "name": "School", "kind": "subscription", "sourceUrl": "webcal://school.example.com/cal.ics",
	}), 200, "subscription calendar").str("id")

	feed := sampleICS
	fetchURLHook = func(ctx context.Context, u string) (io.ReadCloser, error) {
		if u != "https://school.example.com/cal.ics" {
			return nil, fmt.Errorf("unexpected url %s", u)
		}
		return io.NopCloser(strings.NewReader(feed)), nil
	}
	defer func() { fetchURLHook = nil }()

	r := e.must(e.do("POST", "/api/roost/calendars/"+cal+"/refresh", owner, nil), 200, "refresh")
	if r.Body["ok"] != true {
		t.Fatalf("refresh failed: %s", r.Raw)
	}
	evs := e.list("events", owner, "calendar = '"+cal+"' && deleted = false")
	if len(evs) != 4 {
		t.Fatalf("expected 4 imported events (cancelled skipped), got %v", titles(evs, "title"))
	}
	master := byField(evs, "externalUid", "practice-1")
	ex, _ := master["exdates"].([]any)
	if len(ex) != 2 {
		t.Fatalf("master should exclude the EXDATE and the moved instance: %v", ex)
	}
	// Imported events are read-only.
	if r := e.do("PATCH", "/api/collections/events/records/"+master["id"].(string), owner, map[string]any{"title": "x"}); r.Status == 200 {
		t.Fatal("imported events must be read-only")
	}
	updatedBefore := master["updated"]

	// Drop the holiday from the feed → soft-deleted; unchanged events keep `updated`.
	feed = strings.Replace(sampleICS, "BEGIN:VEVENT\r\nUID:holiday-1", "BEGIN:VX\r\nUID:holiday-1", 1)
	feed = strings.Replace(feed, "hool\r\nDTSTART;VALUE=DATE:20261125\r\nDTEND;VALUE=DATE:20261128\r\nEND:VEVENT", "hool\r\nEND:VX", 1)
	e.must(e.do("POST", "/api/roost/calendars/"+cal+"/refresh", owner, nil), 200, "refresh 2")
	evs = e.list("events", owner, "calendar = '"+cal+"' && deleted = false")
	if len(evs) != 3 {
		t.Fatalf("expected 3 after removal, got %v", titles(evs, "title"))
	}
	if byField(evs, "externalUid", "practice-1")["updated"] != updatedBefore {
		t.Fatal("unchanged imported event was re-saved")
	}
	// Private-address guard.
	if _, err := normalizeFeedURL("ftp://x"); err == nil {
		t.Fatal("ftp should be rejected")
	}
	if err := checkHostAllowed(context.Background(), "127.0.0.1", false); err == nil {
		t.Fatal("loopback should be refused")
	}
}

func TestWriteICS(t *testing.T) {
	start := time.Date(2026, 11, 24, 22, 0, 0, 0, time.UTC)
	out := WriteICS("Family", "America/Chicago", []ICSEvent{
		{UID: "a@roost", Summary: "Soccer; bring water, snacks", Start: start, End: start.Add(time.Hour), TZ: "America/Chicago", RRule: "FREQ=WEEKLY;BYDAY=TU", ExDates: []string{"2026-12-01T16:00"},
			Description: strings.Repeat("Long description ", 10)},
		{UID: "b@roost", Summary: "Trip", Start: time.Date(2026, 12, 23, 6, 0, 0, 0, time.UTC), End: time.Date(2026, 12, 27, 6, 0, 0, 0, time.UTC), AllDay: true, TZ: "America/Chicago"},
		{UID: "c@roost", Summary: "secret", Start: start, End: start.Add(time.Hour), Busy: true},
	}, start)
	for _, want := range []string{
		"DTSTART;TZID=America/Chicago:20261124T160000", "RRULE:FREQ=WEEKLY;BYDAY=TU", "EXDATE;TZID=America/Chicago:20261201T160000",
		`SUMMARY:Soccer\; bring water\, snacks`, "DTSTART;VALUE=DATE:20261223", "DTEND;VALUE=DATE:20261227", "SUMMARY:Busy",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in\n%s", want, out)
		}
	}
	if strings.Contains(out, "secret") {
		t.Error("busy event leaked its title")
	}
	for _, line := range strings.Split(out, "\r\n") {
		if len(line) > 75 {
			t.Errorf("line not folded (%d): %q", len(line), line)
		}
	}
	// Round-trip through our own parser.
	evs, err := ParseICS(strings.NewReader(out), "America/Chicago")
	if err != nil || len(evs) != 3 || evs[0].Summary != "Soccer; bring water, snacks" || !strings.HasPrefix(evs[0].Description, "Long description Long") {
		t.Fatalf("round trip failed: %v %+v", err, evs)
	}
}

func TestWebServing(t *testing.T) {
	e := newEnv(t)
	root := e.do("GET", "/", "", nil)
	if root.Status != 404 || root.Raw != "" {
		t.Fatalf("root must reveal nothing: %d %q", root.Status, root.Raw)
	}
	idx := e.do("GET", "/h/test-path/calendar/week", "", nil)
	if idx.Status != 200 || !strings.Contains(idx.Raw, `<base href="/h/test-path/">`) || !strings.Contains(idx.Raw, "ROOST_CONFIG") {
		t.Fatalf("index injection failed: %d %s", idx.Status, idx.Raw)
	}
	if js := e.do("GET", "/h/test-path/assets/app.js", "", nil); js.Status != 200 || js.Raw != "console.log(1)" {
		t.Fatalf("asset: %d %s", js.Status, js.Raw)
	}
	if miss := e.do("GET", "/h/test-path/assets/missing.js", "", nil); miss.Status != 404 {
		t.Fatalf("missing asset should 404, got %d", miss.Status)
	}
	if rb := e.do("GET", "/robots.txt", "", nil); !strings.Contains(rb.Raw, "Disallow: /") {
		t.Fatal("robots")
	}
	if cfg := e.do("GET", "/api/roost/config", "", nil); cfg.str("name") != "Roost" {
		t.Fatalf("config: %s", cfg.Raw)
	}
}

func TestParseCategoryJSON(t *testing.T) {
	got := parseCategoryJSON("Sure! ```json\n{\"Gochujang\": \"International\", \"widget\": \"nonsense\"}\n```", []string{"Gochujang", "widget"})
	if got["Gochujang"] != "international" || got["widget"] != "" {
		t.Fatalf("got %v", got)
	}
}
