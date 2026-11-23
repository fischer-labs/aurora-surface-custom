package roost

import (
	"bufio"
	"io"
	"strings"
	"time"
)

// ---------------------------------------------------------------------------
// Writer (RFC 5545) — used by the per-person feed.
// ---------------------------------------------------------------------------

// ICSEvent is the minimal shape the writer needs.
type ICSEvent struct {
	UID, Summary, Description, Location, URL string
	Start, End                               time.Time // instants
	AllDay                                   bool
	TZ                                       string   // IANA zone for recurring timed events
	RRule                                    string   // without "RRULE:"
	ExDates                                  []string // occurrence keys (DESIGN §4)
	Categories                               []string
	Updated                                  time.Time
	Busy                                     bool
}

func icsEscape(s string) string {
	r := strings.NewReplacer(`\`, `\\`, ";", `\;`, ",", `\,`, "\r\n", `\n`, "\n", `\n`)
	return r.Replace(s)
}

// foldLine folds at 75 octets without splitting UTF-8 sequences.
func foldLine(w *strings.Builder, line string) {
	const max = 75
	b := []byte(line)
	first := true
	for len(b) > 0 {
		limit := max
		if !first {
			limit = max - 1
		}
		if len(b) <= limit {
			if !first {
				w.WriteString(" ")
			}
			w.Write(b)
			w.WriteString("\r\n")
			return
		}
		cut := limit
		for cut > 0 && (b[cut]&0xC0) == 0x80 {
			cut--
		}
		if !first {
			w.WriteString(" ")
		}
		w.Write(b[:cut])
		w.WriteString("\r\n")
		b = b[cut:]
		first = false
	}
}

func WriteICS(calName, tz string, events []ICSEvent, now time.Time) string {
	var w strings.Builder
	p := func(s string) { foldLine(&w, s) }
	p("BEGIN:VCALENDAR")
	p("VERSION:2.0")
	p("PRODID:-//Roost//Family Organizer//EN")
	p("CALSCALE:GREGORIAN")
	p("METHOD:PUBLISH")
	p("X-WR-CALNAME:" + icsEscape(calName))
	if tz != "" {
		p("X-WR-TIMEZONE:" + tz)
	}
	p("REFRESH-INTERVAL;VALUE=DURATION:PT1H")
	p("X-PUBLISHED-TTL:PT1H")
	stamp := now.UTC().Format("20060102T150405Z")
	for _, ev := range events {
		p("BEGIN:VEVENT")
		p("UID:" + ev.UID)
		p("DTSTAMP:" + stamp)
		if !ev.Updated.IsZero() {
			p("LAST-MODIFIED:" + ev.Updated.UTC().Format("20060102T150405Z"))
		}
		loc := loadLoc(ev.TZ)
		switch {
		case ev.AllDay:
			p("DTSTART;VALUE=DATE:" + ev.Start.In(loc).Format("20060102"))
			end := ev.End
			if !end.After(ev.Start) {
				end = ev.Start.Add(24 * time.Hour)
			}
			p("DTEND;VALUE=DATE:" + end.In(loc).Format("20060102"))
		case ev.RRule != "" && ev.TZ != "":
			// Wall-clock recurrence so 4 pm stays 4 pm across DST.
			p("DTSTART;TZID=" + ev.TZ + ":" + ev.Start.In(loc).Format("20060102T150405"))
			p("DTEND;TZID=" + ev.TZ + ":" + ev.End.In(loc).Format("20060102T150405"))
		default:
			p("DTSTART:" + ev.Start.UTC().Format("20060102T150405Z"))
			p("DTEND:" + ev.End.UTC().Format("20060102T150405Z"))
		}
		if ev.RRule != "" {
			p("RRULE:" + ev.RRule)
			for _, key := range ev.ExDates {
				if v, ok := exdateValue(key, ev.AllDay, ev.TZ); ok {
					p(v)
				}
			}
		}
		if ev.Busy {
			p("SUMMARY:Busy")
			p("TRANSP:OPAQUE")
			p("CLASS:PRIVATE")
		} else {
			p("SUMMARY:" + icsEscape(ev.Summary))
			if ev.Description != "" {
				p("DESCRIPTION:" + icsEscape(ev.Description))
			}
			if ev.Location != "" {
				p("LOCATION:" + icsEscape(ev.Location))
			}
			if ev.URL != "" {
				p("URL:" + ev.URL)
			}
			if len(ev.Categories) > 0 {
				cs := make([]string, len(ev.Categories))
				for i, c := range ev.Categories {
					cs[i] = icsEscape(c)
				}
				p("CATEGORIES:" + strings.Join(cs, ","))
			}
		}
		p("END:VEVENT")
	}
	p("END:VCALENDAR")
	return w.String()
}

func exdateValue(key string, allDay bool, tz string) (string, bool) {
	if allDay || len(key) == 10 {
		t, err := time.Parse("2006-01-02", key[:10])
		if err != nil {
			return "", false
		}
		return "EXDATE;VALUE=DATE:" + t.Format("20060102"), true
	}
	loc := loadLoc(tz)
	t, err := time.ParseInLocation("2006-01-02T15:04", key, loc)
	if err != nil {
		return "", false
	}
	if tz != "" {
		return "EXDATE;TZID=" + tz + ":" + t.Format("20060102T150405"), true
	}
	return "EXDATE:" + t.UTC().Format("20060102T150405Z"), true
}

func loadLoc(tz string) *time.Location {
	if tz == "" {
		return time.UTC
	}
	if l, err := time.LoadLocation(tz); err == nil {
		return l
	}
	if iana, ok := windowsZones[tz]; ok {
		if l, err := time.LoadLocation(iana); err == nil {
			return l
		}
	}
	return time.UTC
}

// ---------------------------------------------------------------------------
// Parser — enough of RFC 5545 for school/sports/Google/Outlook feeds.
// ---------------------------------------------------------------------------

type icsProp struct {
	Name   string
	Params map[string]string
	Value  string
}

// ParsedEvent is a VEVENT normalized to Roost's model.
type ParsedEvent struct {
	UID          string
	RecurrenceID string // occurrence key of the overridden instance ("" for masters)
	Summary      string
	Description  string
	Location     string
	URL          string
	Start, End   time.Time
	AllDay       bool
	TZ           string
	RRule        string
	ExDates      []string
	Cancelled    bool
}

func unfold(r io.Reader) ([]string, error) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	var lines []string
	for sc.Scan() {
		l := strings.TrimRight(sc.Text(), "\r")
		if (strings.HasPrefix(l, " ") || strings.HasPrefix(l, "\t")) && len(lines) > 0 {
			lines[len(lines)-1] += l[1:]
			continue
		}
		if l != "" {
			lines = append(lines, l)
		}
	}
	return lines, sc.Err()
}

func parseProp(line string) icsProp {
	// NAME;PARAM=VAL;PARAM="V:AL":VALUE — the first ':' outside quotes splits.
	inQ := false
	split := -1
	for i, c := range line {
		if c == '"' {
			inQ = !inQ
		} else if c == ':' && !inQ {
			split = i
			break
		}
	}
	if split < 0 {
		return icsProp{Name: strings.ToUpper(line)}
	}
	head, val := line[:split], line[split+1:]
	parts := strings.Split(head, ";")
	p := icsProp{Name: strings.ToUpper(parts[0]), Params: map[string]string{}, Value: val}
	for _, kv := range parts[1:] {
		if k, v, ok := strings.Cut(kv, "="); ok {
			p.Params[strings.ToUpper(k)] = strings.Trim(v, `"`)
		}
	}
	return p
}

