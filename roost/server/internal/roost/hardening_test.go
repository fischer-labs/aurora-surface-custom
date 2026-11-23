package roost

import (
	"context"
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

// family sets up an owner, a nanny (caregiver), grandma (relative) and a kid
// login, returning their tokens plus the seeded calendars and lists.
type famFixture struct {
	fam, owner, nanny, grandma, kid               string
	familyCal, personalCal, groceryList, todoList string
	nannyMember, kidMember                        string
}

func setupFamily(t *testing.T, e *env) famFixture {
	t.Helper()
	var f famFixture
	_, f.owner = e.signup("parent@example.com", "Alex", "")
	f.fam = e.must(e.do("POST", "/api/collections/families/records", f.owner, map[string]any{"name": "The Testers", "timezone": "America/Chicago"}), 200, "family").str("id")
	join := func(role, name, email string) (string, string) {
		code := e.must(e.do("POST", "/api/collections/invites/records", f.owner, map[string]any{"family": f.fam, "role": role, "name": name}), 200, "invite").str("code")
		st, tok := e.signup(email, name, code)
		if st != 200 {
			t.Fatalf("signup %s: %d", email, st)
		}
		m := e.must(e.do("POST", "/api/roost/join", tok, map[string]any{"code": code}), 200, "join").str("membership")
		return tok, m
	}
	f.nanny, f.nannyMember = join("caregiver", "Maria", "nanny@example.com")
	f.grandma, _ = join("relative", "Grandma", "grandma@example.com")
	f.kid, f.kidMember = join("kid", "Emma", "emma@example.com")
	cals := e.list("calendars", f.owner, "")
	f.familyCal = byField(cals, "kind", "family")["id"].(string)
	f.personalCal = byField(cals, "kind", "personal")["id"].(string)
	lists := e.list("lists", f.owner, "")
	f.groceryList = byField(lists, "kind", "grocery")["id"].(string)
	f.todoList = byField(lists, "kind", "todo")["id"].(string)
	return f
}

func TestUpdatesMayEchoFamily(t *testing.T) {
	e := newEnv(t)
	f := setupFamily(t, e)
	e.must(e.do("PATCH", "/api/collections/lists/records/"+f.todoList, f.owner, map[string]any{"family": f.fam, "name": "Household"}), 200, "echoing family is fine")
	e.must(e.do("PATCH", "/api/collections/calendars/records/"+f.familyCal, f.owner, map[string]any{"family": f.fam, "color": "teal"}), 200, "calendar update")
	card := e.list("infoCards", f.owner, "")[0]["id"].(string)
	e.must(e.do("PATCH", "/api/collections/infoCards/records/"+card, f.owner, map[string]any{"family": f.fam, "title": "Contacts"}), 200, "card update")
	// …but nothing can move to another family.
	fam2 := e.must(e.do("POST", "/api/collections/families/records", f.owner, map[string]any{"name": "Second"}), 200, "second family").str("id")
	if r := e.do("PATCH", "/api/collections/lists/records/"+f.todoList, f.owner, map[string]any{"family": fam2}); r.Status == 200 {
		t.Fatal("a list must not move between families")
	}
}

func TestSubscriptionURLIsPrivate(t *testing.T) {
	e := newEnv(t)
	f := setupFamily(t, e)
	fetchURLHook = func(context.Context, string) (io.ReadCloser, error) {
		return io.NopCloser(strings.NewReader("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n")), nil
	}
	defer func() { fetchURLHook = nil }()
	cal := e.must(e.do("POST", "/api/collections/calendars/records", f.owner, map[string]any{
		"family": f.fam, "name": "Work", "kind": "subscription", "sourceUrl": "https://calendar.example.com/private-SECRET/basic.ics",
		"sharing": map[string]any{"roles": map[string]any{"caregiver": "busy", "relative": "view"}},
	}), 200, "subscription").str("id")
	if r := e.must(e.do("GET", "/api/collections/calendars/records/"+cal, f.owner, nil), 200, "owner view"); !strings.Contains(r.Raw, "SECRET") {
		t.Fatalf("the owner manages it and should see the URL: %s", r.Raw)
	}
	for who, tok := range map[string]string{"nanny": f.nanny, "grandma": f.grandma} {
		if r := e.must(e.do("GET", "/api/collections/calendars/records/"+cal, tok, nil), 200, who+" view"); strings.Contains(r.Raw, "SECRET") {
			t.Fatalf("%s must not see the subscription URL: %s", who, r.Raw)
		}
		if raw := mustJSON(e.list("calendars", tok, "")); strings.Contains(raw, "SECRET") {
			t.Fatalf("%s list leaks the URL", who)
		}
	}
	if r := e.must(e.do("POST", "/api/roost/calendars/"+cal+"/refresh", f.grandma, nil), 200, "grandma refresh"); strings.Contains(r.Raw, "SECRET") {
		t.Fatalf("refresh response leaks the URL: %s", r.Raw)
	}
}

func TestOnlyCurrentOwnerDeletesFamily(t *testing.T) {
	e := newEnv(t)
	_, creator := e.signup("a@example.com", "A", "")
	fam := e.must(e.do("POST", "/api/collections/families/records", creator, map[string]any{"name": "F"}), 200, "family").str("id")
	code := e.must(e.do("POST", "/api/collections/invites/records", creator, map[string]any{"family": fam, "role": "owner", "name": "B"}), 200, "invite owner").str("code")
	_, b := e.signup("b@example.com", "B", code)
	e.must(e.do("POST", "/api/roost/join", b, map[string]any{"code": code}), 200, "join")
	creatorMember := e.list("memberships", b, "name = 'A'")[0]["id"].(string)
	e.must(e.do("DELETE", "/api/collections/memberships/records/"+creatorMember, b, nil), 204, "co-owner removes creator")
	if r := e.do("DELETE", "/api/collections/families/records/"+fam, creator, nil); r.Status == 204 {
		t.Fatal("a removed creator must not delete the family")
	}
	e.must(e.do("DELETE", "/api/collections/families/records/"+fam, b, nil), 404, "families.owner still gates the rule")
}

func TestAssigneeCanOnlyComplete(t *testing.T) {
	e := newEnv(t)
	f := setupFamily(t, e)
	task := e.must(e.do("POST", "/api/collections/tasks/records", f.owner, map[string]any{
		"list": f.todoList, "title": "Water plants", "due": "2026-11-23", "rrule": "FREQ=WEEKLY", "assignees": []string{f.nannyMember},
	}), 200, "task").str("id")
	for _, body := range []map[string]any{{"title": "Nap"}, {"deleted": true}, {"assignees": []string{}}, {"priority": 3}} {
		if r := e.do("PATCH", "/api/collections/tasks/records/"+task, f.nanny, body); r.Status == 200 {
			t.Fatalf("assignee changed %v", body)
		}
	}
	e.must(e.do("PATCH", "/api/collections/tasks/records/"+task, f.nanny, map[string]any{"due": "2026-11-30"}), 200, "roll a repeating to-do forward")
	e.must(e.do("POST", "/api/collections/tasks/records", f.nanny, map[string]any{
		"list": f.todoList, "title": "Water plants", "due": "2026-11-23", "completed": true, "assignees": []string{f.nannyMember},
	}), 200, "file the completed copy")
	if r := e.do("POST", "/api/collections/tasks/records", f.nanny, map[string]any{"list": f.todoList, "title": "Sneaky", "assignees": []string{f.nannyMember}}); r.Status == 200 {
		t.Fatal("an assignee can't add open to-dos to a list she can't edit")
	}
	if r := e.do("POST", "/api/collections/tasks/records", f.nanny, map[string]any{"list": f.todoList, "title": "Sneaky", "completed": true}); r.Status == 200 {
		t.Fatal("completed copies must be assigned to the caller")
	}
	// A one-off assigned task: done, but not re-dated.
	one := e.must(e.do("POST", "/api/collections/tasks/records", f.owner, map[string]any{"list": f.todoList, "title": "Pack bag", "due": "2026-11-24", "assignees": []string{f.nannyMember}}), 200, "one-off").str("id")
	if r := e.do("PATCH", "/api/collections/tasks/records/"+one, f.nanny, map[string]any{"due": "2026-12-24"}); r.Status == 200 {
		t.Fatal("due is only movable on repeating to-dos")
	}
	e.must(e.do("PATCH", "/api/collections/tasks/records/"+one, f.nanny, map[string]any{"completed": true}), 200, "complete")
}

func TestEditorsCantDeleteOrRetypeLists(t *testing.T) {
	e := newEnv(t)
	f := setupFamily(t, e)
	for _, body := range []map[string]any{{"deleted": true}, {"kind": "todo"}, {"archived": true}} {
		if r := e.do("PATCH", "/api/collections/lists/records/"+f.groceryList, f.kid, body); r.Status == 200 {
			t.Fatalf("kid (grocery editor) did %v", body)
		}
	}
	e.must(e.do("PATCH", "/api/collections/lists/records/"+f.groceryList, f.kid, map[string]any{"storeOrder": []string{"produce", "dairy"}}), 200, "editors can reorder aisles")
	e.must(e.do("PATCH", "/api/collections/lists/records/"+f.groceryList, f.owner, map[string]any{"archived": true}), 200, "owner can archive")
}

func TestJSONShapesValidated(t *testing.T) {
	e := newEnv(t)
	f := setupFamily(t, e)
	start := time.Date(2026, 11, 24, 15, 0, 0, 0, time.UTC)
	ev := func(extra map[string]any) resp {
		body := map[string]any{"calendar": f.familyCal, "title": "X", "start": start.Format(time.RFC3339), "end": start.Add(time.Hour).Format(time.RFC3339), "tz": "America/Chicago"}
		for k, v := range extra {
			body[k] = v
		}
		return e.do("POST", "/api/collections/events/records", f.owner, body)
	}
	for _, bad := range []map[string]any{
		{"rrule": "FREQ=DAILY", "exdates": []string{"x"}}, {"exdates": 5}, {"exdates": map[string]any{"a": 1}},
		{"reminders": []any{"soon"}}, {"reminders": []int{-5}}, {"tz": "Mars/Olympus"}, {"url": "https://a\r\nX-INJECT:1"},
	} {
		if r := ev(bad); r.Status == 200 {
			t.Fatalf("accepted %v", bad)
		}
	}
	e.must(ev(map[string]any{"rrule": "FREQ=DAILY", "exdates": []string{"2026-11-25T09:00"}, "reminders": []int{0, 30}}), 200, "valid event")
	if r := e.do("POST", "/api/collections/tasks/records", f.owner, map[string]any{"list": f.todoList, "title": "T", "due": "tomorrow"}); r.Status == 200 {
		t.Fatal("bad due accepted")
	}
	if r := e.do("PATCH", "/api/collections/lists/records/"+f.groceryList, f.owner, map[string]any{"storeOrder": "produce"}); r.Status == 200 {
		t.Fatal("storeOrder must be a list")
	}
	if _, ok := exdateValue("x", true, "UTC"); ok {
		t.Fatal("short exdate keys are skipped, not sliced")
	}
	if strings.Contains(stripCRLF("a\r\nb"), "\n") {
		t.Fatal("CRLF kept")
	}
}

func TestLearnedTermsNeedGroceryAccess(t *testing.T) {
	e := newEnv(t)
	f := setupFamily(t, e)
	if r := e.do("POST", "/api/collections/groceryLearned/records", f.grandma, map[string]any{"family": f.fam, "term": "milk", "category": "pets"}); r.Status == 200 {
		t.Fatal("grandma has no grocery access and can't teach terms")
	}
	e.must(e.do("POST", "/api/collections/groceryLearned/records", f.nanny, map[string]any{"family": f.fam, "term": "masa", "category": "international"}), 200, "nanny edits groceries")
}

func TestInviteMakesOneAccount(t *testing.T) {
	e := newEnv(t)
	_, owner := e.signup("parent@example.com", "Alex", "")
	fam := e.must(e.do("POST", "/api/collections/families/records", owner, map[string]any{"name": "F"}), 200, "family").str("id")
	code := e.must(e.do("POST", "/api/collections/invites/records", owner, map[string]any{"family": fam, "role": "caregiver"}), 200, "invite").str("code")
	if st, _ := e.signup("one@example.com", "One", code); st != 200 {
		t.Fatal("first sign-up with the invite should work")
	}
	if st, _ := e.signup("two@example.com", "Two", code); st != 403 {
		t.Fatalf("second sign-up with the same invite: %d", st)
	}
}

func TestSetupCodeGuardsFirstAccount(t *testing.T) {
	e := newEnvCfg(t, Config{SetupCode: "ABCD-EFGH"})
	if c := e.must(e.do("GET", "/api/roost/config", "", nil), 200, "config"); c.Body["setupCode"] != true {
		t.Fatalf("config should ask for the setup code: %s", c.Raw)
	}
	if st, _ := e.signup("intruder@example.com", "I", ""); st != 403 {
		t.Fatalf("first sign-up without the setup code: %d", st)
	}
	if st, _ := e.signup("owner@example.com", "O", "abcdefgh"); st != 200 {
		t.Fatalf("setup code (any case, no dash) should work: %d", st)
	}
}

func TestManualRefreshThrottle(t *testing.T) {
	old := manualRefreshEvery
	manualRefreshEvery = time.Minute
	defer func() { manualRefreshEvery = old }()
	if !allowManualRefresh("cal-throttle") || allowManualRefresh("cal-throttle") || !allowManualRefresh("cal-other") {
		t.Fatal("one refresh per calendar per interval")
	}
}

func TestBlockedIPs(t *testing.T) {
	for _, s := range []string{"127.0.0.1", "10.1.2.3", "192.168.1.5", "100.101.102.103", "169.254.169.254", "198.18.0.1", "::1", "fd00::1", "64:ff9b::a00:1", "0.0.0.0"} {
		if !blockedIP(net.ParseIP(s)) {
			t.Errorf("%s should be blocked", s)
		}
	}
	for _, s := range []string{"8.8.8.8", "142.250.72.14", "2606:4700::1111"} {
		if blockedIP(net.ParseIP(s)) {
			t.Errorf("%s should be allowed", s)
		}
	}
}
