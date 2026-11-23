package roost

import (
	"bytes"
	"encoding/json"
	"html"
	"io/fs"
	"net/http"
	"os"
	"path"
	"strings"

	"github.com/pocketbase/pocketbase/core"
)

// registerWeb serves the built web app at the unlisted cfg.WebPath. The app is
// built with relative asset URLs; index.html gets a <base href> and runtime
// config injected so one build works at any path.
func registerWeb(se *core.ServeEvent, cfg Config) {
	noindex := func(e *core.RequestEvent) {
		e.Response.Header().Set("X-Robots-Tag", "noindex, nofollow, noarchive")
		e.Response.Header().Set("Referrer-Policy", "no-referrer")
	}
	// The root reveals nothing.
	se.Router.GET("/{$}", func(e *core.RequestEvent) error {
		noindex(e)
		return e.String(http.StatusNotFound, "")
	})
	if cfg.WebPath == "" || cfg.WebDir == "" {
		return
	}
	fsys := os.DirFS(cfg.WebDir)
	serveIndex := func(e *core.RequestEvent) error {
		raw, err := fs.ReadFile(fsys, "index.html")
		if err != nil {
			return e.NotFoundError("Web app not built.", nil)
		}
		conf, _ := json.Marshal(map[string]any{"apiUrl": "", "basePath": cfg.WebPath})
		inject := `<base href="` + html.EscapeString(cfg.WebPath) + `"><script>window.ROOST_CONFIG=` + string(conf) + `</script>`
		out := bytes.Replace(raw, []byte("<head>"), []byte("<head>"+inject), 1)
		noindex(e)
		e.Response.Header().Set("Cache-Control", "no-cache")
		return e.Blob(http.StatusOK, "text/html; charset=utf-8", out)
	}
	prefix := strings.TrimSuffix(cfg.WebPath, "/")
	se.Router.GET(prefix+"/{path...}", func(e *core.RequestEvent) error {
		p := path.Clean("/" + e.Request.PathValue("path"))[1:]
		if p == "" || p == "index.html" {
			return serveIndex(e)
		}
		if st, err := fs.Stat(fsys, p); err == nil && !st.IsDir() {
			noindex(e)
			if strings.HasPrefix(p, "assets/") {
				e.Response.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
			} else {
				e.Response.Header().Set("Cache-Control", "no-cache")
			}
			if p == "sw.js" {
				e.Response.Header().Set("Service-Worker-Allowed", cfg.WebPath)
			}
			http.ServeFileFS(e.Response, e.Request, fsys, p)
			return nil
		}
		// SPA fallback for client-side routes (but not for missing assets).
		if path.Ext(p) != "" {
			return e.NotFoundError("", nil)
		}
		return serveIndex(e)
	})
	se.Router.GET(prefix, func(e *core.RequestEvent) error {
		return e.Redirect(http.StatusMovedPermanently, cfg.WebPath)
	})
}
