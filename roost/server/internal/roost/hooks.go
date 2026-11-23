package roost

import (
	"crypto/rand"
	"encoding/base32"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

var shareable = []string{"calendars", "lists", "infoCards"}

func registerHooks(app core.App, cfg Config) {
	// ---- sign-up gate ----------------------------------------------------
	app.OnRecordCreateRequest("users").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.HasSuperuserAuth() || cfg.OpenSignup {
			return e.Next()
		}
		total, _ := e.App.CountRecords("families")
		if total == 0 {
			return e.Next() // bootstrap: the very first family owner
		}
		info, _ := e.RequestInfo()
		code, _ := info.Body["inviteCode"].(string)
		if inv := findValidInvite(e.App, code); inv != nil {
			return e.Next()
		}
		return e.ForbiddenError("Sign-up needs an invite code from your family.", nil)
	})

	// ---- families: owner + seed defaults ---------------------------------
	app.OnRecordCreateRequest("families").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.Auth == nil {
			return e.UnauthorizedError("Sign in first.", nil)
		}
		e.Record.Set("owner", e.Auth.Id)
		if e.Record.GetString("timezone") == "" {
			e.Record.Set("timezone", cfg.DefaultTimezone)
		}
		if err := e.Next(); err != nil {
			return err
		}
		return seedFamily(e.App, e.Record, e.Auth)
	})

	// ---- memberships -----------------------------------------------------
	app.OnRecordCreateRequest("memberships").BindFunc(func(e *core.RecordRequestEvent) error {
		if err := guardRoleChange(e, "", e.Record.GetString("role")); err != nil {
			return err
		}
		if e.Record.GetString("color") == "" {
			e.Record.Set("color", nextColor(e.App, e.Record.GetString("family")))
		}
		return e.Next()
	})
	app.OnRecordUpdateRequest("memberships").BindFunc(func(e *core.RecordRequestEvent) error {
		orig := e.Record.Original()
		if err := guardRoleChange(e, orig.GetString("role"), e.Record.GetString("role")); err != nil {
			return err
		}
		return e.Next()
	})
	app.OnRecordDeleteRequest("memberships").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.Record.GetString("role") == RoleOwner {
			me := membershipFor(e.App, e.Record.GetString("family"), authID(e.RequestEvent))
			if me == nil || me.GetString("role") != RoleOwner {
				return e.ForbiddenError("Only an owner can remove an owner.", nil)
			}
			if countOwners(e.App, e.Record.GetString("family")) <= 1 {
				return e.BadRequestError("A family needs at least one owner.", nil)
			}
		}
		return e.Next()
	})
	recompute := func(e *core.RecordEvent) error {
		if err := e.Next(); err != nil {
			return err
		}
		return RecomputeFamily(e.App, e.Record.GetString("family"))
	}
	app.OnRecordAfterCreateSuccess("memberships").BindFunc(recompute)
	app.OnRecordAfterUpdateSuccess("memberships").BindFunc(recompute)
	app.OnRecordAfterDeleteSuccess("memberships").BindFunc(recompute)

	// ---- shareable resources: compute access before every save ----------
	computeHook := func(e *core.RecordEvent) error {
		if err := computeAccess(e.App, e.Record); err != nil {
			return err
		}
		return e.Next()
	}
	app.OnRecordCreate(shareable...).BindFunc(computeHook)
	app.OnRecordUpdate(shareable...).BindFunc(computeHook)

	app.OnRecordCreateRequest(shareable...).BindFunc(func(e *core.RecordRequestEvent) error {
		fam := e.Record.GetString("family")
		me := membershipFor(e.App, fam, authID(e.RequestEvent))
		if me == nil && !e.HasSuperuserAuth() {
			return e.ForbiddenError("Not a member of this family.", nil)
		}
		if me != nil {
			role := me.GetString("role")
			// Relatives and kids can't create shared resources; caregivers only lists.
			coll := e.Record.Collection().Name
			if role == RoleRelative || role == RoleKid || (role == RoleCaregiver && coll != "lists") {
				return e.ForbiddenError("Your role can't create this.", nil)
			}
			if e.Record.GetString("owner") == "" && (coll != "calendars" || e.Record.GetString("kind") == "personal") {
				e.Record.Set("owner", me.Id)
			}
		}
		if err := checkSameFamily(e.App, fam, "memberships", e.Record.GetString("owner")); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		if e.Record.Collection().Name == "infoCards" {
			if err := checkSameFamily(e.App, fam, "memberships", e.Record.GetString("aboutMember")); err != nil {
				return e.BadRequestError(err.Error(), nil)
			}
		}
		if err := validateSharing(e.Record); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		if err := normalizeSubscription(e.Record); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		return e.Next()
	})
	app.OnRecordUpdateRequest(shareable...).BindFunc(func(e *core.RecordRequestEvent) error {
		orig := e.Record.Original()
		fam := orig.GetString("family")
		e.Record.Set("family", fam)
		if !jsonEqual(orig.Get("sharing"), e.Record.Get("sharing")) || orig.GetString("owner") != e.Record.GetString("owner") {
			if !canManage(e.App, orig, authID(e.RequestEvent)) && !e.HasSuperuserAuth() {
				return e.ForbiddenError("Only parents or the owner can change sharing.", nil)
			}
			if err := checkSameFamily(e.App, fam, "memberships", e.Record.GetString("owner")); err != nil {
				return e.BadRequestError(err.Error(), nil)
			}
		}
		if err := validateSharing(e.Record); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		if err := normalizeSubscription(e.Record); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		return e.Next()
	})
	// Fetch a new subscription right away so it isn't empty for 10 minutes.
	app.OnRecordAfterCreateSuccess("calendars").BindFunc(func(e *core.RecordEvent) error {
		if err := e.Next(); err != nil {
			return err
		}
		if asyncInitialSync && e.Record.GetString("kind") == "subscription" && e.Record.GetString("sourceUrl") != "" {
			rec := e.Record
			go func() { _ = SyncSubscription(app, cfg, rec) }()
		}
		return nil
	})

	// ---- events ----------------------------------------------------------
	app.OnRecordCreate("events").BindFunc(func(e *core.RecordEvent) error {
		if cal, err := e.App.FindRecordById("calendars", e.Record.GetString("calendar")); err == nil {
			e.Record.Set("family", cal.GetString("family"))
		}
		if e.Record.GetString("source") == "" {
			e.Record.Set("source", "roost")
		}
		return e.Next()
	})
	app.OnRecordCreateRequest("events").BindFunc(func(e *core.RecordRequestEvent) error {
		e.Record.Set("source", "roost")
		e.Record.Set("createdBy", authID(e.RequestEvent))
		e.Record.Set("updatedBy", authID(e.RequestEvent))
		if err := validateEvent(e.App, e.Record); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		return e.Next()
	})
	app.OnRecordUpdateRequest("events").BindFunc(func(e *core.RecordRequestEvent) error {
		orig := e.Record.Original()
		uid := authID(e.RequestEvent)
		if newCal := e.Record.GetString("calendar"); newCal != orig.GetString("calendar") {
			cal, err := e.App.FindRecordById("calendars", newCal)
			if err != nil || cal.GetString("family") != orig.GetString("family") || !contains(cal.GetStringSlice("editors"), uid) {
				return e.ForbiddenError("You can't move events to that calendar.", nil)
			}
		}
		e.Record.Set("family", orig.GetString("family"))
		e.Record.Set("updatedBy", uid)
		if err := validateEvent(e.App, e.Record); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		return e.Next()
	})

	// ---- tasks & grocery items ------------------------------------------
	setFamilyFromList := func(e *core.RecordEvent) error {
		if l, err := e.App.FindRecordById("lists", e.Record.GetString("list")); err == nil {
			e.Record.Set("family", l.GetString("family"))
		}
		return e.Next()
	}
	app.OnRecordCreate("tasks", "groceryItems").BindFunc(setFamilyFromList)

	app.OnRecordCreateRequest("tasks").BindFunc(func(e *core.RecordRequestEvent) error {
		e.Record.Set("createdBy", authID(e.RequestEvent))
		if err := validateTask(e.App, e.Record); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		return e.Next()
	})
	app.OnRecordUpdateRequest("tasks").BindFunc(func(e *core.RecordRequestEvent) error {
		orig := e.Record.Original()
		if err := checkListMove(e, orig); err != nil {
			return err
		}
		e.Record.Set("family", orig.GetString("family"))
		if e.Record.GetBool("completed") && !orig.GetBool("completed") {
			e.Record.Set("completedBy", authID(e.RequestEvent))
			if e.Record.GetDateTime("completedAt").IsZero() {
				e.Record.Set("completedAt", types.NowDateTime())
			}
		}
		if err := validateTask(e.App, e.Record); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		return e.Next()
	})
	app.OnRecordCreateRequest("groceryItems").BindFunc(func(e *core.RecordRequestEvent) error {
		e.Record.Set("addedBy", authID(e.RequestEvent))
		return e.Next()
	})
	app.OnRecordUpdateRequest("groceryItems").BindFunc(func(e *core.RecordRequestEvent) error {
		orig := e.Record.Original()
		if err := checkListMove(e, orig); err != nil {
			return err
		}
		e.Record.Set("family", orig.GetString("family"))
		if e.Record.GetBool("checked") && !orig.GetBool("checked") {
			e.Record.Set("checkedBy", authID(e.RequestEvent))
			e.Record.Set("checkedAt", types.NowDateTime())
		}
		return e.Next()
	})

	// ---- learned grocery terms ------------------------------------------
	app.OnRecordCreateRequest("groceryLearned").BindFunc(func(e *core.RecordRequestEvent) error {
		e.Record.Set("term", strings.ToLower(strings.TrimSpace(e.Record.GetString("term"))))
		// Upsert semantics: replace an existing mapping for the same term.
		if old, err := e.App.FindFirstRecordByFilter("groceryLearned", "family = {:f} && term = {:t}",
			dbx.Params{"f": e.Record.GetString("family"), "t": e.Record.GetString("term")}); err == nil {
			if err := e.App.Delete(old); err != nil {
				return err
			}
		}
		return e.Next()
	})

	// ---- invites ---------------------------------------------------------
	app.OnRecordCreateRequest("invites").BindFunc(func(e *core.RecordRequestEvent) error {
		fam := e.Record.GetString("family")
		me := membershipFor(e.App, fam, authID(e.RequestEvent))
		if e.Record.GetString("role") == RoleOwner && (me == nil || me.GetString("role") != RoleOwner) {
			return e.ForbiddenError("Only an owner can invite another owner.", nil)
		}
		if mid := e.Record.GetString("membership"); mid != "" {
			m, err := e.App.FindRecordById("memberships", mid)
			if err != nil || m.GetString("family") != fam {
				return e.BadRequestError("That profile isn't in this family.", nil)
			}
			if m.GetString("user") != "" {
				return e.BadRequestError("That profile already has a login.", nil)
			}
		}
		e.Record.Set("code", newInviteCode())
		e.Record.Set("createdBy", authID(e.RequestEvent))
		if e.Record.GetDateTime("expiresAt").IsZero() {
			exp, _ := types.ParseDateTime(time.Now().Add(7 * 24 * time.Hour))
			e.Record.Set("expiresAt", exp)
		}
		return e.Next()
	})

	// ---- feeds -----------------------------------------------------------
	app.OnRecordCreateRequest("feeds").BindFunc(func(e *core.RecordRequestEvent) error {
		e.Record.Set("token", randomToken(32))
		if e.Record.GetString("name") == "" {
			e.Record.Set("name", "Roost")
		}
		return e.Next()
	})
}

