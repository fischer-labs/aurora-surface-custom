// roost-server: PocketBase + Roost family organizer in one binary.
//
//	ROOST_WEB_PATH=/h/k7q2m9x4/ ./roost-server serve --http 0.0.0.0:8090
//
// See docs/DEPLOY.md for configuration.
package main

import (
	"log"
	_ "time/tzdata" // embed zone data so ICS TZIDs resolve on minimal images

	"github.com/pocketbase/pocketbase"

	"roost/server/internal/roost"
)

func main() {
	app := pocketbase.New()
	roost.Register(app, roost.ConfigFromEnv())
	if err := app.Start(); err != nil {
		log.Fatal(err)
	}
}