func icsUnescape(s string) string {
	r := strings.NewReplacer(`\n`, "\n", `\N`, "\n", `\,`, ",", `\;`, ";", `\\`, `\`)
	return r.Replace(s)
}

// parseICSTime returns the instant, whether it was a DATE, and the zone name used.
func parseICSTime(p icsProp, fallbackTZ string) (time.Time, bool, string, error) {
	v := strings.TrimSpace(p.Value)
	if p.Params["VALUE"] == "DATE" || (len(v) == 8 && !strings.Contains(v, "T")) {
		loc := loadLoc(fallbackTZ)
		t, err := time.ParseInLocation("20060102", v[:min(8, len(v))], loc)
		return t, true, fallbackTZ, err
	}
	if strings.HasSuffix(v, "Z") {
		t, err := time.Parse("20060102T150405Z", v)
		return t, false, "", err
	}
	tz := p.Params["TZID"]
	zoneName := tz
	if _, err := time.LoadLocation(tz); tz == "" || err != nil {
		if iana, ok := windowsZones[tz]; ok {
			zoneName = iana
		} else {
			zoneName = fallbackTZ
		}
	}
	loc := loadLoc(zoneName)
	t, err := time.ParseInLocation("20060102T150405", v, loc)
	if err != nil {
		t, err = time.ParseInLocation("20060102T1504", v, loc)
	}
	return t, false, zoneName, err
}

func occurrenceKey(t time.Time, allDay bool, tz string) string {
	t = t.In(loadLoc(tz))
	if allDay {
		return t.Format("2006-01-02")
	}
	return t.Format("2006-01-02T15:04")
}

func parseDuration(s string) time.Duration {
	// P[n]W | P[n]DT[n]H[n]M[n]S  (sign optional)
	neg := strings.HasPrefix(s, "-")
	s = strings.TrimLeft(s, "+-")
	s = strings.TrimPrefix(s, "P")
	var d time.Duration
	num := 0
	inTime := false
	for _, c := range s {
		switch {
		case c >= '0' && c <= '9':
			num = num*10 + int(c-'0')
		case c == 'T':
			inTime = true
		case c == 'W':
			d += time.Duration(num) * 7 * 24 * time.Hour
			num = 0
		case c == 'D':
			d += time.Duration(num) * 24 * time.Hour
			num = 0
		case c == 'H' && inTime:
			d += time.Duration(num) * time.Hour
			num = 0
		case c == 'M' && inTime:
			d += time.Duration(num) * time.Minute
			num = 0
		case c == 'S' && inTime:
			d += time.Duration(num) * time.Second
			num = 0
		}
	}
	if neg {
		d = -d
	}
	return d
}

// ParseICS extracts VEVENTs. fallbackTZ is used for floating times and DATEs.
func ParseICS(r io.Reader, fallbackTZ string) ([]ParsedEvent, error) {
	lines, err := unfold(r)
	if err != nil {
		return nil, err
	}
	var out []ParsedEvent
	var cur *ParsedEvent
	var durStr string
	depth := 0 // nested components inside VEVENT (VALARM)
	for _, l := range lines {
		p := parseProp(l)
		switch {
		case p.Name == "BEGIN" && strings.EqualFold(p.Value, "VEVENT"):
			cur = &ParsedEvent{}
			durStr = ""
			depth = 0
			continue
		case cur != nil && p.Name == "BEGIN":
			depth++
			continue
		case cur != nil && p.Name == "END" && !strings.EqualFold(p.Value, "VEVENT"):
			depth--
			continue
		case cur != nil && p.Name == "END" && strings.EqualFold(p.Value, "VEVENT"):
			if !cur.Start.IsZero() {
				if cur.End.IsZero() {
					switch {
					case durStr != "":
						cur.End = cur.Start.Add(parseDuration(durStr))
					case cur.AllDay:
						cur.End = cur.Start.AddDate(0, 0, 1)
					default:
						cur.End = cur.Start
					}
				}
				if cur.TZ == "" {
					cur.TZ = fallbackTZ
				}
				out = append(out, *cur)
			}
			cur = nil
			continue
		}
		if cur == nil || depth > 0 {
			continue
		}
		switch p.Name {
		case "UID":
			cur.UID = strings.TrimSpace(p.Value)
		case "SUMMARY":
			cur.Summary = icsUnescape(p.Value)
		case "DESCRIPTION":
			cur.Description = icsUnescape(p.Value)
		case "LOCATION":
			cur.Location = icsUnescape(p.Value)
		case "URL":
			cur.URL = strings.TrimSpace(p.Value)
		case "STATUS":
			cur.Cancelled = strings.EqualFold(strings.TrimSpace(p.Value), "CANCELLED")
		case "DTSTART":
			t, allDay, tz, err := parseICSTime(p, fallbackTZ)
			if err == nil {
				cur.Start, cur.AllDay, cur.TZ = t, allDay, tz
			}
		case "DTEND":
			if t, _, _, err := parseICSTime(p, fallbackTZ); err == nil {
				cur.End = t
			}
		case "DURATION":
			durStr = strings.TrimSpace(p.Value)
		case "RRULE":
			cur.RRule = normalizeRRuleUntil(strings.TrimSpace(p.Value))
		case "EXDATE":
			for _, v := range strings.Split(p.Value, ",") {
				pp := icsProp{Name: "EXDATE", Params: p.Params, Value: v}
				if t, allDay, tz, err := parseICSTime(pp, fallbackTZ); err == nil {
					zone := cur.TZ
					if zone == "" {
						zone = tz
					}
					cur.ExDates = append(cur.ExDates, occurrenceKey(t, allDay || cur.AllDay, zone))
				}
			}
		case "RECURRENCE-ID":
			if t, allDay, tz, err := parseICSTime(p, fallbackTZ); err == nil {
				zone := tz
				if zone == "" {
					zone = fallbackTZ
				}
				cur.RecurrenceID = occurrenceKey(t, allDay, zone)
			}
		}
	}
	// UTC-anchored recurring events: express in the fallback zone's wall clock.
	for i := range out {
		if out[i].TZ == "" {
			out[i].TZ = fallbackTZ
		}
	}
	return out, nil
}

// normalizeRRuleUntil keeps the rule as-is but drops properties Roost ignores.
func normalizeRRuleUntil(rule string) string {
	rule = strings.TrimPrefix(rule, "RRULE:")
	var keep []string
	for _, part := range strings.Split(rule, ";") {
		k, _, _ := strings.Cut(part, "=")
		switch strings.ToUpper(k) {
		case "FREQ", "INTERVAL", "COUNT", "UNTIL", "BYDAY", "BYMONTHDAY", "BYMONTH", "BYSETPOS", "WKST":
			keep = append(keep, strings.ToUpper(k)+"="+strings.ToUpper(part[len(k)+1:]))
		}
	}
	return strings.Join(keep, ";")
}

// windowsZones maps the Windows zone names Outlook emits to IANA.
var windowsZones = map[string]string{
	"Eastern Standard Time":         "America/New_York",
	"Central Standard Time":         "America/Chicago",
	"Mountain Standard Time":        "America/Denver",
	"US Mountain Standard Time":     "America/Phoenix",
	"Pacific Standard Time":         "America/Los_Angeles",
	"Alaskan Standard Time":         "America/Anchorage",
	"Hawaiian Standard Time":        "Pacific/Honolulu",
	"Atlantic Standard Time":        "America/Halifax",
	"Newfoundland Standard Time":    "America/St_Johns",
	"Canada Central Standard Time":  "America/Regina",
	"Central America Standard Time": "America/Guatemala",
	"Mexico Standard Time":          "America/Mexico_City",
	"Central Standard Time (Mexico)": "America/Mexico_City",
	"SA Pacific Standard Time":      "America/Bogota",
	"E. South America Standard Time": "America/Sao_Paulo",
	"GMT Standard Time":             "Europe/London",
	"Greenwich Standard Time":       "Atlantic/Reykjavik",
	"W. Europe Standard Time":       "Europe/Berlin",
	"Romance Standard Time":         "Europe/Paris",
	"Central Europe Standard Time":  "Europe/Budapest",
	"Central European Standard Time": "Europe/Warsaw",
	"E. Europe Standard Time":       "Europe/Chisinau",
	"FLE Standard Time":             "Europe/Kiev",
	"GTB Standard Time":             "Europe/Bucharest",
	"Russian Standard Time":         "Europe/Moscow",
	"Israel Standard Time":          "Asia/Jerusalem",
	"Arabian Standard Time":         "Asia/Dubai",
	"India Standard Time":           "Asia/Kolkata",
	"China Standard Time":           "Asia/Shanghai",
	"Tokyo Standard Time":           "Asia/Tokyo",
	"Korea Standard Time":           "Asia/Seoul",
	"Singapore Standard Time":       "Asia/Singapore",
	"AUS Eastern Standard Time":     "Australia/Sydney",
	"E. Australia Standard Time":    "Australia/Brisbane",
	"New Zealand Standard Time":     "Pacific/Auckland",
	"UTC":                           "UTC",
	"Coordinated Universal Time":    "UTC",
}