// -------------------------------------------------------------------------

func authID(e *core.RequestEvent) string {
	if e == nil || e.Auth == nil {
		return ""
	}
	return e.Auth.Id
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

func jsonEqual(a, b any) bool {
	ja, _ := json.Marshal(a)
	jb, _ := json.Marshal(b)
	norm := func(j []byte) string {
		s := string(j)
		if s == "null" || s == `""` || s == "{}" {
			return ""
		}
		return s
	}
	return norm(ja) == norm(jb)
}

func canManage(app core.App, r *core.Record, uid string) bool {
	me := membershipFor(app, r.GetString("family"), uid)
	if me == nil {
		return false
	}
	return isAdminRole(me.GetString("role")) || (r.GetString("owner") != "" && r.GetString("owner") == me.Id)
}

func countOwners(app core.App, familyID string) int {
	n, _ := app.CountRecords("memberships", dbx.HashExp{"family": familyID, "role": RoleOwner})
	return int(n)
}

func guardRoleChange(e *core.RecordRequestEvent, from, to string) error {
	if from == to || e.HasSuperuserAuth() {
		return nil
	}
	fam := e.Record.GetString("family")
	me := membershipFor(e.App, fam, authID(e.RequestEvent))
	if (from == RoleOwner || to == RoleOwner) && (me == nil || me.GetString("role") != RoleOwner) {
		return e.ForbiddenError("Only an owner can grant or remove the owner role.", nil)
	}
	if from == RoleOwner && countOwners(e.App, fam) <= 1 {
		return e.BadRequestError("A family needs at least one owner.", nil)
	}
	return nil
}

func checkSameFamily(app core.App, familyID, collection string, ids ...string) error {
	for _, id := range ids {
		if id == "" {
			continue
		}
		r, err := app.FindRecordById(collection, id)
		if err != nil || r.GetString("family") != familyID {
			return fmt.Errorf("%s %q is not in this family", strings.TrimSuffix(collection, "s"), id)
		}
	}
	return nil
}

func validateSharing(r *core.Record) error {
	s := parseSharing(r)
	for role, l := range s.Roles {
		if !contains(Roles, role) || !validLevel(l) {
			return fmt.Errorf("invalid sharing for role %q", role)
		}
	}
	for _, l := range s.People {
		if !validLevel(l) {
			return fmt.Errorf("invalid sharing level %q", l)
		}
	}
	return nil
}

func normalizeSubscription(r *core.Record) error {
	if r.Collection().Name != "calendars" {
		return nil
	}
	if r.GetString("kind") != "subscription" {
		r.Set("sourceUrl", "")
		return nil
	}
	u, err := normalizeFeedURL(r.GetString("sourceUrl"))
	if err != nil {
		return err
	}
	r.Set("sourceUrl", u)
	return nil
}

func validateEvent(app core.App, r *core.Record) error {
	cal, err := app.FindRecordById("calendars", r.GetString("calendar"))
	if err != nil {
		return fmt.Errorf("calendar not found")
	}
	fam := cal.GetString("family")
	if err := checkSameFamily(app, fam, "memberships", append(r.GetStringSlice("members"), r.GetString("driver"))...); err != nil {
		return err
	}
	if p := r.GetString("recurrenceParent"); p != "" {
		if err := checkSameFamily(app, fam, "events", p); err != nil {
			return err
		}
	}
	start, end := r.GetDateTime("start"), r.GetDateTime("end")
	if !end.IsZero() && end.Time().Before(start.Time()) {
		return fmt.Errorf("event ends before it starts")
	}
	if r.GetString("tz") == "" {
		if f, err := app.FindRecordById("families", fam); err == nil {
			r.Set("tz", f.GetString("timezone"))
		}
	}
	if rr := r.GetString("rrule"); rr != "" && !strings.Contains(strings.ToUpper(rr), "FREQ=") {
		return fmt.Errorf("rrule needs FREQ")
	}
	return nil
}

func validateTask(app core.App, r *core.Record) error {
	l, err := app.FindRecordById("lists", r.GetString("list"))
	if err != nil {
		return fmt.Errorf("list not found")
	}
	fam := l.GetString("family")
	if err := checkSameFamily(app, fam, "memberships", r.GetStringSlice("assignees")...); err != nil {
		return err
	}
	if p := r.GetString("parent"); p != "" {
		if err := checkSameFamily(app, fam, "tasks", p); err != nil {
			return err
		}
	}
	return nil
}

func checkListMove(e *core.RecordRequestEvent, orig *core.Record) error {
	newList := e.Record.GetString("list")
	if newList == orig.GetString("list") {
		return nil
	}
	uid := authID(e.RequestEvent)
	src, err := e.App.FindRecordById("lists", orig.GetString("list"))
	if err != nil || !contains(src.GetStringSlice("editors"), uid) {
		return e.ForbiddenError("You can't move items out of this list.", nil)
	}
	l, err := e.App.FindRecordById("lists", newList)
	if err != nil || l.GetString("family") != orig.GetString("family") || !contains(l.GetStringSlice("editors"), uid) {
		return e.ForbiddenError("You can't move items to that list.", nil)
	}
	return nil
}

// Person colors (DESIGN §12), handed out in order.
var personColors = []string{"blue", "orange", "green", "violet", "pink", "teal", "red", "amber", "indigo", "cyan", "lime", "brown"}

func nextColor(app core.App, familyID string) string {
	used := map[string]bool{}
	if ms, err := familyMemberships(app, familyID); err == nil {
		for _, m := range ms {
			used[m.GetString("color")] = true
		}
		for _, c := range personColors {
			if !used[c] {
				return c
			}
		}
		return personColors[len(ms)%len(personColors)]
	}
	return personColors[0]
}

func randomToken(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return strings.TrimRight(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b), "=")
}

