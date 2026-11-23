package roost

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

// mcpCall sends one JSON-RPC request to the MCP endpoint with an agent key.
func (e *env) mcpCall(key, method string, params any) resp {
	e.t.Helper()
	return e.do("POST", "/api/roost/mcp", "Bearer "+key, map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
}

// tool calls a tool and returns its structured result (or fails on a protocol error).
func (e *env) tool(key, name string, args map[string]any) (map[string]any, bool) {
	e.t.Helper()
	r := e.must(e.mcpCall(key, "tools/call", map[string]any{"name": name, "arguments": args}), 200, "tools/call "+name)
	res, ok := r.Body["result"].(map[string]any)
	if !ok {
		e.t.Fatalf("%s: no result: %s", name, r.Raw)
	}
	if isErr, _ := res["isError"].(bool); isErr {
		content := res["content"].([]any)[0].(map[string]any)
		return map[string]any{"error": content["text"]}, false
	}
	sc, _ := res["structuredContent"].(map[string]any)
	return sc, true
}

func TestMCPEndpoint(t *testing.T) {
	e := newEnv(t)
	_, owner := e.signup("parent@example.com", "Alex", "")
	famID := e.must(e.do("POST", "/api/collections/families/records", owner, map[string]any{"name": "The Testers", "timezone": "America/Chicago"}), 200, "family").str("id")
	e.must(e.do("POST", "/api/collections/memberships/records", owner, map[string]any{"family": famID, "name": "Emma", "role": "kid"}), 200, "kid")
	invite := func(role, name, email string) string {
		code := e.must(e.do("POST", "/api/collections/invites/records", owner, map[string]any{"family": famID, "role": role, "name": name}), 200, "invite").str("code")
		_, tok := e.signup(email, name, code)
		e.must(e.do("POST", "/api/roost/join", tok, map[string]any{"code": code}), 200, "join")
		return tok
	}
	nanny := invite("caregiver", "Maria", "nanny@example.com")
	grandma := invite("relative", "Grandma", "grandma@example.com")
	cals := e.list("calendars", owner, "")
	personalCal := byField(cals, "kind", "personal")["id"].(string)

	newKey := func(token, name string) string {
		r := e.must(e.do("POST", "/api/roost/agent-keys", token, map[string]any{"family": famID, "name": name}), 200, "agent key")
		k := r.str("token")
		if !strings.HasPrefix(k, "rk_") || len(k) < 40 {
			t.Fatalf("bad key %q", k)
		}
		return k
	}
	ownerKey, nannyKey, grandmaKey := newKey(owner, "Claude Desktop"), newKey(nanny, "Nanny's assistant"), newKey(grandma, "")
	e.must(e.do("POST", "/api/roost/agent-keys", "", map[string]any{"family": famID}), 401, "keys need a signed-in user")

	// The secret is never readable back.
	keys := e.list("agentKeys", owner, "")
	if len(keys) != 1 || strings.Contains(mustJSON(keys), ownerKey) || keys[0]["tokenHash"] != nil || keys[0]["hint"] != ownerKey[len(ownerKey)-4:] {
		t.Fatalf("agentKeys leak or wrong: %v", keys)
	}
	if n := len(e.list("agentKeys", nanny, "")); n != 1 {
		t.Fatalf("nanny should see only her own key, got %d", n)
	}
	e.must(e.do("POST", "/api/collections/agentKeys/records", owner, map[string]any{"family": famID, "user": "x", "tokenHash": "abc"}), 403, "keys only via the route")

	// --- protocol
	e.must(e.do("POST", "/api/roost/mcp", "", map[string]any{"jsonrpc": "2.0", "id": 1, "method": "initialize"}), 401, "no key")
	e.must(e.mcpCall("rk_"+strings.Repeat("a", 40), "initialize", nil), 401, "unknown key")
	e.must(e.do("POST", "/api/roost/mcp", owner, map[string]any{"jsonrpc": "2.0", "id": 1, "method": "initialize"}), 401, "a session token is not an agent key")
	init := e.must(e.mcpCall(ownerKey, "initialize", map[string]any{"protocolVersion": "2025-03-26", "capabilities": map[string]any{}, "clientInfo": map[string]any{"name": "test"}}), 200, "initialize")
	res := init.Body["result"].(map[string]any)
	if res["protocolVersion"] != "2025-03-26" || res["serverInfo"].(map[string]any)["name"] != "roost" {
		t.Fatalf("initialize: %s", init.Raw)
	}
	e.must(e.do("POST", "/api/roost/mcp", "Bearer "+ownerKey, map[string]any{"jsonrpc": "2.0", "method": "notifications/initialized"}), 202, "notification")
	tl := e.must(e.mcpCall(ownerKey, "tools/list", nil), 200, "tools/list")
	if n := len(tl.Body["result"].(map[string]any)["tools"].([]any)); n != 9 {
		t.Fatalf("expected 9 tools, got %d", n)
	}
	if r := e.mcpCall(ownerKey, "bogus/method", nil); r.Body["error"] == nil {
		t.Fatalf("unknown method should be a JSON-RPC error: %s", r.Raw)
	}

	// --- overview
	ov, _ := e.tool(ownerKey, "family_overview", nil)
	if ov["family"] != "The Testers" || ov["timezone"] != "America/Chicago" || len(ov["people"].([]any)) != 4 {
		t.Fatalf("overview: %v", ov)
	}

	// --- events: a weekly recurring event, expanded server-side
	day := time.Now().In(loadLoc("America/Chicago")).AddDate(0, 0, 1).Format("2006-01-02")
	ev, ok := e.tool(ownerKey, "add_event", map[string]any{"title": "Swim lessons", "start": day + "T16:30", "end": day + "T17:15",
		"repeat": "FREQ=WEEKLY", "people": []string{"emma"}, "driver": "Maria", "reminders_minutes": []int{30}})
	if !ok || !strings.Contains(ev["start"].(string), "T16:30:00-0") {
		t.Fatalf("add_event: %v", ev)
	}
	if _, ok := e.tool(ownerKey, "add_event", map[string]any{"title": "Therapy", "start": day + "T09:00", "calendar": "nope"}); ok {
		t.Fatal("unknown calendar should fail")
	}
	// Owner's personal-calendar appointment and a private family event.
	e.must(e.do("POST", "/api/collections/events/records", owner, map[string]any{"calendar": personalCal, "title": "Dermatology",
		"start": day + " 15:00:00.000Z", "end": day + " 16:00:00.000Z", "tz": "America/Chicago"}), 200, "personal event")
	if _, ok := e.tool(ownerKey, "add_event", map[string]any{"title": "Surprise party planning", "start": day}); !ok {
		t.Fatal("all-day add failed")
	}
	evs, _ := e.tool(ownerKey, "list_events", map[string]any{"from": day, "days": 15})
	swims := 0
	for _, x := range evs["events"].([]any) {
		m := x.(map[string]any)
		if m["title"] == "Swim lessons" {
			swims++
			if m["driver"] != "Maria" || m["people"].([]any)[0] != "Emma" {
				t.Fatalf("swim details: %v", m)
			}
		}
	}
	if swims != 3 {
		t.Fatalf("expected 3 weekly occurrences in 15 days, got %d: %v", swims, evs)
	}
	if f, _ := e.tool(ownerKey, "list_events", map[string]any{"from": day, "days": 1, "person": "Emma"}); len(f["events"].([]any)) != 1 {
		t.Fatalf("person filter: %v", f)
	}

	// Nanny sees the owner's personal appointment only as Busy.
	nevs, _ := e.tool(nannyKey, "list_events", map[string]any{"from": day, "days": 1})
	raw := mustJSON(nevs)
	if strings.Contains(raw, "Dermatology") || !strings.Contains(raw, `"Busy"`) || !strings.Contains(raw, "Swim lessons") {
		t.Fatalf("nanny events: %s", raw)
	}
	// Grandma can read the family calendar but not add to it.
	if _, ok := e.tool(grandmaKey, "add_event", map[string]any{"title": "Visit", "start": day + "T10:00"}); ok {
		t.Fatal("grandma's calendar access is read-only")
	}

	// --- groceries: parsing, aisles, merging, check-off
	g, ok := e.tool(ownerKey, "add_groceries", map[string]any{"items": []string{"2 lb chicken breast", "milk", "3 avocados", "frozen peas", "Milk"}})
	if !ok || len(g["added"].([]any)) != 4 || len(g["mergedWithExisting"].([]any)) != 1 {
		t.Fatalf("add_groceries: %v", g)
	}
	gl, _ := e.tool(nannyKey, "grocery_list", nil)
	aisles := map[string][]any{}
	for _, a := range gl["aisles"].([]any) {
		m := a.(map[string]any)
		aisles[m["aisle"].(string)] = m["items"].([]any)
	}
	if gl["count"].(float64) != 4 || aisles["Produce"] == nil || aisles["Frozen"] == nil {
		t.Fatalf("grocery_list: %v", gl)
	}
	if !strings.Contains(mustJSON(gl), "Milk (2)") || !strings.Contains(mustJSON(gl), "Chicken breast (2 lb)") {
		t.Fatalf("quantities: %s", mustJSON(gl))
	}
	co, _ := e.tool(nannyKey, "check_off_groceries", map[string]any{"items": []string{"milk", "unicorn"}})
	if len(co["checkedOff"].([]any)) != 1 || len(co["notOnList"].([]any)) != 1 {
		t.Fatalf("check off: %v", co)
	}
	if r, ok := e.tool(grandmaKey, "grocery_list", nil); ok {
		t.Fatalf("grandma has no list access: %v", r)
	}

	// --- to-dos: assign the nanny a repeating chore; she completes it.
	day2 := time.Now().In(loadLoc("America/Chicago")).Format("2006-01-02")
	at, ok := e.tool(ownerKey, "add_task", map[string]any{"title": "Water plants", "due": day2, "assignees": []string{"maria"}, "repeat": "FREQ=WEEKLY"})
	if !ok {
		t.Fatalf("add_task: %v", at)
	}
	id := at["added"].(map[string]any)["id"].(string)
	mine, _ := e.tool(nannyKey, "list_tasks", map[string]any{"assigned_to_me": true})
	if len(mine["tasks"].([]any)) != 1 {
		t.Fatalf("nanny's tasks: %v", mine)
	}
	done, ok := e.tool(nannyKey, "complete_task", map[string]any{"id": id})
	next, _ := time.Parse("2006-01-02", day2)
	if !ok || done["nextDue"] != next.AddDate(0, 0, 7).Format("2006-01-02") {
		t.Fatalf("complete_task: %v", done)
	}
	if _, ok := e.tool(grandmaKey, "complete_task", map[string]any{"id": id}); ok {
		t.Fatal("grandma can't complete someone else's task")
	}
	completed := e.list("tasks", owner, "completed = true")
	if len(completed) != 1 || completed[0]["title"] != "Water plants" {
		t.Fatalf("completed copy: %v", completed)
	}

	// --- revoking a key cuts access immediately.
	e.must(e.do("DELETE", "/api/collections/agentKeys/records/"+keys[0]["id"].(string), owner, nil), 204, "revoke")
	e.must(e.mcpCall(ownerKey, "ping", nil), 401, "revoked key")
	// Removing a person from the family cuts their keys too.
	nannyMember := e.list("memberships", owner, "role = 'caregiver'")[0]["id"].(string)
	e.must(e.do("DELETE", "/api/collections/memberships/records/"+nannyMember, owner, nil), 204, "remove nanny")
	e.must(e.mcpCall(nannyKey, "ping", nil), 403, "removed member")
}

func TestTaskRecurrenceFixtures(t *testing.T) {
	raw, err := os.ReadFile("../../../shared/fixtures/taskrecurrence.json")
	if err != nil {
		t.Fatal(err)
	}
	var fx struct {
		Cases []struct {
			Name, Due, RRule, CompletedAt string
			Expected                      *string
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	for _, c := range fx.Cases {
		done := parseLocal(c.CompletedAt).date
		got := nextTaskDue(c.Due, c.RRule, done)
		want := ""
		if c.Expected != nil {
			want = *c.Expected
		}
		if got != want {
			t.Errorf("%s: got %q want %q", c.Name, got, want)
		}
	}
}

func TestParseGroceryItem(t *testing.T) {
	for in, want := range map[string][3]string{
		"2 lb chicken breast": {"Chicken breast", "2", "lb"},
		"milk x2":             {"Milk", "2", ""},
		"3 avocados":          {"Avocados", "3", ""},
		"1 bag of carrots":    {"Carrots", "1", "bag"},
		"half and half":       {"Half and half", "0", ""},
	} {
		n, q, u := parseItem(in)
		if n != want[0] || u != want[2] || strings.TrimSuffix(strings.TrimSuffix(jsonNum(q), ".0"), "") != want[1] {
			t.Errorf("%q → %q %v %q", in, n, q, u)
		}
	}
	if mergeKey("Avocados") != mergeKey("avocado") {
		t.Error("merge key should singularize")
	}
}

func jsonNum(f float64) string { b, _ := json.Marshal(f); return string(b) }

func mustJSON(v any) string { b, _ := json.Marshal(v); return string(b) }
