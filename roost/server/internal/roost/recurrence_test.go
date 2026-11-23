package roost

import (
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

func parseLocal(s string) localDT {
	y, m, d := 0, 0, 0
	h, mi := 0, 0
	parts := strings.SplitN(s, "T", 2)
	ymd := strings.Split(parts[0], "-")
	y, m, d = atoi(ymd[0]), atoi(ymd[1]), atoi(ymd[2])
	if len(parts) == 2 {
		hm := strings.Split(parts[1], ":")
		h, mi = atoi(hm[0]), atoi(hm[1])
	}
	return localDT{localDate{y, m, d}, h, mi}
}

func atoi(s string) int {
	n := 0
	for _, c := range s {
		n = n*10 + int(c-'0')
	}
	return n
}

func TestRecurrenceFixtures(t *testing.T) {
	raw, err := os.ReadFile("../../../shared/fixtures/recurrence.json")
	if err != nil {
		t.Fatal(err)
	}
	var fx struct {
		Cases []struct {
			Name, TZ, Start, End, RangeStart, RangeEnd string
			AllDay                                     bool
			RRule                                      *string
			ExDates, Expected, ExpectedUTC             []string
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	for _, c := range fx.Cases {
		loc, _ := time.LoadLocation(c.TZ)
		start, end := parseLocal(c.Start), parseLocal(c.End)
		dur := int(end.in(loc).Sub(start.in(loc)).Minutes())
		if c.AllDay {
			dur = (end.date.dayNumber() - start.date.dayNumber()) * 1440
		}
		ex := map[string]bool{}
		for _, e := range c.ExDates {
			ex[e] = true
		}
		rule := ""
		if c.RRule != nil {
			rule = *c.RRule
		}
		occ := expandOccurrences(start, dur, c.AllDay, loc, rule, ex, parseLocal(c.RangeStart).in(loc), parseLocal(c.RangeEnd).in(loc))
		got := []string{}
		var utc []string
		for _, o := range occ {
			got = append(got, o.key(c.AllDay))
			utc = append(utc, o.in(loc).UTC().Format("2006-01-02T15:04:05Z"))
		}
		if !reflect.DeepEqual(got, c.Expected) && !(len(got) == 0 && len(c.Expected) == 0) {
			t.Errorf("%s:\n got  %v\n want %v", c.Name, got, c.Expected)
		}
		if c.ExpectedUTC != nil && !reflect.DeepEqual(utc, c.ExpectedUTC) {
			t.Errorf("%s utc:\n got  %v\n want %v", c.Name, utc, c.ExpectedUTC)
		}
	}
}

func TestLocalDateMath(t *testing.T) {
	if (localDate{1970, 1, 1}).dayNumber() != 0 || (localDate{1970, 1, 1}).weekday() != 4 {
		t.Fatal("epoch")
	}
	if (localDate{2026, 11, 23}).weekday() != 1 {
		t.Fatal("weekday")
	}
	if d := dateFromDayNumber((localDate{2028, 2, 29}).dayNumber()); d != (localDate{2028, 2, 29}) {
		t.Fatalf("roundtrip %v", d)
	}
}
