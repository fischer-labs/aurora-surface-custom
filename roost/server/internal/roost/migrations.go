package roost

import (
	"github.com/pocketbase/pocketbase/core"
)

func init() {
	// One idempotent migration that brings the schema to the current version.
	// Future schema changes append new migrations that call EnsureSchema again.
	core.AppMigrations.Register(func(txApp core.App) error {
		return EnsureSchema(txApp)
	}, nil, "1732320000_roost_schema_v1.go")
}