// Invite codes avoid ambiguous characters and read well aloud: "K7QM-2XPD".
func newInviteCode() string {
	const alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	out := make([]byte, 0, 9)
	for i, v := range b {
		if i == 4 {
			out = append(out, '-')
		}
		out = append(out, alphabet[int(v)%len(alphabet)])
	}
	return string(out)
}

func normalizeInviteCode(code string) string {
	c := strings.ToUpper(strings.ReplaceAll(strings.TrimSpace(code), " ", ""))
	c = strings.ReplaceAll(c, "-", "")
	if len(c) == 8 {
		return c[:4] + "-" + c[4:]
	}
	return c
}

func findValidInvite(app core.App, code string) *core.Record {
	code = normalizeInviteCode(code)
	if code == "" {
		return nil
	}
	inv, err := app.FindFirstRecordByData("invites", "code", code)
	if err != nil || inv.GetString("usedBy") != "" {
		return nil
	}
	if exp := inv.GetDateTime("expiresAt"); !exp.IsZero() && exp.Time().Before(time.Now()) {
		return nil
	}
	return inv
}

// seedFamily creates the owner's membership plus sensible defaults so a new
// family lands on a useful screen.
func seedFamily(app core.App, family *core.Record, auth *core.Record) error {
	mColl, err := app.FindCollectionByNameOrId("memberships")
	if err != nil {
		return err
	}
	name := strings.TrimSpace(auth.GetString("name"))
	if name == "" {
		name = strings.Split(auth.GetString("email"), "@")[0]
	}
	owner := core.NewRecord(mColl)
	owner.Set("family", family.Id)
	owner.Set("user", auth.Id)
	owner.Set("name", name)
	owner.Set("role", RoleOwner)
	owner.Set("color", personColors[0])
	owner.Set("sortOrder", 0)
	if err := app.Save(owner); err != nil {
		return err
	}
	if err := RecomputeFamily(app, family.Id); err != nil {
		return err
	}

	mk := func(coll string, fields map[string]any) error {
		c, err := app.FindCollectionByNameOrId(coll)
		if err != nil {
			return err
		}
		r := core.NewRecord(c)
		r.Set("family", family.Id)
		for k, v := range fields {
			r.Set(k, v)
		}
		return app.Save(r)
	}
	steps := []struct {
		coll   string
		fields map[string]any
	}{
		{"calendars", map[string]any{"name": "Family", "kind": "family", "color": "orange", "sortOrder": 0, "defaultReminders": []int{30}}},
		{"calendars", map[string]any{"name": name, "kind": "personal", "color": personColors[0], "owner": owner.Id, "sortOrder": 1, "defaultReminders": []int{15}}},
		{"lists", map[string]any{"name": "Groceries", "kind": "grocery", "icon": "cart", "color": "green", "sortOrder": 0}},
		{"lists", map[string]any{"name": "To-Do", "kind": "todo", "icon": "checklist", "color": "blue", "sortOrder": 1}},
		{"infoCards", map[string]any{"title": "Emergency contacts", "kind": "contact", "icon": "phone", "pinned": true, "sortOrder": 0,
			"body": "Pediatrician: \nPoison Control: 1-800-222-1222\nNeighbor: \nGrandparents: "}},
		{"infoCards", map[string]any{"title": "Allergies & medications", "kind": "medical", "icon": "cross.case", "pinned": true, "sortOrder": 1,
			"body": "Allergies: none known\nMedications: \nInsurance: "}},
	}
	for _, s := range steps {
		if err := mk(s.coll, s.fields); err != nil {
			return err
		}
	}
	return nil
}
