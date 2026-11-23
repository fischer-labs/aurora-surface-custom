package roost

import (
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

// Roles in the order of decreasing privilege.
const (
	RoleOwner     = "owner"
	RoleParent    = "parent"
	RoleCaregiver = "caregiver"
	RoleRelative  = "relative"
	RoleKid       = "kid"
)

var Roles = []string{RoleOwner, RoleParent, RoleCaregiver, RoleRelative, RoleKid}

// Access rules. Server-managed relation fields (viewers/editors/busyViewers on
// shareable records, members/admins on families) keep these short; see
// docs/DESIGN.md §3.3.
const (
	ruleAuthed      = `@request.auth.id != ""`
	ruleFamilyMember = `family.members.id ?= @request.auth.id`
	ruleFamilyAdmin  = `family.admins.id ?= @request.auth.id`
)

// noServerFields forbids clients from writing fields the server computes.
func noServerFields(fields ...string) string {
	s := ""
	for _, f := range fields {
		s += " && @request.body." + f + ":isset = false"
	}
	return s
}

func ptr(s string) *string { return types.Pointer(s) }

// EnsureSchema creates or updates every Roost collection. It is idempotent and
// runs as an app migration (see migrations.go) and in tests.
func EnsureSchema(app core.App) error {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}

	// ---- families --------------------------------------------------------
	families := getOrNew(app, "families")
	families.Fields.Add(
		&core.TextField{Name: "name", Required: true, Max: 80},
		&core.TextField{Name: "timezone", Max: 64},
		&core.NumberField{Name: "weekStart", OnlyInt: true, Min: types.Pointer(0.0), Max: types.Pointer(6.0)},
		&core.RelationField{Name: "owner", CollectionId: users.Id, MaxSelect: 1},
		&core.RelationField{Name: "members", CollectionId: users.Id, MaxSelect: 500},
		&core.RelationField{Name: "admins", CollectionId: users.Id, MaxSelect: 500},
		&core.JSONField{Name: "settings", MaxSize: 64 << 10},
	)
	addTimestamps(families)
	families.ListRule = ptr(`members.id ?= @request.auth.id`)
	families.ViewRule = families.ListRule
	families.CreateRule = ptr(ruleAuthed + noServerFields("members", "admins", "owner"))
	families.UpdateRule = ptr(`admins.id ?= @request.auth.id` + noServerFields("members", "admins", "owner"))
	families.DeleteRule = ptr(`owner = @request.auth.id`)
	if err := app.Save(families); err != nil {
		return err
	}

	// ---- memberships -----------------------------------------------------
	memberships := getOrNew(app, "memberships")
	memberships.Fields.Add(
		&core.RelationField{Name: "family", CollectionId: families.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.RelationField{Name: "user", CollectionId: users.Id, MaxSelect: 1},
		&core.TextField{Name: "name", Required: true, Max: 60},
		&core.SelectField{Name: "role", Values: Roles, MaxSelect: 1, Required: true},
		&core.TextField{Name: "color", Max: 20},
		&core.TextField{Name: "emoji", Max: 16},
		&core.DateField{Name: "birthday"},
		&core.BoolField{Name: "notifyAll"},
		&core.NumberField{Name: "sortOrder"},
	)
	addTimestamps(memberships)
	memberships.ListRule = ptr(ruleFamilyMember)
	memberships.ViewRule = ptr(ruleFamilyMember)
	memberships.CreateRule = ptr(ruleFamilyAdmin + noServerFields("user"))
	// Admins can edit anyone; people can edit their own color/emoji/notify prefs.
	memberships.UpdateRule = ptr(`((` + ruleFamilyAdmin + `)` + noServerFields("user", "family") + `) || (user = @request.auth.id` + noServerFields("role", "user", "family") + `)`)
	memberships.DeleteRule = ptr(ruleFamilyAdmin)
	memberships.AddIndex("idx_memberships_family_user", false, "family, user", "")
	if err := app.Save(memberships); err != nil {
		return err
	}

	sharingFields := func(c *core.Collection) {
		c.Fields.Add(
			&core.RelationField{Name: "owner", CollectionId: memberships.Id, MaxSelect: 1},
			&core.JSONField{Name: "sharing", MaxSize: 32 << 10},
			&core.RelationField{Name: "viewers", CollectionId: users.Id, MaxSelect: 500},
			&core.RelationField{Name: "editors", CollectionId: users.Id, MaxSelect: 500},
			&core.NumberField{Name: "sortOrder"},
			&core.BoolField{Name: "deleted"},
		)
	}

	// ---- calendars -------------------------------------------------------
	calendars := getOrNew(app, "calendars")
	calendars.Fields.Add(
		&core.RelationField{Name: "family", CollectionId: families.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.TextField{Name: "name", Required: true, Max: 80},
		&core.TextField{Name: "color", Max: 20},
		&core.SelectField{Name: "kind", Values: []string{"family", "personal", "subscription"}, MaxSelect: 1, Required: true},
		&core.JSONField{Name: "defaultReminders", MaxSize: 4 << 10},
		&core.TextField{Name: "sourceUrl", Max: 2000},
		&core.DateField{Name: "lastSyncedAt"},
		&core.TextField{Name: "syncError", Max: 500},
		&core.RelationField{Name: "busyViewers", CollectionId: users.Id, MaxSelect: 500},
	)
	sharingFields(calendars)
	addTimestamps(calendars)
	calendars.ListRule = ptr(`viewers.id ?= @request.auth.id || busyViewers.id ?= @request.auth.id`)
	calendars.ViewRule = calendars.ListRule
	calendars.CreateRule = ptr(ruleFamilyMember + noServerFields("viewers", "editors", "busyViewers", "lastSyncedAt", "syncError"))
	calendars.UpdateRule = ptr(`(` + ruleFamilyAdmin + ` || owner.user ?= @request.auth.id)` + noServerFields("viewers", "editors", "busyViewers", "family", "lastSyncedAt", "syncError"))
	calendars.DeleteRule = ptr(ruleFamilyAdmin + ` || owner.user ?= @request.auth.id`)
	calendars.AddIndex("idx_calendars_family_updated", false, "family, updated", "")
	if err := app.Save(calendars); err != nil {
		return err
	}

	// ---- events ----------------------------------------------------------
	events := getOrNew(app, "events")
	events.Fields.Add(
		&core.RelationField{Name: "family", CollectionId: families.Id, MaxSelect: 1, CascadeDelete: true},
		&core.RelationField{Name: "calendar", CollectionId: calendars.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.TextField{Name: "title", Required: true, Max: 200},
		&core.TextField{Name: "notes", Max: 10000},
		&core.TextField{Name: "location", Max: 300},
		&core.TextField{Name: "url", Max: 1000},
		&core.DateField{Name: "start", Required: true},
		&core.DateField{Name: "end", Required: true},
		&core.BoolField{Name: "allDay"},
		&core.TextField{Name: "tz", Max: 64},
		&core.TextField{Name: "rrule", Max: 500},
		&core.JSONField{Name: "exdates", MaxSize: 32 << 10},
		&core.RelationField{Name: "members", CollectionId: memberships.Id, MaxSelect: 50},
		&core.RelationField{Name: "driver", CollectionId: memberships.Id, MaxSelect: 1},
		&core.TextField{Name: "category", Max: 30},
		&core.JSONField{Name: "reminders", MaxSize: 4 << 10},
		&core.BoolField{Name: "private"},
		&core.TextField{Name: "color", Max: 20},
		&core.SelectField{Name: "source", Values: []string{"roost", "ics"}, MaxSelect: 1},
		&core.TextField{Name: "externalUid", Max: 500},
		&core.RelationField{Name: "createdBy", CollectionId: users.Id, MaxSelect: 1},
		&core.RelationField{Name: "updatedBy", CollectionId: users.Id, MaxSelect: 1},
		&core.BoolField{Name: "deleted"},
	)
	addTimestamps(events)
	// recurrenceParent is self-referencing so it needs the collection id first.
	if events.IsNew() {
		if err := app.Save(events); err != nil {
			return err
		}
	}
	events.Fields.Add(&core.RelationField{Name: "recurrenceParent", CollectionId: events.Id, MaxSelect: 1})
	eventsView := `calendar.viewers.id ?= @request.auth.id && (private = false || calendar.editors.id ?= @request.auth.id || createdBy = @request.auth.id)`
	events.ListRule = ptr(eventsView)
	events.ViewRule = ptr(eventsView)
	events.CreateRule = ptr(`calendar.editors.id ?= @request.auth.id && source != "ics"` + noServerFields("family", "externalUid"))
	events.UpdateRule = ptr(`calendar.editors.id ?= @request.auth.id && source != "ics"` + noServerFields("family", "source", "externalUid", "createdBy"))
	events.DeleteRule = ptr(`calendar.editors.id ?= @request.auth.id && source != "ics"`)
	events.AddIndex("idx_events_family_updated", false, "family, updated", "")
	events.AddIndex("idx_events_calendar_start", false, "calendar, start", "")
	events.AddIndex("idx_events_calendar_uid", false, "calendar, externalUid", "")
	if err := app.Save(events); err != nil {
		return err
	}

	// ---- lists -----------------------------------------------------------
	lists := getOrNew(app, "lists")
	lists.Fields.Add(
		&core.RelationField{Name: "family", CollectionId: families.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.TextField{Name: "name", Required: true, Max: 80},
		&core.SelectField{Name: "kind", Values: []string{"todo", "grocery", "packing"}, MaxSelect: 1, Required: true},
		&core.TextField{Name: "icon", Max: 40},
		&core.TextField{Name: "color", Max: 20},
		&core.JSONField{Name: "storeOrder", MaxSize: 4 << 10},
		&core.BoolField{Name: "archived"},
	)
	sharingFields(lists)
	addTimestamps(lists)
	lists.ListRule = ptr(`viewers.id ?= @request.auth.id`)
	lists.ViewRule = lists.ListRule
	lists.CreateRule = ptr(ruleFamilyMember + noServerFields("viewers", "editors"))
	lists.UpdateRule = ptr(`(` + ruleFamilyAdmin + ` || owner.user ?= @request.auth.id || editors.id ?= @request.auth.id)` + noServerFields("viewers", "editors", "family"))
	lists.DeleteRule = ptr(ruleFamilyAdmin + ` || owner.user ?= @request.auth.id`)
	lists.AddIndex("idx_lists_family_updated", false, "family, updated", "")
	if err := app.Save(lists); err != nil {
		return err
	}

	// ---- tasks -----------------------------------------------------------
	tasks := getOrNew(app, "tasks")
	tasks.Fields.Add(
		&core.RelationField{Name: "family", CollectionId: families.Id, MaxSelect: 1, CascadeDelete: true},
		&core.RelationField{Name: "list", CollectionId: lists.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.TextField{Name: "title", Required: true, Max: 300},
		&core.TextField{Name: "notes", Max: 10000},
		&core.TextField{Name: "due", Max: 16}, // local "YYYY-MM-DD" or "YYYY-MM-DDTHH:mm" in the family timezone
		&core.RelationField{Name: "assignees", CollectionId: memberships.Id, MaxSelect: 50},
		&core.NumberField{Name: "priority", OnlyInt: true, Min: types.Pointer(0.0), Max: types.Pointer(3.0)},
		&core.TextField{Name: "rrule", Max: 500},
		&core.BoolField{Name: "completed"},
		&core.DateField{Name: "completedAt"},
		&core.RelationField{Name: "completedBy", CollectionId: users.Id, MaxSelect: 1},
		&core.JSONField{Name: "reminders", MaxSize: 4 << 10},
		&core.JSONField{Name: "tags", MaxSize: 4 << 10},
		&core.NumberField{Name: "sortOrder"},
		&core.RelationField{Name: "createdBy", CollectionId: users.Id, MaxSelect: 1},
		&core.BoolField{Name: "deleted"},
	)
	addTimestamps(tasks)
	if tasks.IsNew() {
		if err := app.Save(tasks); err != nil {
			return err
		}
	}
	tasks.Fields.Add(&core.RelationField{Name: "parent", CollectionId: tasks.Id, MaxSelect: 1, CascadeDelete: true})
	tasks.ListRule = ptr(`list.viewers.id ?= @request.auth.id || assignees.user ?= @request.auth.id`)
	tasks.ViewRule = tasks.ListRule
	tasks.CreateRule = ptr(`list.editors.id ?= @request.auth.id` + noServerFields("family"))
	tasks.UpdateRule = ptr(`(list.editors.id ?= @request.auth.id || assignees.user ?= @request.auth.id)` + noServerFields("family", "createdBy"))
	tasks.DeleteRule = ptr(`list.editors.id ?= @request.auth.id`)
	tasks.AddIndex("idx_tasks_family_updated", false, "family, updated", "")
	tasks.AddIndex("idx_tasks_list", false, "list", "")
	if err := app.Save(tasks); err != nil {
		return err
	}

	// ---- groceryItems ----------------------------------------------------
	grocery := getOrNew(app, "groceryItems")
	grocery.Fields.Add(
		&core.RelationField{Name: "family", CollectionId: families.Id, MaxSelect: 1, CascadeDelete: true},
		&core.RelationField{Name: "list", CollectionId: lists.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.TextField{Name: "name", Required: true, Max: 200},
		&core.NumberField{Name: "quantity"},
		&core.TextField{Name: "unit", Max: 20},
		&core.TextField{Name: "note", Max: 500},
		&core.TextField{Name: "category", Max: 30},
		&core.SelectField{Name: "categorySource", Values: []string{"dictionary", "learned", "ai", "manual", "none"}, MaxSelect: 1},
		&core.BoolField{Name: "checked"},
		&core.DateField{Name: "checkedAt"},
		&core.RelationField{Name: "checkedBy", CollectionId: users.Id, MaxSelect: 1},
		&core.RelationField{Name: "addedBy", CollectionId: users.Id, MaxSelect: 1},
		&core.NumberField{Name: "sortOrder"},
		&core.BoolField{Name: "deleted"},
	)
	addTimestamps(grocery)
	grocery.ListRule = ptr(`list.viewers.id ?= @request.auth.id`)
	grocery.ViewRule = grocery.ListRule
	grocery.CreateRule = ptr(`list.editors.id ?= @request.auth.id` + noServerFields("family"))
	grocery.UpdateRule = ptr(`list.editors.id ?= @request.auth.id` + noServerFields("family"))
	grocery.DeleteRule = ptr(`list.editors.id ?= @request.auth.id`)
	grocery.AddIndex("idx_grocery_family_updated", false, "family, updated", "")
	if err := app.Save(grocery); err != nil {
		return err
	}

	// ---- groceryLearned --------------------------------------------------
	learned := getOrNew(app, "groceryLearned")
	learned.Fields.Add(
		&core.RelationField{Name: "family", CollectionId: families.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.TextField{Name: "term", Required: true, Max: 200},
		&core.TextField{Name: "category", Required: true, Max: 30},
	)
	addTimestamps(learned)
	learned.ListRule = ptr(ruleFamilyMember)
	learned.ViewRule = ptr(ruleFamilyMember)
	learned.CreateRule = ptr(ruleFamilyMember)
	learned.UpdateRule = ptr(ruleFamilyMember + noServerFields("family"))
	learned.DeleteRule = ptr(ruleFamilyMember)
	learned.AddIndex("idx_learned_family_term", true, "family, term", "")
	if err := app.Save(learned); err != nil {
		return err
	}

	// ---- infoCards -------------------------------------------------------
	info := getOrNew(app, "infoCards")
	info.Fields.Add(
		&core.RelationField{Name: "family", CollectionId: families.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.TextField{Name: "title", Required: true, Max: 120},
		&core.TextField{Name: "body", Max: 20000},
		&core.SelectField{Name: "kind", Values: []string{"contact", "medical", "school", "routine", "home", "note"}, MaxSelect: 1},
		&core.TextField{Name: "icon", Max: 40},
		&core.TextField{Name: "phone", Max: 40},
		&core.TextField{Name: "address", Max: 300},
		&core.RelationField{Name: "aboutMember", CollectionId: memberships.Id, MaxSelect: 1},
		&core.BoolField{Name: "pinned"},
	)
	sharingFields(info)
	addTimestamps(info)
	info.ListRule = ptr(`viewers.id ?= @request.auth.id`)
	info.ViewRule = info.ListRule
	info.CreateRule = ptr(ruleFamilyAdmin + noServerFields("viewers", "editors"))
	info.UpdateRule = ptr(`(` + ruleFamilyAdmin + ` || editors.id ?= @request.auth.id)` + noServerFields("viewers", "editors", "family"))
	info.DeleteRule = ptr(ruleFamilyAdmin)
	info.AddIndex("idx_info_family_updated", false, "family, updated", "")
	if err := app.Save(info); err != nil {
		return err
	}

	// ---- invites ---------------------------------------------------------
	invites := getOrNew(app, "invites")
	invites.Fields.Add(
		&core.RelationField{Name: "family", CollectionId: families.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.TextField{Name: "code", Max: 20},
		&core.SelectField{Name: "role", Values: Roles, MaxSelect: 1, Required: true},
		&core.TextField{Name: "name", Max: 60},
		&core.TextField{Name: "color", Max: 20},
		&core.RelationField{Name: "membership", CollectionId: memberships.Id, MaxSelect: 1},
		&core.DateField{Name: "expiresAt"},
		&core.RelationField{Name: "createdBy", CollectionId: users.Id, MaxSelect: 1},
		&core.RelationField{Name: "usedBy", CollectionId: users.Id, MaxSelect: 1},
		&core.DateField{Name: "usedAt"},
	)
	addTimestamps(invites)
	invites.ListRule = ptr(ruleFamilyAdmin)
	invites.ViewRule = ptr(ruleFamilyAdmin)
	invites.CreateRule = ptr(ruleFamilyAdmin + noServerFields("code", "usedBy", "usedAt", "createdBy"))
	invites.UpdateRule = nil
	invites.DeleteRule = ptr(ruleFamilyAdmin)
	invites.AddIndex("idx_invites_code", true, "code", "")
	if err := app.Save(invites); err != nil {
		return err
	}

	// ---- feeds (ICS export tokens) ---------------------------------------
	feeds := getOrNew(app, "feeds")
	feeds.Fields.Add(
		&core.RelationField{Name: "family", CollectionId: families.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.RelationField{Name: "user", CollectionId: users.Id, MaxSelect: 1, Required: true, CascadeDelete: true},
		&core.TextField{Name: "token", Max: 80},
		&core.TextField{Name: "name", Max: 80},
		&core.JSONField{Name: "calendars", MaxSize: 8 << 10},
		&core.BoolField{Name: "includeBusy"},
	)
	addTimestamps(feeds)
	feeds.ListRule = ptr(`user = @request.auth.id`)
	feeds.ViewRule = feeds.ListRule
	feeds.CreateRule = ptr(`user = @request.auth.id && ` + ruleFamilyMember + noServerFields("token"))
	feeds.UpdateRule = ptr(`user = @request.auth.id` + noServerFields("token", "user", "family"))
	feeds.DeleteRule = ptr(`user = @request.auth.id`)
	feeds.AddIndex("idx_feeds_token", true, "token", "")
	if err := app.Save(feeds); err != nil {
		return err
	}

	// ---- users: rules reference memberships, so they come last -----------
	// Sign-up is gated by the hook in hooks.go (first user or valid invite code).
	users.CreateRule = ptr("")
	users.ListRule = ptr(`id = @request.auth.id || (@collection.memberships:m.user ?= id && @collection.memberships:m.family.members.id ?= @request.auth.id)`)
	users.ViewRule = users.ListRule
	return app.Save(users)
}

func getOrNew(app core.App, name string) *core.Collection {
	c, err := app.FindCollectionByNameOrId(name)
	if err != nil || c == nil {
		return core.NewBaseCollection(name)
	}
	return c
}

func addTimestamps(c *core.Collection) {
	c.Fields.Add(
		&core.AutodateField{Name: "created", OnCreate: true},
		&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true},
	)
}
