package roost

import (
	"bytes"
	"encoding/json"
	"os"
	"testing"
)

func TestEmbeddedTaxonomyMatchesShared(t *testing.T) {
	shared, err := os.ReadFile("../../../shared/grocery/taxonomy.json")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(shared, taxonomyJSON) {
		t.Fatal("server/internal/roost/taxonomy.json is stale: cp shared/grocery/taxonomy.json server/internal/roost/")
	}
}

func TestCategorizeFixtures(t *testing.T) {
	raw, err := os.ReadFile("../../../shared/fixtures/grocery.json")
	if err != nil {
		t.Fatal(err)
	}
	var fx struct {
		Categorize []struct{ Input, Category, Source string } `json:"categorize"`
		Learned    []struct {
			Learned                 map[string]string
			Input, Category, Source string
		} `json:"learned"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	for _, c := range fx.Categorize {
		cat, src := categorizeGrocery(c.Input, nil)
		if cat != c.Category || src != c.Source {
			t.Errorf("%q: got %s/%s want %s/%s", c.Input, cat, src, c.Category, c.Source)
		}
	}
	for _, c := range fx.Learned {
		cat, src := categorizeGrocery(c.Input, c.Learned)
		if cat != c.Category || src != c.Source {
			t.Errorf("learned %q: got %s/%s want %s/%s", c.Input, cat, src, c.Category, c.Source)
		}
	}
}
