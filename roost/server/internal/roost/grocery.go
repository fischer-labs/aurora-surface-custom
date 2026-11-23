package roost

import (
	_ "embed"
	"encoding/json"
	"regexp"
	"sort"
	"strings"
	"unicode"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"golang.org/x/text/unicode/norm"
)

// Server-side port of the grocery categorizer (shared/README.md §1, §3) so
// items created without a category (raw API, scripts, agents) still land in
// the right aisle. Verified against shared/fixtures/grocery.json.

//go:embed taxonomy.json
var taxonomyJSON []byte

type groceryTaxonomy struct {
	index     map[string]string
	modifiers map[string]string
}

var taxonomy = func() groceryTaxonomy {
	var raw struct {
		Modifiers map[string]string   `json:"modifiers"`
		Terms     map[string][]string `json:"terms"`
	}
	if err := json.Unmarshal(taxonomyJSON, &raw); err != nil {
		panic("roost: bad taxonomy.json: " + err.Error())
	}
	t := groceryTaxonomy{index: map[string]string{}, modifiers: raw.Modifiers}
	for cat, terms := range raw.Terms {
		for _, term := range terms {
			t.index[normalizeText(term)] = cat
		}
	}
	return t
}()

var nonWord = regexp.MustCompile(`[^a-z0-9%]+`)

func normalizeText(s string) string {
	var b strings.Builder
	for _, r := range norm.NFD.String(strings.ToLower(s)) {
		if !unicode.Is(unicode.Mn, r) {
			b.WriteRune(r)
		}
	}
	t := strings.NewReplacer("&", " and ", "'", "", "’", "").Replace(b.String())
	return strings.TrimSpace(nonWord.ReplaceAllString(t, " "))
}

func singularVariants(w string) []string {
	var v []string
	add := func(x string) {
		if x != w && x != "" {
			for _, y := range v {
				if y == x {
					return
				}
			}
			v = append(v, x)
		}
	}
	if strings.HasSuffix(w, "ies") && len(w) > 4 {
		add(w[:len(w)-3] + "y")
	}
	if strings.HasSuffix(w, "oes") {
		add(w[:len(w)-2])
	}
	if strings.HasSuffix(w, "ves") {
		add(w[:len(w)-3] + "f")
		add(w[:len(w)-3] + "fe")
	}
	for _, suf := range []string{"ses", "xes", "zes", "ches", "shes"} {
		if strings.HasSuffix(w, suf) {
			add(w[:len(w)-2])
			break
		}
	}
	if strings.HasSuffix(w, "s") && !strings.HasSuffix(w, "ss") && !strings.HasSuffix(w, "us") && !strings.HasSuffix(w, "is") {
		add(w[:len(w)-1])
	}
	return v
}

var overridable = map[string]bool{"produce": true, "meat": true, "bakery": true, "dairy": true}

// categorizeGrocery returns (category, source) with source learned|dictionary|none.
func categorizeGrocery(name string, learned map[string]string) (string, string) {
	n := normalizeText(name)
	if n == "" {
		return "other", "none"
	}
	toks := strings.Split(n, " ")
	if c, ok := learned[n]; ok {
		return c, "learned"
	}
	last := toks[len(toks)-1]
	for _, v := range singularVariants(last) {
		if c, ok := learned[strings.Join(append(append([]string{}, toks[:len(toks)-1]...), v), " ")]; ok {
			return c, "learned"
		}
	}
	type hit struct {
		length, end int
		exact       bool
		cat         string
	}
	var best *hit
	maxLen := len(toks)
	if maxLen > 4 {
		maxLen = 4
	}
	for length := maxLen; length >= 1; length-- {
		for start := 0; start+length <= len(toks); start++ {
			gram := toks[start : start+length]
			var h *hit
			if c, ok := taxonomy.index[strings.Join(gram, " ")]; ok {
				h = &hit{length, start + length - 1, true, c}
			} else {
				for _, v := range singularVariants(gram[len(gram)-1]) {
					alt := strings.Join(append(append([]string{}, gram[:len(gram)-1]...), v), " ")
					if c, ok := taxonomy.index[alt]; ok {
						h = &hit{length, start + length - 1, false, c}
						break
					}
				}
			}
			if h == nil {
				continue
			}
			if best != nil {
				if h.length < best.length || (h.length == best.length && h.end < best.end) ||
					(h.length == best.length && h.end == best.end && (!h.exact || best.exact)) {
					continue
				}
			}
			best = h
		}
	}
	modifier := ""
	for _, t := range toks {
		if m, ok := taxonomy.modifiers[t]; ok {
			modifier = m
			break
		}
	}
	if best != nil {
		if modifier != "" && overridable[best.cat] {
			return modifier, "dictionary"
		}
		return best.cat, "dictionary"
	}
	if modifier != "" {
		return modifier, "dictionary"
	}
	return "other", "none"
}

func learnedTerms(app core.App, familyID string) map[string]string {
	out := map[string]string{}
	recs, err := app.FindAllRecords("groceryLearned", dbx.HashExp{"family": familyID})
	if err != nil {
		return out
	}
	sort.Slice(recs, func(i, j int) bool { return recs[i].GetString("updated") < recs[j].GetString("updated") })
	for _, r := range recs {
		out[r.GetString("term")] = r.GetString("category")
	}
	return out
}
