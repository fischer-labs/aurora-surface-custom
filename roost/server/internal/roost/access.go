package roost

import (
	"encoding/json"
	"slices"
	"sort"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

// Access levels, ordered.
const (
	LevelNone = "none"
	LevelBusy = "busy"
	LevelView = "view"
	LevelEdit = "edit"
)

var levelRank = map[string]int{LevelNone: 0, LevelBusy: 1, LevelView: 2, LevelEdit: 3}

// Sharing is the per-resource override object stored in the `sharing` JSON field.
type Sharing struct {
	Roles  map[string]string `json:"roles,omitempty"`
	People map[string]string `json:"people,omitempty"`
}

// kindDefaults mirrors docs/DESIGN.md §3.2 and shared/fixtures/access.json.
var kindDefaults = map[string]map[string]string{
	"calendar:family":       {RoleOwner: LevelEdit, RoleParent: LevelEdit, RoleCaregiver: LevelEdit, RoleRelative: LevelView, RoleKid: LevelView},
	"calendar:personal":     {RoleOwner: LevelView, RoleParent: LevelView, RoleCaregiver: LevelBusy, RoleRelative: LevelNone, RoleKid: LevelNone},
	"calendar:subscription": {RoleOwner: LevelView, RoleParent: LevelView, RoleCaregiver: LevelView, RoleRelative: LevelView, RoleKid: LevelView},
	"list:todo":             {RoleOwner: LevelEdit, RoleParent: LevelEdit, RoleCaregiver: LevelNone, RoleRelative: LevelNone, RoleKid: LevelNone},
	"list:grocery":          {RoleOwner: LevelEdit, RoleParent: LevelEdit, RoleCaregiver: LevelEdit, RoleRelative: LevelNone, RoleKid: LevelEdit},
	"list:packing":          {RoleOwner: LevelEdit, RoleParent: LevelEdit, RoleCaregiver: LevelEdit, RoleRelative: LevelNone, RoleKid: LevelView},
	"info:card":             {RoleOwner: LevelEdit, RoleParent: LevelEdit, RoleCaregiver: LevelView, RoleRelative: LevelView, RoleKid: LevelNone},
}

func validLevel(l string) bool { _, ok := levelRank[l]; return ok }

// EffectiveLevel implements shared/README.md §7.
func EffectiveLevel(resource, subkind, role, membershipID string, sharing Sharing, isOwner bool) string {
	if isOwner {
		return LevelEdit
	}
	level := ""
	if l, ok := sharing.People[membershipID]; ok && validLevel(l) {
		level = l
	} else if l, ok := sharing.Roles[role]; ok && validLevel(l) {
		level = l
	} else if d, ok := kindDefaults[resource+":"+subkind]; ok {
		level = d[role]
	}
	if level == "" {
		level = LevelNone
	}
	if level == LevelBusy && resource != "calendar" {
		level = LevelNone
	}
	return level
}

// resourceKind returns ("calendar"|"list"|"info", subkind) for a shareable record.
func resourceKind(r *core.Record) (string, string) {
	switch r.Collection().Name {
	case "calendars":
		return "calendar", r.GetString("kind")
	case "lists":
		return "list", r.GetString("kind")
	case "infoCards":
		return "info", "card"
	}
	return "", ""
}

func parseSharing(r *core.Record) Sharing {
	var s Sharing
	raw := r.GetString("sharing")
	if raw != "" && raw != "null" {
		_ = json.Unmarshal([]byte(raw), &s)
	}
	return s
}

func familyMemberships(app core.App, familyID string) ([]*core.Record, error) {
	return app.FindAllRecords("memberships", dbx.HashExp{"family": familyID})
}

// computeAccess fills viewers/editors(/busyViewers) on a shareable record from
// the family's current memberships. It does not save.
func computeAccess(app core.App, r *core.Record) error {
	resource, subkind := resourceKind(r)
	if resource == "" {
		return nil
	}
	members, err := familyMemberships(app, r.GetString("family"))
	if err != nil {
		return err
	}
	sharing := parseSharing(r)
	owner := r.GetString("owner")
	best := map[string]string{} // user id -> highest level
	for _, m := range members {
		uid := m.GetString("user")
		if uid == "" {
			continue
		}
		lvl := EffectiveLevel(resource, subkind, m.GetString("role"), m.Id, sharing, owner != "" && owner == m.Id)
		if levelRank[lvl] > levelRank[best[uid]] {
			best[uid] = lvl
		}
	}
	var viewers, editors, busy []string
	for uid, lvl := range best {
		switch lvl {
		case LevelEdit:
			editors = append(editors, uid)
			viewers = append(viewers, uid)
		case LevelView:
			viewers = append(viewers, uid)
		case LevelBusy:
			busy = append(busy, uid)
		}
	}
	sort.Strings(viewers)
	sort.Strings(editors)
	sort.Strings(busy)
	r.Set("viewers", viewers)
	r.Set("editors", editors)
	if resource == "calendar" {
		r.Set("busyViewers", busy)
	}
	return nil
}

func sameSet(a, b []string) bool {
	a = slices.Clone(a)
	b = slices.Clone(b)
	sort.Strings(a)
	sort.Strings(b)
	return slices.Equal(a, b)
}

// RecomputeFamily refreshes families.members/admins and the access fields of
// every shareable record in the family. Records are only saved when changed.
func RecomputeFamily(app core.App, familyID string) error {
	family, err := app.FindRecordById("families", familyID)
	if err != nil {
		return nil // family deleted (cascade) — nothing to do
	}
	members, err := familyMemberships(app, familyID)
	if err != nil {
		return err
	}
	var all, admins []string
	for _, m := range members {
		uid := m.GetString("user")
		if uid == "" || slices.Contains(all, uid) {
			continue
		}
		all = append(all, uid)
	}
	for _, m := range members {
		uid := m.GetString("user")
		role := m.GetString("role")
		if uid != "" && (role == RoleOwner || role == RoleParent) && !slices.Contains(admins, uid) {
			admins = append(admins, uid)
		}
	}
	if !sameSet(all, family.GetStringSlice("members")) || !sameSet(admins, family.GetStringSlice("admins")) {
		family.Set("members", all)
		family.Set("admins", admins)
		if err := app.Save(family); err != nil {
			return err
		}
	}
	for _, coll := range []string{"calendars", "lists", "infoCards"} {
		recs, err := app.FindAllRecords(coll, dbx.HashExp{"family": familyID})
		if err != nil {
			return err
		}
		for _, r := range recs {
			before := [][]string{r.GetStringSlice("viewers"), r.GetStringSlice("editors"), r.GetStringSlice("busyViewers")}
			if err := computeAccess(app, r); err != nil {
				return err
			}
			after := [][]string{r.GetStringSlice("viewers"), r.GetStringSlice("editors"), r.GetStringSlice("busyViewers")}
			changed := false
			for i := range before {
				if !sameSet(before[i], after[i]) {
					changed = true
				}
			}
			if changed {
				if err := app.Save(r); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

// membershipFor returns the caller's membership in a family (nil if none).
func membershipFor(app core.App, familyID, userID string) *core.Record {
	if familyID == "" || userID == "" {
		return nil
	}
	m, err := app.FindFirstRecordByFilter("memberships", "family = {:f} && user = {:u}", dbx.Params{"f": familyID, "u": userID})
	if err != nil {
		return nil
	}
	return m
}

func isAdminRole(role string) bool { return role == RoleOwner || role == RoleParent }
